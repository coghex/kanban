-- | The repository-scoped issue review host and its durable child actions
-- (issue #594, SAG-10).
--
-- Everything here is either a pure rule or real IO against a redirected cache
-- root. Nothing spawns a host: a supervisor spawn would run this very test
-- binary with @--worker-spec@, and the behaviour worth pinning is not that a
-- process starts but what is durably written, what a later reader makes of
-- it, and what the host does with a command when it reads one.
module Spec.Agent.IssueHost (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (void)
import Data.Maybe (isJust)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar)
import Data.Aeson (FromJSON, ToJSON, Value (..), decode, eitherDecode, encode, toJSON)
import qualified Data.Map.Strict as Map
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Kanban.Domain (Repository (..), defaultWorkflowConfig)
import Kanban.Models (ProviderName (..))
import Kanban.Preflight (IssueOrigin (..), PreflightAction (..))
import Kanban.Review
  ( CanonicalIssueReviewResult (..),
    ConnectionId (..),
    ReviewAnswer (..),
    ReviewApproval (..),
    ReviewChoice (..),
    ReviewEvent (..),
    ReviewOutputKind (..),
    ReviewQuestion (..),
    ReviewQuestionKind (..),
    ReviewRequestId (..),
    ReviewResult (..),
    ReviewStage (..),
    ReviewThreadId (..),
    ReviewTurnOutcome (..),
    reviewTurnResumable,
  )
import Kanban.Solve (ResumeProvenance (..), SolveOutcome (..), SolveWorkflow (..), SolverBrand (..))
import Kanban.UI.Session (reviewSessionInputLive)
import Kanban.UI.Review (reviewOutcomePhase)
import Kanban.Worker
  ( IssueActionWorkerTask (..),
    IssueHostProvider (..),
    IssueHostTuning (..),
    IssueHostWorkerTask (..),
    ReviewCommand (..),
    ReviewCommandAcknowledgement (..),
    ReviewCommandId (..),
    ReviewCommandOutcome (..),
    ReviewCommandPayload (..),
    SolveWorkerTask (..),
    WorkerDescriptor (..),
    WorkerEnvelope (..),
    WorkerEvent (..),
    WorkerId (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    WorkerTask (..),
    acknowledgeReviewCommand,
    acknowledgeWorker,
    canonicalStageOutcome,
    childCommandOutcome,
    issueActionPreflightAction,
    revisionTurnOutcome,
    runIssueReviewHostWith,
    appendReviewCommand,
    collectWorkerCache,
    descriptorForSpec,
    discoverWorkerHistory,
    newReviewCommandId,
    readReviewCommandAcknowledgements,
    readReviewCommands,
    issueActionTask,
    readWorkerJournal,
    reviewCommandPayloadSummary,
    terminateWorker,
    undeliveredReviewCommands,
    workerDirectory,
  )
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Preflight (BackendFixture (..), fullyProvisionedFakes, withPreflightMachine)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory, takeFileName)
import Test.Hspec

spec :: Spec
spec = describe "the repository issue review host" $ do
  lifecycleSpec
  commandProtocolSpec
  terminationSpec
  evidenceSpec
  outcomeSpec
  collectionSpec
  compatibilitySpec

-- ---------------------------------------------------------------------------
-- A real host, running, against a provider the test controls
-- ---------------------------------------------------------------------------

lifecycleSpec :: Spec
lifecycleSpec = describe "one running host" $ do
  -- The whole path a review takes now: the dashboard writes a specification
  -- naming the host and exits, the host adopts it, the provider's events land
  -- in that child's own journal, and a later dashboard reads them from there.
  it "adopts a child that names it and journals its evidence into that child" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      thread <- awaitThreadFor host 594
      deliver host (ReviewTurnStarted thread "turn-1")
      deliver host (ReviewOutput thread AgentOutput "reading the issue")
      awaitJournal child 3
      events <- journalEvents child
      events
        `shouldBe` [ WorkerDiagnostic "issue #594 revision adopted by the repository review host",
                     WorkerReviewEvent (ReviewThreadCreated 594 thread),
                     WorkerReviewEvent (ReviewTurnStarted thread "turn-1"),
                     WorkerReviewEvent (ReviewOutput thread AgentOutput "reading the issue")
                   ]

  -- Requirement 5: the identifiers a later dashboard needs to address a
  -- command are on the child's own record, put there as the provider names
  -- them rather than derived when a command arrives.
  it "records the thread, turn, and pending request as the provider names them" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      thread <- awaitThreadFor host 594
      deliver host (ReviewTurnStarted thread "turn-1")
      deliver host (ReviewQuestionRequested thread (requestId 9) sampleQuestion)
      awaitJournal child 3
      state <- awaitState child (\recorded -> recorded.workerStateReviewRequest == Just (requestId 9))
      state.workerStateReviewThread `shouldBe` Just thread
      state.workerStateReviewTurn `shouldBe` Just "turn-1"

  -- Requirement 10: a question raised while no dashboard was running stays
  -- pending, and the answer a later dashboard writes reaches the original
  -- provider request exactly once.
  it "delivers a dashboard's answer to the original request exactly once" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      thread <- awaitThreadFor host 594
      deliver host (ReviewTurnStarted thread "turn-1")
      deliver host (ReviewQuestionRequested thread (requestId 9) sampleQuestion)
      _ <- awaitState child (\recorded -> recorded.workerStateReviewRequest == Just (requestId 9))
      answer <- commandNumbered 1 child (AnswerReviewQuestion (requestId 9) (ReviewAnswer ["a"] Nothing) "the solve lease")
      Right () <- appendReviewCommand child answer
      -- Appended a second time, as a replay or a retry would.
      Right () <- appendReviewCommand child answer
      awaitCalls host 1 isAnswerCall
      settled <- awaitAcknowledgements child 1
      map (.acknowledgedOutcome) settled `shouldBe` [ReviewCommandAccepted]
      calls <- providerCalls host
      length (filter isAnswerCall calls) `shouldBe` 1
      -- The line the user typed is in the child's evidence, so a dashboard
      -- that never saw the press still shows it.
      journaled <- journalEvents child
      journaled `shouldContain` [WorkerReviewInput "the solve lease" Nothing]

  -- Requirement 9's rejection half. A command aimed at a turn that has since
  -- ended is refused rather than retargeted, and the refusal is durable so it
  -- is not owed again.
  it "rejects a command aimed at a turn that has already ended" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      thread <- awaitThreadFor host 594
      deliver host (ReviewTurnStarted thread "turn-2")
      _ <- awaitState child (\recorded -> recorded.workerStateReviewTurn == Just "turn-2")
      stale <- commandNumbered 1 child InterruptReviewTurn
      Right () <- appendReviewCommand child stale {reviewCommandTurn = Just "turn-1"}
      settled <- awaitAcknowledgements child 1
      map (.acknowledgedOutcome) settled `shouldBe` [ReviewCommandRejected "that turn has already ended"]
      calls <- providerCalls host
      filter isInterruptCall calls `shouldBe` []

  -- Requirement 11 and 12 together, in the shape that matters most: ending
  -- one child leaves its sibling completely usable, and only the ended
  -- child's own thread is finished.
  it "settles one child and leaves its sibling running" $
    withRunningHost $ \host -> do
      first <- publishChild host "action-1" 594 IssueRevision
      firstThread <- awaitThreadFor host 594
      second <- publishChild host "action-2" 595 IssueRevision
      secondThread <- awaitThreadFor host 595
      termination <- commandNumbered 1 first TerminateIssueAction
      Right () <- appendReviewCommand first termination
      _ <- awaitState first (\recorded -> terminalState recorded.workerStateStatus)
      -- The ended child is terminal, its lease released, and its own thread
      -- finished.
      ended <- decodeChildState first
      fmap (.workerStateStatus) ended `shouldBe` Just (WorkerTerminal (SolveFailed "the issue action was terminated"))
      calls <- providerCalls host
      filter isFinishCall calls `shouldBe` [FinishThread firstThread]
      -- The sibling is untouched, and still takes a command.
      feedback <- commandNumbered 2 second (SendReviewFeedback "carry on")
      Right () <- appendReviewCommand second feedback
      awaitCalls host 1 isSendCall
      later <- providerCalls host
      filter isSendCall later `shouldBe` [SendMessage secondThread "carry on"]
      sibling <- decodeChildState second
      fmap (.workerStateStatus) sibling `shouldBe` Just WorkerRunning

  -- Requirement 10 again, on the boundary correction the approving review
  -- made: an interrupt is not a termination. The child stays live and
  -- resumable, and the provider is asked for a turn interrupt rather than a
  -- thread teardown.
  it "interrupts a turn without ending the child" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      thread <- awaitThreadFor host 594
      deliver host (ReviewTurnStarted thread "turn-1")
      _ <- awaitState child (\recorded -> recorded.workerStateReviewTurn == Just "turn-1")
      interrupt <- commandNumbered 1 child InterruptReviewTurn
      Right () <- appendReviewCommand child interrupt
      awaitCalls host 1 isInterruptCall
      calls <- providerCalls host
      filter isInterruptCall calls `shouldBe` [InterruptTurn thread "turn-1"]
      filter isFinishCall calls `shouldBe` []
      -- Still live, and the interrupted turn leaves it resumable.
      deliver host (ReviewTurnCompleted thread TurnInterrupted Nothing Nothing)
      awaitJournal child 3
      state <- decodeChildState child
      fmap (.workerStateStatus) state `shouldBe` Just WorkerRunning

  -- A completed revision turn settles its child, and the published result is
  -- in the evidence an observation reads.
  it "settles a child when its turn publishes a result" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      thread <- awaitThreadFor host 594
      deliver host (ReviewTurnStarted thread "turn-1")
      deliver host (ReviewTurnCompleted thread TurnSucceeded Nothing (Just ("raw", sampleResult)))
      state <- awaitState child (\recorded -> terminalState recorded.workerStateStatus)
      state.workerStateStatus `shouldBe` WorkerTerminal SolveCompleted
      journaled <- journalEvents child
      journaled `shouldContain` [WorkerFinished SolveCompleted]

  -- The host's own life. It holds no bound of its own and exits once it holds
  -- no live child, which is what stops it retaining this repository's host
  -- lease and discovery record for nothing.
  it "exits once it holds no live child, and stops its provider on the way out" $ do
    outcome <- withRunningHostOutcome $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      _ <- awaitThreadFor host 594
      termination <- commandNumbered 1 child TerminateIssueAction
      Right () <- appendReviewCommand child termination
      _ <- awaitState child (\recorded -> terminalState recorded.workerStateStatus)
      pure ()
    outcome `shouldBe` (Just (WorkerFinished SolveCompleted), True)

  -- A provider that will not start is the backend's own failure, reported on
  -- the host's journal and ending it rather than leaving a host serving
  -- nobody.
  it "ends immediately when its provider cannot start" $ do
    events <- withHostStartFailure "codex app-server exited during initialization"
    events `shouldContain` [WorkerFinished (SolveFailed "codex app-server exited during initialization")]

-- ---------------------------------------------------------------------------
-- The durable dashboard-to-child command protocol (requirement 9)
-- ---------------------------------------------------------------------------

commandProtocolSpec :: Spec
commandProtocolSpec = describe "the durable input protocol" $ do
  it "delivers a correlated command exactly once, whatever a restart replays" $
    withIssueAction $ \descriptor -> do
      answer <- commandFor descriptor (AnswerReviewQuestion (requestId 7) (ReviewAnswer ["yes"] Nothing) "yes")
      -- Written once, and read once: this is the host's first pass.
      Right () <- appendReviewCommand descriptor answer
      firstPass <- owedBy descriptor
      map (.reviewCommandId) firstPass `shouldBe` [answer.reviewCommandId]
      -- Applied, and acknowledged.
      acknowledgement <- acknowledged answer ReviewCommandAccepted
      Right () <- acknowledgeReviewCommand descriptor acknowledgement
      -- The host restarts and reads both files again. The command is not
      -- owed a second delivery, which is the whole of "a dashboard restart
      -- must not cause an accepted command to be delivered again".
      secondPass <- owedBy descriptor
      secondPass `shouldBe` []

  it "applies a retried command once, before anything has acknowledged it" $
    withIssueAction $ \descriptor -> do
      steer <- commandFor descriptor (SendReviewFeedback "look at the lease")
      Right () <- appendReviewCommand descriptor steer
      -- The same command id appended again: a deliberate retry, or a replay.
      Right () <- appendReviewCommand descriptor steer
      owed <- owedBy descriptor
      map (.reviewCommandId) owed `shouldBe` [steer.reviewCommandId]

  it "keeps two commands for one child in the order they were issued" $
    withIssueAction $ \descriptor -> do
      first <- commandNumbered 1 descriptor (SendReviewFeedback "one")
      second <- commandNumbered 2 descriptor (SendReviewFeedback "two")
      Right () <- appendReviewCommand descriptor first
      Right () <- appendReviewCommand descriptor second
      owed <- owedBy descriptor
      map (.reviewCommandPayload) owed `shouldBe` [SendReviewFeedback "one", SendReviewFeedback "two"]

  -- A rejection settles the command as finally as an acceptance does. Without
  -- that, a steer the provider refused would be owed forever and retried on
  -- every poll.
  it "settles a rejected command rather than owing it again" $
    withIssueAction $ \descriptor -> do
      steer <- commandFor descriptor (ResendReviewSteer "resend me")
      Right () <- appendReviewCommand descriptor steer
      acknowledgement <- acknowledged steer (ReviewCommandRejected "that turn has already ended")
      Right () <- acknowledgeReviewCommand descriptor acknowledgement
      owedBy descriptor `shouldReturn` []
      settled <- readReviewCommandAcknowledgements descriptor
      map (.acknowledgedOutcome) settled `shouldBe` [ReviewCommandRejected "that turn has already ended"]

  it "carries every command in the vocabulary through the journal unchanged" $
    withIssueAction $ \descriptor -> do
      commands <- mapM (\(ordinal, payload) -> commandNumbered ordinal descriptor payload) (zip [1 ..] everyPayload)
      mapM_ (\command -> appendReviewCommand descriptor command >>= (`shouldBe` Right ())) commands
      readBack <- readReviewCommands descriptor
      map (.reviewCommandPayload) readBack `shouldBe` everyPayload

  -- What the transcript entry a gesture leaves reads as. The three payloads
  -- carrying a person's own words show those; the two that are gestures
  -- rather than words are named by the vocabulary itself, so a new gesture
  -- cannot land in a transcript as an empty line.
  it "names every command in the vocabulary" $
    map reviewCommandPayloadSummary everyPayload
      `shouldBe` [ "question answer",
                   "approval decision",
                   "feedback",
                   "resent steer",
                   "turn interrupt",
                   "termination"
                 ]

  -- The host's own answer to a provider call, which is what an
  -- acknowledgement records.
  it "reads a provider refusal as a rejection and a success as an acceptance" $ do
    childCommandOutcome (Right ()) `shouldBe` ReviewCommandAccepted
    childCommandOutcome (Left "no active turn") `shouldBe` ReviewCommandRejected "no active turn"

everyPayload :: [ReviewCommandPayload]
everyPayload =
  [ AnswerReviewQuestion (requestId 1) (ReviewAnswer ["a"] (Just "other")) "a",
    AnswerReviewApproval (requestId 2) True True "Allowed similar actions for this review session",
    SendReviewFeedback "feedback",
    ResendReviewSteer "steer",
    InterruptReviewTurn,
    TerminateIssueAction
  ]

-- ---------------------------------------------------------------------------
-- Child-scoped termination (requirement 11)
-- ---------------------------------------------------------------------------

terminationSpec :: Spec
terminationSpec = describe "ending one child" $ do
  -- The rule that stops a kill taking the whole repository down. A child's
  -- recorded worker pid is its host's, so the ordinary signal path would
  -- reach the host and every sibling multiplexed onto it.
  it "asks the host to end a child rather than signalling the host's group" $
    withIssueAction $ \descriptor -> do
      now <- getCurrentTime
      writeChildState descriptor (runningChildState descriptor now)
      terminateWorker descriptor
      commands <- readReviewCommands descriptor
      map (.reviewCommandPayload) commands `shouldBe` [TerminateIssueAction]
      map (.reviewCommandTarget) commands `shouldBe` [descriptor.workerDescriptorSpec.workerId]
      -- Nothing was committed here: the host is the one that settles a child,
      -- and it has not read the command yet.
      state <- decodeChildState descriptor
      fmap (.workerStateStatus) state `shouldBe` Just WorkerRunning

  -- The other half. A child whose host is provably gone has nobody to read a
  -- command, so leaving one behind would leave the action live forever.
  it "settles a child directly once its host is provably gone" $
    withIssueAction $ \descriptor -> do
      now <- getCurrentTime
      -- No recorded host identity at all is deliberately *not* this case: it
      -- is the window before the host wrote its own state, so the command is
      -- still what reaches it.
      writeChildState descriptor (runningChildState descriptor now) {workerStateWorkerIdentity = Nothing}
      terminateWorker descriptor
      commands <- readReviewCommands descriptor
      length commands `shouldBe` 1

-- ---------------------------------------------------------------------------
-- Durable evidence (requirements 4 and 5)
-- ---------------------------------------------------------------------------

evidenceSpec :: Spec
evidenceSpec = describe "the durable review evidence" $ do
  -- Replay is what makes a reattached overlay identical to a live one, and
  -- replay is only as faithful as the schema. Every constructor, so a new
  -- event that cannot be read back is caught here rather than by an operator
  -- watching a transcript lose its questions.
  it "round-trips every review event through the journal's schema" $
    mapM_
      (\event -> decode (encode event) `shouldBe` Just event)
      everyReviewEvent

  it "round-trips a canonical backend result, route and models included" $
    decode (encode canonicalResult) `shouldBe` Just canonicalResult

  it "journals a child's evidence and reads it back in order" $
    withIssueAction $ \descriptor -> do
      let events =
            [ WorkerReviewEvent (ReviewThreadCreated 594 sampleThread),
              WorkerReviewInput "yes" Nothing,
              WorkerReviewInput "no" (Just "that review request is no longer pending"),
              WorkerCanonicalReviewFinished InitialReview (Right canonicalResult),
              WorkerFinished SolveCompleted
            ]
      now <- getCurrentTime
      LazyByteString.writeFile
        descriptor.workerDescriptorEventPath
        (LazyByteString.concat [encode (WorkerEnvelope now event) <> "\n" | event <- events])
      journaled <- readWorkerJournal descriptor
      map (.workerEnvelopeEvent) journaled `shouldBe` events

  -- Requirement 5: stage-inapplicable identifiers are optional and absent. A
  -- canonical child has no embedded provider session, and a state that
  -- carried one would be fabricating it.
  it "records no provider thread, turn, or request for a canonical stage" $
    withIssueAction $ \descriptor -> do
      now <- getCurrentTime
      let state = runningChildState descriptor now
      writeChildState descriptor state
      readBack <- decodeChildState descriptor
      fmap (.workerStateReviewThread) readBack `shouldBe` Just Nothing
      fmap (.workerStateReviewTurn) readBack `shouldBe` Just Nothing
      fmap (.workerStateReviewRequest) readBack `shouldBe` Just Nothing

  it "records them once an interactive revision has them" $
    withIssueAction $ \descriptor -> do
      now <- getCurrentTime
      let revising =
            (runningChildState descriptor now)
              { workerStateReviewThread = Just sampleThread,
                workerStateReviewTurn = Just "turn-1",
                workerStateReviewRequest = Just (requestId 3)
              }
      writeChildState descriptor revising
      readBack <- decodeChildState descriptor
      fmap (.workerStateReviewThread) readBack `shouldBe` Just (Just sampleThread)
      fmap (.workerStateReviewTurn) readBack `shouldBe` Just (Just "turn-1")
      fmap (.workerStateReviewRequest) readBack `shouldBe` Just (Just (requestId 3))

everyReviewEvent :: [ReviewEvent]
everyReviewEvent =
  [ ReviewThreadCreated 594 sampleThread,
    ReviewTurnStarted sampleThread "turn-1",
    ReviewOutput sampleThread AgentOutput "text",
    ReviewOutput sampleThread ReasoningOutput "thinking",
    ReviewOutput sampleThread CommandOutput "running",
    ReviewOutput sampleThread (DiagnosticOutput ClaudeProvider) "stderr",
    ReviewQuestionRequested sampleThread (requestId 1) sampleQuestion,
    ReviewApprovalRequested sampleThread (requestId 2) sampleApproval,
    ReviewClaudeStarted sampleThread "opus high",
    ReviewClaudeFinished sampleThread (Right ()),
    ReviewClaudeFinished sampleThread (Left "the CLI exited"),
    ReviewGitHubStarted sampleThread "commenting on #594",
    ReviewGitHubFinished sampleThread (Right "posted"),
    ReviewGitHubFinished sampleThread (Left "gh failed"),
    ReviewTurnCompleted sampleThread TurnSucceeded Nothing (Just ("raw", sampleResult)),
    ReviewTurnCompleted sampleThread TurnFailed (Just "the turn failed") Nothing,
    ReviewTurnCompleted sampleThread TurnInterrupted Nothing Nothing,
    ReviewStartFailed 594 "the coordinator refused",
    ReviewClientStopped "the app server exited",
    ReviewConnectionStopped (ConnectionId 2) "that connection exited",
    ReviewSteerUndelivered sampleThread "turn-1" "look again",
    ReviewInterruptFailed sampleThread "no such turn" (Just "guidance"),
    ReviewInterruptFailed sampleThread "no such turn" Nothing,
    ReviewProtocolWarning CodexProvider "turn/started omitted its thread"
  ]

-- ---------------------------------------------------------------------------
-- What a child's turn leaves behind
-- ---------------------------------------------------------------------------

outcomeSpec :: Spec
outcomeSpec = describe "what settles a child" $ do
  -- The one spelling of resumability, and the reason it has to be one. The
  -- overlay decides from it whether to keep offering an input line, and the
  -- host decides from it whether the child behind that line is still there to
  -- receive what is typed.
  it "keeps a child alive exactly while its overlay still offers a line" $
    sequence_
      [ (stage, outcome, resultKind, hostKeepsAlive, overlayOffersLine)
          `shouldBe` (stage, outcome, resultKind, overlayOffersLine, overlayOffersLine)
        | stage <- [InitialReview, IssueRevision, IssueRereview],
          outcome <- [TurnSucceeded, TurnFailed, TurnInterrupted],
          (resultKind, result) <- [("with a result" :: String, Just sampleResult), ("without one", Nothing)],
          let hostKeepsAlive = revisionTurnOutcome stage outcome result == Nothing,
          let overlayOffersLine = reviewSessionInputLive stage (reviewOutcomePhase stage outcome result)
      ]

  it "leaves only an interrupted revision resumable" $
    sequence_
      [ (stage, outcome, reviewTurnResumable stage outcome)
          `shouldBe` (stage, outcome, stage == IssueRevision && outcome == TurnInterrupted)
        | stage <- [InitialReview, IssueRevision, IssueRereview],
          outcome <- [TurnSucceeded, TurnFailed, TurnInterrupted]
      ]

  -- Requirement 6: a canonical invocation that failed is this invocation's
  -- failure and never a verdict — it may well have published one before
  -- failing, which is exactly why "not approved" would be a lie.
  it "reads a canonical result as completion, and a canonical failure as failure" $ do
    canonicalStageOutcome (Right canonicalResult) `shouldBe` SolveCompleted
    canonicalStageOutcome (Right canonicalResult {canonicalReviewApproved = False}) `shouldBe` SolveCompleted
    canonicalStageOutcome (Left "python3 was not found on PATH")
      `shouldBe` SolveFailed "python3 was not found on PATH"

  -- The stage split that decides the authority, asked of preflight too: a
  -- canonical stage needs the canonical backend and the reviewers its origin
  -- routes to, a revision needs the interactive coordinator's dependencies.
  it "preflights each stage as the action it actually is" $ do
    issueActionPreflightAction InitialReview IssueOriginClaude `shouldBe` ActionIssueReview IssueOriginClaude
    issueActionPreflightAction IssueRereview IssueOriginCodex `shouldBe` ActionIssueReview IssueOriginCodex
    issueActionPreflightAction IssueRevision IssueOriginClaude `shouldBe` ActionIssueRevision IssueOriginClaude

-- ---------------------------------------------------------------------------
-- The §16 collection pass
-- ---------------------------------------------------------------------------

collectionSpec :: Spec
collectionSpec = describe "collecting host and child records" $ do
  -- The host discovers children by scanning for specifications naming it, so
  -- collecting a child's records under a live host takes away the evidence
  -- that host is reading — and the journal a later dashboard replays.
  it "keeps a terminal child's records while its host is live" $
    withHostTopology WorkerRunning (WorkerTerminal SolveCompleted) $ \_ child -> do
      acknowledgeWorker child
      collectWorkerCache testRepository
      doesFileExist child.workerDescriptorSpecPath `shouldReturn` True

  it "collects that child once its host has finished too" $
    withHostTopology (WorkerTerminal SolveCompleted) (WorkerTerminal SolveCompleted) $ \host child -> do
      acknowledgeWorker child
      acknowledgeWorker host
      collectWorkerCache testRepository
      doesFileExist child.workerDescriptorSpecPath `shouldReturn` False

  -- The mirror image. A child records its host's id and reattaches only to
  -- the host it names, so a host record collected out from under a live child
  -- leaves that child naming an owner nothing can resolve.
  it "keeps a terminal host's records while a child is still running" $
    withHostTopology (WorkerTerminal SolveCompleted) WorkerRunning $ \host _ -> do
      acknowledgeWorker host
      collectWorkerCache testRepository
      doesFileExist host.workerDescriptorSpecPath `shouldReturn` True

  it "keeps them while a terminal child is still unacknowledged" $
    withHostTopology (WorkerTerminal SolveCompleted) (WorkerTerminal SolveCompleted) $ \host _ -> do
      acknowledgeWorker host
      collectWorkerCache testRepository
      doesFileExist host.workerDescriptorSpecPath `shouldReturn` True

  -- The command ledger is a companion artifact like the journal, so a
  -- collection that left it behind would accumulate a person's typed guidance
  -- in the cache forever.
  it "collects a child's command ledger with the rest of its records" $
    withHostTopology (WorkerTerminal SolveCompleted) (WorkerTerminal SolveCompleted) $ \host child -> do
      command <- commandFor child (SendReviewFeedback "look again")
      Right () <- appendReviewCommand child command
      acknowledgeWorker child
      acknowledgeWorker host
      collectWorkerCache testRepository
      doesFileExist child.workerDescriptorCommandPath `shouldReturn` False

-- ---------------------------------------------------------------------------
-- Durable-record compatibility
-- ---------------------------------------------------------------------------

compatibilitySpec :: Spec
compatibilitySpec = describe "records written before this change" $ do
  -- A decode failure at startup discovery drops a live worker rather than
  -- reporting it, so the three new state fields and the two new task kinds
  -- must leave every existing record readable.
  -- Built by withholding the new keys from what the current encoder writes,
  -- rather than by hand: a hand-written fixture asserts the shape its author
  -- believed in, and the shape that actually has to keep decoding is the one
  -- the release before this wrote.
  it "decodes a solve specification written before the issue kinds existed" $
    case decodeWithout ["workerAssignment", "workerConfigPath", "workerWorkflowConfig", "workerResumeProvenance"] (specFor (WorkerId "solve-1") (SolveWorkerTaskKind legacySolveTask)) of
      Left message -> expectationFailure message
      Right (specification :: WorkerSpec) -> do
        specification.workerId `shouldBe` WorkerId "solve-1"
        specification.workerAssignment `shouldBe` Nothing

  it "decodes a worker state written before the review identifiers existed" $ do
    now <- getCurrentTime
    descriptor <- descriptorForSpec (specFor (WorkerId "solve-1") (SolveWorkerTaskKind legacySolveTask))
    case decodeWithout ["workerStateReviewThread", "workerStateReviewTurn", "workerStateReviewRequest"] (runningChildState descriptor now) of
      Left message -> expectationFailure message
      Right (state :: WorkerState) -> do
        state.workerStateReviewThread `shouldBe` Nothing
        state.workerStateReviewTurn `shouldBe` Nothing
        state.workerStateReviewRequest `shouldBe` Nothing
        state.workerStateStatus `shouldBe` WorkerRunning

  it "still discovers a pre-change solve worker beside the new kinds" $
    withTemporaryCacheRoot $ \temporaryRoot ->
      withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
        directory <- workerDirectory testRepository
        createDirectoryIfMissing True directory
        solve <- descriptorForSpec (specFor (WorkerId "solve-legacy") (SolveWorkerTaskKind legacySolveTask))
        LazyByteString.writeFile solve.workerDescriptorSpecPath (encode solve.workerDescriptorSpec)
        discovered <- discoverWorkerHistory testRepository
        map (.workerDescriptorSpec.workerId) discovered `shouldBe` [WorkerId "solve-legacy"]

  -- The lease keys, which requirement 13 keeps apart so a solve and a review
  -- of one issue can run at once.
  it "leases an issue action apart from that issue's solve worker" $
    withTemporaryCacheRoot $ \temporaryRoot ->
      withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
        solve <- descriptorForSpec (specFor (WorkerId "solve-1") (SolveWorkerTaskKind legacySolveTask))
        action <- descriptorForSpec (specFor (WorkerId "action-1") (IssueActionWorkerTaskKind sampleAction))
        host <- descriptorForSpec (specFor (WorkerId "host-1") (IssueHostWorkerTaskKind (IssueHostWorkerTask "coghex/kanban")))
        map (takeFileName . (.workerDescriptorLeasePath)) [solve, action, host]
          `shouldBe` ["issue-594.lease", "issue-action-594.lease", "issue-host.lease"]

-- ---------------------------------------------------------------------------
-- A host under test, and the provider it runs against
-- ---------------------------------------------------------------------------

-- | Every provider operation the host made, in order.
--
-- Recorded rather than merely counted so an assertion can name the thread and
-- turn an operation reached: "one interrupt happened" is true of an interrupt
-- aimed at the wrong sibling too.
data ProviderCall
  = BeginReview Int
  | AnswerQuestion ReviewRequestId
  | ApproveAction ReviewRequestId Bool Bool
  | SendMessage ReviewThreadId Text
  | InterruptTurn ReviewThreadId Text
  | FinishThread ReviewThreadId
  | StopProvider
  deriving stock (Eq, Show)

isAnswerCall, isInterruptCall, isFinishCall, isSendCall :: ProviderCall -> Bool
isAnswerCall (AnswerQuestion _) = True
isAnswerCall _ = False
isInterruptCall InterruptTurn {} = True
isInterruptCall _ = False
isFinishCall (FinishThread _) = True
isFinishCall _ = False
isSendCall SendMessage {} = True
isSendCall _ = False

-- | One running host, its cache root, and the handles a test drives it by.
data HostUnderTest = HostUnderTest
  { hostRepository :: Repository,
    -- | The sink the host handed its provider, which is how a test plays a
    -- provider event into the host exactly as a real backend would.
    hostSink :: ReviewEvent -> IO (),
    hostCalls :: MVar [ProviderCall],
    -- | Allocated per @thread\/start@, so two concurrent children get
    -- distinct threads on one connection — the shared-process shape.
    hostThreads :: MVar (Map.Map Int ReviewThreadId)
  }

-- | Runs a real host against a provider this test controls, hands the body a
-- handle to it, then lets it exit and reports its terminal event and whether
-- its provider was stopped.
--
-- The host runs in a thread rather than a process: what is under test is its
-- lifecycle — adoption, routing, commands, settling, exit — and a spawn would
-- run this test binary again.
withRunningHost :: (HostUnderTest -> IO ()) -> IO ()
withRunningHost = void . withRunningHostOutcome

withRunningHostOutcome :: (HostUnderTest -> IO ()) -> IO (Maybe WorkerEvent, Bool)
withRunningHostOutcome body =
  -- A fully provisioned fake machine, because the host runs its /production/
  -- preflight at each child's spawn boundary (requirement 7's first half runs
  -- at the press, this is the second). Stubbing that out would leave the one
  -- boundary a child can be refused at untested.
  withPreflightMachine fullyProvisionedFakes BackendInstalled $ \workingDirectory _ ->
    withEnvironmentValue "XDG_CACHE_HOME" (takeDirectory workingDirectory) $ do
      let repository = Repository workingDirectory "coghex" "kanban"
      directory <- workerDirectory repository
      createDirectoryIfMissing True directory
      calls <- newMVar []
      threads <- newMVar Map.empty
      sinkCell <- newEmptyMVar
      emitted <- newMVar []
      let hostSpecification =
            (specFor hostIdUnderTest (IssueHostWorkerTaskKind (IssueHostWorkerTask "coghex/kanban")))
              {workerRepository = repository}
          record call = modifyMVar_ calls (pure . (<> [call]))
          startProvider _ sink = do
            putMVar sinkCell sink
            pure (Right (recordingProvider record threads sink))
      hostDescriptor <- descriptorForSpec hostSpecification
      LazyByteString.writeFile hostDescriptor.workerDescriptorSpecPath (encode hostSpecification)
      -- Forked rather than spawned: what is under test is the host's own
      -- loop, and a real supervisor spawn would run this test binary again
      -- with @--worker-spec@.
      finished <- newEmptyMVar
      void . forkIO $ do
        runIssueReviewHostWith
          (IssueHostTuning 20000 1)
          startProvider
          hostSpecification
          (\event -> modifyMVar_ emitted (pure . (<> [event])))
        putMVar finished ()
      sink <- takeMVar sinkCell
      body
        HostUnderTest
          { hostRepository = repository,
            hostSink = sink,
            hostCalls = calls,
            hostThreads = threads
          }
      -- The host exits when it holds no live child, so a body that left one
      -- running would wait forever. Ending them is done the way anything ends
      -- one — a durable termination command — rather than by reaching into
      -- the host, so the teardown exercises the same path the tests do.
      endEveryChild repository
      takeMVar finished
      finalCalls <- readMVar calls
      finalEvents <- readMVar emitted
      pure (lastTerminal finalEvents, StopProvider `elem` finalCalls)
  where
    lastTerminal events = case [event | event@(WorkerFinished _) <- events] of
      terminal : _ -> Just terminal
      [] -> Nothing

