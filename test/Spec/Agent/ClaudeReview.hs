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

import Control.Concurrent (threadDelay)
import Data.Aeson (Value (..), eitherDecode, encode, object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.List (isPrefixOf, nub)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text
import qualified Data.Text.Encoding as TextEncoding
import Kanban.Models
  ( Assignment (..),
    ModelRoster (..),
    ProviderName (..),
    RoleName (..),
    assignmentFor,
    defaultRoster,
  )
import Kanban.Domain (defaultWorkflowConfig)
import Kanban.Process (killManagedProcess)
import Kanban.Review
  ( InterruptAcknowledgement (..),
    InterruptSettlement (..),
    InterruptTarget (..),
    PendingInterrupt (..),
    ReviewConnection (..),
    ReviewEvent (..),
    ReviewOutputKind (..),
    ReviewResult (..),
    ReviewStage (..),
    ReviewThreadId (..),
    ReviewTurnOutcome (..),
    StreamRecord (..),
    reviewStageForLabels,
    StreamTurnResult (..),
    beginIssueReview,
    decodeStreamRecord,
    finalOutputSchema,
    interruptReview,
    pendingInterrupt,
    reviewConnectionsForTesting,
    sendReviewMessage,
    settleInterrupt,
    stopReviewClient,
    streamInterruptRequest,
    streamUserMessage,
  )
import Kanban.ReviewToolServer (reviewToolServerConfig)
import Kanban.UI.Review
  ( applyFailedInterrupt,
    carryUndelivered,
    markReviewSessionDisconnected,
    newReviewSession,
    reviewOutcomePhase,
    reviewSessionHoldsUnsentText,
    undeliveredForIssue,
  )
import Kanban.UI.Session (reviewSessionInputLive, reviewSessionReusable)
import Kanban.UI.SessionCore (newAgentSession)
import Kanban.UI.Types (AgentSession (..), ChatTranscript (..), ReviewDetail (..), ReviewPhase (..), ReviewSession)
import Spec.Support.Env (withEnvironmentValue)
import Spec.Support.Expect (shouldMention, shouldNotMention)
import Spec.Support.Fixtures (baseIssue, fixtureReviewThread)
import Spec.Support.Roster (cellOf)
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath ((</>))
import Spec.Support.Process
  ( ClaudeReviewFixture (..),
    claudeReviewTurn,
    connectionStopReports,
    recordedClaudeDirectory,
    recordedClaudeInput,
    recordedClaudeLaunches,
    reviewOutputs,
    withRoutedReviewClientUsing,
    startFailures,
    threadCreations,
    plainChatTranscript,
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
    -- shows the compiled backend is the thing being spawned off PATH. The
    -- two values only a live launch decides — the executable the MCP
    -- configuration re-enters and the endpoint it proxies over — are held
    -- separately: the executable must be exactly the one this process is
    -- running (never a PATH lookup), and the endpoint must be a fresh
    -- directory under this run's own private review-tools root.
    --
    -- The three isolation flags each cover their own scope, and the empty
    -- `--setting-sources` is the one that keeps the operator's user,
    -- project, and local settings — and the hooks they declare — out of the
    -- spawned session. What it does not do is stop every hook: one can still
    -- arrive from outside those three sources, which is why the decoder
    -- below goes on ignoring the hook records.
    it "runs the CLI's stream-json channel with the machine's settings, MCP servers, and built-in tools excluded, on the roster's issue_review.claude cell" $
      withClaudeReviewClient (reviewTurn <> [approvedResult 844]) $ \fixture -> do
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
        _ <- awaitOneCompletedTurn fixture
        launches <- recordedClaudeLaunches fixture.claudeReviewRecordings
        launch <- case launches of
          [one] -> pure one
          other -> fail ("expected exactly one launch, got " <> show other)
        endpoint <- case argumentAfter "--mcp-config" launch >>= mcpEndpointOf of
          Just value -> pure (Data.Text.unpack value)
          Nothing -> fail ("the launch carries no decodable --mcp-config: " <> show launch)
        cacheRoot <- maybe (fail "the fixture set no XDG_CACHE_HOME") pure =<< lookupEnv "XDG_CACHE_HOME"
        (cacheRoot </> "kanban" </> "review-tools") `shouldSatisfy` (`isPrefixOf` endpoint)
        executable <- getExecutablePath
        launch
          `shouldBe` [ "-p",
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
                       "--setting-sources",
                       "",
                       "--mcp-config",
                       encodedText (reviewToolServerConfig executable endpoint),
                       "--allowedTools",
                       "mcp__kanban__kanban_prompt_user,mcp__kanban__kanban_github_issue",
                       "--model",
                       "claude-opus-5",
                       "--effort",
                       "xhigh"
                     ]

    -- The rest of the established embedded-process shape. Its streams and
    -- its process-group leadership are asserted against the backend record
    -- in "Spec.Agent.Adapter"; the working directory is the half only a live
    -- launch can show, because a record only says what it asked for.
    it "runs it at the repository root" $
      withClaudeReviewClient (reviewTurn <> [approvedResult 844]) $ \fixture -> do
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
        _ <- awaitOneCompletedTurn fixture
        recorded <- canonicalizePath =<< recordedClaudeDirectory fixture.claudeReviewRecordings 0
        expected <- canonicalizePath fixture.claudeReviewRepositoryRoot
        recorded `shouldBe` expected

    it "carries a rerostered issue_review.claude cell rather than a compiled pair" $
      withClaudeReviewClientUsing (rerostered "haiku-9" "low") (reviewTurn <> [approvedResult 844]) $ \fixture -> do
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
        _ <- awaitOneCompletedTurn fixture
        launches <- recordedClaudeLaunches fixture.claudeReviewRecordings
        map (dropWhile (/= "--model")) launches `shouldBe` [["--model", "haiku-9", "--effort", "low"]]

    -- Issue #589: the routing itself, rather than a backend this fixture
    -- picked. Every other arm here hands 'startResolvedReviewClient' the
    -- Claude backend, so none of them would notice an install that never
    -- selected it -- which is exactly what a Claude-only install did while
    -- the launch boundary still resolved @issue_review.codex@ and refused
    -- before any backend was reached.
    --
    -- Asserted through to a completed turn, not just a started client,
    -- because "the backend started" and "a review ran on it" are different
    -- claims and only the second one is what the mode promises.
    it "starts a Claude-only install's review through the routing, on that roster's own cell" $
      withRoutedReviewClientUsing claudeOnlyRoster (reviewTurn <> [approvedResult 844]) $ \fixture -> do
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
        _ <- awaitOneCompletedTurn fixture
        launches <- recordedClaudeLaunches fixture.claudeReviewRecordings
        let cell = cellOf (assignmentFor claudeOnlyRoster IssueReviewRole ClaudeProvider)
        map (dropWhile (/= "--model")) launches
          `shouldBe` [["--model", cell.assignmentModel, "--effort", cell.assignmentEffort]]

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
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
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
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
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
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
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
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
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
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
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
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
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
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
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
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
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
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
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
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
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
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
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
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
        _ <- waitForReviewEvents "the stalled review's turn" fixture.claudeReviewEvents (not . null . turnStarts)
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 845) `shouldReturn` Right ()
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
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 846) `shouldReturn` Right ()

  -- MODEL-16. The channel has no operation that redirects a turn in flight
  -- (D-16), so a message typed into one ends that turn and becomes the next.
  -- Both halves of that handshake are asserted through a real fake CLI,
  -- because what has to hold is an ordering between two processes: the
  -- guidance must reach the provider's stdin after the interrupt and after
  -- the turn it targeted has stopped, and nothing readable off one side alone
  -- shows that.
  describe "the Claude embedded review's mid-turn guidance" $ do
    -- The acknowledgement first, then the turn's own end -- the order the
    -- live CLI produced when D-16 was probed.
    it "interrupts the running turn and sends the typed message as the next one" $
      withClaudeReviewClient (interruptibleSession [acknowledgeInterrupt, abortedResult]) $ \fixture -> do
        recorded <- guidanceRoundTrip fixture "focus on the parser"
        map turnOutcomeOf (filter isTurnCompletion recorded)
          `shouldBe` [Just TurnInterrupted, Just TurnSucceeded]
        written <- awaitRecordedWrites fixture 3
        map classifyWrite written `shouldBe` ["prompt", "interrupt", "guidance: focus on the parser"]
        [event | event@ReviewSteerUndelivered {} <- recorded] `shouldBe` []
        interruptFailures recorded `shouldBe` []

    -- The same handshake with its two answers swapped. Neither the channel
    -- nor the CLI orders the acknowledgement against the result of the turn
    -- it ended, so an implementation that reads either as the trigger works
    -- exactly half the time.
    it "sends it in the other arrival order too, and writes it exactly once" $
      withClaudeReviewClient (interruptibleSession [abortedResult, acknowledgeInterrupt]) $ \fixture -> do
        recorded <- guidanceRoundTrip fixture "focus on the parser"
        map turnOutcomeOf (filter isTurnCompletion recorded)
          `shouldBe` [Just TurnInterrupted, Just TurnSucceeded]
        written <- awaitRecordedWrites fixture 3
        map classifyWrite written `shouldBe` ["prompt", "interrupt", "guidance: focus on the parser"]
        interruptFailures recorded `shouldBe` []

    -- A cancellation asks for the turn to end and nothing more. Its report is
    -- the turn's own completion, so there must be no follow-up turn behind
    -- it -- and the turn must be distinguishable from one that ran out.
    it "ends a running turn on an explicit cancellation, with nothing sent after it" $
      withClaudeReviewClient (interruptibleSession [acknowledgeInterrupt, abortedResult]) $ \fixture -> do
        threadId <- awaitRunningTurn fixture
        interruptReview fixture.claudeReviewClient threadId "turn-1" `shouldReturn` Right ()
        recorded <- awaitOneCompletedTurn fixture
        map turnOutcomeOf (filter isTurnCompletion recorded) `shouldBe` [Just TurnInterrupted]
        written <- awaitRecordedWrites fixture 2
        map classifyWrite written `shouldBe` ["prompt", "interrupt"]
        interruptFailures recorded `shouldBe` []

    -- The failure this path owns. A refused interrupt is not a rejected
    -- steer: there is no steer to reject on this channel, so it is reported
    -- as its own event carrying the message back (D-16). What must not happen
    -- is the message going into the turn that is still running.
    it "reports a refused interrupt as its own failure, keeping the message" $
      withClaudeReviewClient (interruptibleSession [refuseInterrupt "cannot interrupt right now"]) $ \fixture -> do
        threadId <- awaitRunningTurn fixture
        sendReviewMessage fixture.claudeReviewClient threadId (Just "turn-1") "focus on the parser"
          `shouldReturn` Right ()
        recorded <- waitForReviewEvents "the interrupt failure" fixture.claudeReviewEvents (not . null . interruptFailures)
        case interruptFailures recorded of
          [(failed, cause, held)] -> do
            failed `shouldBe` threadId
            cause `shouldMention` "cannot interrupt right now"
            held `shouldBe` Just "focus on the parser"
          other -> expectationFailure ("expected one interrupt failure, got " <> show other)
        [event | event@ReviewSteerUndelivered {} <- recorded] `shouldBe` []
        -- The turn is still the one that was running, and nothing was written
        -- into it.
        turnCompletions recorded `shouldBe` []
        written <- awaitRecordedWrites fixture 2
        map classifyWrite written `shouldBe` ["prompt", "interrupt"]

    -- The cancellation half of the same failure. Writing the control request
    -- is not cancelling: the turn goes on running, and a session told only
    -- that the write succeeded would show it as stopping and never hear
    -- otherwise.
    it "reports a refused cancellation too, with no message to hand back" $
      withClaudeReviewClient (interruptibleSession [refuseInterrupt "cannot interrupt right now"]) $ \fixture -> do
        threadId <- awaitRunningTurn fixture
        interruptReview fixture.claudeReviewClient threadId "turn-1" `shouldReturn` Right ()
        recorded <- waitForReviewEvents "the interrupt failure" fixture.claudeReviewEvents (not . null . interruptFailures)
        case interruptFailures recorded of
          [(failed, cause, held)] -> do
            failed `shouldBe` threadId
            cause `shouldMention` "cannot interrupt right now"
            held `shouldBe` Nothing
          other -> expectationFailure ("expected one interrupt failure, got " <> show other)
        -- The turn the cancellation did not end is still running.
        turnCompletions recorded `shouldBe` []

    -- The answer that arrives and cannot be read. Nothing else will be said
    -- about the request, and the turn goes on running, so an implementation
    -- that only warned about the line would strand the message: shown as
    -- sent, never delivered, and every later send refused because an
    -- interrupt is still recorded as in flight.
    it "hands the message back when the answer to the interrupt cannot be read" $
      withClaudeReviewClient (interruptibleSession [unreadableAnswer]) $ \fixture -> do
        threadId <- awaitRunningTurn fixture
        sendReviewMessage fixture.claudeReviewClient threadId (Just "turn-1") "focus on the parser"
          `shouldReturn` Right ()
        recorded <- waitForReviewEvents "the interrupt failure" fixture.claudeReviewEvents (not . null . interruptFailures)
        case interruptFailures recorded of
          [(failed, cause, held)] -> do
            failed `shouldBe` threadId
            cause `shouldMention` "without naming which one"
            held `shouldBe` Just "focus on the parser"
          other -> expectationFailure ("expected one interrupt failure, got " <> show other)
        -- Still warned about, like any line this backend could not read.
        diagnostics recorded `shouldSatisfy` any (Data.Text.isInfixOf "without naming which one")
        -- The turn it failed to end is still running, and nothing was written
        -- into it.
        turnCompletions recorded `shouldBe` []
        written <- awaitRecordedWrites fixture 2
        map classifyWrite written `shouldBe` ["prompt", "interrupt"]
        -- And the thread is free to try again rather than stuck reporting an
        -- interrupt that will never settle.
        retried <- sendReviewMessage fixture.claudeReviewClient threadId (Just "turn-1") "focus on the parser"
        retried `shouldBe` Right ()

    -- The answer that names a request this client never sent. There is only
    -- ever one interrupt in flight on a thread and this backend writes no
    -- other kind of control request, so such an answer is not somebody
    -- else's to wait for -- it is the exchange turning out not to be what
    -- this client thinks it is, and ignoring it strands the message exactly
    -- as an unreadable one would.
    it "hands the message back when the answer names a request it never sent" $
      withClaudeReviewClient (interruptibleSession [mismatchedAnswer]) $ \fixture -> do
        threadId <- awaitRunningTurn fixture
        sendReviewMessage fixture.claudeReviewClient threadId (Just "turn-1") "focus on the parser"
          `shouldReturn` Right ()
        recorded <- waitForReviewEvents "the interrupt failure" fixture.claudeReviewEvents (not . null . interruptFailures)
        case interruptFailures recorded of
          [(failed, cause, held)] -> do
            failed `shouldBe` threadId
            cause `shouldMention` "not the interrupt this review is waiting on"
            held `shouldBe` Just "focus on the parser"
          other -> expectationFailure ("expected one interrupt failure, got " <> show other)
        -- The turn it failed to end is still running, and nothing was
        -- written into it.
        turnCompletions recorded `shouldBe` []
        written <- awaitRecordedWrites fixture 2
        map classifyWrite written `shouldBe` ["prompt", "interrupt"]
        -- And the thread can try again rather than reporting an interrupt
        -- that will never settle.
        sendReviewMessage fixture.claudeReviewClient threadId (Just "turn-1") "focus on the parser"
          `shouldReturn` Right ()

    -- The same bound from the turn's side. A thread runs one turn at a time,
    -- so a turn ending that is not the one the interrupt named is proof the
    -- target is no longer running -- and nothing about it says an interrupt
    -- is what stopped it, so the message comes back rather than being
    -- released into whatever the provider is doing now.
    it "hands the message back when a turn other than the target ends" $
      withClaudeReviewClient (interruptibleSession (reviewTurn <> [abortedResult])) $ \fixture -> do
        threadId <- awaitRunningTurn fixture
        sendReviewMessage fixture.claudeReviewClient threadId (Just "turn-1") "focus on the parser"
          `shouldReturn` Right ()
        recorded <- waitForReviewEvents "the interrupt failure" fixture.claudeReviewEvents (not . null . interruptFailures)
        case interruptFailures recorded of
          [(_, _, held)] -> held `shouldBe` Just "focus on the parser"
          other -> expectationFailure ("expected one interrupt failure, got " <> show other)
        written <- awaitRecordedWrites fixture 2
        map classifyWrite written `shouldBe` ["prompt", "interrupt"]

    -- A line that does not parse at all carries no record type, so nothing
    -- says whether it was the acknowledgement. Warned about like any
    -- unreadable line, and then treated as the answer that may have been
    -- lost inside it -- otherwise a truncated control reply strands the
    -- message exactly as a well-formed unusable one would.
    it "hands the message back when the answer arrives as a line it cannot parse" $
      withClaudeReviewClient (interruptibleSession [truncatedAnswer]) $ \fixture -> do
        threadId <- awaitRunningTurn fixture
        sendReviewMessage fixture.claudeReviewClient threadId (Just "turn-1") "focus on the parser"
          `shouldReturn` Right ()
        recorded <- waitForReviewEvents "the interrupt failure" fixture.claudeReviewEvents (not . null . interruptFailures)
        case interruptFailures recorded of
          [(failed, _, held)] -> do
            failed `shouldBe` threadId
            held `shouldBe` Just "focus on the parser"
          other -> expectationFailure ("expected one interrupt failure, got " <> show other)
        -- The turn it failed to end is still running, nothing was written
        -- into it, and the unreadable line was still reported.
        turnCompletions recorded `shouldBe` []
        diagnostics recorded `shouldSatisfy` any (Data.Text.isInfixOf "not JSON")
        written <- awaitRecordedWrites fixture 2
        map classifyWrite written `shouldBe` ["prompt", "interrupt"]
        sendReviewMessage fixture.claudeReviewClient threadId (Just "turn-1") "focus on the parser"
          `shouldReturn` Right ()

    -- The race the acknowledgement cannot settle on its own: an interrupt
    -- written a moment after the turn reached its verdict is still
    -- acknowledged as a success. Releasing the message on that would open a
    -- turn on a review that has already finished, so it is handed back
    -- instead -- and the turn stays the successful one it was.
    it "hands the message back when the turn reached its verdict first" $
      withClaudeReviewClient (interruptibleSession [acknowledgeInterrupt, approvedResult 844]) $ \fixture -> do
        threadId <- awaitRunningTurn fixture
        sendReviewMessage fixture.claudeReviewClient threadId (Just "turn-1") "focus on the parser"
          `shouldReturn` Right ()
        recorded <- waitForReviewEvents "the interrupt failure" fixture.claudeReviewEvents (not . null . interruptFailures)
        map turnOutcomeOf (filter isTurnCompletion recorded) `shouldBe` [Just TurnSucceeded]
        case interruptFailures recorded of
          [(_, _, held)] -> held `shouldBe` Just "focus on the parser"
          other -> expectationFailure ("expected one interrupt failure, got " <> show other)
        written <- awaitRecordedWrites fixture 2
        map classifyWrite written `shouldBe` ["prompt", "interrupt"]

    -- One acknowledgement can only settle one operation, so a second one may
    -- not be started while the first is unresolved. Refused synchronously,
    -- which is what lets the session keep the draft the user is still
    -- looking at rather than restore it from an event later.
    it "refuses a second guidance or cancellation while one interrupt is unresolved" $
      withClaudeReviewClient (interruptibleSession ["true"]) $ \fixture -> do
        threadId <- awaitRunningTurn fixture
        sendReviewMessage fixture.claudeReviewClient threadId (Just "turn-1") "first"
          `shouldReturn` Right ()
        second <- sendReviewMessage fixture.claudeReviewClient threadId (Just "turn-1") "second"
        refusalText second `shouldMention` "already interrupting this turn"
        cancellation <- interruptReview fixture.claudeReviewClient threadId "turn-1"
        refusalText cancellation `shouldMention` "already interrupting this turn"
        -- Only the first one was ever written, and neither refused message
        -- reached the provider.
        written <- awaitRecordedWrites fixture 2
        map classifyWrite written `shouldBe` ["prompt", "interrupt"]

    -- A turn that has already ended cannot be interrupted, and no ending will
    -- ever settle a request aimed at one. Refused before anything is written,
    -- so the caller keeps its message instead of being told later that it was
    -- lost.
    it "refuses to interrupt a turn the thread has already finished" $
      withClaudeReviewClient (reviewTurn <> [approvedResult 844]) $ \fixture -> do
        fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
        recorded <- awaitOneCompletedTurn fixture
        threadId <- soleThread recorded
        stale <- sendReviewMessage fixture.claudeReviewClient threadId (Just "turn-1") "focus on the parser"
        refusalText stale `shouldMention` "already finished that turn"
        length <$> recordedClaudeInput fixture.claudeReviewRecordings 0 `shouldReturn` 1

    -- The acknowledgement that never comes. Nothing else would settle the
    -- handshake, and the message riding on it has already been shown to the
    -- user as sent, so the connection's end is where it has to be handed
    -- back.
    it "hands the message back when the process dies with the interrupt unanswered" $
      withClaudeReviewClient (interruptibleSession ["true"]) $ \fixture -> do
        threadId <- awaitRunningTurn fixture
        sendReviewMessage fixture.claudeReviewClient threadId (Just "turn-1") "focus on the parser"
          `shouldReturn` Right ()
        killConnectionOf fixture threadId
        recorded <- waitForReviewEvents "the interrupt failure" fixture.claudeReviewEvents (not . null . interruptFailures)
        case interruptFailures recorded of
          [(failed, cause, held)] -> do
            failed `shouldBe` threadId
            cause `shouldMention` "Claude stream-json session"
            held `shouldBe` Just "focus on the parser"
          other -> expectationFailure ("expected one interrupt failure, got " <> show other)
        [event | event@ReviewSteerUndelivered {} <- recorded] `shouldBe` []
        -- The order is load-bearing rather than incidental. A session decides
        -- where a handed-back message can go from the phase it is in, and
        -- 'ReviewConnectionStopped' is what settles it, so that event has to
        -- have arrived first; reported before it, this would offer a resend
        -- from a session about to stop accepting one.
        --
        -- Anchored on that event rather than on the whole terminal sequence
        -- because a dying connection reaches two terminal paths and which of
        -- them reports each taken thing is a race. What is not a race is
        -- that whichever path hands the message back emitted its own
        -- connection report first.
        takeWhile (/= "ReviewInterruptFailed") (lifecycle recorded)
          `shouldSatisfy` elem "ReviewConnectionStopped"

  -- The session half of a failed interrupt. 'applyReviewEvent' runs in
  -- brick's 'EventM', which no unit test here can drive, so the transition a
  -- 'ReviewInterruptFailed' causes lives in 'applyFailedInterrupt' and is
  -- covered directly -- the way issue #17's rejected steer is in
  -- "Spec.Agent.Protocol", and reusing that recovery rather than a second one.
  describe "recovering a message a failed interrupt was carrying" $ do
    let guidance = "focus on the parser" :: Text
        cause = "the interrupt was not performed" :: Text
        interruptedSession :: Text -> ReviewSession
        interruptedSession input =
          ( newAgentSession
              0
              ReviewRunning
              "thinking"
              Nothing
              (plainChatTranscript ("\nYou: " <> guidance <> "\n"))
              ReviewDetail
                { reviewSessionIssue = baseIssue 588 [],
                  -- The stage an embedded review runs at, and the only one
                  -- that ever reads typed text: the others run the canonical
                  -- gate as a subprocess and hold no thread for an interrupt
                  -- to fail on.
                  reviewSessionStage = IssueRevision,
                  reviewSessionThreadId = Just (fixtureReviewThread "claude-session-1"),
                  reviewSessionTurnId = Just "turn-1",
                  reviewSessionPending = Nothing,
                  reviewSessionUndelivered = [],
                  reviewSessionAwaiting = [],
                  reviewSessionRestored = Nothing
                }
          )
            {sessionInput = input}
        -- The same session as the connection's end leaves it: settled, and
        -- past the point where its input line takes anything.
        settledSession :: Text -> ReviewSession
        settledSession input = (interruptedSession input) {sessionPhase = ReviewFailed}

    it "restores the message to an input line the user left alone, and says what failed" $ do
      let recovered = applyFailedInterrupt cause (Just guidance) (interruptedSession "")
      recovered.sessionInput `shouldBe` guidance
      recovered.sessionTranscript.standardTranscript `shouldMention` ("[interrupt failed] " <> cause)

    -- The optimistic entry is written the moment the control request goes
    -- out, so a session shown only the failure would go on claiming the
    -- provider read text it never saw.
    it "qualifies the optimistic transcript entry rather than leaving it claiming delivery" $ do
      let recovered = applyFailedInterrupt cause (Just guidance) (interruptedSession "")
      recovered.sessionTranscript.standardTranscript `shouldMention` ("[not delivered] " <> guidance)

    it "queues it behind a draft typed after the send rather than overwriting it" $ do
      let recovered = applyFailedInterrupt cause (Just guidance) (interruptedSession "wait, ignore that")
      recovered.sessionInput `shouldBe` "wait, ignore that"
      recovered.sessionDetail.reviewSessionUndelivered `shouldBe` [guidance]

    -- A cancellation carried nothing, so there is nothing to restore -- but
    -- one that did not happen is exactly what a user watching the turn keep
    -- running needs told.
    it "reports a failed cancellation without inventing a message to put back" $ do
      let recovered = applyFailedInterrupt cause Nothing (interruptedSession "")
      recovered.sessionInput `shouldBe` ""
      recovered.sessionDetail.reviewSessionUndelivered `shouldBe` []
      recovered.sessionTranscript.standardTranscript `shouldMention` ("[interrupt failed] " <> cause)
      recovered.sessionTranscript.standardTranscript `shouldNotMention` "[not delivered]"

    -- The connection died, so the session this arrives at is already settled
    -- and its input line takes no keystrokes and submits nothing
    -- ('reviewSessionInputLive'). Text parked there would look like a draft
    -- and behave like a decoration; the session's own queue is drawn in the
    -- overlay and drains back onto the line the next time one can be sent,
    -- so that is where a message goes when the line cannot honour it.
    it "queues the message rather than parking it on a settled session's dead input line" $ do
      let recovered = applyFailedInterrupt cause (Just guidance) (settledSession "")
      recovered.sessionInput `shouldBe` ""
      recovered.sessionDetail.reviewSessionUndelivered `shouldBe` [guidance]
      recovered.sessionTranscript.standardTranscript `shouldMention` ("[not delivered] " <> guidance)
      recovered.sessionTranscript.standardTranscript `shouldMention` ("[interrupt failed] " <> cause)

    -- The whole sequence a dying connection actually produces, in order and
    -- through the functions that handle it, rather than a session poked into
    -- a phase by hand. The connection report settles the session, the
    -- failure hands the message to the only place a settled session can
    -- keep it, the settled session is then refused as reusable so the next
    -- press starts a review rather than reopening a dead end, and the
    -- session that press creates has the message back on a line it can send
    -- from. Any one of those four links missing loses the message.
    it "carries the message through the connection's end to a fresh review that can send it" $ do
      let opened = interruptedSession ""
          -- The host routes a connection's end only into the children that
          -- connection was serving (SAG-10), so what reaches this session is
          -- already known to be its own.
          settled = markReviewSessionDisconnected "Claude stream-json session exited" opened
      stranded <- pure (applyFailedInterrupt cause (Just guidance) settled)
      stranded.sessionPhase `shouldBe` ReviewFailed
      stranded.sessionDetail.reviewSessionUndelivered `shouldBe` [guidance]
      reviewSessionReusable
        stranded.sessionPhase
        stranded.sessionDetail.reviewSessionStage
        IssueRevision
        False
        (not (null stranded.sessionDetail.reviewSessionUndelivered))
        `shouldBe` False
      -- Built by the constructor the press itself uses, so the last link is
      -- the session `r` really creates rather than one shaped like it.
      let (restarted, _) =
            carryUndelivered (undeliveredForIssue (Just stranded) []) (newReviewSession (baseIssue 588 []) IssueRevision 0)
      restarted.sessionInput `shouldBe` guidance
      restarted.sessionDetail.reviewSessionUndelivered `shouldBe` []
      reviewSessionInputLive restarted.sessionDetail.reviewSessionStage restarted.sessionPhase
        `shouldBe` True

    -- The other sequence that hands a message back, and the one whose
    -- terminal phase is not a failure at all: the turn reached its verdict
    -- while the interrupt was still unconfirmed. The phase is taken from the
    -- rule the event handler itself uses rather than named here, so a change
    -- to what a completed revision settles into cannot leave this asserting
    -- the wrong thing.
    it "carries the message on from a turn that reached its verdict first" $ do
      let settledPhase = reviewOutcomePhase IssueRevision TurnSucceeded (Just (verdictResult 588))
          finished = (interruptedSession "") {sessionPhase = settledPhase}
          stranded = applyFailedInterrupt cause (Just guidance) finished
      -- A verdict, not a failure -- and still a session that can no longer
      -- be sent to.
      settledPhase `shouldNotBe` ReviewFailed
      reviewSessionInputLive IssueRevision settledPhase `shouldBe` False
      stranded.sessionDetail.reviewSessionUndelivered `shouldBe` [guidance]
      reviewSessionReusable
        settledPhase
        IssueRevision
        IssueRevision
        False
        (not (null stranded.sessionDetail.reviewSessionUndelivered))
        `shouldBe` False
      let (restarted, _) =
            carryUndelivered (undeliveredForIssue (Just stranded) []) (newReviewSession (baseIssue 588 []) IssueRevision 0)
      restarted.sessionInput `shouldBe` guidance
      reviewSessionInputLive restarted.sessionDetail.reviewSessionStage restarted.sessionPhase
        `shouldBe` True

    -- The ordering that defeats a queue-only rule. A refused interrupt is
    -- handled while its target still runs, so the message goes back onto a
    -- line that is live at that moment and stays there -- and then the turn
    -- reaches its verdict, settling the session under it. Nothing moved the
    -- text anywhere, so a rule reading only the queue sees an empty one and
    -- reopens a session that can no longer send.
    it "carries a message left on a live line by a turn that then reached its verdict" $ do
      let refused = applyFailedInterrupt cause (Just guidance) (interruptedSession "")
          settledPhase = reviewOutcomePhase IssueRevision TurnSucceeded (Just (verdictResult 588))
          completed = refused {sessionPhase = settledPhase}
      -- It went to the line, not the queue: the session could still send
      -- when the interrupt failed.
      refused.sessionInput `shouldBe` guidance
      refused.sessionDetail.reviewSessionUndelivered `shouldBe` []
      -- And the turn's own completion left it somewhere it cannot.
      reviewSessionInputLive IssueRevision settledPhase `shouldBe` False
      reviewSessionHoldsUnsentText completed `shouldBe` True
      reviewSessionReusable settledPhase IssueRevision IssueRevision False (reviewSessionHoldsUnsentText completed)
        `shouldBe` False
      let (restarted, _) =
            carryUndelivered (undeliveredForIssue (Just completed) []) (newReviewSession (baseIssue 588 []) IssueRevision 0)
      restarted.sessionInput `shouldBe` guidance
      reviewSessionInputLive restarted.sessionDetail.reviewSessionStage restarted.sessionPhase
        `shouldBe` True

    -- The other late ordering: the interrupt succeeded, the turn was cut
    -- short, and the follow-up write failed. That leaves the session
    -- interrupted -- a phase whose line is deliberately live, because an
    -- interrupted revision is resumable. It stops being resumable when its
    -- connection goes, and nothing used to say so.
    it "carries a message left on an interrupted session whose connection then stopped" $ do
      let interrupted = (interruptedSession "") {sessionPhase = ReviewInterrupted}
          held = applyFailedInterrupt cause (Just guidance) interrupted
          settled = markReviewSessionDisconnected "Claude stream-json session exited" held
      -- Live while the thread was merely interrupted, so the message is on
      -- the line ready to resend.
      reviewSessionInputLive IssueRevision ReviewInterrupted `shouldBe` True
      held.sessionInput `shouldBe` guidance
      let stopped = settled
      -- The connection's end is what makes it unresumable, and says so.
      stopped.sessionPhase `shouldBe` ReviewFailed
      reviewSessionReusable
        stopped.sessionPhase
        stopped.sessionDetail.reviewSessionStage
        IssueRevision
        False
        (reviewSessionHoldsUnsentText stopped)
        `shouldBe` False
      let (restarted, _) =
            carryUndelivered (undeliveredForIssue (Just stopped) []) (newReviewSession (baseIssue 588 []) IssueRevision 0)
      restarted.sessionInput `shouldBe` guidance

    -- Where carrying it forward stops. A revision that published its verdict
    -- moves the labels on, so the next `r` asks for the canonical rereview --
    -- a stage that runs the gate as a subprocess and holds no thread. The
    -- stage is derived from the labels that revision publishes rather than
    -- named, so this is the sequence the board actually produces.
    it "holds the message for the issue when the next stage could never send it" $ do
      let stranded = applyFailedInterrupt cause (Just guidance) (settledSession "")
          -- What a published revision leaves on the issue, and what `r` then
          -- asks for.
          nextStage = reviewStageForLabels defaultWorkflowConfig ["reviewed:revised"]
          canonical = newReviewSession (baseIssue 588 []) nextStage 0
          (replacement, owed) = carryUndelivered (undeliveredForIssue (Just stranded) []) canonical
      nextStage `shouldNotBe` IssueRevision
      reviewSessionInputLive nextStage canonical.sessionPhase `shouldBe` False
      -- Not put into a session that could never send it, and not thrown away
      -- with the session it was parked in either.
      replacement.sessionInput `shouldBe` ""
      replacement.sessionDetail.reviewSessionUndelivered `shouldBe` []
      owed `shouldBe` [guidance]
      -- It survives however many canonical stages come and go...
      let (_, stillOwed) = carryUndelivered (undeliveredForIssue (Just replacement) owed) canonical
      stillOwed `shouldBe` [guidance]
      -- ...and the next session that can send is handed it.
      let (revision, nothingLeft) =
            carryUndelivered (undeliveredForIssue Nothing stillOwed) (newReviewSession (baseIssue 588 []) IssueRevision 0)
      revision.sessionInput `shouldBe` guidance
      nothingLeft `shouldBe` []

    -- A draft the user typed after the send is not overwritten by the
    -- message coming across: the line the fresh session opens with is the
    -- one they were last looking at, and the message waits behind it.
    it "keeps the replaced session's own draft ahead of what it never sent" $ do
      let stranded = applyFailedInterrupt cause (Just guidance) (settledSession "wait, ignore that")
          (restarted, _) =
            carryUndelivered (undeliveredForIssue (Just stranded) []) (newReviewSession (baseIssue 588 []) IssueRevision 0)
      restarted.sessionInput `shouldBe` "wait, ignore that"
      restarted.sessionDetail.reviewSessionUndelivered `shouldBe` [guidance]

  -- The handshake's rule on its own, away from any process. Both halves have
  -- to be in and agree before a user's message may be written, and every way
  -- they can fail to agree has to abandon it rather than leave it pending.
  describe "settling one interrupt" $ do
    it "releases the guidance only once the request was accepted and its turn was cut short" $
      map settleInterrupt [waitingOn InterruptAccepted TargetAborted]
        `shouldBe` [Just InterruptDelivered]

    it "keeps waiting while either half is still outstanding" $
      map
        settleInterrupt
        [ waitingOn AcknowledgementPending TargetRunning,
          waitingOn AcknowledgementPending TargetAborted,
          waitingOn InterruptAccepted TargetRunning
        ]
        `shouldBe` [Nothing, Nothing, Nothing]

    -- A refusal performed nothing whatever the turn went on to do, and a turn
    -- that ended on its own was not interrupted however the request was
    -- answered. Both abandon, and each says which it was.
    it "abandons it, saying why, on every disagreement between the two halves" $
      map
        settleInterrupt
        [ waitingOn (InterruptRefused "refused it") TargetRunning,
          waitingOn (InterruptRefused "refused it") TargetAborted,
          waitingOn (InterruptRefused "refused it") TargetSettled,
          waitingOn AcknowledgementPending TargetSettled,
          waitingOn InterruptAccepted TargetSettled
        ]
        `shouldSatisfy` all abandonedWithReason

  describe "the CLI stream-json decoder" $ do
    it "opens a turn on the session and turn a system init record names" $
      decodeStreamRecord "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s-1\",\"uuid\":\"t-1\"}"
        `shouldBe` Right (StreamTurnOpened "s-1" "t-1")

    -- The records the launch still emits, and the aggregate that would
    -- otherwise duplicate the transcript. Recognised and ignored rather than
    -- warned about, so a CLI release adding a record type does not fill the
    -- review panel with warnings.
    --
    -- Both halves of a hook's report are here on purpose. Excluding the user,
    -- project, and local settings sources stops the hooks those files declare
    -- and nothing past them, so a `SessionStart` hook can still run in an
    -- embedded review from a source the launch does not reach — and it is
    -- announced twice, once opening and once answering. Neither record may
    -- become a warning in the panel.
    it "ignores every record a review has no use for" $
      map
        decodeStreamRecord
        [ "{\"type\":\"system\",\"subtype\":\"hook_started\",\"hook_name\":\"SessionStart\"}",
          "{\"type\":\"system\",\"subtype\":\"hook_response\",\"hook_name\":\"SessionStart\"}",
          "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\"}",
          "{\"type\":\"system\",\"subtype\":\"thinking_tokens\",\"estimated_tokens\":50}",
          "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"already streamed\"}]}}",
          "{\"type\":\"user\",\"message\":{\"content\":[]}}",
          "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"allowed\"}}",
          "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}",
          "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"signature_delta\",\"signature\":\"AbCd\"}}}",
          "{\"type\":\"something_a_later_cli_adds\"}"
        ]
        `shouldBe` replicate 10 (Right StreamIgnored)

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

    it "writes one control request, in the shape the CLI answers" $
      encodedText (streamInterruptRequest "kanban-interrupt-2")
        `shouldBe` "{\"request\":{\"subtype\":\"interrupt\"},\"request_id\":\"kanban-interrupt-2\",\"type\":\"control_request\"}"

    it "reads the acknowledgement of a control request it performed" $
      decodeStreamRecord
        "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"kanban-interrupt-2\",\"response\":{\"still_queued\":[]}}}"
        `shouldBe` Right (StreamControlAnswered "kanban-interrupt-2" (Right ()))

    -- Fails closed on everything that is not agreement, quoting what the CLI
    -- said where it said anything. An answer read as agreement is what would
    -- release a user's message into a turn that is still running.
    it "reads every other answer to a control request as a refusal that says why" $
      map
        decodeStreamRecord
        [ "{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\",\"request_id\":\"r-1\",\"error\":\"Unsupported control request subtype: interrupt\"}}",
          "{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\",\"request_id\":\"r-1\"}}",
          "{\"type\":\"control_response\",\"response\":{\"subtype\":\"a_later_cli_adds_one\",\"request_id\":\"r-1\"}}",
          "{\"type\":\"control_response\",\"response\":{\"request_id\":\"r-1\"}}"
        ]
        `shouldSatisfy` all refusalNamingItsRequest

    -- Reported rather than refused, unlike every other line this decoder
    -- cannot read. An operation is waiting on an answer to a control
    -- request, and a line saying only that one arrived and could not be read
    -- is the last thing that will be said about it -- so a warning alone
    -- would leave the operation waiting for something that has already been
    -- and gone. The detail still names no provider, because this decoder
    -- knows the channel and not who is speaking it.
    it "reports an answer it cannot attach to a request, rather than only refusing it" $
      map
        decodeStreamRecord
        [ "{\"type\":\"control_response\"}",
          "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\"}}"
        ]
        `shouldSatisfy` all unreadableNamingNoProvider

    -- A cut-short turn reports an error subtype and @is_error@ exactly as a
    -- broken one does; only @terminal_reason@ separates them, so a decoder
    -- reading the subtype first would call every interrupted turn a failure.
    it "tells a turn that was cut short from one that broke" $
      map
        decodeStreamRecord
        [ "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"stop_reason\":null,\"terminal_reason\":\"aborted_streaming\"}",
          "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"terminal_reason\":\"completed\",\"result\":\"it broke\"}"
        ]
        `shouldBe` [ Right (StreamTurnClosed StreamTurnAborted),
                     Right (StreamTurnClosed (StreamTurnFailure "ended its turn with an error: it broke"))
                   ]

