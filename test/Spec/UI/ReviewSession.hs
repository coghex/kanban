-- | The review session's overlays: dispatch, liveness and quit protection,
-- animation, and the transcript the user follows.
module Spec.UI.ReviewSession (spec) where

import Brick (BrickEvent (..), Location (..))
import Data.Aeson (Value (..))
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Set as Set
import qualified Data.Text
import qualified Graphics.Vty as Vty
import Kanban.Domain
import Kanban.Review
  ( ReviewApproval (..),
    ReviewChoice (..),
    ReviewQuestion (..),
    ReviewQuestionKind (..),
    ReviewRequestId (..),
    ReviewStage (..)
  )
import Kanban.UI.Board (reviewPhaseGlyphFor)
import Kanban.UI.Events (OverlayMouseAction (..), overlayMouseAction)
import Kanban.UI.Overlay (reviewPhaseLabel)
import Kanban.UI.Reconcile (reconcileReviewSessions)
import Kanban.UI.Review
  ( ReviewCancelAction (..),
    ReviewDigitAction (..),
    canonicalReviewCompletionSuperseded,
    resolveReviewCancelAction,
    resolveReviewDigitAction,
    reviewSessionsNeedingArm,
  )
import Kanban.UI.Session
  ( liveReviewSessions,
    resolveProcessClick,
    resolveProcessSelection,
    reviewAgentSessionEntry,
    reviewSessionLive,
    reviewSessionReusable,
    reviewTurnInterruptible,
  )
import Kanban.UI.SessionCore
  ( SessionTickArm (..),
    SessionTickFire (..),
    decideSessionTickArm,
    decideSessionTickFire,
    newAgentSession,
    transcriptScrollKey,
  )
import Kanban.UI.SessionEvents (reviewTickEligible)
import Kanban.UI.Theme (reviewPhaseAttribute, revisedAttr)
import Kanban.UI.Transcript
  ( TranscriptGeometry (..),
    TranscriptSession (..),
    displayedTranscript,
    followAfterScroll,
    followAfterTurnStarted,
    transcriptShouldTail,
  )
import Kanban.UI.Types
  ( AgentSession (..),
    AgentSessionEntry (..),
    AgentSessionRef (..),
    ChatTranscript (..),
    Name (..),
    Overlay (..),
    PendingReviewInteraction (..),
    ProcessClickOutcome (..),
    ProcessSelection (..),
    ReviewDetail (..),
    ReviewPhase (..),
    ReviewSession,
    withSessionDetail,
  )
import Kanban.Worker (WorkerId (..))
import Spec.Support.Fixtures (baseIssue)
import Test.Hspec

