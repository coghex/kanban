-- | The autosolve loop's stage advancement, exercised directly.
--
-- These are the parts of Milestone 8's loop contract worth pinning: binding
-- a discovered pull request to the run that produced it, the approve and
-- changes-requested label handoffs, and the five-round bound. All of it is
-- pure, so none of it needs an @EventM@, a terminal, or a fake agent.
module Spec.UI.AutoSolve (spec) where

import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Time (addUTCTime)
import Kanban.Domain
import Kanban.Solve (SolveWorkflow (..), SolverBrand (..))
import Kanban.UI.AutoSolve
  ( AutoSolveCompletion (..),
    AutoSolveDecision (..),
    AutoSolveHalt (..),
    AutoSolveHandoff (..),
    AutoSolveObservation (..),
    autoSolveAfterCompletion,
    autoSolveCompletionNotice,
    autoSolveReviewLimit,
    decideAutoSolve,
    newAutoSolvePullRequests,
    recoveredAutoSolveProgress,
  )
import Kanban.UI.Types (AutoSolveProgress (..), AutoSolveStage (..), SolvePhase (..))
import Kanban.Worker (WorkerParent (..))
import Spec.Support.Fixtures (basePullRequest, epoch)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

-- | The issue every fixture below loops over.
loopIssue :: Int
loopIssue = 50

-- | A pull request linked to 'issueNumber', with an explicit origin marker
-- as its final content — the shape 'Kanban.PullRequestFlow.originFromBody'
-- accepts.
linkedPullRequest :: Int -> SolverBrand -> [Label] -> PullRequest
linkedPullRequest number brand labels =
  (basePullRequest number [loopIssue] False labels)
    {pullRequestBody = "Closes #50\n\n" <> marker}
  where
    marker = case brand of
      CodexSolver -> "<!-- pr-origin:codex -->"
      ClaudeSolver -> "<!-- pr-origin:claude -->"

label :: Text.Text -> Label
label name = Label name ""

progressAt :: AutoSolveStage -> Int -> Maybe Int -> AutoSolveProgress
progressAt stage round' bound =
  AutoSolveProgress
    { autoSolveStage = stage,
      autoSolvePullRequest = bound,
      autoSolveReviewRound = round',
      autoSolveKnownPullRequests = Set.empty,
      autoSolveStartedAt = epoch
    }

-- | An observation with nothing interesting in it, refined per test.
observing :: [PullRequest] -> AutoSolveObservation
observing pullRequests =
  AutoSolveObservation
    { autoSolveIssueNumber = loopIssue,
      autoSolveWorkflowConfig = defaultWorkflowConfig,
      autoSolveSolverBrand = ClaudeSolver,
      autoSolveSolverSession = Just "session-1",
      autoSolveSolverRunning = False,
      autoSolveSnapshotPullRequests = pullRequests,
      autoSolveReviewPhase = Nothing
    }

approved :: PullRequest
approved = linkedPullRequest 91 ClaudeSolver [label defaultWorkflowConfig.approvalLabel]

changesRequested :: PullRequest
changesRequested = linkedPullRequest 91 ClaudeSolver [label defaultWorkflowConfig.changesRequestedLabel]

unlabelled :: PullRequest
unlabelled = linkedPullRequest 91 ClaudeSolver []

