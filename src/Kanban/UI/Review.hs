module Kanban.UI.Review
  ( ReviewCancelAction (..),
    ReviewDigitAction (..),
    applyCanonicalIssueReview,
    applyReviewAnimationTick,
    applyReviewBackendStarted,
    applyReviewEvent,
    applyUndeliveredSteer,
    approvalServiceRefusal,
    armReviewTick,
    armVisibleReviewTicks,
    cancelReviewSession,
    canonicalLaunchOutcome,
    canonicalReviewActivity,
    claudeTranscriptStart,
    canonicalReviewCompletionSuperseded,
    canonicalReviewNotice,
    deferredRevisionLaunches,
    chooseReviewOption,
    epicReviewRefusalNotice,
    forcedToNormalBy,
    numberedChoicePrompt,
    resolveReviewCancelAction,
    reviewDigitActionFor,
    resolveReviewDigitAction,
    reviewSessionsNeedingArm,
    startItemReview,
    startSelectedReview,
    submitReviewInput,
  )
where


import Brick
import Brick.BChan (writeBChan)
import Control.Concurrent (forkIO)
import Control.Monad (unless, void )
import Control.Monad.IO.Class (liftIO)
import Data.List (partition)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.ApprovalService
  ( ApprovalController,
    ApprovalUnavailable,
    approvalContentionNotice,
    approvalOwnsCanonicalReview,
    liveApprovalContention,
  )
import Kanban.CLI (Options (..))
import Kanban.Config (ResolvedConfig (..) )
import Kanban.Domain
import Kanban.Drainer (normalizedRepositoryIdentity)
import Kanban.Models (ProviderName (..), RoleName (..), assignmentFor)
import Kanban.Preflight
  ( PreflightAction (..),
    issueOriginFromBody,
    preflightDiagnosticDetail,
    reviewBackendAction
  )
import Kanban.Process (ManagedProcess, interruptThenKillManagedProcess )
import Kanban.Review
  ( CanonicalIssueReviewResult (..),
    ReviewAnswer (..),
    ReviewChoice (..),
    ReviewClient,
    ReviewEvent (..),
    ReviewOutputKind (..),
    ReviewQuestion (..),
    ReviewQuestionKind (..),
    ReviewRequestId,
    ReviewResult (..),
    ReviewStage (..),
    ReviewTurnOutcome (..),
    answerReviewQuestion,
    approveReviewAction,
    beginIssueReview,
    interruptReview,
    killReviewTools,
    outcomeUnknownDiagnostic,
    reviewStageForLabels,
    renderCanonicalIssueReviewResult,
    runCanonicalIssueReview,
    renderReviewResult,
    sendReviewMessage,
    startReviewClient
    )
import Kanban.Settings
  ( ChatVerbosity (..)
    )
import Kanban.Text (sanitizeText)
import Kanban.UI.Filter (readOnlyHistoryRefusal)
import Kanban.UI.Keys (BoardAction (..), actionKeyText)
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.SessionCore
import Kanban.UI.State
import Kanban.UI.Transcript
import Kanban.UI.Session
import Kanban.UI.SessionEvents
import Kanban.UI.Refresh
import Kanban.UI.Solve
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

submitQuestionAnswer :: Int -> ReviewRequestId -> ReviewAnswer -> Text -> EventM Name AppState ()
submitQuestionAnswer issueNumber requestId answer displayAnswer = do
  state <- get
  case state.appReviewBackend of
    ReviewBackendReady client -> do
      result <- liftIO (answerReviewQuestion client requestId answer)
      case result of
        Left message -> setNotice message
        Right () ->
          appendToReviewSession issueNumber
            ( \session ->
                (clearPendingInteraction session)
                  { sessionPhase = ReviewRunning,
                    sessionActivity = "thinking",
                    sessionInput = "",
                    sessionTranscript = appendTranscript session.sessionTranscript ("\nYou: " <> displayAnswer <> "\n")
                  }
            )
          >> armReviewTick issueNumber
    _ -> setNotice "Codex app-server is not connected"

