{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Independent OS processes acting on one mission store.
--
-- Two of issue #592's acceptance cases are about what a /second process/ sees,
-- and neither can be established from inside the process making the assertion.
-- A mission written and then \"read back in a fresh process\" is only a
-- round-trip proof if the reader shares nothing with the writer but the files.
-- And a mission lease released by its holder /being killed/ can only be staged
-- by a holder there is something to kill: the successor's acquisition is
-- evidence about @IdentityAbsent@ only when the identity the lease recorded
-- belonged to a real process that a real signal ended.
--
-- The mission lease is a directory won with @createDirectory@ rather than
-- "Kanban.Repository.Lease"'s POSIX record lock, so — unlike the fixture
-- "Spec.Support.LeaseProbes" builds — a thread-based contention test here
-- would not prove the /opposite/ of what it claimed. It would merely prove
-- less: that one process cannot take a lease twice, which is not the invariant
-- a dashboard and a background runner depend on.
--
-- So each probe is the test binary run again, taking the branch in @main@ that
-- leads to 'runMissionProbe' instead of to hspec. The shape is
-- "Spec.Support.LeaseProbes"'s, deliberately: a marker in the child's
-- environment, answers carried back through files, gates the parent opens one
-- at a time so an ordering is staged rather than hoped for, and every way of
-- failing terminating and reaping every probe before it reports. What is
-- different is only what a probe is asked to do — this harness has two actions
-- rather than one, and its store is a plain path rather than an environment
-- the child has to resolve.
--
-- A probe passes through five states, and each is a file:
--
--   [@started@] it is running and is at its gate. Every probe is waited for
--     here before the body runs, so the rendezvous is a state the parent
--     established rather than a delay it guessed at.
--   [@gate@] opened by the parent. The probe performs its action exactly once
--     and records what it was told.
--   [@release@] opened by the parent. A probe holding a lease gives it up.
--   [@released@] written by the probe, /while it is still running/, which is
--     the only condition under which a successor's acquisition proves
--     anything about release rather than about process exit.
--   [@retire@] opened by the parent. The probe exits.
module Spec.Support.MissionProbes
  ( MissionProbe (..),
    MissionProbeAction (..),
    MissionProbeOutcome (..),
    MissionProbeReadback (..),
    MissionProbeReport (..),
    MissionProbeSealOutcome (..),
    MissionProbes,
    awaitMissionReport,
    killMissionHolder,
    missionProbeEnvironment,
    missionProbeVariable,
    openMissionGate,
    releaseMissionHolder,
    runMissionProbe,
    withMissionProbes,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket_)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (FromJSON, ToJSON, eitherDecodeFileStrict', encode)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find, isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import GHC.Generics (Generic)
import Kanban.Mission
  ( MissionEvent (..),
    MissionId (..),
    MissionJournalLine (MissionJournalEvent, MissionJournalMalformed),
    MissionLeaseAcquisition (..),
    MissionLogKind,
    MissionRead (..),
    MissionRepository (..),
    MissionSealedArchive (..),
    MissionSessionId,
    MissionSnapshot (..),
    MissionSpecification (..),
    MissionStore (..),
    acquireMissionLease,
    missionLifecycleTag,
    missionSealFailureMessage,
    readMissionJournal,
    readMissionSnapshot,
    readMissionSpecification,
    releaseMissionLease,
    sealMissionLog,
  )
import Spec.Support.Env (ignoringIOException)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..), die)
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), withFile)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process
  ( CreateProcess (..),
    Pid,
    ProcessHandle,
    StdStream (..),
    createProcess,
    getPid,
    getProcessExitCode,
    proc,
    terminateProcess,
    waitForProcess,
  )

-- | What one probe is asked to do.
data MissionProbeAction
  = -- | Attempt the mission lease exactly once, and hold whatever it took
    -- until the parent says otherwise.
    MissionProbeLease
  | -- | Read the mission's specification, snapshot and whole journal, and
    -- report what came back.
    MissionProbeReadBack
  | -- | Seal one source file as the named session's log of the given kind.
    MissionProbeSealLog FilePath MissionSessionId MissionLogKind
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | One probe: what it is called, which store and mission it acts on, what it
-- does, and the gate it waits at.
--
-- The gate is a name rather than a probe, so two probes can share one — that
-- is the rendezvous — or hold separate ones, which is how an ordering is
-- staged.
data MissionProbe = MissionProbe
  { missionProbeName :: String,
    missionProbeStore :: FilePath,
    missionProbeRepository :: MissionRepository,
    missionProbeMission :: MissionId,
    missionProbeAction :: MissionProbeAction,
    missionProbeGate :: String
  }
  deriving stock (Eq, Show)

