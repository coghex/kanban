-- | The Claude embedded-review backend: the CLI's stream-json channel driven
-- end to end through a fake @claude@ on a temporary PATH, plus the pure
-- decoding underneath it.
--
-- Held apart from "Spec.Agent.Protocol", which is the app-server exchange and
-- its recovery paths, because nothing here shares a wire message with it.
-- What the two suites do share is a parity target: for the same observable
-- session this backend must produce the events that one does, out of a stream
-- with no request ids, no handshake, and no notification names in common.
--
-- The fake is a real executable Kanban's own compiled backend spawns off
-- PATH, not a fixture backend of this suite's own: half of what is asserted
-- here is the argv that backend builds and the shape it is handed under, and
-- a stand-in would say nothing about the launch an install would perform.
module Spec.Agent.ClaudeReview (spec) where

import Data.Aeson (Value (..), eitherDecode, encode, object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.List (nub)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text
import qualified Data.Text.Encoding as TextEncoding
import Kanban.Models
  ( Assignment (..),
    ModelRoster (..),
    ProviderName (..),
    RoleName (..),
    defaultRoster,
  )
import Kanban.Process (killManagedProcess)
import Kanban.Review
  ( ReviewConnection (..),
    ReviewEvent (..),
    ReviewOutputKind (..),
    ReviewResult (..),
    ReviewStage (..),
    ReviewThreadId (..),
    ReviewTurnOutcome (..),
    StreamRecord (..),
    beginIssueReview,
    decodeStreamRecord,
    finalOutputSchema,
    interruptReview,
    reviewConnectionsForTesting,
    sendReviewMessage,
    stopReviewClient,
    streamUserMessage,
  )
import Spec.Support.Env (withEnvironmentValue)
import Spec.Support.Expect (shouldMention, shouldNotMention)
import Spec.Support.Process
  ( ClaudeReviewFixture (..),
    claudeReviewTurn,
    connectionStopReports,
    recordedClaudeDirectory,
    recordedClaudeInput,
    recordedClaudeLaunches,
    reviewOutputs,
    startFailures,
    threadCreations,
    turnCompletions,
    turnStarts,
    waitForHeldConnections,
    waitForReviewEvents,
    withClaudeReviewClient,
    withClaudeReviewClientUsing,
  )
import System.Directory (canonicalizePath)
import Test.Hspec

spec :: Spec
spec = do
  describe "the Claude embedded review's launch" $ do
    -- The launch in full: every flag in it is load-bearing, so a partial
    -- assertion would let any one of them be dropped. Read off the process
    -- that actually ran rather than off the backend record, which is what
    -- shows the compiled backend is the thing being spawned off PATH.
    it "runs the CLI's stream-json channel hermetically, on the roster's issue_review.claude cell" $
      withClaudeReviewClient (reviewTurn <> [approvedResult 844]) $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        _ <- awaitOneCompletedTurn fixture
        launches <- recordedClaudeLaunches fixture.claudeReviewRecordings
        launches
          `shouldBe` [ [ "-p",
                         "--verbose",
                         "--input-format",
                         "stream-json",
                         "--output-format",
                         "stream-json",
                         "--include-partial-messages",
                         "--json-schema",
                         encodedText finalOutputSchema,
                         "--strict-mcp-config",
                         "--tools",
                         "",
                         "--model",
                         "claude-opus-5",
                         "--effort",
                         "xhigh"
                       ]
                     ]

    -- The rest of the established embedded-process shape. Its streams and
    -- its process-group leadership are asserted against the backend record
    -- in "Spec.Agent.Adapter"; the working directory is the half only a live
    -- launch can show, because a record only says what it asked for.
    it "runs it at the repository root" $
      withClaudeReviewClient (reviewTurn <> [approvedResult 844]) $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        _ <- awaitOneCompletedTurn fixture
        recorded <- canonicalizePath =<< recordedClaudeDirectory fixture.claudeReviewRecordings 0
        expected <- canonicalizePath fixture.claudeReviewRepositoryRoot
        recorded `shouldBe` expected

    it "carries a rerostered issue_review.claude cell rather than a compiled pair" $
      withClaudeReviewClientUsing (rerostered "haiku-9" "low") (reviewTurn <> [approvedResult 844]) $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        _ <- awaitOneCompletedTurn fixture
        launches <- recordedClaudeLaunches fixture.claudeReviewRecordings
        map (dropWhile (/= "--model")) launches `shouldBe` [["--model", "haiku-9", "--effort", "low"]]

    -- Requirement 7. The refusal is reached before a connection is acquired,
    -- and acquiring one is this backend's spawn, so nothing reaches PATH: a
    -- backend whose model and effort are argv cannot be launched from a
    -- roster that cannot supply them, and launching it on the compiled
    -- default is the silent-old-model path D-3 forbids.
    it "refuses a roster with no issue_review.claude cell, and launches nothing" $
      withClaudeReviewClientUsing codexOnlyRoster (reviewTurn <> [approvedResult 844]) $ \fixture -> do
        refused <- beginIssueReview fixture.claudeReviewClient 844
        refusalText refused `shouldMention` "claude"
        refusalText refused `shouldNotMention` "codex"
        recordedClaudeLaunches fixture.claudeReviewRecordings `shouldReturn` []
        map (.connectionId) <$> reviewConnectionsForTesting fixture.claudeReviewClient `shouldReturn` []

    -- A launch that cannot happen at all, which is the first of the two
    -- failures reachable before a thread exists. Reported to the caller, so
    -- the session that asked for the review is the one told.
    --
    -- The executable is taken off PATH rather than made unreadable, because
    -- an unexecutable entry only makes the search /continue/ -- and the next
    -- thing it would find is the operator's own @claude@.
    it "reports a process it could not start, naming its own program" $
      withClaudeReviewClient (reviewTurn <> [approvedResult 844]) $ \fixture ->
        withEnvironmentValue "PATH" fixture.claudeReviewRecordings $ do
          refused <- beginIssueReview fixture.claudeReviewClient 844
          refusalText refused `shouldMention` "Could not start claude stream-json session"
          refusalText refused `shouldNotMention` "codex"
          map (.connectionId) <$> reviewConnectionsForTesting fixture.claudeReviewClient `shouldReturn` []

  describe "the Claude embedded review's transport" $ do
    -- The premise the whole backend rests on: this channel is not the
    -- app-server's. A fake that answered without reading its input would say
    -- nothing about what the client actually writes, so the opening message
    -- is read back and judged.
    it "opens the review with one CLI user message naming the issue, and no app-server request at all" $
      withClaudeReviewClient (reviewTurn <> [approvedResult 844]) $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        _ <- awaitOneCompletedTurn fixture
        written <- recordedClaudeInput fixture.claudeReviewRecordings 0
        case written of
          [opening] -> do
            userMessageShape opening `shouldBe` Right ("user", "user", "text")
            userMessageText opening `shouldMention` "#844"
          other -> expectationFailure ("expected exactly one opening message, got " <> show other)
        mapM_
          (\forbidden -> mapM_ (`shouldNotMention` forbidden) written)
          ["initialize", "thread/start", "turn/start", "turn/steer", "turn/interrupt", "jsonrpc", "outputSchema"]

    -- D-15's one-process-many-turns shape, which is why the backend spawns
    -- per review thread rather than per turn. A message sent between turns
    -- has to reach the process already holding the conversation; respawning
    -- would answer it with none of it.
    it "answers a second between-turn message on the same process, without respawning" $
      withClaudeReviewClient (reviewTurn <> [approvedResult 844]) $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        first <- awaitOneCompletedTurn fixture
        threadId <- soleThread first
        sendReviewMessage fixture.claudeReviewClient threadId Nothing "look again" `shouldReturn` Right ()
        recorded <- waitForReviewEvents "a second completed turn" fixture.claudeReviewEvents ((>= 2) . length . turnCompletions)
        length <$> recordedClaudeLaunches fixture.claudeReviewRecordings `shouldReturn` 1
        -- One thread, two turns, two distinct turn ids: the second turn is
        -- the same conversation continuing, which is the only thing that
        -- makes a between-turn message worth sending.
        map fst (threadCreations recorded) `shouldBe` [844]
        map fst (turnStarts recorded) `shouldBe` [threadId, threadId]
        length (nub (map snd (turnStarts recorded))) `shouldBe` 2
        written <- recordedClaudeInput fixture.claudeReviewRecordings 0
        case map userMessageText written of
          [opening, second] -> do
            opening `shouldMention` "#844"
            second `shouldBe` "look again"
          other -> expectationFailure ("expected two messages on one process, got " <> show other)

  describe "the Claude embedded review's events" $ do
    -- Requirement 4, and the lifecycle ordering the review asked for: the
    -- thread is named before the turn that runs on it, the transcript falls
    -- between, and exactly one completion closes it.
    it "produces the app-server path's lifecycle in the app-server path's order" $
      withClaudeReviewClient (reviewTurn <> [approvedResult 844]) $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        recorded <- awaitOneCompletedTurn fixture
        threadId <- soleThread recorded
        threadId.reviewThreadProvider `shouldNotBe` ""
        lifecycle recorded
          `shouldBe` [ "ReviewThreadCreated",
                       "ReviewTurnStarted",
                       "ReviewOutput",
                       "ReviewOutput",
                       "ReviewTurnCompleted"
                     ]
        map fst (threadCreations recorded) `shouldBe` [844]
        map fst (turnStarts recorded) `shouldBe` [threadId]

    -- The aggregate `assistant` record repeats the whole of what the deltas
    -- streamed a moment earlier. A decoder that took both would render every
    -- review twice, and a fake that omitted that record could not tell.
    it "splits text from thinking and reports each exactly once" $
      withClaudeReviewClient (reviewTurn <> [approvedResult 844]) $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        recorded <- awaitOneCompletedTurn fixture
        threadId <- soleThread recorded
        reviewOutputs recorded
          `shouldBe` [ (threadId, ReasoningOutput, "weighing it"),
                       (threadId, AgentOutput, "reviewing it")
                     ]

    -- Requirement 5: the same 'ReviewResult' the app-server path decodes,
    -- out of the CLI's own structured output.
    it "decodes the structured verdict into the review result the app-server path produces" $
      withClaudeReviewClient (reviewTurn <> [approvedResult 844]) $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        recorded <- awaitOneCompletedTurn fixture
        threadId <- soleThread recorded
        turnCompletions recorded
          `shouldBe` [ ReviewTurnCompleted
                         threadId
                         TurnSucceeded
                         Nothing
                         (Just (encodedText (verdictValue 844), verdictResult 844))
                     ]

    -- Requirement 5's other half, in all four shapes a turn can take without
    -- producing one: no verdict, an unusable verdict, an error the CLI put
    -- words to, and one it only classified. A turn that produced no verdict
    -- reviewed nothing, however cleanly the CLI reports finishing, and a
    -- silent success is what would put an unreviewed issue through the
    -- workflow.
    it "fails a turn whose output does not satisfy the schema, rather than succeeding silently" $ do
      failedTurnSays
        "Claude stream-json session ended its turn without the structured review verdict"
        (rawResult "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"done\"}")
      failedTurnSays
        "Claude stream-json session returned a review verdict that does not satisfy the schema"
        (rawResult "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"structured_output\":{\"issue\":844,\"stage\":\"revision\"}}")
      failedTurnSays
        "Claude stream-json session ended its turn with an error: the session ran out of turns"
        (rawResult "{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,\"result\":\"the session ran out of turns\"}")
      failedTurnSays
        "Claude stream-json session ended its turn with status error_during_execution"
        (rawResult "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true}")

    -- A record this decoder cannot read is recoverable: the stream goes on
    -- and the turn still completes. Reporting it as a dead session would
    -- throw a whole review away over one unreadable line.
    it "warns about a record it cannot read and goes on reading the stream" $
      withClaudeReviewClient (malformedLine : reviewTurn <> [approvedResult 844]) $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        recorded <- awaitOneCompletedTurn fixture
        threadId <- soleThread recorded
        case [(provider, message) | ReviewProtocolWarning provider message <- recorded] of
          [(provider, message)] -> do
            provider `shouldBe` ClaudeProvider
            message `shouldMention` "Claude stream-json session wrote a line that is not JSON"
          other -> expectationFailure ("expected exactly one protocol warning, got " <> show other)
        map turnOutcomeOf (turnCompletions recorded) `shouldBe` [Just TurnSucceeded]
        map fst (turnStarts recorded) `shouldBe` [threadId]

    -- The stderr half of requirement 4, and both halves of what makes it
    -- worth anything: a per-thread process writes its diagnostics for the
    -- one review it is serving, so they belong in that review's transcript
    -- and they are tagged with the program that wrote them. Reported against
    -- the empty thread they would be a notice about nothing, and tagged
    -- @[codex]@ they would name a program the operator is not running.
    --
    -- The early line is the one that matters. The two readers run
    -- concurrently, so stderr routinely arrives before the record that names
    -- the thread — and a provider's complaints on the way up are exactly the
    -- diagnostics worth keeping. The fake sleeps on either side of that
    -- record so both orderings are the ones under test rather than whichever
    -- two the scheduler happens to pick.
    it "reports a per-thread process's stderr against its own review, tagged with its own brand" $
      withClaudeReviewClient (["printf '%s\\n' 'warming up' >&2", "sleep 0.4"] <> reviewTurn <> ["sleep 0.4", "printf '%s\\n' 'still going' >&2", approvedResult 844]) $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        recorded <-
          waitForReviewEvents
            "both diagnostics and a completed turn"
            fixture.claudeReviewEvents
            (\events -> length (diagnosticOutputs events) >= 2 && not (null (turnCompletions events)))
        threadId <- soleThread recorded
        diagnosticOutputs recorded
          `shouldBe` [ (threadId, DiagnosticOutput ClaudeProvider, "warming up"),
                       (threadId, DiagnosticOutput ClaudeProvider, "still going")
                     ]
        -- Held rather than dropped, and released only once the review exists
        -- to hold it: the line the provider wrote first is reported after the
        -- session it belongs to has been announced.
        lifecycle recorded
          `shouldBe` [ "ReviewThreadCreated",
                       "ReviewOutput",
                       "ReviewTurnStarted",
                       "ReviewOutput",
                       "ReviewOutput",
                       "ReviewOutput",
                       "ReviewTurnCompleted"
                     ]

    -- The buffer must not be able to swallow anything. A provider that dies
    -- complaining never names a session, so nothing will ever claim what it
    -- wrote; it is released unattributed, which is where every
    -- shared-process diagnostic goes and where these went before they were
    -- held at all.
    it "still reports early stderr from a process that never names a session" $
      withClaudeReviewClient ["printf '%s\\n' 'cannot start' >&2", "exit 4"] $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        recorded <-
          waitForReviewEvents
            "the released diagnostic and the start failure"
            fixture.claudeReviewEvents
            (\events -> not (null (diagnosticOutputs events)) && not (null (startFailures events)))
        map (\(threadId, outputKind, text) -> (threadId.reviewThreadProvider, outputKind, text)) (diagnosticOutputs recorded)
          `shouldBe` [("", DiagnosticOutput ClaudeProvider, "cannot start")]
        map fst (startFailures recorded) `shouldBe` [844]

    -- A connection serves one review for its whole life, so the session its
    -- provider names must be the one it named first. Adopting a later one
    -- would carry the turn, its transcript and its verdict to a thread no
    -- session is keyed by — and with the pending start already consumed,
    -- nothing would announce that thread to anybody.
    it "disregards a later record naming a different session, keeping the review's own thread" $
      withClaudeReviewClient (reviewTurn <> [approvedResult 844, driftingSecondTurn]) $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        recorded <-
          waitForReviewEvents
            "both turns"
            fixture.claudeReviewEvents
            ((>= 2) . length . turnCompletions)
        threadId <- soleThread recorded
        -- One thread, announced once, and both turns on it.
        map fst (turnStarts recorded) `shouldBe` [threadId, threadId]
        [completed | ReviewTurnCompleted completed _ _ _ <- recorded] `shouldBe` [threadId, threadId]
        case [message | ReviewProtocolWarning ClaudeProvider message <- recorded] of
          [message] -> message `shouldMention` "opened a turn on session someone-elses-session, not the one this review is running on"
          other -> expectationFailure ("expected exactly one drift warning, got " <> show other)

    -- Requirement 6 and the review's diagnostic clause. Every surface this
    -- backend can fail on names the program the operator is actually
    -- running, and none of them names the other provider's.
    it "names its own program in every diagnostic, and never the other provider's" $
      withClaudeReviewClient (malformedLine : reviewTurn <> [rawResult "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true}"]) $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        _ <- awaitOneCompletedTurn fixture
        stopReviewClient fixture.claudeReviewClient
        recorded <- waitForReviewEvents "the connection's end" fixture.claudeReviewEvents (not . null . connectionStopReports)
        let spoken = diagnostics recorded
        length spoken `shouldSatisfy` (>= 3)
        mapM_ (\message -> Data.Text.toLower message `shouldMention` "claude stream-json session") spoken
        mapM_ (\message -> Data.Text.toLower message `shouldNotMention` "codex") spoken

  describe "the Claude embedded review's failures" $ do
    -- Before a thread exists there is no thread-scoped event that could
    -- reach the session, so its issue number is the only thing naming it.
    -- Without this a review whose process died on the way up would sit at
    -- "starting" for good, with no connection behind it.
    --
    -- Named once, not once per terminal path: a dying connection reaches two
    -- of them -- its output reader hitting EOF and its watcher reaping the
    -- process -- and which arrives first is a race, so the diagnostic is
    -- asserted by the program it names rather than by the cause it gives.
    it "fails the review by issue number when its process dies before naming a session" $
      withClaudeReviewClient ["exit 7"] $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        recorded <- waitForReviewEvents "the start failure" fixture.claudeReviewEvents (not . null . startFailures)
        map fst (startFailures recorded) `shouldBe` [844]
        mapM_ (`shouldMention` "Claude stream-json session") (map snd (startFailures recorded))
        turnCompletions recorded `shouldBe` []

    -- The correction this slice's review made explicit, and the two-process
    -- isolation it asked for beside it. One per-thread process dying is not
    -- the client dying: the review it was serving fails and everything else
    -- goes on. 'ReviewClientStopped' disconnects every session there is, so
    -- raising it here would take down a healthy review on another process.
    it "fails only the dead process's own turn, leaving the client and the other review running" $
      withClaudeReviewClient stallingTurn $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        _ <- waitForReviewEvents "the stalled review's turn" fixture.claudeReviewEvents (not . null . turnStarts)
        beginIssueReview fixture.claudeReviewClient 845 `shouldReturn` Right ()
        settled <- waitForReviewEvents "the healthy review's verdict" fixture.claudeReviewEvents (not . null . turnCompletions)
        (stalled, healthy) <- stalledAndHealthy settled
        length <$> recordedClaudeLaunches fixture.claudeReviewRecordings `shouldReturn` 2
        killConnectionOf fixture stalled
        recorded <- waitForReviewEvents "the stalled connection's end" fixture.claudeReviewEvents (not . null . connectionStopReports)
        [threadId | ReviewTurnCompleted threadId TurnFailed _ _ <- recorded] `shouldBe` [stalled]
        [threadId | ReviewTurnCompleted threadId TurnSucceeded _ _ <- recorded] `shouldBe` [healthy]
        -- Reported against the connection that ended, and never as the
        -- client's own end. A dying connection reaches two terminal paths,
        -- so the report may arrive from either or both; what must never
        -- appear is a report naming the survivor, or naming no connection.
        map fst (connectionStopReports recorded) `shouldSatisfy` all (== stalled.reviewThreadConnection)
        [message | ReviewClientStopped message <- recorded] `shouldBe` []
        surviving <- waitForHeldConnections fixture.claudeReviewClient 1
        surviving `shouldBe` [healthy.reviewThreadConnection]
        -- The client is not the connection: a further review still starts.
        beginIssueReview fixture.claudeReviewClient 846 `shouldReturn` Right ()

    -- MODEL-16's boundary, held closed. The app-server's control requests
    -- are meaningless to a CLI process, which would read one as ordinary
    -- input and answer it as a review instruction.
    it "refuses a mid-turn steer and an interrupt rather than writing app-server requests" $
      withClaudeReviewClient (reviewTurn <> [approvedResult 844]) $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        recorded <- awaitOneCompletedTurn fixture
        threadId <- soleThread recorded
        sendReviewMessage fixture.claudeReviewClient threadId (Just "turn-1") "redirect"
          `shouldReturn` Left "Kanban cannot steer a running turn on claude stream-json session yet"
        interruptReview fixture.claudeReviewClient threadId "turn-1"
          `shouldReturn` Left "Kanban cannot interrupt a turn on claude stream-json session yet"
        -- Nothing reached the process: it read the opening message and
        -- nothing else.
        length <$> recordedClaudeInput fixture.claudeReviewRecordings 0 `shouldReturn` 1
        [event | event@ReviewSteerUndelivered {} <- recorded] `shouldBe` []

  describe "the CLI stream-json decoder" $ do
    it "opens a turn on the session and turn a system init record names" $
      decodeStreamRecord "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s-1\",\"uuid\":\"t-1\"}"
        `shouldBe` Right (StreamTurnOpened "s-1" "t-1")

    -- The records a hermetic launch still emits, and the aggregate that
    -- would otherwise duplicate the transcript. Recognised and ignored
    -- rather than warned about, so a CLI release adding a record type does
    -- not fill the review panel with warnings.
    it "ignores every record a review has no use for" $
      map
        decodeStreamRecord
        [ "{\"type\":\"system\",\"subtype\":\"hook_started\",\"hook_name\":\"SessionStart\"}",
          "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
          "{\"type\":\"system\",\"subtype\":\"thinking_tokens\",\"estimated_tokens\":50}",
          "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"already streamed\"}]}}",
          "{\"type\":\"user\",\"message\":{\"content\":[]}}",
          "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"allowed\"}}",
          "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
          "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"signature_delta\",\"signature\":\"AbCd\"}}}",
          "{\"type\":\"something_a_later_cli_adds\"}"
        ]
        `shouldBe` replicate 9 (Right StreamIgnored)

    it "splits the two delta kinds a transcript is made of" $
      map
        decodeStreamRecord
        [ "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"spoken\"}}}",
          "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"weighed\"}}}"
        ]
        `shouldBe` [Right (StreamDelta AgentOutput "spoken"), Right (StreamDelta ReasoningOutput "weighed")]

    -- The decoder knows the channel and not who is speaking it, so its
    -- diagnostics are the predicate of a sentence the backend's own label
    -- opens. One that named a brand here would name it in every install,
    -- including one where a different provider runs the same channel.
    it "refuses a record it cannot read, without naming a provider" $
      map
        decodeStreamRecord
        [ "not json at all",
          "{\"session_id\":\"s-1\"}",
          "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s-1\"}",
          "{\"type\":\"stream_event\"}",
          "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\"}}",
          "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\"}}}"
        ]
        `shouldSatisfy` all (either (not . mentionsAProvider) (const False))

    it "writes one user message, in the shape the CLI's input format reads" $
      encodedText (streamUserMessage "review #844")
        `shouldBe` "{\"message\":{\"content\":[{\"text\":\"review #844\",\"type\":\"text\"}],\"role\":\"user\"},\"type\":\"user\"}"

-- | One realistic turn's worth of stream, minus the result line each test
-- supplies for itself.
reviewTurn :: [ByteString.ByteString]
reviewTurn = claudeReviewTurn "weighing it" "reviewing it"

-- | A second turn announcing a session this connection has never used, then
-- completing normally. Only reachable by a provider that has already opened
-- one, so it is appended after a first turn's result rather than replacing
-- it.
driftingSecondTurn :: ByteString.ByteString
driftingSecondTurn =
  ByteString.intercalate
    "\n"
    [ "printf '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"someone-elses-session\",\"uuid\":\"turn-drifted\"}\\n'",
      approvedResult 844
    ]

-- | A turn that never ends for issue 844 and completes normally for anything
-- else, so one client holds a stalled process and a healthy one at once.
--
-- Told apart by the opening message rather than by spawn order, because the
-- two processes are started by two separate calls and nothing about the
-- fixture guarantees which reaches its first read first.
stallingTurn :: [ByteString.ByteString]
stallingTurn =
  reviewTurn
    <> [ "case \"$message\" in",
         "  *'#844'*) while true; do sleep 1; done ;;",
         "  *) " <> approvedResult 845 <> " ;;",
         "esac"
       ]

-- | The result line closing a turn that produced a verdict for @issueNumber@.
approvedResult :: Int -> ByteString.ByteString
approvedResult issueNumber =
  rawResult
    ( "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"stop_reason\":\"tool_use\",\"structured_output\":"
        <> ByteString.pack (LazyByteString.unpack (encode (verdictValue issueNumber)))
        <> "}"
    )

-- | A line the fake writes to its stdout verbatim.
rawResult :: ByteString.ByteString -> ByteString.ByteString
rawResult line = "printf '%s\\n' '" <> line <> "'"

malformedLine :: ByteString.ByteString
malformedLine = rawResult "notjsonatall"

-- | Asserts that a turn ending in @script@ is reported as failed, saying
-- @detail@ and producing no verdict.
failedTurnSays :: Text -> ByteString.ByteString -> Expectation
failedTurnSays detail script =
  withClaudeReviewClient (reviewTurn <> [script]) $ \fixture -> do
    beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
    recorded <- awaitOneCompletedTurn fixture
    threadId <- soleThread recorded
    case turnCompletions recorded of
      [ReviewTurnCompleted completed TurnFailed (Just message) Nothing] -> do
        completed `shouldBe` threadId
        message `shouldMention` detail
      other -> expectationFailure ("expected one failed turn saying " <> show detail <> ", got " <> show other)

verdictValue :: Int -> Value
verdictValue issueNumber =
  object
    [ "issue" .= issueNumber,
      "stage" .= ("revision" :: Text),
      "approved" .= False,
      "reviewerRoute" .= ("codex" :: Text),
      "models" .= (["Opus 5 xhigh"] :: [Text]),
      "commentUrl" .= ("https://example.invalid/c/1" :: Text),
      "blockingReasons" .= ([] :: [Text])
    ]

verdictResult :: Int -> ReviewResult
verdictResult issueNumber =
  ReviewResult
    { reviewResultIssue = issueNumber,
      reviewResultStage = IssueRevision,
      reviewResultApproved = False,
      reviewResultReviewerRoute = "codex",
      reviewResultModels = ["Opus 5 xhigh"],
      reviewResultCommentUrl = Just "https://example.invalid/c/1",
      reviewResultBlockingReasons = []
    }

encodedText :: Value -> Text
encodedText = TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode

awaitOneCompletedTurn :: ClaudeReviewFixture -> IO [ReviewEvent]
awaitOneCompletedTurn fixture =
  waitForReviewEvents "one completed turn" fixture.claudeReviewEvents (not . null . turnCompletions)

soleThread :: [ReviewEvent] -> IO ReviewThreadId
soleThread recorded = case threadCreations recorded of
  [(_, threadId)] -> pure threadId
  other -> fail ("expected exactly one review thread, got " <> show other)

-- | The stalled review's thread and the healthy one's, told apart by which
-- of them produced a verdict.
stalledAndHealthy :: [ReviewEvent] -> IO (ReviewThreadId, ReviewThreadId)
stalledAndHealthy recorded =
  case (map snd (threadCreations recorded), [threadId | ReviewTurnCompleted threadId TurnSucceeded _ _ <- recorded]) of
    ([first, second], [healthy])
      | first == healthy -> pure (second, first)
      | second == healthy -> pure (first, second)
    other -> fail ("expected one stalled and one completed review thread, got " <> show other)

killConnectionOf :: ClaudeReviewFixture -> ReviewThreadId -> IO ()
killConnectionOf fixture threadId = do
  connections <- reviewConnectionsForTesting fixture.claudeReviewClient
  case filter ((== threadId.reviewThreadConnection) . (.connectionId)) connections of
    [connection] -> killManagedProcess connection.connectionManaged
    other -> fail ("expected exactly one connection serving that review, got " <> show (length other))

lifecycle :: [ReviewEvent] -> [String]
lifecycle = map name
  where
    name ReviewThreadCreated {} = "ReviewThreadCreated"
    name ReviewTurnStarted {} = "ReviewTurnStarted"
    name ReviewOutput {} = "ReviewOutput"
    name ReviewTurnCompleted {} = "ReviewTurnCompleted"
    name other = show other

-- | Every line a provider wrote to its stderr, as the thread it was reported
-- against, the kind that names who wrote it, and the text.
diagnosticOutputs :: [ReviewEvent] -> [(ReviewThreadId, ReviewOutputKind, Text)]
diagnosticOutputs recorded =
  [(threadId, outputKind, text) | (threadId, outputKind@DiagnosticOutput {}, text) <- reviewOutputs recorded]

turnOutcomeOf :: ReviewEvent -> Maybe ReviewTurnOutcome
turnOutcomeOf (ReviewTurnCompleted _ outcome _ _) = Just outcome
turnOutcomeOf _ = Nothing

-- | Every message in which this backend said something went wrong.
diagnostics :: [ReviewEvent] -> [Text]
diagnostics recorded =
  [message | ReviewProtocolWarning _ message <- recorded]
    <> [message | ReviewTurnCompleted _ TurnFailed (Just message) _ <- recorded]
    <> [message | ReviewStartFailed _ message <- recorded]
    <> [message | ReviewConnectionStopped _ message <- recorded]

mentionsAProvider :: Text -> Bool
mentionsAProvider message = any (`Data.Text.isInfixOf` Data.Text.toLower message) ["claude", "codex"]

refusalText :: Either Text () -> Text
refusalText = either id (const "")

-- | The text of every content block in one recorded CLI user message.
userMessageText :: Text -> Text
userMessageText written = case decodeObject written >>= objectField "message" >>= objectField "content" of
  Just (Array items) ->
    mconcat [text | Object item <- foldMap pure items, Just (String text) <- [KeyMap.lookup (Key.fromString "text") item]]
  _ -> ""

-- | The record type, the message role, and the first content block's type of
-- one recorded CLI user message.
userMessageShape :: Text -> Either String (Text, Text, Text)
userMessageShape written = case decodeObject written of
  Nothing -> Left ("not a JSON object: " <> Data.Text.unpack written)
  Just value -> case (stringAt ["type"] value, stringAt ["message", "role"] value, firstContentType value) of
    (Just recordType, Just role, Just contentKind) -> Right (recordType, role, contentKind)
    _ -> Left ("unexpected user message shape: " <> Data.Text.unpack written)
  where
    firstContentType value = case objectField "message" value >>= objectField "content" of
      Just (Array items) -> case foldMap pure items of
        item : _ -> stringAt ["type"] item
        [] -> Nothing
      _ -> Nothing

decodeObject :: Text -> Maybe Value
decodeObject written = case eitherDecode (LazyByteString.fromStrict (TextEncoding.encodeUtf8 written)) of
  Right value@(Object _) -> Just value
  _ -> Nothing

stringAt :: [Text] -> Value -> Maybe Text
stringAt [] (String value) = Just value
stringAt (key : keys) value = objectField key value >>= stringAt keys
stringAt _ _ = Nothing

objectField :: Text -> Value -> Maybe Value
objectField key (Object value) = KeyMap.lookup (Key.fromText key) value
objectField _ _ = Nothing

-- | The default roster with a different @issue_review.claude@ cell, so a
-- launch built from a compiled pair rather than from the roster fails.
rerostered :: Text -> Text -> ModelRoster
rerostered model effort =
  defaultRoster
    { rosterAssignments =
        Map.insert
          (IssueReviewRole, ClaudeProvider)
          (Assignment model effort (model <> " " <> effort))
          defaultRoster.rosterAssignments
    }

-- | A valid roster loading only Codex, so @issue_review.claude@ cannot be
-- resolved at all.
codexOnlyRoster :: ModelRoster
codexOnlyRoster = defaultRoster {rosterAgents = [CodexProvider]}
