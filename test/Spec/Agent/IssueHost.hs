-- | The repository-scoped issue review host and its durable child actions
-- (issue #594, SAG-10).
--
-- Everything here is either a pure rule or real IO against a redirected cache
-- root. Nothing spawns a host: a supervisor spawn would run this very test
-- binary with @--worker-spec@, and the behaviour worth pinning is not that a
-- process starts but what is durably written, what a later reader makes of
-- it, and what the host does with a command when it reads one.
module Spec.Agent.IssueHost (spec) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (IOException, bracket, try)
import Control.Monad (forM_, join, void, when)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List (find, findIndex, isInfixOf, nub)
import Data.Maybe (isJust)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar, tryReadMVar, tryTakeMVar)
import Data.Aeson (FromJSON, ToJSON, Value (..), decode, eitherDecode, eitherDecodeFileStrict', encode, toJSON)
import qualified Data.Map.Strict as Map
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Kanban.Domain (Repository (..), defaultWorkflowConfig)
import Kanban.Models (ProviderName (..))
import Kanban.Process (ManagedProcess, ProcessIdentity (..), identityForPid, managedProcessGroup, managedProcessPid, readProcessSnapshot)
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
import Kanban.Transcript (transcriptRoot)
import Kanban.Worker
  ( IssueActionWorkerTask (..),
    recoverIfWorkerStoppedWith,
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
    acknowledgementFor,
    reviewCommandSettled,
    canonicalStageOutcome,
    childCommandOutcome,
    issueActionPreflightAction,
    liveIssueReviewHost,
    acquireWorkerLease,
    runWorkerWithTask,
    workerDeadlineAt,
    workerDeadlinePassed,
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
    issueHostGone,
    neverAdopted,
    monitorWorker,
    acquireWorkerLeaseFor,
    reconcileIssueActionClaims,
    confirmIssueActionAdoptedWith,
    readWorkerJournal,
    reviewCommandDisplay,
    reviewCommandPayloadSummary,
    terminateWorker,
    undeliveredReviewCommands,
    workerDirectory,
  )
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Preflight (BackendFixture (..), fullyProvisionedFakes, realProcessSnapshotTool, withPreflightMachine)
import Spec.Support.Process (identityForProcess, managedProcessFor, shouldHaveBeenSwept, withManagedShell)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removeDirectory, removeFile)
import System.Timeout (timeout)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.Posix.IO (OpenMode (ReadOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.IO.ByteString (fdRead)
import Test.Hspec

spec :: Spec
spec = describe "the repository issue review host" $ do
  lifecycleSpec
  commandProtocolSpec
  terminationSpec
  evidenceSpec
  outcomeSpec
  hostLivenessSpec
  hostDeadlineSpec
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
      settled <- awaitAcknowledgements child 2
      settledOutcome answer.reviewCommandId settled `shouldBe` Just ReviewCommandAccepted
      calls <- providerCalls host
      length (filter isAnswerCall calls) `shouldBe` 1
      -- The line the user typed is in the child's evidence, so a dashboard
      -- that never saw the press still shows it.
      journaled <- journalEvents child
      journaled `shouldContain` [WorkerReviewInput answer.reviewCommandId "the solve lease" Nothing]

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
      settled <- awaitAcknowledgements child 2
      settledOutcome stale.reviewCommandId settled `shouldBe` Just (ReviewCommandRejected "that turn has already ended")
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

  -- Round 1's first blocker. A child can be settled — by a termination
  -- command, a deadline, or a dead connection — between asking the provider
  -- for a thread and the provider announcing one, because the announcement is
  -- asynchronous. The announcement then lands on a child that has left the
  -- live map, and a thread nobody owns is a thread nobody closes: under a
  -- process-per-thread backend, a leaked process.
  it "closes a thread the provider announces after its child was settled" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      -- Settled after the review was asked for and before its thread was
      -- announced, which is the ordering the race produces.
      _ <- awaitCallsFor host 1 isBeginCall
      termination <- commandNumbered 1 child TerminateIssueAction
      Right () <- appendReviewCommand child termination
      _ <- awaitState child (\recorded -> terminalState recorded.workerStateStatus)
      -- Nothing was finished on the way out: the child never held a thread.
      settledCalls <- providerCalls host
      filter isFinishCall settledCalls `shouldBe` []
      let late = ReviewThreadId (ConnectionId 1) "thread-late"
      deliver host (ReviewThreadCreated 594 late)
      awaitCalls host 1 isFinishCall
      calls <- providerCalls host
      filter isFinishCall calls `shouldBe` [FinishThread late]
      -- The child's journal ended at its terminal envelope, so what became of
      -- the late thread is recorded on the host instead — where an operator
      -- can find it without a replay reading past a terminal event.
      journaled <- journalEvents child
      journaled `shouldNotContain` [WorkerReviewEvent (ReviewThreadCreated 594 late)]
      _ <- awaitHostDiagnostic host "announced this action's thread after it had already been settled"
      pure ()

  -- Round 1's third blocker. A command correlated to one thread must not be
  -- retargeted at whichever thread the child is on when it is read.
  it "rejects a command naming a thread the child has left" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      thread <- awaitThreadFor host 594
      deliver host (ReviewTurnStarted thread "turn-1")
      _ <- awaitState child (\recorded -> recorded.workerStateReviewTurn == Just "turn-1")
      stale <- commandNumbered 1 child (SendReviewFeedback "look again")
      Right () <- appendReviewCommand child stale {reviewCommandThread = Just (ReviewThreadId (ConnectionId 1) "thread-other")}
      settled <- awaitAcknowledgements child 2
      settledOutcome stale.reviewCommandId settled `shouldBe` Just (ReviewCommandRejected "that provider thread has already ended")
      calls <- providerCalls host
      filter isSendCall calls `shouldBe` []

  it "rejects a thread-scoped command that names no thread at all" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      thread <- awaitThreadFor host 594
      deliver host (ReviewTurnStarted thread "turn-1")
      _ <- awaitState child (\recorded -> recorded.workerStateReviewTurn == Just "turn-1")
      unaddressed <- commandNumbered 1 child (SendReviewFeedback "look again")
      Right () <- appendReviewCommand child unaddressed {reviewCommandThread = Nothing}
      settled <- awaitAcknowledgements child 2
      settledOutcome unaddressed.reviewCommandId settled `shouldBe` Just (ReviewCommandRejected "that command names no provider thread")

  -- Termination is the exception, and has to be: it ends the child whichever
  -- thread it is on, and refusing it for a thread that moved would leave an
  -- action nobody can stop.
  it "accepts a termination that names a thread the child has left" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      _ <- awaitThreadFor host 594
      stale <- commandNumbered 1 child TerminateIssueAction
      Right () <- appendReviewCommand child stale {reviewCommandThread = Just (ReviewThreadId (ConnectionId 1) "thread-other")}
      state <- awaitState child (\recorded -> terminalState recorded.workerStateStatus)
      state.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed "the issue action was terminated")

  -- Round 2's first blocker. A settled child releases its lease, so a
  -- replacement action for the same issue can start immediately — and the
  -- first action's thread announcement, keyed on the wire by issue number
  -- alone, would then attach to the replacement. Its thread would take the
  -- replacement's commands and never be closed. Start order is the
  -- correlation the protocol gives, so the announcement resolves to the
  -- action that asked for it.
  it "attaches a late thread to the action that asked, not to its replacement" $
    withRunningHost $ \host -> do
      first <- publishChild host "action-1" 594 IssueRevision
      _ <- awaitCallsFor host 1 isBeginCall
      termination <- commandNumbered 1 first TerminateIssueAction
      Right () <- appendReviewCommand first termination
      _ <- awaitState first (\recorded -> terminalState recorded.workerStateStatus)
      -- The replacement takes the freed lease. It waits for the first
      -- action's start to be answered before asking for a thread of its own
      -- (round 14), and it is present and adopted the whole time — which is
      -- what makes the announcement below a choice between two actions rather
      -- than a foregone conclusion.
      second <- publishChild host "action-2" 594 IssueRevision
      _ <- awaitJust "the replacement was never adopted" $ do
        journaled <- journalEvents second
        pure (if null journaled then Nothing else Just ())
      -- The first action's announcement, arriving now.
      let late = ReviewThreadId (ConnectionId 1) "thread-first"
      deliver host (ReviewThreadCreated 594 late)
      awaitCalls host 1 isFinishCall
      calls <- providerCalls host
      filter isFinishCall calls `shouldBe` [FinishThread late]
      -- The replacement never took it, so it is still waiting for its own.
      replacement <- decodeChildState second
      (replacement >>= (.workerStateReviewThread)) `shouldBe` Nothing
      -- And it works normally once its own start has been made — which the
      -- announcement above is what released.
      _ <- awaitCallsFor host 2 isBeginCall
      own <- awaitThreadFor host 594
      own `shouldNotBe` late

  -- Round 2's second blocker. A command applied and then not acknowledged is
  -- owed again on the next poll, which sends the same steer to the same
  -- provider thread twice. Claiming it before applying inverts that: an
  -- unwritable ledger means nothing was applied, and a written claim means it
  -- is never applied again.
  it "claims a command before applying it, so a lost acknowledgement cannot replay it" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      _ <- awaitThreadFor host 594
      feedback <- commandNumbered 1 child (SendReviewFeedback "look again")
      Right () <- appendReviewCommand child feedback
      awaitCalls host 1 isSendCall
      settled <- awaitAcknowledgements child 2
      -- The claim, then the outcome, in that order.
      map (.acknowledgedOutcome) settled `shouldBe` [ReviewCommandClaimed, ReviewCommandAccepted]
      -- The last record is what a reader takes, and a claimed command is
      -- never owed again.
      acknowledgementFor feedback.reviewCommandId settled
        `shouldSatisfy` maybe False (reviewCommandSettled . (.acknowledgedOutcome))
      owedBy child `shouldReturn` []

  -- The same ledger, read the way a host restarted mid-delivery reads it: a
  -- command carrying only a claim is not owed, so the provider operation is
  -- never repeated.
  it "never owes a command whose claim is the only record of it" $
    withIssueAction $ \descriptor -> do
      command <- commandNumbered 1 descriptor (SendReviewFeedback "look again")
      Right () <- appendReviewCommand descriptor command
      claim <- acknowledged command ReviewCommandClaimed
      Right () <- acknowledgeReviewCommand descriptor claim
      owedBy descriptor `shouldReturn` []
      -- And it reads as unsettled, which is the honest account of an attempt
      -- whose result was never observed.
      settled <- readReviewCommandAcknowledgements descriptor
      acknowledgementFor command.reviewCommandId settled
        `shouldSatisfy` maybe False (not . reviewCommandSettled . (.acknowledgedOutcome))

  -- Round 2's fourth blocker. Host selection and child admission cannot be
  -- one atomic step from the launch side, so a child can name a host that has
  -- since terminated. A fresh host adopts such a child rather than leaving an
  -- action the operator started to sit until stale recovery.
  it "adopts a starting child whose named host has already finished" $
    withRunningHost $ \host -> do
      child <- publishChildNaming host (WorkerId "host-that-exited") "action-1" 594 IssueRevision
      publishTerminalHost host (WorkerId "host-that-exited")
      _ <- awaitThreadFor host 594
      adopted <- decodeChildState child
      fmap (.workerStateStatus) adopted `shouldBe` Just WorkerRunning

  -- The other half, and the one that keeps this from being theft: a child
  -- whose named host is still live belongs to that host, and this one leaves
  -- it alone however long it waits.
  it "leaves a starting child alone while its named host is still live" $
    withRunningHost $ \host -> do
      child <- publishChildNaming host (WorkerId "host-still-running") "action-1" 594 IssueRevision
      publishRunningHost host (WorkerId "host-still-running")
      -- Give the host several polls to get it wrong in.
      threadDelay 300000
      calls <- providerCalls host
      filter isBeginCall calls `shouldBe` []
      untouched <- decodeChildState child
      fmap (.workerStateStatus) untouched `shouldBe` Just WorkerStarting

  -- Round 2's fifth blocker. A shared-process backend writes every thread's
  -- traffic to one client-wide transcript, so a child had no raw evidence of
  -- its own to point at or replay. Each child now keeps its own, recorded on
  -- its own state, and two concurrent revisions do not share one.
  it "gives each concurrent child its own raw log, and the host its client's" $
    withRunningHost $ \host -> do
      first <- publishChild host "action-1" 594 IssueRevision
      firstThread <- awaitThreadFor host 594
      second <- publishChild host "action-2" 595 IssueRevision
      secondThread <- awaitThreadFor host 595
      deliver host (ReviewOutput firstThread AgentOutput "reading 594")
      deliver host (ReviewOutput secondThread AgentOutput "reading 595")
      awaitJournal first 2
      awaitJournal second 2
      firstLog <- awaitJust "the first child recorded no raw log" (fmap (>>= (.workerStateLogPath)) (decodeChildState first))
      secondLog <- awaitJust "the second child recorded no raw log" (fmap (>>= (.workerStateLogPath)) (decodeChildState second))
      firstLog `shouldNotBe` secondLog
      -- Each holds its own traffic and not its sibling's.
      -- Read as bytes rather than through 'readFile': the host still holds
      -- each log open, and GHC's handle locking refuses a second reader.
      firstContents <- readLogBytes firstLog
      secondContents <- readLogBytes secondLog
      firstContents `shouldSatisfy` isInfixOf "reading 594"
      firstContents `shouldSatisfy` (not . isInfixOf "reading 595")
      secondContents `shouldSatisfy` isInfixOf "reading 595"
      secondContents `shouldSatisfy` (not . isInfixOf "reading 594")

  -- Round 3's first blocker. Retiring settled children by issue number let
  -- each later one overwrite the last, so the earlier action's pending
  -- announcement resolved to nothing and its thread was never closed.
  --
  -- Two settled actions for one issue, each with a thread to close. They are
  -- sequential rather than simultaneous because one issue has one start
  -- outstanding at a time (round 14) — but the retirement they land in is
  -- still keyed by action, and the second must not displace the first there.
  it "closes the late thread of every settled action, not only the newest" $
    withRunningHost $ \host -> do
      first <- publishChild host "action-1" 594 IssueRevision
      _ <- awaitCallsFor host 1 isBeginCall
      endChild first
      let firstThread = ReviewThreadId (ConnectionId 1) "thread-first"
          secondThread = ReviewThreadId (ConnectionId 1) "thread-second"
      -- The second action takes the freed lease. Its own start waits for the
      -- first action's announcement, which arrives here and is closed.
      second <- publishChild host "action-2" 594 IssueRevision
      deliver host (ReviewThreadCreated 594 firstThread)
      _ <- awaitCallsFor host 2 isBeginCall
      -- Settled before its own announcement too.
      endChild second
      -- A third is live when the second's late announcement arrives.
      third <- publishChild host "action-3" 594 IssueRevision
      deliver host (ReviewThreadCreated 594 secondThread)
      awaitCalls host 2 isFinishCall
      calls <- providerCalls host
      -- Both closed, in the order they were announced: the first action's
      -- retirement was still there to be found when the second one landed.
      filter isFinishCall calls `shouldBe` [FinishThread firstThread, FinishThread secondThread]
      -- The live action took neither, and still gets its own.
      held <- decodeChildState third
      (held >>= (.workerStateReviewThread)) `shouldBe` Nothing

  -- Round 3's fourth blocker. A claim with no outcome is what a host that
  -- died mid-delivery leaves, and the command must never be applied again —
  -- but the dashboard that submitted it cleared its draft, so leaving the
  -- claim standing loses the message with no account of where it went. The
  -- next host to adopt the child settles it as unobserved and journals it as
  -- undelivered, which is what hands the text back to the input line.
  it "settles a claim a previous host left standing, and reports it as undelivered" $
    withRunningHost $ \host -> do
      -- Written the way a host that died mid-delivery leaves the ledger: the
      -- command, its claim, and nothing else.
      descriptor <- childDescriptorFor host "action-1" 594 IssueRevision
      inherited <- commandNumbered 1 descriptor (SendReviewFeedback "look again")
      Right () <- appendReviewCommand descriptor inherited
      claim <- acknowledged inherited ReviewCommandClaimed
      Right () <- acknowledgeReviewCommand descriptor claim
      child <- publishChild host "action-1" 594 IssueRevision
      _ <- awaitCallsFor host 1 isBeginCall
      settled <- awaitAcknowledgements child 2
      settledOutcome inherited.reviewCommandId settled `shouldBe` Just ReviewCommandOutcomeUnknown
      -- Never re-applied, which is what the claim was for.
      calls <- providerCalls host
      filter isSendCall calls `shouldBe` []
      -- And the child's own evidence says the message was not delivered, so a
      -- replay offers it back rather than showing it as sent.
      journaled <- journalEvents child
      journaled
        `shouldContain` [WorkerReviewInput inherited.reviewCommandId "look again" (Just "the review host stopped before this command's result was observed")]

  -- Round 4's first blocker. A message written to steer one turn and read
  -- after that turn ended would steer the next one — or, with no turn left,
  -- open a fresh turn carrying text meant to redirect a finished one.
  it "rejects feedback written for a turn that has since been replaced" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      thread <- awaitThreadFor host 594
      deliver host (ReviewTurnStarted thread "turn-1")
      _ <- awaitState child (\recorded -> recorded.workerStateReviewTurn == Just "turn-1")
      stale <- commandNumbered 1 child (SendReviewFeedback "look again")
      -- The turn ends and another starts on the same thread before the
      -- command is read.
      deliver host (ReviewTurnCompleted thread TurnInterrupted Nothing Nothing)
      deliver host (ReviewTurnStarted thread "turn-2")
      _ <- awaitState child (\recorded -> recorded.workerStateReviewTurn == Just "turn-2")
      Right () <- appendReviewCommand child stale
      settled <- awaitAcknowledgements child 1
      settledOutcome stale.reviewCommandId settled `shouldBe` Just (ReviewCommandRejected "that turn has already ended")
      calls <- providerCalls host
      filter isSendCall calls `shouldBe` []

  -- Round 4's second blocker. A termination settles the child part-way
  -- through a batch this pass already snapshotted, and everything queued
  -- behind it is addressed to an action that no longer exists — under a
  -- shared connection, feedback read after that point would open a new turn
  -- on a thread the settle had finished with.
  it "refuses commands queued behind a termination rather than acting on them" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      thread <- awaitThreadFor host 594
      deliver host (ReviewTurnStarted thread "turn-1")
      _ <- awaitState child (\recorded -> recorded.workerStateReviewTurn == Just "turn-1")
      termination <- commandNumbered 1 child TerminateIssueAction
      queued <- commandNumbered 2 child (SendReviewFeedback "carry on")
      -- Both in the ledger before the host's next poll, so one batch holds
      -- the termination and the command behind it.
      Right () <- appendReviewCommand child termination
      Right () <- appendReviewCommand child queued
      _ <- awaitState child (\recorded -> terminalState recorded.workerStateStatus)
      settled <- awaitAcknowledgements child 3
      settledOutcome queued.reviewCommandId settled
        `shouldBe` Just (ReviewCommandRejected "this issue action has already ended")
      calls <- providerCalls host
      filter isSendCall calls `shouldBe` []

  -- Round 4's third and fourth blockers together. A child that had already
  -- started under a host that then died is recovered rather than restarted
  -- (requirement 15), its standing claim is answered, and the specification
  -- is rewritten to name the host actually serving it — because startup
  -- discovery and the cache collection pass both read ownership from there.
  it "recovers a started child whose host died, without restarting it" $
    withRunningHost $ \host -> do
      descriptor <- childDescriptorNaming host (WorkerId "host-that-died") "action-1" 594 IssueRevision
      inherited <- commandNumbered 1 descriptor (SendReviewFeedback "look again")
      Right () <- appendReviewCommand descriptor inherited
      claim <- acknowledged inherited ReviewCommandClaimed
      Right () <- acknowledgeReviewCommand descriptor claim
      -- Published as a child that had started: a thread recorded, so it is
      -- not the never-adopted case.
      child <- publishStartedChildNaming host (WorkerId "host-that-died") "action-1" 594 IssueRevision
      publishTerminalHost host (WorkerId "host-that-died")
      state <- awaitState child (\recorded -> terminalState recorded.workerStateStatus)
      state.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed "the review host that owned this action stopped before it finished; its provider session cannot be resumed")
      -- Nothing was restarted, which is what requirement 15 forbids.
      calls <- providerCalls host
      filter isBeginCall calls `shouldBe` []
      -- The standing claim was answered, and its message offered back.
      settled <- readReviewCommandAcknowledgements child
      settledOutcome inherited.reviewCommandId settled `shouldBe` Just ReviewCommandOutcomeUnknown
      journaled <- journalEvents child
      journaled
        `shouldContain` [WorkerReviewInput inherited.reviewCommandId "look again" (Just "the review host stopped before this command's result was observed")]
      -- And the specification now names the host that served it, so
      -- discovery and collection read one owner rather than two.
      adopted <- discoverWorkerHistory host.hostRepository
      let owners =
            [ task.issueActionHost
              | candidate <- adopted,
                Just task <- [issueActionTask candidate.workerDescriptorSpec.workerTask]
            ]
      owners `shouldBe` [hostIdUnderTest]

  -- Round 15's first blocker, and the third instance of one shape: read the
  -- settle claim, then act on what it said. A termination landing between the
  -- two leaves the settle finding no thread to finish and this installing one
  -- on an action already terminal — which under a shared connection goes on
  -- running with nothing owning it.
  it "closes a thread announced while its child is being settled" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      -- Begun, so this child's own start is outstanding and the announcement
      -- below resolves to it; no thread yet, which is the state a settle in
      -- this window would find nothing to finish in.
      _ <- awaitCallsFor host 1 isBeginCall
      inside <- newEmptyMVar
      release <- newEmptyMVar
      entered <- newIORef False
      -- Parked between reading the settle claim and acting on it, which is
      -- the whole window. A test cannot land a termination there from
      -- outside, and losing that race by luck is not a regression anyone can
      -- rely on.
      modifyMVar_ host.hostAttach . const . pure $ do
        first <- atomicModifyIORef' entered (\seen -> (True, not seen))
        when first (putMVar inside () >> takeMVar release)
      let announced = ReviewThreadId (ConnectionId 1) "thread-racing-the-settle"
      void . forkIO $ deliver host (ReviewThreadCreated 594 announced)
      _ <- awaitJust "the attach never reached its barrier" (tryReadMVar inside)
      -- The termination now runs while the attach is parked. Ordered, it
      -- waits; unordered, it settles a child that holds no thread and
      -- finishes nothing, and the attach then installs one on an action
      -- already terminal.
      ended <- newEmptyMVar
      void . forkIO $ endChild child >> putMVar ended ()
      threadDelay 200000
      putMVar release ()
      _ <- awaitMaybe (tryTakeMVar ended)
      _ <- awaitState child (\recorded -> terminalState recorded.workerStateStatus)
      -- The thread was closed, whichever of the two got there first. Never
      -- neither, which is the leak: under a shared connection that thread and
      -- its turn go on running with nothing owning them.
      awaitCalls host 1 isFinishCall
      calls <- providerCalls host
      filter isFinishCall calls `shouldBe` [FinishThread announced]

  -- Round 14's first blocker. An announcement names only an issue on the
  -- wire, and a settled action keeps its start outstanding on purpose so its
  -- late thread is still closed — while its released lease lets a replacement
  -- for that issue begin. Two outstanding starts for one issue cannot be told
  -- apart, so the older takes the newer's thread and the newer the older's.
  it "holds a replacement's start until the earlier one for that issue is answered" $
    withRunningHost $ \host -> do
      first <- publishChild host "action-1" 594 IssueRevision
      _ <- awaitCallsFor host 1 isBeginCall
      -- Settled before its start was answered, which is what leaves the start
      -- outstanding and the issue free to be claimed again.
      endChild first
      second <- publishChild host "action-2" 594 IssueRevision
      -- Adopted — its journal says so — and still not begun: one start at a
      -- time. It stays 'WorkerStarting' precisely because it is waiting.
      _ <- awaitJust "the replacement was never adopted" $ do
        journaled <- journalEvents second
        pure (if null journaled then Nothing else Just ())
      -- A negative, so it is given real time to be wrong in: the stage thread
      -- is forked at adoption and would call the provider within a poll or
      -- two of it.
      tooEarly <- awaitBriefly $ do
        calls <- providerCalls host
        pure (if length (filter isBeginCall calls) >= 2 then Just () else Nothing)
      tooEarly `shouldBe` Nothing
      waiting <- decodeChildState second
      fmap (.workerStateStatus) waiting `shouldBe` Just WorkerStarting
      -- The first action's own thread arrives and is closed as the late
      -- thread of a settled action, rather than becoming the replacement's.
      let firstThread = ReviewThreadId (ConnectionId 1) "thread-of-the-first"
      deliver host (ReviewThreadCreated 594 firstThread)
      awaitCalls host 1 isFinishCall
      providerCalls host >>= \recorded -> filter isFinishCall recorded `shouldBe` [FinishThread firstThread]
      firstState <- decodeChildState second
      (firstState >>= (.workerStateReviewThread)) `shouldBe` Nothing
      -- And only then does the replacement begin, and take its own thread.
      _ <- awaitCallsFor host 2 isBeginCall
      secondThread <- awaitThreadFor host 594
      recorded <- decodeChildState second
      (recorded >>= (.workerStateReviewThread)) `shouldBe` Just secondThread

  -- Round 14's third blocker. Every reader treats a claim as settled, which
  -- is what stops a command being applied twice — so a final acknowledgement
  -- that could not be written left the claim standing, and a live host
  -- answered it never: only a later adoption or a stale-worker recovery did.
  it "answers a claim its own acknowledgement failed to settle" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      thread <- awaitThreadFor host 594
      deliver host (ReviewTurnStarted thread "turn-1")
      _ <- awaitState child (\recorded -> recorded.workerStateReviewTurn == Just "turn-1")
      -- The ledger as a delivery that applied and journaled its line, then
      -- failed to write the outcome, leaves it.
      delivered <- commandNumbered 1 child (SendReviewFeedback "look again")
      Right () <- appendReviewCommand child delivered
      claim <- acknowledged delivered ReviewCommandClaimed
      Right () <- acknowledgeReviewCommand child claim
      seedJournal child [WorkerReviewInput delivered.reviewCommandId "look again" Nothing]
      -- A live host settles it from that evidence, on its own poll, with the
      -- real outcome rather than as one nobody observed.
      settled <- awaitAcknowledgements child 2
      settledOutcome delivered.reviewCommandId settled `shouldBe` Just ReviewCommandAccepted
      -- And re-applies nothing: the provider never sees this message.
      calls <- providerCalls host
      filter isSendCall calls `shouldBe` []

  -- Round 20's first blocker. Closing the journal and recording the terminal
  -- state are two writes, and a host dying between them leaves whichever
  -- prefix landed. The envelope goes first because that prefix — a closed
  -- journal over a state that still reads as running — is the one something
  -- repairs; this is that repair, and it is what makes the order safe.
  it "completes a settle that died between its journal and its state" $
    withTemporaryCacheRoot $ \temporaryRoot ->
      withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
        now <- getCurrentTime
        descriptor <-
          descriptorForSpec
            ( specFor
                (WorkerId "half-settled-action")
                (IssueActionWorkerTaskKind (IssueActionWorkerTask 594 IssueRevision (WorkerId "host-that-died") IssueOriginClaude))
            )
        createDirectoryIfMissing True (takeDirectory descriptor.workerDescriptorSpecPath)
        LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec)
        -- The surviving prefix: the journal closed, the state not yet
        -- written, and the host that was writing them gone.
        writeChildState
          descriptor
          (runningChildState descriptor (addUTCTime (-600) now))
            {workerStateWorkerIdentity = Just departedIdentity}
        seedJournal descriptor [WorkerFinished (SolveFailed "the issue action was terminated")]
        emitted <- newMVar []
        recovered <-
          recoverIfWorkerStoppedWith
            (pure (Right []))
            descriptor
            (\_ _ event -> modifyMVar_ emitted (pure . (<> [event])))
            0
        recovered `shouldBe` True
        -- The state is finished, and the journal still carries exactly one
        -- envelope: a second would be a record after the last record.
        recordedState <- decodeChildState descriptor
        fmap (terminalState . (.workerStateStatus)) recordedState `shouldBe` Just True
        journaled <- journalEvents descriptor
        [event | event@(WorkerFinished _) <- journaled]
          `shouldBe` [WorkerFinished (SolveFailed "the issue action was terminated")]

  -- Round 22's first blocker, and the gap in the round-20 test beside it:
  -- that one drove 'recoverIfWorkerStoppedWith' directly, and the real path
  -- never reaches it. 'monitorWorker' stops replaying at a terminal envelope,
  -- and stopping is exactly what skipped the recovery that was supposed to
  -- complete the settle — so the transcript ended while the child stayed
  -- running, discoverable, and holding its lease for ever.
  it "completes a half-settled child through the monitor that replays it" $
    withTemporaryCacheRoot $ \temporaryRoot ->
      withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
        now <- getCurrentTime
        descriptor <- halfSettledChild (addUTCTime (-600) now)
        emitted <- newMVar []
        monitored <-
          forkIO (monitorWorker descriptor (\_ _ event -> modifyMVar_ emitted (pure . (<> [event]))))
        recorded <-
          awaitJust "the monitor never completed the settle" $ do
            held <- decodeChildState descriptor
            pure (if maybe False (terminalState . (.workerStateStatus)) held then held else Nothing)
        recorded.workerStateStatus
          `shouldBe` WorkerTerminal (SolveFailed "the issue action was terminated")
        -- The envelope it found, replayed once, and no second one written.
        journaled <- journalEvents descriptor
        [event | event@(WorkerFinished _) <- journaled]
          `shouldBe` [WorkerFinished (SolveFailed "the issue action was terminated")]
        -- And the lease is free, which is the thing a child left running
        -- holds against every later action for its issue.
        doesDirectoryExist descriptor.workerDescriptorLeasePath `shouldReturn` False
        killThread monitored

  -- Round 22's second blocker. The dead-host fallback reaches the same
  -- half-settled child by the other route, and appended a second terminal
  -- envelope over the first — a record after the journal's last record, and
  -- a different outcome from the one the action had already published.
  it "repairs a half-settled child rather than ending it a second time" $
    withTemporaryCacheRoot $ \temporaryRoot ->
      withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
        now <- getCurrentTime
        descriptor <- halfSettledChild (addUTCTime (-600) now)
        terminateWorker descriptor
        -- No command: the host is provably gone, so this settles directly.
        readReviewCommands descriptor `shouldReturn` []
        journaled <- journalEvents descriptor
        [event | event@(WorkerFinished _) <- journaled]
          `shouldBe` [WorkerFinished (SolveFailed "the issue action was terminated")]
        recorded <- decodeChildState descriptor
        -- The outcome the action published, not a kill it never received.
        fmap (.workerStateStatus) recorded
          `shouldBe` Just (WorkerTerminal (SolveFailed "the issue action was terminated"))

  -- Round 20's second blocker. Under a shared connection a revision owns no
  -- process and holds no thread until its provider announces one, so a host
  -- dying between the request and that announcement left a record identical
  -- to a child that never asked for anything — and a replacement reran it,
  -- while the original request was still live on a connection that outlived
  -- its host.
  it "records that it has asked before the request goes out" $
    withRunningHost $ \host -> do
      inside <- newEmptyMVar
      release <- newEmptyMVar
      entered <- newIORef False
      -- Parked inside the begin: the request is on the wire and no thread has
      -- been announced, which is the whole of the window.
      modifyMVar_ host.hostBeginGate . const . pure $ do
        first <- atomicModifyIORef' entered (\seen -> (True, not seen))
        when first (putMVar inside () >> takeMVar release)
      child <- publishChild host "action-1" 594 IssueRevision
      _ <- awaitJust "the begin never reached its gate" (tryReadMVar inside)
      recorded <- decodeChildState child
      -- No longer "never started", so a replacement host settles it rather
      -- than running it a second time.
      fmap (.workerStateStatus) recorded `shouldNotBe` Just WorkerStarting
      neverAdopted child `shouldReturn` False
      putMVar release ()

  -- And the reading that rests on it: a child in that state is recovered,
  -- not rerun, which is what requirement 15 asks for.
  it "settles rather than reruns a child whose start was already sent" $
    withRunningHost $ \host -> do
      descriptor <- childDescriptorNaming host (WorkerId "host-that-died") "action-1" 594 IssueRevision
      now <- getCurrentTime
      LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec {workerCreatedAt = now})
      -- Exactly what the write above leaves: no thread, no provider pid, and
      -- a status that is no longer starting.
      writeChildState
        descriptor
        (runningChildState descriptor now)
          { workerStateStatus = WorkerRunning,
            workerStateLastActivity = "asking for a review thread"
          }
      publishTerminalHost host (WorkerId "host-that-died")
      state <- awaitState descriptor (\recorded -> terminalState recorded.workerStateStatus)
      state.workerStateStatus
        `shouldBe` WorkerTerminal (SolveFailed "the review host that owned this action stopped before it finished; its provider session cannot be resumed")
      -- Nothing was asked for a second time, which is what requirement 15
      -- forbids.
      calls <- providerCalls host
      filter isBeginCall calls `shouldBe` []

  -- Round 17's blocker. Settling takes a child off the live list, and a
  -- dashboard that has not yet seen its terminal event still writes to it.
  -- The poll scans live children and reconciliation answers only commands
  -- that were already claimed, so such a command was owed to nobody for ever
  -- — with the draft it came from already cleared.
  it "refuses a command written to a child it has already settled" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      _ <- awaitThreadFor host 594
      endChild child
      _ <- awaitState child (\state -> terminalState state.workerStateStatus)
      -- Written after the settle, the way a dashboard still holding a live
      -- session writes it.
      late <- commandNumbered 1 child (SendReviewFeedback "look again")
      Right () <- appendReviewCommand child late
      -- Its own acknowledgement, not the termination's: that one settled
      -- first and would satisfy a plain count.
      outcome <- awaitJust "the late command was never answered" $ do
        settled <- readReviewCommandAcknowledgements child
        pure (settledOutcome late.reviewCommandId settled)
      outcome `shouldBe` ReviewCommandRejected "this issue action has already ended"
      -- Nothing was applied, and nothing followed the terminal envelope.
      calls <- providerCalls host
      filter isSendCall calls `shouldBe` []
      journaled <- journalEvents child
      let afterTerminal = drop 1 (dropWhile (\event -> case event of WorkerFinished _ -> False; _ -> True) journaled)
      afterTerminal `shouldBe` []

  -- Round 16's blocker. The connection is spawned inside the begin call and
  -- was recorded on its child only when that call returned. A host dying in
  -- between left a child that owned nothing, so terminating it settled the
  -- action and released its lease with the provider still running — the same
  -- leak as round 12, one window earlier.
  it "owns its connection before the call that started it has returned" $
    withManagedShell "sleep 30" $ \handle -> do
      connection <- managedProcessFor handle
      identity <- identityForProcess handle
      withRunningHost $ \host -> do
        modifyMVar_ host.hostThreadProcesses (const (pure [connection]))
        inside <- newEmptyMVar
        release <- newEmptyMVar
        entered <- newIORef False
        -- Parked inside the begin, after the connection was registered and
        -- before the call returns: the exact window a host's death falls in.
        modifyMVar_ host.hostBeginGate . const . pure $ do
          first <- atomicModifyIORef' entered (\seen -> (True, not seen))
          when first (putMVar inside () >> takeMVar release)
        child <- publishChild host "action-1" 594 IssueRevision
        _ <- awaitJust "the begin never reached its gate" (tryReadMVar inside)
        -- Already the child's, with the call that started it still running.
        recorded <-
          awaitState
            child
            (\state -> identity.processIdentityPid `elem` map (.processIdentityPid) state.workerStateKnownProcesses)
        recorded.workerStateReviewThread `shouldBe` Nothing
        putMVar release ()

  -- Round 15's second blocker, and the cost of round 12's fix not being
  -- carried through every path that rebuilds a child's state. A recovering
  -- host built a fresh state for the child it adopted, discarding the
  -- connection the dead host had recorded on it — moments before settling the
  -- action and releasing its lease, leaving that process running.
  it "keeps a recovered child's recorded connection long enough to end it" $
    withManagedShell "sleep 30" $ \handle -> do
      identity <- identityForProcess handle
      withRunningHost $ \host -> do
        child <- publishStartedChildNaming host (WorkerId "host-that-died") "action-1" 594 IssueRevision
        -- The connection the dead host recorded on this child, which is the
        -- only durable name for it once that host is gone.
        recorded <- decodeChildState child
        forM_ recorded $ \state ->
          writeChildState child state {workerStateKnownProcesses = [identity]}
        publishTerminalHost host (WorkerId "host-that-died")
        settled <- awaitState child (\state -> terminalState state.workerStateStatus)
        settled.workerStateStatus
          `shouldBe` WorkerTerminal (SolveFailed "the review host that owned this action stopped before it finished; its provider session cannot be resumed")
        shouldHaveBeenSwept identity.processIdentityPid "a recovered child's per-thread connection"

  -- Round 12's blocker, at the point the record is made. A per-thread
  -- connection is registered with the host's supervisor, and that record is
  -- exactly as useful as the host: a host that has died is precisely when a
  -- termination has nobody to ask for @providerFinishThread@ and settles the
  -- child from its own durable state alone.
  it "records a per-thread connection on the child, where a host's death cannot reach" $
    withManagedShell "sleep 30" $ \handle -> do
      connection <- managedProcessFor handle
      identity <- identityForProcess handle
      withRunningHost $ \host -> do
        modifyMVar_ host.hostThreadProcesses (const (pure [connection]))
        child <- publishChild host "action-1" 594 IssueRevision
        _ <- awaitThreadFor host 594
        -- On the child's own census, which is what a termination with no host
        -- left to ask reads and ends.
        recorded <-
          awaitState
            child
            (\state -> identity.processIdentityPid `elem` map (.processIdentityPid) state.workerStateKnownProcesses)
        recorded.workerStateProviderPid `shouldBe` Just identity.processIdentityPid

  -- Round 14's second blocker. The connection exists from the moment the
  -- review is begun, and the thread that names it is announced an unbounded
  -- time later. A host that died in between left a child whose own state knew
  -- of no process at all, so terminating it settled the action and left its
  -- provider running.
  it "records a per-thread connection before any thread has been announced" $
    withManagedShell "sleep 30" $ \handle -> do
      connection <- managedProcessFor handle
      identity <- identityForProcess handle
      withRunningHost $ \host -> do
        modifyMVar_ host.hostThreadProcesses (const (pure [connection]))
        child <- publishChild host "action-1" 594 IssueRevision
        -- Only the begin has happened: no thread has been announced, and the
        -- child's own state already names the process.
        _ <- awaitCallsFor host 1 isBeginCall
        recorded <-
          awaitState
            child
            (\state -> identity.processIdentityPid `elem` map (.processIdentityPid) state.workerStateKnownProcesses)
        recorded.workerStateReviewThread `shouldBe` Nothing

  -- And the other shape, which must not record: one process serves every
  -- thread, so a child holding it would end all of them when it was
  -- terminated.
  it "records no connection on a child whose backend shares one" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      _ <- awaitThreadFor host 594
      recorded <- awaitState child (\state -> state.workerStateReviewThread /= Nothing)
      recorded.workerStateKnownProcesses `shouldBe` []
      recorded.workerStateProviderPid `shouldBe` Nothing

  -- Round 11's first blocker. Applying a command and recording that it was
  -- applied are two steps, and a settle between them closes the journal: the
  -- provider has the message, the acknowledgement says it was accepted, and
  -- the transcript a replay reads has no trace of it.
  it "records a delivery that a completing turn settles the child during" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      thread <- awaitThreadFor host 594
      deliver host (ReviewTurnStarted thread "turn-1")
      _ <- awaitState child (\recorded -> recorded.workerStateReviewTurn == Just "turn-1")
      inFlight <- newEmptyMVar
      release <- newEmptyMVar
      entered <- newIORef False
      -- The send is held open, so the delivery is genuinely mid-flight when
      -- the turn completes rather than racing it and usually winning.
      modifyMVar_ host.hostSendGate . const . pure $ do
        first <- atomicModifyIORef' entered (\seen -> (True, not seen))
        when first (putMVar inFlight () >> takeMVar release)
      command <- commandNumbered 1 child (SendReviewFeedback "look again")
      Right () <- appendReviewCommand child command
      _ <- awaitJust "the delivery never reached the provider" (tryReadMVar inFlight)
      -- Settles the child, on the client's event thread, while the send above
      -- has not returned.
      settled <- newEmptyMVar
      void . forkIO $ deliver host (ReviewTurnCompleted thread TurnSucceeded Nothing Nothing) >> putMVar settled ()
      -- The handler clears the turn before it settles, so this proves the
      -- settle has reached the step this is ordered against — in both the
      -- ordered and the unordered arrangement, which is what lets one test
      -- tell them apart.
      _ <- awaitState child (\recorded -> recorded.workerStateReviewTurn == Nothing)
      -- Then every chance to get ahead. Ordered, the settle spends this
      -- blocked and the delivery finishes first; unordered, it is far more
      -- than enough to write the terminal envelope and close the journal out
      -- from under the send still waiting below.
      threadDelay 200000
      putMVar release ()
      _ <- awaitMaybe (tryTakeMVar settled)
      _ <- awaitState child (\recorded -> terminalState recorded.workerStateStatus)
      journaled <- journalEvents child
      -- Present at all, which is what a dropped write costs, and before the
      -- terminal envelope, which is where a replay stops reading.
      let offered = [event | event@(WorkerReviewInput identifier _ _) <- journaled, identifier == command.reviewCommandId]
          beforeTerminal = takeWhile (\event -> case event of WorkerFinished _ -> False; _ -> True) journaled
      offered `shouldBe` [WorkerReviewInput command.reviewCommandId "look again" Nothing]
      [event | event@(WorkerReviewInput identifier _ _) <- beforeTerminal, identifier == command.reviewCommandId]
        `shouldBe` offered

  -- Round 11's second blocker. Adopting on the old name and calling the
  -- rewrite retryable could not work on its own terms: an adopted child is in
  -- the host's map from that moment and every later scan skips a child it
  -- already holds, so the retry never happened and discovery and the
  -- collection pass went on reading a dead host as the owner.
  it "refuses an adoption whose ownership will not persist, and retries it" $
    withRunningHost $ \host -> do
      descriptor <- childDescriptorNaming host (WorkerId "host-that-died") "action-1" 594 IssueRevision
      -- 'writePrivateJson' writes its temporary beside the target and
      -- renames, so a directory in that name's place is a write that fails
      -- while leaving the specification itself perfectly readable — which is
      -- what makes the child discoverable and un-rehomable at once.
      createDirectoryIfMissing True (descriptor.workerDescriptorSpecPath <> ".tmp")
      child <- publishChildNaming host (WorkerId "host-that-died") "action-1" 594 IssueRevision
      publishTerminalHost host (WorkerId "host-that-died")
      _ <- awaitJust "the host never reported the ownership it could not record" $ do
        emitted <- readMVar host.hostEmitted
        pure (if any refusesOwnership emitted then Just () else Nothing)
      -- Not adopted: nothing was begun, and its specification still names the
      -- host that died rather than two records disagreeing.
      calls <- providerCalls host
      filter isBeginCall calls `shouldBe` []
      owner <- recordedOwnerOf child
      owner `shouldBe` Just (WorkerId "host-that-died")
      -- And it is a candidate again rather than held: clearing the obstacle
      -- lets the very next scan adopt it, which is the retry the old comment
      -- promised and could not deliver.
      removeDirectory (descriptor.workerDescriptorSpecPath <> ".tmp")
      _ <- awaitCallsFor host 1 isBeginCall
      adopted <- recordedOwnerOf child
      adopted `shouldBe` Just hostIdUnderTest

  -- Round 11's third blocker. A recovering host opened a fresh log and
  -- pointed the child's state at it, leaving the evidence the child had
  -- actually produced on disk under a name carrying an issue number and a
  -- timestamp but no action id — addressable by nothing, and unreachable by
  -- the reattachment it exists for.
  it "continues a recovered child's own raw log rather than starting another" $
    withRunningHost $ \host -> do
      inherited <- transcriptPathFor host.hostRepository "inherited-action.jsonl"
      writeFile inherited "{\"stream\":\"provider\",\"raw\":\"before the host died\"}\n"
      child <- publishStartedChildNaming host (WorkerId "host-that-died") "action-1" 594 IssueRevision
      updateChildLogPath child inherited
      publishTerminalHost host (WorkerId "host-that-died")
      state <- awaitState child (\recorded -> terminalState recorded.workerStateStatus)
      -- The same log, still named by the child's own durable state.
      state.workerStateLogPath `shouldBe` Just inherited
      -- And continued rather than truncated: what the dead host wrote is
      -- still there, with this host's own adoption line after it.
      -- Through a POSIX descriptor: the host still holds this log open for
      -- writing, and GHC locks a file per process.
      contents <- readLogBytes inherited
      contents `shouldContain` "before the host died"
      contents `shouldContain` "action-started"

  -- Round 10's blocker. A launch cannot make host selection and child
  -- admission one step, and round 7's answer — wait for durable evidence of
  -- adoption — left the exit itself unordered: between the scan that finds no
  -- children and the supervisor recording the host terminal, a child written
  -- by a launch is missed by that scan while still reading the host as live.
  -- The host now writes a handoff marker before that scan, so a child written
  -- before the marker is seen by it.
  it "adopts a child written into its handoff window rather than exiting" $
    withRunningHost $ \host -> do
      arrived <- newEmptyMVar
      release <- newEmptyMVar
      opened <- newIORef False
      -- Inside the window: the marker is up and the scan the exit rests on
      -- has not run. This is the ordering no test can produce from outside.
      -- The window is held open until the test has looked at it, because the
      -- host closes it the moment this returns.
      modifyMVar_ host.hostHandoff . const . pure $ do
        first <- atomicModifyIORef' opened (\seen -> (True, not seen))
        when first $ do
          void (publishChild host "action-late" 594 IssueRevision)
          putMVar arrived ()
          takeMVar release
      -- The marker is up while the window is open, which is what makes a
      -- launch reading liveness in it ensure another host rather than hand
      -- its child to this one.
      _ <- awaitJust "the host never opened a handoff window" (tryReadMVar arrived)
      marked <- doesFileExist host.hostRecords.workerDescriptorHandoffPath
      marked `shouldBe` True
      putMVar release ()
      -- Adopted rather than stranded, and the marker comes back down because
      -- the exit is off.
      _ <- awaitCallsFor host 1 isBeginCall
      cleared <- awaitJust "the host never cleared its handoff marker" $ do
        present <- doesFileExist host.hostRecords.workerDescriptorHandoffPath
        pure (if present then Nothing else Just ())
      cleared `shouldBe` ()

  -- And the same command with no host left at all: its own reconciliation
  -- refuses it rather than leaving it owed to a child nothing will read
  -- again.
  it "refuses a command written to an ended child whose host has gone too" $
    withTemporaryCacheRoot $ \temporaryRoot ->
      withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
        now <- getCurrentTime
        descriptor <-
          descriptorForSpec
            ( specFor
                (WorkerId "ended-action")
                (IssueActionWorkerTaskKind (IssueActionWorkerTask 594 IssueRevision (WorkerId "host-that-died") IssueOriginClaude))
            )
        createDirectoryIfMissing True (takeDirectory descriptor.workerDescriptorSpecPath)
        LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec)
        writeChildState descriptor (runningChildState descriptor now) {workerStateStatus = WorkerTerminal SolveCompleted}
        seedJournal descriptor [WorkerFinished SolveCompleted]
        late <- commandNumbered 1 descriptor (SendReviewFeedback "look again")
        Right () <- appendReviewCommand descriptor late
        reconcileIssueActionClaims descriptor
        settled <- readReviewCommandAcknowledgements descriptor
        settledOutcome late.reviewCommandId settled
          `shouldBe` Just (ReviewCommandRejected "this issue action has already ended")
        -- And the journal is untouched: its terminal envelope is still last.
        journaled <- journalEvents descriptor
        journaled `shouldBe` [WorkerFinished SolveCompleted]

  -- Round 9's second blocker, and the path no host runs. A dashboard that
  -- reattaches after the host died monitors the child directly, and generic
  -- stale-worker recovery is what terminalizes it — no replacement host
  -- adopts it, so the adoption-time reconciliation above never runs. Without
  -- its own reconciliation this path writes the terminal envelope over a
  -- standing claim, and the message the dashboard cleared from its input line
  -- is gone with no account of it anywhere.
  it "settles a standing claim when the reattached monitor recovers the child" $
    withTemporaryCacheRoot $ \temporaryRoot ->
      withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
        now <- getCurrentTime
        descriptor <-
          descriptorForSpec
            ( specFor
                (WorkerId "orphaned-action")
                (IssueActionWorkerTaskKind (IssueActionWorkerTask 594 IssueRevision (WorkerId "host-that-died") IssueOriginClaude))
            )
        createDirectoryIfMissing True (takeDirectory descriptor.workerDescriptorSpecPath)
        LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec)
        writeChildState
          descriptor
          (runningChildState descriptor (addUTCTime (-600) now))
            { workerStateWorkerIdentity = Just departedIdentity
            }
        standing <- commandNumbered 1 descriptor (SendReviewFeedback "look again")
        Right () <- appendReviewCommand descriptor standing
        claim <- acknowledged standing ReviewCommandClaimed
        Right () <- acknowledgeReviewCommand descriptor claim
        emitted <- newMVar []
        -- No identity is present, which is the only thing that reads as dead.
        recovered <-
          recoverIfWorkerStoppedWith
            (pure (Right []))
            descriptor
            (\_ _ event -> modifyMVar_ emitted (pure . (<> [event])))
            0
        recovered `shouldBe` True
        settled <- readReviewCommandAcknowledgements descriptor
        settledOutcome standing.reviewCommandId settled `shouldBe` Just ReviewCommandOutcomeUnknown
        journaled <- readMVar emitted
        let offered = WorkerReviewInput standing.reviewCommandId "look again" (Just "the review host stopped before this command's result was observed")
        journaled `shouldContain` [offered]
        -- Round 19's first blocker. The terminal record went only to the sink
        -- attached now, so a dashboard reattaching later replayed an action
        -- that never ended — and the journal stayed open to the appends the
        -- envelope exists to stop.
        durable <- journalEvents descriptor
        [event | event@(WorkerFinished _) <- durable]
          `shouldBe` [WorkerFinished (SolveFailed "persistent worker stopped unexpectedly; its provider process group was terminated")]
        -- Before the terminal envelope, so a monitor that stops on the
        -- terminal record has still seen it.
        let beforeTheOffer = takeWhile (/= offered) journaled
        [event | event@(WorkerFinished _) <- beforeTheOffer] `shouldBe` []

  -- Round 9's first blocker. A canonical stage's whole work is
  -- @approve_issues.py@ and it has no embedded provider session at all
  -- (requirement 5), so requiring one would make it fail on an install whose
  -- embedded backend is unavailable — for a component its own preflight never
  -- asks about.
  it "runs a canonical stage without ever starting an embedded client" $
    withRunningHostNoProvider $ \host -> do
      child <- publishChild host "action-1" 594 InitialReview
      _ <- awaitCallsFor host 1 isCanonicalCall
      putMVar host.hostCanonicalProcess unsignallableProcessGroup
      putMVar host.hostCanonicalFinished ()
      state <- awaitState child (\recorded -> terminalState recorded.workerStateStatus)
      state.workerStateStatus `shouldBe` WorkerTerminal SolveCompleted
      -- The gate published a verdict, and no client was ever asked for.
      journaled <- journalEvents child
      journaled `shouldContain` [WorkerCanonicalReviewFinished InitialReview (Right canonicalReviewResultForFake)]
      calls <- providerCalls host
      filter (== StartProvider) calls `shouldBe` []

  -- And a revision on the same host does start one, so the laziness is real
  -- rather than the client never being needed.
  it "starts the client only when a revision needs one" $
    withRunningHost $ \host -> do
      beforehand <- providerCalls host
      filter (== StartProvider) beforehand `shouldBe` []
      _ <- publishChild host "action-1" 594 IssueRevision
      _ <- awaitCallsFor host 1 isBeginCall
      afterwards <- providerCalls host
      filter (== StartProvider) afterwards `shouldBe` [StartProvider]

  -- Round 8's second blocker. A termination can settle a canonical child
  -- while its gate is still running, and the gate's result would then be
  -- appended after the child's terminal envelope — invisible to a monitor
  -- that stopped there, replayed by one that reattaches, and able to replace
  -- a killed session with an approval. Nothing follows the terminal envelope.
  it "keeps a canonical result that lands after termination out of the journal" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 InitialReview
      _ <- awaitCallsFor host 1 isCanonicalCall
      termination <- commandNumbered 1 child TerminateIssueAction
      Right () <- appendReviewCommand child termination
      _ <- awaitState child (\recorded -> terminalState recorded.workerStateStatus)
      -- The gate reports its process and then its verdict, both too late.
      putMVar host.hostCanonicalProcess unsignallableProcessGroup
      -- Give the stage every chance to append after the terminal envelope.
      threadDelay 300000
      journaled <- journalEvents child
      let terminalAt = findIndex (\event -> case event of WorkerFinished _ -> True; _ -> False) journaled
      -- The terminal envelope is the last record, whatever else happened.
      fmap (+ 1) terminalAt `shouldBe` Just (length journaled)
      journaled
        `shouldSatisfy` all (\event -> case event of WorkerCanonicalReviewFinished _ _ -> False; _ -> True)

  -- Round 7's first blocker. A termination settles the child, and settling
  -- writes its terminal envelope; a monitor stops replaying there, so an
  -- input record written afterwards is either never seen or, if it is, moves
  -- a settled session back to running. The line goes first.
  it "journals a termination's own line before the child's terminal envelope" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      _ <- awaitThreadFor host 594
      termination <- commandNumbered 1 child TerminateIssueAction
      Right () <- appendReviewCommand child termination
      _ <- awaitState child (\recorded -> terminalState recorded.workerStateStatus)
      journaled <- journalEvents child
      let inputAt = findIndex (\event -> case event of WorkerReviewInput identifier _ _ -> identifier == termination.reviewCommandId; _ -> False) journaled
          terminalAt = findIndex (\event -> case event of WorkerFinished _ -> True; _ -> False) journaled
      (inputAt, terminalAt) `shouldSatisfy` \(recorded, ended) -> recorded < ended && recorded /= Nothing

  -- Round 6's first blocker. A shared-process connection exists by the time
  -- the client is started, so registering it at the host's first poll leaves
  -- an interval in which a host killed uncleanly loses the only durable
  -- record of a process it spawned. The client registers each connection as
  -- it creates one, which is before the host has even entered its loop.
  it "has already registered its client's connection by the time it is used" $
    withRunningHost $ \host -> do
      _ <- publishChild host "action-1" 594 IssueRevision
      -- The client registers during creation, which happens before the review
      -- it was started for is begun — so by the time the begin call is
      -- recorded, the registration is already there rather than waiting on a
      -- later poll.
      _ <- awaitCallsFor host 1 isBeginCall
      registered <- readMVar host.hostRegistered
      pids <- mapM managedProcessPid registered
      pids `shouldBe` [Just 2147483647]

  -- Round 6's second blocker. Reading the settle claim before installing the
  -- canonical subprocess is a read a termination can win behind: the settle
  -- finds no process to kill, and the callback then records one nothing will
  -- ever settle. Installing first makes the two orderings exhaustive, and the
  -- loser of the race ends the process where it stands.
  it "ends a canonical subprocess reported after its child was settled" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 InitialReview
      -- The gate has started, so the interlock and preflight are behind us and
      -- the child is live.
      started <- awaitCallsFor host 1 isCanonicalCall
      length (filter isCanonicalCall started) `shouldBe` 1
      -- Settled while the gate is still running, which is the ordering the
      -- race produces.
      termination <- commandNumbered 1 child TerminateIssueAction
      Right () <- appendReviewCommand child termination
      _ <- awaitState child (\recorded -> terminalState recorded.workerStateStatus)
      -- Only now does the gate report its subprocess.
      putMVar host.hostCanonicalProcess unsignallableProcessGroup
      -- The host records that the late process was ended rather than
      -- installed onto an action nothing would settle again. On the host,
      -- because the child's journal ended at its terminal envelope.
      _ <- awaitHostDiagnostic host "the canonical gate started after this action had already been settled"
      pure ()

  -- Round 6's third blocker. Retirement moves a settled child between two
  -- separate cells, and an announcement arriving in the handoff window used
  -- to find neither — logging to the host and leaving the thread unowned.
  -- Retiring before removing the live entry makes the window show "both".
  it "closes a late thread announced while its child is being retired" $
    withRunningHost $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      _ <- awaitCallsFor host 1 isBeginCall
      -- Settle and announce concurrently, so the announcement lands wherever
      -- the retirement happens to be. Whichever ordering the run produces,
      -- the thread must be closed.
      let late = ReviewThreadId (ConnectionId 1) "thread-racing-retirement"
      termination <- commandNumbered 1 child TerminateIssueAction
      Right () <- appendReviewCommand child termination
      void . forkIO $ deliver host (ReviewThreadCreated 594 late)
      _ <- awaitState child (\recorded -> terminalState recorded.workerStateStatus)
      awaitCalls host 1 isFinishCall
      calls <- providerCalls host
      filter isFinishCall calls `shouldBe` [FinishThread late]

  -- Round 5's second blocker. A delivery journals what it delivered before
  -- acknowledging it, so an acknowledgement write that fails leaves the
  -- ledger holding only the claim while the journal already holds the answer.
  -- Reporting that command as unobserved would tell the operator a message
  -- that did reach the provider never did, and hand back text already sent.
  it "recovers a delivered command's outcome from the journal, not as unknown" $
    withRunningHost $ \host -> do
      descriptor <- childDescriptorFor host "action-1" 594 IssueRevision
      delivered <- commandNumbered 1 descriptor (SendReviewFeedback "look again")
      Right () <- appendReviewCommand descriptor delivered
      claim <- acknowledged delivered ReviewCommandClaimed
      Right () <- acknowledgeReviewCommand descriptor claim
      -- The journal record a completed delivery leaves, with the final
      -- acknowledgement missing exactly as a failed append leaves it.
      seedJournal descriptor [WorkerReviewInput delivered.reviewCommandId "look again" Nothing]
      child <- publishChild host "action-1" 594 IssueRevision
      _ <- awaitCallsFor host 1 isBeginCall
      settled <- awaitAcknowledgements child 2
      settledOutcome delivered.reviewCommandId settled `shouldBe` Just ReviewCommandAccepted
      -- Still never re-applied, and never reported back as undelivered.
      calls <- providerCalls host
      filter isSendCall calls `shouldBe` []
      journaled <- journalEvents child
      journaled
        `shouldNotContain` [WorkerReviewInput delivered.reviewCommandId "look again" (Just "the review host stopped before this command's result was observed")]

  -- And a rejection recovers as the rejection it was, not as unknown.
  it "recovers a refused command's own reason from the journal" $
    withRunningHost $ \host -> do
      descriptor <- childDescriptorFor host "action-1" 594 IssueRevision
      refused <- commandNumbered 1 descriptor (SendReviewFeedback "look again")
      Right () <- appendReviewCommand descriptor refused
      claim <- acknowledged refused ReviewCommandClaimed
      Right () <- acknowledgeReviewCommand descriptor claim
      seedJournal descriptor [WorkerReviewInput refused.reviewCommandId "look again" (Just "that turn has already ended")]
      child <- publishChild host "action-1" 594 IssueRevision
      _ <- awaitCallsFor host 1 isBeginCall
      settled <- awaitAcknowledgements child 2
      settledOutcome refused.reviewCommandId settled
        `shouldBe` Just (ReviewCommandRejected "that turn has already ended")

  -- The host is not a provider turn, and must not record itself as one: a
  -- recorded provider pid with no recorded identity is what every termination
  -- path reads as "started, but unverifiable", which leaves a host kill
  -- recording a pending termination it can never complete. What it does
  -- record is its client's own processes, through the supervisor's
  -- registration, so they are identified, censused, and killable.
  it "registers its client's processes rather than claiming to be one" $
    withRunningHost $ \host -> do
      _ <- publishChild host "action-1" 594 IssueRevision
      _ <- awaitThreadFor host 594
      registered <- awaitJust "the host registered no provider process" $ do
        held <- readMVar host.hostRegistered
        pure (if null held then Nothing else Just held)
      pids <- mapM managedProcessPid registered
      pids `shouldBe` [Just 2147483647]
      -- Registered once, however many polls have run.
      readMVar host.hostRegistered >>= (\held -> length held `shouldBe` 1)

  -- A client that will not start is the backend's own failure, and it belongs
  -- to the revision that needed one. The host itself is unaffected: it has
  -- canonical stages it can still serve, and ending it for a component they
  -- never use is the dependency requirement 5 rules out.
  it "fails only the revision that needed a client it could not start" $
    withRunningHostNoProvider $ \host -> do
      child <- publishChild host "action-1" 594 IssueRevision
      state <- awaitState child (\recorded -> terminalState recorded.workerStateStatus)
      state.workerStateStatus
        `shouldBe` WorkerTerminal (SolveFailed "no embedded review backend on this install")
      journaled <- journalEvents child
      journaled
        `shouldContain` [WorkerReviewEvent (ReviewStartFailed 594 "no embedded review backend on this install")]

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

  -- Round 3's third blocker. The ledger deduplicates by command id, so two
  -- ids that collide are one command: the second input is silently discarded.
  --
  -- The count is chosen so this cannot pass vacuously. A timestamp and a pid
  -- were the whole of an id before, and the clock is nowhere near fine enough
  -- to separate rapid calls: measured on this platform, 2000 successive
  -- 'getCurrentTime' readings produced 180 distinct values. At 512 the old
  -- generator collides many times over, so a green run here is the sequence
  -- doing the work rather than the clock happening to.
  it "allocates a distinct identifier for every command, however fast" $ do
    identifiers <- mapM (const newReviewCommandId) [1 .. (512 :: Int)]
    length (nub identifiers) `shouldBe` 512

  -- And the ledger really is keyed by it, so a collision would lose an input.
  it "deduplicates by that identifier, so a collision would discard an input" $
    withIssueAction $ \descriptor -> do
      first <- commandNumbered 1 descriptor (SendReviewFeedback "one")
      let collided = first {reviewCommandPayload = SendReviewFeedback "two"}
      Right () <- appendReviewCommand descriptor first
      Right () <- appendReviewCommand descriptor collided
      owed <- owedBy descriptor
      map (.reviewCommandPayload) owed `shouldBe` [SendReviewFeedback "one"]

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

  -- The category names a diagnostic; the display names what the person
  -- actually submitted, and the two must not be confused, because a rejected
  -- or unobserved command has its display text offered back to the input line
  -- and "feedback" is not something anyone typed.
  it "shows what was submitted rather than the category it falls in" $
    map reviewCommandDisplay everyPayload
      `shouldBe` [ "a",
                   "Allowed similar actions for this review session",
                   "feedback",
                   "steer",
                   "turn interrupt",
                   -- Not the category word beside it: this line is what a
                   -- person reads in the transcript, live and on replay
                   -- alike, so it says what they did rather than what kind of
                   -- command it was.
                   "end this action"
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

  -- Round 12's blocker, end to end. The child is settled from its own
  -- durable state because there is no host to ask, so what that state names
  -- is the whole of what gets ended.
  it "ends the connection its dead host's child was still holding" $
    withManagedShell "sleep 30" $ \handle ->
      withIssueAction $ \descriptor -> do
        now <- getCurrentTime
        identity <- identityForProcess handle
        writeChildState
          descriptor
          (runningChildState descriptor now)
            { -- Provably gone, which is the only thing that settles a child
              -- here rather than queueing a command its host would read.
              workerStateWorkerIdentity = Just departedIdentity,
              workerStateKnownProcesses = [identity]
            }
        terminateWorker descriptor
        readReviewCommands descriptor `shouldReturn` []
        state <- decodeChildState descriptor
        fmap (.workerStateStatus) state `shouldBe` Just (WorkerTerminal (SolveFailed "killed by user"))
        shouldHaveBeenSwept identity.processIdentityPid "a per-thread review connection"
        -- Round 18's second blocker. A dashboard reattaching to this action
        -- replays its journal and nothing else, so a terminal state with no
        -- envelope in that journal leaves it reading an action that never
        -- ends — and leaves the journal open to the appends the envelope
        -- exists to stop.
        journalEvents descriptor `shouldReturn` [WorkerFinished (SolveFailed "killed by user")]

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
              WorkerReviewInput (ReviewCommandId "command-1") "yes" Nothing,
              WorkerReviewInput (ReviewCommandId "command-2") "no" (Just "that review request is no longer pending"),
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

  -- The child is inside its own retention window here, which is what makes
  -- this the rule it says it is: a child past that window is collected by its
  -- own gate whether or not anyone acknowledged it, so a host measured
  -- against one would be answering a question about a record that no longer
  -- exists.
  it "keeps them while a terminal child is still unacknowledged" $
    withRetainedChildTopology (WorkerTerminal SolveCompleted) (WorkerTerminal SolveCompleted) $ \host child -> do
      acknowledgeWorker host
      collectWorkerCache testRepository
      doesFileExist child.workerDescriptorSpecPath `shouldReturn` True
      doesFileExist host.workerDescriptorSpecPath `shouldReturn` True

  -- The pass visits records in the order the filesystem hands them over, and
  -- 'removeWorkerArtifacts' clears a worker's state before its specification
  -- — so a host collected earlier in the same pass is still in this pass's
  -- history with its state already gone. Reading that as "cannot prove the
  -- host is gone" kept every child of a host that had just been collected,
  -- which is why this suite passed on one filesystem's ordering and not
  -- another's.
  it "collects a child whose host was collected earlier in the same pass" $
    withHostTopology (WorkerTerminal SolveCompleted) (WorkerTerminal SolveCompleted) $ \host child -> do
      acknowledgeWorker child
      acknowledgeWorker host
      -- Exactly what the host's own collection leaves behind on its way to
      -- removing the specification last.
      removeFile host.workerDescriptorStatePath
      collectWorkerCache testRepository
      doesFileExist child.workerDescriptorSpecPath `shouldReturn` False

  -- And the same in the other direction, since a host's retention reads its
  -- children's records the same way.
  it "collects a host whose child was collected earlier in the same pass" $
    withHostTopology (WorkerTerminal SolveCompleted) (WorkerTerminal SolveCompleted) $ \host child -> do
      acknowledgeWorker child
      acknowledgeWorker host
      removeFile child.workerDescriptorStatePath
      collectWorkerCache testRepository
      doesFileExist host.workerDescriptorSpecPath `shouldReturn` False

  -- The fail-closed reading this rests on is still there: a record that is
  -- present and will not decode is not proof of anything, and keeps its
  -- counterpart.
  it "keeps a child whose host record is present but unreadable" $
    withHostTopology (WorkerTerminal SolveCompleted) (WorkerTerminal SolveCompleted) $ \host child -> do
      acknowledgeWorker child
      acknowledgeWorker host
      writeFile host.workerDescriptorStatePath "{"
      collectWorkerCache testRepository
      doesFileExist child.workerDescriptorSpecPath `shouldReturn` True

  -- The command ledger is a companion artifact like the journal, so a
  -- collection that left it behind would accumulate a person's typed guidance
  -- in the cache forever.
  it "collects a child's command ledger with the rest of its records" $
    withHostTopology (WorkerTerminal SolveCompleted) (WorkerTerminal SolveCompleted) $ \host child -> do
      command <- commandFor child (SendReviewFeedback "look again")
      Right () <- appendReviewCommand child command
      acknowledgeWorker child
      acknowledgeWorker host
      -- Derived for every worker even though only a host writes one, on the
      -- same reasoning as the ledger beside it: a record a collection pass
      -- does not name is one nothing ever removes.
      writeFile child.workerDescriptorHandoffPath "handing off\n"
      collectWorkerCache testRepository
      doesFileExist child.workerDescriptorCommandPath `shouldReturn` False
      doesFileExist child.workerDescriptorHandoffPath `shouldReturn` False

-- ---------------------------------------------------------------------------
-- Durable-record compatibility
-- ---------------------------------------------------------------------------

-- | Round 5's first blocker: a host is exempt from the deadline watchdog, but
-- three other places still deferred to that watchdog once the deadline
-- elapsed — and every deferral waits on a handshake only the watchdog fills.
hostDeadlineSpec :: Spec
hostDeadlineSpec = describe "a host past the ordinary worker deadline" $ do
  it "gives a host no deadline at all, and every other task one" $ do
    let hostSpec = specFor (WorkerId "host-1") (IssueHostWorkerTaskKind (IssueHostWorkerTask "coghex/kanban"))
        solveSpec = specFor (WorkerId "solve-1") (SolveWorkerTaskKind legacySolveTask)
        actionSpec = specFor (WorkerId "action-1") (IssueActionWorkerTaskKind sampleAction)
    workerDeadlineAt hostSpec `shouldBe` Nothing
    workerDeadlineAt solveSpec `shouldNotBe` Nothing
    workerDeadlineAt actionSpec `shouldNotBe` Nothing

  -- The whole point: however long ago the host was created, its deadline has
  -- never passed, so nothing stands aside for a watchdog that does not exist.
  it "never reports a host's deadline as passed, however old it is" $ do
    now <- getCurrentTime
    let ancient = addUTCTime (negate (365 * 24 * 60 * 60)) now
        hostSpec = (specFor (WorkerId "host-1") (IssueHostWorkerTaskKind (IssueHostWorkerTask "coghex/kanban"))) {workerCreatedAt = ancient}
        solveSpec = (specFor (WorkerId "solve-1") (SolveWorkerTaskKind legacySolveTask)) {workerCreatedAt = ancient}
    workerDeadlinePassed hostSpec now `shouldBe` False
    workerDeadlinePassed solveSpec now `shouldBe` True

  -- And the behaviour that pure rule exists for, through the real supervisor:
  -- an aged host whose task returns must complete and release its lease, not
  -- block forever holding this repository's host lease against every later
  -- host.
  it "exits and releases its lease when its task returns long past that deadline" $
    withTemporaryCacheRoot $ \temporaryRoot -> do
      now <- getCurrentTime
      let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
          longAgo = addUTCTime (-3600) now
          hostSpec =
            (specFor (WorkerId "issue-host-aged") (IssueHostWorkerTaskKind (IssueHostWorkerTask "coghex/kanban")))
              { workerRepository = repository,
                workerCreatedAt = longAgo,
                workerMaxRuntimeSeconds = 60
              }
          workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
          specPath = workerRoot </> "issue-host-aged.spec.json"
      createDirectoryIfMissing True repository.repositoryRoot
      createDirectoryIfMissing True workerRoot
      LazyByteString.writeFile specPath (encode hostSpec)
      withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
        descriptor <- descriptorForSpec hostSpec
        acquireWorkerLease descriptor `shouldReturn` Right ()
        -- The host's own loop, standing in for one that has just gone idle.
        let finishInstantly _spec _aggregator _rememberProvider emit = emit (WorkerFinished SolveCompleted)
        result <- timeout 5000000 (runWorkerWithTask readProcessSnapshot finishInstantly specPath)
        result `shouldBe` Just (Right ())
        -- Released, so a later host can take it. Before this fix the call
        -- above never returned at all.
        acquireWorkerLease descriptor `shouldReturn` Right ()

-- | Round 3's second blocker: a host that died the instant after persisting a
-- fresh running state leaves a record that reads as live forever, and a child
-- assigned to it can never be adopted.
hostLivenessSpec :: Spec
hostLivenessSpec = describe "which host a child is assigned to" $ do
  -- Round 10's blocker, at the point it was reported. Ensuring a host is not
  -- evidence that anything took the child on: the host ensuring hands back
  -- can be one already inside its own handoff, and a host it starts still has
  -- to come up and poll. Returning at the ensure is what leaves an action
  -- leased, starting, and run by nobody while its launch reports success.
  it "keeps waiting after ensuring a host, until something has actually adopted" $
    withTemporaryCacheRoot $ \temporaryRoot ->
      withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
        directory <- workerDirectory testRepository
        createDirectoryIfMissing True directory
        descriptor <-
          descriptorForSpec
            (specFor (WorkerId "action-1") (IssueActionWorkerTaskKind (IssueActionWorkerTask 594 IssueRevision (WorkerId "host-1") IssueOriginClaude)))
        LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec)
        ensured <- newMVar (0 :: Int)
        -- Adoption lands part-way through, the way a host that had to start
        -- first would deliver it — well after the first ensure returned.
        let ensureHost = do
              count <- modifyMVar ensured (\held -> pure (held + 1, held + 1))
              when (count >= 3) (seedJournal descriptor [WorkerDiagnostic "adopted"])
              pure (Right (WorkerId "host-2"))
        confirmIssueActionAdoptedWith 40 1000 ensureHost testRepository descriptor
          `shouldReturn` Right ()
        attempts <- readMVar ensured
        attempts `shouldSatisfy` (>= 3)

  -- And the disposition when nothing ever does. Reporting success here is
  -- what the round found; the launch that reads this failure removes the
  -- child's records and releases its lease, so no host started later runs an
  -- action whose launch was refused.
  it "reports a failure when nothing adopts the child at all" $
    withTemporaryCacheRoot $ \temporaryRoot ->
      withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
        directory <- workerDirectory testRepository
        createDirectoryIfMissing True directory
        descriptor <-
          descriptorForSpec
            (specFor (WorkerId "action-1") (IssueActionWorkerTaskKind (IssueActionWorkerTask 594 IssueRevision (WorkerId "host-1") IssueOriginClaude)))
        LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec)
        confirmIssueActionAdoptedWith 5 1000 (pure (Right (WorkerId "host-2"))) testRepository descriptor
          `shouldReturn` Left "no review host took this action on"

  it "reports a host whose recorded identity is gone as no live host at all" $
    withTemporaryCacheRoot $ \temporaryRoot ->
      withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
        directory <- workerDirectory testRepository
        createDirectoryIfMissing True directory
        descriptor <- descriptorForSpec (specFor (WorkerId "host-1") (IssueHostWorkerTaskKind (IssueHostWorkerTask "coghex/kanban")))
        LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec)
        now <- getCurrentTime
        -- Running, freshly heartbeaten, and dead: exactly what a host killed
        -- straight after persisting its state leaves behind.
        writeChildState
          descriptor
          (runningChildState descriptor now) {workerStateWorkerIdentity = Just departedIdentity}
        liveIssueReviewHost testRepository `shouldReturn` Nothing

  -- The other direction, so this is not passing by reporting every host dead.
  -- Identity 1 is init, which is always present.
  it "reports a host whose recorded identity is present as live" $
    withTemporaryCacheRoot $ \temporaryRoot ->
      withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
        directory <- workerDirectory testRepository
        createDirectoryIfMissing True directory
        descriptor <- descriptorForSpec (specFor (WorkerId "host-1") (IssueHostWorkerTaskKind (IssueHostWorkerTask "coghex/kanban")))
        LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec)
        now <- getCurrentTime
        present <- initIdentity
        writeChildState descriptor (runningChildState descriptor now) {workerStateWorkerIdentity = present}
        found <- liveIssueReviewHost testRepository
        fmap ((.workerId) . (.workerDescriptorSpec)) found `shouldBe` Just (WorkerId "host-1")

  -- Round 10's blocker, from the launch's side. A host inside its handoff
  -- window is alive by every process measure and is still not one to hand a
  -- new child to, because the scan its exit rests on has already been
  -- ordered against this read.
  it "reports a host that has begun handing off as no host to launch into" $
    withTemporaryCacheRoot $ \temporaryRoot ->
      withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
        directory <- workerDirectory testRepository
        createDirectoryIfMissing True directory
        descriptor <- descriptorForSpec (specFor (WorkerId "host-1") (IssueHostWorkerTaskKind (IssueHostWorkerTask "coghex/kanban")))
        LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec)
        now <- getCurrentTime
        present <- initIdentity
        writeChildState descriptor (runningChildState descriptor now) {workerStateWorkerIdentity = present}
        -- Live without the marker, which is what makes the marker the thing
        -- being tested rather than the state beside it.
        found <- liveIssueReviewHost testRepository
        fmap ((.workerId) . (.workerDescriptorSpec)) found `shouldBe` Just (WorkerId "host-1")
        writeFile descriptor.workerDescriptorHandoffPath "handing off\n"
        liveIssueReviewHost testRepository `shouldReturn` Nothing

  -- And the other question the marker must not answer. "May a new child go
  -- here" and "has this child's host gone" are different, and reading the
  -- marker as death in the second would let a passing host take the children
  -- of one that is merely on its way out — which is the theft requirement 16
  -- forbids.
  it "keeps a handing-off host's own children out of another host's reach" $
    withTemporaryCacheRoot $ \temporaryRoot ->
      withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
        directory <- workerDirectory testRepository
        createDirectoryIfMissing True directory
        descriptor <- descriptorForSpec (specFor (WorkerId "host-1") (IssueHostWorkerTaskKind (IssueHostWorkerTask "coghex/kanban")))
        LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec)
        now <- getCurrentTime
        present <- initIdentity
        writeChildState descriptor (runningChildState descriptor now) {workerStateWorkerIdentity = present}
        writeFile descriptor.workerDescriptorHandoffPath "handing off\n"
        issueHostGone testRepository (WorkerId "host-1") `shouldReturn` False

  -- Absence of proof is not proof. A host that has not recorded an identity
  -- yet is one whose supervisor has only just started, and treating that as
  -- dead would make every dispatch attempt a second host — including on a
  -- machine where a process snapshot cannot be taken at all.
  it "keeps a host that has recorded no identity, since nothing disproves it" $
    withTemporaryCacheRoot $ \temporaryRoot ->
      withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
        directory <- workerDirectory testRepository
        createDirectoryIfMissing True directory
        descriptor <- descriptorForSpec (specFor (WorkerId "host-1") (IssueHostWorkerTaskKind (IssueHostWorkerTask "coghex/kanban")))
        LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec)
        now <- getCurrentTime
        writeChildState descriptor (runningChildState descriptor now)
        found <- liveIssueReviewHost testRepository
        fmap ((.workerId) . (.workerDescriptorSpec)) found `shouldBe` Just (WorkerId "host-1")