-- | What one lease attempt was told, flattened from
-- 'MissionLeaseAcquisition': a lease cannot cross a process boundary, and
-- these proofs are about which of the three answers came back.
data MissionProbeOutcome
  = MissionProbeAcquired
  | MissionProbeHeld Text
  | MissionProbeUnusable Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | What a fresh process found when it read a mission back.
--
-- Deliberately reduced to comparable text rather than carried back as the
-- records themselves: what these examples assert is that the durable files
-- said the same thing to a process that had never seen them, and reporting a
-- decoded record would be reporting this harness's own re-encoding of it.
data MissionProbeReadback = MissionProbeReadback
  { readbackRequest :: Maybe Text,
    readbackLifecycle :: Maybe Text,
    readbackEventKinds :: [Text],
    readbackDiagnostics :: [Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | What one seal attempt was told: the digest it committed, or why it was
-- refused.
data MissionProbeSealOutcome
  = MissionProbeSealed Text
  | MissionProbeSealRefused Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data MissionProbeReport
  = MissionProbeLeaseReport MissionProbeOutcome
  | MissionProbeReadbackReport MissionProbeReadback
  | MissionProbeSealReport MissionProbeSealOutcome
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | What one probe is to do, and where to leave each of its answers.
data MissionProbePlan = MissionProbePlan
  { probePlanStore :: FilePath,
    probePlanRepository :: MissionRepository,
    probePlanMission :: MissionId,
    probePlanAction :: MissionProbeAction,
    probePlanStartedPath :: FilePath,
    probePlanGatePath :: FilePath,
    probePlanReportPath :: FilePath,
    probePlanReleasePath :: FilePath,
    probePlanReleasedPath :: FilePath,
    probePlanRetirePath :: FilePath
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data MissionProbes = MissionProbes
  { missionProbesRoot :: FilePath,
    missionProbesRunning :: [RunningProbe]
  }

data RunningProbe = RunningProbe
  { runningProbe :: MissionProbe,
    runningHandle :: ProcessHandle,
    runningPid :: Pid,
    runningSettled :: IORef Bool
  }

-- | Set on a probe and nothing else: its presence is what tells @main@ this
-- process is a probe rather than the suite, which is also what stops a probe
-- from running a lane or starting probes of its own.
missionProbeVariable :: String
missionProbeVariable = "KANBAN_MISSION_PROBE"

missionProbeAttempts :: Int
missionProbeAttempts = 600

pollMicroseconds :: Int
pollMicroseconds = 100000

-- | The environment one probe is given.
--
-- Every @KANBAN_@ marker the parent may itself be carrying is dropped before
-- this probe's own is added, so exactly one branch of @main@ is reachable from
-- here — not this harness's other branch, not a lane, and not a probe of
-- another harness.
missionProbeEnvironment :: [(String, String)] -> FilePath -> [(String, String)]
missionProbeEnvironment inherited planPath =
  [entry | entry@(name, _) <- inherited, not ("KANBAN_" `isPrefixOf` name)]
    <> [(missionProbeVariable, planPath)]

-- * The parent

-- | Starts every probe, waits for all of them to reach the rendezvous, and
-- runs @action@ with them held there.
--
-- Nothing proceeds on its own: 'openMissionGate' is the only thing that lets a
-- probe act, so the body decides the ordering. On the way out every gate,
-- release and retire file is opened, so a probe the body left waiting finishes
-- under its own power rather than being killed for it, and every probe is then
-- required to have exited zero — a probe that crashed before it ever reached
-- the store would otherwise leave every assertion about it vacuously true.
withMissionProbes :: FilePath -> [MissionProbe] -> (MissionProbes -> IO result) -> IO result
withMissionProbes probeRoot probes action = do
  createDirectoryIfMissing True probeRoot
  self <- getExecutablePath
  inherited <- getEnvironment
  launched <- newIORef []
  bracket_ (pure ()) (readIORef launched >>= mapM_ reapHandle) $ do
    running <- forM probes (startProbe launched self inherited probeRoot)
    let probed = MissionProbes probeRoot running
    forM_ running $ \child ->
      awaitState probed child.runningProbe.missionProbeName "reach the rendezvous" (startedPath probeRoot child.runningProbe)
    result <- action probed
    forM_ running $ \child -> do
      touch (gatePath probeRoot child.runningProbe)
      touch (releasePath probeRoot child.runningProbe)
      touch (retirePath probeRoot child.runningProbe)
    forM_ running (requireCleanExit probed)
    pure result

-- | Releases every probe waiting at @gate@, together. One file for however
-- many probes named that gate, so \"released together\" is a single filesystem
-- event rather than a sequence the parent hopes is short enough to count as
-- one.
openMissionGate :: MissionProbes -> String -> IO ()
openMissionGate probes gate = touch (gateFile probes.missionProbesRoot gate)

-- | What the named probe reported.
--
-- Waits for the answer rather than reading whatever is there: the probe writes
-- its report by rename, so the file appears whole or not at all.
awaitMissionReport :: MissionProbes -> String -> IO MissionProbeReport
awaitMissionReport probes name = do
  child <- probeNamed probes name
  let path = reportPath probes.missionProbesRoot child.runningProbe
  awaitState probes name "report" path
  decoded <- eitherDecodeFileStrict' path :: IO (Either String MissionProbeReport)
  case decoded of
    Left message -> probeFailure probes name ("recorded a report that will not decode (" <> message <> ")")
    Right reported -> pure reported

-- | Tells a holder to give the lease up in the ordinary way, and returns once
-- it has — with the holder still running.
--
-- Still running is the point: a successor that acquired after the holder had
-- /exited/ would say nothing about 'releaseMissionLease', because this lease
-- is a directory and a dead process removes no directory. Here the holder is
-- alive and has released, so the successor's acquisition has one explanation.
releaseMissionHolder :: MissionProbes -> String -> IO ()
releaseMissionHolder probes name = do
  child <- probeNamed probes name
  touch (releasePath probes.missionProbesRoot child.runningProbe)
  awaitState probes name "release the lease" (releasedPath probes.missionProbesRoot child.runningProbe)

-- | Kills a holder outright, and returns once the kernel has taken it down.
--
-- @SIGKILL@ rather than @SIGTERM@ so nothing the probe could run on its way
-- out — a handler, a @bracket@, an exit action — can be what freed the lease.
-- The lease directory and its owner record are still there afterwards; what
-- changed is only that the identity the record names no longer matches a
-- process, which is exactly the evidence the successor's acquisition must turn
-- on.
killMissionHolder :: MissionProbes -> String -> IO ()
killMissionHolder probes name = do
  child <- probeNamed probes name
  signalProcess sigKILL child.runningPid
  code <- awaitExit probes child
  when (code == ExitSuccess) $
    probeFailure probes name "exited cleanly instead of being killed"

-- * The probe

-- | The probe half, reached from @main@ when 'missionProbeVariable' is set.
runMissionProbe :: FilePath -> IO ()
runMissionProbe planPath = do
  decoded <- eitherDecodeFileStrict' planPath :: IO (Either String MissionProbePlan)
  case decoded of
    Left message -> die ("the mission probe could not read its plan at " <> planPath <> ": " <> message)
    Right plan -> do
      touch plan.probePlanStartedPath
      awaitGate plan.probePlanGatePath
      case plan.probePlanAction of
        MissionProbeReadBack -> do
          readback <- readMissionBack plan
          report plan (MissionProbeReadbackReport readback)
        MissionProbeSealLog source session kind -> do
          let store = MissionStore plan.probePlanStore plan.probePlanRepository
          sealed <- sealMissionLog store plan.probePlanMission session kind source
          report plan . MissionProbeSealReport $ case sealed of
            Right entry -> MissionProbeSealed entry.missionSealedDigest
            Left failure -> MissionProbeSealRefused (missionSealFailureMessage failure)
        MissionProbeLease -> do
          acquisition <- acquireMissionLease plan.probePlanStore plan.probePlanMission
          case acquisition of
            MissionLeaseAcquired lease -> do
              report plan (MissionProbeLeaseReport MissionProbeAcquired)
              awaitGate plan.probePlanReleasePath
              releaseMissionLease lease
              touch plan.probePlanReleasedPath
              awaitGate plan.probePlanRetirePath
            MissionLeaseHeld reason -> report plan (MissionProbeLeaseReport (MissionProbeHeld reason))
            MissionLeaseUnusable detail -> report plan (MissionProbeLeaseReport (MissionProbeUnusable detail))

-- | Reads one mission's three durable parts with nothing carried over from the
-- process that wrote them.
readMissionBack :: MissionProbePlan -> IO MissionProbeReadback
readMissionBack plan = do
  let store = MissionStore plan.probePlanStore plan.probePlanRepository
  specificationResult <- readMissionSpecification store plan.probePlanMission
  snapshotResult <- readMissionSnapshot store plan.probePlanMission
  journalResult <- readMissionJournal store plan.probePlanMission 0
  let (kinds, journalDiagnostics) = case journalResult of
        Left message -> ([], ["journal: " <> message])
        Right (records, _) ->
          ( [event.missionEventKind | MissionJournalEvent event <- records],
            [message | MissionJournalMalformed message <- records]
          )
  pure
    MissionProbeReadback
      { readbackRequest = present (fmap missionSpecificationRequest specificationResult),
        readbackLifecycle = present (fmap (missionLifecycleTag . missionSnapshotLifecycle) snapshotResult),
        readbackEventKinds = kinds,
        readbackDiagnostics =
          diagnostics "specification" specificationResult
            <> diagnostics "snapshot" snapshotResult
            <> journalDiagnostics
      }
  where
    present result = case result of
      MissionPresent value -> Just value
      _ -> Nothing
    diagnostics label result = case result of
      MissionPresent _ -> []
      MissionAbsent -> [Text.pack label <> ": absent"]
      MissionRefused message -> [Text.pack label <> ": refused: " <> message]
      MissionUnreadable message -> [Text.pack label <> ": unreadable: " <> message]

report :: MissionProbePlan -> MissionProbeReport -> IO ()
report plan value = do
  let partial = plan.probePlanReportPath <> ".partial"
  LazyByteString.writeFile partial (encode value)
  renameFile partial plan.probePlanReportPath

-- | Waits at a gate, and gives up loudly rather than forever. The parent opens
-- every gate on its way out, so this bound is only reached when the parent
-- itself has gone.
awaitGate :: FilePath -> IO ()
awaitGate path = go missionProbeAttempts
  where
    go remaining = do
      opened <- doesFileExist path
      unless opened $
        if remaining <= (0 :: Int)
          then die ("the mission probe waited for " <> path <> " and it never opened")
          else threadDelay pollMicroseconds >> go (remaining - 1)

-- * Starting, waiting and reaping

startProbe :: IORef [ProcessHandle] -> FilePath -> [(String, String)] -> FilePath -> MissionProbe -> IO RunningProbe
startProbe launched self inherited probeRoot probe = do
  planPath <- writePlan probeRoot probe
  handle <-
    withFile (diagnosticsPath probeRoot probe) WriteMode $ \diagnostics -> do
      (_, _, _, child) <-
        createProcess
          (proc self [])
            { env = Just (missionProbeEnvironment inherited planPath),
              std_out = UseHandle diagnostics,
              std_err = UseHandle diagnostics
            }
      pure child
  modifyIORef' launched (handle :)
  identifier <- getPid handle
  case identifier of
    Nothing -> do
      output <- readDiagnostics (diagnosticsPath probeRoot probe)
      fail
        ( "the mission probe "
            <> probe.missionProbeName
            <> " exited before it could be identified (its output: "
            <> Text.unpack output
            <> ")"
        )
    Just pid -> RunningProbe probe handle pid <$> newIORef False

writePlan :: FilePath -> MissionProbe -> IO FilePath
writePlan probeRoot probe = do
  let planPath = probeRoot </> (probe.missionProbeName <> "-plan.json")
  LazyByteString.writeFile
    planPath
    ( encode
        ( MissionProbePlan
            probe.missionProbeStore
            probe.missionProbeRepository
            probe.missionProbeMission
            probe.missionProbeAction
            (startedPath probeRoot probe)
            (gatePath probeRoot probe)
            (reportPath probeRoot probe)
            (releasePath probeRoot probe)
            (releasedPath probeRoot probe)
            (retirePath probeRoot probe)
        )
    )
  pure planPath

awaitState :: MissionProbes -> String -> String -> FilePath -> IO ()
awaitState probes name state path = go missionProbeAttempts
  where
    go remaining = do
      reached <- doesFileExist path
      unless reached $
        if remaining <= (0 :: Int)
          then probeFailure probes name ("did not " <> state)
          else threadDelay pollMicroseconds >> go (remaining - 1)

requireCleanExit :: MissionProbes -> RunningProbe -> IO ()
requireCleanExit probes child = do
  settled <- readIORef child.runningSettled
  unless settled $ do
    code <- awaitExit probes child
    unless (code == ExitSuccess) $
      probeFailure probes child.runningProbe.missionProbeName ("exited with " <> show code)

awaitExit :: MissionProbes -> RunningProbe -> IO ExitCode
awaitExit probes child = go missionProbeAttempts
  where
    go remaining = do
      finished <- getProcessExitCode child.runningHandle
      case finished of
        Just code -> writeIORef child.runningSettled True >> pure code
        Nothing
          | remaining <= (0 :: Int) -> probeFailure probes child.runningProbe.missionProbeName "did not exit"
          | otherwise -> threadDelay pollMicroseconds >> go (remaining - 1)

reapHandle :: ProcessHandle -> IO ()
reapHandle handle = do
  ignoringIOException (terminateProcess handle)
  ignoringIOException (() <$ waitForProcess handle)

-- | The one way this harness fails. Every probe is terminated and reaped
-- before the message is raised, so a failing example leaves none of its own
-- behind still holding a lease its successor will contend for.
probeFailure :: MissionProbes -> String -> String -> IO result
probeFailure probes name state = do
  output <- case find ((== name) . missionProbeName . runningProbe) probes.missionProbesRunning of
    Nothing -> pure "no output"
    Just child -> readDiagnostics (diagnosticsPath probes.missionProbesRoot child.runningProbe)
  mapM_ (reapHandle . runningHandle) probes.missionProbesRunning
  fail ("the mission probe " <> name <> " " <> state <> " (its output: " <> Text.unpack output <> ")")

probeNamed :: MissionProbes -> String -> IO RunningProbe
probeNamed probes name =
  case find ((== name) . missionProbeName . runningProbe) probes.missionProbesRunning of
    Just child -> pure child
    Nothing ->
      fail
        ( "there is no mission probe named "
            <> name
            <> " (the probes are "
            <> unwords (map (missionProbeName . runningProbe) probes.missionProbesRunning)
            <> ")"
        )

touch :: FilePath -> IO ()
touch path = LazyByteString.writeFile path LazyByteString.empty

startedPath, reportPath, releasePath, releasedPath, retirePath, diagnosticsPath :: FilePath -> MissionProbe -> FilePath
startedPath probeRoot probe = probeRoot </> (probe.missionProbeName <> "-started")
reportPath probeRoot probe = probeRoot </> (probe.missionProbeName <> "-report.json")
releasePath probeRoot probe = probeRoot </> (probe.missionProbeName <> "-release")
releasedPath probeRoot probe = probeRoot </> (probe.missionProbeName <> "-released")
retirePath probeRoot probe = probeRoot </> (probe.missionProbeName <> "-retire")
diagnosticsPath probeRoot probe = probeRoot </> (probe.missionProbeName <> "-diagnostics.log")

gatePath :: FilePath -> MissionProbe -> FilePath
gatePath probeRoot probe = gateFile probeRoot probe.missionProbeGate

gateFile :: FilePath -> String -> FilePath
gateFile probeRoot gate = probeRoot </> ("gate-" <> gate)

readDiagnostics :: FilePath -> IO Text
readDiagnostics path = do
  present <- doesFileExist path
  if not present
    then pure "no output"
    else Text.strip . TextEncoding.decodeUtf8With lenientDecode <$> ByteString.readFile path
