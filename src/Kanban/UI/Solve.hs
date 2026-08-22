module Kanban.UI.Solve
  ( SolveStartDecision (..),
    applySolveEvent,
    failSolveLaunch,
    interruptSolveSession,
    issueFromBoard,
    launchSolveInvocation,
    openItemSolveChooser,
    openSelectedSolveChooser,
    preflightBlocker,
    pullRequestFromBoard,
    solveStartDecision,
    startIssueSolve,
    submitSolveInput,
    suppressIfResolvedPullRequest,
    suppressIfResolvedSolve,
  )
where


import Brick
import Brick.BChan (BChan, writeBChan)
import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (unless, void )
import Control.Monad.IO.Class (liftIO)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.CLI (Options (..))
import Kanban.Config (ResolvedConfig (..) )
import Kanban.Domain
import Kanban.Models (ModelRoster)
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
    solveAssignment,
    solverLabel
  )
import Kanban.Text (sanitizeText)
import Kanban.Worker
  ( WorkerParent (..),
    launchSolveWorker,
    pendingTerminationDiagnosticPrefix
    )
import Kanban.UI.Filter (readOnlyHistoryRefusal, readOnlyHistoryRefusalFor)
import Kanban.UI.Keys (BoardAction (..), actionKeyText)
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.SessionCore
import Kanban.UI.State
import Kanban.UI.AutoSolve
import Kanban.UI.Transcript
import Kanban.UI.Selection
import Kanban.UI.Session
import Kanban.UI.SessionEvents
import Kanban.UI.Overlay
import Kanban.UI.Refresh

openSelectedSolveChooser :: SolveWorkflow -> EventM Name AppState ()
openSelectedSolveChooser workflow = do
  state <- get
  case (selectedReviewItem state >>= readOnlyHistoryRefusal state, selectedReviewIssue state) of
    (Just notice, _) -> setNotice notice
    (Nothing, Nothing) -> setNotice ("Select an issue before pressing " <> workflowKey workflow)
    (Nothing, Just issue) -> openIssueSolveChooser workflow issue

-- | Lifecycle outranks the wrong-kind refusal: a merged pull request is
-- read-only history whether or not this key wanted a pull request at all.
openItemSolveChooser :: SolveWorkflow -> BoardItem -> EventM Name AppState ()
openItemSolveChooser workflow item = do
  state <- get
  case (readOnlyHistoryRefusal state item, item) of
    (Just notice, _) -> setNotice notice
    (Nothing, IssueItem issue) -> openIssueSolveChooser workflow issue
    (Nothing, PullRequestItem _) -> setNotice ("Select an issue before pressing " <> workflowKey workflow)

-- | The refusal precedes reopening a reusable session, so a solve overlay left
-- behind by work that has since closed cannot be brought back to act on it.
openIssueSolveChooser :: SolveWorkflow -> Issue -> EventM Name AppState ()
openIssueSolveChooser workflow issue = do
  state <- get
  case readOnlyHistoryRefusal state (IssueItem issue) of
    Just notice -> setNotice notice
    Nothing -> case reusableSolveSession workflow issue.issueNumber state.appSolveSessions of
      Just _ -> openExistingSolveOverlay issue.issueNumber
      Nothing -> modify (\current -> current {appOverlay = Just (SolveChooser workflow issue), appNotice = Nothing})

openExistingSolveOverlay :: Int -> EventM Name AppState ()
openExistingSolveOverlay issueNumber = do
  modify (\current -> current {appOverlay = Just (SolveOverlay issueNumber), appNotice = Nothing})
  presentTranscriptTail

-- | The base-board key that starts each workflow, named from the one table
-- that declares it rather than spelled out a second time here.
workflowKey :: SolveWorkflow -> Text
workflowKey SolveOnly = actionKeyText SolveSelection
workflowKey AutoSolve = actionKeyText AutoSolveSelection

-- | What pressing a chooser digit does, as one total decision.
--
-- The roster is consulted here, before any session exists, as well as at the
-- launch boundary — the same reason 'readOnlyHistoryRefusal' is asked twice,
-- and it matters more here. A refusal reached after 'startFreshIssueSolve'
-- has inserted a session leaves that session in the map, and
-- 'reusableSolveSession' reopens a session of the same workflow whatever its
-- phase — so the chooser never comes back and the operator can never pick
-- the brand the roster actually loads. Refusing before the insert is what
-- keeps the next press a fresh choice.
data SolveStartDecision
  = -- | Show this notice, close the chooser, and create nothing.
    SolveStartRefused Text
  | -- | An existing session for this issue owns the work; reopen it.
    SolveStartReopen
  | -- | Create the session and launch.
    SolveStartFresh
  deriving stock (Eq, Show)

