{-# LANGUAGE DerivingStrategies #-}

-- | The foreground mission runner: @kanban --mission <id>@ (issue #595,
-- requirements 2, 3, and 10).
--
-- One named mission, advanced until it is terminal, paused, or blocked, and
-- then the process exits. It selects nothing: the identifier is an input, a
-- missing, malformed, unknown, or repository-mismatched one is refused by
-- name, and there is no path here that substitutes a different mission for the
-- one that was asked for. Choosing among a repository's missions is SAG-9's
-- work and deliberately absent from this module.
--
-- This is also where the plain-IO controller meets the real world. The live
-- driver below is built over the workflow action registry, the persistent
-- worker layer, and GitHub — so a mission's dispatch takes exactly the path a
-- board key press takes, through the same routing, the same readiness gate,
-- and the same spawn boundary. The registry adds no authority and neither does
-- this: a runner cannot merge, cannot apply a verdict label, and cannot
-- promote an indeterminate result (requirement 18).
--
-- /Waiting is local./ While a registered worker is live the loop reads that
-- worker's own durable state and this mission's files, and nothing else.
-- GitHub is read when a plan is made, immediately before an effect, and when a
-- step's worker has settled and its result has to be validated — never on the
-- timer. Automatic network polling is a non-goal (@docs\/design.md@ §3), and a
-- runner that refreshed the board every two seconds would be exactly that.
--
-- Reattachment is preferred to relaunching everywhere it is possible. A step
-- whose registered worker is still live is attached to rather than started
-- again; a step whose provider session is recorded resumes it; and only when
-- neither is available does a fresh session start, with the bounded recovery
-- brief "Kanban.Mission.Reconcile" derives from durable state alone.
--
-- This module is internal — "Kanban.Mission" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Mission.Runner
  ( MissionRunReport (..),
    missionRunReportLines,
    missionRunSucceeded,
    runMissionMode,
    MissionConsole (..),
    terminalMissionConsole,
    runMissionWith,
    liveMissionDriver,
    decidingWorkerReading,
    drainMissionConsoleWith,
    missionVersionOf,
    preconditionOf,
    missionRunnerPollMicros,
    missionRunnerIterationBudget,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Data.List (find)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (getCurrentTime)
import Kanban.Action
  ( ActionEnvironment (..),
    ActionObservation (..),
    ActionOutcome (..),
    ActionRefusal (..),
    ActionTarget (..),
    actionOutcomeMessage,
    actionOutcomeSucceeded,
    actionRefusalMessage,
    observableActionHandle,
    observeAction,
    resolveActionTarget,
    ActionHandle,
    ActionRequest (..),
    ActionTargetKind (..),
    ActionTargetRef (..),
    CatalogHistory (..),
    TargetCatalog (..),
    TargetPrecondition (..),
    targetPreconditionNumber,
    actionHandleWorker,
    actionKindDecodeErrorMessage,
    actionRequest,
    decodeWorkflowActionKind,
    dispatchAction,
    settledWorkerFailure,
  )
import Kanban.CLI (Options (..))
import Kanban.Config (ResolvedConfig (..), TimeoutsConfig (..))
import Kanban.Domain
  ( ItemId (..),
    Issue (..),
    Label (..),
    PullRequest (..),
    RepoSnapshot (..),
    Repository (..),
    WorkflowConfig (..),
  )
import Kanban.GitHub (GitHubResult (..), fetchGitHubSnapshot, newGhFetchGuard, newGhRecordLock)
import Kanban.GitHub.Precondition (observeTargetPrecondition)
import Kanban.Mission.Control (parseMissionConsoleCommand)
import Kanban.Mission.Controller
  ( MissionController (..),
    MissionDispatchAccepted (..),
    MissionDispatchRequest (..),
    MissionDriver (..),
    MissionInventory (..),
    MissionIteration (..),
    MissionStartRefusal,
    MissionTransition,
    missionControllerIteration,
    missionStartRefusalMessage,
    submitConsoleCommand,
    missionTransitionMessage,
    startMissionController,
    stopMissionController,
  )
import Kanban.Mission.Invocation (MissionInvocationId (..), MissionStaleVersion (..), MissionTargetVersion (..), missionStaleVersionMessage, missionVersionHolds)
import Kanban.Mission.Paths (openMissionStore)
import Kanban.Mission.Reconcile
  ( MissionContinuation (..),
    MissionHalt (..),
    MissionStepEvidence (..),
    MissionStepFailure (..),
    MissionWorkerConclusion (..),
    MissionWorkerReading (..),
    missionFailureFromOutcome,
    missionFailureFromProviderError,
    missionFailureFromRefusal,
    missionHaltMessage,
  )
import Kanban.Mission.Store (listMissions, recordMissionEvent)
import Kanban.Mission.Types
  ( MissionEvent (..),
    MissionId (..),
    MissionObservedOutcome (..),
    MissionPlanStep (..),
    MissionSessionId (..),
    MissionStepRecord (..),
    MissionTarget (..),
    MissionTargetKind (..),
    MissionTerminalObservation (..),
  )
import Kanban.Models (loadModelRoster)
import Kanban.Mission.Paths (MissionStore (..))
import Kanban.Solve (ResumeProvenance (..), SolveOutcome (..))
import Kanban.Worker
  ( IssueActionWorkerTask (..),
    PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerDeadline (..),
    WorkerDescriptor (..),
    WorkerId (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    WorkerTask (..),
    discoverWorkerHistory,
    readWorkerState,
    terminateWorker,
  )
import qualified Data.Text.IO as TextIO
import System.IO (Handle, hGetLine, hIsTerminalDevice, hReady, stdin, stdout)

-- | What one foreground run did, in the order it did it.
data MissionRunReport = MissionRunReport
  { missionRunMission :: MissionId,
    missionRunTransitions :: [MissionTransition],
    missionRunConclusion :: Either Text MissionHalt
  }
  deriving stock (Eq, Show)

-- | A halt is not a failure, whichever halt it is.
--
-- A mission that stopped for an answer did exactly what requirement 1 asks of
-- it. Only a run that could not read or write its own durable record, or that
-- ran out of iterations, is unsuccessful.
missionRunSucceeded :: MissionRunReport -> Bool
missionRunSucceeded report = case report.missionRunConclusion of
  Right _ -> True
  Left _ -> False

-- | The run, rendered for a terminal.
missionRunReportLines :: MissionRunReport -> [Text]
missionRunReportLines report =
  ("mission " <> report.missionRunMission.unMissionId)
    : map (("  " <>) . missionTransitionMessage) report.missionRunTransitions
      <> [ case report.missionRunConclusion of
             Right halt -> "  " <> missionHaltMessage halt
             Left detail -> "  stopped: " <> detail
         ]

-- | How long the runner waits when registered work is live and nothing else is
-- eligible.
--
-- Two seconds, which is the order of the persistent worker's own heartbeat.
-- What is polled is this machine — the worker's state file and this mission's
-- own records — and never GitHub, so the interval costs a few local reads and
-- no network traffic at all. The wait is bounded from the other end too: a
-- live child is bounded by the finite deadline its own specification recorded,
-- so this loop cannot outlive the work it is watching.
missionRunnerPollMicros :: Int
missionRunnerPollMicros = 2 * 1000 * 1000

-- | The most /transitions/ one foreground run will make.
--
-- A bound rather than a trust in progress: a controller that kept advancing
-- without ever reaching a halt would otherwise loop forever inside a process
-- that is explicitly not a daemon (§3). Reaching it is reported as a stop,
-- never as a mission outcome.
--
-- It deliberately does not count the passes that only wait. Those are bounded
-- from the other end — by the finite deadline the live worker's own
-- specification recorded — and counting them here would put a second, smaller
-- bound on the wait: at one pass every 'missionRunnerPollMicros' this budget
-- would give up after about five hours, which is already less than a
-- configured deadline is allowed to be, and the runner would abandon a worker
-- that was still inside the bound it was launched with.
missionRunnerIterationBudget :: Int
missionRunnerIterationBudget = 10000

-- | @kanban --mission <id>@, from the command line down.
--
-- Refuses before it claims anything: an identifier that cannot name a mission,
-- a mission this repository's store does not hold, an unreadable record, a
-- specification belonging to another repository, and a mission another
-- controller is already advancing are each reported as themselves, and none of
-- them resolves to a different mission.
runMissionMode :: Options -> ResolvedConfig -> Repository -> Text -> IO (Either Text MissionRunReport)
runMissionMode options config repository identifier
  | Text.null (Text.strip identifier) =
      pure (Left "--mission takes the identifier of exactly one mission")
  | otherwise = do
      opened <- openMissionStore repository
      case opened of
        Left detail -> pure (Left detail)
        Right store ->
          runMissionWith
            -- This process's own terminal is the authenticated console
            -- requirement 14 names. The console itself is what decides whether
            -- this handle qualifies; a redirected stdin is unauthenticated
            -- process input and is never read.
            (Just terminalMissionConsole)
            store
            repository
            (MissionId (Text.strip identifier))
            (liveMissionDriver options config repository)

-- | The operator's end of a run: where an authenticated line comes from, and
-- where this run says something back.
--
-- A record rather than a bare handle because a blocked mission has to be able
-- to /ask/. The run reports its transitions when it ends, which is exactly the
-- wrong moment for the one thing an operator must answer while it is still
-- going: a mission that reaches an unknown outcome can be resolved by
-- authenticated direction and by nothing else (requirement 7), and a durable
-- file command carries no such authority by design, so a run that exited
-- before saying it was stuck left the operator no way in at all.
data MissionConsole = MissionConsole
  { missionConsoleInput :: Handle,
    -- | Whether that handle is this process's own terminal. The seam a fixture
    -- uses; production supplies 'hIsTerminalDevice' and nothing else does.
    missionConsoleIsTerminal :: IO Bool,
    missionConsoleAnnounce :: Text -> IO ()
  }

-- | This process's terminal, which is the only console production has.
terminalMissionConsole :: MissionConsole
terminalMissionConsole =
  MissionConsole
    { missionConsoleInput = stdin,
      missionConsoleIsTerminal = hIsTerminalDevice stdin,
      missionConsoleAnnounce = TextIO.hPutStrLn stdout
    }

-- | What a blocked run does with the operator's answer.
data MissionDirection
  = -- | A line was taken and handed to the controller; carry on.
    MissionDirectionTaken
  | -- | Nothing more is coming — end of input, an unusable console, or the
    -- operator said so. The run ends on the halt it was already reporting.
    MissionDirectionEnded
  deriving stock (Eq, Show)

-- | The words that leave a blocked mission exactly as it is.
--
-- Spelled out rather than inferred from a parse failure, because \"I do not
-- want to answer this now\" and \"I typed that wrong\" are different answers and
-- only the first should end the run.
missionConsoleDetachWords :: [Text]
missionConsoleDetachWords = ["detach", "quit", "exit"]

-- | The loop, with the driver injected.
--
-- The seam a fixture uses: everything below this point is the controller's own
-- progression, and everything the driver does is the outside world.
runMissionWith :: Maybe MissionConsole -> MissionStore -> Repository -> MissionId -> (MissionStore -> MissionId -> IO MissionDriver) -> IO (Either Text MissionRunReport)
runMissionWith console store repository mission buildDriver = do
  started <- startMissionController store repository mission buildDriver
  case started of
    Left refusal -> pure (Left (missionStartRefusalMessage (refusal :: MissionStartRefusal)))
    Right controller -> do
      report <- loop controller missionRunnerIterationBudget []
      stopMissionController controller
      pure (Right report)
  where
    loop controller remaining transitions
      | remaining <= 0 = pure (concluded transitions (Left budgetExhausted))
      | otherwise = do
          mapM_ (\typed -> drainMissionConsoleWith typed.missionConsoleIsTerminal typed.missionConsoleInput controller) console
          iteration <- missionControllerIteration controller
          case iteration of
            MissionAdvanced transition -> loop controller (remaining - 1) (transition : transitions)
            MissionAwaiting _ -> do
              threadDelay missionRunnerPollMicros
              loop controller remaining transitions
            MissionStopped halt -> stopped controller remaining transitions halt
            MissionControllerFailed detail -> pure (concluded transitions (Left detail))

    -- A terminal mission is over and nothing anybody types changes that. A
    -- /blocked/ one is the opposite: it is waiting for precisely the authority
    -- this console carries, so the run says what it is stuck on and waits for
    -- an answer instead of exiting past the only person who can give one.
    stopped controller remaining transitions halt = case (halt, console) of
      (MissionHaltBlocked _ _, Just typed) -> do
        direction <- await typed controller halt
        case direction of
          MissionDirectionTaken -> loop controller remaining transitions
          MissionDirectionEnded -> pure (concluded transitions (Right halt))
      _ -> pure (concluded transitions (Right halt))

    -- The budget is deliberately not spent here. It bounds automatic progress,
    -- and this pass makes none: it blocks on a person, so it cannot spin, and
    -- an answer that changes nothing simply asks again.
    await typed controller halt = do
      usable <- try @IOException typed.missionConsoleIsTerminal
      case usable of
        Right True -> do
          announced <-
            try @IOException
              ( typed.missionConsoleAnnounce
                  ( missionHaltMessage halt
                      <> "; type a command to direct it, or "
                      <> Text.intercalate "/" missionConsoleDetachWords
                      <> " to leave it as it stands"
                  )
              )
          case announced of
            Left _ -> pure MissionDirectionEnded
            Right () -> answer typed controller
        _ -> pure MissionDirectionEnded

    answer typed controller = do
      -- End of input is an answer too, and the ordinary one: a console that
      -- has closed cannot be asked again.
      line <- try @IOException (Text.pack <$> hGetLine typed.missionConsoleInput)
      case line of
        Left _ -> pure MissionDirectionEnded
        Right spoken
          | Text.toLower (Text.strip spoken) `elem` missionConsoleDetachWords -> pure MissionDirectionEnded
          | otherwise -> do
              submitConsoleLine controller spoken
              pure MissionDirectionTaken
    concluded transitions conclusion =
      MissionRunReport
        { missionRunMission = mission,
          missionRunTransitions = reverse transitions,
          missionRunConclusion = conclusion
        }
    budgetExhausted = "this run reached its iteration budget without the mission settling"

-- ---------------------------------------------------------------------------
-- The live driver
-- ---------------------------------------------------------------------------

-- | The driver that reaches the real registry, the real workers, and real
-- GitHub.
liveMissionDriver :: Options -> ResolvedConfig -> Repository -> MissionStore -> MissionId -> IO MissionDriver
liveMissionDriver options config repository store _ =
  pure
    MissionDriver
      { missionDriverInventory = inventory,
        missionDriverObserveTarget = observeTarget,
        missionDriverStepEvidence = stepEvidence,
        missionDriverObserveSession = observeSession,
        missionDriverAdoptInvocation = adoptInvocation,
        missionDriverDispatch = dispatch,
        missionDriverTerminate = terminate
      }
  where
    workflowConfig :: WorkflowConfig
    workflowConfig = config.resolvedWorkflow

    identity = repository.repositoryOwner <> "/" <> repository.repositoryName

    -- Requirement 17: everything on this machine, for validation and conflict
    -- detection, and nothing that selects.
    inventory = do
      missions <- listMissions store
      workers <- discoverWorkerHistory repository
      pure
        ( Right
            MissionInventory
              { missionInventoryMissions = missions,
                missionInventoryWorkers = map workerIdentity workers
              }
        )

    workerIdentity descriptor = descriptor.workerDescriptorSpec.workerId.unWorkerId

    readBoard = do
      recordLock <- newGhRecordLock
      guard <- newGhFetchGuard recordLock
      fetched <-
        fetchGitHubSnapshot
          guard
          (const (pure ()))
          config.resolvedTimeouts.timeoutsGithubSeconds
          workflowConfig
          repository
      pure (either (Left . missionFailureFromProviderError) (Right . (.githubSnapshot)) fetched)

    catalogOf snapshot =
      TargetCatalog
        { catalogRepository = repository,
          catalogIssues = snapshot.snapshotIssues,
          catalogPullRequests = snapshot.snapshotPullRequests,
          catalogHistory = CatalogHistoryAbsent
        }

    -- The live reading of one target, taken item by item.
    --
    -- Not through a board read, and the reason is the whole point of a
    -- precondition. A board read covers open work, so an issue closed or a
    -- pull request merged since the plan was made does not resolve at all —
    -- and an unresolvable target reaches 'performDispatch' as a precondition
    -- that could not be read, which ends the run, rather than as the stale
    -- version it actually is, which returns the step to replanning. A target
    -- that reached a terminal state is the most ordinary reason a plan is out
    -- of date; it must be a fact this read can report.
    --
    -- It is also the same read the worker takes at its own boundary
    -- ('Kanban.Worker.preconditionStillHolds'), normalized into the same
    -- spellings 'targetPreconditionForItem' produces from a board item, so
    -- every comparison in the chain is between two readings that agree about
    -- what "unchanged" means.
    observeTarget target = do
      recordLock <- newGhRecordLock
      guard <- newGhFetchGuard recordLock
      observed <- observeTargetPrecondition guard repository (itemIdFor target)
      pure $ case observed of
        Left failure -> Left (missionStepFailureText (missionFailureFromProviderError failure))
        Right precondition -> Right (missionVersionOf precondition)

    itemIdFor target = case target.missionTargetKind of
      MissionTargetIssue -> IssueId target.missionTargetNumber
      MissionTargetPullRequest -> PullRequestId target.missionTargetNumber

    -- The environment every registry call this driver makes is answered
    -- against.
    --
    -- One construction rather than one per call site, because a dispatch and
    -- the observation that later judges its result have to agree about the
    -- repository, the workflow configuration, and the catalog: an observation
    -- made against a different read would validate a finished run's pull
    -- request against pull requests the dispatch never saw.
    actionEnvironmentFor snapshot = do
      roster <- loadModelRoster
      now <- getCurrentTime
      pure
        ActionEnvironment
          { actionRepository = repository,
            actionWorkflowConfig = workflowConfig,
            actionConfigPath = options.optionConfig,
            actionRoster = roster,
            actionCatalog = catalogOf snapshot,
            actionNow = now,
            actionWorkerDeadline =
              WorkerDeadline config.resolvedTimeouts.timeoutsWorkerDeadlineSeconds
          }

    -- One step's evidence.
    --
    -- The board is read only when no registered worker of this step is still
    -- live. While one is, the classification is settled by the worker reading
    -- alone, and asking GitHub would be the timed network poll §3 forbids.
    stepEvidence step record = do
      workers <- discoverWorkerHistory repository
      readings <- mapM (readingFor step workers) record.missionStepRecordSessions
      foreignWork <- foreignLiveWork step record workers
      let reading = decidingWorkerReading (mapMaybe id readings)
      case reading of
        Just ours
          | ours.missionWorkerLive ->
              pure (Right (evidenceOf record (Just ours) Nothing Nothing foreignWork))
        _ -> do
          board <- readBoard
          case board of
            -- Reported as a failure to read rather than folded into the
            -- evidence. A board that could not be fetched says nothing about
            -- this step, and passing it off as conflicting work would pause a
            -- mission for the duration of somebody's network outage.
            Left failure -> pure (Left (missionStepFailureText failure))
            Right snapshot -> do
              judged <- mapM (validatedConclusion step snapshot workers) reading
              let (satisfied, departed) = externalState step snapshot
              pure (Right (evidenceOf record judged satisfied departed foreignWork))

    -- What a settled worker actually achieved, decided by the registry rather
    -- than by this module.
    --
    -- A clean exit is not a result. @validateWorkerOutcome@ requires an
    -- attributable pull request before it will call a solve successful, and an
    -- issue action's verdict is read from what its child /published/ rather
    -- than from the fact that it finished — so a mission that read the worker
    -- state itself and called @SolveCompleted@ a success would report a solve
    -- that opened nothing, and a canonical review that published nothing, as
    -- work done. The handle is rebuilt from the worker's own durable record
    -- ('observableActionHandle') so the same validation the dashboard gets is
    -- the validation a headless run gets.
    --
    -- Only the terminal case is asked. A live worker's classification is
    -- settled by the reading alone, and this pass is not reached for one.
    validatedConclusion step snapshot workers reading
      | reading.missionWorkerLive = pure reading
      | otherwise = do
          observed <- observeThroughRegistry step snapshot workers reading
          pure reading {missionWorkerTerminal = observed}

    observeThroughRegistry step snapshot workers reading =
      case ( decodeWorkflowActionKind step.missionPlanStepAction,
             find ((== reading.missionWorkerSession.unMissionSessionId) . workerIdentity) workers
           ) of
        (Left decodeError, _) -> pure (Just (unjudged (actionKindDecodeErrorMessage decodeError)))
        -- Its record has been collected, so there is nothing left to judge it
        -- by. 'observeSession' reads the same absence the same way.
        (_, Nothing) -> pure (Just (unjudged "its worker record has been collected"))
        (Right kind, Just descriptor) -> do
          settled <- readWorkerState descriptor
          case settled of
            -- Unreadable, which is not a finished action: the registry's own
            -- observation waits on exactly this rather than inventing a result.
            Left _ -> pure Nothing
            Right recorded -> case recorded.workerStateStatus of
              WorkerStarting -> pure Nothing
              WorkerRunning -> pure Nothing
              WorkerOrphaned _ -> pure Nothing
              -- The two the registry passes straight through, decided from the
              -- sentence the worker itself wrote.
              WorkerTerminal (SolveNeedsInput detail) -> pure (Just (MissionWorkerNeedsInput detail))
              WorkerTerminal (SolveFailed detail) -> pure (Just (concludedFrom (settledWorkerFailure detail)))
              WorkerTerminal SolveCompleted -> judgeCompleted step snapshot kind descriptor

    judgeCompleted step snapshot kind descriptor =
      case step.missionPlanStepTarget of
        Nothing -> pure (Just (unjudged "the step names no target to judge its result against"))
        Just target -> case resolveActionTarget workflowConfig (catalogOf snapshot) identity (targetRefFor target) of
          Left refusal -> pure (Just (unjudged (actionRefusalMessage refusal)))
          Right (ActionTargetRepositoryWide _) ->
            pure (Just (unjudged ("#" <> Text.pack (show target.missionTargetNumber) <> " resolved to the repository rather than an item")))
          Right (ActionTargetItem resolved) -> case observableActionHandle kind resolved descriptor of
            -- A run whose record cannot supply what its handle needs. Judging
            -- it against this caller's baseline instead is the one thing that
            -- must not happen, so the step reports an outcome nobody can
            -- establish rather than a result nobody earned.
            Nothing -> pure (Just (unjudged "its worker recorded no attribution to judge its result against"))
            Just handle -> do
              environment <- actionEnvironmentFor snapshot
              observation <- observeAction environment handle
              pure $ case observation of
                Left refusal -> Just (unjudged (actionRefusalMessage refusal))
                Right (ActionRunning _) -> Nothing
                Right (ActionSettled outcome) -> Just (concludedFrom outcome)

    -- The registry's validated result, in the mission's own vocabulary.
    concludedFrom outcome
      | actionOutcomeSucceeded outcome = MissionWorkerSucceeded (actionOutcomeMessage outcome)
      | otherwise = case outcome of
          ActionNeedsInput detail -> MissionWorkerNeedsInput detail
          _ ->
            MissionWorkerFailed
              ( fromMaybe
                  (MissionFailureGeneric (actionOutcomeMessage outcome))
                  (missionFailureFromOutcome outcome)
              )

    -- A worker that finished and cannot be judged. Never a failure of the
    -- work: nothing here established what it achieved, which is requirement
    -- 7's unknown outcome exactly.
    unjudged detail =
      MissionWorkerFailed
        (MissionFailureOutcomeUnknown ("its result could not be validated: " <> detail))

    evidenceOf record reading satisfied departed foreignWork =
      MissionStepEvidence
        { missionEvidenceStep = record.missionStepRecordId,
          missionEvidenceLifecycle = record.missionStepRecordLifecycle,
          -- Supplied by the controller from its own invocation journal.
          missionEvidenceInvocation = Nothing,
          missionEvidenceWorker = reading,
          missionEvidenceSatisfied = satisfied,
          missionEvidenceDeparted = departed,
          missionEvidenceForeign = foreignWork
        }

    readingFor step workers session =
      case find ((== session.unMissionSessionId) . workerIdentity) workers of
        Nothing -> pure Nothing
        Just descriptor -> do
          state <- readWorkerState descriptor
          pure $ case state of
            Left _ -> Nothing
            Right recorded ->
              Just
                MissionWorkerReading
                  { missionWorkerSession = session,
                    missionWorkerLive = recorded.workerStateStatus `elem` [WorkerStarting, WorkerRunning],
                    -- Ownership and intent both proven: this mission's record
                    -- names it, it belongs to this repository, and its durable
                    -- task is this step's target.
                    missionWorkerCompatible =
                      descriptor.workerDescriptorSpec.workerRepository == repository
                        && namesTarget step descriptor,
                    missionWorkerTerminal = conclusionOf recorded,
                    missionWorkerProviderSession = recorded.workerStateSessionId
                  }

    -- The worker one invocation actually launched, found by the identity the
    -- launch wrote into its own specification.
    --
    -- This machine's records and nothing else, which is what makes it usable
    -- during recovery: the association was made durable at the moment the
    -- worker was created, so it survives the crash that lost the conclusion
    -- the controller was about to write.
    adoptInvocation invocation = do
      workers <- discoverWorkerHistory repository
      pure
        ( Right
            ( case [ descriptor
                   | descriptor <- workers,
                     descriptor.workerDescriptorSpec.workerInvocation
                       == Just invocation.unMissionInvocationId
                   ] of
                (descriptor : _) -> Just (MissionSessionId (workerIdentity descriptor))
                [] -> Nothing
            )
        )

    -- Whether one registered session has ended, for the accounting
    -- requirement 11 asks of a subtree.
    --
    -- A session identifier is a worker identifier, so this is that worker's
    -- own durable state and nothing else. A worker whose record has been
    -- collected is gone; a worker still running is not; and a worker whose
    -- state will not decode is neither, which keeps the node unsettled and the
    -- parent nonterminal.
    observeSession session step = do
      workers <- discoverWorkerHistory repository
      case find ((== session.unMissionSessionId) . workerIdentity) workers of
        -- Collected, and that is all it says. A worker's terminal artifacts
        -- are collectable after their retention whatever the worker did, so
        -- the record of a child that failed, stopped to ask a question, or
        -- was never observed at all is gone by exactly the same route as a
        -- child that completed. Reporting the absence as a clean exit would
        -- hand a parent the one thing it is waiting for — a conclusive child
        -- outcome — on the strength of no evidence whatever, and let it settle
        -- over a child nothing ever accounted for.
        Nothing -> do
          now <- getCurrentTime
          pure
            ( Right
                ( Just
                    MissionTerminalObservation
                      { missionObservationAt = now,
                        missionObservationOutcome = MissionObservedUnknown,
                        missionObservationDetail = Just "its worker record has been collected; how it ended is unrecorded"
                      }
                )
            )
        Just descriptor -> do
          state <- readWorkerState descriptor
          case state of
            Left _ -> pure (Right Nothing)
            Right recorded -> case recorded.workerStateStatus of
              WorkerStarting -> pure (Right Nothing)
              WorkerRunning -> pure (Right Nothing)
              WorkerOrphaned _ -> pure (Right Nothing)
              -- Ended, and what it ended /having achieved/ is the registry's
              -- to say — for a registered child exactly as for a plan step. A
              -- child solve that opened no pull request and a child review
              -- that published no verdict both exit cleanly, and recording
              -- either as a clean exit would put a result in this mission's
              -- account of itself that nothing ever established.
              WorkerTerminal outcome -> observedEnd step descriptor outcome

    observedEnd step descriptor outcome = do
      judged <- judgedEnd step descriptor outcome
      now <- getCurrentTime
      pure
        ( Right
            ( Just
                MissionTerminalObservation
                  { missionObservationAt = now,
                    missionObservationOutcome = fst judged,
                    missionObservationDetail = Just (snd judged)
                  }
            )
        )

    judgedEnd step descriptor outcome = case outcome of
      -- The two the registry passes through untouched: a provider that asked
      -- a question or failed has already said what happened.
      SolveNeedsInput detail -> pure (MissionObservedExit 1, terminalDetail (SolveNeedsInput detail))
      SolveFailed detail -> pure (MissionObservedExit 1, terminalDetail (SolveFailed detail))
      SolveCompleted -> case step of
        -- Nothing records what this session was for, so nothing can say what
        -- it achieved. Unknown keeps its parent waiting, which is the
        -- fail-closed answer requirement 11 asks for.
        Nothing -> pure (MissionObservedUnknown, "nothing records what this session was doing")
        Just planned -> case decodeWorkflowActionKind planned.missionPlanStepAction of
          Left decodeError -> pure (MissionObservedUnknown, actionKindDecodeErrorMessage decodeError)
          Right kind -> do
            board <- readBoard
            case board of
              Left failure -> pure (MissionObservedUnknown, missionStepFailureText failure)
              Right snapshot -> endOf <$> judgeCompleted planned snapshot kind descriptor

    endOf conclusion = case conclusion of
      Nothing -> (MissionObservedUnknown, "its result could not be established")
      Just (MissionWorkerSucceeded detail) -> (MissionObservedExit 0, detail)
      Just (MissionWorkerNeedsInput detail) -> (MissionObservedExit 1, detail)
      Just (MissionWorkerFailed (MissionFailureOutcomeUnknown detail)) -> (MissionObservedUnknown, detail)
      Just (MissionWorkerFailed failure) -> (MissionObservedExit 1, missionStepFailureText failure)

    terminalDetail outcome = case outcome of
      SolveCompleted -> "it completed"
      SolveNeedsInput detail -> "it stopped to ask: " <> detail
      SolveFailed detail -> detail

    -- Live work on this step's target that this mission never registered.
    --
    -- Read from this machine's own worker records rather than from GitHub, so
    -- it costs nothing and stays true while the board is not being refreshed.
    -- Its whole job is to make requirement 9's "incompatible or conflicting
    -- live work" a state the controller can observe rather than one it takes
    -- on trust.
    --
    -- Two narrowings matter, and both were the difference between a real
    -- conflict and a spurious pause. The worker has to be /live/: a worker
    -- that finished this issue last week is history, not a conflict. And the
    -- target it names has to be this step's target /of the same kind/, read
    -- off its durable task rather than guessed from its identifier — every
    -- repository has an issue #844 and a pull request #844, and they are not
    -- the same item.
    foreignLiveWork step record workers = case step.missionPlanStepTarget of
      Nothing -> pure Nothing
      Just target -> do
        candidates <-
          mapM
            liveIdentity
            [ descriptor
            | descriptor <- workers,
              namesTarget step descriptor,
              MissionSessionId (workerIdentity descriptor) `notElem` record.missionStepRecordSessions
            ]
        pure $ case mapMaybe id candidates of
          [] -> Nothing
          (found : _) ->
            Just
              ( "worker "
                  <> found
                  <> " is live against #"
                  <> Text.pack (show target.missionTargetNumber)
                  <> " and this mission did not start it"
              )

    liveIdentity descriptor = do
      state <- readWorkerState descriptor
      pure $ case state of
        Left _ -> Nothing
        Right recorded
          | recorded.workerStateStatus `elem` [WorkerStarting, WorkerRunning] -> Just (workerIdentity descriptor)
          | otherwise -> Nothing

    -- The item a worker's durable task names, which is what decides whether it
    -- is working on this step's target at all.
    namesTarget step descriptor = case step.missionPlanStepTarget of
      Nothing -> False
      Just target -> workerTarget descriptor.workerDescriptorSpec.workerTask == Just (target.missionTargetKind, target.missionTargetNumber)

    workerTarget task = case task of
      SolveWorkerTaskKind solve -> Just (MissionTargetIssue, solve.solveWorkerIssueNumber)
      PullRequestWorkerTaskKind pullRequest -> Just (MissionTargetPullRequest, pullRequest.pullRequestWorkerNumber)
      IssueActionWorkerTaskKind action -> Just (MissionTargetIssue, action.issueActionIssueNumber)
      -- The repository's review host owns no item of its own; its children do.
      IssueHostWorkerTaskKind _ -> Nothing

    -- Deliberately silent about a clean exit. What @SolveCompleted@ achieved
    -- is the registry's to say (see 'validatedConclusion'), and answering it
    -- here would be the second opinion that reports an unearned success; the
    -- evidence pass replaces this whole field before anything classifies it.
    conclusionOf recorded = case recorded.workerStateStatus of
      WorkerTerminal SolveCompleted -> Nothing
      WorkerTerminal (SolveNeedsInput detail) -> Just (MissionWorkerNeedsInput detail)
      WorkerTerminal (SolveFailed detail) ->
        Just
          ( MissionWorkerFailed
              ( fromMaybe
                  (MissionFailureGeneric detail)
                  (missionFailureFromOutcome (settledWorkerFailure detail))
              )
          )
      WorkerOrphaned _ -> Nothing
      WorkerStarting -> Nothing
      WorkerRunning -> Nothing

    -- What the live board says about this step's target: positive evidence
    -- that it landed, and separately whether it has left the read at all.
    --
    -- The separation is the point. An open read covers open work, so a closed
    -- issue nobody solved, a closed-unmerged pull request, and a genuinely
    -- finished item are all equally absent from it — and reading that absence
    -- as success is how a mission would report work nobody did. Only positive
    -- evidence satisfies a step: an open pull request that links the issue a
    -- solve was for, or a configured verdict label on the pull request a
    -- review was for. Absence is handed on as a departure, which the
    -- classification treats as an outcome nobody can settle from here.
    externalState step snapshot = case step.missionPlanStepTarget of
      Nothing -> (Nothing, Nothing)
      Just target -> case target.missionTargetKind of
        MissionTargetIssue
          | not (any ((== target.missionTargetNumber) . (.issueNumber)) snapshot.snapshotIssues) ->
              (Nothing, Just (departedMessage target))
          | solving step,
            (number : _) <- linkedPullRequests target snapshot ->
              (Just ("PR #" <> Text.pack (show number) <> " already links #" <> Text.pack (show target.missionTargetNumber)), Nothing)
          | otherwise -> (Nothing, Nothing)
        MissionTargetPullRequest ->
          case find ((== target.missionTargetNumber) . (.pullRequestNumber)) snapshot.snapshotPullRequests of
            Nothing -> (Nothing, Just (departedMessage target))
            Just pullRequest
              | reviewing step, any verdictLabel pullRequest.pullRequestLabels ->
                  (Just ("PR #" <> Text.pack (show target.missionTargetNumber) <> " already carries a verdict"), Nothing)
              | otherwise -> (Nothing, Nothing)

    departedMessage target =
      "#"
        <> Text.pack (show target.missionTargetNumber)
        <> " has left this repository's open read, which cannot say whether the work landed"

    solving step = step.missionPlanStepAction `elem` ["solve_issue", "autosolve_issue"]
    reviewing step = step.missionPlanStepAction == "review_pull_request"
    verdictLabel label =
      label.labelName `elem` [workflowConfig.approvalLabel, workflowConfig.changesRequestedLabel]
    linkedPullRequests target snapshot =
      [ pullRequest.pullRequestNumber
      | pullRequest <- snapshot.snapshotPullRequests,
        target.missionTargetNumber `elem` pullRequest.pullRequestLinkedIssues
      ]

    -- The effect itself.
    --
    -- The recorded precondition travels with the request, so the registry
    -- verifies it against this very read immediately before the spawn
    -- (requirement 8). The controller's own recheck happens a moment earlier
    -- and against a read of its own; both are cheap, and the one that matters
    -- is the one nearest the effect.
    dispatch request = case decodeWorkflowActionKind request.missionDispatchStep.missionPlanStepAction of
      Left decodeError -> pure (Left (MissionFailureConfiguration (actionKindDecodeErrorMessage decodeError)))
      Right kind -> do
        board <- readBoard
        case board of
          Left failure -> pure (Left failure)
          Right snapshot -> do
            environment <- actionEnvironmentFor snapshot
            let base = actionRequest kind identity (maybe TargetRepositoryWide targetRefFor request.missionDispatchTarget)
                -- Requirement 13: the recorded session is resumed when there
                -- is one, and a fresh session is briefed rather than handed
                -- the old session's identity.
                continued = case request.missionDispatchContinuation of
                  MissionResumeSession session ->
                    base {requestExistingSession = Just session, requestResumeProvenance = ResumeAnswer}
                  MissionFreshSession brief ->
                    base {requestUserMessage = brief, requestResumeProvenance = ResumeAnswer}
                requested =
                  continued
                    { requestExpectedTarget = preconditionOf <$> request.missionDispatchVersion,
                      -- Written into the worker's own specification, so a
                      -- crash between this call returning and the controller
                      -- recording what it got leaves the two able to find each
                      -- other again.
                      requestInvocation = Just request.missionDispatchInvocation.unMissionInvocationId
                    }
            dispatched <- dispatchAction environment requested
            case dispatched of
              Left refusal -> Left <$> refusedDispatch request refusal
              Right handle -> Right <$> acceptance environment handle

    acceptance :: ActionEnvironment -> ActionHandle -> IO MissionDispatchAccepted
    acceptance environment handle = case actionHandleWorker handle of
      Just descriptor ->
        pure
          MissionDispatchAccepted
            { missionAcceptedSession = MissionSessionId (workerIdentity descriptor),
              missionAcceptedProviderSession = descriptor.workerDescriptorSpec.workerExistingSession,
              missionAcceptedWorker = workerIdentity descriptor,
              missionAcceptedDetail = "dispatched through the workflow action registry",
              missionAcceptedOutcome = Nothing
            }
      -- A registered action with no worker of its own — the approval-queue
      -- read. Its answer exists now and will not exist later: nothing durable
      -- was started, so a session registered for it names a worker no pass can
      -- find. Asking the registry here is the only moment there is anything to
      -- ask.
      Nothing -> do
        observed <- observeAction environment handle
        pure
          MissionDispatchAccepted
            { missionAcceptedSession = MissionSessionId "observation",
              missionAcceptedProviderSession = Nothing,
              missionAcceptedWorker = "observation",
              missionAcceptedDetail = "this action owns no worker",
              missionAcceptedOutcome =
                Just
                  ( case observed of
                      Left refusal -> unjudged (actionRefusalMessage refusal)
                      Right (ActionRunning detail) -> unjudged ("it reported itself still running: " <> detail)
                      Right (ActionSettled outcome) -> concludedFrom outcome
                  )
            }

    -- A refusal, retyped where fresh evidence says it was a race rather than a
    -- fault.
    --
    -- The registry resolves a target against a board read covering open work,
    -- so a target that closed or merged between the controller's own reread
    -- and this dispatch does not resolve at all — and \"could not resolve\"
    -- reaching a mission as a generic failure is the very collapse
    -- requirement 8 exists to prevent, because nothing was mutated and the
    -- plan simply needs recomputing. So an unresolved target is asked about
    -- item by item, and a reading that no longer matches the one this dispatch
    -- was authorized against is reported as what it is.
    refusedDispatch request refusal = case (refusal, request.missionDispatchVersion) of
      (ActionTargetUnresolved _ _, Just recorded) -> staleOrRefused request recorded refusal
      (ActionTargetNotFound _, Just recorded) -> staleOrRefused request recorded refusal
      _ -> pure (missionFailureFromRefusal refusal)

    staleOrRefused request recorded refusal = case request.missionDispatchTarget of
      Nothing -> pure (missionFailureFromRefusal refusal)
      Just target -> do
        observed <- observeTarget target
        pure $ case observed of
          -- Unreadable too, so nothing was established either way; the
          -- registry's own refusal stands.
          Left _ -> missionFailureFromRefusal refusal
          Right live
            | missionVersionHolds recorded live -> missionFailureFromRefusal refusal
            | otherwise ->
                MissionFailureStaleVersion
                  (missionStaleVersionMessage (MissionStaleVersion {missionStaleRecorded = recorded, missionStaleObserved = live}))

    -- Requirement 11: the controller has already journaled which sessions
    -- these are, and they are already the complete registered subtree; this
    -- ends exactly those and nothing else.
    terminate sessions = do
      workers <- discoverWorkerHistory repository
      mapM_ (endOne workers) sessions
      pure (Right ())

    endOne workers session = case find ((== session.unMissionSessionId) . workerIdentity) workers of
      Nothing -> pure ()
      Just descriptor -> terminateWorker descriptor

-- | Submits every complete line waiting at the runner's own console.
--
-- Requirement 14's boundary, and it is a property of the handle rather than of
-- the words on it. A terminal attached to this process is the console the
-- operator is sitting at; a pipe, a file, or @\/dev\/null@ is some other
-- process's output, and reading a command off one of those would be exactly
-- the unauthenticated process input the requirement excludes. So a handle that
-- is not a terminal is not read at all, and this returns without consuming a
-- byte of it.
--
-- What is read goes out through the endpoint the controller /owns/, which is
-- the only endpoint holding this run's secret, so a console line is
-- authenticated by construction rather than by a check further down.
--
-- Non-blocking: only lines already buffered are taken, so a mission with a
-- live worker and a silent operator advances at its own pace. A line that does
-- not parse is journaled as a rejected command and consumes nothing else.
-- The terminal test is a parameter, and that is a seam rather than a
-- convenience: the property worth testing is what the runner does with a line
-- once it has decided the handle is a console, and arranging a real terminal
-- to say so costs a pseudo-terminal. Production supplies 'hIsTerminalDevice'
-- through 'terminalMissionConsole' and nothing else does.
drainMissionConsoleWith :: IO Bool -> Handle -> MissionController -> IO ()
drainMissionConsoleWith isConsole handle controller = do
  usable <- try @IOException isConsole
  case usable of
    Right True -> drain (0 :: Int)
    _ -> pure ()
  where
    -- Bounded, so a console producing lines faster than the controller applies
    -- them cannot keep an iteration from ever happening.
    drain taken
      | taken >= missionConsoleBatch = pure ()
      | otherwise = do
          available <- try @IOException (hReady handle)
          case available of
            Right True -> do
              line <- try @IOException (Text.pack <$> hGetLine handle)
              case line of
                Left _ -> pure ()
                Right typed -> do
                  submit typed
                  drain (taken + 1)
            _ -> pure ()
    submit = submitConsoleLine controller

-- | One typed line, parsed and handed to the controller.
--
-- Shared by the drain and by the prompt a blocked run puts up, so an answer
-- typed at either arrives with the same authority and an unparsable one leaves
-- the same trace. Two spellings of this would be two chances for the
-- interactive path to be the lenient one.
submitConsoleLine :: MissionController -> Text -> IO ()
submitConsoleLine controller typed = do
  commandId <- newConsoleCommandId
  case parseMissionConsoleCommand controller.missionControllerMission typed of
    Left detail -> reportUnparsed commandId detail
    -- Handed to the controller inside this process rather than written
    -- anywhere. That is what makes it authenticated: there is no artefact for
    -- another process to read, copy, or replay.
    Right payload -> submitConsoleCommand controller commandId payload
  where
    -- A line the console could not turn into a command still has to leave a
    -- trace: the operator typed it, and a silently dropped instruction is
    -- indistinguishable from one that was carried out.
    reportUnparsed commandId detail = do
      now <- getCurrentTime
      _ <-
        recordMissionEvent
          controller.missionControllerStore
          MissionEvent
            { missionEventMission = controller.missionControllerMission,
              missionEventRepository = controller.missionControllerStore.missionStoreRepository,
              missionEventAt = now,
              missionEventStep = Nothing,
              missionEventSession = Nothing,
              missionEventKind = "console_rejected",
              missionEventDetail = Just (commandId <> ": " <> Text.strip typed <> " — " <> detail)
            }
      pure ()

-- | How many console lines one iteration will take.
missionConsoleBatch :: Int
missionConsoleBatch = 16

newConsoleCommandId :: IO Text
newConsoleCommandId = do
  now <- getCurrentTime
  pure ("console-" <> Text.pack (filter (`notElem` (" :-." :: String)) (show now)))

-- | The action-layer target reference one mission target names.
targetRefFor :: MissionTarget -> ActionTargetRef
targetRefFor target =
  TargetByKind
    ( case target.missionTargetKind of
        MissionTargetIssue -> ActionTargetIssue
        MissionTargetPullRequest -> ActionTargetPullRequest
    )
    target.missionTargetNumber

-- | Which of a step's registered sessions answers for it.
--
-- A step's session list accumulates rather than replaces: one that was
-- replanned after a stale race carries the abandoned attempt and its
-- replacement, oldest first. Taking the first reading available would let a
-- terminal old worker answer for a step whose replacement is still running —
-- and because that replacement is registered, the foreign-work pass does not
-- report it either, so the step would be reconciled back to pending and
-- dispatched a third time beside a live second one. That is the repeated
-- effect requirement 7 forbids outright.
--
-- So a live session wins, and a compatible live one wins over an opaque live
-- one, because the compatible reading is the one whose intent is proven. Only
-- when nothing registered is still running does a terminal reading answer, and
-- then it is the most recent: the latest attempt is the one whose conclusion
-- is the step's.
decidingWorkerReading :: [MissionWorkerReading] -> Maybe MissionWorkerReading
decidingWorkerReading present = case filter (.missionWorkerLive) present of
  [] -> case reverse present of
    (newest : _) -> Just newest
    [] -> Nothing
  live@(first : _) -> Just (fromMaybe first (find (.missionWorkerCompatible) live))

-- | The durable record of a precondition, and the precondition it records.
--
-- Two shapes rather than one because they answer to different owners: the
-- durable one is the mission store's schema and outlives every release that
-- reads it, and the other is the registry's vocabulary for a value that never
-- reaches a file. The conversions are total in both directions, which is what
-- makes the pair a spelling difference rather than a second opinion.
missionVersionOf :: TargetPrecondition -> MissionTargetVersion
missionVersionOf precondition =
  MissionTargetVersion
    { missionVersionKind = case precondition.preconditionItem of
        IssueId _ -> MissionTargetIssue
        PullRequestId _ -> MissionTargetPullRequest,
      missionVersionNumber = targetPreconditionNumber precondition,
      missionVersionUpdatedAt = precondition.preconditionUpdatedAt,
      missionVersionHead = precondition.preconditionHead,
      missionVersionLabels = precondition.preconditionLabels,
      missionVersionState = precondition.preconditionState
    }

preconditionOf :: MissionTargetVersion -> TargetPrecondition
preconditionOf version =
  TargetPrecondition
    { preconditionItem = case version.missionVersionKind of
        MissionTargetIssue -> IssueId version.missionVersionNumber
        MissionTargetPullRequest -> PullRequestId version.missionVersionNumber,
      preconditionUpdatedAt = version.missionVersionUpdatedAt,
      preconditionHead = version.missionVersionHead,
      preconditionLabels = version.missionVersionLabels,
      preconditionState = version.missionVersionState
    }

-- | The one place a step failure becomes the sentence a caller who wanted a
-- reading gets instead.
missionStepFailureText :: MissionStepFailure -> Text
missionStepFailureText failure = case failure of
  MissionFailureAuthentication detail -> detail
  MissionFailureExecutable detail -> detail
  MissionFailureCapacity detail -> detail
  MissionFailureConfiguration detail -> detail
  MissionFailureDeadline detail -> detail
  MissionFailureOutcomeUnknown detail -> detail
  MissionFailureGeneric detail -> detail
  MissionFailureStaleVersion _ -> "the target's live state could not be established"
