-- | The review session's overlays: dispatch, liveness and quit protection,
-- animation, and the transcript the user follows.
module Spec.UI.ReviewSession (spec) where

import Brick (BrickEvent (..), Location (..))
import Data.Aeson (Value (..))
import qualified Data.Map.Strict as Map
import Data.Foldable (for_)
import qualified Data.Set as Set
import qualified Data.Text
import qualified Graphics.Vty as Vty
import Kanban.Domain
import Kanban.Models (ProviderName (..))
import Kanban.Review
  ( ConnectionId (..),
    ReviewApproval (..),
    ReviewOutputKind (..),
    ReviewThreadId (..),
    ReviewChoice (..),
    ReviewQuestion (..),
    ReviewQuestionKind (..),
    ReviewRequestId (..),
    ReviewStage (..)
  )
import Kanban.UI.Board (reviewPhaseGlyphFor)
import qualified Data.Text as Text
import Kanban.Worker (ReviewCommandPayload (..), reviewCommandDisplay)
import Kanban.UI.Events (OverlayExtent (..), OverlayMouseAction (..), QuitRequest (..), dashboardQuitRequest, overlayMouseAction)
import Kanban.UI.Overlay (reviewPhaseLabel)
import Kanban.UI.Reconcile (reconcileReviewSessions)
import Kanban.UI.Review
  ( appliedIssueActionTermination,
    appliedReviewInput,
    applyUndeliveredSteer,
    carryUndelivered,
    newReviewSession,
    undeliveredForIssue,
    forcedToNormalBy,
    markReviewSessionDisconnected,
    reviewSubmission,
    numberedChoicePrompt,
    reviewDigitActionFor, ReviewCancelAction (..),
    ReviewDigitAction (..),
    canonicalReviewCompletionSuperseded,
    epicReviewRefusalNotice,
    resolveReviewCancelAction,
    resolveReviewDigitAction,
    reviewOutputPrefix,
    reviewProtocolWarningNotice,
    reviewSessionsNeedingArm,
  )
import Kanban.UI.Session
  ( EpicReviewRefusal (..),
    ReviewTarget (..),
    itemReviewRefusal,
    resolveProcessClick,
    resolveProcessSelection,
    reviewAgentSessionEntry,
    reviewSessionLive,
    reviewSessionReusable,
    reviewTurnInterruptible,
    selectedReviewIssue,
    selectedReviewItem,
    selectedReviewTarget,
  )
import Kanban.UI.SessionCore
  ( SessionFocus (..),
    SessionInputEvent (..),
    SessionTickArm (..),
    SessionTickFire (..),
    decideSessionTickArm,
    decideSessionTickFire,
    newAgentSession,
    sessionInputEvent,
    transcriptScrollKey,
  )
import Kanban.UI.SessionEvents (SessionOps (..), reviewSessionOps, reviewTickEligible)
import Kanban.UI.Theme (reviewPhaseAttribute, revisedAttr)
import Kanban.UI.Transcript
  ( TranscriptEnd (..),
    TranscriptGeometry (..),
    TranscriptSession (..),
    displayedTranscript,
    followAfterJump,
    followAfterScroll,
    followAfterTurnStarted,
    transcriptShouldTail,
  )
import Kanban.UI.Types
  ( AgentSession (..),
    AgentSessionEntry (..),
    AgentSessionRef (..),
    AppState (..),
    ChatTranscript (..),
    Name (..),
    Overlay (..),
    PendingReviewInteraction (..),
    ProcessClickOutcome (..),
    ProcessSelection (..),
    ReviewDetail (..),
    ReviewPhase (..),
    ReviewSession,
    SessionMode (..),
    withSessionDetail,
  )
import Kanban.Worker (WorkerId (..))
import Spec.Support.App (testAppState, testReviewSession)
import Kanban.UI.Session (reviewSessionMode)
import Spec.Support.Expect (shouldMention)
import Spec.Support.Fixtures
  ( baseIssue,
    basePullRequest,
    fixtureBoard,
    fixtureReviewThread,
    fixtureStandaloneEntry,
    fixtureTracker,
    fixtureTrackedEntry,
  )
import Test.Hspec