solveStartDecision :: AppState -> Issue -> SolveWorkflow -> SolverBrand -> SolveStartDecision
solveStartDecision state issue workflow brand = case readOnlyHistoryRefusal state (IssueItem issue) of
  Just notice -> SolveStartRefused notice
  Nothing
    | isJust (reusableSolveSession workflow issue.issueNumber state.appSolveSessions) -> SolveStartReopen
    | otherwise -> case resolvedRosterFor (`solveAssignment` brand) state.appModelRoster of
        Left message -> SolveStartRefused ("Solve did not start: " <> message)
        Right _ -> SolveStartFresh

-- | The launch boundary, reached by picking an agent in the chooser. The
-- refusal is asked again here rather than trusted from the press that opened
-- the chooser: the issue the overlay holds was live when it opened, and a
-- refresh in between can have settled it.
startIssueSolve :: Issue -> SolveWorkflow -> SolverBrand -> EventM Name AppState ()
startIssueSolve issue workflow brand = do
  state <- get
  case solveStartDecision state issue workflow brand of
    SolveStartRefused notice -> modify (\current -> current {appOverlay = Nothing, appNotice = Just notice})
    SolveStartReopen -> openExistingSolveOverlay issue.issueNumber
    SolveStartFresh -> startFreshIssueSolve issue workflow brand

