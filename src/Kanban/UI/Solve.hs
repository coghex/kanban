module Kanban.UI.Solve
  ( applySolveAnimationTick,
    applySolveEvent,
    interruptSolveSession,
    issueFromBoard,
    launchSolveInvocation,
    openItemSolveChooser,
    openSelectedSolveChooser,
    preflightBlocker,
    pullRequestFromBoard,
    startIssueSolve,
    submitSolveInput,
    suppressIfResolvedPullRequest,
    suppressIfResolvedSolve,
  )
where


import Brick
import Brick.BChan (writeBChan)
import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (unless, void )
import Control.Monad.IO.Class (liftIO)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.CLI (Options (..))
import Kanban.Config (ResolvedConfig (..) )
import Kanban.Domain
import Kanban.Preflight
  ( PreflightAction (..),
    actionReport,
    blockingRemediation,
    gatherPreflightEnvironment,
    preflightDiagnostic
    )
import Kanban.Process (interruptManagedProcess )
import Kanban.Solve
  ( ResumeProvenance (..),
    SolveEvent (..),
    SolveOutcome (..),
    SolveWorkflow (..),
    SolverBrand (..),
    solverLabel
  )
import Kanban.Text (sanitizeText)
import Kanban.Worker
  ( WorkerParent (..),
    launchSolveWorker,
    pendingTerminationDiagnosticPrefix
    )
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.State
import Kanban.UI.AutoSolve
import Kanban.UI.Transcript
import Kanban.UI.Selection
import Kanban.UI.Session
import Kanban.UI.Overlay
import Kanban.UI.Refresh

openSelectedSolveChooser :: SolveWorkflow -> EventM Name AppState ()
openSelectedSolveChooser workflow = do
  state <- get
  case selectedReviewIssue state of
    Nothing -> setNotice ("Select an issue before pressing " <> workflowKey workflow)
    Just issue -> openIssueSolveChooser workflow issue

openItemSolveChooser :: SolveWorkflow -> BoardItem -> EventM Name AppState ()
openItemSolveChooser workflow (IssueItem issue) = openIssueSolveChooser workflow issue
openItemSolveChooser workflow (PullRequestItem _) = setNotice ("Select an issue before pressing " <> workflowKey workflow)

openIssueSolveChooser :: SolveWorkflow -> Issue -> EventM Name AppState ()
openIssueSolveChooser workflow issue = do
  state <- get
  case reusableSolveSession workflow issue.issueNumber state.appSolveSessions of
    Just _ -> openExistingSolveOverlay issue.issueNumber
    Nothing -> modify (\current -> current {appOverlay = Just (SolveChooser workflow issue), appNotice = Nothing})

openExistingSolveOverlay :: Int -> EventM Name AppState ()
openExistingSolveOverlay issueNumber = do
  modify (\current -> current {appOverlay = Just (SolveOverlay issueNumber), appNotice = Nothing})
  presentTranscriptTail

workflowKey :: SolveWorkflow -> Text
workflowKey SolveOnly = "S"
workflowKey AutoSolve = "A"

startIssueSolve :: Issue -> SolveWorkflow -> SolverBrand -> EventM Name AppState ()
startIssueSolve issue workflow brand = do
  state <- get
  case reusableSolveSession workflow issue.issueNumber state.appSolveSessions of
    Just _ -> openExistingSolveOverlay issue.issueNumber
    Nothing -> startFreshIssueSolve issue workflow brand

startFreshIssueSolve :: Issue -> SolveWorkflow -> SolverBrand -> EventM Name AppState ()
startFreshIssueSolve issue workflow brand = do
  state <- get
  let autoProgress = initialAutoSolveProgress workflow (boardPullRequestNumbers state.appBoard) state.appNow
  let session =
        SolveSession
          { solveSessionIssue = issue,
            solveSessionWorkflow = workflow,
            solveSessionBrand = brand,
            solveSessionId = Nothing,
            solveSessionPhase = SolveStarting,
            solveSessionActivity = "starting",
            solveSessionActivityStartedAt = state.appNow,
            solveSessionLogPath = Nothing,
            solveSessionTranscript = plainTranscript $
              "workflow: "
                <> Text.toLower (workflowTitle workflow)
                <> "\nsolver: "
                <> solverLabel brand
                <> ( case workflow of
                       SolveOnly -> ""
                       AutoSolve -> "\nreviewer: " <> solveReviewerLabel brand
                   )
                <> "\n\n",
            solveSessionInput = "",
            solveSessionSpinnerFrame = 0,
            solveSessionAutoProgress = autoProgress,
            solveSessionResumeProvenance = ResumeAnswer,
            solveSessionFollowing = True
          }
  modify
    ( \current ->
        current
          { appSolveSessions = Map.insert issue.issueNumber session current.appSolveSessions,
            appOverlay = Just (SolveOverlay issue.issueNumber),
            appNotice = Nothing
          }
    )
  presentTranscriptTail
  launchSolveInvocation issue.issueNumber workflow brand Nothing ResumeAnswer ""