-- | One realistic turn's worth of stream, minus the result line each test
-- supplies for itself.
reviewTurn :: [ByteString.ByteString]
reviewTurn = claudeReviewTurn "weighing it" "reviewing it"

-- | A session whose first turn opens and then stays open, so a test can type
-- into a turn that is genuinely still running.
--
-- Three branches, told apart by the line the fake was handed rather than by
-- how many it has read, because the whole point is that they do not arrive in
-- a fixed order. A control request is answered with @answer@ -- which is
-- where each test puts the acknowledgement, the result of the turn it ends,
-- or neither, in whichever order it is about. The opening review prompt opens
-- a turn and writes no result, leaving it running. Anything else is the
-- follow-up turn, and completes with a verdict.
interruptibleSession :: [ByteString.ByteString] -> [ByteString.ByteString]
interruptibleSession answer =
  ["case \"$message\" in", "  *control_request*)"]
    <> answer
    <> ["    ;;", "  *'#844'*)"]
    <> reviewTurn
    <> ["    ;;", "  *)"]
    <> reviewTurn
    <> [approvedResult 844, "    ;;", "esac"]

-- | The @request_id@ the control request named, read back out of the line the
-- fake was handed.
--
-- Echoed rather than invented, so a client that answered an acknowledgement
-- naming somebody else's request would be caught: the id travels from
-- Kanban's own counter, through the provider, and back.
readRequestId :: ByteString.ByteString
readRequestId = "request=$(printf '%s' \"$message\" | sed 's/.*\"request_id\":\"\\([^\"]*\\)\".*/\\1/')"

