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
    autoSolveCursorFor,
    autoSolveStateForWorker,
    initialAutoSolveState,
    autoSolveActionActivity,
    AutoSolveState (..),
    AutoSolveSolver (..),
    AutoSolveSolverRecord (..),
    autoSolveSolverWorker,
    autoSolveSolverAssignment,
    AutoSolveTurns (..),
    AutoSolveDriver (..),
    autoSolveStateFromWorkers,
    recoverAutoSolveState,
    reviewPhaseForRecord,
    reviewPhaseForWorker,
    settledReviewTurn,
    workerStatusIsLive,
    advanceAutoSolveAction,
    runAutoSolveActionWith,
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Data.List (find)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Action.Target (workflowActionKindForLabelledPullRequest)
import Kanban.Cache (normalizedRepositoryIdentity)
import Kanban.Action.Types
import Kanban.Domain (PullRequest (..), RepoSnapshot, Repository, WorkflowConfig)
import Kanban.Models (RecordedAssignment)
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
    recoveredAutoSolveProgress,
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
    autoSolveActionSolver :: AutoSolveSolver,
    autoSolveActionReviewer :: Maybe WorkerDescriptor
  }

-- | The solver turn a loop is waiting on, or would resume.
--
-- Two shapes, because the first one does not survive the loop's own progress.
-- Starting a review round acknowledges the solver that opened the pull
-- request, and an acknowledged terminal worker superseded by a newer one is
-- what the worker cache collects: its specification, state, and journal are
-- removed. A loop that needed that descriptor could therefore never be taken
-- over after its first review round began -- which is most of a run.
--
-- What survives is the parent record the review worker carries, and it exists
-- for exactly this: every field of 'WorkerParent' describes the /solver/ that
-- launched the review rather than the review itself. So a solver whose worker
-- is gone is still nameable, resumable, and answerable for.
data AutoSolveSolver
  = AutoSolveSolverWorker WorkerDescriptor
  | AutoSolveSolverRecorded AutoSolveSolverRecord
  deriving stock (Eq, Show)

-- | What a collected solver's parent record still says about it: the session a
-- revision resumes, the log that revision appends to, and the cell it replays.
data AutoSolveSolverRecord = AutoSolveSolverRecord
  { recordedSolverSession :: Maybe Text,
    recordedSolverLogPath :: Maybe FilePath,
    recordedSolverAssignment :: Maybe RecordedAssignment
  }
  deriving stock (Eq, Show)

autoSolveSolverWorker :: AutoSolveSolver -> Maybe WorkerDescriptor
autoSolveSolverWorker (AutoSolveSolverWorker descriptor) = Just descriptor
autoSolveSolverWorker (AutoSolveSolverRecorded _) = Nothing

autoSolveSolverAssignment :: AutoSolveSolver -> Maybe RecordedAssignment
autoSolveSolverAssignment (AutoSolveSolverWorker descriptor) =
  descriptor.workerDescriptorSpec.workerAssignment
autoSolveSolverAssignment (AutoSolveSolverRecorded record) = record.recordedSolverAssignment

solverRecordFromParent :: Maybe WorkerParent -> AutoSolveSolverRecord
solverRecordFromParent parent =
  AutoSolveSolverRecord
    { recordedSolverSession = parent >>= (.workerParentSolverSession),
      recordedSolverLogPath = parent >>= (.workerParentSolverLogPath),
      recordedSolverAssignment = parent >>= (.workerParentSolverAssignment)
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

-- | The loop state an autosolve worker is in, from its own durable record.
--
-- Used for every autosolve handle, launched or joined, because the two are
-- the same question asked of the same record. A worker this dispatch started
-- carries a parent recording round zero and no bound pull request, which is
-- the opening state; a worker it /joined/ may be a revision three rounds in,
-- and its parent says so.
--
-- Building the opening state unconditionally is what would break the second
-- case: a handle joined to a running revision would be reset to
-- \'AutoImplementing\' with nothing bound, and once that revision finished it
-- would go back to discovering a pull request instead of waiting for the
-- canonical rereview verdict on the one the run already has.
autoSolveStateForWorker :: ResolvedTarget -> WorkerDescriptor -> ActionAttribution -> AutoSolveState
autoSolveStateForWorker target descriptor attribution =
  (initialAutoSolveState target descriptor attribution)
    { autoSolveActionProgress =
        fromMaybe
          (initialAutoSolveState target descriptor attribution).autoSolveActionProgress
          ( recoveredAutoSolveProgress
              AutoSolve
              descriptor.workerDescriptorSpec.workerParent
              attribution.attributionKnownPullRequests
              descriptor.workerDescriptorSpec.workerCreatedAt
          )
    }

-- | The state a worker with no durable parent record starts in: the opening
-- turn of a fresh run.
initialAutoSolveState :: ResolvedTarget -> WorkerDescriptor -> ActionAttribution -> AutoSolveState
initialAutoSolveState target descriptor attribution =
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
      autoSolveActionSolver = AutoSolveSolverWorker descriptor,
      autoSolveActionReviewer = Nothing
    }

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
advanceAutoSolveAction turns environment state
  -- The evidence this tick decides from, and the repository its next turn
  -- would be started in, are both this environment's. Advancing a run against
  -- another repository's would bind whatever happens to share its numbers
  -- over there, so a mismatched environment ends the action rather than
  -- acting on it.
  | Left refusal <- checkTargetRepository identity (ActionTargetItem state.autoSolveActionTarget) =
      pure (Left (ActionFailed (actionRefusalMessage refusal)))
  | otherwise = advanceCheckedAutoSolveAction turns environment state
  where
    identity = normalizedRepositoryIdentity environment.actionRepository