-- | The host's own journal when its provider refuses to start.
withHostStartFailure :: Text -> IO [WorkerEvent]
withHostStartFailure message =
  withTemporaryCacheRoot $ \temporaryRoot ->
    withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
      directory <- workerDirectory testRepository
      createDirectoryIfMissing True directory
      emitted <- newMVar []
      runIssueReviewHostWith
        (IssueHostTuning 20000 1)
        (\_ _ -> pure (Left message))
        (specFor hostIdUnderTest (IssueHostWorkerTaskKind (IssueHostWorkerTask "coghex/kanban")))
        (\event -> modifyMVar_ emitted (pure . (<> [event])))
      readMVar emitted

-- | A provider that records what it was asked and announces a thread for each
-- review it is asked to begin.
--
-- Announcing the thread through the host's own sink is what makes this a
-- faithful stand-in: a real backend names a thread by emitting
-- 'ReviewThreadCreated', and the host binds the child to it there rather than
-- from the return of the call.
recordingProvider :: (ProviderCall -> IO ()) -> MVar (Map.Map Int ReviewThreadId) -> (ReviewEvent -> IO ()) -> IssueHostProvider
recordingProvider record threads sink =
  IssueHostProvider
    { providerBeginReview = \issueNumber -> do
        record (BeginReview issueNumber)
        thread <- modifyMVar threads $ \held ->
          let allocated = ReviewThreadId (ConnectionId 1) (Text.pack ("thread-" <> show (Map.size held + 1)))
           in pure (Map.insert issueNumber allocated held, allocated)
        sink (ReviewThreadCreated issueNumber thread)
        pure (Right ()),
      providerAnswerQuestion = \requested _ -> Right () <$ record (AnswerQuestion requested),
      providerApproveAction = \requested accepted forSession ->
        Right () <$ record (ApproveAction requested accepted forSession),
      providerSendMessage = \thread _ message -> Right () <$ record (SendMessage thread message),
      providerInterruptTurn = \thread turnId -> Right () <$ record (InterruptTurn thread turnId),
      providerFinishThread = record . FinishThread,
      providerStop = record StopProvider
    }