-- | An identity for a process that is certainly gone: a pid far above the
-- system maximum, so no snapshot can match it.
departedIdentity :: ProcessIdentity
departedIdentity = ProcessIdentity 999999999 1 999999999 "1970-01-01T00:00:00Z" "kanban-departed-host"

-- | Init's identity as the running system reports it.
initIdentity :: IO (Maybe ProcessIdentity)
initIdentity = either (const Nothing) (identityForPid 1) <$> readProcessSnapshot

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
  | RunCanonical ReviewStage Int
  | StartProvider
  | StopProvider
  deriving stock (Eq, Show)

isCanonicalCall :: ProviderCall -> Bool
isCanonicalCall RunCanonical {} = True
isCanonicalCall _ = False

isAnswerCall, isInterruptCall, isFinishCall, isSendCall, isBeginCall :: ProviderCall -> Bool
isBeginCall (BeginReview _) = True
isBeginCall _ = False
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
    -- The sink the host handed its client, which is how a test plays a
    -- provider event into the host exactly as a real backend would.
    --
    -- A cell rather than a function, because the client is started on demand:
    -- a host serving only canonical stages never starts one, so waiting for
    -- the sink up front would hang the fixture for exactly the case that
    -- proves canonical stages need no client.
    hostSink :: MVar (ReviewEvent -> IO ()),
    hostCalls :: MVar [ProviderCall],
    -- | Allocated per @thread\/start@, so two concurrent children get
    -- distinct threads on one connection — the shared-process shape.
    hostThreads :: MVar (Map.Map Int ReviewThreadId),
    -- | What the host handed its supervisor's provider registration.
    hostRegistered :: MVar [ManagedProcess],
    -- | Filled by a test to hand the canonical gate's subprocess to the host,
    -- at a moment the test chooses. Empty means the gate has not reported one.
    hostCanonicalProcess :: MVar ManagedProcess,
    -- | Filled by a test to let the fake gate return its verdict.
    hostCanonicalFinished :: MVar (),
    -- | What the host runs inside its handoff window, for a test to replace.
    hostHandoff :: MVar (IO ()),
    -- | What the fake provider runs inside a send, for a test to replace.
    hostSendGate :: MVar (IO ()),
    -- | What the host runs inside a thread attach, for a test to replace.
    hostAttach :: MVar (IO ()),
    -- | What the fake provider runs inside a begin, after registering the
    -- connection and before returning, for a test to replace.
    hostBeginGate :: MVar (IO ()),
    -- | What the fake provider reports as a thread's own processes. Empty is
    -- a shared connection; a test giving it one is the per-thread shape.
    hostThreadProcesses :: MVar [ManagedProcess],
    -- | The host's own durable records, for a test that reads its marker.
    hostRecords :: WorkerDescriptor,
    -- | The host's own journal, where anything that outlived a child's
    -- terminal envelope is recorded.
    hostEmitted :: MVar [WorkerEvent]
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

