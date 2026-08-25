{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Independent OS processes contending for one repository's lease.
--
-- The lease "Kanban.Repository.Lease" builds is a POSIX record lock, and a
-- POSIX record lock belongs to the /process/. A second request from inside the
-- process that already holds one succeeds — it replaces the first rather than
-- conflicting with it — so a fixture built from threads would watch every
-- contention it staged quietly succeed and prove the opposite of what it
-- claimed. Nothing about this authority can be established without two
-- processes.
--
-- So each probe is the test binary run again, taking the branch in @main@ that
-- leads to 'runLeaseProbe' instead of to hspec. The shape is
-- "Spec.Support.UsageWriters"'s, which stages the same kind of overlap for the
-- usage cache: a marker in the child's environment, answers carried back
-- through files, and every assertion made by the parent. What is added here is
-- what a lease needs and a commit does not — a child that /keeps/ what it took
-- until it is told to let go, gates the parent opens one at a time so an
-- ordering is staged rather than hoped for, and a holder the parent can kill
-- outright.
--
-- A probe passes through five states, and each is a file:
--
--   [@started@] it is running and is at its gate. Every probe is waited for
--     here before the body runs, so the rendezvous is a state the parent
--     established rather than a delay it guessed at.
--   [@gate@] opened by the parent. The probe attempts the lease exactly once
--     and records what it was told.
--   [@release@] opened by the parent. A probe that /took/ the lease has been
--     holding it ever since it reported, and now gives it up.
--   [@released@] written by the probe. It has called
--     'Kanban.Repository.Lease.releaseRepositoryLease' and is still running,
--     which is the only condition under which a successor's acquisition proves
--     anything about /release/ rather than about process exit.
--   [@retire@] opened by the parent. The probe exits.
--
-- Holding until @release@ is what makes the contention assertion deterministic
-- rather than a race. Both probes at one gate attempt once and neither lets go
-- on its own, so whichever reaches @F_SETLK@ first holds the lease for the
-- whole of the other's attempt: exactly one can be told it acquired, whatever
-- order the scheduler picks.
--
-- Every way of failing here terminates and reaps every probe before it reports
-- (see 'probeFailure'), and every message names the probe and the state it did
-- not reach. A harness that let a child die quietly would turn each of these
-- proofs into a test that passes because nothing happened.
module Spec.Support.LeaseProbes
  ( LeaseProbe (..),
    LeaseProbeOutcome (..),
    LeaseProbes,
    awaitLeaseOutcome,
    killLeaseHolder,
    leaseHolderPid,
    leaseProbeEnvironment,
    leaseProbeVariable,
    openLeaseGate,
    releaseLeaseHolder,
    runLeaseProbe,
    withLeaseProbes,
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
import Kanban.Domain (Repository)
import Kanban.Repository.Lease
  ( LeaseAcquisition (..),
    acquireRepositoryLease,
    releaseRepositoryLease,
  )
import Spec.Support.Env (ignoringIOException)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.Environment (getEnvironment, getExecutablePath, setEnv)
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

-- | One probe: what it is called, whose lease it goes for, the
-- @XDG_CACHE_HOME@ it resolves that lease under, and the gate it waits at.
--
-- The cache root belongs to the probe rather than to the run because two of
-- the proofs turn on it: one repository under two roots must not contend, and
-- one root holding two repositories must not either. The gate is a name rather
-- than a probe, so two probes can share one — that is the rendezvous — or hold
-- separate ones, which is how an ordering is staged.
data LeaseProbe = LeaseProbe
  { leaseProbeName :: String,
    leaseProbeRepository :: Repository,
    leaseProbeCacheRoot :: FilePath,
    leaseProbeGate :: String
  }
  deriving stock (Eq, Show)

-- | What one probe's single attempt was told, carried back through a file
-- because the probe is a process rather than a thread.
--
-- The three cases are 'LeaseAcquisition''s, flattened: a lease cannot cross a
-- process boundary, and what these proofs assert about is which of the three
-- answers came back, never the descriptor behind one of them.
data LeaseProbeOutcome
  = ProbeAcquired
  | ProbeHeld
  | ProbeUnusable Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | What one probe is to do, and where to leave each of its answers.
data LeaseProbePlan = LeaseProbePlan
  { probePlanRepository :: Repository,
    probePlanCacheRoot :: FilePath,
    probePlanStartedPath :: FilePath,
    probePlanGatePath :: FilePath,
    probePlanOutcomePath :: FilePath,
    probePlanReleasePath :: FilePath,
    probePlanReleasedPath :: FilePath,
    probePlanRetirePath :: FilePath
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The parent's handle on a run of probes.
data LeaseProbes = LeaseProbes
  { leaseProbesRoot :: FilePath,
    leaseProbesRunning :: [RunningProbe]
  }

data RunningProbe = RunningProbe
  { runningProbe :: LeaseProbe,
    runningHandle :: ProcessHandle,
    runningPid :: Pid,
    runningSettled :: IORef Bool
  }

-- | Set on a probe and nothing else: its presence is what tells @main@ this
-- process is a probe rather than the suite, which is also what stops a probe
-- from running a lane or starting probes of its own. It carries the path to
-- that probe's plan.
leaseProbeVariable :: String
leaseProbeVariable = "KANBAN_LEASE_PROBE"

-- | How long a wait here lasts, in units of the 100ms it polls at. Generous,
-- because a process start on a loaded machine is slow; bounded, because a
-- probe that died quietly must fail the suite rather than hang it.
leaseProbeAttempts :: Int
leaseProbeAttempts = 600

pollMicroseconds :: Int
pollMicroseconds = 100000

-- | The environment one probe is given.
--
-- Every @KANBAN_@ marker the parent may itself be carrying is dropped before
-- this probe's own is added, so exactly one branch of @main@ is reachable from
-- here. Dropping the whole family rather than this one variable is what keeps
-- a probe out of the lane runner ('Spec.Support.Lanes.laneVariable'), out of
-- 'Spec.Support.UsageWriters.runUsageWriter', and out of the business of
-- starting probes of its own.
leaseProbeEnvironment :: [(String, String)] -> FilePath -> [(String, String)]
leaseProbeEnvironment inherited planPath =
  [entry | entry@(name, _) <- inherited, not ("KANBAN_" `isPrefixOf` name)]
    <> [(leaseProbeVariable, planPath)]

-- * The parent

-- | Starts every probe, waits for all of them to reach the rendezvous, and
-- runs @action@ with them held there.
--
-- Nothing is released on its own: 'openLeaseGate' is the only thing that lets
-- a probe attempt the lease, so the body decides the ordering. On the way out
-- every gate, release and retire file is opened, so a probe the body left
-- waiting finishes under its own power rather than being killed for it, and
-- every probe is then required to have exited zero — a probe that crashed
-- before it ever reached the lock would otherwise leave every assertion about
-- it vacuously true.
withLeaseProbes :: FilePath -> [LeaseProbe] -> (LeaseProbes -> IO result) -> IO result
withLeaseProbes probeRoot probes action = do
  createDirectoryIfMissing True probeRoot
  self <- getExecutablePath
  inherited <- getEnvironment
  -- Every probe is registered the instant it exists, and the cleanup reads
  -- that register rather than the list the starts return. A start that failed
  -- part way through the list would otherwise leave the probes before it with
  -- nobody to reap them: the value that would have named them is the one the
  -- exception replaced.
  launched <- newIORef []
  bracket_ (pure ()) (readIORef launched >>= mapM_ reapHandle) $ do
    running <- forM probes (startProbe launched self inherited probeRoot)
    let probed = LeaseProbes probeRoot running
    forM_ running $ \child ->
      awaitState probed child.runningProbe.leaseProbeName "reach the rendezvous" (startedPath probeRoot child.runningProbe)
    result <- action probed
    forM_ running $ \child -> do
      touch (gatePath probeRoot child.runningProbe)
      touch (releasePath probeRoot child.runningProbe)
      touch (retirePath probeRoot child.runningProbe)
    forM_ running (requireCleanExit probed)
    pure result

-- | Releases every probe waiting at @gate@, together.
--
-- One file for however many probes named that gate, so \"released together\"
-- is a single filesystem event rather than a sequence the parent hopes is
-- short enough to count as one.
openLeaseGate :: LeaseProbes -> String -> IO ()
openLeaseGate probes gate = touch (gateFile probes.leaseProbesRoot gate)

-- | What the named probe's one attempt was told.
--
-- Waits for the answer rather than reading whatever is there. The probe writes
-- its outcome by rename, so the file appears whole or not at all, and a read
-- that found nothing would be a race rather than a verdict.
awaitLeaseOutcome :: LeaseProbes -> String -> IO LeaseProbeOutcome
awaitLeaseOutcome probes name = do
  child <- probeNamed probes name
  let path = outcomePath probes.leaseProbesRoot child.runningProbe
  awaitState probes name "report an outcome" path
  decoded <- eitherDecodeFileStrict' path :: IO (Either String LeaseProbeOutcome)
  case decoded of
    Left message -> probeFailure probes name ("recorded an outcome that will not decode (" <> message <> ")")
    Right outcome -> pure outcome

-- | Tells a holder to give the lease up in the ordinary way, and returns once
-- it has — with the holder still running.
--
-- Still running is the whole point. The kernel frees a dead process's locks
-- whatever the process did on its way out, so a successor that acquired after
-- the holder had /exited/ would say nothing about
-- 'Kanban.Repository.Lease.releaseRepositoryLease': a release that did nothing
-- at all would pass that test. Here the holder is alive and has released, so
-- the successor's acquisition has only one explanation.
releaseLeaseHolder :: LeaseProbes -> String -> IO ()
releaseLeaseHolder probes name = do
  child <- probeNamed probes name
  touch (releasePath probes.leaseProbesRoot child.runningProbe)
  awaitState probes name "release the lease" (releasedPath probes.leaseProbesRoot child.runningProbe)

-- | The operating-system PID of one running probe.
--
-- Needed by exactly one kind of assertion and worth the export for it: a
-- refusal that names a holder can only be checked against the holder's own
-- PID, and comparing it with anything this harness derived a second way would
-- be checking the derivation rather than the refusal.
leaseHolderPid :: LeaseProbes -> String -> IO Pid
leaseHolderPid probes name = runningPid <$> probeNamed probes name

-- | Kills a holder outright, and returns once the kernel has taken it down.
--
-- @SIGKILL@ rather than @SIGTERM@ so that nothing the probe could run on its
-- way out — a handler, a @bracket@, an exit action — can be what freed the
-- lease. Whatever a later probe is then told is the kernel's doing, and
-- Kanban's own code has had no say in it. Waiting for the process to be reaped
-- before returning is what makes that release an established fact rather than
-- something the next assertion races.
killLeaseHolder :: LeaseProbes -> String -> IO ()
killLeaseHolder probes name = do
  child <- probeNamed probes name
  signalProcess sigKILL child.runningPid
  code <- awaitExit probes child
  when (code == ExitSuccess) $
    probeFailure probes name "exited cleanly instead of being killed"

-- * The probe

-- | The probe half, reached from @main@ when 'leaseProbeVariable' is set.
--
-- One attempt and one attempt only. A probe that retried would turn every
-- refusal this harness stages into a timing question, and a probe that let go
-- on its own would let both sides of a contention be told they acquired.
runLeaseProbe :: FilePath -> IO ()
runLeaseProbe planPath = do
  decoded <- eitherDecodeFileStrict' planPath :: IO (Either String LeaseProbePlan)
  case decoded of
    Left message -> die ("the lease probe could not read its plan at " <> planPath <> ": " <> message)
    Right plan -> do
      -- The probe resolves its own lease path, so the root under test is the
      -- plan's rather than whichever one the parent happened to be pinned at.
      setEnv "XDG_CACHE_HOME" plan.probePlanCacheRoot
      touch plan.probePlanStartedPath
      awaitGate plan.probePlanGatePath
      acquisition <- acquireRepositoryLease plan.probePlanRepository
      case acquisition of
        LeaseAcquired lease -> do
          report plan ProbeAcquired
          awaitGate plan.probePlanReleasePath
          releaseRepositoryLease lease
          touch plan.probePlanReleasedPath
          awaitGate plan.probePlanRetirePath
        LeaseHeld _ -> report plan ProbeHeld
        LeaseUnusable _ detail -> report plan (ProbeUnusable detail)

-- | Records the answer where the parent can read it, by rename so that a
-- parent polling for the file never sees half of one.
report :: LeaseProbePlan -> LeaseProbeOutcome -> IO ()
report plan outcome = do
  let partial = plan.probePlanOutcomePath <> ".partial"
  LazyByteString.writeFile partial (encode outcome)
  renameFile partial plan.probePlanOutcomePath

-- | Waits at a gate, and gives up loudly rather than forever.
--
-- The parent opens every gate on its way out, so this bound is only ever
-- reached when the parent itself has gone; exiting non-zero there leaves a
-- diagnostic behind instead of a process nobody will collect.
awaitGate :: FilePath -> IO ()
awaitGate path = go leaseProbeAttempts
  where
    go remaining = do
      opened <- doesFileExist path
      unless opened $
        if remaining <= (0 :: Int)
          then die ("the lease probe waited for " <> path <> " and it never opened")
          else threadDelay pollMicroseconds >> go (remaining - 1)

-- * Starting, waiting and reaping

startProbe :: IORef [ProcessHandle] -> FilePath -> [(String, String)] -> FilePath -> LeaseProbe -> IO RunningProbe
startProbe launched self inherited probeRoot probe = do
  planPath <- writePlan probeRoot probe
  handle <-
    withFile (diagnosticsPath probeRoot probe) WriteMode $ \diagnostics -> do
      (_, _, _, child) <-
        createProcess
          (proc self [])
            { env = Just (leaseProbeEnvironment inherited planPath),
              std_out = UseHandle diagnostics,
              std_err = UseHandle diagnostics
            }
      pure child
  modifyIORef' launched (handle :)
  identifier <- getPid handle
  case identifier of
    -- Only reachable when the probe is already gone, which means it died
    -- before doing anything this harness is about. Reaping is left to the
    -- cleanup, so that the probes started before this one are reaped with it.
    Nothing -> do
      diagnostics <- readDiagnostics (diagnosticsPath probeRoot probe)
      fail
        ( "the lease probe "
            <> probe.leaseProbeName
            <> " exited before it could be identified (its output: "
            <> Text.unpack diagnostics
            <> ")"
        )
    Just pid -> RunningProbe probe handle pid <$> newIORef False

writePlan :: FilePath -> LeaseProbe -> IO FilePath
writePlan probeRoot probe = do
  let planPath = probeRoot </> (probe.leaseProbeName <> "-plan.json")
  LazyByteString.writeFile
    planPath
    ( encode
        ( LeaseProbePlan
            probe.leaseProbeRepository
            probe.leaseProbeCacheRoot
            (startedPath probeRoot probe)
            (gatePath probeRoot probe)
            (outcomePath probeRoot probe)
            (releasePath probeRoot probe)
            (releasedPath probeRoot probe)
            (retirePath probeRoot probe)
        )
    )
  pure planPath

-- | Waits for one probe to reach one state, failing in this harness's own
-- vocabulary when it does not.
awaitState :: LeaseProbes -> String -> String -> FilePath -> IO ()
awaitState probes name state path = go leaseProbeAttempts
  where
    go remaining = do
      reached <- doesFileExist path
      unless reached $
        if remaining <= (0 :: Int)
          then probeFailure probes name ("did not " <> state)
          else threadDelay pollMicroseconds >> go (remaining - 1)

requireCleanExit :: LeaseProbes -> RunningProbe -> IO ()
requireCleanExit probes child = do
  settled <- readIORef child.runningSettled
  unless settled $ do
    code <- awaitExit probes child
    unless (code == ExitSuccess) $
      probeFailure probes child.runningProbe.leaseProbeName ("exited with " <> show code)

-- | Waits for one probe to be gone, and gives up loudly rather than forever.
--
-- Bounded for the same reason every other wait here is: a probe that wedged
-- somewhere this harness did not anticipate must fail the example rather than
-- hang the suite behind an unbounded 'waitForProcess'. Recording the probe as
-- settled is what keeps the run's epilogue from waiting on a probe an example
-- already accounted for.
awaitExit :: LeaseProbes -> RunningProbe -> IO ExitCode
awaitExit probes child = go leaseProbeAttempts
  where
    go remaining = do
      finished <- getProcessExitCode child.runningHandle
      case finished of
        Just code -> writeIORef child.runningSettled True >> pure code
        Nothing
          | remaining <= (0 :: Int) -> probeFailure probes child.runningProbe.leaseProbeName "did not exit"
          | otherwise -> threadDelay pollMicroseconds >> go (remaining - 1)

-- | Terminates and reaps a probe whatever state it is in.
--
-- @SIGTERM@ is enough: a probe installs no handler, and one still at a gate is
-- sitting in a poll loop. A handle that has already been waited for is a
-- closed handle, which both of these accept, so this is safe on the way out of
-- a run whose body finished cleanly.
reapHandle :: ProcessHandle -> IO ()
reapHandle handle = do
  ignoringIOException (terminateProcess handle)
  ignoringIOException (() <$ waitForProcess handle)

-- | The one way this harness fails.
--
-- Every probe is terminated and reaped before the message is raised, so a
-- failing example leaves none of its own behind to be found by a later
-- example's census or to keep holding a lease its successor will contend for.
-- The probe's own output is read first, while the file it wrote is still the
-- reason rather than the remains.
probeFailure :: LeaseProbes -> String -> String -> IO result
probeFailure probes name state = do
  diagnostics <- case find ((== name) . leaseProbeName . runningProbe) probes.leaseProbesRunning of
    Nothing -> pure "no output"
    Just child -> readDiagnostics (diagnosticsPath probes.leaseProbesRoot child.runningProbe)
  mapM_ (reapHandle . runningHandle) probes.leaseProbesRunning
  fail ("the lease probe " <> name <> " " <> state <> " (its output: " <> Text.unpack diagnostics <> ")")

probeNamed :: LeaseProbes -> String -> IO RunningProbe
probeNamed probes name =
  case find ((== name) . leaseProbeName . runningProbe) probes.leaseProbesRunning of
    Just child -> pure child
    Nothing ->
      fail
        ( "there is no lease probe named "
            <> name
            <> " (the probes are "
            <> unwords (map (leaseProbeName . runningProbe) probes.leaseProbesRunning)
            <> ")"
        )

touch :: FilePath -> IO ()
touch path = LazyByteString.writeFile path LazyByteString.empty

startedPath, outcomePath, releasePath, releasedPath, retirePath, diagnosticsPath :: FilePath -> LeaseProbe -> FilePath
startedPath probeRoot probe = probeRoot </> (probe.leaseProbeName <> "-started")
outcomePath probeRoot probe = probeRoot </> (probe.leaseProbeName <> "-outcome.json")
releasePath probeRoot probe = probeRoot </> (probe.leaseProbeName <> "-release")
releasedPath probeRoot probe = probeRoot </> (probe.leaseProbeName <> "-released")
retirePath probeRoot probe = probeRoot </> (probe.leaseProbeName <> "-retire")
diagnosticsPath probeRoot probe = probeRoot </> (probe.leaseProbeName <> "-diagnostics.log")

-- | The gate a probe waits at, named by the gate rather than by the probe, so
-- that probes sharing a gate share one file.
gatePath :: FilePath -> LeaseProbe -> FilePath
gatePath probeRoot probe = gateFile probeRoot probe.leaseProbeGate

gateFile :: FilePath -> String -> FilePath
gateFile probeRoot gate = probeRoot </> ("gate-" <> gate)

-- | A probe's stdout and stderr, decoded here rather than through 'readFile',
-- so a diagnostic the parent's locale cannot decode still reaches the failure
-- message it belongs in.
readDiagnostics :: FilePath -> IO Text
readDiagnostics path = do
  present <- doesFileExist path
  if not present
    then pure "no output"
    else Text.strip . TextEncoding.decodeUtf8With lenientDecode <$> ByteString.readFile path
