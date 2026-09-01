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
  ( AutoSolveState (..),
    AutoSolveTurns (..),
    liveAutoSolveTurns,
    AutoSolveDriver (..),
    autoSolveStateFor,
    autoSolveStateFromWorkers,
    recoverAutoSolveState,
    reviewPhaseForWorker,
    settledReviewTurn,
    workerStatusIsLive,
    advanceAutoSolveAction,
    runAutoSolveAction,
    runAutoSolveActionWith,
  )
where

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
import Kanban.Domain (PullRequest (..), RepoSnapshot, Repository)
import Kanban.Solve (SolveOutcome (..), SolveWorkflow (..), SolverBrand)
import Kanban.UI.AutoSolve
  ( AutoSolveCompletion (..),
    AutoSolveDecision (..),
    AutoSolveHalt (..),
    AutoSolveObservation (..),
    AutoSolveRevision (..),
    autoSolveAfterCompletion,
    autoSolveRevisionTurn,
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
      reviewPhase = reviewerState >>= either (const Nothing) (Just . reviewPhaseForWorker . (.workerStateStatus))
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
      case decideAutoSolve observation progress of
        AutoSolveWait -> pure (Right state {autoSolveActionProgress = progress})
        AutoSolveWaitingOn _ -> pure (Right state {autoSolveActionProgress = progress})
        AutoSolveStartReview number -> startReview progress solverSession solverLogPath number
        AutoSolveOpenReview number advanced -> startReview advanced solverSession solverLogPath number
        AutoSolveRevise number advanced -> resumeSolver advanced solverSession solverLogPath number
        AutoSolveApprove number -> pure (Left (ActionPullRequestApproved number))
        AutoSolveHalted AutoSolveHaltStopped reason -> pure (Left (ActionStopped reason))
        AutoSolveHalted AutoSolveHaltFailed reason -> pure (Left (ActionFailed reason))
      where
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
    resumeSolver progress solverSession solverLogPath number =
      case autoSolveRevisionTurn
        environment.actionWorkflowConfig
        environment.actionConfigPath
        environment.actionRepository
        brand
        solverSession
        number
        progress.autoSolveReviewRound of
        Nothing -> pure (Left (ActionStopped "the original solver did not return a resumable session id"))
        Just turn -> do
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

-- | Drive one autosolve action to a terminal outcome.
runAutoSolveAction :: ActionEnvironment -> AutoSolveDriver -> AutoSolveState -> IO ActionOutcome
runAutoSolveAction = runAutoSolveActionWith liveAutoSolveTurns

runAutoSolveActionWith :: AutoSolveTurns -> ActionEnvironment -> AutoSolveDriver -> AutoSolveState -> IO ActionOutcome
runAutoSolveActionWith turns environment driver = loop driver.driverSteps
  where
    loop remaining state
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
              advanced <- advanceAutoSolveAction turns refreshedEnvironment state
              case advanced of
                Left outcome -> pure outcome
                Right next -> driver.driverWait >> loop (remaining - 1) next

showNumber :: Int -> Text
showNumber = Text.pack . show
