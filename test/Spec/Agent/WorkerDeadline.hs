-- | Persistent worker deadlines projected into the UI.
module Spec.Agent.WorkerDeadline (spec) where

import qualified Data.Map.Strict as Map
import Kanban.PullRequestFlow (PullRequestAction (..), PullRequestOrigin (..))
import Kanban.Solve
  ( ResumeProvenance (..),
    SolveOutcome (..),
    SolveWorkflow (..),
    SolverBrand (..)
  )
import Kanban.UI
  ( ChatTranscript (..),
    PullRequestReviewSession (..),
    SolvePhase (..),
    SolveSession (..),
    failureActivity,
    killSelectionNotice,
    orphanMessage,
    pullRequestSessionAlreadyResolved,
    solveSessionAlreadyResolved
  )
import Kanban.Worker (workerDeadlineReason)
import Spec.Support.Expect (shouldMention, shouldNotMention)
import Spec.Support.Fixtures (baseIssue, basePullRequest, epoch)
import Test.Hspec

spec :: Spec
spec = do
  describe "persistent worker deadline UI projections" $ do
    it "renders the deadline reason distinctly from a generic provider failure" $ do
      failureActivity workerDeadlineReason `shouldBe` "deadline exceeded"
      failureActivity "some other unexpected failure" `shouldBe` "failed"

    it "renders the deadline reason distinctly for orphan-pending subprocesses, for both solve and PR workers" $ do
      orphanMessage (SolveFailed workerDeadlineReason) "2" "the solver"
        `shouldBe` "deadline exceeded; 2 subprocesses survived termination; press x to terminate the orphaned process tree"
      orphanMessage SolveCompleted "2" "the solver"
        `shouldBe` "2 subprocesses survived the solver; press x to terminate the orphaned process tree"
      orphanMessage (SolveFailed workerDeadlineReason) "1" "the PR agent"
        `shouldBe` "deadline exceeded; 1 subprocesses survived termination; press x to terminate the orphaned process tree"
      orphanMessage SolveCompleted "1" "the PR agent"
        `shouldBe` "1 subprocesses survived the PR agent; press x to terminate the orphaned process tree"

    it "tells an operator with nothing selected to press the kill binding rather than the select-previous binding" $ do
      -- The board dispatches the kill on 'x'; 'k' selects the previous card,
      -- so a notice naming 'k' silently moves the selection instead. The Esc
      -- and Ctrl-L halves of this keyboard-contract fix dispatch in brick's
      -- 'EventM' (and Ctrl-L needs a live Vty handle), which no unit test
      -- here can drive; they stay covered by the manual checks in the PR.
      killSelectionNotice `shouldMention` "pressing x"
      killSelectionNotice `shouldNotMention` "pressing k"
      killSelectionNotice `shouldBe` "Select a working issue or PR before pressing x"

    it "suppresses a late WorkerAgentOutput/WorkerDiagnostic projection once a solve or PR session has already resolved" $ do
      -- 'applyWorkerProtocolEvent' cannot be exercised directly in a unit
      -- test (it runs in brick's 'EventM', which exposes no way to run an
      -- action against a plain state outside a live Vty event loop); this
      -- instead directly covers 'solveSessionAlreadyResolved' and
      -- 'pullRequestSessionAlreadyResolved', the pure predicates that
      -- decide whether a trailing 'WorkerAgentOutput'/'WorkerDiagnostic'
      -- event -- which 'streamOutput'/'streamDiagnostics' can still emit
      -- after the watchdog has already committed 'WorkerOrphansDetected' or
      -- 'WorkerFinished' -- gets applied at all.
      let solveSessionWith phase =
            SolveSession
              { solveSessionIssue = baseIssue 787 [],
                solveSessionWorkflow = SolveOnly,
                solveSessionBrand = CodexSolver,
                solveSessionId = Nothing,
                solveSessionPhase = phase,
                solveSessionActivity = "thinking",
                solveSessionActivityStartedAt = epoch,
                solveSessionLogPath = Nothing,
                solveSessionTranscript = ChatTranscript "" "" "",
                solveSessionInput = "",
                solveSessionSpinnerFrame = 0,
                solveSessionAutoProgress = Nothing,
                solveSessionResumeProvenance = ResumeAnswer,
                solveSessionFollowing = True
              }
          solveSessionsWith phase = Map.fromList [(787, solveSessionWith phase)]
      mapM_
        (\phase -> solveSessionAlreadyResolved 787 (solveSessionsWith phase) `shouldBe` True)
        [SolveFinished, SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase]
      mapM_
        (\phase -> solveSessionAlreadyResolved 787 (solveSessionsWith phase) `shouldBe` False)
        [SolveStarting, SolveRunning, SolveInterrupting, SolveAttention]
      solveSessionAlreadyResolved 999 (solveSessionsWith SolveFinished) `shouldBe` False
      let pullRequestSessionWith phase =
            PullRequestReviewSession
              { pullRequestSessionPullRequest = basePullRequest 826 [] False [],
                pullRequestSessionOrigin = PullRequestCodex,
                pullRequestSessionAction = PullRequestReview,
                pullRequestSessionLaunchedForUpdatedAt = epoch,
                pullRequestSessionBrand = CodexSolver,
                pullRequestSessionId = Nothing,
                pullRequestSessionPhase = phase,
                pullRequestSessionActivity = "thinking",
                pullRequestSessionActivityStartedAt = epoch,
                pullRequestSessionLogPath = Nothing,
                pullRequestSessionTranscript = ChatTranscript "" "" "",
                pullRequestSessionInput = "",
                pullRequestSessionSpinnerFrame = 0,
                pullRequestSessionResumeProvenance = ResumeAnswer,
                pullRequestSessionFollowing = True
              }
          pullRequestSessionsWith phase = Map.fromList [(826, pullRequestSessionWith phase)]
      mapM_
        (\phase -> pullRequestSessionAlreadyResolved 826 (pullRequestSessionsWith phase) `shouldBe` True)
        [SolveFinished, SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase]
      mapM_
        (\phase -> pullRequestSessionAlreadyResolved 826 (pullRequestSessionsWith phase) `shouldBe` False)
        [SolveStarting, SolveRunning, SolveInterrupting, SolveAttention]
      pullRequestSessionAlreadyResolved 999 (pullRequestSessionsWith SolveFinished) `shouldBe` False