advanceCheckedAutoSolveAction :: AutoSolveTurns -> ActionEnvironment -> AutoSolveState -> IO (Either ActionOutcome AutoSolveState)
advanceCheckedAutoSolveAction turns environment state = do
  solverState <- traverse turns.turnWorkerState (autoSolveSolverWorker state.autoSolveActionSolver)
  reviewerState <- traverse turns.turnWorkerState state.autoSolveActionReviewer
  let recorded = case state.autoSolveActionSolver of
        AutoSolveSolverWorker _ -> solverRecordFromParent Nothing
        AutoSolveSolverRecorded held -> held
      readSolver = solverState >>= either (const Nothing) Just
      solverSession = maybe recorded.recordedSolverSession Just (readSolver >>= (.workerStateSessionId))
      solverLogPath = maybe recorded.recordedSolverLogPath Just (readSolver >>= (.workerStateLogPath))
      -- A solver with no worker left is provably finished rather than
      -- unknown: only a terminal worker is acknowledged, and only an
      -- acknowledged one superseded by a newer worker is collected. An
      -- unreadable /live/ descriptor still fails closed onto live.
      solverLive = maybe False workerStatusIsLive solverState
      reviewPhase = reviewPhaseForRecord <$> reviewerState
      solverStatus = (.workerStateStatus) <$> readSolver
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
              requestRecordedAssignment = autoSolveSolverAssignment state.autoSolveActionSolver,
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
                  autoSolveActionSolver = AutoSolveSolverWorker descriptor,
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
          workerParentPullRequest = progress.autoSolvePullRequest,
          workerParentSolverAssignment = autoSolveSolverAssignment state.autoSolveActionSolver
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
autoSolveStateFromWorkers target boardPullRequests descriptors =
  case (solver, reviewer) of
    (Just held, _) -> fromSolver held
    -- No solver worker left, but a review round in flight. This is the
    -- ordinary shape of a dashboard-launched run, not an edge: starting the
    -- review acknowledges the finished solver, and the cache collects an
    -- acknowledged worker a newer one supersedes. Everything the loop needs
    -- about that solver is on the review worker's parent record, which is
    -- what that record is for.
    (Nothing, Just held) -> fromReviewer held
    (Nothing, Nothing) -> Nothing
  where
    issueNumber = target.resolvedTargetNumber
    lastOf values = listToMaybe (reverse values)
    solver = lastOf [descriptor | descriptor <- descriptors, isAutoSolveFor issueNumber descriptor]
    reviewer = lastOf [descriptor | descriptor <- descriptors, isReviewFor issueNumber descriptor]

    fromReviewer held = do
      let parent = held.workerDescriptorSpec.workerParent
      brand <- (.workerParentSolverBrand) <$> parent
      pure
        (assemble
           brand
           (AutoSolveSolverRecorded (solverRecordFromParent parent))
           (Just held)
           AutoReviewing
           (maybe 0 (.workerParentReviewRound) parent)
           (maybe boardPullRequests (.workerParentKnownPullRequests) parent)
           (maybe held.workerDescriptorSpec.workerCreatedAt (.workerParentStartedAt) parent)
           (maybe (reviewNumberOf held) Just (parent >>= (.workerParentPullRequest))))

    fromSolver held = do
      brand <- solverBrandOf held
      let solverParent = held.workerDescriptorSpec.workerParent
          reviewerParent = reviewer >>= (.workerDescriptorSpec.workerParent)
          -- A solver created no earlier than the review worker is a revision
          -- the loop has already moved on to, so that review round is history
          -- rather than the turn in flight. The pull request it reviewed is
          -- /not/ history: it is what the whole loop is looping over, and a
          -- revision is the loop still working on it.
          solverIsCurrent =
            maybe
              True
              (\other -> held.workerDescriptorSpec.workerCreatedAt >= other.workerDescriptorSpec.workerCreatedAt)
              reviewer
          -- The run's baseline is on its own solver's record. A review
          -- worker's parent describes that same solver, so it is the fallback
          -- for a run whose solver was launched before this release recorded
          -- one.
          baseline = maybe reviewerParent Just solverParent
          -- The round belongs to whichever turn is in flight, falling back to
          -- the other record.
          currentParent = maybe baseline Just (if solverIsCurrent then solverParent else reviewerParent)
          -- Read from the solver's own record first: a revision the loop
          -- resumed records the pull request it is revising, which is the only
          -- place a run recovered mid-revision can learn it once its review
          -- worker is history.
          bound = maybe (reviewer >>= reviewNumberOf) Just (solverParent >>= (.workerParentPullRequest))
          reviewRound = maybe 0 (.workerParentReviewRound) currentParent
          stage
            | solverIsCurrent && reviewRound == 0 = AutoImplementing
            | solverIsCurrent = AutoRevising
            | otherwise = AutoReviewing
      pure
        (assemble
           brand
           (AutoSolveSolverWorker held)
           (if solverIsCurrent then Nothing else reviewer)
           stage
           reviewRound
           (maybe boardPullRequests (.workerParentKnownPullRequests) baseline)
           (maybe held.workerDescriptorSpec.workerCreatedAt (.workerParentStartedAt) baseline)
           bound)

    assemble brand solverIdentity reviewerDescriptor stage reviewRound known startedAt bound =
      AutoSolveState
        { autoSolveActionTarget = target,
          autoSolveActionAttribution =
            ActionAttribution
              { attributionKnownPullRequests = known,
                attributionStartedAt = startedAt,
                attributionSolverBrand = brand
              },
          autoSolveActionProgress =
            AutoSolveProgress
              { autoSolveStage = stage,
                autoSolvePullRequest = bound,
                autoSolveReviewRound = reviewRound,
                autoSolveKnownPullRequests = known,
                autoSolveStartedAt = startedAt
              },
          autoSolveActionSolver = solverIdentity,
          autoSolveActionReviewer = reviewerDescriptor
        }

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

