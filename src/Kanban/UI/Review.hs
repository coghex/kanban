module Kanban.UI.Review
  ( ReviewCancelAction (..),
    ReviewDigitAction (..),
    applyCanonicalIssueReview,
    applyIssueActionFinished,
    applyIssueActionOrphans,
    applyIssueActionRefused,
    applyReviewAnimationTick,
    applyReviewDiagnostic,
    applyReviewEvent,
    applyReviewInput,
    reviewOutputPrefix,
    reviewProtocolWarningNotice,
    applyFailedInterrupt,
    applyUndeliveredSteer,
    carryUndelivered,
    undeliveredForIssue,
    approvalServiceRefusal,
    armReviewTick,
    armVisibleReviewTicks,
    cancelReviewSession,
    canonicalReviewActivity,
    claudeTranscriptStart,
    canonicalReviewCompletionSuperseded,
    canonicalReviewNotice,
    chooseReviewOption,
    epicReviewRefusalNotice,
    forcedToNormalBy,
    markReviewSessionDisconnected,
    newReviewSession,
    reviewOutcomePhase,
    reviewSessionHoldsUnsentText,
    reviewSubmission,
    numberedChoicePrompt,
    resolveReviewCancelAction,
    reviewDigitActionFor,
    resolveReviewDigitAction,
    reviewSessionsNeedingArm,
    startItemReview,
    startSelectedReview,
    submitReviewInput,
    terminateIssueAction,
  )
where


import Brick
import Brick.BChan (writeBChan)
import Control.Concurrent (forkIO)
import Control.Monad (unless, void )
import Control.Monad.IO.Class (liftIO)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Time (getCurrentTime)
import qualified Data.Text as Text
import Kanban.ApprovalService (approvalContentionNotice, approvalOwnsCanonicalReview)
import Kanban.Config (ResolvedConfig (..) )
import Kanban.Domain
import Kanban.Models (ProviderName, providerDisplayName, providerKey)
import Kanban.Preflight (preflightDiagnosticDetail)
import Kanban.Review
  ( CanonicalIssueReviewResult (..),
    ReviewAnswer (..),
    ReviewChoice (..),
    ReviewEvent (..),
    ReviewOutputKind (..),
    ReviewQuestion (..),
    ReviewQuestionKind (..),
    ReviewRequestId,
    ReviewResult (..),
    ReviewStage (..),
    ReviewThreadId (..),
    ReviewTurnOutcome (..),
    outcomeUnknownDiagnostic,
    renderCanonicalIssueReviewResult,
    renderReviewResult,
    reviewStageForLabels
    )
import Kanban.Settings
  ( ChatVerbosity (..)
    )
import Kanban.Action
  ( ActionTarget (..),
    ActionEnvironment (..),
    ActionTargetKind (..),
    ActionTargetRef (..),
    TargetStructure (..),
    WorkflowActionKind (..),
    actionHandleWorker,
    actionRefusalMessage,
    actionRequest,
    catalogIdentity,
    dispatchProviderTurn,
    planResolvedAction,
    resolveHeldItem,
  )
import Kanban.Solve (SolveOutcome (..))
import Kanban.Text (sanitizeText)
import Kanban.Worker
  ( ReviewCommand (..),
    ReviewCommandPayload (..),
    appendReviewCommand,
    newReviewCommandId,
    readWorkerState,
    WorkerSpec (..),
    WorkerState (..),
    WorkerDescriptor (..),
    ProcessIdentity,
  )
import Kanban.UI.Filter (dashboardActionEnvironment, readOnlyHistoryRefusal)
import Kanban.UI.Keys (BoardAction (..), actionKeyText)
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.SessionCore
import Kanban.UI.State
import Kanban.UI.Transcript
import Kanban.UI.Session
import Kanban.UI.SessionEvents
import Kanban.UI.Refresh
import Kanban.UI.PullRequest

