{-# LANGUAGE DerivingStrategies #-}

-- | The complete autosolve loop as a plain-IO action.
--
-- Autosolve is not its first solve turn. It is: run the selected solver, bind
-- the one pull request that run opened, review it on the opposite brand,
-- resume the /original/ solver against a changes-requested verdict, observe
-- the canonical rereview that revision publishes, and repeat up to the
-- five-round bound. Registering only the opening turn would leave a headless
-- caller with an action whose stated terminal result — @PR approved@ — it
-- could never reach.
--
-- Every decision about what the loop does next is
-- 'Kanban.UI.AutoSolve.decideAutoSolve''s, unchanged. This module is the
-- plain-IO adapter for it: it gathers the observation from durable worker
-- records instead of from @AppState@, runs the decision, and starts the turn
-- that decision names through the registry. That is what "exactly one
-- progression owner" means here — the stages, the rounds, the discovery rule
-- and the five-round bound all still live in one pure function, and a
-- dashboard refresh and a headless tick reach the same one.
--
-- Two observation inputs are @AppState@-derived in the dashboard and are
-- rebuilt from durable records here: whether a solve process is running for
-- the issue (@appSolveProcesses@ there, this worker's recorded status here),
-- and the phase of the review session for the bound pull request
-- (@appPullRequestReviewSessions@ there, the review worker's recorded status
-- here). The first is what 'Kanban.UI.AutoSolve.decideAutoSolve' holds a
-- revision back on, so rebuilding it from a record is what keeps provider
-- turns sequential with no dashboard present.
module Kanban.Action.AutoSolve
  ( AutoSolveTick (..),
    AutoSolveMove (..),
    AutoSolveConclusion (..),
    autoSolveTick,
    autoSolveConclusionOutcome,
    AutoSolveAction,
    beginAutoSolveAction,
    beginAutoSolveActionWith,
    observeAutoSolveAction,
    autoSolveActionActivity,
    AutoSolveState (..),
    AutoSolveTurns (..),
    liveAutoSolveTurns,
    AutoSolveDriver (..),
    autoSolveStateFor,
    autoSolveStateFromWorkers,
    recoverAutoSolveState,
    reviewPhaseForRecord,
    reviewPhaseForWorker,
    settledReviewTurn,
    workerStatusIsLive,
    advanceAutoSolveAction,
    runAutoSolveAction,
    runAutoSolveActionWith,
  )
where

import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Maybe (listToMaybe)
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Action.Dispatch
  ( ActionEnvironment (..),
    ActionRequest (..),
    actionRequest,
    dispatchAction,
  )
import Kanban.Action.Target
  ( CatalogHistory,
    TargetCatalog (..),
    catalogFromSnapshot,
    catalogIdentity,
    workflowActionKindForLabelledPullRequest,
  )
import Kanban.Action.Types
import Kanban.Domain (PullRequest (..), RepoSnapshot, Repository, WorkflowConfig)
import Kanban.Solve (SolveOutcome (..), SolveWorkflow (..), SolverBrand)
import Kanban.UI.AutoSolve
  ( AutoSolveCompletion (..),
    AutoSolveDecision (..),
    AutoSolveHalt (..),
    AutoSolveObservation (..),
    AutoSolveRevision (..),
    autoSolveAfterCompletion,
    autoSolveCompleted,
    autoSolveRevisionTurn,
    autoSolveStopped,
    decideAutoSolve,
  )
import Kanban.UI.Types (AutoSolveProgress (..), AutoSolveStage (..), SolvePhase (..))
import Kanban.Worker
  ( PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerDescriptor (..),
    WorkerParent (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    WorkerTask (..),
    discoverWorkers,
    readWorkerState,
  )

-- | One autosolve action in flight.
--
-- The solver descriptor changes as the loop resumes the original provider for
-- a revision; the reviewer descriptor is cleared when it does, so the next
-- round starts a fresh review rather than reading the previous round's record.
data AutoSolveState = AutoSolveState
  { autoSolveActionTarget :: ResolvedTarget,
    autoSolveActionAttribution :: ActionAttribution,
    autoSolveActionProgress :: AutoSolveProgress,
    autoSolveActionSolver :: WorkerDescriptor,
    autoSolveActionReviewer :: Maybe WorkerDescriptor
  }

-- | The two things this loop does to the world, injected.
--
-- The same seam, and the same reason, as 'Kanban.Worker.runWorkerWithTask'
-- taking its task: the progression is what has to be exercised, and a suite
-- process cannot spawn a real detached supervisor of its own. Production
-- passes 'liveAutoSolveTurns', which is the registry's own dispatch and the
-- real durable-state read.
data AutoSolveTurns = AutoSolveTurns
  { turnDispatch :: ActionEnvironment -> ActionRequest -> IO (Either ActionRefusal ActionHandle),
    turnWorkerState :: WorkerDescriptor -> IO (Either Text WorkerState)
  }

liveAutoSolveTurns :: AutoSolveTurns
liveAutoSolveTurns = AutoSolveTurns dispatchAction readWorkerState

-- | How a headless caller supplies fresh evidence and paces the loop.
--
-- The refresh is the caller's because the registry adds no read authority of
-- its own, and it runs before every tick because a verdict is only as current
-- as the read it was validated against.
data AutoSolveDriver = AutoSolveDriver
  { driverRefresh :: IO (Either Text RepoSnapshot),
    driverHistory :: CatalogHistory,
    driverWait :: IO (),
    -- | A bound on ticks, so a loop whose provider never settles ends rather
    -- than running forever.
    driverSteps :: Int
  }

-- | The state a freshly dispatched autosolve handle starts in.
autoSolveStateFor :: ActionHandle -> Maybe AutoSolveState
autoSolveStateFor (AutoSolveActionHandle target descriptor attribution) =
  Just
    AutoSolveState
      { autoSolveActionTarget = target,
        autoSolveActionAttribution = attribution,
        autoSolveActionProgress =
          AutoSolveProgress
            { autoSolveStage = AutoImplementing,
              autoSolvePullRequest = Nothing,
              autoSolveReviewRound = 0,
              autoSolveKnownPullRequests = attribution.attributionKnownPullRequests,
              autoSolveStartedAt = attribution.attributionStartedAt
            },
        autoSolveActionSolver = descriptor,
        autoSolveActionReviewer = Nothing
      }
autoSolveStateFor _ = Nothing

-- | The dashboard's session phase, as a worker's durable status reports it.
--
-- The mapping exists because 'Kanban.UI.AutoSolve.decideAutoSolve' reads a
-- 'SolvePhase' and a headless tick has only a 'WorkerStatus'. An orphaned
-- worker is reported as orphaned rather than finished: its outcome is
-- committed but its descendants are not verified gone, and the loop must not
-- read that as a completed review.
reviewPhaseForWorker :: WorkerStatus -> SolvePhase
reviewPhaseForWorker status = case status of
  WorkerStarting -> SolveStarting
  WorkerRunning -> SolveRunning
  WorkerOrphaned _ -> SolveOrphanedPhase
  WorkerTerminal SolveCompleted -> SolveFinished
  WorkerTerminal (SolveNeedsInput _) -> SolveAttention
  WorkerTerminal (SolveFailed _) -> SolveFailedPhase

-- | The phase a bound reviewer's durable record reports.
--
-- Fails closed on the read, exactly as 'workerStatusIsLive' does, and for a
-- sharper reason: 'Kanban.UI.AutoSolve.decideAutoSolve' reads an /absent/
-- review phase as "no review has been started" and answers it by starting
-- one. A record that merely could not be read -- a worker that has not
-- written its state yet, a transient read failure -- would therefore launch a
-- second reviewer beside the first. Reporting it as a starting review is what
-- makes the loop wait instead; "no reviewer at all" stays the caller's own
-- 'Nothing', which only holds when no review worker is bound.
reviewPhaseForRecord :: Either Text WorkerState -> SolvePhase
reviewPhaseForRecord (Left _) = SolveStarting
reviewPhaseForRecord (Right recorded) = reviewPhaseForWorker recorded.workerStateStatus

-- | Whether a recorded worker still owns live work.
--
-- Fails closed on both edges: a state file that could not be read is treated
-- as live rather than gone, and an orphaned worker counts as live because its
-- descendants are not verified absent. Either mistake in the other direction
-- would launch a second provider turn beside a running one.
workerStatusIsLive :: Either Text WorkerState -> Bool
workerStatusIsLive (Left _) = True
workerStatusIsLive (Right state) = case state.workerStateStatus of
  WorkerStarting -> True
  WorkerRunning -> True
  WorkerOrphaned _ -> True
  WorkerTerminal _ -> False

-- | Advance one autosolve action by one tick.
--
-- 'Left' is terminal and ends the action; 'Right' carries the loop forward.
advanceAutoSolveAction :: AutoSolveTurns -> ActionEnvironment -> AutoSolveState -> IO (Either ActionOutcome AutoSolveState)
advanceAutoSolveAction turns environment state = do
  solverState <- turns.turnWorkerState state.autoSolveActionSolver
  reviewerState <- traverse turns.turnWorkerState state.autoSolveActionReviewer
  let solverSession = either (const Nothing) (.workerStateSessionId) solverState
      solverLogPath = either (const Nothing) (.workerStateLogPath) solverState
      solverLive = workerStatusIsLive solverState
      reviewPhase = reviewPhaseForRecord <$> reviewerState
      solverStatus = either (const Nothing) (Just . (.workerStateStatus)) solverState
      reviewerStatus = reviewerState >>= either (const Nothing) (Just . (.workerStateStatus))
  case settledReviewTurn reviewerStatus of
    Just outcome -> pure (Left outcome)
    Nothing -> case settledSolverTurn state.autoSolveActionProgress solverStatus of
      Just (Left outcome) -> pure (Left outcome)
      Just (Right advanced) -> decide advanced solverSession solverLogPath solverLive reviewPhase
      Nothing -> decide state.autoSolveActionProgress solverSession solverLogPath solverLive reviewPhase
  where
    issueNumber = state.autoSolveActionTarget.resolvedTargetNumber
    brand = state.autoSolveActionAttribution.attributionSolverBrand
    identity = catalogIdentity environment.actionCatalog

    decide progress solverSession solverLogPath solverLive reviewPhase =
      case tick.tickMove of
        AutoSolveHold _ -> pure (Right state {autoSolveActionProgress = tick.tickProgress})
        AutoSolveReviewRound number _ -> startReview tick.tickProgress solverSession solverLogPath number
        AutoSolveRevisionRound _ turn -> resumeSolver tick.tickProgress solverSession solverLogPath turn
        AutoSolveConcluded conclusion -> pure (Left (autoSolveConclusionOutcome conclusion))
      where
        tick =
          autoSolveTick
            environment.actionWorkflowConfig
            environment.actionConfigPath
            environment.actionRepository
            observation
            progress
        observation =
          AutoSolveObservation
            { autoSolveIssueNumber = issueNumber,
              autoSolveWorkflowConfig = environment.actionWorkflowConfig,
              autoSolveSolverBrand = brand,
              autoSolveSolverSession = solverSession,
              autoSolveSolverRunning = solverLive,
              autoSolveSnapshotPullRequests = environment.actionCatalog.catalogPullRequests,
              autoSolveReviewPhase = reviewPhase
            }

    -- The label-derived verb, never the @r@ key's. A problem status on the
    -- pull request this loop is reviewing must not silently become a repair
    -- launch.
    startReview progress solverSession solverLogPath number =
      case find ((== number) . (.pullRequestNumber)) environment.actionCatalog.catalogPullRequests of
        Nothing ->
          pure (Left (ActionStopped ("PR #" <> showNumber number <> " left the read before its review started")))
        Just pullRequest -> do
          let kind = workflowActionKindForLabelledPullRequest environment.actionWorkflowConfig pullRequest
          dispatched <-
            turns.turnDispatch
              environment
              (actionRequest kind identity (TargetByKind ActionTargetPullRequest number))
                { requestParent = Just (parentFor progress solverSession solverLogPath)
                }
          pure $ case dispatched of
            Left refusal -> Left (ActionStopped (actionRefusalMessage refusal))
            Right handle ->
              Right
                state
                  { autoSolveActionProgress = progress,
                    autoSolveActionReviewer = actionHandleWorker handle
                  }

    -- The turn is 'Kanban.UI.AutoSolve.autoSolveRevisionTurn''s, which the
    -- dashboard's own revision arm also starts: the session to resume, the
    -- provenance, and the prompt are one construction rather than this
    -- module's and the adapter's.
    resumeSolver progress solverSession solverLogPath turn = do
      dispatched <-
        turns.turnDispatch
          environment
          (actionRequest AutoSolveIssue identity (TargetByKind ActionTargetIssue issueNumber))
            { requestSolverBrand = Just brand,
              requestRecordedAssignment = state.autoSolveActionSolver.workerDescriptorSpec.workerAssignment,
              requestExistingSession = Just turn.autoSolveRevisionSession,
              requestExistingLogPath = solverLogPath,
              requestResumeProvenance = turn.autoSolveRevisionProvenance,
              requestUserMessage = turn.autoSolveRevisionMessage,
              requestParent = Just (parentFor progress solverSession solverLogPath)
            }
      pure $ case dispatched of
        Left refusal -> Left (ActionStopped (actionRefusalMessage refusal))
        Right handle -> case actionHandleWorker handle of
          Nothing -> Left (ActionStopped "the resumed solver left no durable worker")
          Just descriptor ->
            Right
              state
                { autoSolveActionProgress = progress,
                  autoSolveActionSolver = descriptor,
                  autoSolveActionReviewer = Nothing
                }

    -- Every field describes the /solver/, which is what makes a restarted
    -- dashboard able to restore this loop: the round tells an implementation
    -- run from a revision, and the recorded start and known pull requests are
    -- what keep discovery from binding a pull request this run did not open.
    parentFor progress solverSession solverLogPath =
      WorkerParent
        { workerParentIssueNumber = issueNumber,
          workerParentReviewRound = progress.autoSolveReviewRound,
          workerParentSolverBrand = brand,
          workerParentSolverSession = solverSession,
          workerParentSolverLogPath = solverLogPath,
          workerParentStartedAt = progress.autoSolveStartedAt,
          workerParentKnownPullRequests = progress.autoSolveKnownPullRequests,
          workerParentSolverAssignment = state.autoSolveActionSolver.workerDescriptorSpec.workerAssignment
        }

-- | What one observation of an autosolve session does next, for either
-- surface.
--
-- This is the whole of the loop's move: the progress it advances to, the
-- single provider turn that move starts, the activity a surface shows while
-- it waits, and the conclusion that ends the action. The dashboard's refresh
-- adapter and the plain-IO loop both take their move from here and then only
-- render or dispatch it, so the progression has one owner rather than two
-- implementations that agree today.
--
-- The decision inside is 'Kanban.UI.AutoSolve.decideAutoSolve''s, unchanged.
-- What this adds is the reading of it neither surface should own: which
-- progress each arm advances to, and the revision turn an arm asks for.
data AutoSolveTick = AutoSolveTick
  { tickProgress :: AutoSolveProgress,
    tickMove :: AutoSolveMove
  }
  deriving stock (Eq, Show)

data AutoSolveMove
  = -- | Nothing to start. The text is the activity line, when the decision
    -- named one.
    AutoSolveHold (Maybe Text)
  | -- | Start a review round for this pull request. 'True' when /this/
    -- observation is what bound it, which is the only case a surface
    -- announces.
    AutoSolveReviewRound Int Bool
  | -- | Resume the original solver against a changes-requested verdict.
    AutoSolveRevisionRound Int AutoSolveRevision
  | AutoSolveConcluded AutoSolveConclusion
  deriving stock (Eq, Show)

-- | How the action ended. Closed and small on purpose: these are the only
-- three endings a decision produces, so neither surface has to be total over
-- outcomes it can never see.
data AutoSolveConclusion
  = AutoSolveConcludedApproved Int
  | AutoSolveConcludedHalted AutoSolveHalt Text
  deriving stock (Eq, Show)

autoSolveConclusionOutcome :: AutoSolveConclusion -> ActionOutcome
autoSolveConclusionOutcome (AutoSolveConcludedApproved number) = ActionPullRequestApproved number
autoSolveConclusionOutcome (AutoSolveConcludedHalted AutoSolveHaltStopped reason) = ActionStopped reason
autoSolveConclusionOutcome (AutoSolveConcludedHalted AutoSolveHaltFailed reason) = ActionFailed reason

-- | Read one autosolve decision as the move it is.
autoSolveTick :: WorkflowConfig -> Maybe FilePath -> Repository -> AutoSolveObservation -> AutoSolveProgress -> AutoSolveTick
autoSolveTick config configPath repository observation progress =
  case decideAutoSolve observation progress of
    AutoSolveWait -> AutoSolveTick progress (AutoSolveHold Nothing)
    AutoSolveWaitingOn activity -> AutoSolveTick progress (AutoSolveHold (Just activity))
    AutoSolveStartReview number -> AutoSolveTick progress (AutoSolveReviewRound number False)
    AutoSolveOpenReview number advanced -> AutoSolveTick advanced (AutoSolveReviewRound number True)
    AutoSolveRevise number advanced ->
      case autoSolveRevisionTurn
        config
        configPath
        repository
        observation.autoSolveSolverBrand
        observation.autoSolveSolverSession
        number
        advanced.autoSolveReviewRound of
        -- Unreachable: 'decideRevision' halts on a missing session id before
        -- it ever asks for a revision. Stated rather than defaulted, so a
        -- caller that arrived without one starts nothing.
        Nothing ->
          AutoSolveTick
            progress
            ( AutoSolveConcluded
                (AutoSolveConcludedHalted AutoSolveHaltStopped "the original solver did not return a resumable session id")
            )
        Just turn -> AutoSolveTick advanced (AutoSolveRevisionRound number turn)
    AutoSolveApprove number ->
      AutoSolveTick (autoSolveCompleted progress) (AutoSolveConcluded (AutoSolveConcludedApproved number))
    AutoSolveHalted halt reason ->
      AutoSolveTick (autoSolveStopped progress) (AutoSolveConcluded (AutoSolveConcludedHalted halt reason))

-- | What a settled /review/ turn does to a headless action.
--
-- A reviewer that stopped to ask a question is where the two surfaces
-- legitimately differ, and the difference has to be said rather than
-- inherited. On the dashboard 'Kanban.UI.AutoSolve.decideAutoSolve' reports
-- it as an activity and waits, because a person is sitting in front of the
-- session and can answer. Headlessly nobody is, so waiting would spend the
-- observation budget and end as a budget stop -- a result that says nothing
-- about why the run halted. This ends the action with the provider's own
-- question instead, which is a typed outcome a caller can act on.
--
-- Only the question. A failed or killed reviewer already reaches
-- 'AutoSolveHalted' through the decision, and a running one is not settled.
settledReviewTurn :: Maybe WorkerStatus -> Maybe ActionOutcome
settledReviewTurn (Just (WorkerTerminal (SolveNeedsInput detail))) = Just (ActionNeedsInput detail)
settledReviewTurn _ = Nothing

-- | The registry state for an autosolve action already under way, rebuilt
-- from the durable records the run left behind.
--
-- What a dashboard press launched and what a headless runner drives are one
-- action in one state model rather than two implementations of one: the
-- solver's own worker is found by the issue it names, the parent record a
-- review worker carries supplies the round, the run's start, and the pull
-- requests discovery must not bind, and that review worker /is/ the round
-- already in flight. A runner taking an action over here therefore reads
-- exactly the records the sequential-turn guards read, so it cannot start a
-- turn the dashboard has already started.
--
-- 'Nothing' when no autosolve solver worker for this issue is discoverable at
-- all, which is the only honest answer: an action with no durable solver turn
-- is one this registry has nothing to take over.
autoSolveStateFromWorkers :: ResolvedTarget -> Set Int -> [WorkerDescriptor] -> Maybe AutoSolveState
autoSolveStateFromWorkers target boardPullRequests descriptors = do
  solver <- lastOf [descriptor | descriptor <- descriptors, isAutoSolveFor issueNumber descriptor]
  brand <- solverBrandOf solver
  let reviewer =
        lastOf [descriptor | descriptor <- descriptors, isReviewFor issueNumber descriptor]
      parent = reviewer >>= (.workerDescriptorSpec.workerParent)
      -- A solver created no earlier than the review worker is a revision the
      -- loop has already moved on to, so that review is history rather than
      -- the turn in flight.
      solverIsCurrent =
        maybe
          True
          (\held -> solver.workerDescriptorSpec.workerCreatedAt >= held.workerDescriptorSpec.workerCreatedAt)
          reviewer
      reviewRound = maybe 0 (.workerParentReviewRound) parent
      stage
        | solverIsCurrent && reviewRound == 0 = AutoImplementing
        | solverIsCurrent = AutoRevising
        | otherwise = AutoReviewing
  pure
    AutoSolveState
      { autoSolveActionTarget = target,
        autoSolveActionAttribution =
          ActionAttribution
            { attributionKnownPullRequests = maybe boardPullRequests (.workerParentKnownPullRequests) parent,
              attributionStartedAt = maybe solver.workerDescriptorSpec.workerCreatedAt (.workerParentStartedAt) parent,
              attributionSolverBrand = brand
            },
        autoSolveActionProgress =
          AutoSolveProgress
            { autoSolveStage = stage,
              autoSolvePullRequest = if solverIsCurrent then Nothing else reviewer >>= reviewNumberOf,
              autoSolveReviewRound = reviewRound,
              autoSolveKnownPullRequests = maybe boardPullRequests (.workerParentKnownPullRequests) parent,
              autoSolveStartedAt = maybe solver.workerDescriptorSpec.workerCreatedAt (.workerParentStartedAt) parent
            },
        autoSolveActionSolver = solver,
        autoSolveActionReviewer = if solverIsCurrent then Nothing else reviewer
      }
  where
    issueNumber = target.resolvedTargetNumber
    lastOf values = listToMaybe (reverse values)

isAutoSolveFor :: Int -> WorkerDescriptor -> Bool
isAutoSolveFor issueNumber descriptor = case descriptor.workerDescriptorSpec.workerTask of
  SolveWorkerTaskKind task ->
    task.solveWorkerIssueNumber == issueNumber && task.solveWorkerWorkflow == AutoSolve
  PullRequestWorkerTaskKind _ -> False

isReviewFor :: Int -> WorkerDescriptor -> Bool
isReviewFor issueNumber descriptor = case descriptor.workerDescriptorSpec.workerTask of
  PullRequestWorkerTaskKind _ ->
    ((.workerParentIssueNumber) <$> descriptor.workerDescriptorSpec.workerParent) == Just issueNumber
  SolveWorkerTaskKind _ -> False

reviewNumberOf :: WorkerDescriptor -> Maybe Int
reviewNumberOf descriptor = case descriptor.workerDescriptorSpec.workerTask of
  PullRequestWorkerTaskKind task -> Just task.pullRequestWorkerNumber
  SolveWorkerTaskKind _ -> Nothing

solverBrandOf :: WorkerDescriptor -> Maybe SolverBrand
solverBrandOf descriptor = case descriptor.workerDescriptorSpec.workerTask of
  SolveWorkerTaskKind task -> Just task.solveWorkerBrand
  PullRequestWorkerTaskKind _ -> Nothing

-- | 'autoSolveStateFromWorkers' over this repository's discoverable workers.
recoverAutoSolveState :: Repository -> ResolvedTarget -> Set Int -> IO (Maybe AutoSolveState)
recoverAutoSolveState repository target boardPullRequests =
  autoSolveStateFromWorkers target boardPullRequests <$> discoverWorkers repository

-- | What a settled solver turn does to the loop.
--
-- 'Nothing' when the loop is not on a stage a solver turn drives, so the
-- decision runs unchanged. The two failing outcomes end the action: there is
-- no round to advance to and no evidence to validate.
settledSolverTurn :: AutoSolveProgress -> Maybe WorkerStatus -> Maybe (Either ActionOutcome AutoSolveProgress)
settledSolverTurn progress status
  | progress.autoSolveStage `notElem` [AutoImplementing, AutoRevising] = Nothing
  | otherwise = case status of
      Just (WorkerTerminal SolveCompleted) ->
        Right . (.autoSolveCompletionProgress) <$> autoSolveAfterCompletion progress
      Just (WorkerTerminal (SolveNeedsInput detail)) -> Just (Left (ActionNeedsInput detail))
      Just (WorkerTerminal (SolveFailed detail)) -> Just (Left (ActionFailed detail))
      _ -> Nothing

-- | A dispatched autosolve action, holding the loop cursor its observations
-- advance.
--
-- Autosolve is the one registered action whose result cannot be read off the
-- turn it is currently holding, so observing it has to /progress/ it: a
-- caller polling the bare handle would see one turn after another and never
-- the approval that is this action's only success. This is what makes the
-- ordinary dispatch-then-observe path reach that approval.
--
-- The cursor is in memory rather than durable on purpose. What the loop is
-- doing is always recoverable from the worker records
-- ('recoverAutoSolveState'), and requirement 18 leaves persistence to the
-- mission store; this is the caller's place in a run, not a second record of
-- it.
data AutoSolveAction = AutoSolveAction
  { autoSolveActionTurns :: AutoSolveTurns,
    autoSolveActionCursor :: IORef AutoSolveState
  }

-- | Begin observing the action a dispatch just returned, or 'Nothing' when
-- that handle is not an autosolve one.
beginAutoSolveAction :: ActionHandle -> IO (Maybe AutoSolveAction)
beginAutoSolveAction handle = traverse (beginAutoSolveActionWith liveAutoSolveTurns) (autoSolveStateFor handle)

beginAutoSolveActionWith :: AutoSolveTurns -> AutoSolveState -> IO AutoSolveAction
beginAutoSolveActionWith turns state = AutoSolveAction turns <$> newIORef state

-- | Observe one autosolve action, advancing its loop by a tick.
--
-- 'ActionRunning' carries where the loop now is; 'ActionSettled' is the
-- action's validated result, which for a completed run is the approval of the
-- pull request it bound. The evidence comes from the catalog in the
-- environment, so a caller refreshes before observing exactly as
-- 'runAutoSolveAction' does.
observeAutoSolveAction :: ActionEnvironment -> AutoSolveAction -> IO ActionObservation
observeAutoSolveAction environment action = do
  state <- readIORef action.autoSolveActionCursor
  advanced <- advanceAutoSolveAction action.autoSolveActionTurns environment state
  case advanced of
    Left outcome -> pure (ActionSettled outcome)
    Right next -> do
      writeIORef action.autoSolveActionCursor next
      pure (ActionRunning (autoSolveActionActivity next))

-- | Where a running autosolve action currently is, in one line.
autoSolveActionActivity :: AutoSolveState -> Text
autoSolveActionActivity state = case state.autoSolveActionProgress.autoSolveStage of
  AutoImplementing -> "implementing"
  AutoDiscoveringPullRequest -> "discovering the pull request this run opened"
  AutoReviewing -> "reviewing PR" <> boundPullRequest
  AutoRevising -> "revising PR" <> boundPullRequest
  AutoAwaitingRereview -> "waiting for the rereview verdict on PR" <> boundPullRequest
  AutoSolveComplete -> "complete"
  AutoSolveStopped -> "stopped"
  where
    boundPullRequest = maybe "" ((" #" <>) . showNumber) state.autoSolveActionProgress.autoSolvePullRequest

-- | Drive one autosolve action to a terminal outcome.
runAutoSolveAction :: ActionEnvironment -> AutoSolveDriver -> AutoSolveState -> IO ActionOutcome
runAutoSolveAction = runAutoSolveActionWith liveAutoSolveTurns

runAutoSolveActionWith :: AutoSolveTurns -> ActionEnvironment -> AutoSolveDriver -> AutoSolveState -> IO ActionOutcome
runAutoSolveActionWith turns environment driver start = do
  action <- beginAutoSolveActionWith turns start
  loop driver.driverSteps action
  where
    loop remaining action
      | remaining <= 0 = pure (ActionStopped "the autosolve loop reached its observation budget")
      | otherwise = do
          refreshed <- driver.driverRefresh
          case refreshed of
            Left message -> pure (ActionFailed message)
            Right snapshot -> do
              let refreshedEnvironment =
                    environment
                      { actionCatalog =
                          catalogFromSnapshot environment.actionRepository snapshot driver.driverHistory
                      }
              observed <- observeAutoSolveAction refreshedEnvironment action
              case observed of
                ActionSettled outcome -> pure outcome
                ActionRunning _ -> driver.driverWait >> loop (remaining - 1) action

showNumber :: Int -> Text
showNumber = Text.pack . show
