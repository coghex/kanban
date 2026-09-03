module Kanban.UI.Solve
  ( SolveChooserDecision (..),
    SolveStartDecision (..),
    applySolveEvent,
    failSolveLaunch,
    freshSolveTranscript,
    interruptSolveSession,
    issueFromBoard,
    launchSolveInvocation,
    openItemSolveChooser,
    openSelectedSolveChooser,
    preflightBlocker,
    pullRequestFromBoard,
    solveActionKind,
    solveChooserDecision,
    solveChooserFooterHints,
    solveLaunchPlan,
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
import Kanban.Action
  ( ActionEnvironment (..),
    ActionTargetKind (..),
    ActionTargetRef (..),
    ActionTarget (..),
    ActionPlan (..),
    ActionRefusal (..),
    TargetStructure (..),
    WorkflowActionKind (..),
    actionHandleWorker,
    actionRefusalMessage,
    actionRequest,
    catalogIdentity,
    dispatchProviderTurn,
    planResolvedAction,
    resolveHeldItem,
    ActionRequest (..),
  )
import Kanban.Config (ResolvedConfig (..) )
import Kanban.Domain
import Kanban.Models (ModelRoster, OperatingMode, RecordedAssignment, RosterLoadError, soleAgent)
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
    brandForProvider,
    solveAssignment
  )
import Kanban.Text (sanitizeText)
import Kanban.Worker
  ( WorkerParent (..),
    pendingTerminationDiagnosticPrefix
    )
import Kanban.UI.Filter (dashboardActionEnvironment, readOnlyHistoryRefusal, readOnlyHistoryRefusalFor)
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
--
-- Single-agent mode has nothing to choose between, so a /fresh/ solve starts
-- on the one loaded provider without a chooser: showing a box whose only
-- live digit is the brand this install already runs on would be a keystroke
-- that decides nothing. It is fresh solves only. A reusable session is
-- reopened above this, on the provider it recorded, exactly as in dual mode,
-- and the auto-selection never reaches a session that already exists.
--
-- Dual mode still opens the chooser with both rows, and no-agent still
-- reaches the roster refusal 'solveStartDecision' raises -- 'S' and 'A' are
-- already refused there by 'Kanban.UI.Keys.availableIn' before this runs.
openIssueSolveChooser :: SolveWorkflow -> Issue -> EventM Name AppState ()
openIssueSolveChooser workflow issue = do
  state <- get
  case readOnlyHistoryRefusal state (IssueItem issue) of
    Just notice -> setNotice notice
    Nothing -> case reusableSolveSession workflow issue.issueNumber state.appSolveSessions of
      Just _ -> openExistingSolveOverlay issue.issueNumber
      Nothing -> case solveChooserDecision state.appOperatingMode of
        SolveChooserAuto brand -> startIssueSolve issue workflow brand
        SolveChooserOpen -> modify (\current -> noticeCleared current {appOverlay = Just (SolveChooser workflow issue)})

-- | What a press with no reusable session to reopen does, as one total
-- decision on the mode.
--
-- A pure function for the reason 'Kanban.UI.Refresh.usageRefreshProviders' is
-- one: an 'EventM' cannot be run outside brick, and this arm is the whole of
-- what single-agent mode changes about starting a solve.
data SolveChooserDecision
  = -- | Open the chooser and let the operator pick a brand.
    SolveChooserOpen
  | -- | Start on this brand without asking; there is only one to ask about.
    SolveChooserAuto SolverBrand
  deriving stock (Eq, Show)

solveChooserDecision :: OperatingMode -> SolveChooserDecision
solveChooserDecision =
  maybe SolveChooserOpen (SolveChooserAuto . brandForProvider) . soleAgent

openExistingSolveOverlay :: Int -> EventM Name AppState ()
openExistingSolveOverlay issueNumber = do
  modify (\current -> noticeCleared current {appOverlay = Just (SolveOverlay issueNumber)})
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
    | otherwise -> case resolvedRosterCellFor (`solveAssignment` brand) state.appModelRoster of
        Left message -> SolveStartRefused ("Solve did not start: " <> message)
        Right _ -> SolveStartFresh

-- | The chips the base footer shows while the solve chooser is open,
-- declared beside 'startIssueSolve', which is what the two digits reach.
--
-- The chooser answers exactly three keys and this names all three. The rows
-- inside the box label the same two digits with the model each brand would
-- run, which is a different fact -- what the choice /is/ -- from what the
-- footer states, which is that the digits are live at all.
--
-- Carries no @docs\/design.md@ §7 contract: §7 documents the chooser inside
-- the @S@ and @A@ rows' descriptions, so nothing here reaches
-- 'Kanban.UI.Overlay.helpLines'.
solveChooserFooterHints :: [Text]
solveChooserFooterHints =
  [ "1 codex",
    "2 claude",
    "Esc cancel"
  ]