submitApprovalAnswer :: Int -> ReviewRequestId -> Bool -> Bool -> Text -> EventM Name AppState ()
submitApprovalAnswer issueNumber requestId accepted forSession displayAnswer = do
  state <- get
  case state.appReviewBackend of
    ReviewBackendReady client -> do
      result <- liftIO (approveReviewAction client requestId accepted forSession)
      case result of
        Left message -> setNotice message
        Right () ->
          appendToReviewSession issueNumber
            ( \session ->
                (clearPendingInteraction session)
                  { sessionPhase = ReviewRunning,
                    sessionActivity = "thinking",
                    sessionTranscript = appendTranscript session.sessionTranscript ("\n" <> displayAnswer <> "\n")
                  }
            )
          >> armReviewTick issueNumber
    _ -> setNotice "Codex app-server is not connected"

sendReviewFeedback :: Int -> ReviewSession -> EventM Name AppState ()
sendReviewFeedback issueNumber session = do
  state <- get
  case (state.appReviewBackend, session.sessionDetail.reviewSessionThreadId) of
    (ReviewBackendReady client, Just threadId) -> do
      let message = Text.strip session.sessionInput
      result <- liftIO (sendReviewMessage client threadId session.sessionDetail.reviewSessionTurnId message)
      case result of
        Left errorMessage -> setNotice errorMessage
        Right () ->
          appendToReviewSession issueNumber
            ( \current ->
                let (restored, stillUndelivered) = takeNextUndelivered current.sessionDetail.reviewSessionUndelivered
                 in (withUndelivered stillUndelivered current)
                      { sessionInput = restored,
                        sessionPhase = ReviewRunning,
                        sessionActivity = "thinking",
                        sessionTranscript = appendTranscript current.sessionTranscript ("\nYou: " <> message <> "\n")
                      }
            )
    _ -> setNotice "The review session has not connected yet"

