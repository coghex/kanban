-- | A pull request's reported status.
module Spec.GitHub.PullRequestStatus (spec) where

import qualified Data.Map.Strict as Map
import Data.Time (addUTCTime)
import Kanban.Domain
import Kanban.UI.Theme
  ( approvedAttr,
    approvedInteriorAttr,
    cardInteriorAttribute,
    neutralAttr,
    pendingAttr,
    problemAttr,
    pullRequestCardAttribute,
    readyAttr,
  )
import Kanban.Workflow (CardStatus (..), deriveBoard, entryItem, isProblem, pullRequestStatus)
import Spec.Support.Fixtures (baseIssue, basePullRequest, epoch, itemNumber)
import Test.Hspec

spec :: Spec
spec = do
  describe "pull request status" $ do
    it "makes conflicts red even when approved and CI passed" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeConflicting, pullRequestChecks = ChecksPassed 4}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusProblem "merge conflict"
    it "makes clean approved pull requests green when CI passed" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeClean, pullRequestChecks = ChecksPassed 4}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusReady

    -- issue #48: approved + BEHIND must report checks-pending before
    -- merge-pending whenever checks are not yet ready, since a still-running
    -- check is more actionable information than a stale branch.
    it "reports checks-pending before merge-pending when approved, behind, and checks are still pending" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeBehind, pullRequestChecks = ChecksPending 1 2 [CheckDetail "build" CheckPending]}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusPending "checks pending"
    it "reports merge-pending once approved, behind, and checks have already passed" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeBehind, pullRequestChecks = ChecksPassed 4}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusPending "merge pending"

    it "defaults blocking severity to red, preserving the existing problem presentation" $ do
      let pullRequest = basePullRequest 10 [] False [Label "reviewed:changes" "ff0000"]
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusProblem "blocked"
      isProblem defaultWorkflowConfig (PullRequestItem pullRequest) `shouldBe` True
    it "renders and sorts a configured amber blocking severity as pending rather than a problem" $ do
      let config = defaultWorkflowConfig {blockingSeverity = SeverityAmber}
          pullRequest = basePullRequest 10 [] False [Label "reviewed:changes" "ff0000"]
      pullRequestStatus config pullRequest `shouldBe` StatusPending "blocked"
      isProblem config (PullRequestItem pullRequest) `shouldBe` False

    it "reorders standalone board entries when amber blocking severity drops a blocked PR out of the problem bucket" $ do
      let blocked = (basePullRequest 10 [] False [Label "reviewed:changes" "ff0000"]) {pullRequestCreatedAt = addUTCTime 3600 epoch}
          neutral = basePullRequest 11 [] False []
          snapshot = RepoSnapshot [] [blocked, neutral] epoch False False
          Board redColumns = deriveBoard defaultWorkflowConfig snapshot
          amberConfig = defaultWorkflowConfig {blockingSeverity = SeverityAmber}
          Board amberColumns = deriveBoard amberConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing redColumns) `shouldBe` [10, 11]
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing amberColumns) `shouldBe` [11, 10]

    it "reorders tracker groups when amber blocking severity drops a blocked child PR out of the problem bucket" $ do
      let blockedTracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #1 — A1: Child",
                issueCreatedAt = addUTCTime 3600 epoch
              }
          neutralTracker =
            (baseIssue 200 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #2 — A1: Child",
                issueCreatedAt = epoch
              }
          blockedPr = basePullRequest 10 [1] False [Label "reviewed:changes" "ff0000"]
          neutralPr = basePullRequest 11 [2] False []
          snapshot = RepoSnapshot [blockedTracker, neutralTracker, baseIssue 1 [], baseIssue 2 []] [blockedPr, neutralPr] epoch False False
          Board redColumns = deriveBoard defaultWorkflowConfig snapshot
          amberConfig = defaultWorkflowConfig {blockingSeverity = SeverityAmber}
          Board amberColumns = deriveBoard amberConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing redColumns) `shouldBe` [10, 11]
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing amberColumns) `shouldBe` [11, 10]

    it "leaves an unapproved PR with pending checks neutral rather than showing checks-pending" $ do
      let pullRequest = (basePullRequest 10 [] False []) {pullRequestChecks = ChecksPending 1 2 [CheckDetail "build" CheckPending]}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusNeutral

    it "renders an approved, amber-blocked PR's card as pending rather than approved" $ do
      let amberConfig = defaultWorkflowConfig {blockingSeverity = SeverityAmber}
          pullRequest = basePullRequest 10 [] False [Label "reviewed:approve" "00ff00", Label "reviewed:changes" "ff0000"]
      pullRequestCardAttribute amberConfig pullRequest `shouldBe` pendingAttr
      pullRequestCardAttribute amberConfig pullRequest `shouldNotBe` approvedAttr
      cardInteriorAttribute (pullRequestCardAttribute amberConfig pullRequest) `shouldBe` neutralAttr

    it "renders a fully ready, approved PR's card as ready with an approved interior wash" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeClean, pullRequestChecks = ChecksPassed 4}
      pullRequestCardAttribute defaultWorkflowConfig pullRequest `shouldBe` readyAttr
      cardInteriorAttribute (pullRequestCardAttribute defaultWorkflowConfig pullRequest) `shouldBe` approvedInteriorAttr

    it "keeps a red-severity blocked PR's card as a problem, with a neutral interior" $ do
      let pullRequest = basePullRequest 10 [] False [Label "reviewed:approve" "00ff00", Label "reviewed:changes" "ff0000"]
      pullRequestCardAttribute defaultWorkflowConfig pullRequest `shouldBe` problemAttr
      cardInteriorAttribute (pullRequestCardAttribute defaultWorkflowConfig pullRequest) `shouldBe` neutralAttr

    it "confines configurable blocking severity to pull requests, leaving blocked-issue treatment unchanged" $ do
      let issue = (baseIssue 10 []) {issueLabels = [Label "blocked" "d73a4a"]}
      isProblem defaultWorkflowConfig (IssueItem issue) `shouldBe` True
      isProblem (defaultWorkflowConfig {blockingSeverity = SeverityAmber}) (IssueItem issue) `shouldBe` True

    it "reports merge-pending, not checks-pending, when checks are unknown rather than a known pending state" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeBehind, pullRequestChecks = ChecksUnknown}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusPending "merge pending"

    it "lets a configured approval label change Done-column membership" $ do
      let config = defaultWorkflowConfig {approvalLabel = "lgtm"}
          pullRequest = basePullRequest 10 [] False [Label "lgtm" "00ff00"]
          snapshot = RepoSnapshot [] [pullRequest] epoch False False
          Board customColumns = deriveBoard config snapshot
          Board defaultColumns = deriveBoard defaultWorkflowConfig snapshot
      map itemNumber (map entryItem (Map.findWithDefault [] Done customColumns)) `shouldBe` [10]
      map itemNumber (map entryItem (Map.findWithDefault [] Done defaultColumns)) `shouldBe` []