-- | A host whose embedded client can never start, so anything that works
-- under it is something that genuinely needs no client.
withRunningHostNoProvider :: (HostUnderTest -> IO ()) -> IO ()
withRunningHostNoProvider =
  void . withRunningHostUsing (Just (\_ _ _ -> pure (Left "no embedded review backend on this install")))

withRunningHostOutcome :: (HostUnderTest -> IO ()) -> IO (Maybe WorkerEvent, Bool)
withRunningHostOutcome = withRunningHostUsing workingProvider
  where
    -- The ordinary fixture: a client that starts. Recorded, so a test can
    -- assert /when/ it was asked for as well as whether.
    workingProvider = Nothing

withRunningHostUsing :: Maybe (WorkerSpec -> (Maybe Int -> ManagedProcess -> IO ()) -> (ReviewEvent -> IO ()) -> IO (Either Text IssueHostProvider)) -> (HostUnderTest -> IO ()) -> IO (Maybe WorkerEvent, Bool)
withRunningHostUsing overrideProvider body =
  -- A fully provisioned fake machine, because the host runs its /production/
  -- preflight at each child's spawn boundary (requirement 7's first half runs
  -- at the press, this is the second). Stubbing that out would leave the one
  -- boundary a child can be refused at untested.
  -- With a real @ps@ on it, because 'withPreflightMachine' replaces @PATH@
  -- and a host on a machine that cannot snapshot processes records nothing —
  -- which would make every census assertion below quietly vacuous.
  withPreflightMachine (fullyProvisionedFakes <> [realProcessSnapshotTool]) BackendInstalled $ \workingDirectory _ ->
    withEnvironmentValue "XDG_CACHE_HOME" (takeDirectory workingDirectory) $ do
      let repository = Repository workingDirectory "coghex" "kanban"
      directory <- workerDirectory repository
      createDirectoryIfMissing True directory
      calls <- newMVar []
      threads <- newMVar Map.empty
      registeredProcesses <- newMVar []
      canonicalProcess <- newEmptyMVar
      canonicalFinished <- newEmptyMVar
      -- Replaced by a test that needs to act inside the handoff window, or
      -- inside a send; a run that does neither is unaffected.
      handoffBarrier <- newMVar (pure ())
      sendGate <- newMVar (pure ())
      attachBarrier <- newMVar (pure ())
      beginGate <- newMVar (pure ())
      threadProcesses <- newMVar []
      sinkCell <- newEmptyMVar
      emitted <- newMVar []
      let hostSpecification =
            (specFor hostIdUnderTest (IssueHostWorkerTaskKind (IssueHostWorkerTask "coghex/kanban")))
              {workerRepository = repository}
          record call = modifyMVar_ calls (pure . (<> [call]))
          -- The client's own registration, which a real one calls as it
          -- creates each connection. Recorded here so a test can assert the
          -- host registers a connection before its first poll rather than
          -- after it.
          -- The canonical gate, which needs no client: it records that it
          -- started, then waits for the test to hand it a subprocess, which
          -- is what lets a test choose that moment — including after the
          -- child has been settled.
          runCanonical stage issueNumber started = do
            record (RunCanonical stage issueNumber)
            -- The callback runs on a thread of its own, because settling the
            -- child kills the stage thread and the ordering under test
            -- happens inside the recording rather than before it. In
            -- production the spawn reports its subprocess and only then waits
            -- on it, so the recording and a termination genuinely race; this
            -- reproduces that race without depending on which of the two the
            -- scheduler runs first.
            void . forkIO $ takeMVar canonicalProcess >>= started
            -- Waits like a real gate waiting on its subprocess. A test that
            -- wants the gate to finish signals it; one testing the
            -- settle-during-spawn race never does, and the settle cancels
            -- this thread instead.
            takeMVar canonicalFinished
            pure (Right canonicalReviewResultForFake)
          startProvider startingSpec register sink = do
            record StartProvider
            case overrideProvider of
              Just refuse -> refuse startingSpec register sink
              Nothing -> do
                putMVar sinkCell sink
                register Nothing unsignallableProcessGroup
                pure (Right (recordingProvider sendGate beginGate threadProcesses register record))
      hostDescriptor <- descriptorForSpec hostSpecification
      LazyByteString.writeFile hostDescriptor.workerDescriptorSpecPath (encode hostSpecification)
      -- Forked rather than spawned: what is under test is the host's own
      -- loop, and a real supervisor spawn would run this test binary again
      -- with @--worker-spec@.
      finished <- newEmptyMVar
      void . forkIO $ do
        runIssueReviewHostWith
          (IssueHostTuning 20000 1 (join (readMVar handoffBarrier)) (join (readMVar attachBarrier)))
          startProvider
          runCanonical
          hostSpecification
          -- The supervisor's own provider registration, recorded so a test can
          -- assert the host registers its client's processes rather than
          -- claiming to be one itself.
          (\process -> modifyMVar_ registeredProcesses (pure . (<> [process])))
          (\event -> modifyMVar_ emitted (pure . (<> [event])))
        putMVar finished ()
      body
        HostUnderTest
          { hostRepository = repository,
            hostSink = sinkCell,
            hostCalls = calls,
            hostThreads = threads,
            hostRegistered = registeredProcesses,
            hostCanonicalProcess = canonicalProcess,
            hostCanonicalFinished = canonicalFinished,
            hostHandoff = handoffBarrier,
            hostSendGate = sendGate,
            hostAttach = attachBarrier,
            hostBeginGate = beginGate,
            hostThreadProcesses = threadProcesses,
            hostRecords = hostDescriptor,
            hostEmitted = emitted
          }
      -- The host exits when it holds no live child, so a body that left one
      -- running would wait forever. Ending them is done the way anything ends
      -- one — a durable termination command — rather than by reaching into
      -- the host, so the teardown exercises the same path the tests do.
      endEveryChild repository
      -- Bounded, because a host that will not exit is a defect this suite has
      -- to report rather than hang on: an unbounded wait here turns any
      -- lifecycle bug into a suite that never finishes, which is the least
      -- useful failure a test can produce.
      exited <- awaitMaybe (tryTakeMVar finished)
      when (exited == Nothing) (fail "the host never exited after every child was ended")
      finalCalls <- readMVar calls
      finalEvents <- readMVar emitted
      pure (lastTerminal finalEvents, StopProvider `elem` finalCalls)
  where
    lastTerminal events = case [event | event@(WorkerFinished _) <- events] of
      terminal : _ -> Just terminal
      [] -> Nothing