-- | The launch boundary, reached by picking an agent in the chooser. The
-- refusal is asked again here rather than trusted from the press that opened
-- the chooser: the issue the overlay holds was live when it opened, and a
-- refresh in between can have settled it.
startIssueSolve :: Issue -> SolveWorkflow -> SolverBrand -> EventM Name AppState ()
startIssueSolve issue workflow brand = do
  state <- get
  case solveStartDecision state issue workflow brand of
    SolveStartRefused notice -> modify (\current -> noticeSet notice current {appOverlay = Nothing})
    SolveStartReopen -> openExistingSolveOverlay issue.issueNumber
    SolveStartFresh -> startFreshIssueSolve issue workflow brand

-- | The header a fresh solve session opens its transcript with.
--
-- Nothing is recorded yet, so both lines resolve live: the solver names the
-- @solve@ cell this launch is about to resolve and record, and an autosolve
-- run also names the @pr_review@ cell the opposite brand will review on. A
-- refusal is impossible for the solver line by the time a chooser digit gets
-- here -- 'solveStartDecision' has already resolved that very cell -- but the
-- reviewer's is a different cell and may genuinely be unavailable, which it
-- says rather than defaults.
freshSolveTranscript :: Either RosterLoadError ModelRoster -> SolveWorkflow -> SolverBrand -> Text
freshSolveTranscript rosterResult workflow brand =
  "workflow: "
    <> Text.toLower (workflowTitle workflow)
    <> "\nsolver: "
    <> agentSessionLabelFor brand Nothing (`solveAssignment` brand) rosterResult
    <> ( case workflow of
           SolveOnly -> ""
           AutoSolve -> "\nreviewer: " <> solveReviewerDisplay rosterResult brand
       )
    <> "\n\n"

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
          (plainTranscript (freshSolveTranscript state.appModelRoster workflow brand))
          SolveDetail
            { solveSessionIssue = issue,
              solveSessionWorkflow = workflow,
              solveSessionBrand = brand,
              solveSessionId = Nothing,
              solveSessionAutoProgress = autoProgress,
              solveSessionResumeProvenance = ResumeAnswer,
              -- A fresh start is never a replay: this launch resolves the
              -- cell and records what it resolved.
              solveSessionAssignment = Nothing
            }
  modify
    ( \current ->
        noticeCleared
          current
            { appSolveSessions = Map.insert issue.issueNumber session current.appSolveSessions,
              appOverlay = Just (SolveOverlay issue.issueNumber)
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
-- same reason: this is the boundary a process crosses, so the cell the
-- launch is checked against has to be the one it is handed. Autosolve's own
-- revisions reach the provider through 'launchSolveInvocation' above, so
-- they refuse here too rather than needing an arm of their own.
--
-- 'launchAssignment' is what makes a resume immune to a roster edit landing
-- between two turns of the same provider session: it replays this session's
-- recorded assignment and never reaches 'state.appModelRoster'. Recording
-- the result back on the session is what carries the replay forward, and is
-- also how a session recovered from a pre-MODEL-7 specification gains one.
launchLiveSolveInvocation :: Int -> SolveWorkflow -> SolverBrand -> Maybe Text -> ResumeProvenance -> Text -> EventM Name AppState ()
launchLiveSolveInvocation issueNumber workflow brand existingSession provenance input = do
  state <- get
  let recorded = Map.lookup issueNumber state.appSolveSessions >>= (.sessionDetail.solveSessionAssignment)
  case launchAssignment recorded (`solveAssignment` brand) state.appModelRoster of
    Left message -> liftIO (failSolveLaunch state.appEventChannel issueNumber message)
    Right assignment -> do
      modifySolveSession issueNumber (withSessionDetail (\detail -> detail {solveSessionAssignment = Just assignment}))
      launchAssignedSolveInvocation assignment issueNumber workflow brand existingSession provenance input

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

-- | The spawn itself, through the workflow action registry.
--
-- The registry is what runs the preflight, replays this session's recorded
-- cell, and reaches 'Kanban.Worker.launchSolveWorker'; this function's whole
-- remaining job is to gather the session state that plan is built from and to
-- apply the typed answer to the session -- the durable worker on success, and
-- the diagnostic-then-terminal pair 'failSolveLaunch' raises on a refusal.
--
-- The plan is built against the issue the /session/ holds rather than against
-- the number, because that record is what every entry point here already
-- refused on; re-resolving the number would additionally refuse a session
-- whose issue has since left the open read, which is not what pressing a
-- chooser digit has ever done.
launchAssignedSolveInvocation :: RecordedAssignment -> Int -> SolveWorkflow -> SolverBrand -> Maybe Text -> ResumeProvenance -> Text -> EventM Name AppState ()
launchAssignedSolveInvocation assignment issueNumber workflow brand existingSession provenance input = do
  state <- get
  let eventChannel = state.appEventChannel
  void
    . liftIO
    . forkIO
    $ case solveLaunchPlan state assignment issueNumber workflow brand existingSession provenance input of
      Left refusal -> failSolveLaunch eventChannel issueNumber (actionRefusalMessage refusal)
      Right (request, plan) -> do
        dispatched <- dispatchProviderTurn (dashboardActionEnvironment state) request plan
        case dispatched of
          Left refusal -> failSolveLaunch eventChannel issueNumber (actionRefusalMessage refusal)
          Right handle ->
            mapM_ (writeBChan eventChannel . WorkerRegistered) (actionHandleWorker handle)
  void
    . liftIO
    . forkIO
    $ do
      threadDelay solveInitialRefreshDelayMicros
      writeBChan eventChannel SolveBoardRefreshRequested

-- | What a solve launch asks the registry for, from the session state this
-- dashboard holds.
--
-- Extracted from the launch above so the whole of what this adapter /decides/
-- is a value: the verb the key selects, the target, the cell to replay, the
-- session to resume, and the parent record an autosolve run's worker carries.
-- Everything after it is the registry's and everything before it is the
-- press, which leaves the launch a fork, a dispatch, and the two ways of
-- applying the answer -- and leaves this assertable without an @EventM@.
--
-- The plan is built against the issue the /session/ holds rather than against
-- the number, because that record is what every entry point here already
-- refused on; re-resolving the number would additionally refuse a session
-- whose issue has since left the open read, which is not what pressing a
-- chooser digit has ever done.
solveLaunchPlan ::
  AppState ->
  RecordedAssignment ->
  Int ->
  SolveWorkflow ->
  SolverBrand ->
  Maybe Text ->
  ResumeProvenance ->
  Text ->
  Either ActionRefusal (ActionRequest, ActionPlan)
solveLaunchPlan state assignment issueNumber workflow brand existingSession provenance input =
  case session of
    Nothing ->
      Left
        ( ActionDispatchFailed
            kind
            ("no solve session holds #" <> showText issueNumber <> " any more")
        )
    Just held -> do
      plan <-
        planResolvedAction
          state.appConfig.resolvedWorkflow
          (catalogIdentity environment.actionCatalog)
          kind
          (Just brand)
          ( ActionTargetItem
              ( resolveHeldItem
                  environment.actionCatalog
                  TargetPlain
                  (IssueItem held.sessionDetail.solveSessionIssue)
              )
          )
      pure (request, plan)
  where
    session = Map.lookup issueNumber state.appSolveSessions
    environment = dashboardActionEnvironment state
    kind = solveActionKind workflow
    -- Every field describes the /solver/, which is what makes a restarted
    -- dashboard able to restore this loop: the round tells an implementation
    -- run from a revision, the recorded start and known pull requests keep
    -- discovery from binding a pull request this run did not open, and the
    -- bound pull request is what a revision reattached after a restart would
    -- otherwise have no way to learn.
    parent = do
      held <- session
      progress <- held.sessionDetail.solveSessionAutoProgress
      pure
        WorkerParent
          { workerParentIssueNumber = issueNumber,
            workerParentReviewRound = progress.autoSolveReviewRound,
            workerParentSolverBrand = held.sessionDetail.solveSessionBrand,
            workerParentSolverSession = held.sessionDetail.solveSessionId,
            workerParentSolverLogPath = held.sessionLogPath,
            workerParentStartedAt = progress.autoSolveStartedAt,
            workerParentKnownPullRequests = progress.autoSolveKnownPullRequests,
            workerParentPullRequest = progress.autoSolvePullRequest,
            workerParentSolverAssignment = held.sessionDetail.solveSessionAssignment
          }
    request =
      (actionRequest kind (catalogIdentity environment.actionCatalog) (TargetByKind ActionTargetIssue issueNumber))
        { requestSolverBrand = Just brand,
          requestRecordedAssignment = Just assignment,
          requestExistingSession = existingSession,
          requestExistingLogPath = session >>= (.sessionLogPath),
          requestResumeProvenance = provenance,
          requestUserMessage = input,
          requestParent = parent
        }

-- | Which registry verb a solve workflow is.
solveActionKind :: SolveWorkflow -> WorkflowActionKind
solveActionKind SolveOnly = SolveIssue
solveActionKind AutoSolve = AutoSolveIssue

-- | Preflight one AI action just before spawning it, so a missing
-- Kanban-owned component is reported with the command that installs it
-- instead of surfacing minutes later as an opaque agent failure. Only a
-- definite local observation blocks; an inconclusive probe lets the action
-- run and fail on its own terms, so a setup Kanban cannot introspect is
-- never broken by its own diagnostics. Every probe is read-only.
preflightBlocker :: Repository -> OperatingMode -> PreflightAction -> IO (Maybe Text)
preflightBlocker repository mode action = do
  environment <- gatherPreflightEnvironment repository.repositoryRoot
  pure (preflightDiagnostic <$> blockingRemediation (actionReport environment mode action))

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
          modify (\current -> noticeCleared current {appOverlay = Just (PullRequestReviewOverlay pullRequestNumber)})
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
