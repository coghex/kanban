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
    readWorkerState,
    releaseWorkerLease,
    runWorker,
    terminateWorker,
  )
where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, withMVar)
import Control.Exception (IOException, SomeException, try)
import Control.Monad (filterM, unless, void)
import Data.Aeson (FromJSON (..), ToJSON, eitherDecodeStrict', encode, withObject, (.:), (.:?), (.!=))
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import GHC.Generics (Generic)
import Kanban.Domain (Repository (..))
import Kanban.Process
  ( ManagedProcess,
    ProcessIdentity (..),
    descendantProcesses,
    killManagedProcess,
    liveProcesses,
    managedProcessGroup,
    managedProcessPid,
    readProcessSnapshot,
  )
import Kanban.PullRequestFlow (PullRequestAction, PullRequestFlowEvent (..), PullRequestOrigin, runPullRequestFlow)
import Kanban.Solve (AgentEvent (..), SolveEvent (..), SolveOutcome (..), SolveWorkflow, SolverBrand, runSolve)
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
import System.Posix.Signals (Handler (Catch), installHandler, nullSignal, sigINT, sigKILL, sigTERM, signalProcess, signalProcessGroup)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (NoStream), createProcess, getProcessExitCode, proc, terminateProcess)
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
    workerUserMessage :: Text,
    workerParent :: Maybe WorkerParent,
    workerCreatedAt :: UTCTime,
    workerMaxRuntimeSeconds :: Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

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
    workerStateProviderPid :: Maybe Int,
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
      <*> object .: "workerStateProviderPid"
      <*> object .: "workerStateSessionId"
      <*> object .: "workerStateLogPath"
      <*> object .: "workerStateHeartbeatAt"
      <*> object .: "workerStateLastActivity"
      <*> object .:? "workerStateKnownProcesses" .!= []

data WorkerLease = WorkerLease
  { workerLeaseId :: WorkerId,
    workerLeaseCreatedAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

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
    workerDescriptorLeaseOwnerPath :: FilePath
  }
  deriving stock (Eq, Show)

launchSolveWorker :: Repository -> Int -> SolveWorkflow -> SolverBrand -> Maybe Text -> Maybe FilePath -> Text -> Maybe WorkerParent -> IO (Either Text WorkerDescriptor)
launchSolveWorker repository issueNumber workflow brand existingSession existingLogPath userMessage parent = do
  now <- getCurrentTime
  workerId <- newWorkerId "solve" issueNumber
  launchWorker
    WorkerSpec
      { workerId,
        workerRepository = repository,
        workerTask = SolveWorkerTaskKind (SolveWorkerTask issueNumber workflow brand),
        workerExistingSession = existingSession,
        workerExistingLogPath = existingLogPath,
        workerUserMessage = userMessage,
        workerParent = parent,
        workerCreatedAt = now,
        workerMaxRuntimeSeconds = defaultWorkerMaxRuntimeSeconds
      }