-- | The CLI's acknowledgement of an interrupt it performed, in the shape a
-- live 2.1.257 wrote it.
acknowledgeInterrupt :: ByteString.ByteString
acknowledgeInterrupt =
  ByteString.intercalate
    "\n"
    [ readRequestId,
      "printf '{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"%s\",\"response\":{\"still_queued\":[]}}}\\n' \"$request\""
    ]

-- | The CLI's answer to a control request it would not perform.
refuseInterrupt :: ByteString.ByteString -> ByteString.ByteString
refuseInterrupt detail =
  ByteString.intercalate
    "\n"
    [ readRequestId,
      "printf '{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\",\"request_id\":\"%s\",\"error\":\"" <> detail <> "\"}}\\n' \"$request\""
    ]

-- | An answer to a control request that names no request, which is the shape
-- of one this backend cannot attach to the operation waiting on it.
unreadableAnswer :: ByteString.ByteString
unreadableAnswer = rawResult "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\"}}"

-- | A control answer cut off mid-line, which is what a reply lost to a
-- broken write looks like: it parses as nothing at all, so not even its
-- record type survives to say what it was.
truncatedAnswer :: ByteString.ByteString
truncatedAnswer = rawResult "{\"type\":\"control_response\",\"response\":{\"subtype\":\"suc"