-- | Ends every issue action this repository still holds, and waits until the
-- host has settled each one.
endEveryChild :: Repository -> IO ()
endEveryChild repository = do
  history <- discoverWorkerHistory repository
  let children = [descriptor | descriptor <- history, isJust (issueActionTask descriptor.workerDescriptorSpec.workerTask)]
  sequence_
    [ do
        termination <- commandNumbered (900 + ordinal) descriptor TerminateIssueAction
        void (appendReviewCommand descriptor termination)
      | (ordinal, descriptor) <- zip [0 ..] children
    ]
  mapM_ (\descriptor -> void (awaitMaybe (settledOrGone descriptor))) children
  where
    settledOrGone descriptor = do
      recorded <- decodeChildState descriptor
      pure (if maybe True (terminalState . (.workerStateStatus)) recorded then Just () else Nothing)

hostIdUnderTest :: WorkerId
hostIdUnderTest = WorkerId "host-under-test"

-- | Publishes one child specification naming the host under test, exactly as
-- the registry's launch does, and returns its descriptor.
publishChild :: HostUnderTest -> Text -> Int -> ReviewStage -> IO WorkerDescriptor
publishChild host identifier issueNumber stage = do
  now <- getCurrentTime
  descriptor <-
    descriptorForSpec
      ( (specFor
           (WorkerId identifier)
           (IssueActionWorkerTaskKind (IssueActionWorkerTask issueNumber stage hostIdUnderTest IssueOriginClaude)))
          { workerRepository = host.hostRepository,
            -- Dated now, not at the fixture epoch: a child is bounded from
            -- its own creation, and one dated in the past is settled by that
            -- bound before its stage can start.
            workerCreatedAt = now
          }
      )
  writeChildState descriptor (runningChildState descriptor now) {workerStateStatus = WorkerStarting}
  LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec)
  pure descriptor