launchPullRequestWorker :: Repository -> Int -> PullRequestOrigin -> PullRequestAction -> Maybe Text -> Maybe FilePath -> Text -> Maybe WorkerParent -> IO (Either Text WorkerDescriptor)
launchPullRequestWorker repository number origin action existingSession existingLogPath userMessage parent = do
  now <- getCurrentTime
  workerId <- newWorkerId "pr" number
  launchWorker
    WorkerSpec
      { workerId,
        workerRepository = repository,
        workerTask = PullRequestWorkerTaskKind (PullRequestWorkerTask number origin action),
        workerExistingSession = existingSession,
        workerExistingLogPath = existingLogPath,
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
              result <- waitForWorkerStart descriptor processHandle workerStartupAttempts
              case result of
                Left _ -> acknowledgeWorker descriptor >> releaseWorkerLease descriptor
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
                  workerLeaseCreatedAt = descriptor.workerDescriptorSpec.workerCreatedAt
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
    Right lease -> do
      let statePath = takeDirectory descriptor.workerDescriptorLeasePath </> Text.unpack lease.workerLeaseId.unWorkerId <> ".state.json"
      stateResult <- decodeFile statePath :: IO (Either Text WorkerState)
      case stateResult of
        Right state -> case state.workerStateStatus of
          WorkerTerminal _ -> pure False
          _ -> processExists state.workerStateWorkerPid
        Left _ -> leaseIsRecent descriptor
    Left _ -> leaseIsRecent descriptor

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
runWorker specPath = do
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
      stateLock <- newMVar
        WorkerState
          { workerStateId = spec.workerId,
            workerStateStatus = WorkerStarting,
            workerStateWorkerPid = pid,
            workerStateProviderPid = Nothing,
            workerStateSessionId = Nothing,
            workerStateLogPath = Nothing,
            workerStateHeartbeatAt = now,
            workerStateLastActivity = "starting",
            workerStateKnownProcesses = []
          }
      eventLock <- newMVar ()
      providerRef <- newIORef Nothing
      stoppedRef <- newIORef False
      pendingOutcomeRef <- newIORef Nothing
      let stopOwnedWork = do
            writeIORef stoppedRef True
            readIORef providerRef >>= mapM_ killManagedProcess
            terminateRecordedProcesses stateLock
      previousTermHandler <- installHandler sigTERM (Catch stopOwnedWork) Nothing
      previousInterruptHandler <- installHandler sigINT (Catch stopOwnedWork) Nothing
      persistState descriptor stateLock
      void . forkIO $ heartbeatLoop descriptor stateLock stoppedRef
      void . forkIO $ watchdogLoop spec providerRef stoppedRef
      void . forkIO $ processCensusLoop descriptor stateLock providerRef stoppedRef
      let emitRaw event = do
            appendWorkerEvent descriptor eventLock event
            updateWorkerState descriptor stateLock event
            case event of
              WorkerFinished _ -> writeIORef stoppedRef True
              _ -> pure ()
          complete outcome = do
            refreshProcessCensus descriptor stateLock providerRef
            survivors <- liveRecordedProcesses stateLock
            if null survivors
              then emitRaw (WorkerFinished outcome)
              else do
                writeIORef pendingOutcomeRef (Just outcome)
                emitRaw (WorkerOrphansDetected outcome survivors)
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
                    emit (WorkerProviderStarted (fromIntegral providerPid))
                    refreshProcessCensus descriptor stateLock providerRef
                  Nothing -> do
                    let message = "provider started without an observable process-group id; terminating it for safety"
                    emit (WorkerDiagnostic message)
                    killManagedProcess process
          runTask = case spec.workerTask of
            SolveWorkerTaskKind task ->
              runSolve spec.workerRepository task.solveWorkerIssueNumber task.solveWorkerWorkflow task.solveWorkerBrand spec.workerExistingSession spec.workerExistingLogPath spec.workerUserMessage
                (translateSolveEvent rememberProvider emit)
            PullRequestWorkerTaskKind task ->
              runPullRequestFlow spec.workerRepository task.pullRequestWorkerNumber task.pullRequestWorkerOrigin task.pullRequestWorkerAction spec.workerExistingSession spec.workerExistingLogPath spec.workerUserMessage
                (translatePullRequestEvent rememberProvider emit)
      taskResult <- try @SomeException runTask
      case taskResult of
        Right () -> do
          stopped <- readIORef stoppedRef
          pending <- readIORef pendingOutcomeRef
          if stopped || pending /= Nothing
            then pure ()
            else complete (SolveFailed "persistent worker task ended without a terminal provider event")
        Left exception -> do
          refreshProcessCensus descriptor stateLock providerRef
          readIORef providerRef >>= mapM_ killManagedProcess
          let message = "persistent worker failed: " <> Text.pack (show exception)
          void . try @SomeException $ do
            emitRaw (WorkerDiagnostic message)
            complete (SolveFailed message)
      pending <- readIORef pendingOutcomeRef
      mapM_ (waitForOrphanResolution descriptor stateLock providerRef stoppedRef emitRaw) pending
      writeIORef stoppedRef True
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
recoverIfWorkerStopped descriptor eventSink = do
  stateResult <- readWorkerState descriptor
  case stateResult of
    Left _ -> do
      now <- getCurrentTime
      if diffUTCTime now spec.workerCreatedAt < workerMissingStateGraceSeconds
        then pure False
        else do
          let message = "persistent worker never published its initial state"
          releaseWorkerLease descriptor
          eventSink spec.workerId spec (WorkerDiagnostic message)
          eventSink spec.workerId spec (WorkerFinished (SolveFailed message))
          pure True
    Right state -> case state.workerStateStatus of
      WorkerTerminal outcome -> do
        releaseWorkerLease descriptor
        eventSink spec.workerId spec (WorkerFinished outcome)
        pure True
      _ -> do
        now <- getCurrentTime
        if diffUTCTime now state.workerStateHeartbeatAt < workerStaleHeartbeatSeconds
          then pure False
          else do
            alive <- processExists state.workerStateWorkerPid
            if alive
              then pure False
              else do
                mapM_ (killManagedProcess . managedProcessGroup . fromIntegral) state.workerStateProviderPid
                terminateRecordedStateProcesses state
                let message = "persistent worker stopped unexpectedly; its provider process group was terminated"
                    outcome = SolveFailed message
                    terminalState =
                      state
                        { workerStateStatus = WorkerTerminal outcome,
                          workerStateProviderPid = Nothing,
                          workerStateHeartbeatAt = now,
                          workerStateLastActivity = "worker failed closed"
                        }
                writeState descriptor terminalState
                releaseWorkerLease descriptor
                eventSink spec.workerId spec (WorkerDiagnostic message)
                eventSink spec.workerId spec (WorkerFinished outcome)
                pure True
  where
    spec = descriptor.workerDescriptorSpec

processExists :: Int -> IO Bool
processExists processId = do
  result <- try @IOException (signalProcess nullSignal (fromIntegral processId))
  pure $ case result of
    Right () -> True
    Left _ -> False

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
              terminateProcess processHandle
              pure (Left "persistent worker did not initialize within three seconds")
          | otherwise -> do
              threadDelay workerStartupIntervalMicros
              waitForWorkerStart descriptor processHandle (attempts - 1)

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
terminateWorker descriptor = do
  stateResult <- readWorkerState descriptor
  case stateResult of
    Left _ -> pure ()
    Right state -> case state.workerStateStatus of
      WorkerTerminal _ -> pure ()
      _ -> do
        mapM_ (killManagedProcess . managedProcessGroup . fromIntegral) state.workerStateProviderPid
        terminateRecordedStateProcesses state
        ignoreSignal (signalProcessGroup sigTERM (fromIntegral state.workerStateWorkerPid))
        stopped <- waitForProcessStop state.workerStateWorkerPid workerTerminationAttempts
        unless stopped $ do
          ignoreSignal (signalProcessGroup sigKILL (fromIntegral state.workerStateWorkerPid))
          void (waitForProcessStop state.workerStateWorkerPid workerTerminationAttempts)
        now <- getCurrentTime
        let outcome = SolveFailed "killed by user"
        writeState
          descriptor
          state
            { workerStateStatus = WorkerTerminal outcome,
              workerStateProviderPid = Nothing,
              workerStateHeartbeatAt = now,
              workerStateLastActivity = "killed by user"
            }
        releaseWorkerLease descriptor

waitForProcessStop :: Int -> Int -> IO Bool
waitForProcessStop processId attempts = do
  alive <- processExists processId
  if not alive
    then pure True
    else
      if attempts <= 0
        then pure False
        else threadDelay workerTerminationPollMicros >> waitForProcessStop processId (attempts - 1)

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
        workerDescriptorLeaseOwnerPath = leasePath </> "owner.json"
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
        WorkerProviderStarted processId -> state {workerStateStatus = WorkerRunning, workerStateProviderPid = Just processId, workerStateLastActivity = "provider running"}
        WorkerLogOpened path -> state {workerStateLogPath = Just path, workerStateLastActivity = "log opened"}
        WorkerSessionIdentified sessionId -> state {workerStateSessionId = Just sessionId, workerStateLastActivity = "session identified"}
        WorkerAgentOutput output -> state {workerStateLastActivity = Text.take 160 output.agentEventSummary}
        WorkerDiagnostic _ -> state {workerStateLastActivity = "diagnostic output"}
        WorkerOrphansDetected outcome surviving ->
          state
            { workerStateStatus = WorkerOrphaned outcome,
              workerStateProviderPid = Nothing,
              workerStateLastActivity = showProcessCount surviving <> " orphaned subprocesses"
            }
        WorkerFinished outcome -> state {workerStateStatus = WorkerTerminal outcome, workerStateProviderPid = Nothing, workerStateLastActivity = terminalActivity outcome}
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

processCensusLoop :: WorkerDescriptor -> MVar WorkerState -> IORef (Maybe ManagedProcess) -> IORef Bool -> IO ()
processCensusLoop descriptor stateLock providerRef stoppedRef = do
  threadDelay workerCensusIntervalMicros
  stopped <- readIORef stoppedRef
  unless stopped $ do
    refreshProcessCensus descriptor stateLock providerRef
    processCensusLoop descriptor stateLock providerRef stoppedRef

refreshProcessCensus :: WorkerDescriptor -> MVar WorkerState -> IORef (Maybe ManagedProcess) -> IO ()
refreshProcessCensus descriptor stateLock providerRef = do
  providerPid <- readIORef providerRef >>= maybe (pure Nothing) managedProcessPid
  snapshotResult <- readProcessSnapshot
  case snapshotResult of
    Left _ -> pure ()
    Right snapshot ->
      modifyMVar_ stateLock $ \state -> do
        let roots = maybe id (:) (fromIntegral <$> providerPid) (map processIdentityPid state.workerStateKnownProcesses)
            observed = descendantProcesses roots snapshot
            combined = Map.elems (Map.fromList [(processKey process, process) | process <- state.workerStateKnownProcesses <> observed])
            updatedProcesses = sortOn processIdentityPid combined
        if updatedProcesses == state.workerStateKnownProcesses
          then pure state
          else do
            let updated = state {workerStateKnownProcesses = updatedProcesses}
            writeState descriptor updated
            pure updated
  where
    processKey process = (process.processIdentityPid, process.processIdentityStartedAt)

liveRecordedProcesses :: MVar WorkerState -> IO [ProcessIdentity]
liveRecordedProcesses stateLock = withMVar stateLock (liveProcesses . (.workerStateKnownProcesses))

terminateRecordedProcesses :: MVar WorkerState -> IO ()
terminateRecordedProcesses stateLock = withMVar stateLock terminateRecordedStateProcesses

terminateRecordedStateProcesses :: WorkerState -> IO ()
terminateRecordedStateProcesses state = do
  surviving <- liveProcesses state.workerStateKnownProcesses
  let groups =
        Set.toList
          ( Set.fromList
              [ process.processIdentityGroupPid
                | process <- surviving,
                  process.processIdentityGroupPid > 1,
                  process.processIdentityGroupPid /= state.workerStateWorkerPid
              ]
          )
  mapM_ (killManagedProcess . managedProcessGroup . fromIntegral) groups

waitForOrphanResolution :: WorkerDescriptor -> MVar WorkerState -> IORef (Maybe ManagedProcess) -> IORef Bool -> (WorkerEvent -> IO ()) -> SolveOutcome -> IO ()
waitForOrphanResolution descriptor stateLock providerRef stoppedRef emit outcome = loop
  where
    loop = do
      stopped <- readIORef stoppedRef
      unless stopped $ do
        refreshProcessCensus descriptor stateLock providerRef
        surviving <- liveRecordedProcesses stateLock
        if null surviving
          then emit (WorkerFinished outcome)
          else threadDelay workerOrphanCheckIntervalMicros >> loop

watchdogLoop :: WorkerSpec -> IORef (Maybe ManagedProcess) -> IORef Bool -> IO ()
watchdogLoop spec providerRef stoppedRef = do
  threadDelay (spec.workerMaxRuntimeSeconds * 1000 * 1000)
  stopped <- readIORef stoppedRef
  unless stopped $ readIORef providerRef >>= mapM_ killManagedProcess

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

workerMissingStateGraceSeconds :: NominalDiffTime
workerMissingStateGraceSeconds = 10

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