-- | A provider that records what it was asked and announces nothing on its
-- own.
--
-- Announcing nothing is what makes the fixture faithful. A real backend names
-- a thread by emitting 'ReviewThreadCreated' over the client's event sink,
-- asynchronously and an unbounded time after the call that asked for it — so
-- a fake that announced synchronously inside 'providerBeginReview' would make
-- the settled-before-announced ordering unreachable, which is exactly the
-- race round 1 found. Every test drives the announcement itself.
recordingProvider :: MVar (IO ()) -> MVar (IO ()) -> MVar [ManagedProcess] -> (Maybe Int -> ManagedProcess -> IO ()) -> (ProviderCall -> IO ()) -> IssueHostProvider
recordingProvider gate beginGate threadProcesses register record =
  IssueHostProvider
    { providerBeginReview = \issueNumber -> do
        record (BeginReview issueNumber)
        owned <- readMVar threadProcesses
        -- What the real client does at the spawn itself: the connection this
        -- review will run on is registered, named by its issue, before the
        -- start request is sent. Registering only on the return would leave
        -- the process running with the child not yet owning it.
        mapM_ (register (Just issueNumber)) owned
        join (readMVar beginGate)
        pure (Right owned),
      providerAnswerQuestion = \requested _ -> Right () <$ record (AnswerQuestion requested),
      providerApproveAction = \requested accepted forSession ->
        Right () <$ record (ApproveAction requested accepted forSession),
      providerSendMessage = \thread _ message -> do
        -- Held open by a test that needs a delivery in flight while something
        -- else settles the child; nothing by default.
        join (readMVar gate)
        Right () <$ record (SendMessage thread message),
      providerInterruptTurn = \thread turnId -> Right () <$ record (InterruptTurn thread turnId),
      providerFinishThread = record . FinishThread,
      -- One connection, as a shared-process backend holds — a stand-in that
      -- exercises the real registration path without spawning anything.
      providerProcesses = pure [unsignallableProcessGroup],
      -- Empty by default, which is a shared connection's answer. A test that
      -- wants the process-per-thread shape fills this.
      providerThreadProcesses = const (readMVar threadProcesses),
      -- The client's own transcript, which the host records as its log and
      -- which is deliberately not any child's.
      providerLogPath = Nothing,
      providerStop = record StopProvider
    }