deliver :: HostUnderTest -> ReviewEvent -> IO ()
deliver host = host.hostSink

providerCalls :: HostUnderTest -> IO [ProviderCall]
providerCalls host = readMVar host.hostCalls

-- | Waits until the host has begun this issue's review and the provider has
-- named its thread.
awaitThreadFor :: HostUnderTest -> Int -> IO ReviewThreadId
awaitThreadFor host issueNumber = do
  found <- awaitMaybe (Map.lookup issueNumber <$> readMVar host.hostThreads)
  case found of
    Just thread -> pure thread
    Nothing -> do
      -- The child's own journal is the account of why its stage never
      -- started -- a preflight blocker, a refused coordinator -- so a failure
      -- here reports that rather than only the absence.
      history <- discoverWorkerHistory host.hostRepository
      journals <- mapM journalEvents history
      fail ("no thread was allocated for issue #" <> show issueNumber <> "; journals: " <> show journals)

awaitCalls :: HostUnderTest -> Int -> (ProviderCall -> Bool) -> IO ()
awaitCalls host expected wanted =
  awaitJust "the provider was not called as expected" $ do
    calls <- readMVar host.hostCalls
    pure (if length (filter wanted calls) >= expected then Just () else Nothing)

awaitJournal :: WorkerDescriptor -> Int -> IO ()
awaitJournal descriptor expected =
  awaitJust "the child's journal did not reach the expected length" $ do
    journaled <- readWorkerJournal descriptor
    pure (if length journaled > expected then Just () else Nothing)