-- | What the input line becomes once the message on it has been sent: empty
-- as before, unless a previously rejected steer is still waiting, in which
-- case the oldest one comes back for a deliberate resend. Sending is the only
-- moment the line is known to be free, so it is where the queue drains
-- without ever overwriting something the user typed (issue #17).
takeNextUndelivered :: [Text] -> (Text, [Text])
takeNextUndelivered [] = ("", [])
takeNextUndelivered (next : remaining) = (next, remaining)

-- | Folds a rejected steer back into its session. The message goes onto the
-- input line only when the line is free — otherwise it queues behind whatever
-- is already waiting, so neither a draft typed after the original send nor an
-- earlier rejection is overwritten or truncated. The transcript is annotated
-- either way, since 'sendReviewFeedback' already wrote an optimistic @You:@
-- entry that would otherwise claim the message was delivered (issue #17).
applyUndeliveredSteer :: Text -> ReviewSession -> ReviewSession
applyUndeliveredSteer message session =
  (withUndelivered stillUndelivered session)
    { sessionInput = nextInput,
      sessionTranscript =
        appendTranscript session.sessionTranscript ("\n" <> undeliveredTranscriptNote message <> "\n")
    }
  where
    queued = session.sessionDetail.reviewSessionUndelivered <> [message]
    (nextInput, stillUndelivered)
      | Text.null (Text.strip session.sessionInput) = takeNextUndelivered queued
      | otherwise = (session.sessionInput, queued)

clearPendingInteraction :: ReviewSession -> ReviewSession
clearPendingInteraction = withPendingInteraction Nothing

withPendingInteraction :: Maybe PendingReviewInteraction -> ReviewSession -> ReviewSession
withPendingInteraction pending = withSessionDetail (\detail -> detail {reviewSessionPending = pending})

withUndelivered :: [Text] -> ReviewSession -> ReviewSession
withUndelivered undelivered = withSessionDetail (\detail -> detail {reviewSessionUndelivered = undelivered})

undeliveredTranscriptNote :: Text -> Text
undeliveredTranscriptNote message = "[not delivered] " <> message

undeliveredNotice :: Text
undeliveredNotice = "Your message was not delivered — it is waiting in the review session to resend"

-- | What Ctrl-C/Ctrl-X in a review overlay should do, decided from the
-- session's connection/process state rather than inline in
-- 'cancelReviewSession' so the routing between the app-server interrupt
-- path (the only resumable turn) and a canonical stage's process
-- interrupt/kill escalation is unit-testable without an 'EventM' harness.
data ReviewCancelAction
  = ReviewCancelInterruptTurn Text Text
  | ReviewCancelInterruptProcess
  | ReviewCancelStillStarting
  | ReviewCancelNotRunning
  | ReviewCancelNoActiveTurn
  deriving stock (Eq, Show)

resolveReviewCancelAction :: Bool -> Maybe Text -> Maybe Text -> ReviewStage -> ReviewPhase -> Bool -> ReviewCancelAction
resolveReviewCancelAction backendReady threadId turnId stage phase hasCanonicalProcess
  | backendReady, Just thread <- threadId, Just turn <- turnId = ReviewCancelInterruptTurn thread turn
  | hasCanonicalProcess = ReviewCancelInterruptProcess
  | stage /= IssueRevision, phase == ReviewStarting = ReviewCancelStillStarting
  | stage /= IssueRevision = ReviewCancelNotRunning
  | otherwise = ReviewCancelNoActiveTurn

cancelReviewSession :: Int -> EventM Name AppState ()
cancelReviewSession issueNumber = do
  state <- get
  case Map.lookup issueNumber state.appReviewSessions of
    Nothing -> setNotice "Review session is no longer available"
    Just session -> do
      let backendReady = case state.appReviewBackend of
            ReviewBackendReady _ -> True
            _ -> False
          hasCanonicalProcess = Map.member issueNumber state.appCanonicalReviewProcesses
      case resolveReviewCancelAction backendReady session.sessionDetail.reviewSessionThreadId session.sessionDetail.reviewSessionTurnId session.sessionDetail.reviewSessionStage session.sessionPhase hasCanonicalProcess of
        ReviewCancelInterruptTurn threadId turnId -> case state.appReviewBackend of
          ReviewBackendReady client -> do
            void . liftIO . forkIO $ killReviewTools client threadId
            result <- liftIO (interruptReview client threadId turnId)
            case result of
              Left message -> setNotice message
              Right () -> setNotice ("Interrupting review #" <> showText issueNumber <> "; type guidance when the turn stops")
          _ -> setNotice "This review has no active turn to cancel"
        ReviewCancelInterruptProcess -> cancelCanonicalReviewProcess issueNumber (Map.lookup issueNumber state.appCanonicalReviewProcesses)
        ReviewCancelStillStarting -> setNotice ("Issue review #" <> showText issueNumber <> " is still starting; try Ctrl-C again once it is running")
        ReviewCancelNotRunning -> setNotice ("Issue review #" <> showText issueNumber <> " is not running")
        ReviewCancelNoActiveTurn -> setNotice "This review has no active turn to cancel"

-- | Interrupts a canonical review stage's live subprocess. Canonical stages
-- are not resumable turns, so unlike the app-server path this lands the
-- session in the 'ReviewInterrupted' terminal phase immediately (preserving
-- the transcript) rather than waiting on a protocol event, and the notice
-- says a fresh stage restarts rather than promising "type guidance".
-- 'appCanonicalReviewProcesses' keeps its entry until
-- 'applyCanonicalIssueReview' observes the process's actual completion, so
-- quit protection and same-stage retry both stay accurate while the kill is
-- still in flight.
cancelCanonicalReviewProcess :: Int -> Maybe ManagedProcess -> EventM Name AppState ()
cancelCanonicalReviewProcess issueNumber Nothing = setNotice ("Issue review #" <> showText issueNumber <> " is not running")
cancelCanonicalReviewProcess issueNumber (Just process) = do
  appendToReviewSession issueNumber
    ( \session ->
        session
          { sessionPhase = ReviewInterrupted,
            sessionActivity = "interrupted",
            sessionTranscript = appendTranscript session.sessionTranscript "\n[interrupted by user]\n"
          }
    )
  void . liftIO . forkIO $ interruptThenKillManagedProcess process
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

reviewOutputPrefix :: ReviewOutputKind -> Text
reviewOutputPrefix AgentOutput = ""
reviewOutputPrefix ReasoningOutput = ""
reviewOutputPrefix CommandOutput = ""
reviewOutputPrefix DiagnosticOutput = "[codex] "

reviewOutputActivity :: ReviewOutputKind -> Text
reviewOutputActivity AgentOutput = "responding"
reviewOutputActivity ReasoningOutput = "thinking"
reviewOutputActivity CommandOutput = "running command"
reviewOutputActivity DiagnosticOutput = "diagnostic output"

showReviewOutput :: ChatVerbosity -> ReviewOutputKind -> Bool
showReviewOutput CompactChat AgentOutput = True
showReviewOutput CompactChat _ = False
showReviewOutput StandardChat DiagnosticOutput = False
showReviewOutput StandardChat _ = True
showReviewOutput FullChat _ = True

whenReviewOverlayOpen :: (Int -> EventM Name AppState ()) -> EventM Name AppState ()
whenReviewOverlayOpen action = do
  state <- get
  case state.appOverlay of
    Just (ReviewOverlay issueNumber) -> action issueNumber
    _ -> pure ()

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

startIssueReview :: Issue -> EventM Name AppState ()
startIssueReview issue = do
  state <- get
  let requestedStage = issueReviewStage state.appConfig.resolvedWorkflow issue
  case Map.lookup issue.issueNumber state.appReviewSessions of
    Just session
      | reviewSessionReusable session.sessionPhase session.sessionDetail.reviewSessionStage requestedStage (Map.member issue.issueNumber state.appCanonicalReviewProcesses) -> do
          modify (\current -> current {appOverlay = Just (ReviewOverlay issue.issueNumber), appNotice = Nothing})
          presentTranscriptTail
          armVisibleReviewTicks
    -- The service interlock is asked before a session is created, so a press
    -- made while the approval service owns a canonical review reports the wait
    -- rather than opening a session that could only fail. It is asked again at
    -- the spawn boundary below, because the service can take the backend's
    -- approval lock between the press and the launch.
    _ | Just notice <- approvalServiceRefusal state requestedStage -> setNotice notice
    _ -> do
      let priorGeneration = priorTickGeneration issue.issueNumber state.appReviewSessions
          session = newReviewSession issue requestedStage priorGeneration
      modify
        ( \current ->
            current
              { appReviewSessions = Map.insert issue.issueNumber session current.appReviewSessions,
                appOverlay = Just (ReviewOverlay issue.issueNumber),
                appNotice = Nothing
              }
        )
      presentTranscriptTail
      if requestedStage == IssueRevision
        then do
          updated <- get
          case updated.appReviewBackend of
            ReviewBackendReady client -> launchIssueReview client issue
            ReviewBackendStarting -> pure ()
            ReviewBackendStopped -> startReviewBackend
            ReviewBackendFailed _ -> startReviewBackend
        else launchCanonicalIssueReview issue requestedStage

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
        reviewSessionUndelivered = []
      }

-- | The canonical review's spawn boundary. The refusal is re-asked here as
-- well as at the press that reached it, for the reason every other launch
-- re-asks: what a session was created for can settle before the process it
-- needs is started.
launchCanonicalIssueReview :: Issue -> ReviewStage -> EventM Name AppState ()
launchCanonicalIssueReview issue stage = do
  state <- get
  case readOnlyHistoryRefusal state (IssueItem issue) of
    Just notice -> refuseStartedReview issue.issueNumber notice
    Nothing -> case approvalServiceRefusal state stage of
      Just notice -> refuseStartedReview issue.issueNumber notice
      Nothing -> launchLiveCanonicalIssueReview issue stage

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

-- | One canonical launch's sequence: the preflight, then the approval-service
-- interlock, then the spawn.
--
-- The interlock sits /between/ the two rather than ahead of both. The preflight
-- runs several probes — executables, authentication, installed bundles — and
-- the service can take the backend's approval lock while they do, so a check
-- taken before it can be stale by the time the spawn happens. This position is
-- the last instant before a competing canonical child would be started, which
-- is the only place a reading of live state cannot go stale before the thing it
-- guards.
--
-- It is asked of the controller rather than of the board's newest observation,
-- because that observation is up to a whole poll interval old.
--
-- Both dependencies are parameters so that window is exercisable: a test
-- supplies a preflight that changes what the controller reports and establishes
-- that the spawn never ran.
canonicalLaunchOutcome ::
  ReviewStage ->
  Text ->
  Either ApprovalUnavailable ApprovalController ->
  IO (Maybe Text) ->
  IO (Either Text result) ->
  IO (Either Text result)
canonicalLaunchOutcome stage identity controller preflight spawn = do
  blocked <- preflight
  case blocked of
    Just message -> pure (Left message)
    Nothing -> do
      -- A revision performs no canonical backend review, so it contends for
      -- nothing and is never asked about.
      contended <-
        if stage == IssueRevision
          then pure Nothing
          else liveApprovalContention identity controller
      case contended of
        Just notice -> pure (Left notice)
        Nothing -> spawn

-- | The asynchronous launch itself.
--
-- A service refusal is reported the way a preflight blocker is — as this
-- invocation's own failed result — so the session settles with the reason on it
-- rather than waiting on a process that was never started.
launchLiveCanonicalIssueReview :: Issue -> ReviewStage -> EventM Name AppState ()
launchLiveCanonicalIssueReview issue stage = do
  state <- get
  let channel = state.appEventChannel
      issueNumber = issue.issueNumber
      identity = normalizedRepositoryIdentity state.appRepository
  void . liftIO . forkIO $ do
    result <-
      canonicalLaunchOutcome
        stage
        identity
        state.appApprovalController
        (preflightBlocker state.appRepository (ActionIssueReview (issueOriginFromBody issue.issueBody)))
        (runCanonicalIssueReview state.appOptions.optionConfig state.appRepository issueNumber stage (writeBChan channel . CanonicalIssueReviewProcessStarted issueNumber))
    writeBChan channel (CanonicalIssueReviewFinished issueNumber stage result)

-- | Whether a just-arrived 'CanonicalIssueReviewFinished' must be discarded
-- rather than applied: the session was already moved to 'ReviewInterrupted'
-- by a user Ctrl-C, so a late completion from that now-dead invocation must
-- not clobber the terminal state and its restart-oriented notice with the
-- generic failure/result transition below.
canonicalReviewCompletionSuperseded :: ReviewPhase -> Bool
canonicalReviewCompletionSuperseded phase = phase == ReviewInterrupted

applyCanonicalIssueReview :: Int -> ReviewStage -> Either Text CanonicalIssueReviewResult -> EventM Name AppState ()
applyCanonicalIssueReview issueNumber stage result = do
  modify (\current -> current {appCanonicalReviewProcesses = Map.delete issueNumber current.appCanonicalReviewProcesses})
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

-- | One coordinator serves every revision session, so it preflights only
-- its own origin-independent dependencies. A per-issue dependency checked
-- here would be reported against sessions queued behind the one that
-- started it: 'applyReviewBackendStarted' fails every 'ReviewStarting'
-- revision on a backend failure, which is right for a shared cause and
-- wrong for an issue-specific one. Each queued session gets its own
-- preflight from 'launchIssueReview' once the coordinator is up.
--
-- The roster is unwrapped here, before any process is started, exactly as it
-- is at the solve and pull-request boundaries: only @issue_review.codex@ is
-- consulted, because the Claude embedded-review backend is MODEL-13's and
-- @kanban_run_claude@ refuses on its own cell at its own boundary. A refusal
-- travels the backend's existing failure surface, which already fails every
-- session waiting on it.
startReviewBackend :: EventM Name AppState ()
startReviewBackend = do
  state <- get
  modify (\current -> current {appReviewBackend = ReviewBackendStarting})
  let eventChannel = state.appEventChannel
      eventSink = writeBChan eventChannel . ReviewProtocolEvent
  case resolvedRosterCellFor (\roster -> assignmentFor roster IssueReviewRole CodexProvider) state.appModelRoster of
    Left message -> liftIO (writeBChan eventChannel (ReviewBackendStarted (Left message)))
    Right (roster, _) ->
      void
        . liftIO
        . forkIO
        $ do
          blocked <- preflightBlocker state.appRepository reviewBackendAction
          case blocked of
            Just message -> writeBChan eventChannel (ReviewBackendStarted (Left message))
            Nothing -> startReviewClient roster state.appConfig.resolvedWorkflow state.appRepository eventSink >>= writeBChan eventChannel . ReviewBackendStarted

-- | Preflighted here too, not only in 'startReviewBackend': a backend
-- already running for an earlier issue is reused as-is, so this is the only
-- door a Claude-origin revision passes through when the coordinator was
-- started for a Codex-origin one.
-- | The deferred spawn boundary. A revision session is created while the
-- backend is still starting, so this runs an arbitrary time after the press
-- that asked for it — long enough for a refresh to have settled the issue
-- underneath it, which is exactly why the refusal is asked again here.
launchIssueReview :: ReviewClient -> Issue -> EventM Name AppState ()
launchIssueReview client issue = do
  state <- get
  case readOnlyHistoryRefusal state (IssueItem issue) of
    Just notice -> refuseStartedReview issue.issueNumber notice
    Nothing -> launchLiveIssueReview client issue

launchLiveIssueReview :: ReviewClient -> Issue -> EventM Name AppState ()
launchLiveIssueReview client issue = do
  state <- get
  let eventChannel = state.appEventChannel
      issueNumber = issue.issueNumber
  void
    . liftIO
    . forkIO
    $ do
      blocked <- preflightBlocker state.appRepository (issueRevisionPreflightAction issue)
      result <- case blocked of
        Just message -> pure (Left message)
        Nothing -> beginIssueReview client issueNumber
      case result of
        Left message -> writeBChan eventChannel (ReviewProtocolEvent (ReviewStartFailed issueNumber message))
        Right () -> pure ()

issueRevisionPreflightAction :: Issue -> PreflightAction
issueRevisionPreflightAction issue = ActionIssueRevision (issueOriginFromBody issue.issueBody)

-- | What a just-ready review backend owes the revision sessions waiting on
-- it: the ones whose turn it must start, and the ones it must refuse instead.
--
-- Both halves have to be acted on. A session created while the backend was
-- starting has been sitting in 'ReviewStarting' ever since, so one whose issue
-- settled in the meantime cannot simply be skipped — it would wait for a turn
-- that must never be started. Total, and a pure function of the state, so the
-- deferred boundary is decided in one place rather than inside the arm that
-- reaches it.
deferredRevisionLaunches :: AppState -> ([Issue], [(Int, Text)])
deferredRevisionLaunches state = (map fst live, map refusal settled)
  where
    waiting =
      [ (session.sessionDetail.reviewSessionIssue, readOnlyHistoryRefusal state (IssueItem session.sessionDetail.reviewSessionIssue))
        | session <- Map.elems state.appReviewSessions,
          session.sessionDetail.reviewSessionStage == IssueRevision,
          session.sessionPhase == ReviewStarting,
          session.sessionDetail.reviewSessionThreadId == Nothing
      ]
    (settled, live) = partition (isJust . snd) waiting
    refusal (issue, notice) = (issue.issueNumber, fromMaybe "" notice)

-- | A review session a launch boundary turned away. It never started, so it
-- leaves 'ReviewStarting' rather than waiting for a turn that will not come,
-- and the refusal is what its activity, transcript and the notice all say.
refuseStartedReview :: Int -> Text -> EventM Name AppState ()
refuseStartedReview issueNumber notice = do
  appendToReviewSession issueNumber
    ( \session ->
        session
          { sessionPhase = ReviewFailed,
            sessionActivity = "read-only history",
            sessionTranscript = appendTranscript session.sessionTranscript ("\n" <> notice <> "\n")
          }
    )
  setNotice notice

applyReviewBackendStarted :: Either Text ReviewClient -> EventM Name AppState ()
applyReviewBackendStarted result = case result of
  Left message -> do
    modify
      ( \state ->
          state
            { appReviewBackend = ReviewBackendFailed message,
              appReviewSessions = Map.map (failStartingSession message) state.appReviewSessions,
              appNotice = Just (agentFailureNotice "Issue revision" message)
            }
      )
    tailDisplayedTranscript
  Right client -> do
    modify (\state -> state {appReviewBackend = ReviewBackendReady client})
    started <- get
    let (live, settled) = deferredRevisionLaunches started
    mapM_ (uncurry refuseStartedReview) settled
    mapM_ (launchIssueReview client) live
  where
    failStartingSession message session
      | session.sessionDetail.reviewSessionStage == IssueRevision && session.sessionPhase == ReviewStarting =
          session
            { sessionPhase = ReviewFailed,
              sessionActivity = canonicalReviewActivity message,
              sessionTranscript = appendTranscript session.sessionTranscript ("\n" <> message)
            }
      | otherwise = session

applyReviewEvent :: ReviewEvent -> EventM Name AppState ()
applyReviewEvent reviewEvent = case reviewEvent of
  ReviewThreadCreated issueNumber threadId ->
    appendToReviewSession issueNumber
      ( \session ->
          (withSessionDetail (\detail -> detail {reviewSessionThreadId = Just threadId}) session)
            { sessionActivity = "session ready",
              sessionTranscript = appendTranscript session.sessionTranscript "Codex session created.\n"
            }
      )
  ReviewTurnStarted threadId turnId -> do
    modifyReviewSessionByThread threadId
      ( \session ->
          ( clearPendingInteraction
              (withSessionDetail (\detail -> detail {reviewSessionTurnId = Just turnId}) session)
          )
            { sessionPhase = ReviewRunning,
              sessionActivity = "thinking",
              sessionFollowing = followAfterTurnStarted session.sessionFollowing session.sessionDetail.reviewSessionTurnId turnId
            }
      )
    state <- get
    case findReviewSessionByThread threadId state of
      Just (issueNumber, _) -> armReviewTick issueNumber
      Nothing -> pure ()
  ReviewOutput threadId outputKind delta
    | Text.null threadId ->
        whenReviewOverlayOpen (\_ -> setNotice (reviewOutputPrefix outputKind <> sanitizeText delta))
    | otherwise -> do
        modifyReviewSessionByThread threadId
          ( \session ->
              session
                { sessionTranscript =
                    appendReviewOutput outputKind (reviewOutputPrefix outputKind <> sanitizeText delta) session.sessionTranscript,
                  sessionActivity = reviewOutputActivity outputKind
                }
          )
        tailReviewThread threadId
  ReviewQuestionRequested threadId requestId question ->
    modifyReviewSessionByThread threadId
      ( \session ->
          forcedToNormalBy (numberedChoicePrompt question)
            (withPendingInteraction (Just (PendingReviewQuestion requestId question)) session)
              { sessionPhase = ReviewWaiting,
                sessionActivity = "waiting for answer"
              }
      )
  ReviewApprovalRequested threadId requestId approval ->
    modifyReviewSessionByThread threadId
      ( \session ->
          forcedToNormalBy True
            (withPendingInteraction (Just (PendingReviewApproval requestId approval)) session)
              { sessionPhase = ReviewWaiting,
                sessionActivity = "waiting for approval"
              }
      )
  ReviewClaudeStarted threadId display -> do
    let started = claudeTranscriptStart display
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { sessionTranscript = appendTranscript session.sessionTranscript started,
              sessionActivity = "running Claude reviewer"
            }
      )
    tailReviewThread threadId
  ReviewClaudeFinished threadId result -> do
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { sessionTranscript =
                appendTranscript session.sessionTranscript ("[opus] " <> completionMessage result <> "\n"),
              sessionActivity = "processing reviewer result"
            }
      )
    tailReviewThread threadId
  ReviewGitHubStarted threadId summary -> do
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { sessionTranscript =
                appendTranscript session.sessionTranscript ("\n[github] " <> sanitizeText summary <> "\n"),
              sessionActivity = "updating GitHub"
            }
      )
    tailReviewThread threadId
  ReviewGitHubFinished threadId result -> do
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { sessionTranscript =
                appendTranscript session.sessionTranscript ("[github] " <> githubCompletionMessage result <> "\n"),
              sessionActivity = "processing GitHub result"
            }
      )
    tailReviewThread threadId
  ReviewTurnCompleted threadId outcome message result -> do
    modifyReviewSessionByThread threadId
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
    tailReviewThread threadId
    case outcome of
      TurnSucceeded -> startBoardRefresh
      _ -> pure ()
  -- Reached both when the coordinator itself rejects the turn and when
  -- 'launchIssueReview' preflights a revision against an already-running
  -- backend, so it classifies the message the same way every other terminal
  -- path does rather than calling a missing component a failed agent.
  ReviewStartFailed issueNumber message -> do
    appendToReviewSession issueNumber
      ( \session ->
          session
            { sessionPhase = ReviewFailed,
              sessionActivity = canonicalReviewActivity message,
              sessionTranscript = appendTranscript session.sessionTranscript ("\n" <> message)
            }
      )
    setNotice (agentFailureNotice "Issue revision" message)
  ReviewClientStopped message -> do
    modify
      ( \state ->
          state
            { appReviewBackend = ReviewBackendFailed message,
              appReviewSessions = Map.map (markDisconnected message) state.appReviewSessions,
              appNotice = Just message
            }
      )
    tailDisplayedTranscript
  ReviewSteerUndelivered threadId _targetTurnId message -> do
    modifyReviewSessionByThread threadId (applyUndeliveredSteer message)
    tailReviewThread threadId
    setNotice undeliveredNotice
  ReviewProtocolWarning message -> setNotice ("Codex protocol warning: " <> message)
  where
    outcomePhase IssueRevision TurnSucceeded (Just result)
      | null result.reviewResultBlockingReasons = ReviewFinished
      | otherwise = ReviewNeedsChanges
    outcomePhase _ TurnSucceeded (Just result)
      | result.reviewResultApproved = ReviewFinished
      | otherwise = ReviewNeedsChanges
    outcomePhase _ TurnSucceeded Nothing = ReviewFailed
    outcomePhase _ TurnFailed _ = ReviewFailed
    outcomePhase _ TurnInterrupted _ = ReviewInterrupted
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
    markDisconnected message session
      | session.sessionDetail.reviewSessionStage == IssueRevision && session.sessionPhase `elem` [ReviewStarting, ReviewRunning, ReviewWaiting] =
          session
            { sessionPhase = ReviewFailed,
              sessionActivity = "disconnected",
              sessionTranscript = appendTranscript session.sessionTranscript ("\n" <> message)
            }
      | otherwise = session

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