-- | An answer naming a request this client never sent, which on a channel
-- carrying one interrupt and no other control operation confirms nothing.
mismatchedAnswer :: ByteString.ByteString
mismatchedAnswer =
  rawResult
    "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"kanban-interrupt-9999\",\"response\":{\"still_queued\":[]}}}"

-- | The result line closing a turn that was cut short rather than ending on
-- its own: an error subtype and @is_error@ like any broken turn, told apart
-- from one only by @terminal_reason@.
abortedResult :: ByteString.ByteString
abortedResult =
  rawResult
    "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"stop_reason\":null,\"terminal_reason\":\"aborted_streaming\"}"

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
    fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
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

-- | Start review 844 and wait until its first turn is running, which is the
-- state every mid-turn test begins from.
awaitRunningTurn :: ClaudeReviewFixture -> IO ReviewThreadId
awaitRunningTurn fixture = do
  fmap (() <$) (beginIssueReview fixture.claudeReviewClient 844) `shouldReturn` Right ()
  recorded <- waitForReviewEvents "a running turn" fixture.claudeReviewEvents (not . null . turnStarts)
  soleThread recorded

-- | Type @message@ into a running turn and wait for the turn it becomes to
-- reach its verdict.
guidanceRoundTrip :: ClaudeReviewFixture -> Text -> IO [ReviewEvent]
guidanceRoundTrip fixture message = do
  threadId <- awaitRunningTurn fixture
  sendReviewMessage fixture.claudeReviewClient threadId (Just "turn-1") message `shouldReturn` Right ()
  waitForReviewEvents
    "the turn the guidance opened"
    fixture.claudeReviewEvents
    (any ((== Just TurnSucceeded) . turnOutcomeOf))