awaitState :: WorkerDescriptor -> (WorkerState -> Bool) -> IO WorkerState
awaitState descriptor wanted =
  awaitJust "the child's state never satisfied the condition" $ do
    recorded <- decodeChildState descriptor
    pure (if maybe False wanted recorded then recorded else Nothing)

awaitAcknowledgements :: WorkerDescriptor -> Int -> IO [ReviewCommandAcknowledgement]
awaitAcknowledgements descriptor expected =
  awaitJust "the host acknowledged fewer commands than expected" $ do
    settled <- readReviewCommandAcknowledgements descriptor
    pure (if length settled >= expected then Just settled else Nothing)

-- | Polls a condition to a bound rather than sleeping a fixed time: the host
-- is a real loop on its own thread, so a fixed sleep is either slower than it
-- needs to be or flaky under load.
--
-- The bound is generous — half a minute — and costs nothing when the
-- condition holds, because a satisfied probe returns on its first pass. It is
-- sized for the suite's own worst case rather than for an idle machine: five
-- lanes run at once, and a bound tuned to a quiet run is a test that fails
-- for load rather than for a defect.
awaitJust :: String -> IO (Maybe result) -> IO result
awaitJust reason probe = awaitMaybe probe >>= maybe (fail reason) pure

awaitMaybe :: IO (Maybe result) -> IO (Maybe result)
awaitMaybe probe = go (1200 :: Int)
  where
    go remaining = do
      found <- probe
      case found of
        Just result -> pure (Just result)
        Nothing
          | remaining <= 0 -> pure Nothing
          | otherwise -> threadDelay 25000 >> go (remaining - 1)