-- | Ends every issue action this repository still holds, and waits until the
-- host has settled each one.
-- | Publishes another host's records in the status the caller names, so the
-- orphaned-child rules have a real record to judge.
publishHostRecord :: HostUnderTest -> WorkerId -> WorkerStatus -> IO ()
publishHostRecord host identifier status = do
  now <- getCurrentTime
  descriptor <-
    descriptorForSpec
      ( (specFor identifier (IssueHostWorkerTaskKind (IssueHostWorkerTask "coghex/kanban")))
          {workerRepository = host.hostRepository}
      )
  LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec)
  writeChildState descriptor (runningChildState descriptor now) {workerStateStatus = status}

publishTerminalHost :: HostUnderTest -> WorkerId -> IO ()
publishTerminalHost host identifier = publishHostRecord host identifier (WorkerTerminal SolveCompleted)

publishRunningHost :: HostUnderTest -> WorkerId -> IO ()
publishRunningHost host identifier = publishHostRecord host identifier WorkerRunning

endEveryChild :: Repository -> IO ()
endEveryChild repository = do
  history <- discoverWorkerHistory repository
  let children = issueActionsIn history
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

-- | A process group the fixture hands to the host, which the host may then
-- signal without consequence.
--
-- Deliberately not group 1. Settling a child signals its canonical
-- subprocess's group, and @killpg@ on group 1 is a broadcast to every process
-- the caller may signal. That is not hypothetical: it is what made this
-- suite's own CI runner take a SIGINT and abandon four of its five lanes on
-- Linux, while the same tests passed on Darwin, which refuses the broadcast.
--
-- Above any pid a kernel will allocate, so every signal aimed at it finds no
-- group and is the no-op the fixture wants.
unsignallableProcessGroup :: ManagedProcess
unsignallableProcessGroup = managedProcessGroup 2147483647