spec :: Spec
spec = do
  describe "review overlay digit dispatch" $ do
    let requestId = ReviewRequestId (String "req-1")
        choices = [ReviewChoice "keep" "Keep compatibility" "Preserve callers", ReviewChoice "break" "Break compatibility" ""]
        textQuestion allowOther =
          ReviewQuestion
            { reviewQuestionId = "scope",
              reviewQuestionHeader = "SCOPE",
              reviewQuestionText = "How many retries?",
              reviewQuestionKind = QuestionText,
              reviewQuestionChoices = [],
              reviewQuestionAllowOther = allowOther,
              reviewQuestionMultiple = False
            }
        choiceQuestion allowOther =
          ReviewQuestion
            { reviewQuestionId = "scope",
              reviewQuestionHeader = "SCOPE",
              reviewQuestionText = "Which contract?",
              reviewQuestionKind = QuestionChoice,
              reviewQuestionChoices = choices,
              reviewQuestionAllowOther = allowOther,
              reviewQuestionMultiple = False
            }
        approval = ReviewApproval Nothing Nothing False

    it "appends free-text digits instead of treating them as choice selections" $ do
      -- A QuestionText pending interaction must take precedence over any
      -- choices/allowOther it happens to carry (issue #3 spec addition).
      resolveReviewDigitAction (Just (PendingReviewQuestion requestId (textQuestion False))) 2 `shouldBe` ReviewDigitAppend
      resolveReviewDigitAction (Just (PendingReviewQuestion requestId (textQuestion True))) 8 `shouldBe` ReviewDigitAppend

    it "selects an in-range choice by its 1-based digit" $ do
      resolveReviewDigitAction (Just (PendingReviewQuestion requestId (choiceQuestion False))) 0
        `shouldBe` ReviewDigitSelectChoice requestId (ReviewChoice "keep" "Keep compatibility" "Preserve callers")
      resolveReviewDigitAction (Just (PendingReviewQuestion requestId (choiceQuestion False))) 1
        `shouldBe` ReviewDigitSelectChoice requestId (ReviewChoice "break" "Break compatibility" "")

    it "appends an out-of-range choice digit when free text is also accepted" $
      resolveReviewDigitAction (Just (PendingReviewQuestion requestId (choiceQuestion True))) 5 `shouldBe` ReviewDigitAppend

    it "reports an out-of-range choice digit unavailable when free text is not accepted" $
      resolveReviewDigitAction (Just (PendingReviewQuestion requestId (choiceQuestion False))) 5
        `shouldBe` ReviewDigitUnavailable "That review choice is not available"

    it "keeps approval digit handling exactly as before" $ do
      resolveReviewDigitAction (Just (PendingReviewApproval requestId approval)) 0 `shouldBe` ReviewDigitApprovalOnce requestId
      resolveReviewDigitAction (Just (PendingReviewApproval requestId approval)) 1 `shouldBe` ReviewDigitApprovalSession requestId
      resolveReviewDigitAction (Just (PendingReviewApproval requestId approval)) 2 `shouldBe` ReviewDigitApprovalDecline requestId
      resolveReviewDigitAction (Just (PendingReviewApproval requestId approval)) 5
        `shouldBe` ReviewDigitUnavailable "That approval choice is not available"

    it "appends digits when nothing is pending" $
      resolveReviewDigitAction Nothing 4 `shouldBe` ReviewDigitAppend

  describe "review overlay Ctrl-C cancel dispatch" $ do
    -- issue #31: canonical review stages (InitialReview/IssueRereview) have
    -- no app-server thread/turn, so the pre-existing app-server-only
    -- dispatch reported "no active turn to cancel" even while their
    -- ManagedProcess was still running. 'resolveReviewCancelAction' is the
    -- pure routing extracted from 'cancelReviewSession' so each branch is
    -- unconditionally covered without an 'EventM' harness.
    it "routes a ready app-server turn to the interrupt-turn action, unchanged" $ do
      resolveReviewCancelAction True (Just "thread-1") (Just "turn-1") IssueRevision ReviewRunning False
        `shouldBe` ReviewCancelInterruptTurn "thread-1" "turn-1"
      resolveReviewCancelAction False Nothing Nothing IssueRevision ReviewStarting False
        `shouldBe` ReviewCancelNoActiveTurn

    it "routes a live canonical process to the interrupt-process action" $ do
      resolveReviewCancelAction False Nothing Nothing InitialReview ReviewRunning True
        `shouldBe` ReviewCancelInterruptProcess
      resolveReviewCancelAction False Nothing Nothing IssueRereview ReviewRunning True
        `shouldBe` ReviewCancelInterruptProcess

    it "gives a truthful notice for a canonical stage with no live process" $ do
      resolveReviewCancelAction False Nothing Nothing InitialReview ReviewFinished False
        `shouldBe` ReviewCancelNotRunning
      resolveReviewCancelAction False Nothing Nothing InitialReview ReviewInterrupted False
        `shouldBe` ReviewCancelNotRunning
      resolveReviewCancelAction False Nothing Nothing InitialReview ReviewStarting False
        `shouldBe` ReviewCancelStillStarting

  describe "review session liveness, quit protection, and the x gate" $ do
    -- issue #151: the processes overlay, the `x` gate that dispatches on
    -- its rows, and the dashboard quit guard each re-implemented "live"
    -- differently, so a revision waiting on a question or approval blocked
    -- `q` while the overlay called the same session dead and refused `x`.
    -- 'reviewSessionLive' is now the one decision all three consume, and it
    -- means *currently killable*: the session has a target 'killReviewAgent'
    -- can act on. These are the pure decisions behind those call sites, so
    -- the whole input matrix is covered without an 'EventM' harness.
    let reviewedIssue = 151
        sessionFor (_, _, stage, phase, threadId, turnId) =
          newAgentSession
            0
            phase
            ""
            Nothing
            (ChatTranscript "" "" "")
            ReviewDetail
              { reviewSessionIssue = baseIssue reviewedIssue [],
                reviewSessionStage = stage,
                reviewSessionThreadId = threadId,
                reviewSessionTurnId = turnId,
                reviewSessionPending = Nothing,
                reviewSessionUndelivered = []
              }
        canonicalProcesses hasProcess = if hasProcess then Set.singleton reviewedIssue else Set.empty
        allPhases =
          [ ReviewStarting,
            ReviewRunning,
            ReviewWaiting,
            ReviewFinished,
            ReviewNeedsChanges,
            ReviewFailed,
            ReviewRevised,
            ReviewInterrupted
          ]
        allStages = [InitialReview, IssueRevision, IssueRereview]
        -- Every input the kill target depends on: phase, stage,
        -- canonical-process presence, backend readiness, and both IDs.
        killTargetInputs =
          [ (backendReady, hasProcess, stage, phase, threadId, turnId)
            | backendReady <- [False, True],
              hasProcess <- [False, True],
              stage <- allStages,
              phase <- allPhases,
              threadId <- [Nothing, Just "thread-1"],
              turnId <- [Nothing, Just "turn-1"]
          ]
        -- The issue's rule restated independently of the code under test.
        expectedLive (backendReady, hasProcess, stage, phase, threadId, turnId) =
          hasProcess
            || ( stage == IssueRevision
                   && phase `elem` [ReviewStarting, ReviewRunning, ReviewWaiting]
                   && backendReady
                   && isJust threadId
                   && isJust turnId
               )
        sharedLive inputs@(backendReady, hasProcess, _, _, _, _) =
          reviewSessionLive backendReady hasProcess (sessionFor inputs)
        overlayLive inputs@(backendReady, hasProcess, _, _, _, _) =
          (reviewAgentSessionEntry backendReady hasProcess reviewedIssue (sessionFor inputs)).agentSessionLive
        quitBlocked inputs@(backendReady, hasProcess, _, _, _, _) =
          liveReviewSessions backendReady (canonicalProcesses hasProcess) (Map.singleton reviewedIssue (sessionFor inputs))
            == [reviewedIssue]
        -- Every combination whose answer disagrees with the rule above,
        -- tagged with its inputs, so a failure names the exact
        -- combinations rather than reporting "True /= False" or dumping
        -- the whole matrix.
        wrongAnswers decide = [(inputs, decide inputs) | inputs <- killTargetInputs, decide inputs /= expectedLive inputs]

    it "covers every combination of phase, stage, canonical process, backend readiness, and both IDs" $ do
      length killTargetInputs `shouldBe` 384
      (any expectedLive killTargetInputs, all expectedLive killTargetInputs) `shouldBe` (True, False)

    it "reports a review session live exactly when it currently has a kill target" $
      wrongAnswers sharedLive `shouldBe` []

    it "keeps the processes overlay and the quit guard agreeing over the whole matrix" $ do
      wrongAnswers overlayLive `shouldBe` []
      wrongAnswers quitBlocked `shouldBe` []

    it "keeps a waiting revision live and routes x to its interruptible turn" $ do
      let waiting = (True, False, IssueRevision, ReviewWaiting, Just "thread-1", Just "turn-1")
          session = sessionFor waiting
      sharedLive waiting `shouldBe` True
      overlayLive waiting `shouldBe` True
      liveReviewSessions True Set.empty (Map.singleton reviewedIssue session) `shouldBe` [reviewedIssue]
      -- The gate hands a live review row to 'killReviewAgent', whose turn
      -- branch takes the recorded thread and turn under exactly this
      -- condition, so `x` interrupts the turn instead of reporting no live
      -- process to kill.
      reviewTurnInterruptible IssueRevision ReviewWaiting `shouldBe` True

    it "leaves a canonical stage quittable until its process is registered" $ do
      let starting = (True, False, InitialReview, ReviewStarting, Nothing, Nothing)
      sharedLive starting `shouldBe` False
      overlayLive starting `shouldBe` False
      liveReviewSessions True Set.empty (Map.singleton reviewedIssue (sessionFor starting)) `shouldBe` []

    it "leaves a starting revision quittable until its backend is ready and it has both IDs" $
      mapM_
        (\inputs -> (inputs, sharedLive inputs, overlayLive inputs, quitBlocked inputs) `shouldBe` (inputs, False, False, False))
        [ (False, False, IssueRevision, ReviewStarting, Nothing, Nothing),
          (False, False, IssueRevision, ReviewStarting, Just "thread-1", Just "turn-1"),
          (True, False, IssueRevision, ReviewStarting, Nothing, Nothing),
          (True, False, IssueRevision, ReviewStarting, Just "thread-1", Nothing),
          (True, False, IssueRevision, ReviewStarting, Nothing, Just "turn-1")
        ]

    it "keeps a registered canonical process live and killable whatever the session phase" $
      mapM_
        ( \phase -> do
            let withProcess = (False, True, InitialReview, phase, Nothing, Nothing)
            sharedLive withProcess `shouldBe` True
            overlayLive withProcess `shouldBe` True
            quitBlocked withProcess `shouldBe` True
            -- No interruptible turn, so 'killReviewAgent' reaches the
            -- unchanged canonical process-kill branch for this row.
            reviewTurnInterruptible InitialReview phase `shouldBe` False
            (reviewAgentSessionEntry False True reviewedIssue (sessionFor withProcess)).agentSessionRef
              `shouldBe` ReviewAgent reviewedIssue
        )
        allPhases

    it "stops counting a just-killed revision as live while it still carries its turn ID" $ do
      -- 'killReviewAgent' leaves the session ReviewFailed without clearing
      -- the thread and turn IDs, so without the phase condition `q` would
      -- stay refused after the kill and a second `x` would pass the gate
      -- only to hit the no-live-process notice.
      let killed = (True, False, IssueRevision, ReviewFailed, Just "thread-1", Just "turn-1")
      sharedLive killed `shouldBe` False
      overlayLive killed `shouldBe` False
      quitBlocked killed `shouldBe` False
      reviewTurnInterruptible IssueRevision ReviewFailed `shouldBe` False

  describe "canonical review completion vs. cancellation" $ do
    -- issue #31 spec addition: a canonical process's completion event can
    -- arrive after the user already Ctrl-C'd the session; that late
    -- completion must not overwrite the ReviewInterrupted terminal phase.
    it "supersedes a late completion only once the session has been interrupted" $ do
      canonicalReviewCompletionSuperseded ReviewInterrupted `shouldBe` True
      mapM_
        (\phase -> canonicalReviewCompletionSuperseded phase `shouldBe` False)
        [ReviewStarting, ReviewRunning, ReviewWaiting, ReviewFinished, ReviewNeedsChanges, ReviewFailed]

  describe "review session same-stage retry eligibility" $ do
    -- issue #31 spec addition: after a canonical stage is interrupted, 'r'
    -- must launch a fresh label-derived stage rather than reopen the
    -- cancelled session -- but only once the prior invocation's process has
    -- actually finished, so a fresh launch never races its still-pending
    -- completion event.
    it "reuses a live session regardless of stage" $ do
      mapM_
        (\phase -> reviewSessionReusable phase InitialReview InitialReview False `shouldBe` True)
        [ReviewStarting, ReviewRunning, ReviewWaiting]
      reviewSessionReusable ReviewRunning InitialReview IssueRereview False `shouldBe` True

    it "reuses a finished session whose recorded stage still matches what labels request" $
      reviewSessionReusable ReviewFinished InitialReview InitialReview False `shouldBe` True

    it "does not reuse a finished session once labels request a different stage" $
      reviewSessionReusable ReviewNeedsChanges InitialReview IssueRereview False `shouldBe` False

    it "forces a fresh launch for an interrupted canonical stage once its process is gone" $
      reviewSessionReusable ReviewInterrupted InitialReview InitialReview False `shouldBe` False

    it "keeps reusing an interrupted session while its kill is still in flight" $
      reviewSessionReusable ReviewInterrupted InitialReview InitialReview True `shouldBe` True

    it "reuses an interrupted app-server revision when its stage is unchanged" $
      reviewSessionReusable ReviewInterrupted IssueRevision IssueRevision False `shouldBe` True

  describe "review animation tick decisions" $ do
    -- issue #30: answering a question/approval and the backend's matching
    -- 'ReviewTurnStarted' notification each used to call the tick
    -- scheduler unconditionally, arming two independent 10 Hz chains for
    -- the same turn; canonical (thread-less) sessions had no tick path at
    -- all. 'decideSessionTickArm'/'decideSessionTickFire' are the pure
    -- decision core extracted from 'armReviewTick'/
    -- 'applyReviewAnimationTick' so every transition is covered without an
    -- 'EventM' harness.
    it "arms a fresh chain only when eligible and not already armed" $ do
      decideSessionTickArm (reviewTickEligible True ReviewRunning) False 0 `shouldBe` ArmSessionTick 1
      decideSessionTickArm (reviewTickEligible True ReviewStarting) False 5 `shouldBe` ArmSessionTick 6

    it "coalesces a repeated trigger onto the chain already in flight" $
      decideSessionTickArm (reviewTickEligible True ReviewRunning) True 1 `shouldBe` SessionTickAlreadyArmed

    it "does not arm a chain outside the eligible phases, even if visible" $
      mapM_
        (\phase -> decideSessionTickArm (reviewTickEligible True phase) False 0 `shouldBe` SessionTickNotEligible)
        [ReviewWaiting, ReviewFinished, ReviewNeedsChanges, ReviewFailed, ReviewRevised, ReviewInterrupted]

    it "does not arm a chain while the review overlay is hidden" $
      decideSessionTickArm (reviewTickEligible False ReviewRunning) False 0 `shouldBe` SessionTickNotEligible

    it "drops a tick carrying a stale generation instead of rescheduling" $
      decideSessionTickFire 2 1 (reviewTickEligible True ReviewRunning) `shouldBe` SessionTickStale

    it "reschedules a tick that matches the current generation while still eligible" $
      decideSessionTickFire 1 1 (reviewTickEligible True ReviewRunning) `shouldBe` SessionTickReschedule

    it "expires a matching tick once the phase transitions to terminal, unarming the session" $
      mapM_
        (\phase -> decideSessionTickFire 1 1 (reviewTickEligible True phase) `shouldBe` SessionTickExpire)
        [ReviewFinished, ReviewNeedsChanges, ReviewFailed, ReviewRevised, ReviewInterrupted, ReviewWaiting]

    it "expires a matching tick once the review overlay is hidden" $
      decideSessionTickFire 1 1 (reviewTickEligible False ReviewRunning) `shouldBe` SessionTickExpire

    it "answer-then-turn-started keeps exactly one live generation" $ do
      -- A chain is already armed (generation 1) from the turn that produced
      -- the question. The user answers before that tick fires: the answer
      -- path's arm request coalesces rather than minting generation 2.
      decideSessionTickArm (reviewTickEligible True ReviewRunning) True 1 `shouldBe` SessionTickAlreadyArmed
      -- The backend's ReviewTurnStarted for the same turn arrives next and
      -- also coalesces onto the same still-armed chain.
      decideSessionTickArm (reviewTickEligible True ReviewRunning) True 1 `shouldBe` SessionTickAlreadyArmed

    it "resolves the verified fast-resume race onto a single chain" $ do
      -- Generation 1 is armed while ReviewRunning, with its tick already
      -- scheduled. A question arrives (ReviewWaiting); armed stays True,
      -- only the phase changes -- the chain is still in flight.
      -- The user answers before that tick fires: phase returns to
      -- ReviewRunning and the answer's arm request coalesces, since
      -- generation 1 is still armed.
      decideSessionTickArm (reviewTickEligible True ReviewRunning) True 1 `shouldBe` SessionTickAlreadyArmed
      -- The original in-flight tick for generation 1 then fires: it
      -- matches the still-current generation and the phase is running
      -- again, so it reschedules that same chain rather than a second one
      -- having been spawned alongside it.
      decideSessionTickFire 1 1 (reviewTickEligible True ReviewRunning) `shouldBe` SessionTickReschedule

    it "arms exactly one chain across a canonical session's lifecycle" $ do
      -- CanonicalIssueReviewProcessStarted arms the first chain while the
      -- session sits in ReviewStarting for the whole run (canonical stages
      -- have no thread/turn, so this is their only tick trigger).
      decideSessionTickArm (reviewTickEligible True ReviewStarting) False 0 `shouldBe` ArmSessionTick 1
      -- Further ticks against generation 1 reschedule the same chain for
      -- as long as the process keeps running.
      decideSessionTickFire 1 1 (reviewTickEligible True ReviewStarting) `shouldBe` SessionTickReschedule
      -- The process finishes; the session's phase leaves ReviewStarting.
      -- The next tick for generation 1 expires rather than rescheduling.
      decideSessionTickFire 1 1 (reviewTickEligible True ReviewFinished) `shouldBe` SessionTickExpire
      -- No further chain arms once the session is terminal.
      decideSessionTickArm (reviewTickEligible True ReviewFinished) False 1 `shouldBe` SessionTickNotEligible

    it "expires while hidden and arms exactly one fresh chain on reopen" $ do
      -- The overlay closes while a turn is still running: the in-flight
      -- tick for generation 1 expires (unarms) rather than rescheduling.
      decideSessionTickFire 1 1 (reviewTickEligible False ReviewRunning) `shouldBe` SessionTickExpire
      -- Reopening the overlay re-checks eligibility with armed now False,
      -- arming exactly one fresh chain (generation 2) for the session.
      decideSessionTickArm (reviewTickEligible True ReviewRunning) False 1 `shouldBe` ArmSessionTick 2

    -- issue #30 follow-up (round 1 review): reopening the review overlay,
    -- or Tab-cycling within it, must resume every still-running session's
    -- spinner, not only the one being explicitly opened or focused next --
    -- a different session's chain can have expired while the overlay was
    -- closed. 'reviewSessionsNeedingArm' is what 'armVisibleReviewTicks'
    -- sweeps across all sessions to find and re-arm exactly those.
    let tickSession :: ReviewPhase -> Bool -> ReviewSession
        tickSession phase armed =
          ( newAgentSession
              0
              phase
              ""
              Nothing
              (ChatTranscript "" "" "")
              ReviewDetail
                { reviewSessionIssue = baseIssue 1 [],
                  reviewSessionStage = InitialReview,
                  reviewSessionThreadId = Nothing,
                  reviewSessionTurnId = Nothing,
                  reviewSessionPending = Nothing,
                  reviewSessionUndelivered = []
                }
          )
            {sessionTickArmed = armed}

    it "finds a still-running session left unarmed behind another tab" $ do
      let sessions = Map.fromList [(1, tickSession ReviewRunning False), (2, tickSession ReviewRunning True)]
      reviewSessionsNeedingArm True sessions `shouldBe` [1]
      reviewSessionsNeedingArm False sessions `shouldBe` []

    it "does not flag a terminal or an already-armed session for arming" $ do
      reviewSessionsNeedingArm True (Map.singleton 1 (tickSession ReviewFinished False)) `shouldBe` []
      reviewSessionsNeedingArm True (Map.singleton 1 (tickSession ReviewRunning True)) `shouldBe` []

    -- issue #30 round-2/round-3 review: 'startIssueReview' discards a
    -- non-reusable session (e.g. its recorded stage no longer matches
    -- current labels) and replaces it with a genuinely fresh one for the
    -- same issue number. A tick the *old* session already queued can
    -- still be delivered, carrying whatever generation it last armed.
    it "would collide with a replaced session's stale in-flight tick if the generation reset to 0" $ do
      -- The old session reached generation 1 before being replaced, and
      -- left a tick in flight still carrying that generation.
      let staleTickGeneration = 1
      -- A from-scratch replacement session resets to generation 0, so it
      -- does not yet collide with the stale tick while unarmed...
      decideSessionTickFire 0 staleTickGeneration (reviewTickEligible True ReviewStarting) `shouldBe` SessionTickStale
      -- ...but once that session's own first arm mints generation 1, the
      -- stale tick matches it exactly and incorrectly reschedules.
      decideSessionTickArm (reviewTickEligible True ReviewStarting) False 0 `shouldBe` ArmSessionTick 1
      decideSessionTickFire 1 staleTickGeneration (reviewTickEligible True ReviewStarting) `shouldBe` SessionTickReschedule

    it "carrying the prior generation forward without bumping it still collides before the replacement's first arm" $ do
      -- Seeding the replacement at exactly the old session's last
      -- generation (rather than resetting to 0) is not sufficient on its
      -- own: a queued stale tick arriving *before* the replacement's own
      -- first arm still matches it exactly.
      let staleTickGeneration = 1
          seededButNotYetArmed = staleTickGeneration
      decideSessionTickFire seededButNotYetArmed staleTickGeneration (reviewTickEligible True ReviewStarting) `shouldBe` SessionTickReschedule

    it "bumps the generation at replacement time so a queued stale tick is dropped even before the replacement's first arm" $ do
      let staleTickGeneration = 1 -- the old session's last-armed generation
          replacementGeneration = staleTickGeneration + 1 -- newReviewSession's construction-time generation
      -- The stale tick is dropped immediately, before the replacement
      -- session has armed any chain of its own.
      decideSessionTickFire replacementGeneration staleTickGeneration (reviewTickEligible True ReviewStarting) `shouldBe` SessionTickStale
      -- Its own eventual first arm mints a generation still further past
      -- the stale tick's, so the collision cannot resurface later either.
      decideSessionTickArm (reviewTickEligible True ReviewStarting) False replacementGeneration `shouldBe` ArmSessionTick (replacementGeneration + 1)
      decideSessionTickFire (replacementGeneration + 1) staleTickGeneration (reviewTickEligible True ReviewStarting) `shouldBe` SessionTickStale

  describe "issue-revision refresh reconciliation" $ do
    -- issue #72: a completed issue-revision that posted its amendment and
    -- landed `reviewed:revised` was still shown as a failed revision after
    -- the board refreshed, because reconcileReviewSessions only recovered
    -- reviewed:approve and reviewed:changes. A failed issue-revision session
    -- refreshed against a reviewed:revised issue must now surface as the
    -- purple "awaiting rereview" state instead.
    let failedRevisionSession :: Issue -> ReviewSession
        failedRevisionSession issue =
          newAgentSession
            0
            ReviewFailed
            "failed"
            Nothing
            (ChatTranscript "" "" "")
            ReviewDetail
              { reviewSessionIssue = issue,
                reviewSessionStage = IssueRevision,
                reviewSessionThreadId = Nothing,
                reviewSessionTurnId = Nothing,
                reviewSessionPending = Nothing,
                reviewSessionUndelivered = []
              }
        reconciledPhaseFor issue session =
          (reconcileReviewSessions defaultWorkflowConfig [issue] (Map.singleton issue.issueNumber session) Map.! issue.issueNumber).sessionPhase

    it "reconciles a failed issue-revision session to the revised state once the issue carries reviewed:revised" $ do
      let issue = (baseIssue 59 []) {issueLabels = [Label "reviewed:revised" "8250DF"]}
          session = failedRevisionSession issue
      reconciledPhaseFor issue session `shouldBe` ReviewRevised

    it "presents the revised state with the purple attribute and awaiting-rereview text, not the failure presentation" $ do
      let phase = ReviewRevised
          failedSession = failedRevisionSession (baseIssue 59 [])
          revisedSession = failedSession {sessionPhase = phase}
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
      Data.Text.unpack (reviewPhaseLabel session {sessionPhase = reconciledPhaseFor issue session}) `shouldContain` "failed"

    it "matches a mixed-case reviewed:revised label the same as the canonical casing" $ do
      let issue = (baseIssue 59 []) {issueLabels = [Label "ReViEwEd:ReViSeD" "8250DF"]}
          session = failedRevisionSession issue
      reconciledPhaseFor issue session `shouldBe` ReviewRevised

    it "does not let a stray reviewed:revised label mask a failed rereview session" $ do
      let issue = (baseIssue 59 []) {issueLabels = [Label "reviewed:revised" "8250DF"]}
          session = withSessionDetail (\detail -> detail {reviewSessionStage = IssueRereview}) (failedRevisionSession issue)
      reconciledPhaseFor issue session `shouldBe` ReviewFailed

    it "keeps reviewed:approve as top precedence over a coincident reviewed:revised label" $ do
      let issue = (baseIssue 59 []) {issueLabels = [Label "reviewed:approve" "0e8a16", Label "reviewed:revised" "8250DF"]}
          session = failedRevisionSession issue
      reconciledPhaseFor issue session `shouldBe` ReviewFinished

  describe "processes overlay selection resolution" $ do
    let sessionEntry ref =
          AgentSessionEntry
            { agentSessionRef = ref,
              agentSessionLabel = "label",
              agentSessionProvider = "provider",
              agentSessionStatus = "status",
              agentSessionActivity = "activity",
              agentSessionId = Nothing,
              agentSessionLive = True,
              agentSessionProblem = False
            }
        solve = sessionEntry . SolveAgent

    it "keeps the clamped entry as the target when the list shrinks past the selection" $ do
      let selection = ProcessSelection (Just (SolveAgent 5)) 4
          shrunk = [solve 1, solve 2]
      resolveProcessSelection shrunk selection `shouldBe` ProcessSelection (Just (SolveAgent 2)) 1

    it "follows the selected identity across a reorder instead of the row" $ do
      let selection = ProcessSelection (Just (SolveAgent 2)) 1
          reordered = [solve 2, solve 1, solve 3]
      resolveProcessSelection reordered selection `shouldBe` ProcessSelection (Just (SolveAgent 2)) 0

    it "falls back to the nearest remaining row when the selected session disappears" $ do
      let selection = ProcessSelection (Just (WorkerAgent (WorkerId "w1"))) 2
          remaining = [solve 1, solve 2]
      resolveProcessSelection remaining selection `shouldBe` ProcessSelection (Just (SolveAgent 2)) 1

    it "resolves to no selection when no sessions remain" $
      resolveProcessSelection [] (ProcessSelection (Just (SolveAgent 1)) 0) `shouldBe` ProcessSelection Nothing 0

    it "adopts the fallback entry as canonical so a later reorder follows it, not the vanished identity" $ do
      let selection = ProcessSelection (Just (WorkerAgent (WorkerId "w1"))) 2
          afterDisappearance = [solve 1, solve 2, solve 3]
          afterReorder = [solve 3, solve 2, solve 1]
          resolvedOnce = resolveProcessSelection afterDisappearance selection
          resolvedTwice = resolveProcessSelection afterReorder resolvedOnce
      resolvedOnce `shouldBe` ProcessSelection (Just (SolveAgent 3)) 2
      resolvedTwice `shouldBe` ProcessSelection (Just (SolveAgent 3)) 0

    it "resolves a click by the identity rendered at that row, not the row itself, across a pre-dispatch reorder" $ do
      let selection = ProcessSelection (Just (SolveAgent 1)) 0
          reorderedBeforeDispatch = [solve 3, solve 1, solve 2]
      resolveProcessClick reorderedBeforeDispatch selection (SolveAgent 2)
        `shouldBe` ProcessClickSelect (ProcessSelection (Just (SolveAgent 2)) 2)
      resolveProcessClick reorderedBeforeDispatch selection (SolveAgent 1)
        `shouldBe` ProcessClickOpen
      resolveProcessClick [solve 1, solve 2] selection (SolveAgent 9)
        `shouldBe` ProcessClickIgnored

  describe "overlay mouse dispatch" $ do
    let backgroundCard = CardTarget Issues 0
        zeroLoc = Location (0, 0)
        rawWheel button = VtyEvent (Vty.EvMouseDown 0 0 button [])
        overlays =
          [ ("review overlay", ReviewPanel, ReviewViewport),
            ("solve overlay", SolvePanel, SolveViewport),
            ("pull request review overlay", PullRequestReviewPanel, PullRequestReviewViewport),
            ("details overlay", DetailsPanel, DetailsViewport)
          ]

    mapM_
      ( \(label, panel, viewport) -> describe label $ do
          it "scrolls, without closing, when the wheel lands on a background clickable" $ do
            overlayMouseAction panel (MouseDown backgroundCard Vty.BScrollUp [] zeroLoc) `shouldBe` Just (OverlayMouseScroll (-3))
            overlayMouseAction panel (MouseDown backgroundCard Vty.BScrollDown [] zeroLoc) `shouldBe` Just (OverlayMouseScroll 3)

          it "scrolls on a raw Vty wheel event that carries no Brick name at all" $ do
            overlayMouseAction panel (rawWheel Vty.BScrollUp) `shouldBe` Just (OverlayMouseScroll (-3))
            overlayMouseAction panel (rawWheel Vty.BScrollDown) `shouldBe` Just (OverlayMouseScroll 3)

          it "scrolls when the wheel lands on the overlay's own viewport or panel" $ do
            overlayMouseAction panel (MouseDown viewport Vty.BScrollUp [] zeroLoc) `shouldBe` Just (OverlayMouseScroll (-3))
            overlayMouseAction panel (MouseDown viewport Vty.BScrollDown [] zeroLoc) `shouldBe` Just (OverlayMouseScroll 3)
            overlayMouseAction panel (MouseDown panel Vty.BScrollUp [] zeroLoc) `shouldBe` Just (OverlayMouseScroll (-3))
            overlayMouseAction panel (MouseDown panel Vty.BScrollDown [] zeroLoc) `shouldBe` Just (OverlayMouseScroll 3)

          it "closes on an outside click, left or right, named or raw" $ do
            overlayMouseAction panel (MouseDown backgroundCard Vty.BLeft [] zeroLoc) `shouldBe` Just OverlayMouseClose
            overlayMouseAction panel (MouseDown backgroundCard Vty.BRight [] zeroLoc) `shouldBe` Just OverlayMouseClose
            overlayMouseAction panel (rawWheel Vty.BLeft) `shouldBe` Just OverlayMouseClose

          it "closes the panel on a right click but leaves a left click on the panel inert" $ do
            overlayMouseAction panel (MouseDown panel Vty.BRight [] zeroLoc) `shouldBe` Just OverlayMouseClose
            overlayMouseAction panel (MouseDown panel Vty.BLeft [] zeroLoc) `shouldBe` Just OverlayMouseNoOp
       )
       overlays

  describe "live transcript follow state" $ do
    -- issue #39: every output delta used to force its transcript viewport
    -- to the end -- the review path did so even for a hidden overlay or a
    -- background tab -- so scrolling back during a running turn was
    -- impossible. 'tailTranscript', 'scrollTranscript', and
    -- 'presentTranscriptTail' run in brick's 'EventM', which a unit test
    -- cannot drive against a plain state; these cover the pure decisions
    -- those are assembled from: which transcript an overlay displays,
    -- whether an event may tail it, where a scroll gesture lands, which
    -- keys are scroll gestures at all, and what a turn start does.
    let solveOverlay = Just (SolveOverlay 39)
        reviewOverlay = Just (ReviewOverlay 39)
        pullRequestOverlay = Just (PullRequestReviewOverlay 39)
        atBottom = Just (TranscriptGeometry {transcriptTop = 80, transcriptHeight = 20, transcriptContentHeight = 100})
        scrolledUp = Just (TranscriptGeometry {transcriptTop = 50, transcriptHeight = 20, transcriptContentHeight = 100})

    it "maps each transcript overlay to its own session and every other overlay to none" $ do
      displayedTranscript solveOverlay `shouldBe` Just (SolveTranscript 39)
      displayedTranscript reviewOverlay `shouldBe` Just (ReviewTranscript 39)
      displayedTranscript pullRequestOverlay `shouldBe` Just (PullRequestTranscript 39)
      displayedTranscript (Just HelpOverlay) `shouldBe` Nothing
      displayedTranscript (Just ProcessesOverlay) `shouldBe` Nothing
      displayedTranscript Nothing `shouldBe` Nothing

    it "tails the displayed session's output while it is still following" $ do
      transcriptShouldTail solveOverlay (SolveTranscript 39) True `shouldBe` True
      transcriptShouldTail reviewOverlay (ReviewTranscript 39) True `shouldBe` True
      transcriptShouldTail pullRequestOverlay (PullRequestTranscript 39) True `shouldBe` True

    it "preserves the position of a displayed session the user has scrolled back into" $ do
      transcriptShouldTail solveOverlay (SolveTranscript 39) False `shouldBe` False
      transcriptShouldTail reviewOverlay (ReviewTranscript 39) False `shouldBe` False
      transcriptShouldTail pullRequestOverlay (PullRequestTranscript 39) False `shouldBe` False

    it "issues no viewport operation for a session that is not the one on screen" $ do
      -- The review overlay's tabs share a single viewport, so a background
      -- review session's output must not move the displayed tab; the same
      -- holds for a solve or PR session other than the open one.
      transcriptShouldTail reviewOverlay (ReviewTranscript 40) True `shouldBe` False
      transcriptShouldTail solveOverlay (SolveTranscript 40) True `shouldBe` False
      transcriptShouldTail pullRequestOverlay (PullRequestTranscript 40) True `shouldBe` False
      -- A different kind of overlay, or none at all, hides all three.
      transcriptShouldTail reviewOverlay (SolveTranscript 39) True `shouldBe` False
      transcriptShouldTail solveOverlay (ReviewTranscript 39) True `shouldBe` False
      transcriptShouldTail (Just HelpOverlay) (ReviewTranscript 39) True `shouldBe` False
      transcriptShouldTail Nothing (SolveTranscript 39) True `shouldBe` False
      transcriptShouldTail Nothing (PullRequestTranscript 39) True `shouldBe` False

    it "keeps following when the view is already at the bottom" $
      followAfterScroll True atBottom 0 `shouldBe` True

    it "disengages follow on any upward scroll away from the bottom" $ do
      followAfterScroll True atBottom (-1) `shouldBe` False
      followAfterScroll True atBottom (-3) `shouldBe` False

    it "re-engages follow only once a downward scroll actually reaches the bottom" $ do
      followAfterScroll False scrolledUp 3 `shouldBe` False
      followAfterScroll False scrolledUp 29 `shouldBe` False
      followAfterScroll False scrolledUp 30 `shouldBe` True
      -- Overshooting clamps to the bottom the way brick's own scroll does.
      followAfterScroll False scrolledUp 300 `shouldBe` True

    it "treats content shorter than the viewport as always at its bottom" $ do
      let short = Just (TranscriptGeometry {transcriptTop = 0, transcriptHeight = 20, transcriptContentHeight = 5})
      followAfterScroll False short (-3) `shouldBe` True
      followAfterScroll False short 3 `shouldBe` True

    it "leaves follow state alone when the viewport has never been rendered" $ do
      followAfterScroll True Nothing (-3) `shouldBe` True
      followAfterScroll False Nothing 3 `shouldBe` False

    it "recognizes the arrow bindings every transcript overlay shares" $
      mapM_
        ( \reviewChords -> do
            transcriptScrollKey reviewChords (Vty.EvKey Vty.KDown []) `shouldBe` Just 1
            transcriptScrollKey reviewChords (Vty.EvKey Vty.KUp []) `shouldBe` Just (-1)
        )
        [False, True]

    it "recognizes Ctrl-J/Ctrl-K only for the review transcript, which alone binds them" $ do
      transcriptScrollKey True (Vty.EvKey (Vty.KChar 'j') [Vty.MCtrl]) `shouldBe` Just 1
      transcriptScrollKey True (Vty.EvKey (Vty.KChar 'k') [Vty.MCtrl]) `shouldBe` Just (-1)
      transcriptScrollKey False (Vty.EvKey (Vty.KChar 'j') [Vty.MCtrl]) `shouldBe` Nothing
      transcriptScrollKey False (Vty.EvKey (Vty.KChar 'k') [Vty.MCtrl]) `shouldBe` Nothing

    it "leaves typing and the overlays' other bindings out of the scroll path" $
      mapM_
        (\event -> mapM_ (\reviewChords -> transcriptScrollKey reviewChords event `shouldBe` Nothing) [False, True])
        [ Vty.EvKey (Vty.KChar 'j') [],
          Vty.EvKey (Vty.KChar 'k') [],
          Vty.EvKey (Vty.KChar '\t') [],
          Vty.EvKey Vty.KEnter [],
          Vty.EvKey Vty.KBS [],
          Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl]
        ]

    it "runs the wheel through the same follow-state transitions as the arrows" $ do
      -- The wheel reaches all three transcripts through
      -- 'overlayMouseAction', whose amount is handed to the same
      -- 'followAfterScroll' the key bindings use.
      let wheelAmount panel button = case overlayMouseAction panel (VtyEvent (Vty.EvMouseDown 0 0 button [])) of
            Just (OverlayMouseScroll amount) -> Just amount
            _ -> Nothing
      mapM_
        ( \panel -> do
            wheelAmount panel Vty.BScrollUp `shouldBe` Just (-3)
            wheelAmount panel Vty.BScrollDown `shouldBe` Just 3
        )
        [ReviewPanel, SolvePanel, PullRequestReviewPanel]
      followAfterScroll True atBottom (-3) `shouldBe` False
      followAfterScroll False scrolledUp 30 `shouldBe` True

    it "puts terminal output under the same gate as streamed output" $ do
      -- Round-1 review: the completion paths grow a transcript too --
      -- 'SolveProcessFinished'/'PullRequestProcessFinished' append
      -- interruption guidance, the resumable question, or the failure;
      -- 'ReviewTurnCompleted' and 'applyCanonicalIssueReview' append the
      -- verdict; the orphan and disconnect projections append their
      -- markers. Those all now route through 'tailTranscript' rather than
      -- ending silently above the tail, so they answer this same gate:
      -- follow the tail when displayed and engaged, move nothing
      -- otherwise.
      transcriptShouldTail solveOverlay (SolveTranscript 39) True `shouldBe` True
      transcriptShouldTail pullRequestOverlay (PullRequestTranscript 39) True `shouldBe` True
      transcriptShouldTail reviewOverlay (ReviewTranscript 39) True `shouldBe` True
      transcriptShouldTail solveOverlay (SolveTranscript 39) False `shouldBe` False
      transcriptShouldTail Nothing (SolveTranscript 39) True `shouldBe` False
      transcriptShouldTail reviewOverlay (ReviewTranscript 40) True `shouldBe` False

    it "re-engages follow when a genuinely new review turn starts" $ do
      followAfterTurnStarted False (Just "turn-1") "turn-2" `shouldBe` True
      followAfterTurnStarted False Nothing "turn-1" `shouldBe` True

    it "does not treat a repeated notification for the running turn as a new turn" $ do
      -- The backend can send a matching 'ReviewTurnStarted' after a
      -- question is answered (see the same-turn coverage above), which
      -- must not discard a deliberate scrollback.
      followAfterTurnStarted False (Just "turn-1") "turn-1" `shouldBe` False
      followAfterTurnStarted True (Just "turn-1") "turn-1" `shouldBe` True