journalEvents :: WorkerDescriptor -> IO [WorkerEvent]
journalEvents descriptor = map (.workerEnvelopeEvent) <$> readWorkerJournal descriptor

terminalState :: WorkerStatus -> Bool
terminalState (WorkerTerminal _) = True
terminalState _ = False

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

testRepository :: Repository
testRepository = Repository "/tmp/kanban" "coghex" "kanban"

legacySolveTask :: SolveWorkerTask
legacySolveTask = SolveWorkerTask 594 SolveOnly ClaudeSolver

sampleAction :: IssueActionWorkerTask
sampleAction = IssueActionWorkerTask 594 InitialReview (WorkerId "host-1") IssueOriginClaude

sampleThread :: ReviewThreadId
sampleThread = ReviewThreadId (ConnectionId 1) "thread-7"

requestId :: Int -> ReviewRequestId
requestId value = ReviewRequestId (ConnectionId 1) (encodeNumber value)
  where
    encodeNumber number = maybe (error "request id") id (decode (encode number))

sampleQuestion :: ReviewQuestion
sampleQuestion =
  ReviewQuestion
    { reviewQuestionId = "q-1",
      reviewQuestionHeader = "INPUT REQUIRED",
      reviewQuestionText = "which lease?",
      reviewQuestionKind = QuestionChoice,
      reviewQuestionChoices = [ReviewChoice "a" "the solve lease" "issue-N"],
      reviewQuestionAllowOther = True,
      reviewQuestionMultiple = False
    }