hostIdUnderTest :: WorkerId
hostIdUnderTest = WorkerId "host-under-test"

-- | Publishes one child specification naming the host under test, exactly as
-- the registry's launch does, and returns its descriptor.
publishChild :: HostUnderTest -> Text -> Int -> ReviewStage -> IO WorkerDescriptor
publishChild host = publishChildNaming host hostIdUnderTest

-- | The descriptor a child /would/ be published under, so a test can write
-- its durable files before the host ever sees it.
childDescriptorFor :: HostUnderTest -> Text -> Int -> ReviewStage -> IO WorkerDescriptor
childDescriptorFor host identifier issueNumber stage =
  descriptorForSpec
    ( (specFor
         (WorkerId identifier)
         (IssueActionWorkerTaskKind (IssueActionWorkerTask issueNumber stage hostIdUnderTest IssueOriginClaude)))
        {workerRepository = host.hostRepository}
    )

-- | The descriptor a child naming some other host would be published under.
childDescriptorNaming :: HostUnderTest -> WorkerId -> Text -> Int -> ReviewStage -> IO WorkerDescriptor
childDescriptorNaming host named identifier issueNumber stage =
  descriptorForSpec
    ( (specFor
         (WorkerId identifier)
         (IssueActionWorkerTaskKind (IssueActionWorkerTask issueNumber stage named IssueOriginClaude)))
        {workerRepository = host.hostRepository}
    )