launchSolveInvocation :: Int -> SolveWorkflow -> SolverBrand -> Maybe Text -> ResumeProvenance -> Text -> EventM Name AppState ()
launchSolveInvocation issueNumber workflow brand existingSession provenance input = do
  state <- get
  let existingLogPath = Map.lookup issueNumber state.appSolveSessions >>= (.solveSessionLogPath)
      eventChannel = state.appEventChannel
      parent = do
        session <- Map.lookup issueNumber state.appSolveSessions
        progress <- session.solveSessionAutoProgress
        pure
          WorkerParent
            { workerParentIssueNumber = issueNumber,
              workerParentReviewRound = progress.autoSolveReviewRound,
              workerParentSolverBrand = session.solveSessionBrand,
              workerParentSolverSession = session.solveSessionId,
              workerParentSolverLogPath = session.solveSessionLogPath,
              workerParentStartedAt = progress.autoSolveStartedAt,
              workerParentKnownPullRequests = progress.autoSolveKnownPullRequests
            }
  void
    . liftIO
    . forkIO
    $ do
      blocked <- preflightBlocker state.appRepository (solvePreflightAction workflow brand)
      case blocked of
        Just message -> do
          writeBChan eventChannel (SolveProtocolEvent (SolveDiagnostic issueNumber message))
          writeBChan eventChannel (SolveProtocolEvent (SolveProcessFinished issueNumber (SolveFailed message)))
        Nothing -> do
          launched <- launchSolveWorker state.appRepository issueNumber workflow brand existingSession existingLogPath provenance input parent state.appOptions.optionConfig state.appConfig.resolvedWorkflow
          case launched of
            Left message -> do
              writeBChan eventChannel (SolveProtocolEvent (SolveDiagnostic issueNumber message))
              writeBChan eventChannel (SolveProtocolEvent (SolveProcessFinished issueNumber (SolveFailed message)))
            Right descriptor -> do
              writeBChan eventChannel (WorkerRegistered descriptor)
  void
    . liftIO
    . forkIO
    $ do
      threadDelay solveInitialRefreshDelayMicros
      writeBChan eventChannel SolveBoardRefreshRequested

solvePreflightAction :: SolveWorkflow -> SolverBrand -> PreflightAction
solvePreflightAction SolveOnly = ActionSolve
solvePreflightAction AutoSolve = ActionAutoSolve

-- | Preflight one AI action just before spawning it, so a missing
-- Kanban-owned component is reported with the command that installs it
-- instead of surfacing minutes later as an opaque agent failure. Only a
-- definite local observation blocks; an inconclusive probe lets the action
-- run and fail on its own terms, so a setup Kanban cannot introspect is
-- never broken by its own diagnostics. Every probe is read-only.
preflightBlocker :: Repository -> PreflightAction -> IO (Maybe Text)
preflightBlocker repository action = do
  environment <- gatherPreflightEnvironment repository.repositoryRoot
  pure (preflightDiagnostic <$> blockingRemediation (actionReport environment action))

submitSolveInput :: Int -> EventM Name AppState ()
submitSolveInput issueNumber = do
  state <- get
  case Map.lookup issueNumber state.appSolveSessions of
    Nothing -> setNotice "Solve session is no longer available"
    Just session
      | session.solveSessionPhase == SolveAttention,
        Just progress <- session.solveSessionAutoProgress,
        progress.autoSolveStage == AutoReviewing,
        Just pullRequestNumber <- progress.autoSolvePullRequest -> do
          modify (\current -> current {appOverlay = Just (PullRequestReviewOverlay pullRequestNumber), appNotice = Nothing})
          presentTranscriptTail
      | session.solveSessionPhase /= SolveAttention -> setNotice "This solve session is not waiting for input"
      | Text.null (Text.strip session.solveSessionInput) -> setNotice "Type an answer before pressing Enter"
      | otherwise -> case session.solveSessionId of
          Nothing -> setNotice "The solver did not return a resumable session id"
          Just sessionId -> do
            let answer = Text.strip session.solveSessionInput
            appendToSolveSession issueNumber
              ( \current ->
                  current
                    { solveSessionPhase = SolveStarting,
                      solveSessionActivity = "resuming",
                      solveSessionInput = "",
                      solveSessionTranscript = appendSolveTranscript current.solveSessionTranscript ("\nYou: " <> answer <> "\n")
                    }
              )
            launchSolveInvocation issueNumber session.solveSessionWorkflow session.solveSessionBrand (Just sessionId) session.solveSessionResumeProvenance answer

