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
    runMissionWith,
    liveMissionDriver,
    drainMissionConsole,
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
    ActionHandle,
    ActionRequest (..),
    ActionTarget (..),
    ActionTargetKind (..),
    ActionTargetRef (..),
    CatalogHistory (..),
    TargetCatalog (..),
    TargetPrecondition (..),
    targetPreconditionNumber,
    actionHandleWorker,
    actionKindDecodeErrorMessage,
    actionRefusalMessage,
    actionRequest,
    decodeWorkflowActionKind,
    dispatchAction,
    resolveActionTarget,
    settledWorkerFailure,
    targetPreconditionFor,
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
import Kanban.Mission.Invocation (MissionTargetVersion (..))
import Kanban.Mission.Paths (openMissionStore)
import Kanban.Mission.Reconcile
  ( MissionContinuation (..),
    MissionHalt,
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
import System.IO (Handle, hGetLine, hIsTerminalDevice, hReady, stdin)

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
            -- requirement 14 names. 'drainMissionConsole' is what decides
            -- whether this handle qualifies; a redirected stdin is
            -- unauthenticated process input and is never read.
            (Just stdin)
            store
            repository
            (MissionId (Text.strip identifier))
            (liveMissionDriver options config repository)

-- | The loop, with the driver injected.
--
-- The seam a fixture uses: everything below this point is the controller's own
-- progression, and everything the driver does is the outside world.
runMissionWith :: Maybe Handle -> MissionStore -> Repository -> MissionId -> (MissionStore -> MissionId -> IO MissionDriver) -> IO (Either Text MissionRunReport)
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
          mapM_ (\handle -> drainMissionConsole handle controller) console
          iteration <- missionControllerIteration controller
          case iteration of
            MissionAdvanced transition -> loop controller (remaining - 1) (transition : transitions)
            MissionAwaiting _ -> do
              threadDelay missionRunnerPollMicros
              loop controller remaining transitions
            MissionStopped halt -> pure (concluded transitions (Right halt))
            MissionControllerFailed detail -> pure (concluded transitions (Left detail))
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

    -- The live reading of one target, taken through the registry's own
    -- resolution and its own precondition derivation.
    --
    -- Shared rather than re-extracted, so the record the controller journals
    -- and the record `dispatchProviderTurn` compares against at the launch
    -- boundary are the same reading of the same item. Two derivations here
    -- would be two chances to disagree about what "unchanged" means.
    observeTarget target = do
      board <- readBoard
      pure $ case board of
        Left failure -> Left (missionStepFailureText failure)
        Right snapshot -> case resolveActionTarget workflowConfig (catalogOf snapshot) identity (targetRefFor target) of
          Left refusal -> Left (actionRefusalMessage refusal)
          Right (ActionTargetRepositoryWide _) ->
            Left ("#" <> Text.pack (show target.missionTargetNumber) <> " resolved to the repository rather than an item")
          Right (ActionTargetItem resolved) -> Right (missionVersionOf (targetPreconditionFor resolved))

    -- One step's evidence.
    --
    -- The board is read only when no registered worker of this step is still
    -- live. While one is, the classification is settled by the worker reading
    -- alone, and asking GitHub would be the timed network poll §3 forbids.
    stepEvidence step record = do
      workers <- discoverWorkerHistory repository
      readings <- mapM (readingFor step workers) record.missionStepRecordSessions
      foreignWork <- foreignLiveWork step record workers
      let reading = firstJust readings
      case reading of
        Just ours
          | ours.missionWorkerLive ->
              pure (Right (evidenceOf record (Just ours) Nothing Nothing foreignWork))
        _ -> do
          board <- readBoard
          pure $ case board of
            -- Reported as a failure to read rather than folded into the
            -- evidence. A board that could not be fetched says nothing about
            -- this step, and passing it off as conflicting work would pause a
            -- mission for the duration of somebody's network outage.
            Left failure -> Left (missionStepFailureText failure)
            Right snapshot ->
              let (satisfied, departed) = externalState step snapshot
               in Right (evidenceOf record reading satisfied departed foreignWork)

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

    firstJust values = case mapMaybe id values of
      (value : _) -> Just value
      [] -> Nothing

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

    -- Whether one registered session has ended, for the accounting
    -- requirement 11 asks of a subtree.
    --
    -- A session identifier is a worker identifier, so this is that worker's
    -- own durable state and nothing else. A worker whose record has been
    -- collected is gone; a worker still running is not; and a worker whose
    -- state will not decode is neither, which keeps the node unsettled and the
    -- parent nonterminal.
    observeSession session = do
      workers <- discoverWorkerHistory repository
      case find ((== session.unMissionSessionId) . workerIdentity) workers of
        Nothing -> do
          now <- getCurrentTime
          pure
            ( Right
                ( Just
                    MissionTerminalObservation
                      { missionObservationAt = now,
                        missionObservationOutcome = MissionObservedExit 0,
                        missionObservationDetail = Just "its worker record has been collected"
                      }
                )
            )
        Just descriptor -> do
          state <- readWorkerState descriptor
          now <- getCurrentTime
          pure $ case state of
            Left _ -> Right Nothing
            Right recorded -> case recorded.workerStateStatus of
              WorkerStarting -> Right Nothing
              WorkerRunning -> Right Nothing
              WorkerOrphaned _ -> Right Nothing
              WorkerTerminal outcome ->
                Right
                  ( Just
                      MissionTerminalObservation
                        { missionObservationAt = now,
                          missionObservationOutcome = case outcome of
                            SolveCompleted -> MissionObservedExit 0
                            _ -> MissionObservedExit 1,
                          missionObservationDetail = Just (terminalDetail outcome)
                        }
                  )

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

    conclusionOf recorded = case recorded.workerStateStatus of
      WorkerTerminal SolveCompleted -> Just (MissionWorkerSucceeded "the registered worker completed")
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
        roster <- loadModelRoster
        board <- readBoard
        case board of
          Left failure -> pure (Left failure)
          Right snapshot -> do
            now <- getCurrentTime
            let environment =
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
                base = actionRequest kind identity (maybe TargetRepositoryWide targetRefFor request.missionDispatchTarget)
                -- Requirement 13: the recorded session is resumed when there
                -- is one, and a fresh session is briefed rather than handed
                -- the old session's identity.
                continued = case request.missionDispatchContinuation of
                  MissionResumeSession session ->
                    base {requestExistingSession = Just session, requestResumeProvenance = ResumeAnswer}
                  MissionFreshSession brief ->
                    base {requestUserMessage = brief, requestResumeProvenance = ResumeAnswer}
                requested = continued {requestExpectedTarget = preconditionOf <$> request.missionDispatchVersion}
            dispatched <- dispatchAction environment requested
            pure (either (Left . missionFailureFromRefusal) (Right . acceptance) dispatched)

    acceptance :: ActionHandle -> MissionDispatchAccepted
    acceptance handle = case actionHandleWorker handle of
      Just descriptor ->
        MissionDispatchAccepted
          { missionAcceptedSession = MissionSessionId (workerIdentity descriptor),
            missionAcceptedProviderSession = descriptor.workerDescriptorSpec.workerExistingSession,
            missionAcceptedWorker = workerIdentity descriptor,
            missionAcceptedDetail = "dispatched through the workflow action registry"
          }
      Nothing ->
        MissionDispatchAccepted
          { missionAcceptedSession = MissionSessionId "observation",
            missionAcceptedProviderSession = Nothing,
            missionAcceptedWorker = "observation",
            missionAcceptedDetail = "this action owns no worker"
          }

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
drainMissionConsole :: Handle -> MissionController -> IO ()
drainMissionConsole handle = drainMissionConsoleWith (hIsTerminalDevice handle) handle

-- | 'drainMissionConsole' with the console test injected.
--
-- The seam a fixture uses, and the reason it is a seam: the property worth
-- testing is what the runner does with a line once it decides the handle is a
-- console, and arranging a real terminal to say so costs a pseudo-terminal.
-- Production supplies 'hIsTerminalDevice' and nothing else does.
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
    submit typed = do
      commandId <- newConsoleCommandId
      case parseMissionConsoleCommand controller.missionControllerMission typed of
        Left detail -> reportUnparsed commandId typed detail
        -- Handed to the controller inside this process rather than written
        -- anywhere. That is what makes it authenticated: there is no artefact
        -- for another process to read, copy, or replay.
        Right payload -> submitConsoleCommand controller commandId payload
    -- A line the console could not turn into a command still has to leave a
    -- trace: the operator typed it, and a silently dropped instruction is
    -- indistinguishable from one that was carried out.
    reportUnparsed commandId typed detail = do
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