-- | Publishes a child that had already started under another host: running,
-- with a thread recorded, which is what makes it a recovery rather than a
-- never-adopted re-home.
publishStartedChildNaming :: HostUnderTest -> WorkerId -> Text -> Int -> ReviewStage -> IO WorkerDescriptor
publishStartedChildNaming host named identifier issueNumber stage = do
  now <- getCurrentTime
  descriptor <- childDescriptorNaming host named identifier issueNumber stage
  let started = descriptor.workerDescriptorSpec {workerCreatedAt = now}
  LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode started)
  writeChildState
    descriptor
    (runningChildState descriptor now)
      { workerStateStatus = WorkerRunning,
        workerStateReviewThread = Just (ReviewThreadId (ConnectionId 1) "thread-of-dead-host")
      }
  pure descriptor {workerDescriptorSpec = started}

-- | Writes journal records a previous host would have left behind.
seedJournal :: WorkerDescriptor -> [WorkerEvent] -> IO ()
seedJournal descriptor events = do
  now <- getCurrentTime
  LazyByteString.appendFile
    descriptor.workerDescriptorEventPath
    (LazyByteString.concat [encode (WorkerEnvelope now event) <> "\n" | event <- events])

-- | Ends one child through the durable termination command and waits for the
-- host to settle it.
endChild :: WorkerDescriptor -> IO ()
endChild descriptor = do
  termination <- commandNumbered 0 descriptor TerminateIssueAction
  written <- appendReviewCommand descriptor termination
  either (fail . Text.unpack) pure written
  void (awaitJust "the child was never settled" (fmap (fmap (const ()) . (\state -> if maybe False (terminalState . (.workerStateStatus)) state then state else Nothing)) (decodeChildState descriptor)))