startFreshIssueSolve :: Issue -> SolveWorkflow -> SolverBrand -> EventM Name AppState ()
startFreshIssueSolve issue workflow brand = do
  state <- get
  let autoProgress = initialAutoSolveProgress workflow (boardPullRequestNumbers state.appBoard) state.appNow
  let session =
        newAgentSession
          (priorTickGeneration issue.issueNumber state.appSolveSessions)
          SolveStarting
          "starting"
          (Just state.appNow)
          ( plainTranscript $
              "workflow: "
                <> Text.toLower (workflowTitle workflow)
                <> "\nsolver: "
                <> solverLabel brand
                <> ( case workflow of
                       SolveOnly -> ""
                       AutoSolve -> "\nreviewer: " <> solveReviewerLabel brand
                   )
                <> "\n\n"
          )
          SolveDetail
            { solveSessionIssue = issue,
              solveSessionWorkflow = workflow,
              solveSessionBrand = brand,
              solveSessionId = Nothing,
              solveSessionAutoProgress = autoProgress,
              solveSessionResumeProvenance = ResumeAnswer
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

-- | The one place a solve worker is spawned, from a fresh start, a resumed
-- answer, or an automated revision alike.
--
-- The read-only-history refusal is re-asked here as well as at each of those
-- entry points, because this is the boundary a process actually crosses: an
-- entry point decided minutes ago against work a refresh has since settled
-- must not reach it.
launchSolveInvocation :: Int -> SolveWorkflow -> SolverBrand -> Maybe Text -> ResumeProvenance -> Text -> EventM Name AppState ()
launchSolveInvocation issueNumber workflow brand existingSession provenance input = do
  refusal <- flip readOnlyHistoryRefusalFor (IssueId issueNumber) <$> get
  case refusal of
    Just notice -> setNotice notice
    Nothing -> launchLiveSolveInvocation issueNumber workflow brand existingSession provenance input

-- | The roster refusal sits beside the read-only-history one and for the
-- same reason: this is the boundary a process crosses, so the roster the
-- launch is checked against has to be the one it is handed. Autosolve's own
-- revisions reach the provider through 'launchSolveInvocation' above, so
-- they refuse here too rather than needing an arm of their own.
launchLiveSolveInvocation :: Int -> SolveWorkflow -> SolverBrand -> Maybe Text -> ResumeProvenance -> Text -> EventM Name AppState ()
launchLiveSolveInvocation issueNumber workflow brand existingSession provenance input = do
  state <- get
  case resolvedRosterFor (`solveAssignment` brand) state.appModelRoster of
    Left message -> liftIO (failSolveLaunch state.appEventChannel issueNumber message)
    Right roster -> launchRosteredSolveInvocation roster issueNumber workflow brand existingSession provenance input

-- | How a launch that never reached a provider reports itself: the
-- diagnostic-then-terminal pair, which is the only thing that settles the
-- session this launch was created for.
--
-- A bare notice is not enough and never was. Every caller of
-- 'launchSolveInvocation' has already inserted or reopened a session, and
-- 'solvePhaseActive' counts 'SolveStarting' as live work — so a refusal that
-- only set a notice would leave that session permanently starting,
-- 'reusableSolveSession' would hand it back instead of letting the user pick
-- a different solver, and nothing would ever terminalize it. The pair below
-- moves it to 'SolveFailedPhase' and raises the same
-- 'Kanban.UI.Util.agentFailureNotice' the arm that consumes it always has.
failSolveLaunch :: BChan AppEvent -> Int -> Text -> IO ()
failSolveLaunch eventChannel issueNumber message = do
  writeBChan eventChannel (SolveProtocolEvent (SolveDiagnostic issueNumber message))
  writeBChan eventChannel (SolveProtocolEvent (SolveProcessFinished issueNumber (SolveFailed message)))

launchRosteredSolveInvocation :: ModelRoster -> Int -> SolveWorkflow -> SolverBrand -> Maybe Text -> ResumeProvenance -> Text -> EventM Name AppState ()
launchRosteredSolveInvocation roster issueNumber workflow brand existingSession provenance input = do
  state <- get
  let existingLogPath = Map.lookup issueNumber state.appSolveSessions >>= (.sessionLogPath)
      eventChannel = state.appEventChannel
      parent = do
        session <- Map.lookup issueNumber state.appSolveSessions
        progress <- session.sessionDetail.solveSessionAutoProgress
        pure
          WorkerParent
            { workerParentIssueNumber = issueNumber,
              workerParentReviewRound = progress.autoSolveReviewRound,
              workerParentSolverBrand = session.sessionDetail.solveSessionBrand,
              workerParentSolverSession = session.sessionDetail.solveSessionId,
              workerParentSolverLogPath = session.sessionLogPath,
              workerParentStartedAt = progress.autoSolveStartedAt,
              workerParentKnownPullRequests = progress.autoSolveKnownPullRequests
            }
  void
    . liftIO
    . forkIO
    $ do
      blocked <- preflightBlocker state.appRepository (solvePreflightAction workflow brand)
      case blocked of
        Just message -> failSolveLaunch eventChannel issueNumber message
        Nothing -> do
          launched <- launchSolveWorker roster state.appRepository issueNumber workflow brand existingSession existingLogPath provenance input parent state.appOptions.optionConfig state.appConfig.resolvedWorkflow
          case launched of
            Left message -> failSolveLaunch eventChannel issueNumber message
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
      | session.sessionPhase == SolveAttention,
        Just progress <- session.sessionDetail.solveSessionAutoProgress,
        progress.autoSolveStage == AutoReviewing,
        Just pullRequestNumber <- progress.autoSolvePullRequest -> do
          modify (\current -> current {appOverlay = Just (PullRequestReviewOverlay pullRequestNumber), appNotice = Nothing})
          presentTranscriptTail
      | session.sessionPhase /= SolveAttention -> setNotice "This solve session is not waiting for input"
      | Text.null (Text.strip session.sessionInput) -> setNotice "Type an answer before pressing Enter"
      | otherwise -> case session.sessionDetail.solveSessionId of
          Nothing -> setNotice "The solver did not return a resumable session id"
          Just sessionId -> do
            let answer = Text.strip session.sessionInput
            appendToSolveSession issueNumber
              ( \current ->
                  current
                    { sessionPhase = SolveStarting,
                      sessionActivity = "resuming",
                      sessionInput = "",
                      sessionTranscript = appendTranscript current.sessionTranscript ("\nYou: " <> answer <> "\n")
                    }
              )
            launchSolveInvocation issueNumber session.sessionDetail.solveSessionWorkflow session.sessionDetail.solveSessionBrand (Just sessionId) session.sessionDetail.solveSessionResumeProvenance answer

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
              appSolveSessions = Map.adjust (setSessionActivity state.appNow "thinking" . (\session -> session {sessionPhase = SolveRunning, sessionFollowing = True})) issueNumber state.appSolveSessions
            }
      )
    armSessionTick solveSessionOps issueNumber
  SolveLogOpened issueNumber path ->
    modifySolveSession issueNumber (\session -> session {sessionLogPath = Just path})
  SolveSessionIdentified issueNumber sessionId ->
    modifySolveSession issueNumber (withSessionDetail (\detail -> detail {solveSessionId = Just sessionId}))
  SolveOutput issueNumber output -> do
    now <- (.appNow) <$> get
    appendToSolveSession issueNumber
      (setSessionActivity now (agentActivity output) . (\session -> session {sessionTranscript = appendAgentTranscript output session.sessionTranscript}))
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
      ( setSessionActivity now "diagnostic output"
          . ( \session ->
                session
                  { sessionTranscript = appendTranscript session.sessionTranscript ("[solver] " <> sanitizeText diagnostic <> "\n"),
                    sessionPhase = if pendingTerminationDiagnosticPrefix `Text.isInfixOf` diagnostic then SolveOrphanedPhase else session.sessionPhase
                  }
            )
      )
  SolveProcessFinished issueNumber outcome -> do
    state <- get
    let priorSession = Map.lookup issueNumber state.appSolveSessions
        priorPhase = (.sessionPhase) <$> priorSession
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
            $ priorSession >>= (.sessionDetail.solveSessionAutoProgress) >>= autoSolveAfterCompletion
        SolveNeedsInput _ -> setNotice ("Solve workflow for #" <> showText issueNumber <> " needs input")
        SolveFailed message -> setNotice (agentFailureNotice ("Solve workflow for #" <> showText issueNumber) message)
  where
    finishSolveSession (Just SolveInterrupting) _ session =
      withResumeProvenance ResumeInterruptGuidance
        session
          { sessionPhase = SolveAttention,
            sessionActivity = "waiting for guidance",
            sessionTranscript = appendTranscript session.sessionTranscript "\n[interrupted] Type guidance and press Enter to resume this session.\n"
          }
    finishSolveSession (Just SolveKilledPhase) _ session =
      (stopAutoSolve session) {sessionActivity = "killed"}
    finishSolveSession _ outcome session = case outcome of
      SolveCompleted -> case session.sessionDetail.solveSessionAutoProgress >>= autoSolveAfterCompletion of
        Just continuation ->
          (withSessionDetail (\detail -> detail {solveSessionAutoProgress = Just continuation.autoSolveCompletionProgress}) session)
            { sessionPhase = SolveRunning,
              sessionActivity = continuation.autoSolveCompletionActivity
            }
        Nothing -> session {sessionPhase = SolveFinished, sessionActivity = "completed"}
      SolveNeedsInput question ->
        withResumeProvenance ResumeAnswer
          session
            { sessionPhase = SolveAttention,
              sessionActivity = "waiting for input",
              sessionTranscript = appendTranscript session.sessionTranscript ("\nQuestion: " <> sanitizeText question <> "\n")
            }
      SolveFailed message ->
        (stopAutoSolve session)
          { sessionPhase = SolveFailedPhase,
            sessionActivity = failureActivity message,
            sessionTranscript = appendTranscript session.sessionTranscript ("\n" <> sanitizeText message <> "\n")
          }

    withResumeProvenance provenance = withSessionDetail (\detail -> detail {solveSessionResumeProvenance = provenance})
    stopAutoSolve = withSessionDetail (\detail -> detail {solveSessionAutoProgress = autoSolveStopped <$> detail.solveSessionAutoProgress})

