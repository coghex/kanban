{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | The persistent worker's supervisor: one detached process per solve or
-- pull-request task, owning that item's lease, its durable state, and the
-- deadline that bounds its whole lifetime.
--
-- This module is also the layer's facade. The lease, journal, census,
-- termination, discovery, and monitoring seams live in @Kanban.Worker.*@
-- internal modules and are re-exported from here, so every consumer keeps
-- importing "Kanban.Worker" alone.
--
-- 'runWorkerWithTask' is deliberately one function. It is a single
-- supervisor lifecycle whose correctness lives in the ordering of its masks,
-- claims, and compare-and-swaps against 'watchdogLoop' and
-- 'waitForOrphanResolution'; splitting it would scatter the race
-- documentation that makes it readable.
module Kanban.Worker
  ( WorkerDescriptor (..),
    WorkerEnvelope (..),
    WorkerEvent (..),
    WorkerId (..),
    WorkerParent (..),
    ProcessIdentity (..),
    ProviderSlot (..),
    WorkerTask (..),
    SolveWorkerTask (..),
    PullRequestWorkerTask (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    SupervisorCells (..),
    acquireWorkerLease,
    acquireWorkerLeaseFor,
    WorkerLeaseRefusal (..),
    WorkerLaunchRefusal (..),
    workerLaunchRefusalMessage,
    workerHoldingItem,
    acknowledgeWorker,
    acknowledgeSupersededWorkers,
    collectWorkerCache,
    -- | Exported so the suite can drive the janitor against a chosen process
    -- snapshot, the same way the termination and recovery paths are.
    collectWorkerCacheWith,
    consumeJournalLines,
    -- | Exported so the suite can address a hand-built spec's durable files.
    descriptorForSpec,
    discoverWorkers,
    discoverWorkerHistory,
    launchPullRequestWorker,
    launchSolveWorker,
    monitorWorker,
    -- | Exported so the suite can build a supervisor's cells mechanically
    -- for the helpers that take them, rather than enumerating every field.
    newSupervisorCells,
    pendingTerminationDiagnosticPrefix,
    readWorkerState,
    recordLaunchedSupervisorIdentity,
    recoverIfWorkerStoppedWith,
    releaseWorkerLease,
    runWorker,
    runWorkerWith,
    runWorkerWithTask,
    -- | Exported so the suite can observe the descriptors a detached
    -- supervisor is actually launched with.
    spawnDetachedSupervisor,
    terminateProviderRefWith,
    terminateRecordedStateProcessesWith,
    terminateWorker,
    terminateWorkerWith,
    waitForOrphanResolution,
    workerDeadlineReason,
    waitForWorkerStart,
    workerDirectory,
  )
where

import Control.Concurrent (ThreadId, forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar, withMVar)
import Control.Exception (Exception, IOException, SomeException, bracket, mask, throwIO, try, uninterruptibleMask_)
import Control.Monad (unless, void, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (addUTCTime, diffUTCTime, getCurrentTime)
import Kanban.Domain (Repository, WorkflowConfig)
import Kanban.Models (RecordedAssignment (..), recordedAssignmentCell)
import Kanban.Paths (createPrivateDirectory)
import Kanban.Process
  ( ManagedProcess,
    ProcessIdentity (..),
    identityForPid,
    killManagedProcess,
    liveProcessesWith,
    managedProcess,
    managedProcessPid,
    readProcessSnapshot,
  )
import Kanban.PullRequestFlow (PullRequestAction, PullRequestFlowEvent (..), PullRequestOrigin, runPullRequestFlow)
import Kanban.Solve (AgentEvent (..), ResumeProvenance, SolveEvent (..), SolveOutcome (..), SolveWorkflow, SolverBrand, UnknownAggregator, brandForProvider, newUnknownAggregator, runSolve, sealUnknownAggregates)
import Kanban.Worker.Census (liveRecordedProcessesWith, recordProviderIdentity, refreshProcessCensus)
import Kanban.Worker.Discovery
  ( acknowledgeSupersededWorkers,
    acknowledgeWorker,
    collectWorkerCache,
    collectWorkerCacheWith,
    discoverWorkerHistory,
    discoverWorkers,
    workerHoldingItem,
  )
import Kanban.Worker.Journal (EventJournalLock, appendWorkerEvent, consumeJournalLines, newEventJournalLock)
import Kanban.Worker.Lease
  ( WorkerLeaseRefusal (..),
    acquireWorkerLease,
    acquireWorkerLeaseFor,
    recordLaunchedSupervisorIdentity,
    releaseWorkerLease,
  )
import Kanban.Worker.Monitor (monitorWorker, recoverIfWorkerStoppedWith)
import Kanban.Worker.Paths
  ( decodeFile,
    descriptorForSpec,
    newWorkerId,
    persistState,
    readWorkerState,
    workerDirectory,
    writePrivateJson,
    writeState,
  )
import Kanban.Worker.Termination
  ( pendingTerminationDiagnosticPrefix,
    terminateProviderRefWith,
    terminateRecordedProcesses,
    terminateRecordedStateProcessesWith,
    terminateWorker,
    terminateWorkerWith,
    workerTerminationAttempts,
    workerTerminationPollMicros,
  )
import Kanban.Worker.Types
  ( ProviderSlot (..),
    PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerDescriptor (..),
    WorkerEnvelope (..),
    WorkerEvent (..),
    WorkerId (..),
    WorkerParent (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    WorkerTask (..),
  )
import System.Directory (XdgDirectory (XdgCache), doesFileExist)
import System.Environment (getExecutablePath)
import System.IO (IOMode (ReadMode, WriteMode), hClose, openFile)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (Handler (Catch), installHandler, sigINT, sigTERM)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (UseHandle), createProcess, getProcessExitCode, proc)

-- | Takes the assignment its caller resolved or replayed rather than a
-- roster to resolve for itself: the launch boundary is where a session's
-- cell is decided once (see 'Kanban.UI.Util.launchAssignment'), and this is
-- where that decision becomes durable.
launchSolveWorker :: RecordedAssignment -> Repository -> Int -> SolveWorkflow -> SolverBrand -> Maybe Text -> Maybe FilePath -> ResumeProvenance -> Text -> Maybe WorkerParent -> Maybe FilePath -> WorkflowConfig -> IO (Either WorkerLaunchRefusal WorkerDescriptor)
launchSolveWorker assignment repository issueNumber workflow brand existingSession existingLogPath provenance userMessage parent configPath workflowConfig = do
  now <- getCurrentTime
  workerId <- newWorkerId "solve" issueNumber
  launchWorker
    WorkerSpec
      { workerId,
        workerRepository = repository,
        workerTask = SolveWorkerTaskKind (SolveWorkerTask issueNumber workflow brand),
        workerExistingSession = existingSession,
        workerExistingLogPath = existingLogPath,
        workerResumeProvenance = provenance,
        workerUserMessage = userMessage,
        workerParent = parent,
        workerCreatedAt = now,
        workerMaxRuntimeSeconds = defaultWorkerMaxRuntimeSeconds,
        workerConfigPath = configPath,
        workerWorkflowConfig = workflowConfig,
        workerAssignment = Just assignment
      }

-- | The pull-request twin of 'launchSolveWorker', assignment and all.
launchPullRequestWorker :: RecordedAssignment -> Repository -> Int -> PullRequestOrigin -> PullRequestAction -> Maybe Text -> Maybe FilePath -> ResumeProvenance -> Text -> Maybe WorkerParent -> Maybe FilePath -> WorkflowConfig -> IO (Either WorkerLaunchRefusal WorkerDescriptor)
launchPullRequestWorker assignment repository number origin action existingSession existingLogPath provenance userMessage parent configPath workflowConfig = do
  now <- getCurrentTime
  workerId <- newWorkerId "pr" number
  launchWorker
    WorkerSpec
      { workerId,
        workerRepository = repository,
        workerTask = PullRequestWorkerTaskKind (PullRequestWorkerTask number origin action),
        workerExistingSession = existingSession,
        workerExistingLogPath = existingLogPath,
        workerResumeProvenance = provenance,
        workerUserMessage = userMessage,
        workerParent = parent,
        workerCreatedAt = now,
        workerMaxRuntimeSeconds = defaultWorkerMaxRuntimeSeconds,
        workerConfigPath = configPath,
        workerWorkflowConfig = workflowConfig,
        workerAssignment = Just assignment
      }

-- | Spawns a detached supervisor in its own session with fds 0, 1, and 2
-- attached to @\/dev\/null@ rather than closed.
--
-- 'NoStream' closes the child's descriptor outright, which leaves 0-2
-- unallocated in the supervisor: the first files it opens -- the event
-- journal, a state temp file, a session log -- receive exactly those
-- numbers, and any later write to stdout or stderr (an RTS report from one
-- of the forked loops, a library diagnostic) is appended straight into the
-- JSONL that 'monitorWorker' and 'leaseIsActive' parse. Holding all three
-- open on @\/dev\/null@ discards stray writes harmlessly and keeps newly
-- opened files off descriptors 0-2 for the process's whole life.
--
-- Only this supervisor spawn is configured here. Provider processes carry
-- their own explicit pipes (see "Kanban.Solve" and "Kanban.PullRequestFlow")
-- and are unaffected.
--
-- 'createProcess' closes a 'UseHandle' in the parent itself once the child
-- mapping is established, so the bracket matters only when the spawn throws;
-- 'hClose' on an already-closed handle is a no-op, which keeps both paths
-- leak-free.
spawnDetachedSupervisor :: FilePath -> [String] -> IO (Either IOException ProcessHandle)
spawnDetachedSupervisor executable arguments =
  bracket openNullStreams closeNullStreams $ \(inHandle, outHandle, errHandle) -> do
    started <-
      try @IOException $
        createProcess
          (proc executable arguments)
            { std_in = UseHandle inHandle,
              std_out = UseHandle outHandle,
              std_err = UseHandle errHandle,
              close_fds = True,
              new_session = True
            }
    pure (fmap (\(_, _, _, processHandle) -> processHandle) started)
  where
    openNullStreams =
      (,,)
        <$> openFile "/dev/null" ReadMode
        <*> openFile "/dev/null" WriteMode
        <*> openFile "/dev/null" WriteMode
    closeNullStreams (inHandle, outHandle, errHandle) =
      mapM_ (void . try @IOException . hClose) [inHandle, outHandle, errHandle]

-- | The assignment is a launch input, not something the supervisor resolves
-- for itself: whoever reached here already resolved this session's cell once
-- or replayed the one a previous worker recorded, and a roster that could
-- not supply it refused before this function was ever called — before any
-- lease, specification, or cache directory entry existed. Writing it into
-- the specification is what carries it to the detached supervisor, which
-- reads no roster of its own.
-- | Why a launch produced no worker.
--
-- The two are different answers to different questions and a caller acts on
-- them differently: an item whose turn is already running is one to /join/,
-- while everything else is a launch that failed. Collapsing them is what made
-- a second advancer of one autosolve action report a stopped run instead of
-- observing the turn that was already under way.
data WorkerLaunchRefusal
  = WorkerTurnAlreadyRunning (Maybe WorkerId) Text
  | WorkerLaunchFailed Text
  deriving stock (Eq, Show)

workerLaunchRefusalMessage :: WorkerLaunchRefusal -> Text
workerLaunchRefusalMessage (WorkerTurnAlreadyRunning _ message) = message
workerLaunchRefusalMessage (WorkerLaunchFailed message) = message

launchWorker :: WorkerSpec -> IO (Either WorkerLaunchRefusal WorkerDescriptor)
launchWorker spec = do
  descriptor <- descriptorForSpec spec
  directory <- workerDirectory spec.workerRepository
  createPrivateDirectory XdgCache directory
  leased <- acquireWorkerLeaseFor descriptor
  case leased of
    Left (WorkerLeaseHeld owner message) -> pure (Left (WorkerTurnAlreadyRunning owner message))
    Left (WorkerLeaseUnavailable message) -> pure (Left (WorkerLaunchFailed message))
    Right () -> do
      written <- writePrivateJson descriptor.workerDescriptorSpecPath spec
      case written of
        Left message -> releaseWorkerLease descriptor >> pure (Left (WorkerLaunchFailed message))
        Right () -> do
          executable <- getExecutablePath
          started <- spawnDetachedSupervisor executable ["--worker-spec", descriptor.workerDescriptorSpecPath]
          case started of
            Left exception -> do
              acknowledgeWorker descriptor
              releaseWorkerLease descriptor
              pure (Left (WorkerLaunchFailed ("could not start persistent worker: " <> Text.pack (show exception))))
            Right processHandle -> do
              recordLaunchedSupervisorIdentity descriptor processHandle
              result <- waitForWorkerStart descriptor processHandle workerStartupAttempts
              case result of
                Left _ -> do
                  acknowledgeWorker descriptor
                  -- 'waitForWorkerStart' has already escalated and polled a
                  -- stalled supervisor to a confirmed exit by the time it
                  -- returns 'Left'; a single TERM is not enough to safely
                  -- release here, because the supervisor's own TERM handler
                  -- only stops the work it owns so far (see
                  -- 'runWorkerWithTask'), not a long-running task already under
                  -- way such as the worktree git operations 'runSolve'
                  -- performs before any provider starts. If exit still
                  -- could not be confirmed, the lease is left in place for
                  -- ordinary stale-lease recovery rather than released over
                  -- a possibly-live supervisor.
                  exitCode <- getProcessExitCode processHandle
                  case exitCode of
                    Just _ -> releaseWorkerLease descriptor
                    Nothing -> pure ()
                Right _ -> pure ()
              -- A supervisor that never started is a failed launch, never a
              -- turn someone else owns: this process took the lease.
              pure (either (Left . WorkerLaunchFailed) Right result)

runWorker :: FilePath -> IO (Either Text ())
runWorker = runWorkerWith readProcessSnapshot

runWorkerWith :: IO (Either Text [ProcessIdentity]) -> FilePath -> IO (Either Text ())
runWorkerWith takeSnapshot = runWorkerWithTask takeSnapshot defaultRunTask

-- | Dispatches a worker's task to its real solve/PR-flow implementation.
-- Factored out of 'runWorkerWithTask' so tests can substitute a fake task
-- (e.g. one that stalls before ever registering a provider) while exercising
-- the real supervisor lifecycle, the same way 'takeSnapshot' is already
-- substituted for process verification.
--
-- The unknown-notice aggregator is the supervisor's, not the flow's: a
-- deadline cancels this task outright and emits the terminal envelope from
-- the watchdog thread, so only the supervisor can guarantee the flow's
-- suppressed-occurrence counts are journaled before that envelope rather
-- than lost with the cancelled thread or appended after replay has stopped.
--
-- The model assignment comes from the specification this supervisor was
-- handed, never from the user's live @models.toml@ and never from a cell
-- resolved here: the dashboard refused or allowed this launch against a
-- specific cell, and an edit landing in between must not change what this
-- provider runs on. A specification that records none spawns nothing and
-- names itself, which is the same fail-closed shape the launch boundary's
-- own refusal has.
defaultRunTask :: WorkerSpec -> UnknownAggregator -> (ManagedProcess -> IO ()) -> (WorkerEvent -> IO ()) -> IO ()
defaultRunTask spec aggregator rememberProvider emit = case spec.workerAssignment of
  Nothing -> do
    descriptor <- descriptorForSpec spec
    let message = "worker specification " <> Text.pack descriptor.workerDescriptorSpecPath <> " records no model assignment"
    emit (WorkerDiagnostic message)
    emit (WorkerFinished (SolveFailed message))
  Just assignment -> runTaskWithAssignment spec assignment aggregator rememberProvider emit

-- | Every one of the four recorded values is authoritative, the provider
-- included: the brand each flow spawns comes from 'brandForProvider' on what
-- was recorded rather than from the task's own routing, so a replayed
-- assignment can never reach the other brand's executable.
runTaskWithAssignment :: WorkerSpec -> RecordedAssignment -> UnknownAggregator -> (ManagedProcess -> IO ()) -> (WorkerEvent -> IO ()) -> IO ()
runTaskWithAssignment spec recorded aggregator rememberProvider emit = case spec.workerTask of
  SolveWorkerTaskKind task ->
    runSolve spec.workerRepository task.solveWorkerIssueNumber task.solveWorkerWorkflow brand spec.workerConfigPath spec.workerWorkflowConfig cell spec.workerExistingSession spec.workerExistingLogPath spec.workerResumeProvenance spec.workerUserMessage
      aggregator
      (translateSolveEvent rememberProvider emit)
  PullRequestWorkerTaskKind task ->
    runPullRequestFlow spec.workerRepository task.pullRequestWorkerNumber task.pullRequestWorkerOrigin task.pullRequestWorkerAction brand spec.workerConfigPath spec.workerWorkflowConfig cell spec.workerExistingSession spec.workerExistingLogPath spec.workerResumeProvenance spec.workerUserMessage
      aggregator
      (translatePullRequestEvent rememberProvider emit)
  where
    brand = brandForProvider recorded.recordedAssignmentProvider
    cell = recordedAssignmentCell recorded

-- | Thrown by the 'emit' callback (see 'runWorkerWithTask') when a task's
-- attempt to begin spawning a provider loses its compare-and-swap against
-- 'ProviderSlotClaimedEmpty' — the deadline watchdog has already committed
-- to a verified-empty outcome, so this task must not proceed to actually
-- create a process at all. Raised from deep inside 'runSolve'/
-- 'runPullRequestFlow's own masked spawn bracket, before 'createProcess' is
-- ever reached, so it aborts the spawn attempt outright rather than merely
-- reporting a problem after the fact. Caught, like any other task failure,
-- by 'runWorkerWithTask's own @'try' \@'SomeException'@ around the task
-- thread; its content is never inspected because 'supervisorForcedOutcome' being
-- already set is what makes this outcome irrelevant.
data WorkerDeadlineSpawnRejected = WorkerDeadlineSpawnRejected
  deriving stock (Show)
  deriving anyclass (Exception)

-- | Every mutable cell a persistent worker's supervisor arbitrates on,
-- created once by 'newSupervisorCells' and handed to its helpers as this
-- one aggregate rather than positionally.
--
-- Five of these are 'IORef Bool' and two are 'MVar ()', so passed
-- individually every one of them was silently interchangeable with its
-- same-typed siblings at every call site — including
-- 'supervisorCompletionClaim' and 'supervisorLeaseReleaseClaim', two
-- distinct one-shot claims that arbitrate, respectively, who commits the
-- terminal outcome and who releases the lease. Those two must be raced
-- separately (see 'claimCompletion' and 'claimLeaseRelease'): winning one
-- says nothing about the other, and confusing them would break the
-- one-live-worker invariant silently, on a code path that only runs when a
-- deadline fires. Reaching each cell by name is what makes an exchange a
-- compile error instead.
data SupervisorCells = SupervisorCells
  { -- | This worker's durable 'WorkerState' under the lock every reader and
    -- writer of it takes.
    supervisorState :: MVar WorkerState,
    supervisorEventJournalLock :: EventJournalLock,
    -- | The single source of truth the deadline watchdog and a task's own
    -- spawn-to-registration bracket contend on (see 'ProviderSlot').
    supervisorProviderSlot :: IORef ProviderSlot,
    -- | Stops the heartbeat and census loops, and gates 'rememberProvider'
    -- so a registration racing a deadline or signal is killed rather than
    -- left running.
    supervisorStopped :: IORef Bool,
    -- | Whether this shutdown began with 'sigTERM'/'sigINT', which only
    -- selects the wording of the verification diagnostics.
    supervisorSignalShutdown :: IORef Bool,
    -- | An outcome committed but not yet resolved, because recorded
    -- descendants are still live or could not be verified gone. Carries
    -- @requireVerification@: whether the commit that produced it was itself
    -- unverified, so the orphan poll cannot treat a merely-empty recorded
    -- census as equivalent to a confirmed one.
    supervisorPendingOutcome :: IORef (Maybe (Bool, SolveOutcome)),
    -- | Backs the one-shot claim on committing this worker's terminal
    -- outcome; race it via 'claimCompletion', never directly.
    supervisorCompletionClaim :: IORef Bool,
    -- | Whether a claimed completion actually ran all the way to an emitted
    -- outcome — terminal or orphan-pending, both genuine commitments. It
    -- stays 'False' when the body itself throws (a snapshot that raises
    -- rather than returning 'Left' leaves the completion claim spent but
    -- nothing recorded), which is exactly the case
    -- 'finalizeSupervisorFailure' has to finish off.
    supervisorOutcomeCommitted :: IORef Bool,
    -- | Set unconditionally as soon as the deadline elapses, regardless of
    -- who wins the completion claim: it tells the supervisor the deadline
    -- fired at all — not that the watchdog specifically owns the outcome —
    -- so it knows to wait on 'supervisorWatchdogDone' rather than racing
    -- ahead on a stale read.
    supervisorForcedOutcome :: IORef (Maybe SolveOutcome),
    -- | The task thread a fired deadline cancels.
    supervisorTaskThreadId :: IORef (Maybe ThreadId),
    -- | Delivers the task thread's result to the supervisor exactly once.
    supervisorTaskResult :: MVar (Either SomeException ()),
    -- | Filled unconditionally once 'watchdogLoop' returns, win or lose, so
    -- the supervisor never mistakes a merely-fired deadline for a fully
    -- settled one.
    supervisorWatchdogDone :: MVar (),
    -- | Filled only once 'supervisorPendingOutcome' has actually reached its
    -- final value for a winning deadline claim — not merely once win/lose is
    -- decided — so 'waitForOrphanResolution', on the branch where it loses
    -- the lease-release race, blocks until it can read a settled value
    -- rather than one still in flight.
    supervisorWatchdogAdjudicated :: MVar (),
    -- | Backs the one-shot claim on releasing this worker's lease; race it
    -- via 'claimLeaseRelease', never directly.
    supervisorLeaseReleaseClaim :: IORef Bool
  }

newSupervisorCells :: WorkerState -> IO SupervisorCells
newSupervisorCells initialState = do
  state <- newMVar initialState
  eventJournalLock <- newEventJournalLock
  providerSlot <- newIORef ProviderSlotIdle
  stopped <- newIORef False
  signalShutdown <- newIORef False
  pendingOutcome <- newIORef Nothing
  completionClaim <- newIORef False
  outcomeCommitted <- newIORef False
  forcedOutcome <- newIORef Nothing
  taskThreadId <- newIORef Nothing
  taskResult <- newEmptyMVar
  watchdogDone <- newEmptyMVar
  watchdogAdjudicated <- newEmptyMVar
  leaseReleaseClaim <- newIORef False
  pure
    SupervisorCells
      { supervisorState = state,
        supervisorEventJournalLock = eventJournalLock,
        supervisorProviderSlot = providerSlot,
        supervisorStopped = stopped,
        supervisorSignalShutdown = signalShutdown,
        supervisorPendingOutcome = pendingOutcome,
        supervisorCompletionClaim = completionClaim,
        supervisorOutcomeCommitted = outcomeCommitted,
        supervisorForcedOutcome = forcedOutcome,
        supervisorTaskThreadId = taskThreadId,
        supervisorTaskResult = taskResult,
        supervisorWatchdogDone = watchdogDone,
        supervisorWatchdogAdjudicated = watchdogAdjudicated,
        supervisorLeaseReleaseClaim = leaseReleaseClaim
      }

-- | Only the first caller ever runs @completeBody@: the deadline watchdog
-- and a genuine task-reported outcome can both reach it around the same
-- instant, and once one of them has committed a terminal/orphan outcome,
-- the other must not resurrect or replace it. The watchdog claims this
-- atomically for itself before it even cancels the task (see
-- 'watchdogLoop'), so a deadline reliably wins that race instead of merely
-- attempting to afterward. Whichever side wins runs the body under
-- 'uninterruptibleMask_': claiming the slot only to have a concurrent
-- 'killThread' interrupt it partway would leave no terminal or pending
-- outcome committed at all, stranding the worker with a
-- claimed-but-unfulfilled completion. A watchdog that loses this claim (a
-- task's own completion was already in flight) still calls 'killThread'
-- afterward, but since that target is itself masked there, the call simply
-- blocks until the in-flight completion finishes rather than corrupting it
-- — letting an already-claimed completion run to conclusion instead of
-- being cancelled out from under itself.
claimCompletion :: SupervisorCells -> IO Bool
claimCompletion cells = atomicModifyIORef' cells.supervisorCompletionClaim (\done -> (True, not done))

-- | The one-shot claim on releasing this worker's lease, raced by three
-- parties: 'watchdogLoop' immediately after its delay elapses,
-- 'waitForOrphanResolution' the instant it observes the recorded census go
-- empty, and the supervisor itself as late as it possibly can before
-- releasing (see 'runWorkerWithTask'). Deliberately separate from
-- 'claimCompletion': winning the right to commit the terminal outcome says
-- nothing about who may free the lease, and each of the three call sites
-- documents what its own win and loss mean.
claimLeaseRelease :: SupervisorCells -> IO Bool
claimLeaseRelease cells = atomicModifyIORef' cells.supervisorLeaseReleaseClaim (\claimed -> (True, not claimed))

runWorkerWithTask :: IO (Either Text [ProcessIdentity]) -> (WorkerSpec -> UnknownAggregator -> (ManagedProcess -> IO ()) -> (WorkerEvent -> IO ()) -> IO ()) -> FilePath -> IO (Either Text ())
runWorkerWithTask takeSnapshot buildRunTask specPath = do
  decoded <- decodeFile specPath
  case decoded of
    Left message -> pure (Left message)
    Right spec -> do
      descriptor <- descriptorForSpec spec
      directory <- workerDirectory spec.workerRepository
      createPrivateDirectory XdgCache directory
      pid <- fromIntegral <$> getProcessID
      now <- getCurrentTime
      selfSnapshot <- readProcessSnapshot
      let selfIdentity = either (const Nothing) (identityForPid pid) selfSnapshot
      cells <-
        newSupervisorCells
          WorkerState
            { workerStateId = spec.workerId,
              workerStateStatus = WorkerStarting,
              workerStateWorkerPid = pid,
              workerStateWorkerIdentity = selfIdentity,
              workerStateProviderPid = Nothing,
              workerStateProviderIdentity = Nothing,
              workerStateSessionId = Nothing,
              workerStateLogPath = Nothing,
              workerStateHeartbeatAt = now,
              workerStateLastActivity = "starting",
              workerStateKnownProcesses = []
            }
      noticeAggregator <- newUnknownAggregator
      let registeredProvider slot = case slot of
            ProviderSlotRegistered process -> Just process
            _ -> Nothing
      let stopOwnedWork = do
            writeIORef cells.supervisorStopped True
            writeIORef cells.supervisorSignalShutdown True
            readIORef cells.supervisorProviderSlot >>= mapM_ killManagedProcess . registeredProvider
            terminateRecordedProcesses cells.supervisorState
      previousTermHandler <- installHandler sigTERM (Catch stopOwnedWork) Nothing
      previousInterruptHandler <- installHandler sigINT (Catch stopOwnedWork) Nothing
      persistState descriptor cells.supervisorState
      void . forkIO $ heartbeatLoop descriptor cells
      void . forkIO $ processCensusLoop descriptor cells
      let emitRaw event = do
            appendWorkerEvent descriptor cells.supervisorEventJournalLock event
            updateWorkerState descriptor cells.supervisorState event
            case event of
              WorkerFinished _ -> writeIORef cells.supervisorStopped True
              _ -> pure ()
          -- 'verified' is False only for the deadline watchdog's own call,
          -- when its identity-verified kill of the current provider and
          -- recorded census could not be confirmed complete (e.g. a
          -- snapshot failure). An empty census in that case may simply mean
          -- nothing was ever recorded for a provider that had not finished
          -- registering when the deadline fired, not that it is actually
          -- gone, so this retains orphan-pending state rather than
          -- finalizing on that gap. A genuine task-reported outcome always
          -- passes True: the provider it reports for has already exited on
          -- its own.
          -- The 'Bool' recorded alongside a pending outcome is
          -- 'requireVerification': whether the commit that produced it was
          -- itself unverified (came from 'completeBody's False case),
          -- carried forward so the orphan-resolution poll below cannot
          -- treat a merely-empty recorded census as equivalent to an
          -- actually-confirmed one (see 'waitForOrphanResolution').
          -- Reaching an emitted outcome at all is recorded in
          -- 'supervisorOutcomeCommitted'; see that field for what its
          -- staying False means and who finishes such a claim off.
          completeBody verified outcome = uninterruptibleMask_ $ do
            -- First, before any terminal or orphan envelope: replay stops
            -- at the terminal envelope, and a deadline reaches here having
            -- already killed the provider and about to cancel the task
            -- thread, so this is the last and only point at which the
            -- flow's suppressed unknown-event counts can still be
            -- journaled where replay will see them. Sealing here is what
            -- makes that final: the stream loop is still live and may be
            -- draining buffered output, and a sealed aggregator refuses
            -- every unknown notice it produces from now on rather than
            -- letting them restart after the summary. The flow seals the
            -- same aggregator on its own unforced paths; the seal is
            -- one-shot and writes under its own lock, so exactly one side
            -- ever reports, and if the flow won it, this blocks until its
            -- summaries are written rather than terminalizing over them.
            sealUnknownAggregates noticeAggregator (emitRaw . WorkerAgentOutput)
            refreshProcessCensus descriptor cells.supervisorState
            result <- liveRecordedProcessesWith takeSnapshot cells.supervisorState
            case result of
              Left message -> do
                known <- withMVar cells.supervisorState (pure . (.workerStateKnownProcesses))
                signalTriggered <- readIORef cells.supervisorSignalShutdown
                let operation = if signalTriggered then "signal shutdown" else "completion" :: Text
                writeIORef cells.supervisorPendingOutcome (Just (not verified, outcome))
                emitRaw (WorkerDiagnostic (operation <> ": could not verify recorded descendants are gone (" <> message <> "); retaining orphan state and lease"))
                emitRaw (WorkerOrphansDetected outcome known)
              Right survivors
                | null survivors, verified -> emitRaw (WorkerFinished outcome)
                | null survivors -> do
                    writeIORef cells.supervisorPendingOutcome (Just (True, outcome))
                    emitRaw (WorkerDiagnostic "deadline: could not verify the current provider was terminated; retaining orphan state and lease")
                    emitRaw (WorkerOrphansDetected outcome survivors)
                | otherwise -> do
                    writeIORef cells.supervisorPendingOutcome (Just (not verified, outcome))
                    emitRaw (WorkerOrphansDetected outcome survivors)
            writeIORef cells.supervisorOutcomeCommitted True
          -- Claiming and running the completion body happen under the same
          -- mask: without it, an async exception (the watchdog's own
          -- 'killThread', losing the race to claim completion itself) could
          -- land in the gap between 'claimCompletion' succeeding and
          -- 'completeBody' establishing its own 'uninterruptibleMask_',
          -- leaving 'supervisorCompletionClaim' claimed but no outcome ever
          -- committed — stranding the supervisor on its 'takeMVar' of
          -- 'supervisorTaskResult' forever. A
          -- 'killThread' targeting a thread already inside this mask simply
          -- blocks until the claimed completion finishes, letting it run to
          -- conclusion instead of being cut off partway.
          --
          -- The atomic 'claimCompletion' race alone is not sufficient for an
          -- already-overdue spec: a trivially fast task can call this before
          -- 'watchdogLoop' is ever even scheduled, let alone reaches its own
          -- 'claimCompletion' attempt, since its zero-length delay does not
          -- make the GHC scheduler run it any sooner than a normal one. Left
          -- unchecked, that lets a task's own success claim the outcome for
          -- a worker that was already over its deadline before it started.
          -- Rechecking wall-clock time here, symmetric to the supervisor's
          -- own late 'claimLeaseRelease' recheck below, closes that gap:
          -- once the deadline has genuinely passed, every normal completion
          -- attempt (this function's only caller, 'emit') defers
          -- unconditionally, leaving 'supervisorCompletionClaim' unclaimed
          -- for the watchdog — whose own delay has, by the same wall clock, also
          -- already elapsed — to win outright whenever it does get
          -- scheduled.
          complete outcome = uninterruptibleMask_ $ do
            completeNow <- getCurrentTime
            let completeDeadline = addUTCTime (fromIntegral spec.workerMaxRuntimeSeconds) spec.workerCreatedAt
            unless (completeNow >= completeDeadline) (claimCompletion cells >>= \won -> when won (completeBody True outcome))
          -- 'WorkerProviderSpawning' is intercepted here rather than
          -- flowing through 'emitRaw': it exists purely to bracket the
          -- spawn-to-registration window in 'supervisorProviderSlot' for
          -- 'terminateProviderRefWith' to consult (see 'watchdogLoop'), not
          -- to become a durable event-log entry or 'WorkerState' field.
          --
          -- 'True' (about to spawn) is a genuine compare-and-swap against
          -- 'ProviderSlotIdle', the same claim 'terminateProviderRefWith'
          -- makes for the opposite outcome ("verified empty" —
          -- 'ProviderSlotClaimedEmpty'). Only one of the two attempts can
          -- ever win the transition away from 'ProviderSlotIdle': if the
          -- watchdog got there first, this loses and throws
          -- 'WorkerDeadlineSpawnRejected' right here, before 'runSolve'/
          -- 'runPullRequestFlow' ever reaches their own 'createProcess' —
          -- unlike the old two-ref design, there is no window left in which
          -- a real process could still be created after the watchdog has
          -- already committed to nothing being here. 'False' (the spawn
          -- attempt concluded without a live registration) reverts the slot
          -- unconditionally: only this task thread ever writes
          -- 'ProviderSlotSpawning' or moves off it short of a genuine
          -- registration, so no compare-and-swap is needed for that half.
          emit event = case event of
            WorkerFinished outcome -> complete outcome
            WorkerProviderSpawning True -> do
              claimed <- atomicModifyIORef' cells.supervisorProviderSlot $ \slot -> case slot of
                ProviderSlotIdle -> (ProviderSlotSpawning, True)
                _ -> (slot, False)
              unless claimed (throwIO WorkerDeadlineSpawnRejected)
            WorkerProviderSpawning False -> writeIORef cells.supervisorProviderSlot ProviderSlotIdle
            _ -> emitRaw event
          -- Identity and census recording run unconditionally, before ever
          -- checking whether a stop was already requested: a deadline that
          -- fires mid-spawn can only retain orphan-pending state (rather
          -- than vacuously finalizing — see 'terminateProviderRefWith') if
          -- this actually populates 'workerStateProviderIdentity' and
          -- 'workerStateKnownProcesses' for the watchdog's later verified
          -- kill and 'waitForOrphanResolution's poll to find anything at
          -- all. Recording first and killing after (when already stopped)
          -- means even a late registration still leaves a real, verifiable
          -- trail instead of a bare best-effort signal with nothing behind
          -- it to confirm against.
          --
          -- Reached only once this task's own spawn claim (the 'emit' case
          -- above) has already won its compare-and-swap into
          -- 'ProviderSlotSpawning', so a plain 'writeIORef' here is safe:
          -- the watchdog's competing claim can only ever act on
          -- 'ProviderSlotIdle', which this call site is guaranteed to have
          -- already left behind.
          rememberProvider process = do
            writeIORef cells.supervisorProviderSlot (ProviderSlotRegistered process)
            processId <- managedProcessPid process
            case processId of
              Just providerPid -> do
                recordProviderIdentity descriptor cells.supervisorState (fromIntegral providerPid)
                emit (WorkerProviderStarted (fromIntegral providerPid))
                refreshProcessCensus descriptor cells.supervisorState
                stopRequested <- readIORef cells.supervisorStopped
                -- A late registration can land after the watchdog already
                -- gave up on an empty 'ProviderSlotSpawning' census (nothing
                -- was recorded yet at that moment) and moved on. This must
                -- not settle for the same best-effort, non-verifying signal
                -- 'killManagedProcess' alone provides: if 'recordProviderIdentity'
                -- and/or the 'refreshProcessCensus' call just above also hit
                -- a snapshot failure, 'workerStateProviderIdentity' stays
                -- unset -- and, since neither is ever retried, permanently
                -- starves 'refreshProcessCensus's own descendant walk of a
                -- root -- leaving any descendant in another process group
                -- entirely undiscovered, with 'waitForOrphanResolution'
                -- later accepting that permanently-empty census as fully
                -- resolved and releasing the lease out from under it.
                -- 'terminateProviderRefWith' independently re-derives the
                -- provider's identity and descendants from a snapshot it
                -- takes itself, using the live handle already recorded in
                -- 'supervisorProviderSlot' -- the exact same call the watchdog
                -- makes for this purpose -- so this retries that capture
                -- here rather than trusting whatever the census already
                -- holds. The subsequent 'terminateRecordedStateProcessesWith'
                -- then kills and verifies everything that capture just
                -- merged in, not only the direct provider.
                when stopRequested $ do
                  void (terminateProviderRefWith takeSnapshot cells.supervisorState cells.supervisorProviderSlot)
                  void (withMVar cells.supervisorState (terminateRecordedStateProcessesWith takeSnapshot))
              Nothing -> do
                let message = "provider started without an observable process-group id; terminating it for safety"
                emit (WorkerDiagnostic message)
                killManagedProcess process
          runTask = buildRunTask spec noticeAggregator rememberProvider emit
      -- `runTask` runs under `restore` so a deadline's `killThread` can
      -- still cancel it — that's the whole point. But once it has returned
      -- or been caught by `try`, the handoff to `supervisorTaskResult` runs
      -- fully masked (the outer `mask` defers a pending exception at the
      -- statement boundary right after `try` returns; the inner
      -- `uninterruptibleMask_` then covers `putMVar` itself, since `putMVar`
      -- remains an interruptible operation even under plain `mask`). Without
      -- this, an exception landing in that gap could leave a fully computed
      -- result never delivered, blocking the supervisor on its `takeMVar`
      -- of `supervisorTaskResult` forever. `uninterruptibleMask_` is safe
      -- here specifically because `supervisorTaskResult` is always empty at
      -- this point (this is its one and only producer), so `putMVar` cannot
      -- itself actually block.
      -- Everything below runs after the descriptor, journal, and state
      -- facilities exist, so a synchronous failure here can still be
      -- recorded durably. Without this guard such a failure kills the
      -- supervisor with no terminal event at all: the death is only noticed
      -- much later, by the stale-heartbeat path. Task exceptions are already
      -- caught around 'runTask' below; this covers the orchestration outside
      -- that boundary, including the reporting and cleanup path itself.
      --
      -- Exceptions raised inside the three forked loops are deliberately out
      -- of reach here -- they are unlinked, so they never reach this thread.
      -- Discarding stray stderr (see 'spawnDetachedSupervisor') is what keeps
      -- those from corrupting the journal.
      let finalizeSupervisorFailure exception = do
            let message = "persistent worker supervisor failed: " <> Text.pack (show exception)
            -- Best effort throughout: the storage this wants to write to may
            -- be exactly what failed, and a raise here would defeat the
            -- purpose of the guard.
            void . try @SomeException $ do
              -- Stop owned work first, then let 'completeBody' do the
              -- verification: it emits 'WorkerFinished' only once the
              -- recorded descendants are confirmed gone, and otherwise
              -- records the orphan outcome and leaves the lease in place.
              writeIORef cells.supervisorStopped True
              readIORef cells.supervisorProviderSlot >>= mapM_ killManagedProcess . registeredProvider
              terminateRecordedProcesses cells.supervisorState
              emitRaw (WorkerDiagnostic message)
              -- A completion already committed by the task or the watchdog
              -- stands; this only finishes off a claim that was spent
              -- without ever recording an outcome.
              committed <- readIORef cells.supervisorOutcomeCommitted
              unless committed (completeBody True (SolveFailed message))
              -- The lease follows the same rule as the normal path: release
              -- it only when no orphan outcome is pending and the watchdog
              -- has not claimed the release for itself.
              stillPending <- readIORef cells.supervisorPendingOutcome
              when (stillPending == Nothing) $ do
                wonRelease <- claimLeaseRelease cells
                when wonRelease (releaseWorkerLease descriptor)
            pure (Left message)
      orchestrated <- try @SomeException $ do
        taskThreadId <- forkIO $ mask $ \restore -> do
          result <- try @SomeException (restore runTask)
          uninterruptibleMask_ (putMVar cells.supervisorTaskResult result)
        writeIORef cells.supervisorTaskThreadId (Just taskThreadId)
        void . forkIO $ watchdogLoop takeSnapshot spec cells completeBody emitRaw
        taskResult <- takeMVar cells.supervisorTaskResult
        forcedOutcome <- readIORef cells.supervisorForcedOutcome
        case forcedOutcome of
          -- 'supervisorForcedOutcome' is only consulted here to skip the redundant
          -- fallback completion below — it can still be stale (the deadline
          -- can fire after this exact read), which is harmless for that one
          -- decision: the fallback goes through the same atomic
          -- 'claimCompletion' either way, so at worst this attempts it
          -- pointlessly. Whether it is safe to actually release the lease
          -- below is decided separately, immediately before doing so, via
          -- 'claimLeaseRelease' — a real, race-free arbitration rather than a
          -- one-time snapshot like this one.
          Just _ -> pure ()
          Nothing -> case taskResult of
            Right () -> do
              stopped <- readIORef cells.supervisorStopped
              pending <- readIORef cells.supervisorPendingOutcome
              if stopped || pending /= Nothing
                then pure ()
                else complete (SolveFailed "persistent worker task ended without a terminal provider event")
            Left exception -> do
              refreshProcessCensus descriptor cells.supervisorState
              readIORef cells.supervisorProviderSlot >>= mapM_ killManagedProcess . registeredProvider
              let message = "persistent worker failed: " <> Text.pack (show exception)
              void . try @SomeException $ do
                emitRaw (WorkerDiagnostic message)
                complete (SolveFailed message)
        pending <- readIORef cells.supervisorPendingOutcome
        -- Verification always runs to a real conclusion here regardless of
        -- `supervisorStopped`: a signal-triggered shutdown already set that flag
        -- true (to stop the heartbeat/census loops), and gating this wait on
        -- it too would let the lease below release on an unverified kill.
        -- 'waitForOrphanResolution' re-reads `supervisorPendingOutcome` itself on
        -- every poll rather than trusting this one-time snapshot, since the
        -- deadline watchdog can still take over that same ref after this
        -- point (see 'watchdogLoop'); this read only decides whether to
        -- enter the wait at all. When it does, its own return value settles
        -- whether this has already won 'claimLeaseRelease' for itself (see
        -- its own documentation for why re-attempting the claim below in
        -- that case would be actively harmful, not merely redundant) —
        -- 'Nothing' here means the wait was never entered at all, in which
        -- case the claim below still needs to be attempted fresh.
        alreadyWonLeaseRelease <-
          if pending /= Nothing
            then Just <$> waitForOrphanResolution descriptor spec takeSnapshot cells emitRaw
            else pure Nothing
        writeIORef cells.supervisorStopped True
        -- Whether it is safe to release the lease now without waiting for the
        -- watchdog is decided by a genuine race against it, claimed as late
        -- as possible (right here) rather than inferred from any earlier,
        -- necessarily stale snapshot: everything above (fallback completion,
        -- orphan resolution) can finish before the deadline ever fires, so an
        -- early check has no way to know whether the watchdog will still act
        -- later. Winning this claim means the watchdog's own 'threadDelay'
        -- has not elapsed yet (or, if it does later, 'watchdogLoop' will find
        -- this already claimed and do nothing) — safe to proceed directly.
        -- Losing it means the watchdog already committed to firing and may
        -- still be mid-sequence (its own bounded termination-grace waits);
        -- 'supervisorWatchdogDone' blocks until that has genuinely finished.
        --
        -- The atomic race alone is not sufficient for an already-overdue
        -- spec: 'watchdogLoop' is forked after the task thread, and for a
        -- trivially fast task there is no guarantee the watchdog thread ever
        -- gets scheduled — let alone reaches its own 'claimLeaseRelease' —
        -- before this point, even though its delay is already zero and it is
        -- entitled to fire immediately. Thread scheduling order has no
        -- relationship to wall-clock deadline elapsed-ness, so this
        -- independently rechecks the deadline directly against the current
        -- time: if it has already passed, this treats itself as having lost
        -- regardless of what the atomic race would otherwise say, leaving
        -- 'claimLeaseRelease' unclaimed for the watchdog (whenever it
        -- eventually runs) to win outright. Only reached when
        -- 'alreadyWonLeaseRelease' is 'Nothing' — 'waitForOrphanResolution'
        -- already settled this exact question, via the same claim, whenever
        -- it ran at all.
        wonLeaseRelease <- case alreadyWonLeaseRelease of
          Just settled -> pure settled
          Nothing -> do
            releaseCheckNow <- getCurrentTime
            let deadline = addUTCTime (fromIntegral spec.workerMaxRuntimeSeconds) spec.workerCreatedAt
            if releaseCheckNow >= deadline then pure False else claimLeaseRelease cells
        unless wonLeaseRelease (takeMVar cells.supervisorWatchdogDone)
        releaseWorkerLease descriptor
      -- Restored on both paths so an in-process caller does not inherit the
      -- supervisor's signal handlers.
      void (installHandler sigTERM previousTermHandler Nothing)
      void (installHandler sigINT previousInterruptHandler Nothing)
      case orchestrated of
        Right () -> pure (Right ())
        Left exception -> finalizeSupervisorFailure exception

translateSolveEvent :: (ManagedProcess -> IO ()) -> (WorkerEvent -> IO ()) -> SolveEvent -> IO ()
translateSolveEvent rememberProvider emit solveEvent = case solveEvent of
  SolveProcessStarted _ _ process -> rememberProvider process
  SolveProcessSpawning _ pending -> emit (WorkerProviderSpawning pending)
  SolveLogOpened _ path -> emit (WorkerLogOpened path)
  SolveSessionIdentified _ sessionId -> emit (WorkerSessionIdentified sessionId)
  SolveOutput _ output -> emit (WorkerAgentOutput output)
  SolveDiagnostic _ message -> emit (WorkerDiagnostic message)
  SolveProcessFinished _ outcome -> emit (WorkerFinished outcome)

translatePullRequestEvent :: (ManagedProcess -> IO ()) -> (WorkerEvent -> IO ()) -> PullRequestFlowEvent -> IO ()
translatePullRequestEvent rememberProvider emit flowEvent = case flowEvent of
  PullRequestProcessStarted _ _ _ process -> rememberProvider process
  PullRequestProcessSpawning _ pending -> emit (WorkerProviderSpawning pending)
  PullRequestLogOpened _ path -> emit (WorkerLogOpened path)
  PullRequestSessionIdentified _ sessionId -> emit (WorkerSessionIdentified sessionId)
  PullRequestFlowOutput _ output -> emit (WorkerAgentOutput output)
  PullRequestFlowDiagnostic _ message -> emit (WorkerDiagnostic message)
  PullRequestProcessFinished _ outcome -> emit (WorkerFinished outcome)

waitForWorkerStart :: WorkerDescriptor -> ProcessHandle -> Int -> IO (Either Text WorkerDescriptor)
waitForWorkerStart descriptor processHandle attempts = do
  stateExists <- doesFileExist descriptor.workerDescriptorStatePath
  if stateExists
    then pure (Right descriptor)
    else do
      exitCode <- getProcessExitCode processHandle
      case exitCode of
        Just code -> pure (Left ("persistent worker exited before initialization: " <> Text.pack (show code)))
        Nothing
          | attempts <= 0 -> do
              -- A single TERM is not sufficient to safely hand this worktree
              -- to a replacement worker: the supervisor's own TERM handler
              -- only stops the work it owns so far, not a task already in
              -- flight (see 'runWorkerWithTask'), so this escalates to SIGKILL
              -- and polls for a confirmed exit before giving up on it.
              void (confirmStalledSupervisorStopped processHandle)
              pure (Left "persistent worker did not initialize within three seconds")
          | otherwise -> do
              -- Retried on every poll, not just once at spawn: recovery
              -- paths reached after this launcher itself is gone (see
              -- 'supervisorLaunchIdentityPresenceWith') have no other way to
              -- learn this supervisor's identity, so this gives a transient
              -- snapshot failure the whole startup window to resolve rather
              -- than one attempt.
              recordLaunchedSupervisorIdentity descriptor processHandle
              threadDelay workerStartupIntervalMicros
              waitForWorkerStart descriptor processHandle (attempts - 1)

-- | Escalates a startup-stalled supervisor to a confirmed exit rather than
-- merely signalling it, so the caller can tell "definitely dead, safe to
-- release its lease" from "could not confirm, leave the lease for ordinary
-- stale-lease recovery" ('getProcessExitCode' after this call reflects
-- which case applied).
confirmStalledSupervisorStopped :: ProcessHandle -> IO Bool
confirmStalledSupervisorStopped processHandle = do
  (managed, _) <- managedProcess processHandle
  killManagedProcess managed
  pollExit workerTerminationAttempts
  where
    pollExit attempts = do
      exitCode <- getProcessExitCode processHandle
      case exitCode of
        Just _ -> pure True
        Nothing
          | attempts <= 0 -> pure False
          | otherwise -> threadDelay workerTerminationPollMicros >> pollExit (attempts - 1)

updateWorkerState :: WorkerDescriptor -> MVar WorkerState -> WorkerEvent -> IO ()
updateWorkerState descriptor stateLock event = modifyMVar_ stateLock $ \state -> do
  now <- getCurrentTime
  let updated = case event of
        -- 'rememberProvider' reads the deadline watchdog's stop guard before
        -- this event ever reaches the state lock, so a registration already
        -- past that read can still land here after the watchdog has since
        -- fired and committed a terminal or orphan-pending status. Once
        -- settled, that status must never be reverted back to running by a
        -- late arrival like this one.
        WorkerProviderStarted processId -> case state.workerStateStatus of
          WorkerTerminal _ -> state
          WorkerOrphaned _ -> state
          _ -> state {workerStateStatus = WorkerRunning, workerStateProviderPid = Just processId, workerStateLastActivity = "provider running"}
        -- Never reaches here at runtime: 'runWorkerWithTask's own 'emit'
        -- intercepts this before it ever reaches 'emitRaw'/'updateWorkerState'
        -- (see its definition) — this case exists only so the match stays
        -- exhaustive over 'WorkerEvent'.
        WorkerProviderSpawning _ -> state
        WorkerLogOpened path -> state {workerStateLogPath = Just path, workerStateLastActivity = "log opened"}
        WorkerSessionIdentified sessionId -> state {workerStateSessionId = Just sessionId, workerStateLastActivity = "session identified"}
        WorkerAgentOutput output -> state {workerStateLastActivity = Text.take 160 output.agentEventSummary}
        WorkerDiagnostic _ -> state {workerStateLastActivity = "diagnostic output"}
        WorkerOrphansDetected outcome surviving ->
          state
            { workerStateStatus = WorkerOrphaned outcome,
              workerStateProviderPid = Nothing,
              workerStateProviderIdentity = Nothing,
              workerStateLastActivity = showProcessCount surviving <> " orphaned subprocesses"
            }
        WorkerFinished outcome -> state {workerStateStatus = WorkerTerminal outcome, workerStateProviderPid = Nothing, workerStateProviderIdentity = Nothing, workerStateLastActivity = terminalActivity outcome}
      heartbeat = updated {workerStateHeartbeatAt = now}
  writeState descriptor heartbeat
  pure heartbeat

heartbeatLoop :: WorkerDescriptor -> SupervisorCells -> IO ()
heartbeatLoop descriptor cells = do
  threadDelay workerHeartbeatIntervalMicros
  stopped <- readIORef cells.supervisorStopped
  unless stopped $ do
    modifyMVar_ cells.supervisorState $ \state -> do
      now <- getCurrentTime
      let updated = state {workerStateHeartbeatAt = now}
      writeState descriptor updated
      pure updated
    heartbeatLoop descriptor cells

processCensusLoop :: WorkerDescriptor -> SupervisorCells -> IO ()
processCensusLoop descriptor cells = do
  threadDelay workerCensusIntervalMicros
  stopped <- readIORef cells.supervisorStopped
  unless stopped $ do
    refreshProcessCensus descriptor cells.supervisorState
    processCensusLoop descriptor cells

-- | Polls until a fresh snapshot verifies every recorded descendant is gone,
-- then emits the terminal outcome. Runs to a real conclusion unconditionally
-- — it does not stop early on a "stop requested" signal — because its
-- caller relies on this to gate the worker's lease release: a
-- signal-triggered shutdown must not let an in-flight stop request
-- short-circuit verification. 'supervisorSignalShutdown' is read only to label a
-- failure diagnostic as signal-triggered, never to gate the loop itself. A
-- snapshot failure retains the pending state and reports a diagnostic once
-- per distinct failure message rather than once per poll.
--
-- The pending outcome (and whether it still needs verification even once
-- the recorded census reads empty — see 'completeBody') is re-read from
-- 'supervisorPendingOutcome' on every iteration rather than captured once
-- at the start: the deadline watchdog can take over this same cell after
-- this loop has already begun (a normal completion can win
-- 'claimCompletion' and start this poll well before the deadline elapses;
-- see 'watchdogLoop'), and only
-- a re-read on each pass ever observes that takeover — the loop otherwise
-- has no other way to learn its outcome changed out from under it. This
-- assumes the caller only starts the loop once 'supervisorPendingOutcome'
-- already holds 'Just'; a race where it is somehow 'Nothing' on first read never
-- happens in practice but degrades to a harmless no-op rather than a
-- crash.
--
-- Finalizing is an atomic *consume* of 'supervisorPendingOutcome' — one
-- 'atomicModifyIORef'' call that reads whatever value is present and
-- simultaneously replaces it with 'Nothing' — rather than a plain read
-- followed by a separate 'emit' call. A plain read-then-act still leaves a
-- gap (the census check in between takes a real snapshot, wide enough for
-- the watchdog's takeover to land inside it) in which this could act on an
-- already-stale value even after re-reading closer to the 'emit' call:
-- however narrow, that gap is still a real race, not merely an unlikely
-- one. The atomic consume has none: whatever 'watchdogLoop' last wrote is
-- necessarily what this reads, because there is no separate "read" step
-- for a write to land inside. 'watchdogLoop' symmetrically only ever
-- writes its takeover via a matching compare-and-swap that no-ops once
-- this has already consumed the value, so a takeover can never be silently
-- resurrected after finalization already happened.
--
-- That atomicity prevents a torn read, but not a *stale-but-whole* one:
-- 'watchdogLoop' only ever gets a chance to write its own takeover once
-- its thread is actually scheduled, which — same as 'claimLeaseRelease'
-- and 'complete' — has no relationship to wall-clock deadline
-- elapsed-ness. A recorded process dying on its own (not from any kill
-- this worker performed) can make this observe an empty census right as,
-- or just after, the deadline passes, while the value still sitting in
-- 'supervisorPendingOutcome' is the original pre-deadline one.
--
-- No wall-clock check can decide whether this or 'watchdogLoop' gets to
-- finalize: reading 'now' and separately consuming 'supervisorPendingOutcome'
-- are two steps, not one atomic one, so a pause of any length between
-- them (a GC pause, a context switch to some other runnable thread) can
-- let a "not yet due" reading go stale before the consume actually runs,
-- no matter how few instructions sit in between or how many times it is
-- rechecked — a wall-clock recheck answers "has the deadline passed,"
-- never "has the watchdog thread actually run yet," and only the second
-- question is the one that matters here.
--
-- What actually closes it is racing 'watchdogLoop' for 'claimLeaseRelease'
-- itself — the exact same single atomic compare-and-swap the supervisor
-- uses for its own later lease-release decision (see 'runWorkerWithTask'),
-- not a separate check gated by a stale boolean. Winning it here means
-- 'watchdogLoop' can never win it afterward (it is one-shot), so its own
-- 'claimLeaseRelease' attempt is guaranteed to lose and do nothing further
-- at all — safe to consume 'supervisorPendingOutcome' immediately, exactly
-- as the normal completion left it. Losing it means 'watchdogLoop' already
-- won and is (or is about to be) writing its takeover into
-- 'supervisorPendingOutcome'; 'supervisorWatchdogAdjudicated' — filled only
-- once that write has actually landed, not merely once win/lose is
-- decided, see
-- 'watchdogLoop' — is then read (blocking, never spinning) to wait for
-- it, guaranteed to unblock because a losing attempt here can only happen
-- after 'watchdogLoop' has already won the same claim, which it only
-- ever attempts once its own identically-computed delay has elapsed.
--
-- The caller (see 'runWorkerWithTask') never independently attempts
-- 'claimLeaseRelease' after this returns 'True': doing so would be not
-- just redundant but actively harmful, forcing every worker that ever
-- passes through this poll — including the overwhelmingly common case of
-- resolving long before any deadline is near — to needlessly wait out
-- watchdogLoop's entire remaining delay before releasing its lease, even
-- though nothing is left for that watchdog to do. Returning whether this
-- itself won lets the caller skip that attempt entirely and proceed
-- directly, while still correctly deferring to 'supervisorWatchdogDone' on the
-- (rare, deadline-adjacent) branch where this lost instead.
--
-- Winning 'claimLeaseRelease' settles *who* gets to release the lease, but
-- not, on its own, *which* outcome is correct to report: this poll can win
-- that claim because the recorded census happened to go empty on its own
-- (not from any kill this worker performed) at almost any real wall-clock
-- moment, including one already past the deadline if 'watchdogLoop' simply
-- has not been scheduled yet — GHC's scheduler gives no upper bound on how
-- late a runnable thread's next instruction actually executes, so no
-- design can guarantee the watchdog thread reacts to an elapsed
-- 'threadDelay' promptly. Reporting the stale pre-deadline 'outcome'
-- whenever that happens would let a completion that in fact only finished
-- verifying itself after the deadline read as on-time, purely as an
-- artifact of which thread the scheduler happened to run first.
--
-- The fix is not another check-then-act wall-clock guard like the ones
-- this module has already rejected elsewhere (see 'complete' and this
-- very function's own atomic-consume documentation above) — those are
-- unsound specifically because two *concurrent* actors are still racing
-- each other across the gap between the check and the act. Here, by the
-- time this reads 'now', that race is already over: winning
-- 'claimLeaseRelease' is a one-shot claim, so 'watchdogLoop' is
-- structurally guaranteed to lose its own attempt and do nothing further
-- at all (see its own documentation) the instant this wins. Nothing else
-- can still overwrite 'supervisorPendingOutcome', kill anything, or otherwise
-- invalidate this decision after that point — there is no concurrent actor
-- left to race, only a plain fact (has the deadline passed) to read once
-- and act on immediately. Checking it only in the branch where this itself
-- won avoids the same recheck when the *watchdog* won instead: that branch
-- already reports the correct outcome unconditionally, because
-- 'watchdogLoop' only ever writes 'workerDeadlineOutcome' into
-- 'supervisorPendingOutcome' when it wins, whether via 'completeBody' or its own
-- takeover compare-and-swap.
waitForOrphanResolution :: WorkerDescriptor -> WorkerSpec -> IO (Either Text [ProcessIdentity]) -> SupervisorCells -> (WorkerEvent -> IO ()) -> IO Bool
waitForOrphanResolution descriptor spec takeSnapshot cells emit = loop Nothing
  where
    deadline = addUTCTime (fromIntegral spec.workerMaxRuntimeSeconds) spec.workerCreatedAt
    loop lastDiagnostic = do
      current <- readIORef cells.supervisorPendingOutcome
      case current of
        Nothing -> pure False
        Just (requireVerification, outcome) -> do
          refreshProcessCensus descriptor cells.supervisorState
          known <- withMVar cells.supervisorState (\state -> pure (state.workerStateKnownProcesses))
          result <-
            if requireVerification && null known
              then fmap (const []) <$> takeSnapshot
              else liveProcessesWith takeSnapshot known
          case result of
            Left message -> do
              reported <-
                if lastDiagnostic == Just message
                  then pure lastDiagnostic
                  else do
                    signalTriggered <- readIORef cells.supervisorSignalShutdown
                    let operation = if signalTriggered then "signal shutdown" else "orphan poll" :: Text
                    emit (WorkerDiagnostic (operation <> ": could not verify recorded descendants are gone (" <> message <> "); retaining orphan state and lease"))
                    pure (Just message)
              threadDelay workerOrphanCheckIntervalMicros
              loop reported
            Right surviving
              | null surviving -> do
                  wonLease <- claimLeaseRelease cells
                  unless wonLease (readMVar cells.supervisorWatchdogAdjudicated)
                  final <- atomicModifyIORef' cells.supervisorPendingOutcome (\value -> (Nothing, value))
                  let priorOutcome = maybe outcome snd final
                  pastDeadline <- if wonLease then (>= deadline) <$> getCurrentTime else pure False
                  emit (WorkerFinished (if pastDeadline then workerDeadlineOutcome else priorOutcome))
                  pure wonLease
              | otherwise -> threadDelay workerOrphanCheckIntervalMicros >> loop Nothing

-- | Bounds the worker's whole lifetime (task execution, not just its
-- provider) from 'workerCreatedAt', not from whenever this thread happened
-- to start: the delay is the remainder of that window, clamped to zero so
-- an already-overdue spec fires immediately instead of waiting a full
-- 'workerMaxRuntimeSeconds' from scratch. On firing, this claims the exact
-- same 'claimCompletion' slot a genuine task completion ('complete')
-- contends for — not a separate guard claimed just beforehand — so the two
-- can never each "win" their own half of the decision: whichever caller's
-- claim actually lands first is the sole, unambiguous owner of the
-- outcome. 'supervisorStopped' and 'supervisorForcedOutcome' are set
-- unconditionally as soon as the delay elapses, regardless of who wins:
-- 'supervisorStopped' gates
-- 'rememberProvider' (so a registration racing this firing is killed
-- rather than left running) and stops the heartbeat/census loops;
-- 'supervisorForcedOutcome' tells the supervisor the deadline fired at
-- all — not
-- that it specifically owns the outcome — so it knows to wait on
-- 'supervisorWatchdogDone' below rather than racing ahead on a stale read.
--
-- Killing is never conditional on winning the completion claim: even a
-- losing deadline still identity-verifies and kills the current provider
-- and every recorded census group. A normal completion already owning the
-- outcome only means its *provider* has already exited on its own — any
-- descendants it left behind (recorded but still live when it reported
-- 'WorkerOrphansDetected') are not, and nothing else ever actively kills
-- them; leaving that census untouched here would let a live descendant
-- hold the lease indefinitely past the deadline. When this loses the
-- claim to an outcome that is still pending (an orphan wait, not a fully
-- resolved 'WorkerFinished'), it takes over that pending outcome with its
-- own reason and re-publishes the orphan state, so eventual resolution
-- reports the deadline rather than the stale original reason.
--
-- Ordering differs by outcome. On a win, verifying and killing the
-- provider and census runs before 'completeBody', which runs before the
-- task thread is cancelled: 'completeBody' reports what the census holds
-- at the moment it runs, so verifying and killing first means it reports
-- on processes this function actually attempted to terminate rather than
-- a premature census that has not yet observed a provider still
-- mid-registration; cancelling the task only afterward means a 'killThread'
-- that targets a task still inside a claimed completion's
-- 'uninterruptibleMask_' simply blocks here until that completion
-- finishes, rather than the supervisor's blocking 'takeMVar' on the task
-- result racing ahead of this function's own still-in-flight completion
-- (which 'supervisorWatchdogDone' below also independently guards against). On a
-- loss, the task thread is cancelled *before* checking the pending
-- outcome: an already-claimed normal completion may itself still be
-- running (e.g. verifying its own census); cancelling first blocks here
-- until it genuinely finishes (same masked-thread semantics as above),
-- guaranteeing a stable, already-settled 'supervisorPendingOutcome' to read and
-- take over — reading it any earlier could race that completion's own
-- write and either miss the takeover or have this function's own write
-- clobbered afterward. The takeover write itself then runs *before* the
-- kill that follows it, reversing the win case's order: 'completeBody'
-- only ever runs on the winning side, so there the write (via
-- 'completeBody') and the killing are the same atomic step; here, on a
-- loss, 'waitForOrphanResolution' is already polling the same census
-- independently and concurrently (it started as soon as the normal
-- completion first reported the orphan, well before this deadline ever
-- fired), so it can observe the kill's effect — the recorded group
-- actually dying — the instant that happens. Killing before writing would
-- let that independent poll notice "gone" and finalize on the stale
-- original outcome before this function ever gets to its own takeover;
-- writing first guarantees the poll's next observation, whenever it
-- lands, already reads the deadline reason.
--
-- 'supervisorWatchdogDone' is filled unconditionally once this returns, win or
-- lose (including winning nothing at all — see 'claimLeaseRelease' below),
-- so the supervisor never mistakes a merely-fired deadline for a fully
-- settled one.
--
-- Before doing anything else — before even 'supervisorStopped' — this races the
-- supervisor for 'claimLeaseRelease', immediately after the delay elapses.
-- The supervisor claims the same thing immediately before releasing the
-- lease, as late as it possibly can (see 'runWorkerWithTask'), rather than
-- inferring from any earlier snapshot whether the deadline will still fire
-- later. Losing this claim means the supervisor has already decided the
-- worker is fully done and is releasing the lease right now (or already
-- has): there is nothing left here to kill or commit, another worker may
-- already be acquiring that lease, and this does nothing further at all.
watchdogLoop :: IO (Either Text [ProcessIdentity]) -> WorkerSpec -> SupervisorCells -> (Bool -> SolveOutcome -> IO ()) -> (WorkerEvent -> IO ()) -> IO ()
watchdogLoop takeSnapshot spec cells completeBody emitRaw = do
  now <- getCurrentTime
  let deadline = addUTCTime (fromIntegral spec.workerMaxRuntimeSeconds) spec.workerCreatedAt
      delayMicros = max 0 (round (diffUTCTime deadline now * 1000000))
  threadDelay delayMicros
  wonLeaseRelease <- claimLeaseRelease cells
  if wonLeaseRelease
    then do
      writeIORef cells.supervisorStopped True
      writeIORef cells.supervisorForcedOutcome (Just workerDeadlineOutcome)
      wonCompletion <- claimCompletion cells
      if wonCompletion
        then do
          providerOk <- terminateProviderRefWith takeSnapshot cells.supervisorState cells.supervisorProviderSlot
          recordedOk <- withMVar cells.supervisorState (terminateRecordedStateProcessesWith takeSnapshot)
          completeBody (providerOk && recordedOk) workerDeadlineOutcome
          -- 'supervisorWatchdogAdjudicated' fills only once
          -- 'supervisorPendingOutcome'
          -- has actually reached its final value for this claim (via
          -- 'completeBody' here, or the takeover compare-and-swap below)
          -- — not merely once win/lose is decided — so
          -- 'waitForOrphanResolution', on the branch where it loses
          -- 'claimLeaseRelease' to this thread, can block on it and be
          -- guaranteed to see a settled value rather than one still in
          -- flight. This branch can never actually be the one that poll
          -- is waiting on (it starts only once 'supervisorCompletionClaim'
          -- is already
          -- claimed by the normal completion it is polling for, so this
          -- call can never itself still win 'claimCompletion' while
          -- racing it), but filling this here too keeps the guarantee
          -- unconditional rather than dependent on that invariant.
          putMVar cells.supervisorWatchdogAdjudicated ()
          readIORef cells.supervisorTaskThreadId >>= mapM_ killThread
        else do
          readIORef cells.supervisorTaskThreadId >>= mapM_ killThread
          -- This branch is reached only when this thread has itself just
          -- won 'claimLeaseRelease' — a one-shot claim — which means
          -- 'waitForOrphanResolution' (see its own documentation) cannot
          -- have won it instead, and so cannot yet have consumed
          -- 'supervisorPendingOutcome': it is guaranteed to still be blocked on
          -- 'supervisorWatchdogAdjudicated', not racing this compare-and-swap.
          -- The 'Nothing' case below is kept only as a defensive no-op,
          -- not because it can actually happen.
          tookOver <-
            atomicModifyIORef' cells.supervisorPendingOutcome $ \pending -> case pending of
              Nothing -> (Nothing, False)
              Just _ -> (Just (False, workerDeadlineOutcome), True)
          -- Filled here, right after the takeover claim is decided (win or
          -- no-op alike): this is the earliest point 'supervisorPendingOutcome'
          -- is guaranteed settled for this branch, and — since 'killThread'
          -- above already blocked until any in-flight normal completion
          -- this deadline is racing had itself finished settling that same
          -- ref — the poll blocked on this var can never observe anything
          -- still in flight.
          putMVar cells.supervisorWatchdogAdjudicated ()
          when tookOver $ do
            known <- withMVar cells.supervisorState (pure . (.workerStateKnownProcesses))
            emitRaw (WorkerOrphansDetected workerDeadlineOutcome known)
          void (terminateProviderRefWith takeSnapshot cells.supervisorState cells.supervisorProviderSlot)
          void (withMVar cells.supervisorState (terminateRecordedStateProcessesWith takeSnapshot))
    else pure ()
  putMVar cells.supervisorWatchdogDone ()

-- | The canonical externally visible reason a persistent worker's
-- 'workerMaxRuntimeSeconds' bound fired, used consistently in worker state,
-- journal events, and the UI's session/card and process-inspector
-- projections so a deadline is never mistaken for a generic provider
-- failure.
workerDeadlineReason :: Text
workerDeadlineReason = "persistent worker deadline exceeded"

workerDeadlineOutcome :: SolveOutcome
workerDeadlineOutcome = SolveFailed workerDeadlineReason

terminalActivity :: SolveOutcome -> Text
terminalActivity SolveCompleted = "completed"
terminalActivity (SolveNeedsInput _) = "waiting for input"
terminalActivity (SolveFailed _) = "failed"

showProcessCount :: [value] -> Text
showProcessCount values = Text.pack (show (length values))

defaultWorkerMaxRuntimeSeconds :: Int
defaultWorkerMaxRuntimeSeconds = 4 * 60 * 60

workerHeartbeatIntervalMicros :: Int
workerHeartbeatIntervalMicros = 5 * 1000 * 1000

workerCensusIntervalMicros :: Int
workerCensusIntervalMicros = 250 * 1000

workerOrphanCheckIntervalMicros :: Int
workerOrphanCheckIntervalMicros = 500 * 1000

workerStartupAttempts :: Int
workerStartupAttempts = 60

workerStartupIntervalMicros :: Int
workerStartupIntervalMicros = 50 * 1000