-- | The cursor a dispatched autosolve action's handle carries.
--
-- Each advance is one tick of the loop: it reads where the action is, moves it
-- on, and reports 'ActionRunning' with where it now is or 'ActionSettled' with
-- the action's validated result -- for a completed run, the approval of the
-- pull request it bound. That is what makes the ordinary
-- dispatch-then-observe path reach that approval rather than stalling on the
-- provider turn in flight.
--
-- The turns are injected for the same reason
-- 'Kanban.Worker.runWorkerWithTask' takes its task: a suite process cannot
-- spawn a real detached supervisor, and the progression is what has to be
-- exercised. Production passes the registry's own dispatch.
autoSolveCursorFor :: AutoSolveTurns -> AutoSolveState -> IO AutoSolveCursor
autoSolveCursorFor turns start = do
  cursor <- newMVar start
  pure (AutoSolveCursor (advanceOnce turns cursor))

-- | One tick, under the lock the cursor is.
--
-- The whole read-decide-start-write sequence is held, not just the write. Two
-- observations of one action that each read the same state would each see a
-- solve that had just finished, each bind the pull request it opened, and each
-- start a review round for it -- two provider turns for one action, which is
-- exactly what requirement 12's sequential guarantee forbids. Holding the
-- cursor across the dispatch is what makes the second observation decide from
-- the first one's result instead.
--
-- A settled action leaves the cursor where it was: the outcome was derived
-- from evidence rather than from the cursor, so observing it again re-derives
-- the same answer rather than advancing past it.
advanceOnce :: AutoSolveTurns -> MVar AutoSolveState -> ActionEnvironment -> IO ActionObservation
advanceOnce turns cursor environment =
  modifyMVar cursor $ \state -> do
    advanced <- advanceAutoSolveAction turns environment state
    pure $ case advanced of
      Left outcome -> (state, ActionSettled outcome)
      Right next -> (next, ActionRunning (autoSolveActionActivity next))

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

runAutoSolveActionWith :: AutoSolveTurns -> ActionEnvironment -> AutoSolveDriver -> AutoSolveState -> IO ActionOutcome
runAutoSolveActionWith turns environment driver start = do
  cursor <- autoSolveCursorFor turns start
  loop driver.driverSteps cursor
  where
    loop remaining cursor
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
              observed <- advanceAutoSolveCursor cursor refreshedEnvironment
              case observed of
                ActionSettled outcome -> pure outcome
                ActionRunning _ -> driver.driverWait >> loop (remaining - 1) cursor

showNumber :: Int -> Text
showNumber = Text.pack . show