interruptSolveSession :: Int -> EventM Name AppState ()
interruptSolveSession issueNumber = do
  state <- get
  case (Map.lookup issueNumber state.appSolveSessions, Map.lookup issueNumber state.appSolveProcesses) of
    (Just session, Just process)
      | session.sessionPhase `elem` [SolveStarting, SolveRunning], session.sessionDetail.solveSessionId /= Nothing -> do
          appendToSolveSession issueNumber
            ( \current ->
                current
                  { sessionPhase = SolveInterrupting,
                    sessionActivity = "interrupting",
                    sessionTranscript = appendTranscript current.sessionTranscript "\n[interrupt requested]\n"
                  }
            )
          liftIO (interruptManagedProcess process)
          setNotice ("Interrupting solve workflow #" <> showText issueNumber <> "…")
      | session.sessionDetail.solveSessionId == Nothing -> setNotice "Wait for the resumable session id before interrupting"
      | otherwise -> setNotice "This solve workflow has no live turn to interrupt"
    _ -> setNotice "This solve workflow has no live process to interrupt"

suppressIfResolvedSolve :: Int -> EventM Name AppState () -> EventM Name AppState ()
suppressIfResolvedSolve issueNumber action = do
  sessions <- (.appSolveSessions) <$> get
  unless (sessionAlreadyResolved issueNumber sessions) action

suppressIfResolvedPullRequest :: Int -> EventM Name AppState () -> EventM Name AppState ()
suppressIfResolvedPullRequest number action = do
  sessions <- (.appPullRequestReviewSessions) <$> get
  unless (sessionAlreadyResolved number sessions) action

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