spec :: Spec
spec = do
  describe "review overlay digit dispatch" $ do
    let requestId = ReviewRequestId (ConnectionId 0) (String "req-1")
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

    -- Every case below is asked in both modes. The mode is not a filter over
    -- the answers: a digit only ever picks a pending numbered choice, and in
    -- normal mode -- the only mode the decoder routes a digit here from --
    -- everything that used to fall through to typing is nothing at all
    -- (issue #515 requirement 9).
    it "appends free-text digits instead of treating them as choice selections" $ do
      -- A QuestionText pending interaction must take precedence over any
      -- choices/allowOther it happens to carry (issue #3 spec addition).
      resolveReviewDigitAction SessionInsert (Just (PendingReviewQuestion requestId (textQuestion False))) 2 `shouldBe` ReviewDigitAppend
      resolveReviewDigitAction SessionInsert (Just (PendingReviewQuestion requestId (textQuestion True))) 8 `shouldBe` ReviewDigitAppend

    it "types nothing for a normal-mode digit no numbered choice claims" $ do
      -- The whole set that used to append: a free-text question, an
      -- out-of-range digit a question would take as text, and no pending
      -- interaction at all.
      resolveReviewDigitAction SessionNormal (Just (PendingReviewQuestion requestId (textQuestion False))) 2 `shouldBe` ReviewDigitIgnored
      resolveReviewDigitAction SessionNormal (Just (PendingReviewQuestion requestId (choiceQuestion True))) 5 `shouldBe` ReviewDigitIgnored
      resolveReviewDigitAction SessionNormal Nothing 4 `shouldBe` ReviewDigitIgnored

    it "selects an in-range choice by its 1-based digit" $ do
      resolveReviewDigitAction SessionNormal (Just (PendingReviewQuestion requestId (choiceQuestion False))) 0
        `shouldBe` ReviewDigitSelectChoice requestId (ReviewChoice "keep" "Keep compatibility" "Preserve callers")
      resolveReviewDigitAction SessionNormal (Just (PendingReviewQuestion requestId (choiceQuestion False))) 1
        `shouldBe` ReviewDigitSelectChoice requestId (ReviewChoice "break" "Break compatibility" "")

    it "appends an out-of-range choice digit when free text is also accepted" $
      resolveReviewDigitAction SessionInsert (Just (PendingReviewQuestion requestId (choiceQuestion True))) 5 `shouldBe` ReviewDigitAppend

    it "reports an out-of-range choice digit unavailable when free text is not accepted" $
      -- A choice /is/ pending, so this stays a notice in either mode rather
      -- than becoming the silent normal-mode no-op above.
      mapM_
        ( \mode ->
            resolveReviewDigitAction mode (Just (PendingReviewQuestion requestId (choiceQuestion False))) 5
              `shouldBe` ReviewDigitUnavailable "That review choice is not available"
        )
        [SessionNormal, SessionInsert]

    it "keeps approval digit handling exactly as before" $ do
      resolveReviewDigitAction SessionNormal (Just (PendingReviewApproval requestId approval)) 0 `shouldBe` ReviewDigitApprovalOnce requestId
      resolveReviewDigitAction SessionNormal (Just (PendingReviewApproval requestId approval)) 1 `shouldBe` ReviewDigitApprovalSession requestId
      resolveReviewDigitAction SessionNormal (Just (PendingReviewApproval requestId approval)) 2 `shouldBe` ReviewDigitApprovalDecline requestId
      resolveReviewDigitAction SessionNormal (Just (PendingReviewApproval requestId approval)) 5
        `shouldBe` ReviewDigitUnavailable "That approval choice is not available"

    it "appends digits when nothing is pending" $
      resolveReviewDigitAction SessionInsert Nothing 4 `shouldBe` ReviewDigitAppend

  describe "the mode the digit path reads" $ do
    -- PR #523 round 1: 'chooseReviewOption' read the stored 'sessionMode'
    -- while the decoder read the derived one, so the two could answer the
    -- same press differently. 'ReviewClientStopped' settles a session to
    -- 'ReviewFailed' without clearing a pending interaction, and a free-text
    -- question leaves the session in insert -- so a digit pressed on the
    -- result decoded as a normal-mode choice and was then typed into a draft
    -- that can never be sent.
    let settledMidQuestion =
          withSessionDetail
            ( \detail ->
                detail
                  { reviewSessionStage = IssueRevision,
                    reviewSessionPending =
                      Just
                        ( PendingReviewQuestion
                            (ReviewRequestId (ConnectionId 0) "req-1")
                            ReviewQuestion
                              { reviewQuestionId = "scope",
                                reviewQuestionHeader = "SCOPE",
                                reviewQuestionText = "Which contract?",
                                reviewQuestionKind = QuestionText,
                                reviewQuestionChoices = [],
                                reviewQuestionAllowOther = True,
                                reviewQuestionMultiple = False
                              }
                        )
                  }
            )
            (testReviewSession (baseIssue 7 []) ReviewFailed) {sessionMode = SessionInsert}

    it "derives it from the session's liveness, not from the stored field" $ do
      settledMidQuestion.sessionMode `shouldBe` SessionInsert
      reviewSessionMode settledMidQuestion `shouldBe` SessionNormal

    it "types nothing when a settled session's stale insert mode meets a digit" $ do
      -- Asked of the whole call-site decision, not of the resolver alone: the
      -- bug was that this step read the stored field, so a test that passed
      -- the derived mode in by hand could not see it. Reading
      -- `settledMidQuestion.sessionMode` here instead returns
      -- ReviewDigitAppend, and only this input distinguishes the two.
      reviewDigitActionFor (Just settledMidQuestion) 0 `shouldBe` ReviewDigitIgnored
      -- And the decoder agrees the press is a normal-mode choice, which is
      -- the disagreement itself.
      sessionInputEvent
        (SessionFocus reviewSessionOps.sessionOpsCaps settledMidQuestion.sessionMode False)
        (Vty.EvKey (Vty.KChar '1') [])
        `shouldBe` Just (SessionInputChoice 0)

    it "still answers a live session's own insert mode as insert" $ do
      -- The derivation must not simply pin every session to normal: a
      -- revision still reading text keeps whichever mode it is in.
      let live = settledMidQuestion {sessionPhase = ReviewRunning}
      reviewSessionMode live `shouldBe` SessionInsert
      reviewDigitActionFor (Just live) 0 `shouldBe` ReviewDigitAppend

    it "reads a session the map no longer holds as normal" $
      reviewDigitActionFor Nothing 0 `shouldBe` ReviewDigitIgnored

  describe "a prompt whose answer is a digit" $ do
    -- issue #515 requirement 10: the agent presenting a numbered choice puts
    -- its own session back into normal mode so the digits answer it, rather
    -- than being typed into a draft the user is mid-way through.
    let choices =
          [ ReviewChoice "keep" "Keep compatibility" "Preserve callers",
            ReviewChoice "break" "Break compatibility" ""
          ]
        question kind offered allowOther =
          ReviewQuestion
            { reviewQuestionId = "scope",
              reviewQuestionHeader = "SCOPE",
              reviewQuestionText = "Which contract?",
              reviewQuestionKind = kind,
              reviewQuestionChoices = offered,
              reviewQuestionAllowOther = allowOther,
              reviewQuestionMultiple = False
            }

    it "recognizes a question by whether it offers numbered choices at all" $ do
      numberedChoicePrompt (question QuestionChoice choices False) `shouldBe` True
      numberedChoicePrompt (question QuestionChoice choices True) `shouldBe` True
      -- A free-text-only request has no digits to answer with, so requirement
      -- 10 does not reach it and an already-typing user keeps typing.
      numberedChoicePrompt (question QuestionText [] True) `shouldBe` False
      numberedChoicePrompt (question QuestionChoice [] False) `shouldBe` False

    it "forces the session to normal for a prompt that offers them" $ do
      let drafting = (testReviewSession (baseIssue 7 []) ReviewRunning) {sessionMode = SessionInsert}
      (forcedToNormalBy True drafting).sessionMode `shouldBe` SessionNormal
      (forcedToNormalBy True drafting {sessionMode = SessionNormal}).sessionMode `shouldBe` SessionNormal

    it "leaves the mode alone for a prompt that does not" $ do
      let drafting = (testReviewSession (baseIssue 7 []) ReviewRunning) {sessionMode = SessionInsert}
      (forcedToNormalBy False drafting).sessionMode `shouldBe` SessionInsert

    it "erases neither the draft nor the undelivered queue it forces past" $ do
      -- The user still has to send both, so the only thing the prompt may
      -- take is the mode.
      let waiting =
            withSessionDetail
              (\detail -> detail {reviewSessionUndelivered = ["an earlier rejected steer"]})
              (testReviewSession (baseIssue 7 []) ReviewRunning)
                { sessionMode = SessionInsert,
                  sessionInput = "half typed"
                }
          forced = forcedToNormalBy True waiting
      forced.sessionInput `shouldBe` ("half typed" :: Data.Text.Text)
      forced.sessionDetail.reviewSessionUndelivered `shouldBe` (["an earlier rejected steer"] :: [Data.Text.Text])
      forced.sessionTranscript `shouldBe` waiting.sessionTranscript
      forced.sessionPhase `shouldBe` waiting.sessionPhase

  describe "review overlay Ctrl-C cancel dispatch" $ do
    -- issue #31: canonical review stages (InitialReview/IssueRereview) have
    -- no app-server thread/turn, so the pre-existing app-server-only
    -- dispatch reported "no active turn to cancel" even while their
    -- ManagedProcess was still running. 'resolveReviewCancelAction' is the
    -- pure routing extracted from 'cancelReviewSession' so each branch is
    -- unconditionally covered without an 'EventM' harness.
    it "routes a ready app-server turn to the interrupt-turn action, unchanged" $ do
      resolveReviewCancelAction True (Just (fixtureReviewThread "thread-1")) (Just "turn-1") IssueRevision ReviewRunning False
        `shouldBe` ReviewCancelInterruptTurn (fixtureReviewThread "thread-1") "turn-1"
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

  -- MODEL-14 requirement 5: a connection that ends is reported against the
  -- review threads it served and never against threads served by another.
  -- With one shared connection that is every session, which is what a Codex
  -- backend still produces; with one of several per-thread connections it is
  -- only the sessions on that connection, and the rest keep running.
  describe "the sessions an ended provider connection terminalizes" $ do
    let sessionOn threadId phase =
          newAgentSession
            0
            phase
            ""
            Nothing
            (ChatTranscript "" "" "")
            ReviewDetail
              { reviewSessionIssue = baseIssue 151 [],
                reviewSessionStage = IssueRevision,
                reviewSessionThreadId = threadId,
                reviewSessionTurnId = Nothing,
                reviewSessionPending = Nothing,
                reviewSessionUndelivered = [],
                reviewSessionRestored = Nothing
              }
        onFirst = Just (ReviewThreadId (ConnectionId 0) "thread-1")
        onSecond = Just (ReviewThreadId (ConnectionId 1) "thread-1")
        sessions =
          Map.fromList
            [ (1, sessionOn onFirst ReviewRunning),
              (2, sessionOn onSecond ReviewRunning),
              (3, sessionOn Nothing ReviewStarting),
              (4, sessionOn onFirst ReviewFinished)
            ]
        disconnectedPhase :: Int -> Maybe ReviewPhase
        disconnectedPhase key = (.sessionPhase) . markReviewSessionDisconnected "backend gone" <$> Map.lookup key sessions
        interruptedSession = sessionOn onFirst ReviewInterrupted

    -- An interrupted revision keeps its input line because it is resumable,
    -- which is true only while there is something to resume it on. Its
    -- connection ending is what makes it as finished as a failed one, and
    -- leaving it resumable leaves that line offering a send into a dead
    -- process.
    it "terminalizes an interrupted revision whose connection has gone" $
      (markReviewSessionDisconnected "backend gone" interruptedSession).sessionPhase
        `shouldBe` ReviewFailed

    -- Which sessions an ended connection reaches is the host's decision now,
    -- not this function's: it journals a client-stopped or connection-stopped
    -- event only into the children that connection was serving (SAG-10), so
    -- what arrives here is already known to belong to this session. What is
    -- left to decide is the phase, and the one session it must /not/ move is
    -- one that already settled.
    it "terminalizes a live session the ended connection was serving" $
      map disconnectedPhase [1, 2, 3]
        `shouldBe` [Just ReviewFailed, Just ReviewFailed, Just ReviewFailed]

    it "leaves an already-settled session alone" $
      disconnectedPhase 4 `shouldBe` Just ReviewFinished

    it "names the ended connection in the transcript of the session it claimed" $ do
      let disconnected = markReviewSessionDisconnected "backend gone" (sessionOn onSecond ReviewRunning)
      disconnected.sessionTranscript.compactTranscript `shouldMention` "backend gone"

  -- The one review event whose display names a program rather than a
  -- session. Every other diagnostic reaches the operator inside a session
  -- that already says which backend it belongs to; a protocol warning is a
  -- bare notice, so the brand has to be in the sentence.
  describe "the provider a protocol warning is announced under" $ do
    it "keeps Codex's wording exactly as it was" $
      reviewProtocolWarningNotice CodexProvider "turn/started omitted its thread or turn id"
        `shouldBe` "Codex protocol warning: turn/started omitted its thread or turn id"

    it "names Claude for a warning Claude's backend raised" $
      reviewProtocolWarningNotice ClaudeProvider "Claude stream-json session wrote a line that is not JSON"
        `shouldBe` "Claude protocol warning: Claude stream-json session wrote a line that is not JSON"

    -- The seam's teeth: one message, two providers, two notices. A renderer
    -- that had kept a compiled-in brand would produce the same sentence
    -- twice and pass every assertion above that named only one of them.
    it "distinguishes the two for one and the same message" $
      map (`reviewProtocolWarningNotice` "unreadable") [CodexProvider, ClaudeProvider]
        `shouldBe` ["Codex protocol warning: unreadable", "Claude protocol warning: unreadable"]

  -- The other place a review's display names a program. Diagnostic output is
  -- the one output kind that is a line some process wrote rather than a part
  -- of the conversation, so it is tagged with which process wrote it — and a
  -- tag compiled in here would put the app-server's name on a CLI session's
  -- stderr.
  describe "the provider a diagnostic line is tagged with" $ do
    it "keeps Codex's tag exactly as it was, and tags nothing else" $
      map reviewOutputPrefix [AgentOutput, ReasoningOutput, CommandOutput, DiagnosticOutput CodexProvider]
        `shouldBe` ["", "", "", "[codex] "]

    it "tags a Claude session's stderr as Claude's" $
      reviewOutputPrefix (DiagnosticOutput ClaudeProvider) `shouldBe` "[claude] "

  describe "review session liveness and the x gate" $ do
    -- issue #151 made the processes overlay, the @x@ gate that dispatches on
    -- its rows, and the dashboard quit guard consume one decision, because
    -- three implementations of "live" disagreed. SAG-10 keeps that single
    -- decision and simplifies what it is made of: the durable child action a
    -- review runs as either exists or it does not, and ending it is a command
    -- its host applies, so there is no window in which a row reads live while
    -- the kill would refuse.
    --
    -- The quit guard is no longer one of the three. A live issue action
    -- outlives the dashboard now (requirement 3), so it is asserted here
    -- against the quit decision itself rather than against this predicate.
    let reviewedIssue = 151
        sessionFor (stage, phase, threadId, turnId) =
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
                reviewSessionUndelivered = [],
                reviewSessionRestored = Nothing
              }
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
        sessionInputs =
          [ (stage, phase, threadId, turnId)
            | stage <- allStages,
              phase <- allPhases,
              threadId <- [Nothing, Just (fixtureReviewThread "thread-1")],
              turnId <- [Nothing, Just "turn-1"]
          ]

    -- The whole point of the simplification: the answer depends on the child
    -- and on nothing the session happens to be showing. A row that reported
    -- live off a phase would go on offering @x@ after the action ended, and
    -- one that reported dead off a phase would refuse @x@ for an action still
    -- running — both of which #151 was filed for.
    it "reports a review session live exactly when its durable action is" $
      sequence_
        [ (actionLive, stage, phase, reviewSessionLive actionLive) `shouldBe` (actionLive, stage, phase, actionLive)
          | actionLive <- [False, True],
            (stage, phase, _, _) <- sessionInputs
        ]

    it "covers every combination of phase, stage, and both identifiers" $ do
      length sessionInputs `shouldBe` 96
      length (filter (\(stage, _, _, _) -> stage == IssueRevision) sessionInputs) `shouldBe` 32

    it "keeps the processes overlay agreeing with that decision" $
      sequence_
        [ (actionLive, (reviewAgentSessionEntry actionLive reviewedIssue (sessionFor inputs)).agentSessionLive)
            `shouldBe` (actionLive, actionLive)
          | actionLive <- [False, True],
            inputs <- sessionInputs
        ]

    -- Which of the two things @x@ then does. Only an interactive revision
    -- with a running turn gets a turn interrupt; every canonical stage ends
    -- the whole child, which is the escalation requirement 13 preserves
    -- along with its wording.
    it "routes x to a turn interrupt only for a revision that has one" $
      sequence_
        [ (stage, phase, reviewTurnInterruptible stage phase)
            `shouldBe` (stage, phase, stage == IssueRevision && phase `elem` [ReviewStarting, ReviewRunning, ReviewWaiting])
          | stage <- allStages,
            phase <- allPhases
        ]

  -- Round 8's first blocker. A command must name the thread and turn the
  -- overlay is showing, not the newest the child has recorded: the two differ
  -- for as long as a journal event takes to reach Brick, and a durable read
  -- in that window addresses a turn the user never saw. Naming what was on
  -- screen turns the race into a refusal they are told about.
  describe "which turn a submitted command names" $ do
    let showing turnId =
          newAgentSession
            0
            ReviewWaiting
            ""
            Nothing
            (ChatTranscript "" "" "")
            ReviewDetail
              { reviewSessionIssue = baseIssue 151 [],
                reviewSessionStage = IssueRevision,
                reviewSessionThreadId = Just (fixtureReviewThread "thread-1"),
                reviewSessionTurnId = turnId,
                reviewSessionPending = Nothing,
                reviewSessionUndelivered = [],
                reviewSessionRestored = Nothing
              }

    it "takes the thread and turn from the session on screen" $ do
      let displayed = showing (Just "turn-1")
      ( displayed.sessionDetail.reviewSessionThreadId,
        displayed.sessionDetail.reviewSessionTurnId
        )
        `shouldBe` (Just (fixtureReviewThread "thread-1"), Just "turn-1")

    -- A session that has not been told a turn yet names none, which the host
    -- accepts only while the child holds none either. The refusal half of
    -- that rule is exercised against a real host in
    -- "Spec.Agent.IssueHost" — "rejects feedback written for a turn that has
    -- since been replaced" — because it is the host that decides it.
    it "names no turn when the overlay has not been told one" $
      (showing Nothing).sessionDetail.reviewSessionTurnId `shouldBe` Nothing

  -- Which durable command a submission becomes (requirement 9). The two are
  -- not interchangeable: one is new guidance, the other is the recovery of a
  -- specific message the provider refused, and a review's evidence should say
  -- which happened.
  describe "what the input line submits" $ do
    let revising phase =
          newAgentSession
            0
            phase
            ""
            Nothing
            (ChatTranscript "" "" "")
            ReviewDetail
              { reviewSessionIssue = baseIssue 151 [],
                reviewSessionStage = IssueRevision,
                reviewSessionThreadId = Just (fixtureReviewThread "thread-1"),
                reviewSessionTurnId = Just "turn-1",
                reviewSessionPending = Nothing,
                reviewSessionUndelivered = [],
                reviewSessionRestored = Nothing
              }

    it "sends text the user typed as feedback" $
      reviewSubmission (revising ReviewRunning) {sessionInput = "look again"}
        `shouldBe` SendReviewFeedback "look again"

    -- The message a refused steer hands back lands on the line, and pressing
    -- Enter on it is the deliberate resend the queue exists for. The queue
    -- itself cannot answer this: it drains onto the line the moment the line
    -- is free, so by Enter the message is no longer in it.
    it "sends a handed-back message as a deliberate resend" $ do
      let handed = applyUndeliveredSteer "look again" (revising ReviewRunning)
      handed.sessionInput `shouldBe` "look again"
      handed.sessionDetail.reviewSessionUndelivered `shouldBe` []
      reviewSubmission handed `shouldBe` ResendReviewSteer "look again"

    -- Offered back /editable/ is the point, so editing it makes it new text.
    it "treats an edited handed-back message as new feedback" $ do
      let edited = (applyUndeliveredSteer "look again" (revising ReviewRunning)) {sessionInput = "look again, but at the lease"}
      reviewSubmission edited `shouldBe` SendReviewFeedback "look again, but at the lease"

    -- A message that could not reach the line stays queued, and nothing on
    -- the line claims to be it.
    it "leaves a message queued when the line is already holding a draft" $ do
      let queued = applyUndeliveredSteer "look again" (revising ReviewRunning) {sessionInput = "my own draft"}
      queued.sessionInput `shouldBe` "my own draft"
      queued.sessionDetail.reviewSessionUndelivered `shouldBe` ["look again"]
      reviewSubmission queued `shouldBe` SendReviewFeedback "my own draft"

    -- And the message carried into a fresh session by the press that
    -- replaces a dead one is a resend there too: it is the same refused
    -- message, on the first line that can actually send it.
    it "carries a handed-back message into a fresh session as a resend" $ do
      let stranded = applyUndeliveredSteer "look again" (revising ReviewFailed)
          (restarted, held) =
            carryUndelivered (undeliveredForIssue (Just stranded) []) (newReviewSession (baseIssue 151 []) IssueRevision 0)
      held `shouldBe` []
      restarted.sessionInput `shouldBe` "look again"
      reviewSubmission restarted `shouldBe` ResendReviewSteer "look again"

  -- The other half of the terminal-envelope ordering (round 7). A command
  -- that ends an action journals its line before the child's terminal event
  -- so a replay meets them in that order — and this holds whatever order a
  -- replay actually meets them in: a delivered line is always recorded, and
  -- never moves a session that has already settled back to running.
  describe "a delivered input arriving after a session settled" $ do
    let settledAs phase =
          newAgentSession
            0
            phase
            "approved"
            Nothing
            (ChatTranscript "" "" "")
            ReviewDetail
              { reviewSessionIssue = baseIssue 151 [],
                reviewSessionStage = IssueRevision,
                reviewSessionThreadId = Just (fixtureReviewThread "thread-1"),
                reviewSessionTurnId = Nothing,
                reviewSessionPending = Nothing,
                reviewSessionUndelivered = [],
                reviewSessionRestored = Nothing
              }

    it "records the line without reviving the session" $
      sequence_
        [ (phase, applied.sessionPhase, applied.sessionTranscript.standardTranscript)
            `shouldBe` (phase, phase, "\nYou: carry on\n")
          | phase <- [ReviewFinished, ReviewNeedsChanges, ReviewFailed, ReviewRevised],
            let applied = appliedReviewInput "carry on" Nothing (settledAs phase)
        ]

    -- A running session still takes the line and the phase, which is what
    -- makes the rule above a rule rather than the function doing nothing.
    it "still moves a running session to thinking" $ do
      let applied = appliedReviewInput "carry on" Nothing (settledAs ReviewWaiting)
      applied.sessionPhase `shouldBe` ReviewRunning
      applied.sessionActivity `shouldBe` "thinking"
      applied.sessionTranscript.standardTranscript `shouldMention` "carry on"

  -- Round 13's blocker. Both gestures that end an action used to mark the
  -- transcript and move the phase at the press, before the command was even
  -- written. A reattached overlay cannot reconstruct that mark — it is no
  -- journal event — so one action read one way live and another on replay,
  -- and a ledger write that failed still announced a kill.
  describe "ending an action from the overlay" $ do
    let running =
          newAgentSession
            0
            ReviewRunning
            "thinking"
            Nothing
            (ChatTranscript "" "" "")
            ReviewDetail
              { reviewSessionIssue = baseIssue 151 [],
                reviewSessionStage = InitialReview,
                reviewSessionThreadId = Nothing,
                reviewSessionTurnId = Nothing,
                reviewSessionPending = Nothing,
                reviewSessionUndelivered = [],
                reviewSessionRestored = Nothing
              }

    -- The property both gestures rest on. Anything moved here is moved for a
    -- live overlay and for nobody else.
    it "moves nothing at the press, for a kill or a canonical interrupt alike" $
      appliedIssueActionTermination running `shouldBe` running

    -- And what the two journaled records do, which is the whole of what
    -- either gesture produces. The line reads as the thing the user did, and
    -- no bracketed marker appears in it, because no such marker is written
    -- anywhere any more.
    it "renders a termination from its journal alone" $ do
      let afterInput = appliedReviewInput (reviewCommandDisplay TerminateIssueAction) Nothing running
      afterInput.sessionTranscript.standardTranscript `shouldBe` "\nYou: end this action\n"
      Text.unpack afterInput.sessionTranscript.standardTranscript `shouldNotContain` "[killed by user]"
      Text.unpack afterInput.sessionTranscript.standardTranscript `shouldNotContain` "[interrupted by user]"

  -- Requirement 3. The quoted refusal is gone, and with it the only reason
  -- the dashboard ever declined to quit for an agent.
  describe "quitting with a live issue action" $ do
    it "halts immediately even while an issue action is running" $ do
      state <- testAppState (fixtureBoard [])
      let running =
            state
              { appReviewSessions =
                  Map.singleton
                    151
                    ( newAgentSession
                        0
                        ReviewRunning
                        "thinking"
                        Nothing
                        (ChatTranscript "" "" "")
                        ReviewDetail
                          { reviewSessionIssue = baseIssue 151 [],
                            reviewSessionStage = IssueRevision,
                            reviewSessionThreadId = Just (fixtureReviewThread "thread-1"),
                            reviewSessionTurnId = Just "turn-1",
                            reviewSessionPending = Nothing,
                            reviewSessionUndelivered = [],
                            reviewSessionRestored = Nothing
                          }
                    )
              }
      dashboardQuitRequest running False `shouldBe` QuitImmediate

    -- The two answers that remain, so this is not passing merely because the
    -- function always says halt.
    it "still settles GitHub work first, and still reports an in-flight settle" $ do
      state <- testAppState (fixtureBoard [])
      dashboardQuitRequest state True `shouldBe` QuitMustSettle
      dashboardQuitRequest state {appQuitPending = True} False `shouldBe` QuitAlreadySettling

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
        (\phase -> reviewSessionReusable phase InitialReview InitialReview False False `shouldBe` True)
        [ReviewStarting, ReviewRunning, ReviewWaiting]
      reviewSessionReusable ReviewRunning InitialReview IssueRereview False False `shouldBe` True

    it "reuses a finished session whose recorded stage still matches what labels request" $
      reviewSessionReusable ReviewFinished InitialReview InitialReview False False `shouldBe` True

    it "does not reuse a finished session once labels request a different stage" $
      reviewSessionReusable ReviewNeedsChanges InitialReview IssueRereview False False `shouldBe` False

    it "forces a fresh launch for an interrupted canonical stage once its process is gone" $
      reviewSessionReusable ReviewInterrupted InitialReview InitialReview False False `shouldBe` False

    it "keeps reusing an interrupted session while its kill is still in flight" $
      reviewSessionReusable ReviewInterrupted InitialReview InitialReview True False `shouldBe` True

    it "reuses an interrupted app-server revision when its stage is unchanged" $
      reviewSessionReusable ReviewInterrupted IssueRevision IssueRevision False False `shouldBe` True

    -- The opposite of the interrupted revision above. An interrupted one is
    -- paused and keeps its input line; a failed one has lost the thread it
    -- would send on, so 'reviewSessionInputLive' takes no text for it and
    -- reopening it is a dead end no further press can leave. 'r' has to be
    -- able to start another, which is also what gives a message the backend
    -- never read somewhere to go.
    it "forces a fresh launch for a failed revision, which cannot be resumed" $
      reviewSessionReusable ReviewFailed IssueRevision IssueRevision False False `shouldBe` False

    -- Scoped to the revision, because a settled canonical stage is not a
    -- dead end in the same way: it holds a verdict worth reopening to read,
    -- and its retry is the label change that moves the stage.
    it "still reopens a failed canonical stage whose stage labels still request it" $
      reviewSessionReusable ReviewFailed InitialReview InitialReview False False `shouldBe` True

    -- A turn that reached its verdict while an interrupt was still
    -- unconfirmed hands the message back into a session that has by then
    -- stopped accepting one (D-16). Those phases are otherwise the most
    -- reusable there are -- they hold the verdict -- so the held message is
    -- what decides: reopening such a session is the one press that would
    -- strand it for good.
    it "forces a fresh launch for a settled revision still holding a message it cannot send" $
      mapM_
        (\phase -> reviewSessionReusable phase IssueRevision IssueRevision False True `shouldBe` False)
        [ReviewFinished, ReviewNeedsChanges, ReviewRevised, ReviewFailed]

    it "reopens those same settled revisions when they hold nothing undelivered" $
      mapM_
        (\phase -> reviewSessionReusable phase IssueRevision IssueRevision False False `shouldBe` True)
        [ReviewFinished, ReviewNeedsChanges, ReviewRevised]

    -- An interrupted revision is resumable and its line still takes text, so
    -- a message waiting on it is not stranded and the session is kept.
    it "keeps an interrupted revision even while it holds an undelivered message" $
      reviewSessionReusable ReviewInterrupted IssueRevision IssueRevision False True `shouldBe` True

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
                  reviewSessionUndelivered = [],
                  reviewSessionRestored = Nothing
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
                reviewSessionUndelivered = [],
                reviewSessionRestored = Nothing
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
        -- Everything but the outside click is extent-independent, and saying
        -- so is what proves fullscreen changed only the one gesture.
        bothExtents :: [(String, OverlayExtent)]
        bothExtents = [("windowed", WindowedOverlay), ("fullscreen", FullscreenOverlay)]
        overlays =
          [ ("review overlay", ReviewPanel, ReviewViewport),
            ("solve overlay", SolvePanel, SolveViewport),
            ("pull request review overlay", PullRequestReviewPanel, PullRequestReviewViewport),
            ("details overlay", DetailsPanel, DetailsViewport)
          ]

    mapM_
      ( \(label, panel, viewport) -> describe label $ do
          it "scrolls, without closing, when the wheel lands on a background clickable" $
            for_ bothExtents $ \(extentLabel, extent) -> do
              (extentLabel, overlayMouseAction extent panel (MouseDown backgroundCard Vty.BScrollUp [] zeroLoc)) `shouldBe` (extentLabel, Just (OverlayMouseScroll (-3)))
              (extentLabel, overlayMouseAction extent panel (MouseDown backgroundCard Vty.BScrollDown [] zeroLoc)) `shouldBe` (extentLabel, Just (OverlayMouseScroll 3))

          it "scrolls on a raw Vty wheel event that carries no Brick name at all" $
            for_ bothExtents $ \(extentLabel, extent) -> do
              (extentLabel, overlayMouseAction extent panel (rawWheel Vty.BScrollUp)) `shouldBe` (extentLabel, Just (OverlayMouseScroll (-3)))
              (extentLabel, overlayMouseAction extent panel (rawWheel Vty.BScrollDown)) `shouldBe` (extentLabel, Just (OverlayMouseScroll 3))

          it "scrolls when the wheel lands on the overlay's own viewport or panel" $
            for_ bothExtents $ \(extentLabel, extent) -> do
              (extentLabel, overlayMouseAction extent panel (MouseDown viewport Vty.BScrollUp [] zeroLoc)) `shouldBe` (extentLabel, Just (OverlayMouseScroll (-3)))
              (extentLabel, overlayMouseAction extent panel (MouseDown viewport Vty.BScrollDown [] zeroLoc)) `shouldBe` (extentLabel, Just (OverlayMouseScroll 3))
              (extentLabel, overlayMouseAction extent panel (MouseDown panel Vty.BScrollUp [] zeroLoc)) `shouldBe` (extentLabel, Just (OverlayMouseScroll (-3)))
              (extentLabel, overlayMouseAction extent panel (MouseDown panel Vty.BScrollDown [] zeroLoc)) `shouldBe` (extentLabel, Just (OverlayMouseScroll 3))

          it "closes on an outside click, left or right, named or raw" $ do
            overlayMouseAction WindowedOverlay panel (MouseDown backgroundCard Vty.BLeft [] zeroLoc) `shouldBe` Just OverlayMouseClose
            overlayMouseAction WindowedOverlay panel (MouseDown backgroundCard Vty.BRight [] zeroLoc) `shouldBe` Just OverlayMouseClose
            overlayMouseAction WindowedOverlay panel (rawWheel Vty.BLeft) `shouldBe` Just OverlayMouseClose
            -- The press over the panel's own content, which brick reports
            -- against the viewport inside it rather than against the panel,
            -- and which the windowed gesture has always closed on.
            overlayMouseAction WindowedOverlay panel (MouseDown viewport Vty.BLeft [] zeroLoc) `shouldBe` Just OverlayMouseClose

          -- Issue #543 requirement 9: what a windowed box treats as "outside"
          -- is the board, and what a fullscreen one leaves showing there is
          -- the application's own frame and its footer. A plain click on
          -- those does nothing rather than throwing the panel away.
          it "leaves a plain outside click inert while the overlay is fullscreen" $ do
            overlayMouseAction FullscreenOverlay panel (MouseDown backgroundCard Vty.BLeft [] zeroLoc) `shouldBe` Just OverlayMouseNoOp
            overlayMouseAction FullscreenOverlay panel (MouseDown backgroundCard Vty.BMiddle [] zeroLoc) `shouldBe` Just OverlayMouseNoOp
            overlayMouseAction FullscreenOverlay panel (VtyEvent (Vty.EvMouseDown 0 0 Vty.BLeft [])) `shouldBe` Just OverlayMouseNoOp

          -- The right click is the exception requirement 9 names among a
          -- fullscreen overlay's own exits, so it keeps today's meaning at
          -- both extents. It is decided by button rather than by name because
          -- a press over the panel's content is reported against the
          -- scrolling viewport inside it, not against the panel: naming the
          -- panel here would leave the gesture working only on the border.
          it "closes on a right click wherever it lands, at either extent" $
            for_ bothExtents $ \(extentLabel, extent) -> do
              (extentLabel, overlayMouseAction extent panel (MouseDown panel Vty.BRight [] zeroLoc)) `shouldBe` (extentLabel, Just OverlayMouseClose)
              (extentLabel, overlayMouseAction extent panel (MouseDown viewport Vty.BRight [] zeroLoc)) `shouldBe` (extentLabel, Just OverlayMouseClose)
              (extentLabel, overlayMouseAction extent panel (MouseDown backgroundCard Vty.BRight [] zeroLoc)) `shouldBe` (extentLabel, Just OverlayMouseClose)
              (extentLabel, overlayMouseAction extent panel (VtyEvent (Vty.EvMouseDown 0 0 Vty.BRight []))) `shouldBe` (extentLabel, Just OverlayMouseClose)

          it "leaves a left click on the panel itself inert, at either extent" $
            for_ bothExtents $ \(extentLabel, extent) ->
              (extentLabel, overlayMouseAction extent panel (MouseDown panel Vty.BLeft [] zeroLoc)) `shouldBe` (extentLabel, Just OverlayMouseNoOp)
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

    -- issue #515 requirement 8's two absolute gestures. Unlike the relative
    -- scrolls above, these land on a known end, so the follow state comes
    -- from which end rather than from where an offset happened to stop.
    it "disengages following when g reaches the beginning of a scrollable transcript" $ do
      let scrollable = Just (TranscriptGeometry {transcriptTop = 40, transcriptHeight = 20, transcriptContentHeight = 400})
      followAfterJump TranscriptBeginning scrollable `shouldBe` False
      -- Even from a transcript that was following its tail a moment ago: the
      -- beginning of a scrollable transcript is not its tail.
      followAfterJump TranscriptBeginning (Just (TranscriptGeometry {transcriptTop = 380, transcriptHeight = 20, transcriptContentHeight = 400}))
        `shouldBe` False

    it "keeps following when g reaches the beginning of a transcript with no scrollback" $ do
      -- Content shorter than the viewport shows both ends at once, so `g`
      -- moves nothing and must not silently stop the live tail.
      followAfterJump TranscriptBeginning (Just (TranscriptGeometry {transcriptTop = 0, transcriptHeight = 20, transcriptContentHeight = 5}))
        `shouldBe` True
      followAfterJump TranscriptBeginning (Just (TranscriptGeometry {transcriptTop = 0, transcriptHeight = 20, transcriptContentHeight = 20}))
        `shouldBe` True
      -- A viewport that has never been rendered has no scrollback either.
      followAfterJump TranscriptBeginning Nothing `shouldBe` True

    it "re-engages following when G reaches the live tail, whatever the geometry" $
      mapM_
        (\geometry -> followAfterJump TranscriptTail geometry `shouldBe` True)
        [ Nothing,
          Just (TranscriptGeometry {transcriptTop = 0, transcriptHeight = 20, transcriptContentHeight = 400}),
          Just (TranscriptGeometry {transcriptTop = 40, transcriptHeight = 20, transcriptContentHeight = 400}),
          Just (TranscriptGeometry {transcriptTop = 0, transcriptHeight = 20, transcriptContentHeight = 5})
        ]

    it "recognizes the arrow bindings every transcript overlay shares" $ do
      transcriptScrollKey (Vty.EvKey Vty.KDown []) `shouldBe` Just 1
      transcriptScrollKey (Vty.EvKey Vty.KUp []) `shouldBe` Just (-1)

    -- issue #515 retired Ctrl-J/Ctrl-K along with the capability that gated
    -- them: plain `j` and `k` do that job for every kind now, in normal mode,
    -- and this is the only layer that ever answered the chords.
    it "no longer recognizes the review overlay's retired Ctrl-J/Ctrl-K chords" $ do
      transcriptScrollKey (Vty.EvKey (Vty.KChar 'j') [Vty.MCtrl]) `shouldBe` Nothing
      transcriptScrollKey (Vty.EvKey (Vty.KChar 'k') [Vty.MCtrl]) `shouldBe` Nothing

    -- The arrows alone: `j` and `k` are modal and so are decided a layer up,
    -- by 'sessionInputEvent', which is where the mode is known.
    it "leaves typing and the overlays' other bindings out of the scroll path" $
      mapM_
        (\event -> transcriptScrollKey event `shouldBe` Nothing)
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
      let wheelAmount panel button = case overlayMouseAction WindowedOverlay panel (VtyEvent (Vty.EvMouseDown 0 0 button [])) of
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

  describe "the review key on an epic header" $ do
    -- Issue #254. 'selectedReviewItem' promotes both epic-header shapes to
    -- the tracker's own issue, which is exactly what solve, autosolve and
    -- the kill binding want. Review does not: an epic carries no
    -- Requirements or Acceptance for the canonical gate to read, so @r@ on a
    -- header used to open an overlay, launch a session, and leave a badge on
    -- board structure. The refusal is a notice only, so 'appReviewSessions'
    -- is never written and no badge can appear.
    let epicHeaderRow = 0
        collapsedChildRow = 1
        ordinaryIssueRow = 3
        pullRequest = basePullRequest 42 [] False []
        board =
          fixtureBoard
            [ ( Issues,
                [ TrackerHeader (fixtureTracker 700),
                  fixtureTrackedEntry 800 [] 811,
                  fixtureTrackedEntry 800 [] 812,
                  fixtureStandaloneEntry 10
                ]
              ),
              (Reviewing, [Standalone (PullRequestItem pullRequest)])
            ]
        selectedState column row = do
          state <- testAppState board
          pure state {appSelectedColumn = column, appSelectedRows = Map.insert column row state.appSelectedRows}
        withExpandedTracker state = state {appExpandedTrackers = Set.fromList [800]}

    it "refuses a collapsed epic group and a childless epic header" $ do
      collapsed <- selectedState Issues collapsedChildRow
      header <- selectedState Issues epicHeaderRow
      selectedReviewTarget collapsed `shouldBe` ReviewTargetRefused CollapsedEpicGroup
      selectedReviewTarget header `shouldBe` ReviewTargetRefused StructuralEpicHeader

    it "explains each refusal, naming the expand key when there is a child to reach" $ do
      -- Requirement 3 follows 'openSelectedDetails', which answers Enter on
      -- a collapsed header with the key that makes its children selectable.
      epicReviewRefusalNotice CollapsedEpicGroup
        `shouldBe` "An epic header is not reviewable; press e to expand it and select a child"
      epicReviewRefusalNotice StructuralEpicHeader
        `shouldBe` "An epic header is not reviewable; it is board structure, not work"

    it "refuses a childless header from its open details overlay too" $ do
      -- The details path presses the key against the item the overlay
      -- already holds, so it cannot reach the board resolution above and
      -- needs the same refusal of its own.
      state <- testAppState board
      itemReviewRefusal state (IssueItem (baseIssue 700 [])) `shouldBe` Just StructuralEpicHeader
      itemReviewRefusal state (IssueItem (baseIssue 10 [])) `shouldBe` Nothing
      itemReviewRefusal state (PullRequestItem pullRequest) `shouldBe` Nothing

    it "leaves solve, autosolve, and kill resolving the epic issue from both headers" $ do
      -- Requirement 6: 'selectedReviewIssue' and 'selectedReviewItem' are
      -- shared with 'openSelectedSolveChooser' and
      -- 'killSelectedWorkingProcess', so the refusal above must not have
      -- moved what those two see.
      collapsed <- selectedState Issues collapsedChildRow
      header <- selectedState Issues epicHeaderRow
      selectedReviewItem collapsed `shouldBe` Just (IssueItem (baseIssue 800 []))
      selectedReviewItem header `shouldBe` Just (IssueItem (baseIssue 700 []))
      ((.issueNumber) <$> selectedReviewIssue collapsed) `shouldBe` Just 800
      ((.issueNumber) <$> selectedReviewIssue header) `shouldBe` Just 700

    it "still reviews an ordinary issue, an expanded tracker's child, and a pull request" $ do
      ordinary <- selectedState Issues ordinaryIssueRow
      child <- withExpandedTracker <$> selectedState Issues collapsedChildRow
      selectedPullRequest <- selectedState Reviewing 0
      selectedReviewTarget ordinary `shouldBe` ReviewTargetItem (IssueItem (baseIssue 10 []))
      selectedReviewTarget child `shouldBe` ReviewTargetItem (IssueItem (baseIssue 811 []))
      selectedReviewTarget selectedPullRequest `shouldBe` ReviewTargetItem (PullRequestItem pullRequest)