-- | The lines the fake read from its stdin, once there are at least @wanted@
-- of them. A write is made by one process and recorded by another, so a
-- count read too early says nothing.
awaitRecordedWrites :: ClaudeReviewFixture -> Int -> IO [Text]
awaitRecordedWrites fixture wanted = go (400 :: Int)
  where
    go remaining = do
      written <- recordedClaudeInput fixture.claudeReviewRecordings 0
      if length written >= wanted
        then pure written
        else
          if remaining <= 0
            then fail ("timed out waiting for " <> show wanted <> " writes; recorded " <> show written)
            else threadDelay 25000 >> go (remaining - 1)

-- | What one line Kanban wrote to the provider is, named rather than
-- compared: an interrupt, the review prompt that opens a session, or a
-- message the user typed, quoted so the assertion says which one.
classifyWrite :: Text -> String
classifyWrite written
  | "\"control_request\"" `Data.Text.isInfixOf` written = "interrupt"
  | "#844" `Data.Text.isInfixOf` spoken = "prompt"
  | otherwise = "guidance: " <> Data.Text.unpack spoken
  where
    spoken = userMessageText written

isTurnCompletion :: ReviewEvent -> Bool
isTurnCompletion ReviewTurnCompleted {} = True
isTurnCompletion _ = False