-- | Publishes a child naming some other host, for the orphaned-child rules.
publishChildNaming :: HostUnderTest -> WorkerId -> Text -> Int -> ReviewStage -> IO WorkerDescriptor
publishChildNaming host named identifier issueNumber stage = do
  now <- getCurrentTime
  descriptor <-
    descriptorForSpec
      ( (specFor
           (WorkerId identifier)
           (IssueActionWorkerTaskKind (IssueActionWorkerTask issueNumber stage named IssueOriginClaude)))
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

-- | Plays one provider event into the host, over the very sink its client was
-- given. Waits for that client to exist, since it is started on demand.
deliver :: HostUnderTest -> ReviewEvent -> IO ()
deliver host event = do
  sink <- awaitJust "the host never started a client to deliver through" (tryReadMVar host.hostSink)
  sink event

providerCalls :: HostUnderTest -> IO [ProviderCall]
providerCalls host = readMVar host.hostCalls

-- | Waits for a diagnostic on the host's own journal containing this text.
awaitHostDiagnostic :: HostUnderTest -> Text -> IO Text
awaitHostDiagnostic host wanted =
  awaitJust ("the host recorded no diagnostic mentioning " <> Text.unpack wanted) $ do
    emitted <- readMVar host.hostEmitted
    pure (find (Text.isInfixOf wanted) [message | WorkerDiagnostic message <- emitted])

-- | Waits for the host to ask for this issue's review, then announces the
-- thread the provider would have named and waits for the child to record it.
--
-- The two halves are one helper because that is one wire exchange: a real
-- backend is asked, and later says which thread it gave. Splitting them in
-- every test would only repeat the wait.
awaitThreadFor :: HostUnderTest -> Int -> IO ReviewThreadId
awaitThreadFor host issueNumber = do
  thread <- announceThreadFor host issueNumber
  _ <- awaitJust
    ("issue #" <> show issueNumber <> " never recorded its thread")
    ( do
        history <- discoverWorkerHistory host.hostRepository
        recorded <- mapM decodeChildState (issueActionsIn history)
        pure (find (\state -> maybe False ((== Just thread) . (.workerStateReviewThread)) state) recorded)
    )
  pure thread

-- | Waits for the review to be asked for, then names its thread — without
-- waiting for the child to record it, which is what a test of the
-- settled-before-announced race needs.
announceThreadFor :: HostUnderTest -> Int -> IO ReviewThreadId
announceThreadFor host issueNumber = do
  begun <- awaitMaybe (readMVar host.hostCalls >>= \calls -> pure (find (== BeginReview issueNumber) calls))
  case begun of
    Nothing -> do
      -- The child's own journal is the account of why its stage never
      -- started -- a preflight blocker, a refused coordinator -- so a failure
      -- here reports that rather than only the absence.
      history <- discoverWorkerHistory host.hostRepository
      journals <- mapM journalEvents (issueActionsIn history)
      fail ("no review was begun for issue #" <> show issueNumber <> "; journals: " <> show journals)
    Just _ -> do
      thread <- modifyMVar host.hostThreads $ \held ->
        let allocated = ReviewThreadId (ConnectionId 1) (Text.pack ("thread-" <> show (Map.size held + 1)))
         in pure (Map.insert issueNumber allocated held, allocated)
      deliver host (ReviewThreadCreated issueNumber thread)
      pure thread

awaitCalls :: HostUnderTest -> Int -> (ProviderCall -> Bool) -> IO ()
awaitCalls host expected wanted = void (awaitCallsFor host expected wanted)

awaitCallsFor :: HostUnderTest -> Int -> (ProviderCall -> Bool) -> IO [ProviderCall]
awaitCallsFor host expected wanted =
  awaitJust "the provider was not called as expected" $ do
    calls <- readMVar host.hostCalls
    pure (if length (filter wanted calls) >= expected then Just calls else Nothing)

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

-- | A short bounded probe, for asserting that something does /not/ happen.
--
-- 'awaitMaybe' waits half a minute, which is right for a signal that is
-- coming and wrong for one that must not: a negative assertion pays its whole
-- bound on every passing run. Forty polls is many times the host's own
-- interval under test, so anything that was going to happen has.
awaitBriefly :: IO (Maybe result) -> IO (Maybe result)
awaitBriefly probe = go (40 :: Int)
  where
    go remaining = do
      found <- probe
      case found of
        Just result -> pure (Just result)
        Nothing
          | remaining <= 0 -> pure Nothing
          | otherwise -> threadDelay 25000 >> go (remaining - 1)

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

-- | A child whose settle wrote its terminal envelope and died before it
-- recorded the terminal state: the journal ends, the state says running, the
-- lease is still held, and the host that was doing it is gone.
halfSettledChild :: UTCTime -> IO WorkerDescriptor
halfSettledChild heartbeat = do
  descriptor <-
    descriptorForSpec
      ( specFor
          (WorkerId "half-settled-action")
          (IssueActionWorkerTaskKind (IssueActionWorkerTask 594 IssueRevision (WorkerId "host-that-died") IssueOriginClaude))
      )
  createDirectoryIfMissing True (takeDirectory descriptor.workerDescriptorSpecPath)
  LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec)
  writeChildState
    descriptor
    (runningChildState descriptor heartbeat) {workerStateWorkerIdentity = Just departedIdentity}
  seedJournal descriptor [WorkerFinished (SolveFailed "the issue action was terminated")]
  Right () <- acquireWorkerLeaseFor descriptor
  pure descriptor

-- | Whether the host said it could not record itself as a child's owner.
refusesOwnership :: WorkerEvent -> Bool
refusesOwnership event = case event of
  WorkerDiagnostic message -> "could not record this host as the owner" `Text.isInfixOf` message
  _ -> False

-- | The host a child's own durable specification names.
recordedOwnerOf :: WorkerDescriptor -> IO (Maybe WorkerId)
recordedOwnerOf descriptor = do
  decoded <- eitherDecodeFileStrict' @WorkerSpec descriptor.workerDescriptorSpecPath
  pure $ case decoded of
    Left _ -> Nothing
    Right recorded -> (.issueActionHost) <$> issueActionTask recorded.workerTask

-- | A path under this repository's transcript directory, for a log a test
-- writes before the host ever sees it.
transcriptPathFor :: Repository -> FilePath -> IO FilePath
transcriptPathFor repository name = do
  directory <- transcriptRoot repository
  createDirectoryIfMissing True directory
  pure (directory </> name)

-- | Points a child's durable state at a log, the way its previous host left
-- it.
updateChildLogPath :: WorkerDescriptor -> FilePath -> IO ()
updateChildLogPath descriptor path = do
  recorded <- decodeChildState descriptor
  forM_ recorded (\state -> writeChildState descriptor state {workerStateLogPath = Just path})

journalEvents :: WorkerDescriptor -> IO [WorkerEvent]
journalEvents descriptor = map (.workerEnvelopeEvent) <$> readWorkerJournal descriptor

-- | A log's current contents, read through a POSIX descriptor.
--
-- Not 'ByteString.readFile': GHC locks a file per process, and the host still
-- holds this log open for writing, so any second 'Handle' on it is refused.
-- Reading the descriptor directly is what lets a test look at a log its
-- subject is still writing — which is the only moment the separation between
-- two concurrent children is observable.
readLogBytes :: FilePath -> IO String
readLogBytes path =
  bracket (openFd path ReadOnly defaultFileFlags) closeFd $ \descriptor ->
    Text.unpack . TextEncoding.decodeUtf8Lenient . ByteString.concat <$> readChunks descriptor
  where
    -- 'fdRead' throws at end of file rather than returning nothing, so the
    -- end of the log is caught rather than tested for.
    readChunks descriptor = do
      chunk <- try @IOException (fdRead descriptor 8192)
      case chunk of
        Left _ -> pure []
        Right bytes
          | ByteString.null bytes -> pure []
          | otherwise -> (bytes :) <$> readChunks descriptor

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

-- | What the fake gate reports, so a canonical child settles on evidence
-- rather than on a clean exit.
canonicalReviewResultForFake :: CanonicalIssueReviewResult
canonicalReviewResultForFake = canonicalResult

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
      workerAssignment = Nothing,
      workerExpectedTarget = Nothing
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
withHostTopology hostStatus childStatus = withHostTopologyAged hostStatus childStatus expiredHeartbeat

-- | The same topology with the child inside the retention window, so its own
-- records survive the pass and the rules that read them have something to
-- read.
withRetainedChildTopology :: WorkerStatus -> WorkerStatus -> (WorkerDescriptor -> WorkerDescriptor -> IO result) -> IO result
withRetainedChildTopology hostStatus childStatus = withHostTopologyAged hostStatus childStatus getCurrentTime

withHostTopologyAged :: WorkerStatus -> WorkerStatus -> IO UTCTime -> (WorkerDescriptor -> WorkerDescriptor -> IO result) -> IO result
withHostTopologyAged hostStatus childStatus childHeartbeat body =
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
      hostNow <- expiredHeartbeat
      childNow <- childHeartbeat
      mapM_
        (\(descriptor, status, heartbeat) -> publish descriptor status heartbeat)
        [(host, hostStatus, hostNow), (child, childStatus, childNow)]
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

-- | A child's durable state, or 'Nothing' when it has none yet.
--
-- Tolerant of an absent file on purpose: a worker that has not written state
-- is a normal state to read, and every caller here is either waiting for one
-- to appear or scanning a directory that also holds a host.
decodeChildState :: WorkerDescriptor -> IO (Maybe WorkerState)
decodeChildState descriptor = do
  present <- doesFileExist descriptor.workerDescriptorStatePath
  if not present then pure Nothing else decode <$> LazyByteString.readFile descriptor.workerDescriptorStatePath

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
  -- Correlated against what the child currently records, which is exactly
  -- what 'Kanban.UI.Review.submitReviewCommand' reads when the overlay
  -- submits one. A fixture that named a thread of its own would be testing a
  -- command no dashboard writes.
  recorded <- decodeChildState descriptor
  pure
    ReviewCommand
      { reviewCommandId = distinct identifier,
        reviewCommandTarget = descriptor.workerDescriptorSpec.workerId,
        reviewCommandIssue = issueNumberOf descriptor,
        reviewCommandThread = recorded >>= (.workerStateReviewThread),
        reviewCommandTurn = recorded >>= (.workerStateReviewTurn),
        reviewCommandIssuedAt = now,
        reviewCommandPayload = payload
      }
  where
    distinct (ReviewCommandId value) = ReviewCommandId (value <> "-" <> Text.pack (show ordinal))

issueActionsIn :: [WorkerDescriptor] -> [WorkerDescriptor]
issueActionsIn history =
  [descriptor | descriptor <- history, isJust (issueActionTask descriptor.workerDescriptorSpec.workerTask)]

issueNumberOf :: WorkerDescriptor -> Int
issueNumberOf descriptor =
  maybe 594 (.issueActionIssueNumber) (issueActionTask descriptor.workerDescriptorSpec.workerTask)

owedBy :: WorkerDescriptor -> IO [ReviewCommand]
owedBy descriptor =
  undeliveredReviewCommands <$> readReviewCommands descriptor <*> readReviewCommandAcknowledgements descriptor

-- | The outcome standing for one command, which is the last record for it:
-- every command is claimed before it is applied and settled afterwards.
settledOutcome :: ReviewCommandId -> [ReviewCommandAcknowledgement] -> Maybe ReviewCommandOutcome
settledOutcome identity = fmap (.acknowledgedOutcome) . acknowledgementFor identity

acknowledged :: ReviewCommand -> ReviewCommandOutcome -> IO ReviewCommandAcknowledgement
acknowledged command outcome = do
  now <- getCurrentTime
  pure (ReviewCommandAcknowledgement command.reviewCommandId now outcome)