applySolveEvent :: SolveEvent -> EventM Name AppState ()
applySolveEvent solveEvent = case solveEvent of
  SolveProcessSpawning _ _ -> pure ()
  SolveProcessStarted issueNumber _ process -> do
    modify
      ( \state ->
          state
            { appSolveProcesses = Map.insert issueNumber process state.appSolveProcesses,
              -- issue #39: spawning a process is this workflow's new turn,
              -- so it re-engages the live tail.
              appSolveSessions = Map.adjust (setSolveActivity state.appNow "thinking" . (\session -> session {solveSessionPhase = SolveRunning, solveSessionFollowing = True})) issueNumber state.appSolveSessions
            }
      )
    scheduleSolveTick issueNumber
  SolveLogOpened issueNumber path ->
    modifySolveSession issueNumber (\session -> session {solveSessionLogPath = Just path})
  SolveSessionIdentified issueNumber sessionId ->
    modifySolveSession issueNumber (\session -> session {solveSessionId = Just sessionId})
  SolveOutput issueNumber output -> do
    now <- (.appNow) <$> get
    appendToSolveSession issueNumber
      (setSolveActivity now (agentActivity output) . (\session -> session {solveSessionTranscript = appendAgentTranscript output session.solveSessionTranscript}))
  SolveDiagnostic issueNumber diagnostic -> do
    now <- (.appNow) <$> get
    -- This specific diagnostic means a user-requested kill could not be
    -- verified (see Kanban.Worker's pending-termination marker) and the
    -- worker is still alive and retrying: render it orphaned rather than
    -- running or optimistically "killed". Matched by text, not by the
    -- session's current phase, so a TUI restart that replays this same
    -- event from a fresh session (which never ran the "killed by user" UI
    -- transition) still renders it correctly.
    appendToSolveSession issueNumber
      ( setSolveActivity now "diagnostic output"
          . ( \session ->
                session
                  { solveSessionTranscript = appendSolveTranscript session.solveSessionTranscript ("[solver] " <> sanitizeText diagnostic <> "\n"),
                    solveSessionPhase = if pendingTerminationDiagnosticPrefix `Text.isInfixOf` diagnostic then SolveOrphanedPhase else session.solveSessionPhase
                  }
            )
      )
  SolveProcessFinished issueNumber outcome -> do
    state <- get
    let priorSession = Map.lookup issueNumber state.appSolveSessions
        priorPhase = (.solveSessionPhase) <$> priorSession
    modify
      ( \current ->
          current
            { appSolveProcesses = Map.delete issueNumber current.appSolveProcesses,
              appSolveSessions = Map.adjust (finishSolveSession priorPhase outcome) issueNumber current.appSolveSessions
            }
      )
    tailTranscript (SolveTranscript issueNumber)
    startBoardRefresh
    case priorPhase of
      Just SolveInterrupting -> setNotice ("Solve workflow for #" <> showText issueNumber <> " interrupted; type guidance and press Enter")
      Just SolveKilledPhase -> setNotice ("Solve workflow for #" <> showText issueNumber <> " was killed")
      _ -> case outcome of
        SolveCompleted ->
          setNotice
            . maybe
              ("Solve workflow for #" <> showText issueNumber <> " finished")
              (autoSolveCompletionNotice issueNumber . (.autoSolveCompletionHandoff))
            $ priorSession >>= (.solveSessionAutoProgress) >>= autoSolveAfterCompletion
        SolveNeedsInput _ -> setNotice ("Solve workflow for #" <> showText issueNumber <> " needs input")
        SolveFailed message -> setNotice (agentFailureNotice ("Solve workflow for #" <> showText issueNumber) message)
  where
    finishSolveSession (Just SolveInterrupting) _ session =
      session
        { solveSessionPhase = SolveAttention,
          solveSessionActivity = "waiting for guidance",
          solveSessionTranscript = appendSolveTranscript session.solveSessionTranscript "\n[interrupted] Type guidance and press Enter to resume this session.\n",
          solveSessionResumeProvenance = ResumeInterruptGuidance
        }
    finishSolveSession (Just SolveKilledPhase) _ session =
      session {solveSessionActivity = "killed", solveSessionAutoProgress = autoSolveStopped <$> session.solveSessionAutoProgress}
    finishSolveSession _ outcome session = case outcome of
      SolveCompleted -> case session.solveSessionAutoProgress >>= autoSolveAfterCompletion of
        Just continuation ->
          session
            { solveSessionPhase = SolveRunning,
              solveSessionActivity = continuation.autoSolveCompletionActivity,
              solveSessionAutoProgress = Just continuation.autoSolveCompletionProgress
            }
        Nothing -> session {solveSessionPhase = SolveFinished, solveSessionActivity = "completed"}
      SolveNeedsInput question ->
        session
          { solveSessionPhase = SolveAttention,
            solveSessionActivity = "waiting for input",
            solveSessionTranscript = appendSolveTranscript session.solveSessionTranscript ("\nQuestion: " <> sanitizeText question <> "\n"),
            solveSessionResumeProvenance = ResumeAnswer
          }
      SolveFailed message ->
        session
          { solveSessionPhase = SolveFailedPhase,
            solveSessionActivity = failureActivity message,
            solveSessionAutoProgress = autoSolveStopped <$> session.solveSessionAutoProgress,
            solveSessionTranscript = appendSolveTranscript session.solveSessionTranscript ("\n" <> sanitizeText message <> "\n")
          }

interruptSolveSession :: Int -> EventM Name AppState ()
interruptSolveSession issueNumber = do
  state <- get
  case (Map.lookup issueNumber state.appSolveSessions, Map.lookup issueNumber state.appSolveProcesses) of
    (Just session, Just process)
      | session.solveSessionPhase `elem` [SolveStarting, SolveRunning], session.solveSessionId /= Nothing -> do
          appendToSolveSession issueNumber
            ( \current ->
                current
                  { solveSessionPhase = SolveInterrupting,
                    solveSessionActivity = "interrupting",
                    solveSessionTranscript = appendSolveTranscript current.solveSessionTranscript "\n[interrupt requested]\n"
                  }
            )
          liftIO (interruptManagedProcess process)
          setNotice ("Interrupting solve workflow #" <> showText issueNumber <> "…")
      | session.solveSessionId == Nothing -> setNotice "Wait for the resumable session id before interrupting"
      | otherwise -> setNotice "This solve workflow has no live turn to interrupt"
    _ -> setNotice "This solve workflow has no live process to interrupt"

applySolveAnimationTick :: Int -> EventM Name AppState ()
applySolveAnimationTick issueNumber = do
  state <- get
  case (Map.lookup issueNumber state.appSolveSessions, Map.member issueNumber state.appSolveProcesses) of
    (Just session, True)
      | session.solveSessionPhase `elem` [SolveStarting, SolveRunning] -> do
          modifySolveSession issueNumber (\current -> current {solveSessionSpinnerFrame = current.solveSessionSpinnerFrame + 1})
          scheduleSolveTick issueNumber
    _ -> pure ()

scheduleSolveTick :: Int -> EventM Name AppState ()
scheduleSolveTick issueNumber = do
  eventChannel <- (.appEventChannel) <$> get
  void
    . liftIO
    . forkIO
    $ do
      threadDelay reviewAnimationIntervalMicros
      writeBChan eventChannel (SolveAnimationTick issueNumber)

suppressIfResolvedSolve :: Int -> EventM Name AppState () -> EventM Name AppState ()
suppressIfResolvedSolve issueNumber action = do
  sessions <- (.appSolveSessions) <$> get
  unless (solveSessionAlreadyResolved issueNumber sessions) action

suppressIfResolvedPullRequest :: Int -> EventM Name AppState () -> EventM Name AppState ()
suppressIfResolvedPullRequest number action = do
  sessions <- (.appPullRequestReviewSessions) <$> get
  unless (pullRequestSessionAlreadyResolved number sessions) action

issueFromBoard :: Board -> Int -> Maybe Issue
issueFromBoard board issueNumber = do
  (_, _, item) <- findItem board (IssueId issueNumber)
  case item of
    IssueItem issue -> Just issue
    PullRequestItem _ -> Nothing

pullRequestFromBoard :: Board -> Int -> Maybe PullRequest
pullRequestFromBoard board number = do
  (_, _, item) <- findItem board (PullRequestId number)
  case item of
    PullRequestItem pullRequest -> Just pullRequest
    IssueItem _ -> Nothing

solveInitialRefreshDelayMicros :: Int
solveInitialRefreshDelayMicros = 5 * 1000 * 1000