spec :: Spec
spec = describe "autosolve stage advancement" $ do
  describe "binding the pull request an implementation opened" $ do
    it "binds a single new linked PR carrying the solver's own origin marker" $ do
      let pullRequest = linkedPullRequest 91 ClaudeSolver []
          decision = decideAutoSolve (observing [pullRequest]) (progressAt AutoDiscoveringPullRequest 0 Nothing)
      decision
        `shouldBe` AutoSolveOpenReview
          91
          (progressAt AutoReviewing 1 (Just 91))

    it "opens the first review round, not a later one" $ do
      case decideAutoSolve (observing [linkedPullRequest 91 ClaudeSolver []]) (progressAt AutoDiscoveringPullRequest 0 Nothing) of
        AutoSolveOpenReview _ progress -> progress.autoSolveReviewRound `shouldBe` 1
        other -> fail ("expected a bound review, got " <> show other)

    it "stops rather than review a PR opened by the other brand" $ do
      let decision = decideAutoSolve (observing [linkedPullRequest 91 CodexSolver []]) (progressAt AutoDiscoveringPullRequest 0 Nothing)
      decision
        `shouldBe` AutoSolveHalted
          AutoSolveHaltStopped
          "new linked PR has the wrong origin marker for the selected solver"

    it "stops rather than review a PR whose origin marker cannot be read" $ do
      let unmarked = (basePullRequest 91 [loopIssue] False []) {pullRequestBody = "no marker here"}
      case decideAutoSolve (observing [unmarked]) (progressAt AutoDiscoveringPullRequest 0 Nothing) of
        AutoSolveHalted AutoSolveHaltStopped reason ->
          reason `shouldSatisfy` Text.isPrefixOf "new linked PR cannot be reviewed: "
        other -> fail ("expected a stop, got " <> show other)

    it "stops rather than guess between two new linked PRs" $ do
      let decision =
            decideAutoSolve
              (observing [linkedPullRequest 91 ClaudeSolver [], linkedPullRequest 92 ClaudeSolver []])
              (progressAt AutoDiscoveringPullRequest 0 Nothing)
      decision
        `shouldBe` AutoSolveHalted
          AutoSolveHaltStopped
          "multiple new linked PRs appeared; choose the intended PR manually"

    it "waits when nothing linked has appeared yet" $
      decideAutoSolve (observing []) (progressAt AutoDiscoveringPullRequest 0 Nothing)
        `shouldBe` AutoSolveWaitingOn "waiting for linked PR; press u to retry"

    it "does not adopt a pull request the board already carried when the run began" $ do
      let known = (progressAt AutoDiscoveringPullRequest 0 Nothing) {autoSolveKnownPullRequests = Set.singleton 91}
      newAutoSolvePullRequests loopIssue known [linkedPullRequest 91 ClaudeSolver []] `shouldBe` []

    it "does not adopt a pull request opened well before the run started" $ do
      let progress = (progressAt AutoDiscoveringPullRequest 0 Nothing) {autoSolveStartedAt = addUTCTime 3600 epoch}
      newAutoSolvePullRequests loopIssue progress [linkedPullRequest 91 ClaudeSolver []] `shouldBe` []

    it "does not adopt a pull request linked to a different issue" $
      newAutoSolvePullRequests
        loopIssue
        (progressAt AutoDiscoveringPullRequest 0 Nothing)
        [basePullRequest 91 [999] False []]
        `shouldBe` []

  describe "review verdicts" $ do
    it "completes on the approval label" $
      decideAutoSolve
        (observing [approved]) {autoSolveReviewPhase = Just SolveFinished}
        (progressAt AutoReviewing 1 (Just 91))
        `shouldBe` AutoSolveApprove 91

    it "resumes the original solver on the changes-requested label" $
      decideAutoSolve
        (observing [changesRequested]) {autoSolveReviewPhase = Just SolveFinished}
        (progressAt AutoReviewing 1 (Just 91))
        `shouldBe` AutoSolveRevise 91 (progressAt AutoRevising 1 (Just 91))

    it "waits for a verdict when the finished review left no label" $
      decideAutoSolve
        (observing [unlabelled]) {autoSolveReviewPhase = Just SolveFinished}
        (progressAt AutoReviewing 1 (Just 91))
        `shouldBe` AutoSolveWaitingOn "waiting for review verdict; press u to retry"

    it "starts the review the bound pull request is missing" $
      decideAutoSolve (observing [unlabelled]) (progressAt AutoReviewing 1 (Just 91))
        `shouldBe` AutoSolveStartReview 91

    it "fails when the review process failed" $
      decideAutoSolve
        (observing [unlabelled]) {autoSolveReviewPhase = Just SolveFailedPhase}
        (progressAt AutoReviewing 1 (Just 91))
        `shouldBe` AutoSolveHalted AutoSolveHaltFailed "PR #91 review failed; press p to inspect it"

    it "fails when the review process was killed" $
      decideAutoSolve
        (observing [unlabelled]) {autoSolveReviewPhase = Just SolveKilledPhase}
        (progressAt AutoReviewing 1 (Just 91))
        `shouldBe` AutoSolveHalted AutoSolveHaltFailed "PR #91 review was killed"

    it "hands a review that wants input back to the user" $
      decideAutoSolve
        (observing [unlabelled]) {autoSolveReviewPhase = Just SolveAttention}
        (progressAt AutoReviewing 1 (Just 91))
        `shouldBe` AutoSolveWaitingOn "PR review needs input; press p"

    it "stops when the pull request it was reviewing disappeared" $
      decideAutoSolve (observing []) (progressAt AutoReviewing 1 (Just 91))
        `shouldBe` AutoSolveHalted AutoSolveHaltStopped "the autosolve PR disappeared before review completed"

  describe "the rereview verdict pr-revise publishes" $ do
    it "completes on the fresh approval, without launching another reviewer" $
      decideAutoSolve (observing [approved]) (progressAt AutoAwaitingRereview 1 (Just 91))
        `shouldBe` AutoSolveApprove 91

    it "opens the next round on a fresh changes-requested verdict" $
      decideAutoSolve (observing [changesRequested]) (progressAt AutoAwaitingRereview 1 (Just 91))
        `shouldBe` AutoSolveRevise 91 (progressAt AutoRevising 2 (Just 91))

    it "waits while no fresh verdict stands, rather than wait on reviewed:revised" $
      decideAutoSolve (observing [unlabelled]) (progressAt AutoAwaitingRereview 1 (Just 91))
        `shouldBe` AutoSolveWaitingOn "waiting for the canonical rereview verdict; press u to retry"

    it "stops when the pull request disappeared after the revision" $
      decideAutoSolve (observing []) (progressAt AutoAwaitingRereview 1 (Just 91))
        `shouldBe` AutoSolveHalted AutoSolveHaltStopped "the autosolve PR disappeared after revision"

  describe "the five-round bound" $ do
    it "runs the last permitted round" $
      decideAutoSolve
        (observing [changesRequested]) {autoSolveReviewPhase = Just SolveFinished}
        (progressAt AutoReviewing (autoSolveReviewLimit - 1) (Just 91))
        `shouldBe` AutoSolveRevise 91 (progressAt AutoRevising (autoSolveReviewLimit - 1) (Just 91))

    it "stops once the limit is reached rather than open another round" $
      decideAutoSolve
        (observing [changesRequested]) {autoSolveReviewPhase = Just SolveFinished}
        (progressAt AutoReviewing autoSolveReviewLimit (Just 91))
        `shouldBe` AutoSolveHalted
          AutoSolveHaltStopped
          "PR #91 still has requested changes after 5 review rounds"

    it "counts the rereview's own increment against the same limit" $
      decideAutoSolve
        (observing [changesRequested])
        (progressAt AutoAwaitingRereview (autoSolveReviewLimit - 1) (Just 91))
        `shouldBe` AutoSolveHalted
          AutoSolveHaltStopped
          "PR #91 still has requested changes after 5 review rounds"

  describe "guards on resuming the solver" $ do
    it "stops when the original solver returned no resumable session" $
      decideAutoSolve
        (observing [changesRequested]) {autoSolveReviewPhase = Just SolveFinished, autoSolveSolverSession = Nothing}
        (progressAt AutoReviewing 1 (Just 91))
        `shouldBe` AutoSolveHalted AutoSolveHaltStopped "the original solver did not return a resumable session id"

    it "does not launch a second solver while one is already running" $
      decideAutoSolve
        (observing [changesRequested]) {autoSolveReviewPhase = Just SolveFinished, autoSolveSolverRunning = True}
        (progressAt AutoReviewing 1 (Just 91))
        `shouldBe` AutoSolveWait

  describe "stages a refresh does not drive" $
    mapM_
      ( \stage ->
          it ("waits while " <> show stage) $
            decideAutoSolve (observing [approved]) (progressAt stage 1 (Just 91)) `shouldBe` AutoSolveWait
      )
      [AutoImplementing, AutoRevising, AutoSolveComplete, AutoSolveStopped]

  describe "handing the loop on when a solver run finishes" $ do
    it "sends a finished implementation to discovery" $
      autoSolveAfterCompletion (progressAt AutoImplementing 0 Nothing)
        `shouldBe` Just
          AutoSolveCompletion
            { autoSolveCompletionHandoff = AutoSolveToDiscovery,
              autoSolveCompletionProgress = progressAt AutoDiscoveringPullRequest 0 Nothing,
              autoSolveCompletionActivity = "discovering pull request"
            }

    it "sends a finished revision to the rereview verdict" $
      autoSolveAfterCompletion (progressAt AutoRevising 2 (Just 91))
        `shouldBe` Just
          AutoSolveCompletion
            { autoSolveCompletionHandoff = AutoSolveToRereview,
              autoSolveCompletionProgress = progressAt AutoAwaitingRereview 2 (Just 91),
              autoSolveCompletionActivity = "waiting for revised PR state"
            }

    it "settles a run the loop does not continue past" $
      autoSolveAfterCompletion (progressAt AutoReviewing 1 (Just 91)) `shouldBe` Nothing

    it "names the issue in each handoff notice" $ do
      autoSolveCompletionNotice 50 AutoSolveToDiscovery
        `shouldBe` "Implementation for #50 finished; discovering its new PR…"
      autoSolveCompletionNotice 50 AutoSolveToRereview
        `shouldBe` "Revision for #50 finished; waiting for the revised PR state…"

  describe "recovering the loop from a reattached worker" $ do
    it "resumes an implementation when the parent recorded no review round" $ do
      let parent = workerParent 0
      recoveredAutoSolveProgress AutoSolve (Just parent) Set.empty epoch
        `shouldBe` Just
          AutoSolveProgress
            { autoSolveStage = AutoImplementing,
              autoSolvePullRequest = Nothing,
              autoSolveReviewRound = 0,
              autoSolveKnownPullRequests = Set.singleton 7,
              autoSolveStartedAt = addUTCTime 60 epoch
            }

    it "resumes a revision when the parent recorded one" $
      (recoveredAutoSolveProgress AutoSolve (Just (workerParent 3)) Set.empty epoch >>= Just . (.autoSolveStage))
        `shouldBe` Just AutoRevising

    it "falls back to the board's pull requests when there is no parent record" $
      recoveredAutoSolveProgress AutoSolve Nothing (Set.singleton 42) epoch
        `shouldBe` Just
          AutoSolveProgress
            { autoSolveStage = AutoImplementing,
              autoSolvePullRequest = Nothing,
              autoSolveReviewRound = 0,
              autoSolveKnownPullRequests = Set.singleton 42,
              autoSolveStartedAt = epoch
            }

    it "gives a solve-only worker no loop at all" $
      recoveredAutoSolveProgress SolveOnly (Just (workerParent 3)) Set.empty epoch `shouldBe` Nothing

workerParent :: Int -> WorkerParent
workerParent reviewRound =
  WorkerParent
    { workerParentIssueNumber = loopIssue,
      workerParentReviewRound = reviewRound,
      workerParentSolverBrand = ClaudeSolver,
      workerParentSolverSession = Just "session-1",
      workerParentSolverLogPath = Nothing,
      workerParentStartedAt = addUTCTime 60 epoch,
      workerParentKnownPullRequests = Set.singleton 7
    }
