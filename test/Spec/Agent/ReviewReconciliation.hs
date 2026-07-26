-- | Reconciling review sessions against a refreshed board.
module Spec.Agent.ReviewReconciliation (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Text
import Kanban.Domain
import Kanban.Review (ReviewStage (..))
import Kanban.UI
  ( ChatTranscript (..),
    ReviewPhase (..),
    ReviewSession (..),
    reconcileReviewSessions,
    reviewPhaseAttribute,
    reviewPhaseGlyphFor,
    reviewPhaseLabel,
    revisedAttr
  )
import Spec.Support.Fixtures (baseIssue)
import Test.Hspec

spec :: Spec
spec = do
  describe "issue-revision refresh reconciliation" $ do
    -- issue #72: a completed issue-revision that posted its amendment and
    -- landed `reviewed:revised` was still shown as a failed revision after
    -- the board refreshed, because reconcileReviewSessions only recovered
    -- reviewed:approve and reviewed:changes. A failed issue-revision session
    -- refreshed against a reviewed:revised issue must now surface as the
    -- purple "awaiting rereview" state instead.
    let failedRevisionSession issue =
          ReviewSession
            { reviewSessionIssue = issue,
              reviewSessionStage = IssueRevision,
              reviewSessionThreadId = Nothing,
              reviewSessionTurnId = Nothing,
              reviewSessionPhase = ReviewFailed,
              reviewSessionActivity = "failed",
              reviewSessionTranscript = ChatTranscript "" "" "",
              reviewSessionPending = Nothing,
              reviewSessionInput = "",
              reviewSessionUndelivered = [],
              reviewSessionSpinnerFrame = 0,
              reviewSessionTickGeneration = 0,
              reviewSessionTickArmed = False,
              reviewSessionFollowing = True
            }
        reconciledPhaseFor issue session =
          (reconcileReviewSessions defaultWorkflowConfig [issue] (Map.singleton issue.issueNumber session) Map.! issue.issueNumber).reviewSessionPhase

    it "reconciles a failed issue-revision session to the revised state once the issue carries reviewed:revised" $ do
      let issue = (baseIssue 59 []) {issueLabels = [Label "reviewed:revised" "8250DF"]}
          session = failedRevisionSession issue
      reconciledPhaseFor issue session `shouldBe` ReviewRevised

    it "presents the revised state with the purple attribute and awaiting-rereview text, not the failure presentation" $ do
      let phase = ReviewRevised
          failedSession = failedRevisionSession (baseIssue 59 [])
          revisedSession = failedSession {reviewSessionPhase = phase}
      reviewPhaseAttribute phase `shouldBe` revisedAttr
      reviewPhaseAttribute phase `shouldNotBe` reviewPhaseAttribute ReviewFailed
      Data.Text.unpack (reviewPhaseLabel revisedSession) `shouldNotContain` "failed"
      reviewPhaseGlyphFor False revisedSession `shouldNotBe` reviewPhaseGlyphFor False failedSession
      reviewPhaseGlyphFor True revisedSession `shouldNotBe` reviewPhaseGlyphFor True failedSession

    it "leaves a failed issue-revision session genuinely failed when reviewed:revised is absent" $ do
      let issue = baseIssue 59 []
          session = failedRevisionSession issue
      reconciledPhaseFor issue session `shouldBe` ReviewFailed
      reviewPhaseAttribute ReviewFailed `shouldBe` reviewPhaseAttribute (reconciledPhaseFor issue session)
      Data.Text.unpack (reviewPhaseLabel session {reviewSessionPhase = reconciledPhaseFor issue session}) `shouldContain` "failed"

    it "matches a mixed-case reviewed:revised label the same as the canonical casing" $ do
      let issue = (baseIssue 59 []) {issueLabels = [Label "ReViEwEd:ReViSeD" "8250DF"]}
          session = failedRevisionSession issue
      reconciledPhaseFor issue session `shouldBe` ReviewRevised

    it "does not let a stray reviewed:revised label mask a failed rereview session" $ do
      let issue = (baseIssue 59 []) {issueLabels = [Label "reviewed:revised" "8250DF"]}
          session = (failedRevisionSession issue) {reviewSessionStage = IssueRereview}
      reconciledPhaseFor issue session `shouldBe` ReviewFailed

    it "keeps reviewed:approve as top precedence over a coincident reviewed:revised label" $ do
      let issue = (baseIssue 59 []) {issueLabels = [Label "reviewed:approve" "0e8a16", Label "reviewed:revised" "8250DF"]}
          session = failedRevisionSession issue
      reconciledPhaseFor issue session `shouldBe` ReviewFinished