-- | Every interrupt this backend could not complete, as the thread it was on,
-- what went wrong, and the guidance it handed back.
interruptFailures :: [ReviewEvent] -> [(ReviewThreadId, Text, Maybe Text)]
interruptFailures recorded =
  [(threadId, cause, message) | ReviewInterruptFailed threadId cause message <- recorded]

-- | One interrupt carrying a message, with its two halves in a stated state.
waitingOn :: InterruptAcknowledgement -> InterruptTarget -> PendingInterrupt
waitingOn acknowledgement target =
  (pendingInterrupt "kanban-interrupt-2" "turn-1" (Just "focus on the parser"))
    { interruptAcknowledgement = acknowledgement,
      interruptTarget = target
    }

-- | Whether one decoded line is an answer that could not be attached to a
-- request, saying why without naming a provider.
unreadableNamingNoProvider :: Either Text StreamRecord -> Bool
unreadableNamingNoProvider (Right (StreamControlUnreadable detail)) =
  not (Data.Text.null detail) && not (mentionsAProvider detail)
unreadableNamingNoProvider _ = False

-- | Whether one decoded line is an answer that named its request and refused
-- it, saying something about why.
refusalNamingItsRequest :: Either Text StreamRecord -> Bool
refusalNamingItsRequest (Right (StreamControlAnswered "r-1" (Left detail))) = not (Data.Text.null detail)
refusalNamingItsRequest _ = False

