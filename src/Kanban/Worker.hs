{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

module Kanban.Worker
  ( WorkerDescriptor (..),
    WorkerEvent (..),
    WorkerId (..),
    WorkerParent (..),
    ProcessIdentity (..),
    WorkerTask (..),
    SolveWorkerTask (..),
    PullRequestWorkerTask (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    acquireWorkerLease,
    acknowledgeWorker,
    acknowledgeSupersededWorkers,
    discoverWorkers,
    discoverWorkerHistory,
    launchPullRequestWorker,
    launchSolveWorker,
    monitorWorker,
    pendingTerminationDiagnosticPrefix,
    readWorkerState,
    recordLaunchedSupervisorIdentity,
    recoverIfWorkerStoppedWith,
    releaseWorkerLease,
    runWorker,
    runWorkerWith,
    runWorkerWithTask,
    terminateWorker,
    terminateWorkerWith,
    workerDeadlineReason,
    waitForWorkerStart,
  )
where

import Control.Concurrent (ThreadId, forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, takeMVar, withMVar)
import Control.Exception (IOException, SomeException, mask, try, uninterruptibleMask_)
import Control.Monad (filterM, unless, void, when)
import Data.Aeson (FromJSON (..), ToJSON, eitherDecodeStrict', encode, withObject, (.:), (.:?), (.!=))
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Either (isRight)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import GHC.Generics (Generic)
import Kanban.Domain (Repository (..))
import Kanban.Process
  ( IdentityPresence (..),
    ManagedProcess,
    ProcessIdentity (..),
    checkGroupMembershipWith,
    checkIdentityPresenceWith,
    defaultProcessSnapshot,
    descendantProcesses,
    identityForPid,
    killManagedProcess,
    killVerifiedGroupWith,
    liveProcessesWith,
    managedProcess,
    managedProcessPid,
    matchingIdentities,
    readProcessSnapshot,
  )
import Kanban.PullRequestFlow (PullRequestAction, PullRequestFlowEvent (..), PullRequestOrigin, runPullRequestFlow)
import Kanban.Solve (AgentEvent (..), ResumeProvenance (..), SolveEvent (..), SolveOutcome (..), SolveWorkflow, SolverBrand, runSolve)
import System.Directory
  ( XdgDirectory (XdgCache),
    createDirectory,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getModificationTime,
    getXdgDirectory,
    listDirectory,
    removeDirectory,
    removeFile,
    renameDirectory,
    renameFile,
  )
import System.FilePath (takeDirectory, (</>))
import System.Environment (getExecutablePath)
import System.IO (BufferMode (LineBuffering), IOMode (AppendMode), hClose, hSetBuffering, openBinaryFile)
import System.Posix.Files (setFileMode)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (Handler (Catch), installHandler, sigINT, sigKILL, sigTERM, signalProcessGroup)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (NoStream), createProcess, getPid, getProcessExitCode, proc)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)

newtype WorkerId = WorkerId {unWorkerId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data SolveWorkerTask = SolveWorkerTask
  { solveWorkerIssueNumber :: Int,
    solveWorkerWorkflow :: SolveWorkflow,
    solveWorkerBrand :: SolverBrand
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data PullRequestWorkerTask = PullRequestWorkerTask
  { pullRequestWorkerNumber :: Int,
    pullRequestWorkerOrigin :: PullRequestOrigin,
    pullRequestWorkerAction :: PullRequestAction
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WorkerTask = SolveWorkerTaskKind SolveWorkerTask | PullRequestWorkerTaskKind PullRequestWorkerTask
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WorkerParent = WorkerParent
  { workerParentIssueNumber :: Int,
    workerParentReviewRound :: Int,
    workerParentSolverBrand :: SolverBrand,
    workerParentSolverSession :: Maybe Text,
    workerParentSolverLogPath :: Maybe FilePath,
    workerParentStartedAt :: UTCTime,
    workerParentKnownPullRequests :: Set Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WorkerSpec = WorkerSpec
  { workerId :: WorkerId,
    workerRepository :: Repository,
    workerTask :: WorkerTask,
    workerExistingSession :: Maybe Text,
    workerExistingLogPath :: Maybe FilePath,
    workerResumeProvenance :: ResumeProvenance,
    workerUserMessage :: Text,
    workerParent :: Maybe WorkerParent,
    workerCreatedAt :: UTCTime,
    workerMaxRuntimeSeconds :: Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Manual instance so a durable spec file written before
-- 'workerResumeProvenance' existed still decodes: legacy specs default to
-- 'ResumeAnswer', matching every resume's framing prior to its introduction.
instance FromJSON WorkerSpec where
  parseJSON = withObject "WorkerSpec" $ \object ->
    WorkerSpec
      <$> object .: "workerId"
      <*> object .: "workerRepository"
      <*> object .: "workerTask"
      <*> object .: "workerExistingSession"
      <*> object .: "workerExistingLogPath"
      <*> object .:? "workerResumeProvenance" .!= ResumeAnswer
      <*> object .: "workerUserMessage"
      <*> object .: "workerParent"
      <*> object .: "workerCreatedAt"
      <*> object .: "workerMaxRuntimeSeconds"

data WorkerEvent
  = WorkerProviderStarted Int
  | WorkerLogOpened FilePath
  | WorkerSessionIdentified Text
  | WorkerAgentOutput AgentEvent
  | WorkerDiagnostic Text
  | WorkerOrphansDetected SolveOutcome [ProcessIdentity]
  | WorkerFinished SolveOutcome
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WorkerStatus = WorkerStarting | WorkerRunning | WorkerOrphaned SolveOutcome | WorkerTerminal SolveOutcome
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WorkerState = WorkerState
  { workerStateId :: WorkerId,
    workerStateStatus :: WorkerStatus,
    workerStateWorkerPid :: Int,
    workerStateWorkerIdentity :: Maybe ProcessIdentity,
    workerStateProviderPid :: Maybe Int,
    workerStateProviderIdentity :: Maybe ProcessIdentity,
    workerStateSessionId :: Maybe Text,
    workerStateLogPath :: Maybe FilePath,
    workerStateHeartbeatAt :: UTCTime,
    workerStateLastActivity :: Text,
    workerStateKnownProcesses :: [ProcessIdentity]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON WorkerState where
  parseJSON = withObject "WorkerState" $ \object ->
    WorkerState
      <$> object .: "workerStateId"
      <*> object .: "workerStateStatus"
      <*> object .: "workerStateWorkerPid"
      <*> object .:? "workerStateWorkerIdentity" .!= Nothing
      <*> object .: "workerStateProviderPid"
      <*> object .:? "workerStateProviderIdentity" .!= Nothing
      <*> object .: "workerStateSessionId"
      <*> object .: "workerStateLogPath"
      <*> object .: "workerStateHeartbeatAt"
      <*> object .: "workerStateLastActivity"
      <*> object .:? "workerStateKnownProcesses" .!= []

data WorkerLease = WorkerLease
  { workerLeaseId :: WorkerId,
    workerLeaseCreatedAt :: UTCTime,
    -- | The freshly spawned supervisor's identity, recorded as soon as it is
    -- known (see 'recordLaunchedSupervisorIdentity'). Durable so a recovery
    -- pass reached before any worker state file exists — the only other
    -- place a supervisor's identity would otherwise be recorded — can still
    -- tell a live pre-state supervisor from a dead one instead of guessing
    -- from elapsed time alone.
    workerLeaseSupervisorIdentity :: Maybe ProcessIdentity
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON WorkerLease where
  parseJSON = withObject "WorkerLease" $ \object ->
    WorkerLease
      <$> object .: "workerLeaseId"
      <*> object .: "workerLeaseCreatedAt"
      <*> object .:? "workerLeaseSupervisorIdentity" .!= Nothing

data WorkerEnvelope = WorkerEnvelope
  { workerEnvelopeTimestamp :: UTCTime,
    workerEnvelopeEvent :: WorkerEvent
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WorkerDescriptor = WorkerDescriptor
  { workerDescriptorSpec :: WorkerSpec,
    workerDescriptorSpecPath :: FilePath,
    workerDescriptorEventPath :: FilePath,
    workerDescriptorStatePath :: FilePath,
    workerDescriptorAckPath :: FilePath,
    workerDescriptorLeasePath :: FilePath,
    workerDescriptorLeaseOwnerPath :: FilePath,
    -- | Marks a user-requested termination a snapshot failure left
    -- unverified. Owned solely by 'terminateWorkerWith' and
    -- 'recoverIfWorkerStoppedWith' (both outside the live supervisor
    -- process), so unlike the state file it is never clobbered by the
    -- supervisor's own heartbeat or census writes.
    workerDescriptorPendingTerminationPath :: FilePath
  }
  deriving stock (Eq, Show)

launchSolveWorker :: Repository -> Int -> SolveWorkflow -> SolverBrand -> Maybe Text -> Maybe FilePath -> ResumeProvenance -> Text -> Maybe WorkerParent -> IO (Either Text WorkerDescriptor)
launchSolveWorker repository issueNumber workflow brand existingSession existingLogPath provenance userMessage parent = do
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
        workerMaxRuntimeSeconds = defaultWorkerMaxRuntimeSeconds
      }

launchPullRequestWorker :: Repository -> Int -> PullRequestOrigin -> PullRequestAction -> Maybe Text -> Maybe FilePath -> ResumeProvenance -> Text -> Maybe WorkerParent -> IO (Either Text WorkerDescriptor)
launchPullRequestWorker repository number origin action existingSession existingLogPath provenance userMessage parent = do
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
        workerMaxRuntimeSeconds = defaultWorkerMaxRuntimeSeconds
      }

launchWorker :: WorkerSpec -> IO (Either Text WorkerDescriptor)
launchWorker spec = do
  descriptor <- descriptorForSpec spec
  directory <- workerDirectory spec.workerRepository
  createDirectoryIfMissing True directory
  setFileMode directory 0o700
  leased <- acquireWorkerLease descriptor
  case leased of
    Left message -> pure (Left message)
    Right () -> do
      written <- writePrivateJson descriptor.workerDescriptorSpecPath spec
      case written of
        Left message -> releaseWorkerLease descriptor >> pure (Left message)
        Right () -> do
          executable <- getExecutablePath
          started <- try @IOException $ createProcess
            (proc executable ["--worker-spec", descriptor.workerDescriptorSpecPath])
              { std_in = NoStream,
                std_out = NoStream,
                std_err = NoStream,
                close_fds = True,
                new_session = True
              }
          case started of
            Left exception -> do
              acknowledgeWorker descriptor
              releaseWorkerLease descriptor
              pure (Left ("could not start persistent worker: " <> Text.pack (show exception)))
            Right (_, _, _, processHandle) -> do
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
                  -- 'runWorkerWith'), not a long-running task already under
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
              pure result

acquireWorkerLease :: WorkerDescriptor -> IO (Either Text ())
acquireWorkerLease descriptor = attempt workerLeaseAttempts
  where
    attempt attempts = do
      created <- try @IOException (createDirectory descriptor.workerDescriptorLeasePath)
      case created of
        Right () -> do
          setFileMode descriptor.workerDescriptorLeasePath 0o700
          written <-
            writePrivateJson
              descriptor.workerDescriptorLeaseOwnerPath
              WorkerLease
                { workerLeaseId = descriptor.workerDescriptorSpec.workerId,
                  workerLeaseCreatedAt = descriptor.workerDescriptorSpec.workerCreatedAt,
                  workerLeaseSupervisorIdentity = Nothing
                }
          case written of
            Right () -> pure (Right ())
            Left message -> do
              ignoreFileOperation (removeDirectory descriptor.workerDescriptorLeasePath)
              pure (Left ("could not initialize worker lease: " <> message))
        Left exception
          | not (isAlreadyExistsError exception) -> pure (Left ("could not acquire worker lease: " <> Text.pack (show exception)))
          | attempts <= 0 -> pure (Left "could not acquire worker lease after concurrent recovery")
          | otherwise -> do
              active <- leaseIsActive descriptor
              if active
                then pure (Left (workerLeaseConflictMessage descriptor.workerDescriptorSpec.workerTask))
                else do
                  retired <- retireStaleLease descriptor
                  case retired of
                    Left message -> pure (Left message)
                    Right () -> attempt (attempts - 1)

leaseIsActive :: WorkerDescriptor -> IO Bool
leaseIsActive descriptor = do
  leaseResult <- decodeFile descriptor.workerDescriptorLeaseOwnerPath :: IO (Either Text WorkerLease)
  case leaseResult of
    Left _ -> leaseIsRecent descriptor
    Right lease -> do
      let ownerBase = takeDirectory descriptor.workerDescriptorLeasePath </> Text.unpack lease.workerLeaseId.unWorkerId
          statePath = ownerBase <> ".state.json"
          pendingTerminationPath = ownerBase <> ".pending-termination"
      stateResult <- decodeFile statePath :: IO (Either Text WorkerState)
      case stateResult of
        Right state -> case state.workerStateStatus of
          -- Every path that writes WorkerTerminal has already verified zero
          -- surviving identities before doing so, so this is normally
          -- redundant; it is still re-checked (rather than trusted
          -- unconditionally) so a live identity match at this exact moment —
          -- e.g. a PID somehow reused with the same recorded start time in
          -- the narrow window right after that verified write — still blocks
          -- a relaunch instead of racing it. Every recorded identity is
          -- consulted, not only the supervisor's, since a terminal write
          -- clears the supervisor's own fields on some paths while a
          -- provider or other descendant identity can still be present in
          -- 'workerStateKnownProcesses'; only when nothing at all is
          -- recorded is there nothing left to re-verify.
          WorkerTerminal _ -> do
            let identities = catMaybes [state.workerStateWorkerIdentity, state.workerStateProviderIdentity] <> state.workerStateKnownProcesses
            if null identities
              then pure False
              else do
                presence <- checkIdentityPresenceWith defaultProcessSnapshot identities
                pure (presence /= IdentityAbsent)
          -- Every other status — including Orphaned — is judged by whether
          -- any durably recorded identity for this worker still matches a
          -- process, not by the status label alone: a blanket "Orphaned is
          -- always active" would block a same-issue relaunch forever once a
          -- confirmed-gone orphan's supervisor also died without writing a
          -- terminal state, and checking only the supervisor's identity for
          -- every other status would let a relaunch start alongside a live
          -- provider or other recorded descendant whose supervisor happened
          -- to already be gone.
          _ -> recordedIdentitiesActive state pendingTerminationPath
        Left _ -> do
          -- No state file has been written yet: fall back to the
          -- supervisor's identity recorded directly on the lease at launch.
          -- Unlike every other fallback in this function, there is no
          -- elapsed-time escape hatch here: elapsed time cannot distinguish
          -- a still-slow-but-alive supervisor from a dead one, and the
          -- one-live-worker invariant must hold even in the rare case where
          -- identity capture itself never succeeds — a lease that can never
          -- be proven dead stays active rather than risk a concurrent
          -- worker.
          presence <- supervisorLaunchIdentityPresenceWith defaultProcessSnapshot descriptor
          pure (presence /= Just IdentityAbsent)

-- | A lease stays active while any durably recorded identity for its
-- worker — the supervisor itself, its provider, or any other recorded
-- descendant — still matches a fresh process snapshot: the one-live-worker
-- invariant covers the whole recorded process tree, not merely the
-- supervisor, so a descendant surviving a dead supervisor (mid-orphan-wait,
-- or a supervisor that died without a terminal write) must still block a
-- same-issue relaunch.
recordedIdentitiesActive :: WorkerState -> FilePath -> IO Bool
recordedIdentitiesActive state pendingTerminationPath = case state.workerStateWorkerIdentity of
  -- An unverified identity (a pre-identity state file) must never authorize
  -- retiring a lease that might still be live: fail closed as active rather
  -- than risk a concurrent worker.
  Nothing -> pure True
  Just workerIdentity -> do
    let identities = workerIdentity : maybe [] (: []) state.workerStateProviderIdentity <> state.workerStateKnownProcesses
    presence <- checkIdentityPresenceWith defaultProcessSnapshot identities
    case presence of
      IdentityPresent -> pure True
      IdentitySnapshotFailed _ -> pure True
      IdentityAbsent -> do
        -- Every recorded identity is confirmed gone, but if the supervisor
        -- never got to signal a pending user termination (recorded only in
        -- this marker file, not the state it stopped updating), that
        -- termination's recorded descendants are still unverified: never
        -- retire the lease out from under them.
        doesFileExist pendingTerminationPath

leaseIsRecent :: WorkerDescriptor -> IO Bool
leaseIsRecent descriptor = do
  modified <- try @IOException (getModificationTime descriptor.workerDescriptorLeasePath)
  case modified of
    Left _ -> pure False
    Right modificationTime -> do
      now <- getCurrentTime
      pure (diffUTCTime now modificationTime < workerLeaseInitializationGraceSeconds)

retireStaleLease :: WorkerDescriptor -> IO (Either Text ())
retireStaleLease descriptor = do
  let retiredPath = descriptor.workerDescriptorLeasePath <> ".stale-" <> Text.unpack descriptor.workerDescriptorSpec.workerId.unWorkerId
  renamed <- try @IOException (renameDirectory descriptor.workerDescriptorLeasePath retiredPath)
  pure $ case renamed of
    Right () -> Right ()
    Left exception
      | isDoesNotExistError exception -> Right ()
      | otherwise -> Left ("could not retire stale worker lease: " <> Text.pack (show exception))

releaseWorkerLease :: WorkerDescriptor -> IO ()
releaseWorkerLease descriptor = do
  ownerResult <- decodeFile descriptor.workerDescriptorLeaseOwnerPath :: IO (Either Text WorkerLease)
  case ownerResult of
    Right owner
      | owner.workerLeaseId == descriptor.workerDescriptorSpec.workerId -> do
          ignoreFileOperation (removeFile descriptor.workerDescriptorLeaseOwnerPath)
          ignoreFileOperation (removeDirectory descriptor.workerDescriptorLeasePath)
    _ -> pure ()

ignoreFileOperation :: IO () -> IO ()
ignoreFileOperation operation = void (try @IOException operation)

workerLeaseConflictMessage :: WorkerTask -> Text
workerLeaseConflictMessage task = case task of
  SolveWorkerTaskKind solveTask -> "issue #" <> Text.pack (show solveTask.solveWorkerIssueNumber) <> " already has a live solve worker; open it from Processes or kill it before starting another"
  PullRequestWorkerTaskKind pullRequestTask -> "PR #" <> Text.pack (show pullRequestTask.pullRequestWorkerNumber) <> " already has a live worker; open it from Processes or kill it before starting another"

runWorker :: FilePath -> IO (Either Text ())
runWorker = runWorkerWith readProcessSnapshot

runWorkerWith :: IO (Either Text [ProcessIdentity]) -> FilePath -> IO (Either Text ())
runWorkerWith takeSnapshot = runWorkerWithTask takeSnapshot defaultRunTask

-- | Dispatches a worker's task to its real solve/PR-flow implementation.
-- Factored out of 'runWorkerWithTask' so tests can substitute a fake task
-- (e.g. one that stalls before ever registering a provider) while exercising
-- the real supervisor lifecycle, the same way 'takeSnapshot' is already
-- substituted for process verification.
defaultRunTask :: WorkerSpec -> (ManagedProcess -> IO ()) -> (WorkerEvent -> IO ()) -> IO ()
defaultRunTask spec rememberProvider emit = case spec.workerTask of
  SolveWorkerTaskKind task ->
    runSolve spec.workerRepository task.solveWorkerIssueNumber task.solveWorkerWorkflow task.solveWorkerBrand spec.workerExistingSession spec.workerExistingLogPath spec.workerResumeProvenance spec.workerUserMessage
      (translateSolveEvent rememberProvider emit)
  PullRequestWorkerTaskKind task ->
    runPullRequestFlow spec.workerRepository task.pullRequestWorkerNumber task.pullRequestWorkerOrigin task.pullRequestWorkerAction spec.workerExistingSession spec.workerExistingLogPath spec.workerResumeProvenance spec.workerUserMessage
      (translatePullRequestEvent rememberProvider emit)

runWorkerWithTask :: IO (Either Text [ProcessIdentity]) -> (WorkerSpec -> (ManagedProcess -> IO ()) -> (WorkerEvent -> IO ()) -> IO ()) -> FilePath -> IO (Either Text ())
runWorkerWithTask takeSnapshot buildRunTask specPath = do
  decoded <- decodeFile specPath
  case decoded of
    Left message -> pure (Left message)
    Right spec -> do
      descriptor <- descriptorForSpec spec
      directory <- workerDirectory spec.workerRepository
      createDirectoryIfMissing True directory
      setFileMode directory 0o700
      pid <- fromIntegral <$> getProcessID
      now <- getCurrentTime
      selfSnapshot <- readProcessSnapshot
      let selfIdentity = either (const Nothing) (identityForPid pid) selfSnapshot
      stateLock <- newMVar
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
      eventLock <- newMVar ()
      providerRef <- newIORef Nothing
      stoppedRef <- newIORef False
      signalShutdownRef <- newIORef False
      pendingOutcomeRef <- newIORef Nothing
      completedRef <- newIORef False
      forcedOutcomeRef <- newIORef Nothing
      taskThreadIdRef <- newIORef Nothing
      taskResultVar <- newEmptyMVar
      watchdogDoneVar <- newEmptyMVar
      leaseReleaseClaimRef <- newIORef False
      let claimLeaseRelease = atomicModifyIORef' leaseReleaseClaimRef (\claimed -> (True, not claimed))
      let stopOwnedWork = do
            writeIORef stoppedRef True
            writeIORef signalShutdownRef True
            readIORef providerRef >>= mapM_ killManagedProcess
            terminateRecordedProcesses stateLock
      previousTermHandler <- installHandler sigTERM (Catch stopOwnedWork) Nothing
      previousInterruptHandler <- installHandler sigINT (Catch stopOwnedWork) Nothing
      persistState descriptor stateLock
      void . forkIO $ heartbeatLoop descriptor stateLock stoppedRef
      void . forkIO $ processCensusLoop descriptor stateLock stoppedRef
      let emitRaw event = do
            appendWorkerEvent descriptor eventLock event
            updateWorkerState descriptor stateLock event
            case event of
              WorkerFinished _ -> writeIORef stoppedRef True
              _ -> pure ()
          -- Only the first caller ever runs `completeBody`: the deadline
          -- watchdog and a genuine task-reported outcome can both reach it
          -- around the same instant, and once one of them has committed a
          -- terminal/orphan outcome, the other must not resurrect or
          -- replace it. The watchdog claims this atomically for itself
          -- before it even cancels the task (see 'watchdogLoop'), so a
          -- deadline reliably wins that race instead of merely attempting
          -- to afterward. Whichever side wins runs the body under
          -- 'uninterruptibleMask_': claiming the slot only to have a
          -- concurrent 'killThread' interrupt it partway would leave no
          -- terminal or pending outcome committed at all, stranding the
          -- worker with a claimed-but-unfulfilled completion. A watchdog
          -- that loses this claim (a task's own completion was already in
          -- flight) still calls 'killThread' afterward, but since that
          -- target is itself masked here, the call simply blocks until the
          -- in-flight completion finishes rather than corrupting it —
          -- letting an already-claimed completion run to conclusion instead
          -- of being cancelled out from under itself.
          claimCompletion = atomicModifyIORef' completedRef (\done -> (True, not done))
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
          completeBody verified outcome = uninterruptibleMask_ $ do
            refreshProcessCensus descriptor stateLock
            result <- liveRecordedProcessesWith takeSnapshot stateLock
            case result of
              Left message -> do
                known <- withMVar stateLock (pure . (.workerStateKnownProcesses))
                signalTriggered <- readIORef signalShutdownRef
                let operation = if signalTriggered then "signal shutdown" else "completion" :: Text
                writeIORef pendingOutcomeRef (Just (not verified, outcome))
                emitRaw (WorkerDiagnostic (operation <> ": could not verify recorded descendants are gone (" <> message <> "); retaining orphan state and lease"))
                emitRaw (WorkerOrphansDetected outcome known)
              Right survivors
                | null survivors, verified -> emitRaw (WorkerFinished outcome)
                | null survivors -> do
                    writeIORef pendingOutcomeRef (Just (True, outcome))
                    emitRaw (WorkerDiagnostic "deadline: could not verify the current provider was terminated; retaining orphan state and lease")
                    emitRaw (WorkerOrphansDetected outcome survivors)
                | otherwise -> do
                    writeIORef pendingOutcomeRef (Just (not verified, outcome))
                    emitRaw (WorkerOrphansDetected outcome survivors)
          -- Claiming and running the completion body happen under the same
          -- mask: without it, an async exception (the watchdog's own
          -- 'killThread', losing the race to claim completion itself) could
          -- land in the gap between 'claimCompletion' succeeding and
          -- 'completeBody' establishing its own 'uninterruptibleMask_',
          -- leaving 'completedRef' claimed but no outcome ever committed —
          -- stranding the supervisor on 'takeMVar taskResultVar' forever. A
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
          -- unconditionally, leaving 'completedRef' unclaimed for the
          -- watchdog — whose own delay has, by the same wall clock, also
          -- already elapsed — to win outright whenever it does get
          -- scheduled.
          complete outcome = uninterruptibleMask_ $ do
            completeNow <- getCurrentTime
            let completeDeadline = addUTCTime (fromIntegral spec.workerMaxRuntimeSeconds) spec.workerCreatedAt
            unless (completeNow >= completeDeadline) (claimCompletion >>= \won -> when won (completeBody True outcome))
          emit event = case event of
            WorkerFinished outcome -> complete outcome
            _ -> emitRaw event
          rememberProvider process = do
            writeIORef providerRef (Just process)
            stopRequested <- readIORef stoppedRef
            if stopRequested
              then killManagedProcess process
              else do
                processId <- managedProcessPid process
                case processId of
                  Just providerPid -> do
                    recordProviderIdentity descriptor stateLock (fromIntegral providerPid)
                    emit (WorkerProviderStarted (fromIntegral providerPid))
                    refreshProcessCensus descriptor stateLock
                  Nothing -> do
                    let message = "provider started without an observable process-group id; terminating it for safety"
                    emit (WorkerDiagnostic message)
                    killManagedProcess process
          runTask = buildRunTask spec rememberProvider emit
      -- `runTask` runs under `restore` so a deadline's `killThread` can
      -- still cancel it — that's the whole point. But once it has returned
      -- or been caught by `try`, the handoff to `taskResultVar` runs fully
      -- masked (the outer `mask` defers a pending exception at the
      -- statement boundary right after `try` returns; the inner
      -- `uninterruptibleMask_` then covers `putMVar` itself, since `putMVar`
      -- remains an interruptible operation even under plain `mask`). Without
      -- this, an exception landing in that gap could leave a fully computed
      -- result never delivered, blocking the supervisor on
      -- `takeMVar taskResultVar` forever. `uninterruptibleMask_` is safe
      -- here specifically because `taskResultVar` is always empty at this
      -- point (this is its one and only producer), so `putMVar` cannot
      -- itself actually block.
      taskThreadId <- forkIO $ mask $ \restore -> do
        result <- try @SomeException (restore runTask)
        uninterruptibleMask_ (putMVar taskResultVar result)
      writeIORef taskThreadIdRef (Just taskThreadId)
      void . forkIO $ watchdogLoop takeSnapshot spec providerRef stoppedRef stateLock taskThreadIdRef pendingOutcomeRef forcedOutcomeRef claimCompletion completeBody emitRaw claimLeaseRelease watchdogDoneVar
      taskResult <- takeMVar taskResultVar
      forcedOutcome <- readIORef forcedOutcomeRef
      case forcedOutcome of
        -- 'forcedOutcomeRef' is only consulted here to skip the redundant
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
            stopped <- readIORef stoppedRef
            pending <- readIORef pendingOutcomeRef
            if stopped || pending /= Nothing
              then pure ()
              else complete (SolveFailed "persistent worker task ended without a terminal provider event")
          Left exception -> do
            refreshProcessCensus descriptor stateLock
            readIORef providerRef >>= mapM_ killManagedProcess
            let message = "persistent worker failed: " <> Text.pack (show exception)
            void . try @SomeException $ do
              emitRaw (WorkerDiagnostic message)
              complete (SolveFailed message)
      pending <- readIORef pendingOutcomeRef
      -- Verification always runs to a real conclusion here regardless of
      -- `stoppedRef`: a signal-triggered shutdown already set that flag
      -- true (to stop the heartbeat/census loops), and gating this wait on
      -- it too would let the lease below release on an unverified kill.
      -- 'waitForOrphanResolution' re-reads `pendingOutcomeRef` itself on
      -- every poll rather than trusting this one-time snapshot, since the
      -- deadline watchdog can still take over that same ref after this
      -- point (see 'watchdogLoop'); this read only decides whether to
      -- enter the wait at all.
      when (pending /= Nothing) (waitForOrphanResolution descriptor stateLock takeSnapshot signalShutdownRef emitRaw pendingOutcomeRef)
      writeIORef stoppedRef True
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
      -- 'watchdogDoneVar' blocks until that has genuinely finished.
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
      -- eventually runs) to win outright.
      releaseCheckNow <- getCurrentTime
      let deadline = addUTCTime (fromIntegral spec.workerMaxRuntimeSeconds) spec.workerCreatedAt
      wonLeaseRelease <- if releaseCheckNow >= deadline then pure False else claimLeaseRelease
      unless wonLeaseRelease (takeMVar watchdogDoneVar)
      releaseWorkerLease descriptor
      void (installHandler sigTERM previousTermHandler Nothing)
      void (installHandler sigINT previousInterruptHandler Nothing)
      pure (Right ())

translateSolveEvent :: (ManagedProcess -> IO ()) -> (WorkerEvent -> IO ()) -> SolveEvent -> IO ()
translateSolveEvent rememberProvider emit solveEvent = case solveEvent of
  SolveProcessStarted _ _ process -> rememberProvider process
  SolveLogOpened _ path -> emit (WorkerLogOpened path)
  SolveSessionIdentified _ sessionId -> emit (WorkerSessionIdentified sessionId)
  SolveOutput _ output -> emit (WorkerAgentOutput output)
  SolveDiagnostic _ message -> emit (WorkerDiagnostic message)
  SolveProcessFinished _ outcome -> emit (WorkerFinished outcome)

translatePullRequestEvent :: (ManagedProcess -> IO ()) -> (WorkerEvent -> IO ()) -> PullRequestFlowEvent -> IO ()
translatePullRequestEvent rememberProvider emit flowEvent = case flowEvent of
  PullRequestProcessStarted _ _ _ process -> rememberProvider process
  PullRequestLogOpened _ path -> emit (WorkerLogOpened path)
  PullRequestSessionIdentified _ sessionId -> emit (WorkerSessionIdentified sessionId)
  PullRequestFlowOutput _ output -> emit (WorkerAgentOutput output)
  PullRequestFlowDiagnostic _ message -> emit (WorkerDiagnostic message)
  PullRequestProcessFinished _ outcome -> emit (WorkerFinished outcome)

monitorWorker :: WorkerDescriptor -> (WorkerId -> WorkerSpec -> WorkerEvent -> IO ()) -> IO ()
monitorWorker descriptor eventSink = loop 0
  where
    spec = descriptor.workerDescriptorSpec
    loop consumed = do
      contentResult <- try @IOException (ByteString.readFile descriptor.workerDescriptorEventPath)
      let linesNow = case contentResult of
            Left _ -> []
            Right content -> filter (not . ByteString.null) (ByteString.split 10 content)
          unseen = drop consumed linesNow
      mapM_ emitLine unseen
      terminal <- anyM isTerminalEnvelope unseen
      unless terminal $ do
        recovered <- recoverIfWorkerStopped descriptor eventSink
        unless recovered $ threadDelay workerMonitorIntervalMicros >> loop (length linesNow)
    emitLine line = case (eitherDecodeStrict' line :: Either String WorkerEnvelope) of
      Left _ -> pure ()
      Right envelope -> eventSink spec.workerId spec envelope.workerEnvelopeEvent
    isTerminalEnvelope line = pure $ case (eitherDecodeStrict' line :: Either String WorkerEnvelope) of
      Right envelope -> case envelope.workerEnvelopeEvent of
        WorkerFinished _ -> True
        _ -> False
      Left _ -> False

-- A provider is deliberately subordinate to its persistent supervisor.  If
-- that supervisor disappears, fail closed instead of leaving an invisible
-- model process able to consume tokens indefinitely.
recoverIfWorkerStopped :: WorkerDescriptor -> (WorkerId -> WorkerSpec -> WorkerEvent -> IO ()) -> IO Bool
recoverIfWorkerStopped = recoverIfWorkerStoppedWith defaultProcessSnapshot

recoverIfWorkerStoppedWith :: IO (Either Text [ProcessIdentity]) -> WorkerDescriptor -> (WorkerId -> WorkerSpec -> WorkerEvent -> IO ()) -> IO Bool
recoverIfWorkerStoppedWith takeSnapshot descriptor eventSink = do
  stateResult <- readWorkerState descriptor
  case stateResult of
    Left _ -> do
      -- No state file exists yet to consult for the supervisor's identity;
      -- fall back to the identity recorded directly on the lease at launch
      -- (see 'recordLaunchedSupervisorIdentity'), which is available to
      -- this independent recovery pass exactly because the state file is
      -- not. Unlike the prior elapsed-time heuristic this replaces, there is
      -- no time-based escape hatch: elapsed time cannot distinguish a
      -- still-slow-but-alive supervisor from a dead one, so a launch whose
      -- identity was never recorded (a legacy lease, or best-effort capture
      -- that never succeeded) is left pending rather than finalized on a
      -- guess.
      identityPresence <- supervisorLaunchIdentityPresenceWith takeSnapshot descriptor
      case identityPresence of
        Just IdentityAbsent -> finalizeMissingState
        _ -> pure False
    Right state -> case state.workerStateStatus of
      -- Mirrors leaseIsActive's own re-check for WorkerTerminal: every path
      -- that writes it has already verified zero survivors, so this is
      -- normally immediate, but releasing here unconditionally would be the
      -- one place in this module that trusts the status label over a
      -- recorded identity. A live match (e.g. this pass racing the narrow
      -- window between the terminal write and the writer's own release)
      -- leaves the lease untouched and lets the monitor loop retry rather
      -- than free it out from under something still recorded as present.
      WorkerTerminal outcome -> do
        let identities = catMaybes [state.workerStateWorkerIdentity, state.workerStateProviderIdentity] <> state.workerStateKnownProcesses
        presence <- if null identities then pure IdentityAbsent else checkIdentityPresenceWith takeSnapshot identities
        case presence of
          IdentityAbsent -> do
            releaseWorkerLease descriptor
            eventSink spec.workerId spec (WorkerFinished outcome)
            pure True
          _ -> pure False
      _ -> do
        now <- getCurrentTime
        if diffUTCTime now state.workerStateHeartbeatAt < workerStaleHeartbeatSeconds
          then retryPendingTermination state
          else case state.workerStateWorkerIdentity of
            -- No recorded identity to verify against: fail closed as still
            -- active rather than guess the worker is gone from a bare PID.
            Nothing -> pure False
            Just workerIdentity -> do
              presence <- checkIdentityPresenceWith takeSnapshot [workerIdentity]
              case presence of
                IdentityPresent -> pure False
                IdentitySnapshotFailed _ -> reportStaleRecoveryPending state
                IdentityAbsent -> do
                  providerOk <- terminateProviderGroupWith takeSnapshot state
                  recordedOk <- terminateRecordedStateProcessesWith takeSnapshot state
                  if not (providerOk && recordedOk)
                    then reportStaleRecoveryPending state
                    else do
                      -- A pending user termination that outlived its supervisor
                      -- (the kill request was recorded but never reached a
                      -- supervisor that has since died on its own) still
                      -- finalizes as "killed by user" rather than the generic
                      -- unexpected-stop outcome.
                      pendingTermination <- doesFileExist descriptor.workerDescriptorPendingTerminationPath
                      let diagnostic
                            | pendingTermination = "stale-supervisor recovery: completing a pending user termination"
                            | otherwise = "persistent worker stopped unexpectedly; its provider process group was terminated"
                          outcome
                            | pendingTermination = SolveFailed "killed by user"
                            | otherwise = SolveFailed diagnostic
                          terminalState =
                            state
                              { workerStateStatus = WorkerTerminal outcome,
                                workerStateProviderPid = Nothing,
                                workerStateProviderIdentity = Nothing,
                                workerStateHeartbeatAt = now,
                                workerStateLastActivity = "worker failed closed"
                              }
                      writeState descriptor terminalState
                      ignoreFileOperation (removeFile descriptor.workerDescriptorPendingTerminationPath)
                      releaseWorkerLease descriptor
                      eventSink spec.workerId spec (WorkerDiagnostic diagnostic)
                      eventSink spec.workerId spec (WorkerFinished outcome)
                      pure True
  where
    spec = descriptor.workerDescriptorSpec
    -- Reached only once the supervisor is either confirmed absent by its
    -- durably recorded launch identity or, lacking that, has outlived the
    -- elapsed-time grace window: no state file ever appeared, so nothing
    -- was ever started to terminate beyond the lease itself.
    finalizeMissingState = do
      let message = "persistent worker never published its initial state"
      releaseWorkerLease descriptor
      eventSink spec.workerId spec (WorkerDiagnostic message)
      eventSink spec.workerId spec (WorkerFinished (SolveFailed message))
      pure True
    -- A pending user termination ('terminateWorkerWith' left it unverified)
    -- is retried here even while the supervisor's heartbeat is still fresh,
    -- since an unverified termination never signaled the supervisor and it
    -- has no reason to retry the kill itself.
    retryPendingTermination state = do
      pending <- doesFileExist descriptor.workerDescriptorPendingTerminationPath
      if not pending
        then pure False
        else do
          completed <- finalizeUserTermination takeSnapshot descriptor state
          if completed
            then do
              releaseWorkerLease descriptor
              eventSink spec.workerId spec (WorkerFinished (SolveFailed "killed by user"))
              pure True
            else pure False
    -- Reports the stale-supervisor verification failure once, on the
    -- transition into this state, rather than on every ~200ms recovery poll;
    -- the unresolved state itself remains visible via 'WorkerOrphaned'.
    reportStaleRecoveryPending state = do
      let message = "stale-supervisor recovery: a process snapshot failed while verifying the worker and its recorded descendants are gone; retaining orphan state and lease"
          pendingOutcome = SolveFailed message
      unless (state.workerStateStatus == WorkerOrphaned pendingOutcome) $ do
        writeState descriptor state {workerStateStatus = WorkerOrphaned pendingOutcome, workerStateLastActivity = "stale-recovery verification pending"}
        eventSink spec.workerId spec (WorkerDiagnostic message)
      pure False

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
              -- flight (see 'runWorkerWith'), so this escalates to SIGKILL
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

-- | Durably records the freshly spawned supervisor's identity onto the
-- lease this launch already holds, so a later recovery pass with no other
-- way to learn its PID — its own state file may never appear, e.g. a slow
-- or crashed start — can still tell a live supervisor from a dead one
-- instead of guessing from elapsed time alone. Best-effort and idempotent:
-- a snapshot or lookup failure just leaves the lease without an identity
-- for this attempt (the caller retries across the whole startup window
-- rather than giving up after one), and a lease that already carries an
-- identity is left untouched rather than rewritten on every poll.
recordLaunchedSupervisorIdentity :: WorkerDescriptor -> ProcessHandle -> IO ()
recordLaunchedSupervisorIdentity descriptor processHandle = do
  existing <- decodeFile descriptor.workerDescriptorLeaseOwnerPath :: IO (Either Text WorkerLease)
  case existing of
    Right lease
      | lease.workerLeaseId == descriptor.workerDescriptorSpec.workerId,
        Nothing <- lease.workerLeaseSupervisorIdentity -> do
          maybePid <- getPid processHandle
          case maybePid of
            Nothing -> pure ()
            Just pid -> do
              snapshotResult <- defaultProcessSnapshot
              case snapshotResult of
                Left _ -> pure ()
                Right snapshot -> case identityForPid (fromIntegral pid) snapshot of
                  Nothing -> pure ()
                  Just identity -> void (writePrivateJson descriptor.workerDescriptorLeaseOwnerPath lease {workerLeaseSupervisorIdentity = Just identity})
    _ -> pure ()

-- | Whether the freshly launched supervisor identity durably recorded on
-- this lease (see 'recordLaunchedSupervisorIdentity') still matches a
-- process, for recovery paths reached before any worker state file exists
-- to consult instead. 'Nothing' means no identity was ever recorded (a
-- legacy lease predating this field, or a launch whose best-effort
-- recording failed), so the caller falls back to its own existing
-- time-based heuristic rather than guessing from a signal that was never
-- captured.
supervisorLaunchIdentityPresenceWith :: IO (Either Text [ProcessIdentity]) -> WorkerDescriptor -> IO (Maybe IdentityPresence)
supervisorLaunchIdentityPresenceWith takeSnapshot descriptor = do
  leaseResult <- decodeFile descriptor.workerDescriptorLeaseOwnerPath :: IO (Either Text WorkerLease)
  case leaseResult of
    Left _ -> pure Nothing
    Right lease -> case lease.workerLeaseSupervisorIdentity of
      Nothing -> pure Nothing
      Just identity -> Just <$> checkIdentityPresenceWith takeSnapshot [identity]

discoverWorkers :: Repository -> IO [WorkerDescriptor]
discoverWorkers repository = do
  now <- getCurrentTime
  descriptors <- discoverWorkerHistory repository
  filterM (attachable now) descriptors
  where
    attachable now descriptor = do
      acknowledged <- doesFileExist descriptor.workerDescriptorAckPath
      stateResult <- readWorkerState descriptor
      pure $ case stateResult of
        Right state -> case state.workerStateStatus of
          WorkerStarting -> True
          WorkerRunning -> True
          WorkerOrphaned _ -> True
          WorkerTerminal _ -> not acknowledged
        Left _ -> not acknowledged && diffUTCTime now descriptor.workerDescriptorSpec.workerCreatedAt < workerDiscoveryStartupGraceSeconds

discoverWorkerHistory :: Repository -> IO [WorkerDescriptor]
discoverWorkerHistory repository = do
  directory <- workerDirectory repository
  exists <- doesDirectoryExist directory
  entries <- if not exists then pure [] else do
    listed <- try @IOException (listDirectory directory)
    pure (either (const []) id listed)
  descriptors <- mapM (descriptorFromName directory) [name | name <- entries, ".spec.json" `Text.isSuffixOf` Text.pack name]
  pure (sortOn (workerCreatedAt . (.workerDescriptorSpec)) (catMaybes descriptors))
  where
    descriptorFromName directory name = do
      decoded <- decodeFile (directory </> name)
      case decoded of
        Left _ -> pure Nothing
        Right spec
          | spec.workerRepository.repositoryRoot /= repository.repositoryRoot -> pure Nothing
          | otherwise -> do
              Just <$> descriptorForSpec spec

readWorkerState :: WorkerDescriptor -> IO (Either Text WorkerState)
readWorkerState descriptor = decodeFile descriptor.workerDescriptorStatePath

acknowledgeWorker :: WorkerDescriptor -> IO ()
acknowledgeWorker descriptor = do
  result <- try @IOException (ByteString.writeFile descriptor.workerDescriptorAckPath "handled\n")
  case result of
    Left _ -> pure ()
    Right () -> setFileMode descriptor.workerDescriptorAckPath 0o600

acknowledgeSupersededWorkers :: WorkerDescriptor -> IO ()
acknowledgeSupersededWorkers current = do
  history <- discoverWorkerHistory current.workerDescriptorSpec.workerRepository
  mapM_ acknowledgeWorker (filter superseded history)
  where
    currentSpec = current.workerDescriptorSpec
    superseded candidate =
      candidate.workerDescriptorSpec.workerId /= currentSpec.workerId
        && candidate.workerDescriptorSpec.workerCreatedAt <= currentSpec.workerCreatedAt
        && taskSupersedes currentSpec candidate.workerDescriptorSpec

taskSupersedes :: WorkerSpec -> WorkerSpec -> Bool
taskSupersedes current previous = case current.workerTask of
  SolveWorkerTaskKind task -> case previous.workerTask of
    SolveWorkerTaskKind oldTask -> oldTask.solveWorkerIssueNumber == task.solveWorkerIssueNumber
    PullRequestWorkerTaskKind _ -> False
  PullRequestWorkerTaskKind task -> case previous.workerTask of
    PullRequestWorkerTaskKind oldTask -> oldTask.pullRequestWorkerNumber == task.pullRequestWorkerNumber
    SolveWorkerTaskKind oldTask ->
      maybe False ((== oldTask.solveWorkerIssueNumber) . (.workerParentIssueNumber)) current.workerParent

terminateWorker :: WorkerDescriptor -> IO ()
terminateWorker = terminateWorkerWith defaultProcessSnapshot

terminateWorkerWith :: IO (Either Text [ProcessIdentity]) -> WorkerDescriptor -> IO ()
terminateWorkerWith takeSnapshot descriptor = do
  stateResult <- readWorkerState descriptor
  case stateResult of
    Left _ -> pure ()
    Right state -> case state.workerStateStatus of
      WorkerTerminal _ -> pure ()
      _ -> do
        completed <- finalizeUserTermination takeSnapshot descriptor state
        if completed
          then releaseWorkerLease descriptor
          else recordPendingTermination descriptor

-- | Marks a user-requested termination that a snapshot failure kept
-- inconclusive, so a later recovery pass ('recoverIfWorkerStoppedWith')
-- retries it once the worker's heartbeat is next observed. This is a
-- dedicated marker file rather than a 'WorkerState' field: the live
-- supervisor still owns and periodically rewrites the state file from its
-- own in-memory copy (heartbeat, census), which would otherwise clobber a
-- flag set here from outside that process. Reports a diagnostic only on the
-- transition into this state, so pressing kill again while it is still
-- pending does not duplicate the message.
recordPendingTermination :: WorkerDescriptor -> IO ()
recordPendingTermination descriptor = do
  alreadyPending <- doesFileExist descriptor.workerDescriptorPendingTerminationPath
  unless alreadyPending $ do
    result <- try @IOException (ByteString.writeFile descriptor.workerDescriptorPendingTerminationPath "pending\n")
    case result of
      Left _ -> pure ()
      Right () -> setFileMode descriptor.workerDescriptorPendingTerminationPath 0o600
    lock <- newMVar ()
    appendWorkerEvent descriptor lock (WorkerDiagnostic (pendingTerminationDiagnosticPrefix <> "; retaining lease and retrying"))

-- | Shared with the UI layer so it can recognize this specific diagnostic
-- (by text, since 'WorkerDiagnostic' carries free-form text) and render the
-- session as orphaned rather than running — both live and when a durable
-- worker event journal is replayed fresh after a TUI restart, since a
-- restart never re-runs the optimistic "killed by user" UI transition this
-- diagnostic would otherwise be correcting.
pendingTerminationDiagnosticPrefix :: Text
pendingTerminationDiagnosticPrefix = "user termination: could not verify recorded descendants are gone"

-- | Attempts to complete a requested termination: verifies the provider and
-- recorded-descendant groups are gone, and only then signals the
-- supervisor's own group and writes the terminal "killed by user" outcome.
-- The supervisor itself must never be signaled until its provider and
-- recorded children are confirmed handled: a real TERM there lets the
-- supervisor's own shutdown path race this function's later checks, so an
-- earlier inconclusive (snapshot-failed) step has to stop everything, not
-- just the final state write. Shared by the initial 'terminateWorkerWith'
-- call and by 'recoverIfWorkerStoppedWith' retrying a pending termination.
finalizeUserTermination :: IO (Either Text [ProcessIdentity]) -> WorkerDescriptor -> WorkerState -> IO Bool
finalizeUserTermination takeSnapshot descriptor state = do
  providerOk <- terminateProviderGroupWith takeSnapshot state
  recordedOk <- terminateRecordedStateProcessesWith takeSnapshot state
  if not (providerOk && recordedOk)
    then pure False
    else do
      selfOk <- terminateWorkerSelfWith takeSnapshot state
      if selfOk
        then do
          now <- getCurrentTime
          let outcome = SolveFailed "killed by user"
          writeState
            descriptor
            state
              { workerStateStatus = WorkerTerminal outcome,
                workerStateProviderPid = Nothing,
                workerStateProviderIdentity = Nothing,
                workerStateHeartbeatAt = now,
                workerStateLastActivity = "killed by user"
              }
          ignoreFileOperation (removeFile descriptor.workerDescriptorPendingTerminationPath)
          pure True
        else pure False

-- | The worker supervisor is its own process-group leader (`new_session =
-- True` at launch), so its recorded identity's group id is the signal
-- target; group membership (not just PID/start time) is re-verified at each
-- checkpoint so a supervisor that kept its PID and start time but moved
-- groups is never mistaken for still owning the old group id. Uses the same
-- grace-window TERM/KILL cadence as 'Kanban.Process.killVerifiedGroup' but
-- keeps the longer, more patient exit-poll this supervisor's own graceful
-- shutdown (which itself terminates its provider and recorded children) can
-- need.
terminateWorkerSelfWith :: IO (Either Text [ProcessIdentity]) -> WorkerState -> IO Bool
terminateWorkerSelfWith takeSnapshot state = case state.workerStateWorkerIdentity of
  Nothing -> pure False
  Just workerIdentity -> do
    let groupPid = workerIdentity.processIdentityGroupPid
    initial <- checkGroupMembershipWith takeSnapshot groupPid [workerIdentity]
    case initial of
      IdentitySnapshotFailed _ -> pure False
      IdentityAbsent -> pure True
      IdentityPresent -> do
        ignoreSignal (signalProcessGroup sigTERM (fromIntegral groupPid))
        stopped <- waitForGroupMembershipStop takeSnapshot groupPid [workerIdentity] workerTerminationAttempts
        if stopped
          then pure True
          else do
            final <- checkGroupMembershipWith takeSnapshot groupPid [workerIdentity]
            case final of
              IdentityPresent -> do
                ignoreSignal (signalProcessGroup sigKILL (fromIntegral groupPid))
                waitForGroupMembershipStop takeSnapshot groupPid [workerIdentity] workerTerminationAttempts
              IdentityAbsent -> pure True
              IdentitySnapshotFailed _ -> pure False

waitForGroupMembershipStop :: IO (Either Text [ProcessIdentity]) -> Int -> [ProcessIdentity] -> Int -> IO Bool
waitForGroupMembershipStop takeSnapshot groupPid expected attempts = do
  presence <- checkGroupMembershipWith takeSnapshot groupPid expected
  case presence of
    IdentityAbsent -> pure True
    _
      | attempts <= 0 -> pure False
      | otherwise -> threadDelay workerTerminationPollMicros >> waitForGroupMembershipStop takeSnapshot groupPid expected (attempts - 1)

ignoreSignal :: IO () -> IO ()
ignoreSignal action = void (try @IOException action)

descriptorForSpec :: WorkerSpec -> IO WorkerDescriptor
descriptorForSpec spec = do
  directory <- workerDirectory spec.workerRepository
  let base = Text.unpack spec.workerId.unWorkerId
      leasePath = directory </> workerLeaseKey spec.workerTask <> ".lease"
  pure
    WorkerDescriptor
      { workerDescriptorSpec = spec,
        workerDescriptorSpecPath = directory </> base <> ".spec.json",
        workerDescriptorEventPath = directory </> base <> ".events.jsonl",
        workerDescriptorStatePath = directory </> base <> ".state.json",
        workerDescriptorAckPath = directory </> base <> ".ack",
        workerDescriptorLeasePath = leasePath,
        workerDescriptorLeaseOwnerPath = leasePath </> "owner.json",
        workerDescriptorPendingTerminationPath = directory </> base <> ".pending-termination"
      }

workerLeaseKey :: WorkerTask -> FilePath
workerLeaseKey task = case task of
  SolveWorkerTaskKind solveTask -> "issue-" <> show solveTask.solveWorkerIssueNumber
  PullRequestWorkerTaskKind pullRequestTask -> "pr-" <> show pullRequestTask.pullRequestWorkerNumber

workerDirectory :: Repository -> IO FilePath
workerDirectory repository = do
  cacheRoot <- getXdgDirectory XdgCache "kanban"
  pure (cacheRoot </> "workers" </> safeKey (repository.repositoryOwner <> "-" <> repository.repositoryName))

newWorkerId :: Text -> Int -> IO WorkerId
newWorkerId category number = do
  now <- getCurrentTime
  pid <- getProcessID
  pure . WorkerId $ category <> "-" <> Text.pack (show number) <> "-" <> timestampKey now <> "-" <> Text.pack (show pid)

timestampKey :: UTCTime -> Text
timestampKey = Text.filter (`notElem` ("-:.TZ " :: String)) . Text.pack . show

safeKey :: Text -> FilePath
safeKey = Text.unpack . Text.map replace
  where
    replace character
      | character `elem` ['/', '\\', ':', ' '] = '-'
      | otherwise = character

appendWorkerEvent :: WorkerDescriptor -> MVar () -> WorkerEvent -> IO ()
appendWorkerEvent descriptor lock event = withMVar lock $ \() -> do
  now <- getCurrentTime
  handle <- openBinaryFile descriptor.workerDescriptorEventPath AppendMode
  hSetBuffering handle LineBuffering
  LazyByteString.hPut handle (encode (WorkerEnvelope now event))
  LazyByteString.hPut handle "\n"
  -- The handle is intentionally short-lived so a TUI restart always sees a
  -- fully flushed record and the worker never retains a deleted log inode.
  hClose handle

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

persistState :: WorkerDescriptor -> MVar WorkerState -> IO ()
persistState descriptor stateLock = withMVar stateLock (writeState descriptor)

writeState :: WorkerDescriptor -> WorkerState -> IO ()
writeState descriptor = void . writePrivateJson descriptor.workerDescriptorStatePath

heartbeatLoop :: WorkerDescriptor -> MVar WorkerState -> IORef Bool -> IO ()
heartbeatLoop descriptor stateLock stoppedRef = do
  threadDelay workerHeartbeatIntervalMicros
  stopped <- readIORef stoppedRef
  unless stopped $ do
    modifyMVar_ stateLock $ \state -> do
      now <- getCurrentTime
      let updated = state {workerStateHeartbeatAt = now}
      writeState descriptor updated
      pure updated
    heartbeatLoop descriptor stateLock stoppedRef

processCensusLoop :: WorkerDescriptor -> MVar WorkerState -> IORef Bool -> IO ()
processCensusLoop descriptor stateLock stoppedRef = do
  threadDelay workerCensusIntervalMicros
  stopped <- readIORef stoppedRef
  unless stopped $ do
    refreshProcessCensus descriptor stateLock
    processCensusLoop descriptor stateLock stoppedRef

-- | Records the provider's PID, start identity, and group id the moment it
-- is observed, so census roots and later terminate paths always have an
-- anchor to verify against rather than trusting a raw, possibly-reused PID.
recordProviderIdentity :: WorkerDescriptor -> MVar WorkerState -> Int -> IO ()
recordProviderIdentity descriptor stateLock providerPid = do
  snapshotResult <- readProcessSnapshot
  case snapshotResult of
    Left _ -> pure ()
    Right snapshot -> modifyMVar_ stateLock $ \state -> do
      let updated = state {workerStateProviderIdentity = identityForPid providerPid snapshot}
      writeState descriptor updated
      pure updated

-- | A recorded process contributes as a census root only while a fresh
-- snapshot still shows its PID with the same start identity; a mismatch
-- (PID reuse) or absence drops it instead of walking into an unrelated
-- process's descendants. Previously-known entries that no longer match are
-- pruned rather than retained as raw, unverifiable PIDs.
refreshProcessCensus :: WorkerDescriptor -> MVar WorkerState -> IO ()
refreshProcessCensus descriptor stateLock = do
  snapshotResult <- readProcessSnapshot
  case snapshotResult of
    Left _ -> pure ()
    Right snapshot ->
      modifyMVar_ stateLock $ \state -> do
        let survivingKnown = matchingIdentities snapshot state.workerStateKnownProcesses
            providerRoots = maybe [] (map processIdentityPid . matchingIdentities snapshot . (: [])) state.workerStateProviderIdentity
            roots = providerRoots <> map processIdentityPid survivingKnown
            observed = descendantProcesses roots snapshot
            combined = Map.elems (Map.fromList [(processKey process, process) | process <- survivingKnown <> observed])
            updatedProcesses = sortOn processIdentityPid combined
        if updatedProcesses == state.workerStateKnownProcesses
          then pure state
          else do
            let updated = state {workerStateKnownProcesses = updatedProcesses}
            writeState descriptor updated
            pure updated
  where
    processKey process = (process.processIdentityPid, process.processIdentityStartedAt)

liveRecordedProcessesWith :: IO (Either Text [ProcessIdentity]) -> MVar WorkerState -> IO (Either Text [ProcessIdentity])
liveRecordedProcessesWith takeSnapshot stateLock = withMVar stateLock (liveProcessesWith takeSnapshot . (.workerStateKnownProcesses))

terminateRecordedProcesses :: MVar WorkerState -> IO ()
terminateRecordedProcesses stateLock = withMVar stateLock (void . terminateRecordedStateProcesses)

-- | The provider group is signaled only while its recorded anchor identity
-- still matches a fresh snapshot; a provider that was never started is a
-- no-op success, while one that was started but has no recorded identity
-- (only possible from an unverifiable legacy state) is left unsignaled and
-- reported as inconclusive so the caller does not finalize on a guess.
terminateProviderGroupWith :: IO (Either Text [ProcessIdentity]) -> WorkerState -> IO Bool
terminateProviderGroupWith takeSnapshot state = case (state.workerStateProviderPid, state.workerStateProviderIdentity) of
  (Nothing, _) -> pure True
  (Just _, Nothing) -> pure False
  (Just _, Just providerIdentity) -> isRight <$> killVerifiedGroupWith takeSnapshot providerIdentity.processIdentityGroupPid [providerIdentity]

-- | Kills the provider currently referenced by a live 'providerRef' handle,
-- verifying its identity against a fresh snapshot first so a PID that has
-- already been reused points nowhere. Used by the deadline watchdog instead
-- of 'terminateProviderGroupWith', which sources its identity from the
-- durable 'WorkerState': that field can still be unset when the deadline
-- fires before 'rememberProvider' has finished recording it, while the live
-- handle itself is available the moment the provider starts. Returns True
-- when there was nothing to kill or the kill was confirmed complete; False
-- when a snapshot failure (or a missing observable process id) left it
-- unverified, so the caller retains a pending outcome rather than finalize
-- on a guess.
terminateProviderRefWith :: IO (Either Text [ProcessIdentity]) -> IORef (Maybe ManagedProcess) -> IO Bool
terminateProviderRefWith takeSnapshot providerRef = do
  current <- readIORef providerRef
  case current of
    Nothing -> pure True
    Just process -> do
      maybePid <- managedProcessPid process
      case maybePid of
        Nothing -> killManagedProcess process >> pure False
        Just pid -> do
          snapshotResult <- takeSnapshot
          case snapshotResult of
            Left _ -> killManagedProcess process >> pure False
            Right snapshot -> case identityForPid (fromIntegral pid) snapshot of
              Nothing -> pure True
              Just identity -> isRight <$> killVerifiedGroupWith takeSnapshot identity.processIdentityGroupPid [identity]

-- | Re-verifies each recorded process's identity before signaling its group,
-- and again before the KILL that follows the grace window, so a group that
-- exited and had its pid recycled during that window is never mistakenly
-- targeted. Returns False if any group's verification hit a snapshot
-- failure (inconclusive; the caller should retry rather than finalize).
terminateRecordedStateProcesses :: WorkerState -> IO Bool
terminateRecordedStateProcesses = terminateRecordedStateProcessesWith defaultProcessSnapshot

terminateRecordedStateProcessesWith :: IO (Either Text [ProcessIdentity]) -> WorkerState -> IO Bool
terminateRecordedStateProcessesWith takeSnapshot state = do
  results <- mapM (uncurry (killVerifiedGroupWith takeSnapshot)) (Map.toList groups)
  pure (all isRight results)
  where
    groups =
      Map.fromListWith
        (<>)
        [ (process.processIdentityGroupPid, [process])
          | process <- state.workerStateKnownProcesses,
            process.processIdentityGroupPid > 1,
            process.processIdentityGroupPid /= state.workerStateWorkerPid
        ]

-- | Polls until a fresh snapshot verifies every recorded descendant is gone,
-- then emits the terminal outcome. Runs to a real conclusion unconditionally
-- — it does not stop early on a "stop requested" signal — because its
-- caller relies on this to gate the worker's lease release: a
-- signal-triggered shutdown must not let an in-flight stop request
-- short-circuit verification. 'signalShutdownRef' is read only to label a
-- failure diagnostic as signal-triggered, never to gate the loop itself. A
-- snapshot failure retains the pending state and reports a diagnostic once
-- per distinct failure message rather than once per poll.
--
-- The pending outcome (and whether it still needs verification even once
-- the recorded census reads empty — see 'completeBody') is re-read from
-- 'pendingOutcomeRef' on every iteration rather than captured once at the
-- start: the deadline watchdog can take over this same ref after this loop
-- has already begun (a normal completion can claim completedRef and start
-- this poll well before the deadline elapses; see 'watchdogLoop'), and only
-- a re-read on each pass ever observes that takeover — the loop otherwise
-- has no other way to learn its outcome changed out from under it. This
-- assumes the caller only starts the loop once 'pendingOutcomeRef' already
-- holds 'Just'; a race where it is somehow 'Nothing' on first read never
-- happens in practice but degrades to a harmless no-op rather than a
-- crash.
--
-- Finalizing is an atomic *consume* of 'pendingOutcomeRef' — one
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
waitForOrphanResolution :: WorkerDescriptor -> MVar WorkerState -> IO (Either Text [ProcessIdentity]) -> IORef Bool -> (WorkerEvent -> IO ()) -> IORef (Maybe (Bool, SolveOutcome)) -> IO ()
waitForOrphanResolution descriptor stateLock takeSnapshot signalShutdownRef emit pendingOutcomeRef = loop Nothing
  where
    loop lastDiagnostic = do
      current <- readIORef pendingOutcomeRef
      case current of
        Nothing -> pure ()
        Just (requireVerification, outcome) -> do
          refreshProcessCensus descriptor stateLock
          known <- withMVar stateLock (\state -> pure (state.workerStateKnownProcesses))
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
                    signalTriggered <- readIORef signalShutdownRef
                    let operation = if signalTriggered then "signal shutdown" else "orphan poll" :: Text
                    emit (WorkerDiagnostic (operation <> ": could not verify recorded descendants are gone (" <> message <> "); retaining orphan state and lease"))
                    pure (Just message)
              threadDelay workerOrphanCheckIntervalMicros
              loop reported
            Right surviving
              | null surviving -> do
                  final <- atomicModifyIORef' pendingOutcomeRef (\value -> (Nothing, value))
                  emit (WorkerFinished (maybe outcome snd final))
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
-- outcome. 'stoppedRef' and 'forcedOutcomeRef' are set unconditionally as
-- soon as the delay elapses, regardless of who wins: 'stoppedRef' gates
-- 'rememberProvider' (so a registration racing this firing is killed
-- rather than left running) and stops the heartbeat/census loops;
-- 'forcedOutcomeRef' tells the supervisor the deadline fired at all — not
-- that it specifically owns the outcome — so it knows to wait on
-- 'watchdogDoneVar' below rather than racing ahead on a stale read.
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
-- (which 'watchdogDoneVar' below also independently guards against). On a
-- loss, the task thread is cancelled *before* checking the pending
-- outcome: an already-claimed normal completion may itself still be
-- running (e.g. verifying its own census); cancelling first blocks here
-- until it genuinely finishes (same masked-thread semantics as above),
-- guaranteeing a stable, already-settled 'pendingOutcomeRef' to read and
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
-- 'watchdogDoneVar' is filled unconditionally once this returns, win or
-- lose (including winning nothing at all — see 'claimLeaseRelease' below),
-- so the supervisor never mistakes a merely-fired deadline for a fully
-- settled one.
--
-- Before doing anything else — before even 'stoppedRef' — this races the
-- supervisor for 'claimLeaseRelease', immediately after the delay elapses.
-- The supervisor claims the same thing immediately before releasing the
-- lease, as late as it possibly can (see 'runWorkerWithTask'), rather than
-- inferring from any earlier snapshot whether the deadline will still fire
-- later. Losing this claim means the supervisor has already decided the
-- worker is fully done and is releasing the lease right now (or already
-- has): there is nothing left here to kill or commit, another worker may
-- already be acquiring that lease, and this does nothing further at all.
watchdogLoop :: IO (Either Text [ProcessIdentity]) -> WorkerSpec -> IORef (Maybe ManagedProcess) -> IORef Bool -> MVar WorkerState -> IORef (Maybe ThreadId) -> IORef (Maybe (Bool, SolveOutcome)) -> IORef (Maybe SolveOutcome) -> IO Bool -> (Bool -> SolveOutcome -> IO ()) -> (WorkerEvent -> IO ()) -> IO Bool -> MVar () -> IO ()
watchdogLoop takeSnapshot spec providerRef stoppedRef stateLock taskThreadIdRef pendingOutcomeRef forcedOutcomeRef claimCompletion completeBody emitRaw claimLeaseRelease watchdogDoneVar = do
  now <- getCurrentTime
  let deadline = addUTCTime (fromIntegral spec.workerMaxRuntimeSeconds) spec.workerCreatedAt
      delayMicros = max 0 (round (diffUTCTime deadline now * 1000000))
  threadDelay delayMicros
  wonLeaseRelease <- claimLeaseRelease
  when wonLeaseRelease $ do
    writeIORef stoppedRef True
    writeIORef forcedOutcomeRef (Just workerDeadlineOutcome)
    wonCompletion <- claimCompletion
    if wonCompletion
      then do
        providerOk <- terminateProviderRefWith takeSnapshot providerRef
        recordedOk <- withMVar stateLock (terminateRecordedStateProcessesWith takeSnapshot)
        completeBody (providerOk && recordedOk) workerDeadlineOutcome
        readIORef taskThreadIdRef >>= mapM_ killThread
      else do
        readIORef taskThreadIdRef >>= mapM_ killThread
        -- A single compare-and-swap: claims the takeover only while
        -- 'pendingOutcomeRef' is still 'Just' something, and no-ops (rather
        -- than clobbering 'Nothing' back to a stale 'Just') if
        -- 'waitForOrphanResolution' has already atomically consumed it —
        -- see its own documentation for why a plain read-then-write here
        -- could otherwise resurrect a value after finalization already
        -- happened. Written *before* the kill below, not after: the poll
        -- runs independently and concurrently (it has been running since
        -- the normal completion first reported this orphan, well before
        -- this deadline fired), so it can observe the kill's effect — the
        -- recorded group actually dying — the moment that happens,
        -- regardless of when this function gets around to writing the
        -- takeover. Writing the outcome first guarantees that whenever the
        -- poll's own atomic consume next runs — even racing this exact
        -- kill — it already reads the deadline reason rather than the
        -- stale original one.
        tookOver <-
          atomicModifyIORef' pendingOutcomeRef $ \pending -> case pending of
            Nothing -> (Nothing, False)
            Just _ -> (Just (False, workerDeadlineOutcome), True)
        when tookOver $ do
          known <- withMVar stateLock (pure . (.workerStateKnownProcesses))
          emitRaw (WorkerOrphansDetected workerDeadlineOutcome known)
        void (terminateProviderRefWith takeSnapshot providerRef)
        void (withMVar stateLock (terminateRecordedStateProcessesWith takeSnapshot))
  putMVar watchdogDoneVar ()

-- | The canonical externally visible reason a persistent worker's
-- 'workerMaxRuntimeSeconds' bound fired, used consistently in worker state,
-- journal events, and the UI's session/card and process-inspector
-- projections so a deadline is never mistaken for a generic provider
-- failure.
workerDeadlineReason :: Text
workerDeadlineReason = "persistent worker deadline exceeded"

workerDeadlineOutcome :: SolveOutcome
workerDeadlineOutcome = SolveFailed workerDeadlineReason

writePrivateJson :: ToJSON value => FilePath -> value -> IO (Either Text ())
writePrivateJson path value = do
  let temporary = path <> ".tmp"
  result <- try @IOException $ do
    LazyByteString.writeFile temporary (encode value)
    setFileMode temporary 0o600
    renameFile temporary path
  pure (either (Left . Text.pack . show) Right result)

decodeFile :: FromJSON value => FilePath -> IO (Either Text value)
decodeFile path = do
  bytesResult <- try @IOException (ByteString.readFile path)
  pure $ case bytesResult of
    Left exception -> Left (Text.pack (show exception))
    Right bytes -> case eitherDecodeStrict' bytes of
      Left message -> Left (Text.pack message)
      Right value -> Right value

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

workerMonitorIntervalMicros :: Int
workerMonitorIntervalMicros = 200 * 1000

workerStartupAttempts :: Int
workerStartupAttempts = 60

workerStartupIntervalMicros :: Int
workerStartupIntervalMicros = 50 * 1000

workerStaleHeartbeatSeconds :: NominalDiffTime
workerStaleHeartbeatSeconds = 20

workerDiscoveryStartupGraceSeconds :: NominalDiffTime
workerDiscoveryStartupGraceSeconds = 30

workerLeaseInitializationGraceSeconds :: NominalDiffTime
workerLeaseInitializationGraceSeconds = 10

workerLeaseAttempts :: Int
workerLeaseAttempts = 3

workerTerminationAttempts :: Int
workerTerminationAttempts = 20

workerTerminationPollMicros :: Int
workerTerminationPollMicros = 100 * 1000

anyM :: Monad monad => (value -> monad Bool) -> [value] -> monad Bool
anyM predicate = go
  where
    go [] = pure False
    go (value : rest) = do
      matches <- predicate value
      if matches then pure True else go rest