-- | What a digit key '1'..'9' should do given the pending review
-- interaction (if any) and the 0-based choice index it encodes. Pulled out
-- of 'chooseReviewOption' so the dispatch rules are unit-testable without an
-- 'EventM' harness.
data ReviewDigitAction
  = ReviewDigitAppend
  | -- | A normal-mode digit that no pending numbered choice claims. §7 makes
    -- it nothing at all rather than text: normal mode is where the digits are
    -- commands, and a command with no subject does not quietly type itself
    -- into a draft the user cannot see (issue #515).
    ReviewDigitIgnored
  | ReviewDigitSelectChoice ReviewRequestId ReviewChoice
  | ReviewDigitApprovalOnce ReviewRequestId
  | ReviewDigitApprovalSession ReviewRequestId
  | ReviewDigitApprovalDecline ReviewRequestId
  | ReviewDigitUnavailable Text
  deriving stock (Eq, Show)

resolveReviewDigitAction :: SessionMode -> Maybe PendingReviewInteraction -> Int -> ReviewDigitAction
resolveReviewDigitAction mode pending choiceIndex = case (mode, claimed) of
  (SessionNormal, ReviewDigitAppend) -> ReviewDigitIgnored
  _ -> claimed
  where
    claimed = case pending of
      Just (PendingReviewQuestion requestId question)
        | question.reviewQuestionKind == QuestionText -> ReviewDigitAppend
        | otherwise -> case safeIndex choiceIndex question.reviewQuestionChoices of
            Just choice -> ReviewDigitSelectChoice requestId choice
            Nothing
              | question.reviewQuestionAllowOther -> ReviewDigitAppend
              | otherwise -> ReviewDigitUnavailable "That review choice is not available"
      Just (PendingReviewApproval requestId _approval) -> case choiceIndex of
        0 -> ReviewDigitApprovalOnce requestId
        1 -> ReviewDigitApprovalSession requestId
        2 -> ReviewDigitApprovalDecline requestId
        _ -> ReviewDigitUnavailable "That approval choice is not available"
      Nothing -> ReviewDigitAppend

-- | Whether a question the agent just asked offers numbered choices at all.
-- A free-text-only request does not, so it leaves the session's mode alone
-- and an already-typing user keeps typing; anything with a numbered list is
-- what §7 makes normal mode's digits answer.
numberedChoicePrompt :: ReviewQuestion -> Bool
numberedChoicePrompt question = not (null question.reviewQuestionChoices)

-- | Drop one session back to normal mode for a prompt whose answer is a
-- digit, so the digit answers it instead of being typed into the draft
-- (issue #515). Only the mode moves: the draft and the undelivered-steer
-- queue behind it are exactly what the user still has to send afterwards, and
-- only this session is touched -- prompts arrive per thread and a background
-- tab's mode is none of their business.
forcedToNormalBy :: Bool -> ReviewSession -> ReviewSession
forcedToNormalBy False session = session
forcedToNormalBy True session = setSessionMode SessionNormal session

-- | The action a digit press means for one review session, if the map still
-- holds it: the whole decision 'chooseReviewOption' carries out, mode
-- included.
--
-- Pulled out for the reason 'resolveReviewDigitAction' already was, and
-- extended to cover the mode because that is where the two could disagree.
-- The mode is 'reviewSessionMode', never the stored field: a session can
-- settle into a phase with no reader while its own mode still says insert and
-- a pending interaction is still on it -- 'ReviewClientStopped' marks a
-- session 'ReviewFailed' without clearing the interaction. The decoder reads
-- such a session as normal, so taking the raw field here would answer the
-- same press differently and type the digit into a draft that can never be
-- sent.
reviewDigitActionFor :: Maybe ReviewSession -> Int -> ReviewDigitAction
reviewDigitActionFor session choiceIndex =
  resolveReviewDigitAction
    (maybe SessionNormal reviewSessionMode session)
    (session >>= (.sessionDetail.reviewSessionPending))
    choiceIndex

chooseReviewOption :: Int -> Int -> EventM Name AppState ()
chooseReviewOption issueNumber choiceIndex = do
  state <- get
  case reviewDigitActionFor (Map.lookup issueNumber state.appReviewSessions) choiceIndex of
    ReviewDigitAppend -> modifyReviewSession issueNumber (insertSessionInput (toEnum (fromEnum '1' + choiceIndex)))
    ReviewDigitIgnored -> pure ()
    ReviewDigitSelectChoice requestId choice -> submitQuestionAnswer issueNumber requestId (ReviewAnswer [choice.reviewChoiceId] Nothing) choice.reviewChoiceLabel
    ReviewDigitApprovalOnce requestId -> submitApprovalAnswer issueNumber requestId True False "Allowed this action once"
    ReviewDigitApprovalSession requestId -> submitApprovalAnswer issueNumber requestId True True "Allowed similar actions for this review session"
    ReviewDigitApprovalDecline requestId -> submitApprovalAnswer issueNumber requestId False False "Declined this action"
    ReviewDigitUnavailable message -> setNotice message

submitReviewInput :: Int -> EventM Name AppState ()
submitReviewInput issueNumber = do
  state <- get
  case Map.lookup issueNumber state.appReviewSessions of
    Nothing -> setNotice "Review session is no longer available"
    Just session
      | Text.null (Text.strip session.sessionInput) -> setNotice "Type a message or select one of the numbered choices"
      | otherwise -> case session.sessionDetail.reviewSessionPending of
          Just (PendingReviewQuestion requestId question)
            | question.reviewQuestionKind == QuestionText || question.reviewQuestionAllowOther ->
                let answerText = Text.strip session.sessionInput
                 in submitQuestionAnswer issueNumber requestId (ReviewAnswer [] (Just answerText)) answerText
            | otherwise -> setNotice "This question requires one of the numbered choices"
          Just (PendingReviewApproval _ _) -> setNotice "Use 1, 2, or 3 to answer the approval request"
          Nothing -> sendReviewFeedback issueNumber session

-- | Every dashboard input reaches its action the same way: as one durable,
-- correlated, deduplicated command written to that action's own command
-- journal (requirement 9).
--
-- Not a direct call into a client, because there is no longer one to call:
-- the review runs inside the repository host, and the dashboard that submits
-- a command may be closed before the provider reads it and replaced by
-- another before the answer comes back. The command carries the thread and
-- turn the overlay was looking at, so the host can refuse one aimed at a turn
-- that has since ended rather than silently retargeting it at the next.
--
-- What the user sees happen is /not/ written here. The transcript entry
-- arrives back through the child's journal as a 'WorkerReviewInput', which is
-- what makes the line identical for the dashboard that typed it and for one
-- that reattaches later (requirement 4). Only the input line is cleared here,
-- because that is this dashboard's own draft rather than the action's
-- evidence.
submitReviewCommand :: Int -> ReviewCommandPayload -> EventM Name AppState ()
submitReviewCommand issueNumber payload = do
  state <- get
  case issueActionWorkerFor state issueNumber of
    Nothing -> setNotice issueActionGoneNotice
    Just descriptor -> do
      recorded <- liftIO (readWorkerState descriptor)
      identifier <- liftIO newReviewCommandId
      now <- liftIO getCurrentTime
      let command =
            ReviewCommand
              { reviewCommandId = identifier,
                reviewCommandTarget = descriptor.workerDescriptorSpec.workerId,
                reviewCommandIssue = issueNumber,
                reviewCommandThread = either (const Nothing) (.workerStateReviewThread) recorded,
                reviewCommandTurn = either (const Nothing) (.workerStateReviewTurn) recorded,
                reviewCommandIssuedAt = now,
                reviewCommandPayload = payload
              }
      written <- liftIO (appendReviewCommand descriptor command)
      case written of
        Left message -> setNotice (agentFailureNotice "Issue review" message)
        Right () -> modifyReviewSession issueNumber clearedInput
  where
    -- Cleared even for a command the host may reject: a rejection comes back
    -- as an undelivered message that is offered to the line again, and
    -- leaving the text there in the meantime would show it twice. What the
    -- line was holding goes with it, so a later draft that happens to read
    -- the same is not mistaken for a resend.
    clearedInput session = (withRestored Nothing session) {sessionInput = ""}

issueActionGoneNotice :: Text
issueActionGoneNotice = "This review is no longer running; press " <> actionKeyText ReviewSelection <> " to start a fresh one"

submitQuestionAnswer :: Int -> ReviewRequestId -> ReviewAnswer -> Text -> EventM Name AppState ()
submitQuestionAnswer issueNumber requestId answer displayAnswer =
  submitReviewCommand issueNumber (AnswerReviewQuestion requestId answer displayAnswer)

submitApprovalAnswer :: Int -> ReviewRequestId -> Bool -> Bool -> Text -> EventM Name AppState ()
submitApprovalAnswer issueNumber requestId accepted forSession displayAnswer =
  submitReviewCommand issueNumber (AnswerReviewApproval requestId accepted forSession displayAnswer)

-- | Ordinary feedback, or the deliberate resend of a steer the provider
-- refused.
--
-- The two are distinct commands rather than one, because a resend is the
-- recovery of a specific earlier message (issue #17) and reporting it as a
-- fresh one would lose that. Which of them a submission is depends on whether
-- the line is carrying a message handed back — 'takeNextUndelivered' is what
-- puts one there — so the queue is consulted here rather than at the send.
sendReviewFeedback :: Int -> ReviewSession -> EventM Name AppState ()
sendReviewFeedback issueNumber session =
  submitReviewCommand issueNumber (reviewSubmission session)

-- | Which command the message on a session's input line is.
--
-- A resend exactly when the line is holding a message that was handed back
-- rather than one the user typed, and only while that message is still the
-- one on the line: editing it makes it new text, which is the whole point of
-- offering it back editable.
reviewSubmission :: ReviewSession -> ReviewCommandPayload
reviewSubmission session
  | session.sessionDetail.reviewSessionRestored == Just message = ResendReviewSteer message
  | otherwise = SendReviewFeedback message
  where
    message = Text.strip session.sessionInput

-- | What the input line becomes once the message on it has been sent: empty
-- as before, unless a previously rejected steer is still waiting, in which
-- case the oldest one comes back for a deliberate resend. Sending is the only
-- moment the line is known to be free, so it is where the queue drains
-- without ever overwriting something the user typed (issue #17).
takeNextUndelivered :: [Text] -> (Text, [Text])
takeNextUndelivered [] = ("", [])
takeNextUndelivered (next : remaining) = (next, remaining)

-- | Folds a rejected steer back into its session. A steer is only ever
-- rejected by a thread that is still running, so its session can always take
-- the message back onto its input line (issue #17).
applyUndeliveredSteer :: Text -> ReviewSession -> ReviewSession
applyUndeliveredSteer = holdUndelivered True

-- | Folds a message the provider never read back into its session.
--
-- It goes onto the input line only when the line is free /and/ the session
-- can still send from it — otherwise it queues behind whatever is already
-- waiting, so neither a draft typed after the original send nor an earlier
-- undelivered message is overwritten or truncated. The queue is drawn in the
-- overlay and drains oldest-first the next time a send succeeds, which is why
-- it is where a message goes when the input line is not an offer the session
-- can honour: a settled session's line takes no keystrokes and submits
-- nothing, so text parked there would look like a draft and behave like a
-- decoration.
--
-- The transcript is annotated in every case, since 'sendReviewFeedback'
-- already wrote an optimistic @You:@ entry that would otherwise claim the
-- message was delivered.
holdUndelivered :: Bool -> Text -> ReviewSession -> ReviewSession
holdUndelivered inputLive message session =
  (withRestored restored (withUndelivered stillUndelivered session))
    { sessionInput = nextInput,
      sessionTranscript =
        appendTranscript session.sessionTranscript ("\n" <> undeliveredTranscriptNote message <> "\n")
    }
  where
    queued = session.sessionDetail.reviewSessionUndelivered <> [message]
    (nextInput, stillUndelivered)
      | inputLive, Text.null (Text.strip session.sessionInput) = takeNextUndelivered queued
      | otherwise = (session.sessionInput, queued)
    -- Only when this call is what put the message there. A line already
    -- carrying the user's own draft keeps whatever it was holding.
    restored
      | nextInput == session.sessionInput = session.sessionDetail.reviewSessionRestored
      | otherwise = Just nextInput

-- | Record what an issue's review still owes a send, dropping the entry
-- entirely once nothing is owed so the map holds only live obligations.
holdUndeliveredForIssue :: Int -> [Text] -> Map Int [Text] -> Map Int [Text]
holdUndeliveredForIssue issueNumber owed held
  | null owed = Map.delete issueNumber held
  | otherwise = Map.insert issueNumber owed held

-- | Whether a session is still holding text nobody has managed to send.
--
-- The input line as well as the queue, because that is where a message
-- handed back lands while the session is still live — and a turn reaching
-- its verdict a moment later is exactly what turns that offer into a dead
-- one. A draft typed mid-turn counts for the same reason: once the session
-- cannot send, it is as stranded as anything the backend refused, and
-- telling the two apart would only decide which of them to lose.
reviewSessionHoldsUnsentText :: ReviewSession -> Bool
reviewSessionHoldsUnsentText session =
  any
    (not . Text.null . Text.strip)
    (session.sessionInput : session.sessionDetail.reviewSessionUndelivered)

-- | Carries what a session being replaced never managed to send into the
-- session replacing it: the draft on its input line, and everything still
-- waiting behind it, oldest first.
--
-- The other half of handing a message back. A message that failed to reach
-- the provider is put where the session can still act on it, but a session
-- whose backend has gone cannot act on anything — so it holds the message in
-- its queue, and the press that starts the review it needs is the one press
-- that would otherwise throw it away with the session it was parked in. This
-- is what makes "kept in the review session" true across that press rather
-- than only until it.
--
-- The old line goes first because it is what the user was last looking at,
-- and the queue follows in the order it accumulated; empty text is dropped
-- rather than carried as a blank entry.
--
-- Only into a session that can send it, and what it cannot take is held for
-- the issue instead rather than either forced on it or thrown away. @r@
-- starts whatever stage the labels ask for, and a revision that published
-- its verdict moves them on — so the session replacing it is often a
-- canonical stage, which runs the gate as a subprocess and holds no thread
-- to send anything on. Text put there would look kept while being
-- unreachable, and text dropped there would be lost to the single keystroke
-- the user made to carry on; 'appReviewUndelivered' is neither.
carryUndelivered :: [Text] -> ReviewSession -> (ReviewSession, [Text])
carryUndelivered carried session
  | not (reviewSessionInputLive session.sessionDetail.reviewSessionStage session.sessionPhase) = (session, offered)
  | otherwise = ((withRestored (restoredFrom nextInput) (withUndelivered stillUndelivered session)) {sessionInput = nextInput}, [])
  where
    (nextInput, stillUndelivered) = takeNextUndelivered offered
    offered = filter (not . Text.null . Text.strip) carried
    restoredFrom line = if Text.null line then Nothing else Just line

-- | Everything an issue's review still owes a send, oldest first: what the
-- session being replaced was holding, and whatever earlier stages could not
-- take.
--
-- The replaced session's own line goes first because it is what the user was
-- last looking at, then its queue, then what was already being held for the
-- issue — so the most recent thing they saw is the one that comes back to
-- the line.
undeliveredForIssue :: Maybe ReviewSession -> [Text] -> [Text]
undeliveredForIssue previous held = maybe [] fromSession previous <> held
  where
    fromSession session = session.sessionInput : session.sessionDetail.reviewSessionUndelivered

clearPendingInteraction :: ReviewSession -> ReviewSession
clearPendingInteraction = withPendingInteraction Nothing

withPendingInteraction :: Maybe PendingReviewInteraction -> ReviewSession -> ReviewSession
withPendingInteraction pending = withSessionDetail (\detail -> detail {reviewSessionPending = pending})

withUndelivered :: [Text] -> ReviewSession -> ReviewSession
withUndelivered undelivered = withSessionDetail (\detail -> detail {reviewSessionUndelivered = undelivered})

withRestored :: Maybe Text -> ReviewSession -> ReviewSession
withRestored restored = withSessionDetail (\detail -> detail {reviewSessionRestored = restored})

-- | The phase a completed turn leaves its session in.
--
-- Lifted out of 'applyReviewEvent' rather than left inline because it is the
-- rule that decides whether a session can still be sent to, and anything
-- reasoning about what a turn's end leaves behind — a test covering the
-- sequence a failed interrupt arrives in, above all — has to reach the same
-- answer the event handler does rather than name a phase and hope.
reviewOutcomePhase :: ReviewStage -> ReviewTurnOutcome -> Maybe ReviewResult -> ReviewPhase
reviewOutcomePhase IssueRevision TurnSucceeded (Just result)
  | null result.reviewResultBlockingReasons = ReviewFinished
  | otherwise = ReviewNeedsChanges
reviewOutcomePhase _ TurnSucceeded (Just result)
  | result.reviewResultApproved = ReviewFinished
  | otherwise = ReviewNeedsChanges
reviewOutcomePhase _ TurnSucceeded Nothing = ReviewFailed
reviewOutcomePhase _ TurnFailed _ = ReviewFailed
reviewOutcomePhase _ TurnInterrupted _ = ReviewInterrupted

undeliveredTranscriptNote :: Text -> Text
undeliveredTranscriptNote message = "[not delivered] " <> message

undeliveredNotice :: Text
undeliveredNotice = "Your message was not delivered — it is waiting in the review session to resend"

-- | Folds a failed interrupt back into its session: what went wrong, and —
-- when a message was riding on it — the same restoration a rejected steer
-- gets (issue #17).
--
-- Both halves are needed and neither substitutes for the other. A message
-- sent on the Claude path is shown as sent the moment the control request is
-- written, because that is the last synchronous moment there is (D-16), so a
-- session told only that something failed would go on displaying a @You:@
-- entry for text the provider never read. And a cancellation carries no
-- message at all, yet a cancellation that did not happen is exactly what a
-- user watching a turn keep running needs told.
--
-- Where the message lands is decided from the session this leaves behind,
-- not from the one that sent it. A refused interrupt leaves a thread still
-- running and an input line that can resend; a connection that died leaves a
-- settled session whose line takes nothing, and this event arrives after the
-- events that settle it precisely so that difference is visible here.
applyFailedInterrupt :: Text -> Maybe Text -> ReviewSession -> ReviewSession
applyFailedInterrupt cause message session = maybe noted hold message
  where
    hold text =
      holdUndelivered
        (reviewSessionInputLive noted.sessionDetail.reviewSessionStage noted.sessionPhase)
        text
        noted
    noted =
      session
        { sessionTranscript =
            appendTranscript session.sessionTranscript ("\n" <> interruptFailureTranscriptNote cause <> "\n")
        }

interruptFailureTranscriptNote :: Text -> Text
interruptFailureTranscriptNote cause = "[interrupt failed] " <> sanitizeText cause

-- | The notice a failed interrupt raises. It says what went wrong either way,
-- and adds where the message went only when there was one to put back.
interruptFailureNotice :: Text -> Maybe Text -> Text
interruptFailureNotice cause message = "Interrupt failed: " <> sanitizeText cause <> whereItWent
  where
    whereItWent = case message of
      Nothing -> ""
      -- Kept, not "waiting to resend": where it is waiting depends on whether
      -- the session survived, and a notice promising a resend from one that
      -- did not would be the same false claim the optimistic entry made.
      Just _ -> " — your message was not delivered and is kept in the review session"

-- | What Ctrl-C/Ctrl-X in a review overlay should do, decided from the
-- action's own live state rather than inline in 'cancelReviewSession' so the
-- routing between the interrupt path (the only resumable turn) and a
-- canonical stage's process interrupt/kill escalation is unit-testable
-- without an 'EventM' harness.
--
-- The split is stage-specific and stays that way (requirement 13). Only an
-- interactive revision holding a thread and a turn gets a turn interrupt;
-- every canonical stage escalates to ending the whole child, because a
-- canonical stage has no turn to redirect and never resumes.
data ReviewCancelAction
  = ReviewCancelInterruptTurn ReviewThreadId Text
  | ReviewCancelInterruptProcess
  | ReviewCancelStillStarting
  | ReviewCancelNotRunning
  | ReviewCancelNoActiveTurn
  deriving stock (Eq, Show)

resolveReviewCancelAction :: Bool -> Maybe ReviewThreadId -> Maybe Text -> ReviewStage -> ReviewPhase -> Bool -> ReviewCancelAction
resolveReviewCancelAction actionLive threadId turnId stage phase hasCanonicalAction
  | actionLive, Just thread <- threadId, Just turn <- turnId = ReviewCancelInterruptTurn thread turn
  | hasCanonicalAction, stage /= IssueRevision = ReviewCancelInterruptProcess
  | stage /= IssueRevision, phase == ReviewStarting = ReviewCancelStillStarting
  | stage /= IssueRevision = ReviewCancelNotRunning
  | otherwise = ReviewCancelNoActiveTurn

cancelReviewSession :: Int -> EventM Name AppState ()
cancelReviewSession issueNumber = do
  state <- get
  case Map.lookup issueNumber state.appReviewSessions of
    Nothing -> setNotice "Review session is no longer available"
    Just session -> do
      let actionLive = isJust (issueActionWorkerFor state issueNumber)
          stage = session.sessionDetail.reviewSessionStage
      case resolveReviewCancelAction actionLive session.sessionDetail.reviewSessionThreadId session.sessionDetail.reviewSessionTurnId stage session.sessionPhase actionLive of
        ReviewCancelInterruptTurn _ _ -> do
          submitReviewCommand issueNumber InterruptReviewTurn
          setNotice ("Interrupting review #" <> showText issueNumber <> "; type guidance when the turn stops")
        ReviewCancelInterruptProcess -> cancelCanonicalIssueAction issueNumber
        ReviewCancelStillStarting -> setNotice ("Issue review #" <> showText issueNumber <> " is still starting; try Ctrl-C again once it is running")
        ReviewCancelNotRunning -> setNotice ("Issue review #" <> showText issueNumber <> " is not running")
        ReviewCancelNoActiveTurn -> setNotice "This review has no active turn to cancel"

-- | Ends a canonical stage's whole child action.
--
-- Canonical stages are not resumable turns, so unlike the interrupt path this
-- ends the action outright — which under runner ownership is a termination
-- command the host applies to that child alone, settling its subprocess and
-- descendants without touching the host or a sibling (requirement 11). The
-- session moves to the 'ReviewInterrupted' terminal phase immediately,
-- preserving the transcript, and the notice says a fresh stage restarts
-- rather than promising "type guidance" — the same meaning and the same
-- words as before (requirement 13).
-- | Ends one issue action outright, from a kill gesture rather than a
-- cancellation.
--
-- The same durable termination command 'cancelCanonicalIssueAction' submits,
-- with the wording a kill has always used. Child-scoped: its host settles
-- this action's thread or process and its descendants and leaves every
-- sibling — and itself — running (requirement 11).
terminateIssueAction :: Int -> EventM Name AppState ()
terminateIssueAction issueNumber = do
  appendToReviewSession issueNumber
    ( \session ->
        session
          { sessionPhase = ReviewFailed,
            sessionActivity = "killing process tree",
            sessionTranscript = appendTranscript session.sessionTranscript "\n[killed by user]\n"
          }
    )
  submitReviewCommand issueNumber TerminateIssueAction

cancelCanonicalIssueAction :: Int -> EventM Name AppState ()
cancelCanonicalIssueAction issueNumber = do
  appendToReviewSession issueNumber
    ( \session ->
        session
          { sessionPhase = ReviewInterrupted,
            sessionActivity = "interrupted",
            sessionTranscript = appendTranscript session.sessionTranscript "\n[interrupted by user]\n"
          }
    )
  submitReviewCommand issueNumber TerminateIssueAction
  setNotice ("Interrupting issue review #" <> showText issueNumber <> "; canonical stages don't resume — Esc, then r starts a fresh one")

appendReviewOutput :: ReviewOutputKind -> Text -> ChatTranscript -> ChatTranscript
appendReviewOutput outputKind addition transcript =
  ChatTranscript
    { compactTranscript = appendWhen (showReviewOutput CompactChat outputKind) transcript.compactTranscript,
      standardTranscript = appendWhen (showReviewOutput StandardChat outputKind) transcript.standardTranscript,
      fullTranscript = appendWhen (showReviewOutput FullChat outputKind) transcript.fullTranscript
    }
  where
    appendWhen True value = boundedAppend value addition
    appendWhen False value = value

-- | What a line of provider output is tagged with in the transcript.
--
-- Only the diagnostic kind carries a tag, and it names the provider the
-- event carries rather than a brand compiled in here: a @claude@ session's
-- stderr shown as @[codex]@ tells the operator the wrong program is
-- misbehaving. The key rather than the display name, because this is a
-- machine-ish tag beside raw output rather than prose — and because it is
-- what Codex's own lines have always read.
reviewOutputPrefix :: ReviewOutputKind -> Text
reviewOutputPrefix AgentOutput = ""
reviewOutputPrefix ReasoningOutput = ""
reviewOutputPrefix CommandOutput = ""
reviewOutputPrefix (DiagnosticOutput provider) = "[" <> providerKey provider <> "] "

reviewOutputActivity :: ReviewOutputKind -> Text
reviewOutputActivity AgentOutput = "responding"
reviewOutputActivity ReasoningOutput = "thinking"
reviewOutputActivity CommandOutput = "running command"
reviewOutputActivity DiagnosticOutput {} = "diagnostic output"

showReviewOutput :: ChatVerbosity -> ReviewOutputKind -> Bool
showReviewOutput CompactChat AgentOutput = True
showReviewOutput CompactChat _ = False
showReviewOutput StandardChat DiagnosticOutput {} = False
showReviewOutput StandardChat _ = True
showReviewOutput FullChat _ = True

startSelectedReview :: EventM Name AppState ()
startSelectedReview = do
  state <- get
  case selectedReviewTarget state of
    ReviewTargetNone -> setNotice ("Select an issue or PR before pressing " <> actionKeyText ReviewSelection)
    -- Lifecycle outranks the structural refusal: a closed epic's header is
    -- read-only history first and board structure second, and saying only the
    -- second would invite expanding it to find reviewable work that is not
    -- there.
    ReviewTargetRefused refusal ->
      setNotice (fromMaybe (epicReviewRefusalNotice refusal) (selectedReadOnlyHistoryRefusal state))
    ReviewTargetItem item -> startItemReview item

-- | The details overlay presses the review key against the item it already
-- holds, so the board resolution above has nothing left to refuse on. Both
-- paths therefore meet here, and the refusal is a plain notice: the overlay
-- stays open and 'appReviewSessions' is left exactly as it was, so no badge
-- appears on the header and no unrelated session is disturbed.
--
-- The read-only-history refusal is asked first, ahead of the structural one
-- and ahead of everything 'startIssueReview' and 'startPullRequestReview' go
-- on to decide — the review stage, the action, and whether a session already
-- open may be reused. An overlay or a reusable session can have been opened
-- while the work was live, so this is also the launch boundary that stops one
-- acting after a refresh settled the item beneath it.
startItemReview :: BoardItem -> EventM Name AppState ()
startItemReview item = do
  state <- get
  case (readOnlyHistoryRefusal state item, itemReviewRefusal state item) of
    (Just notice, _) -> setNotice notice
    (Nothing, Just refusal) -> setNotice (epicReviewRefusalNotice refusal)
    (Nothing, Nothing) -> case item of
      IssueItem issue -> startIssueReview issue
      PullRequestItem pullRequest -> startPullRequestReview pullRequest

-- | The read-only-history refusal for whatever the board has selected, which
-- is the one the structural refusals above have to be checked against: a
-- collapsed or childless epic never becomes a 'ReviewTargetItem', so its own
-- lifecycle has to be asked for here.
selectedReadOnlyHistoryRefusal :: AppState -> Maybe Text
selectedReadOnlyHistoryRefusal state = selectedReviewItem state >>= readOnlyHistoryRefusal state

-- | Why the review key did nothing, in the shape 'openSelectedDetails' set
-- for the same headers: name the reason, and name the key that reaches the
-- reviewable work whenever there is one to reach.
epicReviewRefusalNotice :: EpicReviewRefusal -> Text
epicReviewRefusalNotice CollapsedEpicGroup =
  "An epic header is not reviewable; press " <> actionKeyText ToggleEpic <> " to expand it and select a child"
epicReviewRefusalNotice StructuralEpicHeader =
  "An epic header is not reviewable; it is board structure, not work"

-- | The board's review key, as an adapter over the workflow action registry.
--
-- Three things happen here and nothing else: the stage is read off the
-- labels, a live child action for this issue is reattached to, and anything
-- else is dispatched. There is no second launch path — no canonical
-- subprocess started from Brick, no app-server turn opened from Brick
-- (requirement 14) — so what the board starts and what a headless mission
-- runner starts are one thing.
--
-- Reattachment comes first and is not a refusal (requirement 13, and the
-- rereview's third correction). Pressing the key on an issue whose action is
-- already live reopens its overlay and presents the transcript tail, exactly
-- as reopening a reusable in-memory session did; the registry's own lease
-- refusal is reserved for the fail-closed case where a turn is running and
-- its owner cannot be identified.
startIssueReview :: Issue -> EventM Name AppState ()
startIssueReview issue = do
  state <- get
  let requestedStage = issueReviewStage state.appConfig.resolvedWorkflow issue
  case Map.lookup issue.issueNumber state.appReviewSessions of
    Just session
      | reviewSessionReusable
          session.sessionPhase
          session.sessionDetail.reviewSessionStage
          requestedStage
          (liveCanonicalIssueAction state issue.issueNumber)
          (reviewSessionHoldsUnsentText session) -> do
          modify (\current -> noticeCleared current {appOverlay = Just (ReviewOverlay issue.issueNumber)})
          presentTranscriptTail
          armVisibleReviewTicks
    -- The service interlock is asked before an action is dispatched, so a
    -- press made while the approval service owns a canonical review reports
    -- the wait rather than creating a child that could only fail. The host
    -- asks it again at its own spawn boundary, because the service can take
    -- the backend's approval lock between this press and that spawn
    -- (requirement 7).
    _ | Just notice <- approvalServiceRefusal state requestedStage -> setNotice notice
    _ -> do
      let priorGeneration = priorTickGeneration issue.issueNumber state.appReviewSessions
          owed =
            undeliveredForIssue
              (Map.lookup issue.issueNumber state.appReviewSessions)
              (Map.findWithDefault [] issue.issueNumber state.appReviewUndelivered)
          (session, stillOwed) = carryUndelivered owed (newReviewSession issue requestedStage priorGeneration)
      modify
        ( \current ->
            noticeCleared
              current
                { appReviewSessions = Map.insert issue.issueNumber session current.appReviewSessions,
                  -- Kept for the issue rather than for the session that could
                  -- not take it, so the next one that can send is handed it.
                  appReviewUndelivered = holdUndeliveredForIssue issue.issueNumber stillOwed current.appReviewUndelivered,
                  appOverlay = Just (ReviewOverlay issue.issueNumber)
                }
        )
      presentTranscriptTail
      dispatchIssueReview issue requestedStage

-- | Dispatch one issue action through the registry.
--
-- Asynchronous, like every other launch boundary: the dispatch acquires the
-- child's lease, writes its specification, and ensures the repository host,
-- none of which the event loop may block on. The descriptor comes back as a
-- 'WorkerRegistered' event, which is what starts the journal monitor that
-- feeds this session every event the action produces.
dispatchIssueReview :: Issue -> ReviewStage -> EventM Name AppState ()
dispatchIssueReview issue stage = do
  state <- get
  let eventChannel = state.appEventChannel
      environment = dashboardActionEnvironment state
      kind = issueReviewActionKind stage
      -- Planned against the issue the press was made on rather than against
      -- its number, exactly as the solve boundary plans: that record is what
      -- every refusal above has already been asked about, and re-resolving
      -- the number would additionally refuse an issue that has since left the
      -- open read.
      planned =
        planResolvedAction
          state.appConfig.resolvedWorkflow
          (catalogIdentity environment.actionCatalog)
          kind
          Nothing
          (ActionTargetItem (resolveHeldItem environment.actionCatalog TargetPlain (IssueItem issue)))
      request = actionRequest kind (catalogIdentity environment.actionCatalog) (TargetByKind ActionTargetIssue issue.issueNumber)
  void . liftIO . forkIO $ case planned of
    Left refusal -> writeBChan eventChannel (IssueActionRefused issue.issueNumber (actionRefusalMessage refusal))
    Right plan -> do
      dispatched <- dispatchProviderTurn environment request plan
      case dispatched of
        Left refusal -> writeBChan eventChannel (IssueActionRefused issue.issueNumber (actionRefusalMessage refusal))
        Right handle -> mapM_ (writeBChan eventChannel . WorkerRegistered) (actionHandleWorker handle)

-- | Which registry verb a review stage is.
--
-- The stage is the authority and the verb follows it, never the other way
-- round: @review_issue@ runs the canonical @approve_issues.py@ gate for the
-- initial review and the rereview, and @revise_issue@ runs the interactive
-- coordinator for the revision (requirement 6).
issueReviewActionKind :: ReviewStage -> WorkflowActionKind
issueReviewActionKind IssueRevision = ReviseIssue
issueReviewActionKind _ = ReviewIssue

-- | A dispatch the registry refused. The session was created by the press
-- that reached it, so it settles here with the reason on it rather than
-- waiting for a turn that will never start — the same shape
-- this shape has always had.
applyIssueActionRefused :: Int -> Text -> EventM Name AppState ()
applyIssueActionRefused issueNumber notice = do
  appendToReviewSession issueNumber
    ( \session ->
        session
          { sessionPhase = ReviewFailed,
            sessionActivity = "not started",
            sessionTranscript = appendTranscript session.sessionTranscript ("\n" <> notice <> "\n")
          }
    )
  setNotice notice

issueReviewStage :: WorkflowConfig -> Issue -> ReviewStage
issueReviewStage config issue = reviewStageForLabels config (map (.labelName) issue.issueLabels)

-- | A fresh review session. 'priorGeneration' must be 0 for an issue with no
-- previous session, or the replaced session's 'sessionTickGeneration' when
-- 'startIssueReview' discards a non-reusable one (e.g. its stage no longer
-- matches current labels); 'newAgentSession' carries the construction-time
-- bump past it that keeps a tick the old session already queued from
-- colliding with this one before it has armed a chain of its own (issue #30
-- round-3 review, now shared by every kind).
newReviewSession :: Issue -> ReviewStage -> Int -> ReviewSession
newReviewSession issue stage priorGeneration =
  newAgentSession
    priorGeneration
    ReviewStarting
    (if stage == IssueRevision then "starting coordinator" else "running canonical gate")
    Nothing
    (plainTranscript (if stage == IssueRevision then "" else "Running canonical issue-review:v2 gate…\n"))
    ReviewDetail
      { reviewSessionIssue = issue,
        reviewSessionStage = stage,
        reviewSessionThreadId = Nothing,
        reviewSessionTurnId = Nothing,
        reviewSessionPending = Nothing,
        reviewSessionUndelivered = [],
        reviewSessionRestored = Nothing
      }

-- | Why a canonical stage started from a card has to wait for the persistent
-- issue approval service, if it does (requirement 8).
--
-- Three facts decide it, and each is why one of the arms is here.
--
-- A revision is never refused: 'reviewStageForLabels' maps a
-- changes-requested issue to 'IssueRevision', which runs the interactive
-- coordinator and performs no canonical backend review at all, so it contends
-- for nothing. That is what keeps the repair of a barriered issue reachable
-- while the service is on.
--
-- A barriered service is never refusing either. It performs no model work and
-- only rechecks one issue's read-only gate, releasing the backend's approval
-- lock between checks, so the rereview that follows a repair can take it
-- (D-10).
--
-- Everything else the service could be doing with a live run /is/ a refusal,
-- including for the issue the card names: the service reviews issues in
-- numeric order and cannot be asked to skip to this one, so a second canonical
-- child for the same issue is the same contention as for any other.
-- Neither this nor the live recheck below is what makes concurrent canonical
-- work safe: the backend's own approval lock is the cross-process authority.
-- Both exist so an operator is told to wait instead of watching a review queue
-- behind one it cannot see.
approvalServiceRefusal :: AppState -> ReviewStage -> Maybe Text
approvalServiceRefusal state stage
  | stage == IssueRevision = Nothing
  | approvalOwnsCanonicalReview state.appApprovalResult = Just approvalContentionNotice
  | otherwise = Nothing

-- | Whether a just-arrived 'CanonicalIssueReviewFinished' must be discarded
-- rather than applied: the session was already moved to 'ReviewInterrupted'
-- by a user Ctrl-C, so a late completion from that now-dead invocation must
-- not clobber the terminal state and its restart-oriented notice with the
-- generic failure/result transition below.
canonicalReviewCompletionSuperseded :: ReviewPhase -> Bool
canonicalReviewCompletionSuperseded phase = phase == ReviewInterrupted

applyCanonicalIssueReview :: Int -> ReviewStage -> Either Text CanonicalIssueReviewResult -> EventM Name AppState ()
applyCanonicalIssueReview issueNumber stage result = do
  state <- get
  let superseded = maybe False (canonicalReviewCompletionSuperseded . (.sessionPhase)) (Map.lookup issueNumber state.appReviewSessions)
  unless superseded $ do
    appendToReviewSession issueNumber $ \session -> case result of
      Left message -> session {sessionPhase = ReviewFailed, sessionActivity = canonicalReviewActivity message, sessionTranscript = appendTranscript session.sessionTranscript ("\n" <> sanitizeText message <> "\n")}
      Right canonicalResult ->
        session
          { sessionPhase = if canonicalResult.canonicalReviewApproved then ReviewFinished else ReviewNeedsChanges,
            sessionActivity = if canonicalResult.canonicalReviewApproved then "approved" else "changes requested",
            sessionTranscript = appendTranscript session.sessionTranscript ("\n" <> renderCanonicalIssueReviewResult stage canonicalResult)
          }
    startBoardRefresh
    setNotice (case result of Left message -> canonicalReviewNotice message; Right _ -> stageActivity stage <> " completed with issue-review:v2 state")
  where
    stageActivity InitialReview = "Issue review"
    stageActivity IssueRereview = "Issue rereview"
    stageActivity IssueRevision = "Issue revision"

-- | The activity and notice text for a canonical review that produced no
-- usable result. A run whose GitHub-side outcome was simply never observed
-- (its process outlived the deadline, or its output never finished
-- arriving) may well have posted its verdict comment and moved the labels,
-- so neither line may claim the review failed -- only that this end of it
-- could not see what happened. The invocation itself is still terminal, so
-- the session phase stays 'ReviewFailed' either way.
canonicalReviewActivity :: Text -> Text
canonicalReviewActivity message
  | outcomeUnknownDiagnostic message = "outcome unknown"
  | isJust (preflightDiagnosticDetail message) = "setup required"
  | otherwise = "failed"

canonicalReviewNotice :: Text -> Text
canonicalReviewNotice message
  | outcomeUnknownDiagnostic message = "Canonical issue review outcome could not be observed; check the issue before running it again"
  | otherwise = agentFailureNotice "Canonical issue review" message

reviewProtocolWarningNotice :: ProviderName -> Text -> Text
reviewProtocolWarningNotice provider message =
  providerDisplayName provider <> " protocol warning: " <> message

applyReviewEvent :: Int -> ReviewEvent -> EventM Name AppState ()
applyReviewEvent issueNumber reviewEvent = case reviewEvent of
  ReviewThreadCreated _ threadId ->
    appendToReviewSession issueNumber
      ( \session ->
          (withSessionDetail (\detail -> detail {reviewSessionThreadId = Just threadId}) session)
            { sessionActivity = "session ready",
              sessionTranscript = appendTranscript session.sessionTranscript "Codex session created.\n"
            }
      )
  ReviewTurnStarted _ turnId -> do
    modifyReviewSession issueNumber
      ( \session ->
          ( clearPendingInteraction
              (withSessionDetail (\detail -> detail {reviewSessionTurnId = Just turnId}) session)
          )
            { sessionPhase = ReviewRunning,
              sessionActivity = "thinking",
              sessionFollowing = followAfterTurnStarted session.sessionFollowing session.sessionDetail.reviewSessionTurnId turnId
            }
      )
    armReviewTick issueNumber
  -- A connection's stderr belongs to no thread and so to no child: the
  -- provider writes it for the whole process, and the host journals it
  -- against itself rather than routing it into whichever action happens to be
  -- running. So everything that reaches here is this child's own output.
  ReviewOutput _ outputKind delta -> do
        modifyReviewSession issueNumber
          ( \session ->
              session
                { sessionTranscript =
                    appendReviewOutput outputKind (reviewOutputPrefix outputKind <> sanitizeText delta) session.sessionTranscript,
                  sessionActivity = reviewOutputActivity outputKind
                }
          )
        tailReviewSession issueNumber
  ReviewQuestionRequested _ requestId question ->
    modifyReviewSession issueNumber
      ( \session ->
          forcedToNormalBy (numberedChoicePrompt question)
            (withPendingInteraction (Just (PendingReviewQuestion requestId question)) session)
              { sessionPhase = ReviewWaiting,
                sessionActivity = "waiting for answer"
              }
      )
  ReviewApprovalRequested _ requestId approval ->
    modifyReviewSession issueNumber
      ( \session ->
          forcedToNormalBy True
            (withPendingInteraction (Just (PendingReviewApproval requestId approval)) session)
              { sessionPhase = ReviewWaiting,
                sessionActivity = "waiting for approval"
              }
      )
  ReviewClaudeStarted _ display -> do
    let started = claudeTranscriptStart display
    modifyReviewSession issueNumber
      ( \session ->
          session
            { sessionTranscript = appendTranscript session.sessionTranscript started,
              sessionActivity = "running Claude reviewer"
            }
      )
    tailReviewSession issueNumber
  ReviewClaudeFinished _ result -> do
    modifyReviewSession issueNumber
      ( \session ->
          session
            { sessionTranscript =
                appendTranscript session.sessionTranscript ("[opus] " <> completionMessage result <> "\n"),
              sessionActivity = "processing reviewer result"
            }
      )
    tailReviewSession issueNumber
  ReviewGitHubStarted _ summary -> do
    modifyReviewSession issueNumber
      ( \session ->
          session
            { sessionTranscript =
                appendTranscript session.sessionTranscript ("\n[github] " <> sanitizeText summary <> "\n"),
              sessionActivity = "updating GitHub"
            }
      )
    tailReviewSession issueNumber
  ReviewGitHubFinished _ result -> do
    modifyReviewSession issueNumber
      ( \session ->
          session
            { sessionTranscript =
                appendTranscript session.sessionTranscript ("[github] " <> githubCompletionMessage result <> "\n"),
              sessionActivity = "processing GitHub result"
            }
      )
    tailReviewSession issueNumber
  ReviewTurnCompleted _ outcome message result -> do
    modifyReviewSession issueNumber
      ( \session ->
          let completedStage = maybe session.sessionDetail.reviewSessionStage (reviewResultStage . snd) result
              completed =
                withSessionDetail
                  ( \detail ->
                      detail
                        { reviewSessionStage = completedStage,
                          reviewSessionTurnId = Nothing,
                          reviewSessionPending = Nothing
                        }
                  )
                  session
           in completed
                { sessionPhase = outcomePhase completedStage outcome (snd <$> result),
                  sessionActivity = reviewOutcomeActivity completedStage outcome (snd <$> result),
                  sessionTranscript =
                    maybe (formatReviewTranscript session.sessionTranscript result)
                      (appendTranscript session.sessionTranscript . ("\n" <>))
                      message
                }
      )
    tailReviewSession issueNumber
    case outcome of
      TurnSucceeded -> startBoardRefresh
      _ -> pure ()
  -- Reached both when the coordinator itself rejects the turn and when
  -- 'launchIssueReview' preflights a revision against an already-running
  -- backend, so it classifies the message the same way every other terminal
  -- path does rather than calling a missing component a failed agent.
  ReviewStartFailed _ message -> do
    appendToReviewSession issueNumber
      ( \session ->
          session
            { sessionPhase = ReviewFailed,
              sessionActivity = canonicalReviewActivity message,
              sessionTranscript = appendTranscript session.sessionTranscript ("\n" <> message)
            }
      )
    setNotice (agentFailureNotice "Issue revision" message)
  -- Every thread was multiplexed onto the connection that ended, so the
  -- backend itself is finished and every live revision session with it.
  ReviewClientStopped message -> do
    modifyReviewSession issueNumber (markReviewSessionDisconnected message)
    setNotice message
    tailDisplayedTranscript
  -- One connection of several ended. Only the sessions it was serving are
  -- finished; the backend stays ready, because the threads on its other
  -- connections are still running and a new review can still be started.
  ReviewConnectionStopped _ message -> do
    modifyReviewSession issueNumber (markReviewSessionDisconnected message)
    setNotice message
    tailDisplayedTranscript
  ReviewSteerUndelivered _ _targetTurnId message -> do
    modifyReviewSession issueNumber (applyUndeliveredSteer message)
    tailReviewSession issueNumber
    setNotice undeliveredNotice
  ReviewInterruptFailed _ cause message -> do
    modifyReviewSession issueNumber (applyFailedInterrupt cause message)
    tailReviewSession issueNumber
    setNotice (interruptFailureNotice cause message)
  ReviewProtocolWarning provider message -> setNotice (reviewProtocolWarningNotice provider message)
  where
    outcomePhase = reviewOutcomePhase
    reviewOutcomeActivity completedStage TurnSucceeded (Just result)
      | completedStage == IssueRevision && null result.reviewResultBlockingReasons = "revision published"
      | result.reviewResultApproved = "approved"
      | otherwise = "changes requested"
    reviewOutcomeActivity _ TurnSucceeded Nothing = "invalid result"
    reviewOutcomeActivity _ TurnFailed _ = "failed"
    reviewOutcomeActivity _ TurnInterrupted _ = "interrupted"
    completionMessage (Right ()) = "Sonnet response returned to the coordinator."
    completionMessage (Left message) = "Sonnet failed: " <> sanitizeText message
    githubCompletionMessage (Right _) = "GitHub operation completed and returned to the coordinator."
    githubCompletionMessage (Left message) = "GitHub operation failed: " <> sanitizeText message
    formatReviewTranscript transcript Nothing = transcript
    formatReviewTranscript transcript (Just (rawResult, result)) =
      appendTranscript
        (stripTranscriptSuffix (sanitizeText rawResult) transcript)
        ("\n\n" <> renderReviewResult result)
    stripTranscriptSuffix suffix transcript =
      ChatTranscript
        { compactTranscript = fromMaybe transcript.compactTranscript (Text.stripSuffix suffix transcript.compactTranscript),
          standardTranscript = fromMaybe transcript.standardTranscript (Text.stripSuffix suffix transcript.standardTranscript),
          fullTranscript = fromMaybe transcript.fullTranscript (Text.stripSuffix suffix transcript.fullTranscript)
        }


-- | Which review sessions 'armVisibleReviewTicks' finds and re-arms:
-- eligible to animate right now but not currently ticking, e.g. because
-- their chain expired while the review overlay was hidden, or was never
-- armed for a session that only just became visible behind another tab.
reviewSessionsNeedingArm :: Bool -> Map Int ReviewSession -> [Int]
reviewSessionsNeedingArm overlayVisible =
  sessionsNeedingArm (\_ session -> reviewTickEligible overlayVisible session.sessionPhase)

-- | The review overlay's own name for the shared sweep. Reopening the
-- overlay -- on any tab, via any of the several paths that can do so --
-- must resume every still-running session's spinner, not only the one being
-- focused.
armVisibleReviewTicks :: EventM Name AppState ()
armVisibleReviewTicks = armEligibleSessionTicks reviewSessionOps

armReviewTick :: Int -> EventM Name AppState ()
armReviewTick = armSessionTick reviewSessionOps

applyReviewAnimationTick :: Int -> Int -> EventM Name AppState ()
applyReviewAnimationTick = applySessionTick reviewSessionOps

-- | The line the review transcript opens a @kanban_run_claude@ run with.
--
-- The @[sonnet]@ channel tag is unversioned and stays (docs\/design.md §7,
-- requirement 2); only the model-and-effort portion comes from the roster,
-- and it is @issue_revise.claude@ -- the very cell the tool this line
-- announces has already resolved in order to spawn.
--
-- The display is the event's own, resolved by
-- 'Kanban.Review.claudeStartedEvent' from the client actually running the
-- call, and nothing here consults application state. That is what makes the
-- line right whatever has happened to the backend in between: the tool runs
-- in a fork, so a stop or a restart can be applied before this event, and
-- resolving at this point would name a replacement client's assignment -- or
-- none at all -- for a call running on the roster the emitting client
-- captured.
claudeTranscriptStart :: Text -> Text
claudeTranscriptStart display =
  "\n[sonnet] Starting authenticated " <> display <> "…\n"

-- | What an ended provider connection does to the one session it was serving.
--
-- Applied per child now rather than swept across the whole map: the host
-- delivers a client-stopped or connection-stopped event only into the
-- children that connection was actually serving, so deciding here which
-- sessions it reaches would be answering a question that has already been
-- answered correctly with less information.
--
-- A session that already settled is left alone. 'ReviewInterrupted' is not
-- one of those, unlike every other settled phase: an interrupted revision is
-- resumable only while there is something to resume it on, and once the
-- connection carrying its thread is gone it is exactly as finished as a
-- failed one — leaving it resumable would leave its input line offering a
-- send that can only reach a dead process, and 'reviewSessionReusable'
-- reopening it forever.
markReviewSessionDisconnected :: Text -> ReviewSession -> ReviewSession
markReviewSessionDisconnected message session
  | session.sessionDetail.reviewSessionStage == IssueRevision,
    session.sessionPhase `elem` [ReviewStarting, ReviewRunning, ReviewWaiting, ReviewInterrupted] =
      session
        { sessionPhase = ReviewFailed,
          sessionActivity = "disconnected",
          sessionTranscript = appendTranscript session.sessionTranscript ("\n" <> message)
        }
  | otherwise = session

-- | The transcript entry one applied command leaves, and where a refused one
-- puts the message back.
--
-- Journaled by the host rather than appended optimistically at the press, so
-- a dashboard that reattaches an hour later writes exactly the same line in
-- exactly the same place as the one that typed it (requirement 4). A refusal
-- carries its reason and hands the text back through the same
-- undelivered-steer path a rejected steer takes, so nothing the user typed is
-- lost and nothing they never sent is shown as sent (issue #17).
applyReviewInput :: Int -> Text -> Maybe Text -> EventM Name AppState ()
applyReviewInput issueNumber display rejected = do
  appendToReviewSession issueNumber apply
  tailReviewSession issueNumber
  case rejected of
    Nothing -> armReviewTick issueNumber
    Just reason -> setNotice ("Not delivered: " <> sanitizeText reason)
  where
    apply session = case rejected of
      Nothing ->
        (clearPendingInteraction session)
          { sessionPhase = ReviewRunning,
            sessionActivity = "thinking",
            sessionTranscript = appendTranscript session.sessionTranscript ("\nYou: " <> display <> "\n")
          }
      Just reason ->
        holdUndelivered
          (reviewSessionInputLive session.sessionDetail.reviewSessionStage session.sessionPhase)
          display
          session
            { sessionTranscript =
                appendTranscript session.sessionTranscript ("\n[not delivered] " <> sanitizeText reason <> "\n")
            }

-- | A diagnostic the host recorded against this action.
applyReviewDiagnostic :: Int -> Text -> EventM Name AppState ()
applyReviewDiagnostic issueNumber message = do
  appendToReviewSession issueNumber
    ( \session ->
        session {sessionTranscript = appendTranscript session.sessionTranscript ("\n" <> sanitizeText message <> "\n")}
    )
  tailReviewSession issueNumber

-- | Subprocesses that outlived a settled issue action, reported the way a
-- solve worker's are: the session says what survived and which key ends it.
applyIssueActionOrphans :: Int -> SolveOutcome -> [ProcessIdentity] -> EventM Name AppState ()
applyIssueActionOrphans issueNumber outcome processes = do
  let notice = orphanMessage outcome (showText (length processes)) "the issue review"
  appendToReviewSession issueNumber
    ( \session ->
        session
          { sessionPhase = ReviewFailed,
            sessionActivity = notice,
            sessionTranscript = appendTranscript session.sessionTranscript ("\n" <> notice <> "\n")
          }
    )
  setNotice notice

-- | The child's terminal envelope.
--
-- Confirming rather than deciding: the event that /produced/ the outcome —
-- the canonical result, the completed turn, the start failure — has already
-- moved the session to the phase it belongs in, and that phase carries the
-- verdict this one does not have. So a session that has already settled is
-- left exactly as it is, and only one still showing an active phase is
-- brought to a terminal one, which is the case where the action ended for a
-- reason its own events never reported: a deadline, a kill, a host that died.
applyIssueActionFinished :: Int -> SolveOutcome -> EventM Name AppState ()
applyIssueActionFinished issueNumber outcome = do
  state <- get
  case Map.lookup issueNumber state.appReviewSessions of
    Just session | not (reviewPhaseActive session.sessionPhase) -> pure ()
    _ -> do
      appendToReviewSession issueNumber
        ( \session ->
            session
              { sessionPhase = ReviewFailed,
                sessionActivity = canonicalReviewActivity detail,
                sessionTranscript = appendTranscript session.sessionTranscript ("\n" <> sanitizeText detail <> "\n")
              }
        )
      setNotice (agentFailureNotice "Issue review" detail)
  where
    detail = case outcome of
      SolveCompleted -> "the issue action ended without publishing a result"
      SolveNeedsInput message -> message
      SolveFailed message -> message