sampleApproval :: ReviewApproval
sampleApproval = ReviewApproval (Just "gh issue edit") (Just "label move") False

sampleResult :: ReviewResult
sampleResult =
  ReviewResult
    { reviewResultIssue = 594,
      reviewResultStage = IssueRevision,
      reviewResultApproved = False,
      reviewResultReviewerRoute = "codex",
      reviewResultModels = ["gpt-5.6-sol@xhigh"],
      reviewResultCommentUrl = Just "https://example.test/1",
      reviewResultBlockingReasons = []
    }

canonicalResult :: CanonicalIssueReviewResult
canonicalResult =
  CanonicalIssueReviewResult
    { canonicalReviewApproved = True,
      canonicalReviewIssue = 594,
      canonicalReviewOrigin = "claude",
      canonicalReviewRequiredReviewers = Just "codex",
      canonicalReviewRequiredModels = Just "gpt-5.6-sol@xhigh",
      canonicalReviewReasons = []
    }

specFor :: WorkerId -> WorkerTask -> WorkerSpec
specFor identifier task =
  WorkerSpec
    { workerId = identifier,
      workerRepository = testRepository,
      workerTask = task,
      workerExistingSession = Nothing,
      workerExistingLogPath = Nothing,
      workerResumeProvenance = ResumeAnswer,
      workerUserMessage = "",
      workerParent = Nothing,
      workerCreatedAt = fixtureTime,
      workerMaxRuntimeSeconds = 600,
      workerConfigPath = Nothing,
      workerWorkflowConfig = defaultWorkflowConfig,
      workerAssignment = Nothing
    }

