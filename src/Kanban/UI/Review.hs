module Kanban.UI.Review
  ( ReviewCancelAction (..),
    ReviewDigitAction (..),
    ReviewTickArmOutcome (..),
    ReviewTickFireOutcome (..),
    appendReviewInput,
    applyCanonicalIssueReview,
    applyReviewAnimationTick,
    applyReviewBackendStarted,
    applyReviewEvent,
    applyUndeliveredSteer,
    armReviewTick,
    armVisibleReviewTicks,
    cancelReviewSession,
    canonicalReviewActivity,
    canonicalReviewCompletionSuperseded,
    canonicalReviewNotice,
    chooseReviewOption,
    cycleReviewSession,
    decideReviewTickArm,
    decideReviewTickFire,
    removeReviewInputCharacter,
    resolveReviewCancelAction,
    resolveReviewDigitAction,
    reviewSessionsNeedingArm,
    startItemReview,
    startSelectedReview,
    submitReviewInput,
  )
where


import Brick
import Brick.BChan (writeBChan)
import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (unless, void )
import Control.Monad.IO.Class (liftIO)
import Data.List (findIndex, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.CLI (Options (..))
import Kanban.Config (ResolvedConfig (..) )
import Kanban.Domain
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
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.State
import Kanban.UI.Transcript
import Kanban.UI.Session
import Kanban.UI.Refresh
import Kanban.UI.Solve
import Kanban.UI.PullRequest

-- | What a digit key '1'..'9' should do given the pending review
-- interaction (if any) and the 0-based choice index it encodes. Pulled out
-- of 'chooseReviewOption' so the dispatch rules are unit-testable without an
-- 'EventM' harness.
data ReviewDigitAction
  = ReviewDigitAppend
  | ReviewDigitSelectChoice ReviewRequestId ReviewChoice
  | ReviewDigitApprovalOnce ReviewRequestId
  | ReviewDigitApprovalSession ReviewRequestId
  | ReviewDigitApprovalDecline ReviewRequestId
  | ReviewDigitUnavailable Text
  deriving stock (Eq, Show)

resolveReviewDigitAction :: Maybe PendingReviewInteraction -> Int -> ReviewDigitAction
resolveReviewDigitAction pending choiceIndex = case pending of
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

chooseReviewOption :: Int -> Int -> EventM Name AppState ()
chooseReviewOption issueNumber choiceIndex = do
  state <- get
  let pending = Map.lookup issueNumber state.appReviewSessions >>= (.reviewSessionPending)
  case resolveReviewDigitAction pending choiceIndex of
    ReviewDigitAppend -> modifyReviewSession issueNumber (appendReviewInput (toEnum (fromEnum '1' + choiceIndex)))
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
      | Text.null (Text.strip session.reviewSessionInput) -> setNotice "Type a message or select one of the numbered choices"
      | otherwise -> case session.reviewSessionPending of
          Just (PendingReviewQuestion requestId question)
            | question.reviewQuestionKind == QuestionText || question.reviewQuestionAllowOther ->
                let answerText = Text.strip session.reviewSessionInput
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
                session
                  { reviewSessionPhase = ReviewRunning,
                    reviewSessionActivity = "thinking",
                    reviewSessionPending = Nothing,
                    reviewSessionInput = "",
                    reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript ("\nYou: " <> displayAnswer <> "\n")
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
                session
                  { reviewSessionPhase = ReviewRunning,
                    reviewSessionActivity = "thinking",
                    reviewSessionPending = Nothing,
                    reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript ("\n" <> displayAnswer <> "\n")
                  }
            )
          >> armReviewTick issueNumber
    _ -> setNotice "Codex app-server is not connected"

sendReviewFeedback :: Int -> ReviewSession -> EventM Name AppState ()
sendReviewFeedback issueNumber session = do
  state <- get
  case (state.appReviewBackend, session.reviewSessionThreadId) of
    (ReviewBackendReady client, Just threadId) -> do
      let message = Text.strip session.reviewSessionInput
      result <- liftIO (sendReviewMessage client threadId session.reviewSessionTurnId message)
      case result of
        Left errorMessage -> setNotice errorMessage
        Right () ->
          appendToReviewSession issueNumber
            ( \current ->
                let (restored, stillUndelivered) = takeNextUndelivered current.reviewSessionUndelivered
                 in current
                      { reviewSessionInput = restored,
                        reviewSessionUndelivered = stillUndelivered,
                        reviewSessionPhase = ReviewRunning,
                        reviewSessionActivity = "thinking",
                        reviewSessionTranscript = appendReviewTranscript current.reviewSessionTranscript ("\nYou: " <> message <> "\n")
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
  session
    { reviewSessionInput = nextInput,
      reviewSessionUndelivered = stillUndelivered,
      reviewSessionTranscript =
        appendReviewTranscript session.reviewSessionTranscript ("\n" <> undeliveredTranscriptNote message <> "\n")
    }
  where
    queued = session.reviewSessionUndelivered <> [message]
    (nextInput, stillUndelivered)
      | Text.null (Text.strip session.reviewSessionInput) = takeNextUndelivered queued
      | otherwise = (session.reviewSessionInput, queued)

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
      case resolveReviewCancelAction backendReady session.reviewSessionThreadId session.reviewSessionTurnId session.reviewSessionStage session.reviewSessionPhase hasCanonicalProcess of
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
          { reviewSessionPhase = ReviewInterrupted,
            reviewSessionActivity = "interrupted",
            reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript "\n[interrupted by user]\n"
          }
    )
  void . liftIO . forkIO $ interruptThenKillManagedProcess process
  setNotice ("Interrupting issue review #" <> showText issueNumber <> "; canonical stages don't resume — Esc, then r starts a fresh one")

cycleReviewSession :: Int -> EventM Name AppState ()
cycleReviewSession currentIssue = do
  state <- get
  let issueNumbers = map fst (sortOn fst (Map.toList state.appReviewSessions))
      currentIndex = fromMaybe 0 (findIndex (== currentIssue) issueNumbers)
      nextIssue = safeIndex ((currentIndex + 1) `mod` max 1 (length issueNumbers)) issueNumbers
  case nextIssue of
    Nothing -> pure ()
    Just issueNumber -> do
      modify (\current -> current {appOverlay = Just (ReviewOverlay issueNumber), appNotice = Nothing})
      presentTranscriptTail
      armVisibleReviewTicks

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
  case selectedReviewItem state of
    Nothing -> setNotice "Select an issue or PR before pressing r"
    Just item -> startItemReview item

startItemReview :: BoardItem -> EventM Name AppState ()
startItemReview (IssueItem issue) = startIssueReview issue
startItemReview (PullRequestItem pullRequest) = startPullRequestReview pullRequest

startIssueReview :: Issue -> EventM Name AppState ()
startIssueReview issue = do
  state <- get
  let requestedStage = issueReviewStage state.appConfig.resolvedWorkflow issue
  case Map.lookup issue.issueNumber state.appReviewSessions of
    Just session
      | reviewSessionReusable session.reviewSessionPhase session.reviewSessionStage requestedStage (Map.member issue.issueNumber state.appCanonicalReviewProcesses) -> do
          modify (\current -> current {appOverlay = Just (ReviewOverlay issue.issueNumber), appNotice = Nothing})
          presentTranscriptTail
          armVisibleReviewTicks
    _ -> do
      let priorGeneration = maybe 0 (.reviewSessionTickGeneration) (Map.lookup issue.issueNumber state.appReviewSessions)
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

-- | 'priorGeneration' must be 0 for an issue with no previous session, or
-- the replaced session's 'reviewSessionTickGeneration' when 'startIssueReview'
-- discards a non-reusable one (e.g. its stage no longer matches current
-- labels). A tick queued by that old session can still be delivered before
-- this replacement ever arms its own chain, and by the time it arrives
-- this session is already visible and 'ReviewStarting' -- eligible -- so
-- the generation must already be past whatever that old tick carries
-- *at construction time*, not only from this session's own eventual first
-- arm (issue #30 round-3 review). Bumping past 'priorGeneration' here
-- achieves that regardless of when the first arm happens.
newReviewSession :: Issue -> ReviewStage -> Int -> ReviewSession
newReviewSession issue stage priorGeneration =
  ReviewSession
    { reviewSessionIssue = issue,
      reviewSessionStage = stage,
      reviewSessionThreadId = Nothing,
      reviewSessionTurnId = Nothing,
      reviewSessionPhase = ReviewStarting,
      reviewSessionActivity = if stage == IssueRevision then "starting coordinator" else "running canonical gate",
      reviewSessionTranscript = plainTranscript (if stage == IssueRevision then "" else "Running canonical issue-review:v2 gate…\n"),
      reviewSessionPending = Nothing,
      reviewSessionInput = "",
      reviewSessionUndelivered = [],
      reviewSessionSpinnerFrame = 0,
      reviewSessionTickGeneration = priorGeneration + 1,
      reviewSessionTickArmed = False,
      reviewSessionFollowing = True
    }

launchCanonicalIssueReview :: Issue -> ReviewStage -> EventM Name AppState ()
launchCanonicalIssueReview issue stage = do
  state <- get
  let channel = state.appEventChannel
      issueNumber = issue.issueNumber
  void . liftIO . forkIO $ do
    blocked <- preflightBlocker state.appRepository (ActionIssueReview (issueOriginFromBody issue.issueBody))
    result <- case blocked of
      Just message -> pure (Left message)
      Nothing -> runCanonicalIssueReview state.appOptions.optionConfig state.appRepository issueNumber stage (writeBChan channel . CanonicalIssueReviewProcessStarted issueNumber)
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
  let superseded = maybe False (canonicalReviewCompletionSuperseded . (.reviewSessionPhase)) (Map.lookup issueNumber state.appReviewSessions)
  unless superseded $ do
    appendToReviewSession issueNumber $ \session -> case result of
      Left message -> session {reviewSessionPhase = ReviewFailed, reviewSessionActivity = canonicalReviewActivity message, reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript ("\n" <> sanitizeText message <> "\n")}
      Right canonicalResult ->
        session
          { reviewSessionPhase = if canonicalResult.canonicalReviewApproved then ReviewFinished else ReviewNeedsChanges,
            reviewSessionActivity = if canonicalResult.canonicalReviewApproved then "approved" else "changes requested",
            reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript ("\n" <> renderCanonicalIssueReviewResult stage canonicalResult)
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
startReviewBackend :: EventM Name AppState ()
startReviewBackend = do
  state <- get
  modify (\current -> current {appReviewBackend = ReviewBackendStarting})
  let eventChannel = state.appEventChannel
      eventSink = writeBChan eventChannel . ReviewProtocolEvent
  void
    . liftIO
    . forkIO
    $ do
      blocked <- preflightBlocker state.appRepository reviewBackendAction
      case blocked of
        Just message -> writeBChan eventChannel (ReviewBackendStarted (Left message))
        Nothing -> startReviewClient state.appConfig.resolvedWorkflow state.appRepository eventSink >>= writeBChan eventChannel . ReviewBackendStarted

-- | Preflighted here too, not only in 'startReviewBackend': a backend
-- already running for an earlier issue is reused as-is, so this is the only
-- door a Claude-origin revision passes through when the coordinator was
-- started for a Codex-origin one.
launchIssueReview :: ReviewClient -> Issue -> EventM Name AppState ()
launchIssueReview client issue = do
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
    sessions <- Map.elems . (.appReviewSessions) <$> get
    mapM_
      ( \session ->
          if session.reviewSessionStage == IssueRevision && session.reviewSessionPhase == ReviewStarting && session.reviewSessionThreadId == Nothing
            then launchIssueReview client session.reviewSessionIssue
            else pure ()
      )
      sessions
  where
    failStartingSession message session
      | session.reviewSessionStage == IssueRevision && session.reviewSessionPhase == ReviewStarting =
          session
            { reviewSessionPhase = ReviewFailed,
              reviewSessionActivity = canonicalReviewActivity message,
              reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript ("\n" <> message)
            }
      | otherwise = session

applyReviewEvent :: ReviewEvent -> EventM Name AppState ()
applyReviewEvent reviewEvent = case reviewEvent of
  ReviewThreadCreated issueNumber threadId ->
    appendToReviewSession issueNumber
      ( \session ->
          session
            { reviewSessionThreadId = Just threadId,
              reviewSessionActivity = "session ready",
              reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript "Codex session created.\n"
            }
      )
  ReviewTurnStarted threadId turnId -> do
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { reviewSessionTurnId = Just turnId,
              reviewSessionPhase = ReviewRunning,
              reviewSessionActivity = "thinking",
              reviewSessionPending = Nothing,
              reviewSessionFollowing = followAfterTurnStarted session.reviewSessionFollowing session.reviewSessionTurnId turnId
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
                { reviewSessionTranscript =
                    appendReviewOutput outputKind (reviewOutputPrefix outputKind <> sanitizeText delta) session.reviewSessionTranscript,
                  reviewSessionActivity = reviewOutputActivity outputKind
                }
          )
        tailReviewThread threadId
  ReviewQuestionRequested threadId requestId question ->
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { reviewSessionPhase = ReviewWaiting,
              reviewSessionActivity = "waiting for answer",
              reviewSessionPending = Just (PendingReviewQuestion requestId question)
            }
      )
  ReviewApprovalRequested threadId requestId approval ->
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { reviewSessionPhase = ReviewWaiting,
              reviewSessionActivity = "waiting for approval",
              reviewSessionPending = Just (PendingReviewApproval requestId approval)
            }
      )
  ReviewClaudeStarted threadId -> do
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { reviewSessionTranscript =
                appendReviewTranscript session.reviewSessionTranscript "\n[sonnet] Starting authenticated Sonnet 5 high…\n",
              reviewSessionActivity = "running Claude reviewer"
            }
      )
    tailReviewThread threadId
  ReviewClaudeFinished threadId result -> do
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { reviewSessionTranscript =
                appendReviewTranscript session.reviewSessionTranscript ("[opus] " <> completionMessage result <> "\n"),
              reviewSessionActivity = "processing reviewer result"
            }
      )
    tailReviewThread threadId
  ReviewGitHubStarted threadId summary -> do
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { reviewSessionTranscript =
                appendReviewTranscript session.reviewSessionTranscript ("\n[github] " <> sanitizeText summary <> "\n"),
              reviewSessionActivity = "updating GitHub"
            }
      )
    tailReviewThread threadId
  ReviewGitHubFinished threadId result -> do
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { reviewSessionTranscript =
                appendReviewTranscript session.reviewSessionTranscript ("[github] " <> githubCompletionMessage result <> "\n"),
              reviewSessionActivity = "processing GitHub result"
            }
      )
    tailReviewThread threadId
  ReviewTurnCompleted threadId outcome message result -> do
    modifyReviewSessionByThread threadId
      ( \session ->
          let completedStage = maybe session.reviewSessionStage (reviewResultStage . snd) result
           in session
                { reviewSessionStage = completedStage,
                  reviewSessionTurnId = Nothing,
                  reviewSessionPhase = outcomePhase completedStage outcome (snd <$> result),
                  reviewSessionActivity = reviewOutcomeActivity completedStage outcome (snd <$> result),
                  reviewSessionPending = Nothing,
                  reviewSessionTranscript =
                    maybe (formatReviewTranscript session.reviewSessionTranscript result)
                      (appendReviewTranscript session.reviewSessionTranscript . ("\n" <>))
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
            { reviewSessionPhase = ReviewFailed,
              reviewSessionActivity = canonicalReviewActivity message,
              reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript ("\n" <> message)
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
      appendReviewTranscript
        (stripTranscriptSuffix (sanitizeText rawResult) transcript)
        ("\n\n" <> renderReviewResult result)
    stripTranscriptSuffix suffix transcript =
      ChatTranscript
        { compactTranscript = fromMaybe transcript.compactTranscript (Text.stripSuffix suffix transcript.compactTranscript),
          standardTranscript = fromMaybe transcript.standardTranscript (Text.stripSuffix suffix transcript.standardTranscript),
          fullTranscript = fromMaybe transcript.fullTranscript (Text.stripSuffix suffix transcript.fullTranscript)
        }
    markDisconnected message session
      | session.reviewSessionStage == IssueRevision && session.reviewSessionPhase `elem` [ReviewStarting, ReviewRunning, ReviewWaiting] =
          session
            { reviewSessionPhase = ReviewFailed,
              reviewSessionActivity = "disconnected",
              reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript ("\n" <> message)
            }
      | otherwise = session

-- | Whether a session in this phase, with the review overlay in this
-- visibility, should be animating at all. A canonical stage holds
-- 'ReviewStarting' for the whole life of its process, so this one phase
-- set covers both a running canonical process and an in-progress
-- app-server turn.
reviewTickEligible :: ReviewPhase -> Bool -> Bool
reviewTickEligible phase overlayVisible = overlayVisible && phase `elem` [ReviewStarting, ReviewRunning]

-- | Result of asking whether a trigger -- an answered question/approval,
-- a 'ReviewTurnStarted' notification, a canonical process starting, or the
-- review overlay reopening -- should arm a new tick chain.
data ReviewTickArmOutcome
  = ArmReviewTick Int
  | ReviewTickAlreadyArmed
  | ReviewTickNotEligible
  deriving stock (Eq, Show)

-- | issue #30: every trigger used to call the tick scheduler
-- unconditionally, so a fast answer/approval and the backend's matching
-- 'ReviewTurnStarted' notification each armed their own independent tick
-- chain for the same turn. This coalesces repeated triggers: a chain
-- already armed for the current generation absorbs the request instead of
-- spawning a second one, so at most one chain is ever live per session.
decideReviewTickArm :: ReviewPhase -> Bool -> Bool -> Int -> ReviewTickArmOutcome
decideReviewTickArm phase overlayVisible armed currentGeneration
  | not (reviewTickEligible phase overlayVisible) = ReviewTickNotEligible
  | armed = ReviewTickAlreadyArmed
  | otherwise = ArmReviewTick (currentGeneration + 1)

-- | Result of a fired 'ReviewAnimationTick' checked against its session's
-- current generation/phase/visibility.
data ReviewTickFireOutcome
  = ReviewTickStale
  | ReviewTickReschedule
  | ReviewTickExpire
  deriving stock (Eq, Show)

-- | issue #30: a tick only advances the frame and reschedules itself when
-- it still carries its session's current generation -- a tick from a
-- superseded chain (one the session has since moved past) is dropped
-- silently instead of rearming alongside whatever chain replaced it. This
-- is the fix for the verified fast-resume race: a tick scheduled before a
-- question/approval can arrive after a fast answer restores the running
-- phase, and generation-matching alone would let it rearm alongside the
-- chain the answer itself coalesced onto -- so a match reschedules the
-- *same* chain rather than proving a second one is safe to keep.
decideReviewTickFire :: Int -> Int -> ReviewPhase -> Bool -> ReviewTickFireOutcome
decideReviewTickFire sessionGeneration tickGeneration phase overlayVisible
  | sessionGeneration /= tickGeneration = ReviewTickStale
  | reviewTickEligible phase overlayVisible = ReviewTickReschedule
  | otherwise = ReviewTickExpire

-- | The single entry point every trigger calls to (re)start review
-- animation for an issue's session. Coalesces via 'decideReviewTickArm' so
-- repeated triggers for the same running turn never arm more than one
-- chain.
armReviewTick :: Int -> EventM Name AppState ()
armReviewTick issueNumber = do
  state <- get
  let overlayVisible = reviewOverlayVisible state.appOverlay
  case Map.lookup issueNumber state.appReviewSessions of
    Nothing -> pure ()
    Just session -> case decideReviewTickArm session.reviewSessionPhase overlayVisible session.reviewSessionTickArmed session.reviewSessionTickGeneration of
      ArmReviewTick generation -> do
        modifyReviewSession issueNumber (\current -> current {reviewSessionTickGeneration = generation, reviewSessionTickArmed = True})
        scheduleReviewTick issueNumber generation
      ReviewTickAlreadyArmed -> pure ()
      ReviewTickNotEligible -> pure ()

-- | Which sessions are eligible to animate right now but not currently
-- armed -- e.g. because their chain expired while the review overlay was
-- hidden, or was never armed for a session that only just became visible
-- by having a different tab focused. 'armVisibleReviewTicks' arms exactly
-- these.
reviewSessionsNeedingArm :: Bool -> Map Int ReviewSession -> [Int]
reviewSessionsNeedingArm overlayVisible sessions =
  [ issueNumber
    | (issueNumber, session) <- Map.toList sessions,
      reviewTickEligible session.reviewSessionPhase overlayVisible,
      not session.reviewSessionTickArmed
  ]

-- | Re-arms every review session that is eligible to animate but not
-- currently ticking. A session's chain can expire (unarm) while the
-- review overlay is closed; simply reopening the overlay -- on any tab,
-- via any of the several paths that can do so -- must resume every
-- still-running session's spinner, not only the one being focused, so
-- this sweeps 'armReviewTick' across all of them rather than requiring
-- every overlay-opening call site to know which sessions might need it.
armVisibleReviewTicks :: EventM Name AppState ()
armVisibleReviewTicks = do
  state <- get
  mapM_ armReviewTick (reviewSessionsNeedingArm (reviewOverlayVisible state.appOverlay) state.appReviewSessions)

applyReviewAnimationTick :: Int -> Int -> EventM Name AppState ()
applyReviewAnimationTick issueNumber generation = do
  state <- get
  let overlayVisible = reviewOverlayVisible state.appOverlay
  case Map.lookup issueNumber state.appReviewSessions of
    Nothing -> pure ()
    Just session -> case decideReviewTickFire session.reviewSessionTickGeneration generation session.reviewSessionPhase overlayVisible of
      ReviewTickStale -> pure ()
      ReviewTickReschedule -> do
        modifyReviewSession issueNumber (\current -> current {reviewSessionSpinnerFrame = current.reviewSessionSpinnerFrame + 1})
        scheduleReviewTick issueNumber generation
      ReviewTickExpire -> modifyReviewSession issueNumber (\current -> current {reviewSessionTickArmed = False})

scheduleReviewTick :: Int -> Int -> EventM Name AppState ()
scheduleReviewTick issueNumber generation = do
  eventChannel <- (.appEventChannel) <$> get
  void
    . liftIO
    . forkIO
    $ do
      threadDelay reviewAnimationIntervalMicros
      writeBChan eventChannel (ReviewAnimationTick issueNumber generation)

appendReviewInput :: Char -> ReviewSession -> ReviewSession
appendReviewInput character session =
  session {reviewSessionInput = Text.take reviewInputLimit (session.reviewSessionInput <> Text.singleton character)}

removeReviewInputCharacter :: ReviewSession -> ReviewSession
removeReviewInputCharacter session = session {reviewSessionInput = Text.dropEnd 1 session.reviewSessionInput}
