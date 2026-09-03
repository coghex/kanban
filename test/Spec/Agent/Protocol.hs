-- | The wire protocols the agent layer speaks: the Codex app-server exchange,
-- its recovery paths, the stream reader, and how a finished handoff is
-- classified.
module Spec.Agent.Protocol (spec) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (throwTo)
import Control.Monad (void)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.ByteString.Char8 as ByteString
import Data.IORef (modifyIORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text
import qualified Data.Text.Encoding as TextEncoding
import Kanban.Domain
import Kanban.Models (ProviderName (..))
import Kanban.Process (killManagedProcess, managedProcessPid)
import Kanban.PullRequestFlow (flowOutcome)
import Kanban.Review
  ( CanonicalIssueReviewResult (..),
    GitHubIssueOperation (..),
    GitHubIssueToolRequest (..),
    ReviewAnswer (..),
    ReviewChoice (..),
    ReviewConnection (..),
    ReviewEvent (..),
    ReviewOutputKind (..),
    ReviewProcessShape (..),
    ReviewQuestion (..),
    ReviewQuestionKind (..),
    ReviewResult (..),
    ReviewStage (..),
    ReviewTurnOutcome (..),
    ReviewWireMessage (..),
    answerReviewQuestion,
    approveReviewAction,
    beginIssueReview,
    reviewConnectionsForTesting,
    reviewThreadOwnProcesses,
    reviewThreadOwnProcesses,
    stopReviewClient,
    decodeCanonicalIssueReviewResult,
    decodeClaudeToolPrompt,
    decodeGitHubIssueToolRequest,
    decodeReviewQuestion,
    decodeReviewResult,
    decodeReviewWireMessage,
    canonicalIssueReviewArguments,
    canonicalIssueReviewerPath,
    issueReviewerRecordPath,
    githubIssueCommentArguments,
    githubIssueEditArguments,
    githubIssueViewArguments,
    githubLabelCreateArguments,
    handleWireMessage,
    resolveCanonicalIssueReviewer,
    reviewStageForLabels,
    sendReviewMessage,
    renderCanonicalIssueReviewResult,
    renderReviewResult
  )
import Kanban.Solve (SolveOutcome (..), solveOutcome)
import Kanban.StreamReader
  ( StreamOutcome (..),
    handleReadLine,
    maxConsecutiveReadFailures,
    onStreamAbandoned,
    runStreamReader,
    runStreamReaderWith
  )
import Kanban.UI.Overlay (drawUndeliveredSteers)
import Kanban.UI.Review (applyUndeliveredSteer)
import Kanban.UI.Theme (themeFor)
import Kanban.UI.SessionCore (newAgentSession)
import Kanban.UI.Types (AgentSession (..), ChatTranscript (..), ReviewDetail (..), ReviewPhase (..), ReviewSession)
import Spec.Support.Env
  ( createTemporaryDirectory,
    withEnvironmentValue,
    withManagedRecordHome,
    withTemporaryCacheRoot,
  )
import Spec.Support.Expect (isRight, shouldMention, shouldNotMention)
import Spec.Support.Fixtures (baseIssue, fixtureReviewThread, testOptions)
import Spec.Support.Process
  ( encodedValue,
    fakeProviderDiagnostic,
    reviewOutputs,
    waitForReviewEvents,
    expectNoFurtherClientRequests,
    managedProcessFor,
    nextClientRequest,
    nextClientLine,
    plainChatTranscript,
    protocolWarnings,
    readRecordedPids,
    shouldHaveBeenSwept,
    soleReviewConnection,
    startFailures,
    threadOn,
    turnCompletions,
    twoConnectionsOf,
    waitForConnectionStops,
    waitForHeldConnections,
    withFakeReviewClient,
    withTwoConnectionReviewClient,
    TwoConnectionClient (..),
    undeliveredSteers,
    withManagedShell,
    withRecordingReviewClient
  )
import Spec.Support.Render (renderWidgetLines)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (hClose)
import System.Process
  ( CreateProcess (..),
    StdStream (CreatePipe),
    createProcess,
    proc,
    waitForProcess
  )
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = do
  describe "Codex app-server protocol" $ do
    it "decodes streamed notifications without scraping their payload" $ do
      let payload = "{\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"thread-1\",\"delta\":\"hello\"}}"
      decodeReviewWireMessage payload
        `shouldBe` Right
          ( WireNotification
              "item/agentMessage/delta"
              (object ["threadId" .= ("thread-1" :: Text), "delta" .= ("hello" :: Text)])
          )

    it "distinguishes server requests that require a client response" $ do
      let payload = "{\"id\":41,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"kanban_prompt_user\"}}"
      decodeReviewWireMessage payload
        `shouldBe` Right
          ( WireRequest
              (Number 41)
              "item/tool/call"
              (object ["tool" .= ("kanban_prompt_user" :: Text)])
          )

    it "validates structured multiple-choice questions" $ do
      let payload =
            "{\"id\":\"scope\",\"header\":\"SCOPE\",\"question\":\"Which contract?\",\"kind\":\"choice\",\"options\":[{\"id\":\"keep\",\"label\":\"Keep compatibility\",\"description\":\"Preserve callers\"},{\"id\":\"break\",\"label\":\"Break compatibility\"}]}"
      decodeReviewQuestion payload
        `shouldBe` Right
          ReviewQuestion
            { reviewQuestionId = "scope",
              reviewQuestionHeader = "SCOPE",
              reviewQuestionText = "Which contract?",
              reviewQuestionKind = QuestionChoice,
              reviewQuestionChoices =
                [ ReviewChoice "keep" "Keep compatibility" "Preserve callers",
                  ReviewChoice "break" "Break compatibility" ""
                ],
              reviewQuestionAllowOther = False,
              reviewQuestionMultiple = False
            }

    it "rejects a choice question with fewer than two options" $ do
      let payload = "{\"id\":\"scope\",\"question\":\"Which contract?\",\"kind\":\"choice\",\"options\":[{\"id\":\"keep\",\"label\":\"Keep\"}]}"
      decodeReviewQuestion payload `shouldBe` Left "Choice questions must provide at least two options"

    it "decodes and presents the final structured result as readable review metadata" $ do
      let payload =
            "{\"issue\":844,\"stage\":\"review\",\"approved\":false,\"reviewerRoute\":\"codex-origin → Opus 5\",\"models\":[\"Opus 5 xhigh\"],\"commentUrl\":\"https://example.test/issues/844#issuecomment-1\",\"blockingReasons\":[\"Clarify the save-version migration.\",\"Name the regression probe.\"]}"
          expected =
            ReviewResult
              { reviewResultIssue = 844,
                reviewResultStage = InitialReview,
                reviewResultApproved = False,
                reviewResultReviewerRoute = "codex-origin → Opus 5",
                reviewResultModels = ["Opus 5 xhigh"],
                reviewResultCommentUrl = Just "https://example.test/issues/844#issuecomment-1",
                reviewResultBlockingReasons = ["Clarify the save-version migration.", "Name the regression probe."]
              }
      decodeReviewResult payload `shouldBe` Right expected
      renderReviewResult expected
        `shouldBe` Data.Text.unlines
          [ "Review result",
            "  Outcome: CHANGES REQUESTED",
            "  Reviewer route: codex-origin → Opus 5",
            "  Models: Opus 5 xhigh",
            "  Comment: https://example.test/issues/844#issuecomment-1",
            "  Blocking reasons:",
            "    • Clarify the save-version migration.",
            "    • Name the regression probe."
          ]

    it "selects revision and rereview stages from durable workflow labels" $ do
      reviewStageForLabels defaultWorkflowConfig [] `shouldBe` InitialReview
      reviewStageForLabels defaultWorkflowConfig ["reviewed:changes"] `shouldBe` IssueRevision
      reviewStageForLabels defaultWorkflowConfig ["REVIEWED:REVISED", "reviewed:changes"] `shouldBe` IssueRereview

    it "selects the revision stage from a configured changes-requested label" $
      reviewStageForLabels (defaultWorkflowConfig {changesRequestedLabel = "needs-work"}) ["needs-work"] `shouldBe` IssueRevision

    it "formats the canonical v2 gate without exposing raw JSON" $ do
      let payload =
            "{\"approved\":false,\"issue\":844,\"origin\":\"codex\",\"required_reviewers\":\"claude\",\"required_models\":\"claude-opus-5@xhigh\",\"reasons\":[\"latest current review verdict is CHANGES_REQUESTED\"]}"
          expected =
            CanonicalIssueReviewResult
              { canonicalReviewApproved = False,
                canonicalReviewIssue = 844,
                canonicalReviewOrigin = "codex",
                canonicalReviewRequiredReviewers = Just "claude",
                canonicalReviewRequiredModels = Just "claude-opus-5@xhigh",
                canonicalReviewReasons = ["latest current review verdict is CHANGES_REQUESTED"]
              }
      decodeCanonicalIssueReviewResult payload `shouldBe` Right expected
      renderCanonicalIssueReviewResult InitialReview expected
        `shouldBe` Data.Text.unlines
          [ "Review result",
            "  Outcome: CHANGES REQUESTED",
            "  Origin: codex",
            "  Reviewer route: claude",
            "  Models: claude-opus-5@xhigh",
            "  Blocking reasons:",
            "    • latest current review verdict is CHANGES_REQUESTED"
          ]

    it "passes an explicit --repo, matching Kanban's own resolved repository, to the canonical issue reviewer" $ do
      let repository = Repository "/tmp/repo" "coghex" "kanban"
          arguments = canonicalIssueReviewArguments "/opt/approve_issues.py" repository 844 InitialReview Nothing
      arguments `shouldContain` ["--repo", "coghex/kanban"]
      arguments `shouldContain` ["--path", "/tmp/repo"]

    it "resolves a --repo override the same way regardless of the checkout's own remote, mirroring a fork checkout" $ do
      -- The dashboard's own --repo option can point at a different
      -- repository than the checkout's configured remote (e.g. reviewing
      -- upstream from a fork checkout); the canonical reviewer must be told
      -- the same explicit identity Kanban resolved, not left to re-derive
      -- one from the remote itself.
      let forkCheckout = Repository "/tmp/fork" "upstream-owner" "upstream-repo"
          arguments = canonicalIssueReviewArguments "/opt/approve_issues.py" forkCheckout 844 IssueRereview (Just "/tmp/custom.toml")
      arguments `shouldContain` ["--repo", "upstream-owner/upstream-repo"]
      arguments `shouldContain` ["--rereview", "844"]
      arguments `shouldContain` ["--config", "/tmp/custom.toml"]

    it "composes the backend path from an install directory rather than an embedded separator" $ do
      canonicalIssueReviewerPath "/opt/kanban-review" `shouldBe` "/opt/kanban-review/approve_issues.py"
      -- A trailing separator on the install directory must not double up.
      canonicalIssueReviewerPath "/opt/kanban-review/" `shouldBe` "/opt/kanban-review/approve_issues.py"

    it "looks for the install record where the installer fixes it, not where --install-dir moved" $
      withTemporaryCacheRoot $ \home -> do
        -- Stated rather than inherited: the `~/Library` location is the
        -- occupied one, which is the answer on macOS and on Linux alike, so
        -- what this asserts about is the override and not the host. Which
        -- location an empty host answers with is "Spec.ManagedPaths"'s.
        let recordPath = home <> "/Library/Application Support/kanban/issue-review/config.json"
        createDirectoryIfMissing True (takeDirectory recordPath)
        ByteString.writeFile recordPath "{}"
        withManagedRecordHome home $
          withEnvironmentValue "KANBAN_ISSUE_REVIEW_INSTALL_DIR" (home </> "elsewhere") $ do
            resolved <- issueReviewerRecordPath
            resolved `shouldBe` recordPath
            Data.Text.pack resolved `shouldNotMention` "/work/approve-issues.py"

    -- The environment-driven entry point, end to end: with the override set
    -- it never reads the real record, so this stays hermetic while still
    -- covering the wiring the parameterised cases below bypass.
    it "resolves the bundled canonical issue reviewer from its Kanban-managed install directory" $ do
      temporaryRoot <- createTemporaryDirectory
      let installDir = temporaryRoot </> "issue-review"
          scriptPath = canonicalIssueReviewerPath installDir
      withEnvironmentValue "KANBAN_ISSUE_REVIEW_INSTALL_DIR" installDir $ do
        missing <- resolveCanonicalIssueReviewer
        case missing of
          Left message -> do
            message `shouldSatisfy` Data.Text.isInfixOf "was not found at"
            message `shouldSatisfy` Data.Text.isInfixOf "tools/install_issue_review.py"
          Right found -> expectationFailure ("expected a missing-backend diagnostic, got " <> found)
        createDirectoryIfMissing True installDir
        writeFile scriptPath "#!/usr/bin/env python3\n"
        resolveCanonicalIssueReviewer `shouldReturn` Right scriptPath

    it "validates standalone prompts for the authenticated Claude client tool" $ do
      decodeClaudeToolPrompt (object ["prompt" .= ("Review issue #844" :: Text)])
        `shouldBe` Right "Review issue #844"
      decodeClaudeToolPrompt (object ["prompt" .= ("   " :: Text)])
        `shouldBe` Left "kanban_run_claude requires a non-empty prompt"

    it "bounds authenticated GitHub updates to issue comments and review labels" $ do
      let request =
            object
              [ "operation" .= ("update" :: Text),
                "issue" .= (844 :: Int),
                "comment" .= ("## Review result\nApproved." :: Text),
                "addLabels" .= (["reviewed:approve"] :: [Text]),
                "removeLabels" .= (["reviewed:changes", "reviewed:revised"] :: [Text])
              ]
      decodeGitHubIssueToolRequest defaultWorkflowConfig request
        `shouldBe` Right
          GitHubIssueToolRequest
            { githubToolOperation = GitHubIssueUpdate,
              githubToolIssue = 844,
              githubToolComment = Just "## Review result\nApproved.",
              githubToolAddLabels = ["reviewed:approve"],
              githubToolRemoveLabels = ["reviewed:changes", "reviewed:revised"]
            }
      decodeGitHubIssueToolRequest defaultWorkflowConfig (object ["operation" .= ("update" :: Text), "issue" .= (844 :: Int), "addLabels" .= (["bug"] :: [Text])])
        `shouldBe` Left "kanban_github_issue may only change reviewed:approve, reviewed:changes, and reviewed:revised"
      decodeGitHubIssueToolRequest
        (defaultWorkflowConfig {approvalLabel = "lgtm", changesRequestedLabel = "needs-work"})
        (object ["operation" .= ("update" :: Text), "issue" .= (844 :: Int), "addLabels" .= (["lgtm"] :: [Text])])
        `shouldSatisfy` isRight

    it "passes an explicit --repo, matching Kanban's own resolved repository, to every embedded GitHub tool command" $ do
      let repo = "upstream-owner/upstream-repo"
          request =
            GitHubIssueToolRequest
              { githubToolOperation = GitHubIssueUpdate,
                githubToolIssue = 844,
                githubToolComment = Just "## Review result\nApproved.",
                githubToolAddLabels = ["reviewed:approve"],
                githubToolRemoveLabels = ["reviewed:changes", "reviewed:revised"]
              }
      githubIssueViewArguments repo 844 `shouldContain` ["--repo", "upstream-owner/upstream-repo"]
      githubIssueCommentArguments repo 844 `shouldContain` ["--repo", "upstream-owner/upstream-repo"]
      githubLabelCreateArguments repo `shouldContain` ["--repo", "upstream-owner/upstream-repo"]
      githubIssueEditArguments repo request `shouldContain` ["--repo", "upstream-owner/upstream-repo"]

  -- issue #17: a rejected turn/steer used to land in 'handleResponse''s
  -- catch-all arm as a generic protocol warning, so the feedback the user
  -- typed was neither retried, restored, nor flagged -- it vanished while the
  -- transcript still showed it as sent. These drive real responses through
  -- 'handleWireMessage' against a client whose app-server stdin is a readable
  -- pipe, so both halves of the contract are observed directly: what goes
  -- back out on the wire, and what the session is told.
  describe "rejected turn/steer recovery" $ do
    let steerThread = "thread-1" :: Text
        targetTurn = "turn-1" :: Text
        newerTurn = "turn-2" :: Text
        steerMessage = "actually, check the drainer path too" :: Text
        turnStarted turnId =
          WireNotification
            "turn/started"
            (object ["threadId" .= steerThread, "turn" .= object ["id" .= turnId]])
        turnCompleted =
          WireNotification
            "turn/completed"
            (object ["threadId" .= steerThread, "turn" .= object ["status" .= ("completed" :: Text)]])
        -- The app-server's own rejection when 'expectedTurnId' no longer
        -- names the running turn. The steer is the first request this client
        -- sends, so it carries id 2 (the testing client's counter starts at
        -- 2, matching the real one after 'initialize').
        steerRejected =
          WireResponse (Number 2) (Left (object ["message" .= ("expected turn is not active" :: Text)]))
        steerAccepted = WireResponse (Number 2) (Right (object []))
        -- The whole exchange runs on one connection, which is what a
        -- message is now addressed by: 'steerThread' is the provider's own
        -- id, and the identity the client keys its state on is that id
        -- paired with the connection it arrived on.
        withSteerConnection action =
          withRecordingReviewClient $ \client wire events -> do
            connection <- soleReviewConnection client
            let deliver = handleWireMessage client connection
                sendSteer = do
                  sent <- sendReviewMessage client (threadOn connection steerThread) (Just targetTurn) steerMessage
                  sent `shouldBe` Right ()
            action connection deliver sendSteer wire events

    it "resends the message as a new turn/start when the turn it aimed at has already completed" $
      withSteerConnection $ \_ deliver sendSteer wire events -> do
        deliver (turnStarted targetTurn)
        sendSteer
        (steerMethod, steerParams) <- nextClientRequest wire
        steerMethod `shouldBe` "turn/steer"
        encodedValue steerParams `shouldMention` ("\"expectedTurnId\":\"" <> targetTurn <> "\"")
        -- The race the issue describes: the targeted turn finishes in the
        -- instant between Enter and the request arriving.
        deliver turnCompleted
        deliver steerRejected
        (retryMethod, retryParams) <- nextClientRequest wire
        retryMethod `shouldBe` "turn/start"
        encodedValue retryParams `shouldMention` ("\"text\":\"" <> steerMessage <> "\"")
        -- Exactly one follow-up, and nothing reported to the session: the
        -- optimistic "You:" entry it already holds stayed accurate, so a
        -- second entry would duplicate it.
        expectNoFurtherClientRequests wire
        recorded <- readIORef events
        undeliveredSteers recorded `shouldBe` []
        protocolWarnings recorded `shouldBe` []

    it "hands the message back undelivered, sending nothing, when a newer turn is already running" $
      withSteerConnection $ \connection deliver sendSteer wire events -> do
        deliver (turnStarted targetTurn)
        sendSteer
        void (nextClientRequest wire)
        deliver turnCompleted
        deliver (turnStarted newerTurn)
        deliver steerRejected
        -- Silently applying the guidance to a turn the user never aimed at
        -- is exactly the misdirection the rejection is warning about.
        expectNoFurtherClientRequests wire
        recorded <- readIORef events
        undeliveredSteers recorded `shouldBe` [ReviewSteerUndelivered (threadOn connection steerThread) targetTurn steerMessage]
        protocolWarnings recorded `shouldBe` []

    it "hands the message back undelivered when the targeted turn is still the running one" $
      withSteerConnection $ \connection deliver sendSteer wire events -> do
        deliver (turnStarted targetTurn)
        sendSteer
        void (nextClientRequest wire)
        deliver steerRejected
        expectNoFurtherClientRequests wire
        recorded <- readIORef events
        undeliveredSteers recorded `shouldBe` [ReviewSteerUndelivered (threadOn connection steerThread) targetTurn steerMessage]

    it "leaves an accepted steer alone: no retry and no undelivered state" $
      withSteerConnection $ \_ deliver sendSteer wire events -> do
        deliver (turnStarted targetTurn)
        sendSteer
        void (nextClientRequest wire)
        deliver steerAccepted
        expectNoFurtherClientRequests wire
        recorded <- readIORef events
        undeliveredSteers recorded `shouldBe` []
        protocolWarnings recorded `shouldBe` []

  -- The session half of issue #17. 'applyReviewEvent' runs in brick's
  -- 'EventM', which no unit test here can drive, so the transition a
  -- 'ReviewSteerUndelivered' causes lives in 'applyUndeliveredSteer' and is
  -- covered directly.
  describe "undelivered review message recovery" $ do
    let steerMessage = "actually, check the drainer path too" :: Text
        laterMessage = "and the label cleanup" :: Text
        undeliveredSession :: Text -> [Text] -> ReviewSession
        undeliveredSession input undelivered =
          ( newAgentSession
              0
              ReviewRunning
              "thinking"
              Nothing
              (plainChatTranscript ("\nYou: " <> steerMessage <> "\n"))
              ReviewDetail
                { reviewSessionIssue = baseIssue 17 [],
                  reviewSessionStage = InitialReview,
                  reviewSessionThreadId = Just (fixtureReviewThread "thread-1"),
                  reviewSessionTurnId = Just "turn-2",
                  reviewSessionPending = Nothing,
                  reviewSessionUndelivered = undelivered,
                  reviewSessionRestored = Nothing
                }
          )
            {sessionInput = input}

    it "restores the rejected message to an input line the user left alone" $ do
      let recovered = applyUndeliveredSteer steerMessage (undeliveredSession "" [])
      recovered.sessionInput `shouldBe` steerMessage
      recovered.sessionDetail.reviewSessionUndelivered `shouldBe` []

    it "qualifies the optimistic transcript entry rather than leaving it claiming delivery" $ do
      let recovered = applyUndeliveredSteer steerMessage (undeliveredSession "" [])
      recovered.sessionTranscript.standardTranscript `shouldMention` ("[not delivered] " <> steerMessage)

    it "keeps a draft typed after the send, queueing the rejected message behind it" $ do
      let draft = "wait, ignore that"
          recovered = applyUndeliveredSteer steerMessage (undeliveredSession draft [])
      recovered.sessionInput `shouldBe` draft
      recovered.sessionDetail.reviewSessionUndelivered `shouldBe` [steerMessage]

    it "preserves every independently rejected steer instead of overwriting the first" $ do
      let draft = "wait, ignore that"
          recovered =
            applyUndeliveredSteer laterMessage (applyUndeliveredSteer steerMessage (undeliveredSession draft []))
      recovered.sessionInput `shouldBe` draft
      recovered.sessionDetail.reviewSessionUndelivered `shouldBe` [steerMessage, laterMessage]

    it "returns queued messages oldest first once the input line is free again" $ do
      let recovered = applyUndeliveredSteer laterMessage (undeliveredSession "" [steerMessage])
      recovered.sessionInput `shouldBe` steerMessage
      recovered.sessionDetail.reviewSessionUndelivered `shouldBe` [laterMessage]

    it "shows what is still waiting inside the session overlay, not only in a transient notice" $ do
      let rendered =
            renderWidgetLines
              (themeFor testOptions)
              60
              (drawUndeliveredSteers (undeliveredSession "wait, ignore that" [steerMessage]))
      Data.Text.unlines rendered `shouldMention` "NOT DELIVERED"
      Data.Text.unlines rendered `shouldMention` steerMessage

    it "renders nothing at all when no message is waiting" $
      renderWidgetLines (themeFor testOptions) 60 (drawUndeliveredSteers (undeliveredSession "" []))
        `shouldBe` []

  -- MODEL-14: a review client holds a pool of provider connections rather
  -- than one process. What that has to buy is isolation between them, and
  -- every piece of state a client keys by thread or by request id is a place
  -- two connections could resolve each other's entries: provider thread ids
  -- and JSON-RPC ids are unique only within one connection, and two
  -- connections numbering their own from the same start collide by
  -- construction. These drive the colliding case directly.
  describe "connection isolation within one review client" $ do
    let collidingThread = "thread-1" :: Text
        turnStartedOn :: Text -> ReviewWireMessage
        turnStartedOn turnId =
          WireNotification
            "turn/started"
            (object ["threadId" .= collidingThread, "turn" .= object ["id" .= turnId]])
        turnCompletedOn =
          WireNotification
            "turn/completed"
            (object ["threadId" .= collidingThread, "turn" .= object ["status" .= ("completed" :: Text)]])
        questionRequest :: Int -> ReviewWireMessage
        questionRequest wireId =
          WireRequest
            (Number (fromIntegral wireId))
            "item/tool/call"
            ( object
                [ "tool" .= ("kanban_prompt_user" :: Text),
                  "threadId" .= collidingThread,
                  "arguments"
                    .= object
                      [ "id" .= ("scope" :: Text),
                        "header" .= ("SCOPE" :: Text),
                        "question" .= ("How far?" :: Text),
                        "kind" .= ("text" :: Text)
                      ]
                ]
            )
        githubReadRequest :: Int -> Int -> ReviewWireMessage
        githubReadRequest wireId issueNumber =
          WireRequest
            (Number (fromIntegral wireId))
            "item/tool/call"
            ( object
                [ "tool" .= ("kanban_github_issue" :: Text),
                  "threadId" .= collidingThread,
                  "arguments" .= object ["operation" .= ("read" :: Text), "issue" .= issueNumber]
                ]
            )

    it "gives two connections' identically named threads separate identities" $
      withTwoConnectionReviewClient $ \fixture -> do
        handleWireMessage fixture.twoConnectionClient fixture.firstConnection (turnStartedOn "turn-a")
        handleWireMessage fixture.twoConnectionClient fixture.secondConnection (turnStartedOn "turn-b")
        recorded <- readIORef fixture.twoConnectionEvents
        -- Two threads, because the connection is half of the identity. Keyed
        -- by the provider's id alone these would be one thread that started
        -- twice, and the second start would have replaced the first.
        recorded
          `shouldBe` [ ReviewTurnStarted (threadOn fixture.firstConnection collidingThread) "turn-a",
                       ReviewTurnStarted (threadOn fixture.secondConnection collidingThread) "turn-b"
                     ]
        threadOn fixture.firstConnection collidingThread
          `shouldNotBe` threadOn fixture.secondConnection collidingThread

    it "keeps each connection's active turn separate under a colliding thread id" $
      withTwoConnectionReviewClient $ \fixture -> do
        let client = fixture.twoConnectionClient
        -- Both connections run a turn on their own "thread-1", and the
        -- first's then completes. A steer the first connection rejects is
        -- resent as a new turn precisely because that thread is idle; the
        -- second connection's still-running turn must not make it look busy.
        handleWireMessage client fixture.firstConnection (turnStartedOn "turn-a")
        handleWireMessage client fixture.secondConnection (turnStartedOn "turn-b")
        sendReviewMessage client (threadOn fixture.firstConnection collidingThread) (Just "turn-a") "keep going"
          `shouldReturn` Right ()
        (steerMethod, _) <- nextClientRequest fixture.firstWire
        steerMethod `shouldBe` "turn/steer"
        handleWireMessage client fixture.firstConnection turnCompletedOn
        handleWireMessage client fixture.firstConnection (WireResponse (Number 2) (Left (object ["message" .= ("stale" :: Text)])))
        (retryMethod, _) <- nextClientRequest fixture.firstWire
        retryMethod `shouldBe` "turn/start"
        recorded <- readIORef fixture.twoConnectionEvents
        undeliveredSteers recorded `shouldBe` []
        -- Nothing about that exchange reached the other connection.
        expectNoFurtherClientRequests fixture.secondWire

    it "answers a server request only on the connection that asked it" $
      withTwoConnectionReviewClient $ \fixture -> do
        let client = fixture.twoConnectionClient
        -- The same wire id on both connections, which is what two providers
        -- numbering their own server requests produce.
        handleWireMessage client fixture.firstConnection (questionRequest 90)
        handleWireMessage client fixture.secondConnection (questionRequest 90)
        recorded <- readIORef fixture.twoConnectionEvents
        (firstRequestId, secondRequestId) <- case recorded of
          [ReviewQuestionRequested firstThread firstId _, ReviewQuestionRequested secondThread secondId _] -> do
            firstThread `shouldBe` threadOn fixture.firstConnection collidingThread
            secondThread `shouldBe` threadOn fixture.secondConnection collidingThread
            firstId `shouldNotBe` secondId
            pure (firstId, secondId)
          other -> fail ("expected one question per connection, got " <> show other)
        -- The user answers the second connection's question. Minutes may have
        -- passed by then, so only the connection the request carried says
        -- where the answer goes.
        answerReviewQuestion client secondRequestId (ReviewAnswer [] (Just "as far as it takes"))
          `shouldReturn` Right ()
        answered <- nextClientLine fixture.secondWire
        answered `shouldMention` "as far as it takes"
        expectNoFurtherClientRequests fixture.firstWire
        -- And the first connection's own question is still answerable, on its
        -- own wire, which is what says the routing above chose rather than
        -- simply preferring the last connection to speak.
        approveReviewAction client firstRequestId True False `shouldReturn` Right ()
        approved <- nextClientLine fixture.firstWire
        approved `shouldMention` "\"decision\":\"accept\""
        expectNoFurtherClientRequests fixture.secondWire

    it "authorizes a GitHub tool call against its own connection's thread only" $
      withTwoConnectionReviewClient $ \fixture -> do
        let client = fixture.twoConnectionClient
        -- The first connection's thread is the one that owns issue 844.
        beginIssueReview client 844 `shouldReturn` Right ()
        (threadMethod, _) <- nextClientRequest fixture.firstWire
        threadMethod `shouldBe` "thread/start"
        handleWireMessage
          client
          fixture.firstConnection
          (WireResponse (Number 2) (Right (object ["thread" .= object ["id" .= collidingThread]])))
        (turnMethod, _) <- nextClientRequest fixture.firstWire
        turnMethod `shouldBe` "turn/start"
        -- An empty PATH is what keeps the authorized control below from
        -- spawning anything: 'runGitHubIssueTool' resolves @gh@ before it
        -- runs, so an authorized call is observable by its own distinct
        -- refusal rather than by a real GitHub read.
        withEnvironmentValue "PATH" "/nonexistent-kanban-review-path" $ do
          -- The same provider thread id on the other connection owns nothing.
          handleWireMessage client fixture.secondConnection (githubReadRequest 91 844)
          refused <- nextClientLine fixture.secondWire
          refused `shouldMention` "may only access the issue owned by this review thread"
          -- The control: on the connection that does own it, the identical
          -- call is authorized and fails for an entirely different reason.
          handleWireMessage client fixture.firstConnection (githubReadRequest 92 844)
          authorized <- nextClientLine fixture.firstWire
          authorized `shouldMention` "GitHub CLI was not found on PATH"
          authorized `shouldNotMention` "may only access the issue owned by this review thread"

  -- The process shape a backend declares, driven against a fake provider that
  -- answers the handshake and nothing else. What is under test is how many
  -- processes two reviews occupy, which connection resolves what, and what
  -- shutdown reaps -- none of which the protocol above it can change.
  describe "the connection a review thread runs on" $ do
    it "serves every review from one process when the backend shares one" $
      withFakeReviewClient SharedProcess $ \spawnLog client _ -> do
        beginIssueReview client 844 `shouldReturn` Right ()
        beginIssueReview client 845 `shouldReturn` Right ()
        connections <- reviewConnectionsForTesting client
        length connections `shouldBe` 1
        pids <- readRecordedPids spawnLog
        length pids `shouldBe` 1
        stopReviewClient client
        map (.connectionId) <$> reviewConnectionsForTesting client `shouldReturn` []

    it "gives each review its own process when the backend does not share one" $
      withFakeReviewClient ProcessPerThread $ \spawnLog client _ -> do
        -- Nothing is spawned until a review needs a thread.
        map (.connectionId) <$> reviewConnectionsForTesting client `shouldReturn` []
        beginIssueReview client 844 `shouldReturn` Right ()
        beginIssueReview client 845 `shouldReturn` Right ()
        connections <- reviewConnectionsForTesting client
        length connections `shouldBe` 2
        pids <- readRecordedPids spawnLog
        length pids `shouldBe` 2
        stopReviewClient client
        -- Requirement 4: shutdown stopped every connection and waited for
        -- every loop they started, which is what makes the pool empty here
        -- rather than merely emptying soon, and left no provider process.
        map (.connectionId) <$> reviewConnectionsForTesting client `shouldReturn` []
        mapM_ (\pid -> shouldHaveBeenSwept pid "a per-thread review connection") pids

    -- Round 12's blocker, at the point the rule lives. A per-thread
    -- connection is that thread's own process, so the action owning the
    -- thread records it on its own durable state and can end it with no host
    -- left to ask. A shared one is every thread's, and recording it against
    -- one action would let that action's termination kill all of them.
    it "names the process serving a thread only where the thread owns it" $ do
      withFakeReviewClient ProcessPerThread $ \_ client _ -> do
        beginIssueReview client 844 `shouldReturn` Right ()
        connections <- reviewConnectionsForTesting client
        case connections of
          [connection] -> do
            owned <- reviewThreadOwnProcesses client (threadOn connection "thread-1")
            expected <- managedProcessPid connection.connectionManaged
            mapM managedProcessPid owned `shouldReturn` [expected]
          _ -> expectationFailure "expected exactly one per-thread connection"
        stopReviewClient client
      withFakeReviewClient SharedProcess $ \_ client _ -> do
        beginIssueReview client 844 `shouldReturn` Right ()
        connections <- reviewConnectionsForTesting client
        case connections of
          [connection] -> do
            owned <- reviewThreadOwnProcesses client (threadOn connection "thread-1")
            mapM managedProcessPid owned `shouldReturn` []
          _ -> expectationFailure "expected exactly one shared connection"
        stopReviewClient client

    it "resolves a response only against the connection it arrived on" $
      withFakeReviewClient ProcessPerThread $ \_ client events -> do
        beginIssueReview client 844 `shouldReturn` Right ()
        beginIssueReview client 845 `shouldReturn` Right ()
        (firstConnection, secondConnection) <- twoConnectionsOf client
        -- Each connection numbered its own thread/start 2, so an id says
        -- nothing on its own about which review a response belongs to.
        handleWireMessage
          client
          firstConnection
          (WireResponse (Number 2) (Right (object ["thread" .= object ["id" .= ("thread-1" :: Text)]])))
        -- That created the first review's thread and sent its turn/start as
        -- id 3, pending on the first connection and nowhere else.
        let turnFailure = WireResponse (Number 3) (Left (object ["message" .= ("no such turn" :: Text)]))
        handleWireMessage client secondConnection turnFailure
        wrongConnection <- readIORef events
        turnCompletions wrongConnection `shouldBe` []
        -- The pending entry the wrong connection could not see is untouched,
        -- so the right connection still resolves it, and resolves it once.
        handleWireMessage client firstConnection turnFailure
        handleWireMessage client firstConnection turnFailure
        rightConnection <- readIORef events
        turnCompletions rightConnection
          `shouldBe` [ ReviewTurnCompleted
                         (threadOn firstConnection "thread-1")
                         TurnFailed
                         (Just "{\"message\":\"no such turn\"}")
                         Nothing
                     ]
        stopReviewClient client

    it "fails the review whose thread never arrived when its connection dies first" $
      withFakeReviewClient ProcessPerThread $ \_ client events -> do
        beginIssueReview client 844 `shouldReturn` Right ()
        beginIssueReview client 845 `shouldReturn` Right ()
        (firstConnection, secondConnection) <- twoConnectionsOf client
        -- The second review's thread/start is answered; the first's never is,
        -- which is the state a session sits in between pressing r and the
        -- provider naming its thread.
        handleWireMessage
          client
          secondConnection
          (WireResponse (Number 2) (Right (object ["thread" .= object ["id" .= ("thread-2" :: Text)]])))
        killManagedProcess firstConnection.connectionManaged
        void (waitForConnectionStops events 1)
        recorded <- readIORef events
        -- A session with no thread cannot be reached by a connection-scoped
        -- stop, so without this it would sit at "starting" for good with no
        -- connection behind it. Its issue number is what names it.
        startFailures recorded `shouldSatisfy` any (\(issueNumber, _) -> issueNumber == 844)
        startFailures recorded `shouldSatisfy` all (\(issueNumber, _) -> issueNumber == 844)
        -- Reported once, not once per terminal path the dying connection
        -- reaches.
        length (filter ((== 844) . fst) (startFailures recorded)) `shouldBe` 1
        stopReviewClient client

    it "reports one connection's end against that connection alone, leaving the client usable" $
      withFakeReviewClient ProcessPerThread $ \_ client events -> do
        beginIssueReview client 844 `shouldReturn` Right ()
        beginIssueReview client 845 `shouldReturn` Right ()
        (firstConnection, secondConnection) <- twoConnectionsOf client
        killManagedProcess firstConnection.connectionManaged
        stopped <- waitForConnectionStops events 1
        map fst stopped `shouldSatisfy` all (== firstConnection.connectionId)
        -- The client is not the connection: the survivor is still registered,
        -- and a further review still starts against a backend that would be
        -- reported as failed had the client-wide event been raised instead.
        --
        -- Waited for rather than read: the stop report above can come from
        -- the reader that hits EOF, which runs before the watcher takes the
        -- connection out of the pool.
        surviving <- waitForHeldConnections client 1
        surviving `shouldBe` [secondConnection.connectionId]
        beginIssueReview client 846 `shouldReturn` Right ()
        stopReviewClient client

    -- The negative control for the stream backend's held diagnostics. A
    -- backend that names its threads in its responses rather than in its
    -- stream has nothing for a stderr line to wait on, so holding one would
    -- delay it until the connection ended — which for a review still running
    -- is never. Asserted here, on a per-thread app-server backend, because
    -- that is the shape in which the two properties could be confused with
    -- each other.
    it "reports an app-server's stderr as it arrives, whatever process shape it takes" $
      withFakeReviewClient ProcessPerThread $ \_ client events -> do
        beginIssueReview client 844 `shouldReturn` Right ()
        connection <- soleReviewConnection client
        diagnostics <-
          waitForReviewEvents
            "the provider's stderr"
            events
            (not . null . reviewOutputs)
        reviewOutputs diagnostics
          `shouldBe` [ ( threadOn connection "",
                         DiagnosticOutput CodexProvider,
                         TextEncoding.decodeUtf8 fakeProviderDiagnostic
                       )
                     ]
        stopReviewClient client

  describe "Kanban.StreamReader" $ do
    it "reads every line through to EOF, forwarding each in order and never abandoning" $ do
      cursor <- newIORef (["one", "two", "three"] :: [ByteString.ByteString])
      onLineSeen <- newIORef ([] :: [ByteString.ByteString])
      abandonSeen <- newIORef ([] :: [Text])
      let readLine = do
            queued <- readIORef cursor
            case queued of
              [] -> pure (Right Nothing)
              (line : rest) -> writeIORef cursor rest >> pure (Right (Just line))
      outcome <- runStreamReaderWith readLine "stdout" (\line -> modifyIORef onLineSeen (line :)) (\reason -> modifyIORef abandonSeen (reason :))
      outcome `shouldBe` StreamCompleted
      seenLines <- reverse <$> readIORef onLineSeen
      seenLines `shouldBe` ["one", "two", "three"]
      readIORef abandonSeen `shouldReturn` []

    it "resets its consecutive-failure budget after every successful read, tolerating many isolated failures over a long stream" $ do
      -- Each simulated round fails one short of the bound, then succeeds:
      -- never a run long enough to exhaust it, even though the total
      -- failure count across the whole stream far exceeds the bound.
      let failsBetweenSuccesses = maxConsecutiveReadFailures - 1
          rounds = 12 :: Int
          failure = Left (userError "simulated transient read failure")
          scriptRound n = replicate failsBetweenSuccesses failure <> [Right (Just (ByteString.pack ("line-" <> show n)))]
          script = concatMap scriptRound [1 .. rounds] <> [Right Nothing]
      cursor <- newIORef script
      onLineSeen <- newIORef ([] :: [ByteString.ByteString])
      abandonSeen <- newIORef ([] :: [Text])
      let readLine = do
            queued <- readIORef cursor
            case queued of
              [] -> pure (Right Nothing)
              (next : rest) -> writeIORef cursor rest >> pure next
      outcome <- runStreamReaderWith readLine "stdout" (\line -> modifyIORef onLineSeen (line :)) (\reason -> modifyIORef abandonSeen (reason :))
      outcome `shouldBe` StreamCompleted
      seenLines <- reverse <$> readIORef onLineSeen
      seenLines `shouldBe` [ByteString.pack ("line-" <> show n) | n <- [1 .. rounds]]
      readIORef abandonSeen `shouldReturn` []

    it "gives up after maxConsecutiveReadFailures consecutive read failures instead of retrying forever or abandoning silently" $ do
      attempts <- newIORef (0 :: Int)
      onLineSeen <- newIORef ([] :: [ByteString.ByteString])
      abandonSeen <- newIORef ([] :: [Text])
      let readLine = do
            modifyIORef attempts (+ 1)
            pure (Left (userError "simulated persistent read failure"))
      outcome <- runStreamReaderWith readLine "stdout" (\line -> modifyIORef onLineSeen (line :)) (\reason -> modifyIORef abandonSeen (reason :))
      outcome `shouldBe` StreamAbandoned
      readIORef attempts `shouldReturn` maxConsecutiveReadFailures
      readIORef onLineSeen `shouldReturn` []
      reasons <- readIORef abandonSeen
      case reasons of
        [reason] -> do
          reason `shouldSatisfy` Data.Text.isInfixOf (Data.Text.pack (show maxConsecutiveReadFailures))
          reason `shouldSatisfy` Data.Text.isInfixOf "simulated persistent read failure"
        _ -> expectationFailure ("expected exactly one abandonment diagnostic, got " <> show (length reasons))

    it "onStreamAbandoned reports the diagnostic, remembers only the first reason, and terminates the still-live process" $
      withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \process -> do
        threadDelay 100000
        managed <- managedProcessFor process
        abandonReasonRef <- newIORef Nothing
        diagnostics <- newIORef ([] :: [Text])
        let emitDiagnostic message = modifyIORef diagnostics (message :)
        onStreamAbandoned emitDiagnostic managed abandonReasonRef "stdout gave up"
        onStreamAbandoned emitDiagnostic managed abandonReasonRef "stderr gave up too"
        readIORef abandonReasonRef `shouldReturn` Just "stdout gave up"
        seenDiagnostics <- reverse <$> readIORef diagnostics
        seenDiagnostics `shouldBe` ["stdout gave up", "stderr gave up too"]
        timeout 3000000 (waitForProcess process) `shouldReturn` Just (ExitFailure (-9))

    it "runStreamReader reads a real provider pipe through to EOF, exactly like the injected-action path" $ do
      (_, Just outputHandle, _, process) <- createProcess (proc "sh" ["-c", "printf 'alpha\\nbeta\\n'"]) {std_out = CreatePipe}
      onLineSeen <- newIORef ([] :: [ByteString.ByteString])
      abandonSeen <- newIORef ([] :: [Text])
      outcome <- runStreamReader outputHandle "stdout" (\line -> modifyIORef onLineSeen (line :)) (\reason -> modifyIORef abandonSeen (reason :))
      _ <- waitForProcess process
      outcome `shouldBe` StreamCompleted
      seenLines <- reverse <$> readIORef onLineSeen
      seenLines `shouldBe` ["alpha", "beta"]
      readIORef abandonSeen `shouldReturn` []

    it "handleReadLine reports a failure when the EOF probe itself throws" $ do
      (_, Just outputHandle, _, process) <- createProcess (proc "sh" ["-c", "sleep 30"]) {std_out = CreatePipe}
      hClose outputHandle
      result <- handleReadLine outputHandle
      case result of
        Left _ -> pure ()
        Right _ -> expectationFailure "expected hIsEOF on a closed handle to fail"
      managedProcessFor process >>= killManagedProcess
      void (timeout 3000000 (waitForProcess process))

    it "handleReadLine reports a failure when the line read is interrupted after the EOF probe already reported more to read" $ do
      (_, Just outputHandle, _, process) <- createProcess (proc "sh" ["-c", "printf '%s' 'partial-line-without-a-newline'; sleep 30"]) {std_out = CreatePipe}
      resultVar <- newEmptyMVar
      readerThread <- forkIO (handleReadLine outputHandle >>= putMVar resultVar)
      -- Long enough that the reader thread has certainly finished its
      -- (non-blocking, data-already-pending) EOF probe and parked in the
      -- blocking line read before the injected exception lands, so it
      -- exercises the line-read 'try', not the EOF probe's.
      threadDelay 500000
      throwTo readerThread (userError "simulated line-read cancellation")
      result <- timeout 5000000 (takeMVar resultVar)
      case result of
        Just (Left _) -> pure ()
        Just (Right _) -> expectationFailure "expected the interrupted read to fail"
        Nothing -> expectationFailure "handleReadLine did not return after being interrupted"
      managedProcessFor process >>= killManagedProcess
      void (timeout 3000000 (waitForProcess process))

  -- Both workflows classify their terminal outcome through one shared
  -- implementation, so every case below is asserted against 'solveOutcome'
  -- and 'flowOutcome' together: they must agree on marker anchoring and on
  -- exit-status precedence, and differ only in the failure diagnostic's
  -- agent label.
  describe "agent handoff outcome classification" $ do
    let bothOutcomes message exitCode = (solveOutcome exitCode message, flowOutcome exitCode message)

    it "treats a marker that begins the final message as a handoff" $
      bothOutcomes "KANBAN_NEEDS_INPUT: which base branch?" ExitSuccess
        `shouldBe` (SolveNeedsInput "which base branch?", SolveNeedsInput "which base branch?")

    it "treats a marker that begins a later line as a handoff" $
      bothOutcomes "I inspected the worktree.\nKANBAN_NEEDS_INPUT: which base branch?" ExitSuccess
        `shouldBe` (SolveNeedsInput "which base branch?", SolveNeedsInput "which base branch?")

    it "accepts an indented marker line" $
      bothOutcomes "Summary:\n   \tKANBAN_NEEDS_INPUT: which base branch?" ExitSuccess
        `shouldBe` (SolveNeedsInput "which base branch?", SolveNeedsInput "which base branch?")

    -- The regression this classification exists for: the prompts tell the
    -- agent to "stop with exactly KANBAN_NEEDS_INPUT: <question>", so a
    -- completion summary quoting the contract used to turn a finished run
    -- into a question nobody asked.
    it "completes a successful run whose message only mentions the marker mid-line" $
      bothOutcomes
        "Opened PR #42. Had ambiguity arisen I would have stopped with KANBAN_NEEDS_INPUT: a concrete question."
        ExitSuccess
        `shouldBe` (SolveCompleted, SolveCompleted)

    it "completes a successful run with no marker at all" $
      bothOutcomes "PR #42 — anchored the marker match." ExitSuccess
        `shouldBe` (SolveCompleted, SolveCompleted)

    it "ignores an anchored marker whose question is empty" $
      bothOutcomes "KANBAN_NEEDS_INPUT:   " ExitSuccess
        `shouldBe` (SolveCompleted, SolveCompleted)

    -- Deterministic rule: the last *valid* anchored line supplies the single
    -- question, so a resumed session's newest ask is the one surfaced.
    it "takes the last anchored line when several qualify" $
      bothOutcomes
        "KANBAN_NEEDS_INPUT: first question?\nstill working\nKANBAN_NEEDS_INPUT: second question?"
        ExitSuccess
        `shouldBe` (SolveNeedsInput "second question?", SolveNeedsInput "second question?")

    it "skips a trailing empty marker in favour of the last valid anchored line" $
      bothOutcomes "KANBAN_NEEDS_INPUT: real question?\nKANBAN_NEEDS_INPUT:" ExitSuccess
        `shouldBe` (SolveNeedsInput "real question?", SolveNeedsInput "real question?")

    -- A question the agent actually printed must outrank the exit status:
    -- needs-input is always more useful than a failure that buries it.
    it "keeps an anchored handoff when the agent exits nonzero" $
      bothOutcomes "KANBAN_NEEDS_INPUT: which base branch?" (ExitFailure 1)
        `shouldBe` (SolveNeedsInput "which base branch?", SolveNeedsInput "which base branch?")

    it "still fails a nonzero exit whose message only mentions the marker mid-line" $
      bothOutcomes "aborted before I could stop with KANBAN_NEEDS_INPUT: a question" (ExitFailure 3)
        `shouldBe` ( SolveFailed "Solver exited with status 3: aborted before I could stop with KANBAN_NEEDS_INPUT: a question",
                     SolveFailed "PR agent exited with status 3: aborted before I could stop with KANBAN_NEEDS_INPUT: a question"
                   )

    it "reports a nonzero exit without a marker using each workflow's diagnostic" $
      bothOutcomes "fatal: not a git repository" (ExitFailure 128)
        `shouldBe` ( SolveFailed "Solver exited with status 128: fatal: not a git repository",
                     SolveFailed "PR agent exited with status 128: fatal: not a git repository"
                   )

    it "omits the message from the diagnostic when the final message is blank" $
      bothOutcomes "  \n  " (ExitFailure 2)
        `shouldBe` (SolveFailed "Solver exited with status 2", SolveFailed "PR agent exited with status 2")

    it "truncates a long failure message to 1000 characters" $ do
      let (solveFailure, flowFailure) = bothOutcomes (Data.Text.replicate 1200 "x") (ExitFailure 1)
      solveFailure `shouldBe` SolveFailed ("Solver exited with status 1: " <> Data.Text.replicate 1000 "x")
      flowFailure `shouldBe` SolveFailed ("PR agent exited with status 1: " <> Data.Text.replicate 1000 "x")
