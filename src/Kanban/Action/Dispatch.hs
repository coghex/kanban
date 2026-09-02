{-# LANGUAGE DerivingStrategies #-}

-- | The registry proper: plan a request, dispatch it to its owning authority,
-- and observe what that authority durably recorded.
--
-- Dispatch and observation are separate on purpose. A provider turn is owned
-- by a detached persistent worker, so a dispatch that waited for the answer
-- would be waiting for minutes; it returns as soon as the durable handle
-- exists, and every later question about that action is asked of the worker's
-- own records rather than of anything a dashboard is rendering.
--
-- The rule that makes observation worth anything is that /worker exit success
-- is not action success/. A supervisor exiting 'SolveCompleted' means the
-- provider session ended without failing, and nothing more. A solve reports a
-- pull request only once exactly one attributable one has been identified —
-- through 'Kanban.UI.AutoSolve.decideAutoSolve''s own discovery rule, so solve
-- and autosolve cannot disagree about which pull request a run opened — and a
-- review, rereview, revision, or repair reports a verdict only once that
-- verdict is actually standing on the pull request. Absent, multiple, stale,
-- wrong-origin, and conflicting evidence all produce a non-success result.
--
-- The public boundary below takes no @AppState@, no @EventM@, and no Brick
-- event channel. It does import 'Kanban.UI.Util.launchAssignment' and
-- "Kanban.UI.AutoSolve": both are pure decisions that happen to live beside
-- the dashboard, and reaching them is what keeps this module from becoming a
-- second site for "what does this launch run on" and "what does the loop do
-- next". Neither imports this module, so nothing here is circular.
module Kanban.Action.Dispatch
  ( -- * Planning
    ActionPlan (..),
    planAction,
    planResolvedAction,
    checkTargetRepository,
    checkedAgainst,

    -- * Dispatch and observation
    dispatchAction,
    dispatchProviderTurn,
    liveAutoSolveTurns,
    autoSolveActionHandle,
    runAutoSolveAction,
    observeAction,
    observeWorkerHandle,
    observeAutoSolveTurn,
    approvalQueueObservation,

    -- * Terminal validation
    validateWorkerOutcome,
    attributedSolvePullRequest,
    validatedPullRequestVerdict,
  )
where

import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Action.Capability
  ( ActionCapability (..),
    ActionRoute (..),
    actionCapabilityIO,
    actionRoute,
  )
import Kanban.Action.AutoSolve
  ( AutoSolveDriver,
    AutoSolveState,
    AutoSolveTurns (..),
    autoSolveCursorFor,
    initialAutoSolveState,
    runAutoSolveActionWith,
  )
import Kanban.Action.Target (actionCompatibility, resolveActionTarget)
import Kanban.Action.Types
import Kanban.ApprovalService
  ( ApprovalObservation (..),
    discoverApprovalController,
    queryApprovalStatus,
  )
import Kanban.Cache (normalizedRepositoryIdentity)
import Kanban.Domain (ItemId (..), Label (..), PullRequest (..), Repository, WorkflowConfig)
import Kanban.Models (RecordedAssignment)
import Kanban.Preflight (PreflightAction (..))
import Kanban.PullRequestFlow
  ( PullRequestAction,
    PullRequestOrigin,
    PullRequestVerdict (..),
    agentForAction,
    pullRequestAssignment,
    pullRequestVerdictEvidence,
  )
import Kanban.Solve (SolveOutcome (..), SolveWorkflow (..), SolverBrand, solveAssignment)
import Kanban.UI.AutoSolve
  ( AutoSolveDecision (..),
    AutoSolveObservation (..),
    decideAutoSolve,
  )
import Kanban.UI.Types (AutoSolveProgress (..), AutoSolveStage (..))
import Kanban.UI.Util (launchAssignment)
import Kanban.Worker
  ( WorkerDescriptor (..),
    WorkerLaunchRefusal (..),
    WorkerParent (..),
    WorkerState (..),
    WorkerStatus (..),
    launchPullRequestWorker,
    launchSolveWorker,
    readWorkerState,
    workerHoldingItem,
  )

-- ---------------------------------------------------------------------------
-- Planning
-- ---------------------------------------------------------------------------

-- | A request that has passed every check a decision can make without
-- touching the machine.
data ActionPlan = ActionPlan
  { planKind :: WorkflowActionKind,
    planTarget :: ActionTarget,
    planRoute :: ActionRoute
  }
  deriving stock (Eq, Show)

-- | Resolve, refuse, and route — all of it pure, so every refusal in the
-- vocabulary is reachable in a test without a process, a repository, or a
-- network.
planAction :: ActionEnvironment -> ActionRequest -> Either ActionRefusal ActionPlan
planAction environment request = do
  target <-
    resolveActionTarget
      environment.actionWorkflowConfig
      environment.actionCatalog
      request.requestRepository
      request.requestTarget
  planResolvedAction
    environment.actionWorkflowConfig
    request.requestRepository
    request.requestKind
    request.requestSolverBrand
    target

-- | The same refusals and routing for a target the caller already resolved.
--
-- The dashboard reaches this one: it holds the issue or pull request the press
-- was made on, so re-resolving that number against a read would be a second
-- answer to a question it has already answered -- and a stricter one, since a
-- number that has left the open read is unresolvable while the session holding
-- its record is not.
planResolvedAction :: WorkflowConfig -> Text -> WorkflowActionKind -> Maybe SolverBrand -> ActionTarget -> Either ActionRefusal ActionPlan
planResolvedAction config requested kind solverBrand target = do
  checkTargetRepository requested target
  case actionCompatibility config kind target of
    Just refusal -> Left refusal
    Nothing -> ActionPlan kind target <$> actionRoute config kind solverBrand target

-- | One planned action, checked against the repository the environment would
-- actually act on.
--
-- Every dispatch passes through this, the repository-wide approval-queue
-- action included: a request can resolve and plan cleanly against a catalog
-- for one repository while the environment beside it names another, and that
-- environment is what supplies the controller to read and the checkout to
-- spawn in. Checking only the actions that own a worker would leave the one
-- that reads a queue silently observing the wrong repository's.
checkedAgainst :: ActionEnvironment -> ActionPlan -> Either ActionRefusal ActionPlan
checkedAgainst environment plan =
  plan
    <$ checkTargetRepository (normalizedRepositoryIdentity environment.actionRepository) plan.planTarget

-- | Refuse a target that belongs to a repository other than the one the
-- caller means.
--
-- 'resolveActionTarget' asks this before it looks a number up, and this asks
-- it again of a record the caller resolved itself -- which is the whole reason
-- the identity is carried on the record. Every repository has a #123, so a
-- target resolved against one repository and dispatched with another's
-- environment would spawn a worker on the wrong repository entirely while the
-- record it came from still named the right one.
checkTargetRepository :: Text -> ActionTarget -> Either ActionRefusal ()
checkTargetRepository requested target = case target of
  ActionTargetRepositoryWide repository -> compareWith (normalizedRepositoryIdentity repository)
  ActionTargetItem resolved -> compareWith resolved.resolvedTargetRepository
  where
    normalized = Text.toLower (Text.strip requested)
    compareWith held
      | normalized == held = Right ()
      | otherwise = Left (ActionRepositoryMismatch normalized held)

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

-- | Start one action and return the durable handle it left behind.
--
-- Nonblocking in the sense that matters: it returns once the owning authority
-- owns the work, not once the work is done. It never merges a pull request,
-- never writes an approval verdict label, and never starts or stops the
-- approval service.
dispatchAction :: ActionEnvironment -> ActionRequest -> IO (Either ActionRefusal ActionHandle)
dispatchAction environment request = case planAction environment request >>= checkedAgainst environment of
  Left refusal -> pure (Left refusal)
  Right plan -> case plan.planKind of
    -- Declared, and refused before anything is reached for. No canonical
    -- review subprocess and no app-server revision turn is started here:
    -- SAG-10 owns both runners.
    ReviewIssue -> pure (Left (ActionNotRunnerOwned ReviewIssue))
    ReviseIssue -> pure (Left (ActionNotRunnerOwned ReviseIssue))
    ObserveApprovalQueue -> pure (Right (ApprovalQueueHandle environment.actionRepository))
    _ -> dispatchProviderTurn environment request plan

-- | Start the provider turn one planned action names.
--
-- The capability probe and the spawn, and nothing else: every refusal a plan
-- can carry has already been made. Exported because the dashboard's launch
-- boundaries plan against the record they hold rather than against a number.
dispatchProviderTurn :: ActionEnvironment -> ActionRequest -> ActionPlan -> IO (Either ActionRefusal ActionHandle)
dispatchProviderTurn environment request plan = case plan.planTarget of
  ActionTargetRepositoryWide _ -> pure (Left (ActionTargetMismatchedArity plan.planKind))
  -- Asked again here, of the environment this launch will actually be made
  -- against, and before anything is probed or spawned. A plan is checked
  -- against the identity its request named; this is the boundary a worker
  -- crosses, and the repository it crosses into is this environment's.
  ActionTargetItem resolved
    | Left refusal <- checkedAgainst environment plan -> pure (Left refusal)
    | otherwise -> do
        capability <- actionCapabilityIO environment.actionRepository plan.planRoute
        case capability of
          ActionIncapable detail -> pure (Left (ActionCapabilityBlocked plan.planKind detail))
          ActionCapable -> case assignmentFor plan of
            Left message -> pure (Left (ActionRoutingUnavailable plan.planKind message))
            Right cell -> launchFor resolved cell
  where
    -- The baseline is taken here, at dispatch, and carried on the handle:
    -- "exactly one /new/ pull request" is only answerable against what already
    -- existed when the run started.
    attribution brand =
      ActionAttribution
        { attributionKnownPullRequests = catalogPullRequestNumbers environment.actionCatalog,
          attributionStartedAt = environment.actionNow,
          attributionSolverBrand = brand
        }

    -- Every cell comes from the existing owning code:
    -- 'Kanban.Solve.solveAssignment' for the solver's, and
    -- 'Kanban.PullRequestFlow.pullRequestAssignment' — which resolves through
    -- 'agentForAction' — for every pull-request action including repair.
    assignmentFor selected = case selected.planRoute of
      RouteProvider (ActionSolve brand) -> resolve (`solveAssignment` brand)
      RouteProvider (ActionAutoSolve brand) -> resolve (`solveAssignment` brand)
      RouteProvider (ActionPullRequestFlow origin action) ->
        resolve (\roster -> pullRequestAssignment roster origin action)
      RouteProvider (ActionIssueReview _) -> Left "no runner owns issue review yet"
      RouteProvider (ActionIssueRevision _) -> Left "no runner owns issue revision yet"
      RouteApprovalQueue -> Left "the approval queue starts no provider"
      where
        resolve cell = launchAssignment request.requestRecordedAssignment cell environment.actionRoster

    launchFor resolved cell = case plan.planRoute of
      RouteProvider (ActionSolve brand) ->
        launchSolve resolved SolveOnly brand cell request.requestParent
          >>= settled resolved (workerHandle resolved brand)
      RouteProvider (ActionAutoSolve brand) ->
        launchSolve resolved AutoSolve brand cell (Just (autoSolveParent resolved brand cell))
          >>= settled resolved (autoSolveHandle resolved brand)
      RouteProvider (ActionPullRequestFlow origin action) ->
        launchPullRequest resolved origin action cell
          >>= settled resolved (workerHandle resolved (agentForAction origin action))
      _ -> pure (Left (ActionRoutingUnavailable plan.planKind "this action starts no provider"))

    -- What a launch's answer means, with the one refusal a caller can act on
    -- treated as such.
    --
    -- An item whose turn is already running is one to /join/. The worker
    -- lease is keyed by item, so a launch that lost it lost to exactly one
    -- worker; adopting that worker is what makes two advancers of the same
    -- action -- a dashboard refresh and a headless runner, say -- observe one
    -- turn rather than race to start a second. Reporting it as a failure is
    -- what made the loser record a stopped run over work that was proceeding
    -- perfectly well.
    --
    -- Fails closed when the holder cannot be found: a turn is running and
    -- this dispatch does not know which, so it refuses rather than starting
    -- another.
    settled resolved build outcome = case outcome of
      Right descriptor -> build descriptor
      Left (WorkerLaunchFailed detail) -> pure (Left (ActionDispatchFailed plan.planKind detail))
      Left (WorkerTurnAlreadyRunning owner detail) -> do
        held <- workerHoldingItem environment.actionRepository owner (itemFor resolved)
        case held of
          Just descriptor -> build descriptor
          Nothing -> pure (Left (ActionTurnAlreadyRunning plan.planKind detail))

    itemFor resolved = case resolved.resolvedTargetKind of
      ActionTargetIssue -> IssueId resolved.resolvedTargetNumber
      ActionTargetPullRequest -> PullRequestId resolved.resolvedTargetNumber

    workerHandle resolved brand descriptor =
      pure (Right (WorkerActionHandle plan.planKind resolved descriptor (attribution brand)))

    -- The one place an autosolve handle is made, so every one of them carries
    -- a cursor observing it can advance.
    autoSolveHandle resolved brand descriptor =
      Right <$> autoSolveActionHandle liveAutoSolveTurns resolved (attribution brand) descriptor

    -- An autosolve launch records the run's own baseline on the solver it
    -- starts, because nothing else will. The loop's discovery arm binds only a
    -- /new/ pull request, so a run recovered after its opening solve finished
    -- -- and before any review worker exists to carry a parent record -- would
    -- otherwise take the board's current pull requests as its baseline, find
    -- the one it just opened already in it, and wait for a pull request that
    -- has already arrived. A caller that supplied its own parent keeps it:
    -- that is a revision round, which knows its own round and bound pull
    -- request.
    autoSolveParent resolved brand cell =
      fromMaybe
        WorkerParent
          { workerParentIssueNumber = resolved.resolvedTargetNumber,
            workerParentReviewRound = 0,
            workerParentSolverBrand = brand,
            workerParentSolverSession = request.requestExistingSession,
            workerParentSolverLogPath = request.requestExistingLogPath,
            workerParentStartedAt = environment.actionNow,
            workerParentKnownPullRequests = catalogPullRequestNumbers environment.actionCatalog,
            workerParentPullRequest = Nothing,
            workerParentSolverAssignment = Just cell
          }
        request.requestParent

    launchSolve resolved workflow brand cell parent =
      launchSolveWorker
        cell
        environment.actionRepository
        resolved.resolvedTargetNumber
        workflow
        brand
        request.requestExistingSession
        request.requestExistingLogPath
        request.requestResumeProvenance
        request.requestUserMessage
        parent
        environment.actionConfigPath
        environment.actionWorkflowConfig

    launchPullRequest :: ResolvedTarget -> PullRequestOrigin -> PullRequestAction -> RecordedAssignment -> IO (Either WorkerLaunchRefusal WorkerDescriptor)
    launchPullRequest resolved origin action cell =
      launchPullRequestWorker
        cell
        environment.actionRepository
        resolved.resolvedTargetNumber
        origin
        action
        request.requestExistingSession
        request.requestExistingLogPath
        request.requestResumeProvenance
        request.requestUserMessage
        request.requestParent
        environment.actionConfigPath
        environment.actionWorkflowConfig

-- ---------------------------------------------------------------------------
-- The autosolve loop's live wiring
-- ---------------------------------------------------------------------------

-- | The two things the autosolve loop does to the world, in production: this
-- registry's own dispatch, and the real durable-state read.
liveAutoSolveTurns :: AutoSolveTurns
liveAutoSolveTurns = AutoSolveTurns dispatchAction readWorkerState

-- | An autosolve handle carrying a cursor its observations advance.
autoSolveActionHandle :: AutoSolveTurns -> ResolvedTarget -> ActionAttribution -> WorkerDescriptor -> IO ActionHandle
autoSolveActionHandle turns resolved attribution descriptor = do
  cursor <- autoSolveCursorFor turns (initialAutoSolveState resolved descriptor attribution)
  pure (AutoSolveActionHandle resolved descriptor attribution cursor)

-- | Drive one autosolve action to a terminal outcome.
runAutoSolveAction :: ActionEnvironment -> AutoSolveDriver -> AutoSolveState -> IO ActionOutcome
runAutoSolveAction = runAutoSolveActionWith liveAutoSolveTurns

-- ---------------------------------------------------------------------------
-- Observation
-- ---------------------------------------------------------------------------

-- | Observe one dispatched action.
--
-- An autosolve handle is the one that cannot be concluded from what it is
-- holding: see 'observeAutoSolveTurn'. Advancing that loop is
-- "Kanban.Action.AutoSolve"'s, so its progression has exactly one owner.
observeAction :: ActionEnvironment -> ActionHandle -> IO ActionObservation
observeAction environment handle = case handle of
  ApprovalQueueHandle repository ->
    ActionSettled . ActionApprovalQueueReport <$> approvalQueueObservation repository
  WorkerActionHandle kind resolved descriptor attribution ->
    observeWorkerHandle environment kind resolved descriptor attribution
  -- Advancing rather than merely reading: an autosolve action's result is the
  -- approval its loop reaches, so observing it moves the loop on a tick.
  AutoSolveActionHandle _ _ _ cursor -> advanceAutoSolveCursor cursor environment

-- | What one observation of an autosolve action's /current provider turn/
-- reports.
--
-- Never a success. Autosolve's only successful terminal result is the
-- validated approval of the pull request its loop bound, and no single
-- provider turn can establish that one: a finished solver has opened a pull
-- request nothing has reviewed, and a finished reviewer has published a
-- verdict the loop may still have to act on. So a turn that settled leaves
-- the action running, and only the two answers that end the loop wherever it
-- is — a provider's question, and a provider's failure — settle it here.
--
-- Reporting the opened pull request instead would be the exact promotion
-- requirement 7 forbids: a caller polling this handle would see success after
-- the opening solve and never drive the review, the revision, or the approval
-- the action was asked for.
--
-- This is the view of a handle held on its own, which cannot progress because
-- it carries nowhere to record progress. To /observe/ an autosolve action --
-- advancing it a tick at a time until it reaches that approval -- open it
-- with 'Kanban.Action.AutoSolve.beginAutoSolveAction' and observe that, or
-- drive it to its end with
-- 'Kanban.Action.AutoSolve.runAutoSolveAction'.
observeAutoSolveTurn :: ActionEnvironment -> ResolvedTarget -> WorkerDescriptor -> IO ActionObservation
observeAutoSolveTurn _ resolved descriptor = do
  recorded <- readWorkerState descriptor
  pure $ case recorded of
    Left message -> ActionRunning ("worker state unavailable: " <> message)
    Right state -> case state.workerStateStatus of
      WorkerStarting -> ActionRunning state.workerStateLastActivity
      WorkerRunning -> ActionRunning state.workerStateLastActivity
      WorkerOrphaned _ -> ActionRunning "resolving orphaned provider processes"
      WorkerTerminal (SolveNeedsInput detail) -> ActionSettled (ActionNeedsInput detail)
      WorkerTerminal (SolveFailed detail) -> ActionSettled (ActionFailed detail)
      WorkerTerminal SolveCompleted ->
        ActionRunning
          ( "the current provider turn for autosolve #"
              <> showNumber resolved.resolvedTargetNumber
              <> " finished; the loop advances on its next observation"
          )

-- | The worker half, on its own, so the autosolve loop can ask the same
-- question of whichever provider turn it is currently waiting on.
observeWorkerHandle :: ActionEnvironment -> WorkflowActionKind -> ResolvedTarget -> WorkerDescriptor -> ActionAttribution -> IO ActionObservation
observeWorkerHandle environment kind resolved descriptor attribution = do
  recorded <- readWorkerState descriptor
  pure $ case recorded of
    -- A state file that cannot be read is not a finished action. The worker
    -- may not have written one yet, so this waits rather than inventing a
    -- terminal result for work that may still be running.
    Left message -> ActionRunning ("worker state unavailable: " <> message)
    Right state -> case state.workerStateStatus of
      WorkerStarting -> ActionRunning state.workerStateLastActivity
      WorkerRunning -> ActionRunning state.workerStateLastActivity
      -- Committed, but recorded descendants are still live or could not be
      -- verified gone. Not terminal yet: the supervisor is still resolving it.
      WorkerOrphaned _ -> ActionRunning "resolving orphaned provider processes"
      WorkerTerminal outcome -> ActionSettled (validateWorkerOutcome environment kind resolved attribution outcome)

-- | What a settled worker actually achieved.
--
-- The two failing outcomes pass straight through, because a provider that
-- asked a question or failed has said what happened. 'SolveCompleted' is the
-- one that has to be checked against evidence rather than believed.
validateWorkerOutcome :: ActionEnvironment -> WorkflowActionKind -> ResolvedTarget -> ActionAttribution -> SolveOutcome -> ActionOutcome
validateWorkerOutcome environment kind resolved attribution outcome = case outcome of
  SolveNeedsInput detail -> ActionNeedsInput detail
  SolveFailed detail -> ActionFailed detail
  SolveCompleted -> case kind of
    SolveIssue -> attributedSolvePullRequest environment resolved attribution
    -- Deliberately not the opened pull request. An autosolve action concludes
    -- on the approval its loop reaches, so one finished turn of it is never a
    -- result; 'observeAutoSolveTurn' is what observes one, and
    -- 'Kanban.Action.AutoSolve.runAutoSolveAction' is what drives the loop.
    AutoSolveIssue ->
      ActionStopped
        "an autosolve action concludes on its bound pull request's approval; drive it with runAutoSolveAction"
    ReviewPullRequest -> validatedPullRequestVerdict environment resolved
    RevisePullRequest -> validatedPullRequestVerdict environment resolved
    RepairPullRequest -> validatedPullRequestVerdict environment resolved
    ReviewIssue -> ActionFailed notRunnerOwned
    ReviseIssue -> ActionFailed notRunnerOwned
    ObserveApprovalQueue -> ActionFailed "the approval queue owns no worker"
  where
    notRunnerOwned = actionRefusalMessage (ActionNotRunnerOwned kind)

-- | The pull request a finished solve opened, if exactly one is attributable
-- to it.
--
-- The decision is 'Kanban.UI.AutoSolve.decideAutoSolve''s discovery arm rather
-- than a second implementation of the same rule. That arm already defines
-- "exactly one new linked pull request carrying this solver's origin marker",
-- including the multiple-candidate and wrong-origin halts, and reaching it
-- here is what keeps solve and autosolve from ever disagreeing about which
-- pull request a run produced.
attributedSolvePullRequest :: ActionEnvironment -> ResolvedTarget -> ActionAttribution -> ActionOutcome
attributedSolvePullRequest environment resolved attribution =
  case decideAutoSolve observation progress of
    AutoSolveOpenReview number _ -> ActionPullRequestOpened number
    AutoSolveWaitingOn _ ->
      ActionStopped
        ("no new pull request linked to #" <> showNumber resolved.resolvedTargetNumber <> " has appeared yet")
    AutoSolveHalted _ reason -> ActionStopped reason
    _ -> ActionStopped "the solve produced no attributable pull request"
  where
    progress =
      AutoSolveProgress
        { autoSolveStage = AutoDiscoveringPullRequest,
          autoSolvePullRequest = Nothing,
          autoSolveReviewRound = 0,
          autoSolveKnownPullRequests = attribution.attributionKnownPullRequests,
          autoSolveStartedAt = attribution.attributionStartedAt
        }
    observation =
      AutoSolveObservation
        { autoSolveIssueNumber = resolved.resolvedTargetNumber,
          autoSolveWorkflowConfig = environment.actionWorkflowConfig,
          autoSolveSolverBrand = attribution.attributionSolverBrand,
          autoSolveSolverSession = Nothing,
          autoSolveSolverRunning = False,
          autoSolveSnapshotPullRequests = environment.actionCatalog.catalogPullRequests,
          autoSolveReviewPhase = Nothing
        }
-- | The verdict actually standing on a pull request a review, rereview,
-- revision, or repair has finished.
--
-- Validated against the catalog the caller supplied, so a driver that has not
-- refreshed since the worker exited gets a stale answer by construction; the
-- headless loop refreshes first for exactly that reason. A pull request that
-- has disappeared from the read, and a pull request carrying no verdict at
-- all, are both non-success results.
validatedPullRequestVerdict :: ActionEnvironment -> ResolvedTarget -> ActionOutcome
validatedPullRequestVerdict environment resolved =
  case find ((== number) . (.pullRequestNumber)) environment.actionCatalog.catalogPullRequests of
    Nothing ->
      ActionStopped ("PR #" <> showNumber number <> " is no longer in this read; its verdict cannot be validated")
    Just pullRequest ->
      case pullRequestVerdictEvidence environment.actionWorkflowConfig (map (.labelName) pullRequest.pullRequestLabels) of
        -- Contradictory evidence, which requirement 7 forbids promoting: two
        -- canonical verdicts stand on this pull request and neither is the
        -- one it carries.
        Left reason -> ActionStopped ("PR #" <> showNumber number <> " " <> reason)
        Right PullRequestVerdictPending ->
          ActionStopped ("PR #" <> showNumber number <> " carries no canonical verdict yet")
        Right verdict -> ActionPullRequestVerdict number verdict
  where
    number = resolved.resolvedTargetNumber

-- | One read of the approval controller, with none of its distinctions
-- flattened and nothing started or stopped.
approvalQueueObservation :: Repository -> IO ApprovalQueueObservation
approvalQueueObservation repository = do
  discovered <- discoverApprovalController repository
  case discovered of
    Left unavailable -> pure (ApprovalQueueUndiscoverable unavailable)
    Right controller -> do
      observed <- queryApprovalStatus (normalizedRepositoryIdentity repository) controller
      pure $ case observed of
        Left message -> ApprovalQueueQueryFailed message
        Right observation ->
          ApprovalQueueReported observation.observedApprovalStatus observation.observedApprovalIncidents

showNumber :: Int -> Text
showNumber = Text.pack . show