abandonedWithReason :: Maybe InterruptSettlement -> Bool
abandonedWithReason (Just (InterruptAbandoned cause)) = not (Data.Text.null cause)
abandonedWithReason _ = False

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
    name ReviewConnectionStopped {} = "ReviewConnectionStopped"
    name ReviewInterruptFailed {} = "ReviewInterruptFailed"
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

refusalText :: Either Text value -> Text
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

-- | The value following @flag@ in a recorded argv.
argumentAfter :: Text -> [Text] -> Maybe Text
argumentAfter flag arguments = case dropWhile (/= flag) arguments of
  _ : value : _ -> Just value
  _ -> Nothing

-- | The endpoint directory a recorded @--mcp-config@ value proxies over.
mcpEndpointOf :: Text -> Maybe Text
mcpEndpointOf configText = do
  value <- decodeObject configText
  arguments <- objectField "mcpServers" value >>= objectField "kanban" >>= objectField "args"
  case arguments of
    Array items -> case foldMap pure items of
      [_, String endpoint] -> Just endpoint
      _ -> Nothing
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

-- | The mirror image: a valid roster loading only Claude, which is the
-- install issue #589 routes its embedded review to this backend.
claudeOnlyRoster :: ModelRoster
claudeOnlyRoster = defaultRoster {rosterAgents = [ClaudeProvider]}