fixtureTime :: UTCTime
fixtureTime = maybe (error "fixture time") id (decode "\"2026-01-01T00:00:00Z\"")

-- | One issue action's durable files under a redirected cache root.
withIssueAction :: (WorkerDescriptor -> IO result) -> IO result
withIssueAction body =
  withTemporaryCacheRoot $ \temporaryRoot ->
    withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
      directory <- workerDirectory testRepository
      createDirectoryIfMissing True directory
      descriptor <- descriptorForSpec (specFor (WorkerId "action-1") (IssueActionWorkerTaskKind sampleAction))
      LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec)
      body descriptor

-- | A host and one child of it, each published in the status the caller names.
withHostTopology :: WorkerStatus -> WorkerStatus -> (WorkerDescriptor -> WorkerDescriptor -> IO result) -> IO result
withHostTopology hostStatus childStatus body =
  withTemporaryCacheRoot $ \temporaryRoot ->
    withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
      directory <- workerDirectory testRepository
      createDirectoryIfMissing True directory
      host <- descriptorForSpec (specFor hostId (IssueHostWorkerTaskKind (IssueHostWorkerTask "coghex/kanban")))
      child <- descriptorForSpec (specFor (WorkerId "action-1") (IssueActionWorkerTaskKind sampleAction {issueActionHost = hostId}))
      -- Dated well past the retention window on purpose. Inside it, a
      -- terminal worker is retained by a rule that predates this change --
      -- collectable only once acknowledged /and/ superseded -- and a test
      -- measured there would pass whatever the host/child rules did. Past it,
      -- the only thing left holding a record is the topology.
      now <- expiredHeartbeat
      mapM_
        (\(descriptor, status) -> publish descriptor status now)
        [(host, hostStatus), (child, childStatus)]
      body host child
  where
    hostId = WorkerId "host-1"
    publish descriptor status now = do
      LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec)
      writeChildState descriptor (runningChildState descriptor now) {workerStateStatus = status}

-- | The record this release writes, with the named keys withheld, decoded as
-- the release before this would have left it.
decodeWithout :: (ToJSON record, FromJSON decoded) => [Key.Key] -> record -> Either String decoded
decodeWithout withheld record = case toJSON record of
  Object fields -> eitherDecode (encode (Object (foldr KeyMap.delete fields withheld)))
  _ -> Left "the record did not encode as an object"

-- | A heartbeat far enough back that the retention window has closed on it.
expiredHeartbeat :: IO UTCTime
expiredHeartbeat = addUTCTime (negate (60 * 24 * 60 * 60)) <$> getCurrentTime

runningChildState :: WorkerDescriptor -> UTCTime -> WorkerState
runningChildState descriptor now =
  WorkerState
    { workerStateId = descriptor.workerDescriptorSpec.workerId,
      workerStateStatus = WorkerRunning,
      -- The host's, because the host is this child's supervisor. Identity 1
      -- is init, which is always present, so a termination test that reads it
      -- sees a live host rather than a flake.
      workerStateWorkerPid = 1,
      workerStateWorkerIdentity = Nothing,
      workerStateProviderPid = Nothing,
      workerStateProviderIdentity = Nothing,
      workerStateSessionId = Nothing,
      workerStateLogPath = Nothing,
      workerStateHeartbeatAt = now,
      workerStateLastActivity = "running",
      workerStateKnownProcesses = [],
      workerStateReviewThread = Nothing,
      workerStateReviewTurn = Nothing,
      workerStateReviewRequest = Nothing
    }

writeChildState :: WorkerDescriptor -> WorkerState -> IO ()
writeChildState descriptor = LazyByteString.writeFile descriptor.workerDescriptorStatePath . encode

decodeChildState :: WorkerDescriptor -> IO (Maybe WorkerState)
decodeChildState descriptor = decode <$> LazyByteString.readFile descriptor.workerDescriptorStatePath

commandFor :: WorkerDescriptor -> ReviewCommandPayload -> IO ReviewCommand
commandFor = commandNumbered 0

-- | Two commands allocated in the same clock tick would otherwise share an
-- id and be deduplicated against each other, which would make an ordering
-- test pass for the wrong reason. The suffix is the caller's, so a test that
-- needs two distinct commands says so rather than relying on the clock.
commandNumbered :: Int -> WorkerDescriptor -> ReviewCommandPayload -> IO ReviewCommand
commandNumbered ordinal descriptor payload = do
  identifier <- newReviewCommandId
  now <- getCurrentTime
  pure
    ReviewCommand
      { reviewCommandId = distinct identifier,
        reviewCommandTarget = descriptor.workerDescriptorSpec.workerId,
        reviewCommandIssue = 594,
        reviewCommandThread = Just sampleThread,
        reviewCommandTurn = Just "turn-1",
        reviewCommandIssuedAt = now,
        reviewCommandPayload = payload
      }
  where
    distinct (ReviewCommandId value) = ReviewCommandId (value <> "-" <> Text.pack (show ordinal))

owedBy :: WorkerDescriptor -> IO [ReviewCommand]
owedBy descriptor =
  undeliveredReviewCommands <$> readReviewCommands descriptor <*> readReviewCommandAcknowledgements descriptor

acknowledged :: ReviewCommand -> ReviewCommandOutcome -> IO ReviewCommandAcknowledgement
acknowledged command outcome = do
  now <- getCurrentTime
  pure (ReviewCommandAcknowledgement command.reviewCommandId now outcome)
