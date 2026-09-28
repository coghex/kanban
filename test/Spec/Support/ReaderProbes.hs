{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Independent OS processes reading one repository through the durable @gh@
-- record, each holding the one record lock its kind of process holds for its
-- whole life (issue #742).
--
-- Two claims need a process rather than a thread. Three readers together is a
-- claim about processes that share nothing but the files under the cache
-- root: threads of one suite process would share its pid, so every entry any
-- of them wrote would read as this process's own, and the writer
-- classification the claim rests on would never be exercised. And a held-back
-- refusal outliving the read that earned it is a claim about one reader
-- process's lifetime: the lock that carries it is minted where that process
-- starts, so the probe has to be the process.
--
-- So each reader is the test binary run again, taking the branch in @main@
-- that leads to 'runReaderProbe' instead of to hspec. It reads through the
-- production entry points -- a refresh coordinator's open job, the mission
-- runner's board read and target observation, and a worker's precondition
-- reread, each through the guard-taking form its lock-taking entry point runs
-- -- under one record lock minted at the
-- top of the probe, exactly where the production process mints its own. The
-- shape is "Spec.Support.RecordWriters"': a marker in the child's environment,
-- a plan and answers carried through files, every wait bounded, and every
-- assertion made by the parent.
module Spec.Support.ReaderProbes
  ( ReaderRole (..),
    ReadKind (..),
    ReaderStep (..),
    ReaderOutcome (..),
    ReaderProbe (..),
    readerProbeVariable,
    runReaderProbe,
    startReaderProbe,
    awaitReaderOutcome,
    awaitProbeFile,
    reapReaderProbe,
    readerFakeGh,
    readerIssueNumber,
    readerExpectedTarget,
    countGhMarkers,
  )
where

import Brick.BChan (newBChan)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Control.Monad (forM, unless)
import Data.Aeson (FromJSON, ToJSON, eitherDecodeFileStrict', encode)
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Either (isRight)
import Data.List (isPrefixOf)
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import GHC.Generics (Generic)
import Kanban.Cache (GhGroupRecordLoad (..), loadGhGroupRecord)
import Kanban.Config (ResolvedConfig (..), TimeoutsConfig (..), defaultTimeoutsConfig)
import Kanban.Domain (ItemId (..), Repository, TargetPrecondition (..))
import Kanban.GitHub (GhCleanupFailure (..), GhRecordLock, RefreshJob (..), ghFetchCleanupFailure, newGhFetchGuard, newGhRecordLock, newHistoryTraversal, newRefreshCoordinator, requestRefreshJob, shutdownRefreshCoordinator)
import Kanban.Mission (MissionTarget (..), MissionTargetKind (..), missionBoardReadUnder, missionTargetObservationUnder)
import Kanban.UI.Refresh (boardRefreshRunner)
import Kanban.UI.Types (BoardRefreshOutcome (..))
import Kanban.Worker (WorkerId (..), WorkerSpec (..), preconditionStillHoldsUnder)
import Spec.Support.Board (termIgnoringGh, withForcedCleanup)
import Spec.Support.Env (ignoringIOException)
import Spec.Support.Fixtures (testResolvedConfig)
import Spec.Support.Json (githubIndependentPage)
import Spec.Support.Process (workerFixtureSpec)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, renameFile)
import System.Environment (getEnvironment, getExecutablePath, setEnv)
import System.Exit (ExitCode (..), die)
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), withFile)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (..),
    createProcess,
    getProcessExitCode,
    proc,
    terminateProcess,
    waitForProcess,
  )

-- | What one probe process is.
data ReaderRole
  = -- | A dashboard's open refresh: one job of a refresh coordinator that owns
    -- the process's record lock.
    DashboardReader
  | -- | A mission runner's board read.
    RunnerBoardReader
  | -- | A persistent worker's precondition reread.
    WorkerReader
  | -- | One process that takes a first read under a store that can neither
    -- record its @gh@ nor confirm it gone, then the given reads with every
    -- failure restored, then the first of them again under a lock nobody has
    -- read through. The first read is named by the first role.
    LatchSequence ReadKind [ReadKind]
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | One of the reads a non-dashboard reader process takes.
data ReadKind
  = -- | 'missionBoardRead'.
    ReadBoard
  | -- | 'missionTargetObservation'.
    ReadTarget
  | -- | 'preconditionStillHolds', as the issue-review host takes it for each
    -- child it adopts.
    ReadPrecondition
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | What one read reported, and how many @gh@ processes it started.
--
-- The count is taken from the fake @gh@'s own markers, so a read refused
-- before it spawned anything shows as zero rather than as a read that
-- happened to fail.
data ReaderStep = ReaderStep
  { readerStepLabel :: Text,
    readerStepSucceeded :: Bool,
    readerStepDetail :: Text,
    readerStepSpawned :: Int,
    -- | The read's own guard verdict once the read was over, spelled as the
    -- 'Kanban.GitHub.GhCleanupGuard' it carries, or 'Nothing' for a read that
    -- left nothing held back.
    readerStepGuard :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Everything one probe reported, carried back through a file.
data ReaderOutcome = ReaderOutcome
  { readerOutcomeSteps :: [ReaderStep],
    -- | Whether the durable record held nothing once every read was over: a
    -- refusal with nothing on disk is one only this process's memory made.
    readerOutcomeRecordEmpty :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ReaderPlan = ReaderPlan
  { readerPlanRole :: ReaderRole,
    readerPlanRepository :: Repository,
    readerPlanCacheRoot :: FilePath,
    readerPlanConfigRoot :: FilePath,
    readerPlanMarkerDirectory :: FilePath,
    -- | Where a 'LatchSequence' stages its first read's broken store.
    readerPlanForcedRoot :: FilePath,
    readerPlanOutcomePath :: FilePath
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A started probe: the process, and where its answers land.
data ReaderProbe = ReaderProbe
  { readerProbeName :: String,
    readerProbeHandle :: ProcessHandle,
    readerProbeOutcomePath :: FilePath,
    readerProbeDiagnosticsPath :: FilePath
  }

-- | Set on a child and nothing else: its presence is what tells @main@ this
-- process is a reader probe rather than the suite. It carries the path to that
-- child's plan.
readerProbeVariable :: String
readerProbeVariable = "KANBAN_GH_READER_PROBE"

-- | How long any wait here lasts, in units of the 100ms it polls at.
-- Generous, because a process start on a loaded machine is slow; bounded,
-- because a probe that died quietly must fail the suite rather than hang it.
probeAttempts :: Int
probeAttempts = 900

pollMicroseconds :: Int
pollMicroseconds = 100000

-- * The parent

-- | Starts one probe as its own process.
--
-- @pathPrefix@ goes in front of the child's @PATH@, which is how a fake @gh@
-- -- and for one example a fake @ps@ -- reaches it; @extra@ is added to its
-- environment as given. The cache and configuration roots are the plan's, so
-- the child reads the record the parent names rather than whatever the
-- parent happens to be pinned at.
startReaderProbe :: FilePath -> String -> ReaderRole -> Repository -> FilePath -> FilePath -> FilePath -> [FilePath] -> [(String, String)] -> IO ReaderProbe
startReaderProbe probeRoot name role repository cacheRoot configRoot markerDirectory pathPrefix extra = do
  createDirectoryIfMissing True probeRoot
  createDirectoryIfMissing True markerDirectory
  self <- getExecutablePath
  inherited <- getEnvironment
  let planPath = probeRoot </> (name <> "-plan.json")
      outcomePath = probeRoot </> (name <> "-outcome.json")
      diagnosticsPath = probeRoot </> (name <> "-diagnostics.log")
      plan =
        ReaderPlan
          { readerPlanRole = role,
            readerPlanRepository = repository,
            readerPlanCacheRoot = cacheRoot,
            readerPlanConfigRoot = configRoot,
            readerPlanMarkerDirectory = markerDirectory,
            readerPlanForcedRoot = probeRoot </> (name <> "-forced"),
            readerPlanOutcomePath = outcomePath
          }
  LazyByteString.writeFile planPath (encode plan)
  -- Every probe marker the parent may itself be carrying is dropped, so a
  -- child cannot re-enter a branch of @main@ this fixture did not choose.
  let carried = filter (\(key, _) -> not ("KANBAN_" `isPrefixOf` key) && key /= "PATH") inherited
      originalPath = maybe "" id (lookup "PATH" inherited)
      path = foldr (\directory rest -> directory <> ":" <> rest) originalPath pathPrefix
  handle <- withFile diagnosticsPath WriteMode $ \diagnostics -> do
    (_, _, _, child) <-
      createProcess
        (proc self [])
          { env = Just (carried <> extra <> [("PATH", path), (readerProbeVariable, planPath)]),
            std_out = UseHandle diagnostics,
            std_err = UseHandle diagnostics
          }
    pure child
  pure (ReaderProbe name handle outcomePath diagnosticsPath)

-- | Waits for a probe to exit successfully and returns what it reported.
awaitReaderOutcome :: ReaderProbe -> IO ReaderOutcome
awaitReaderOutcome probe = go probeAttempts
  where
    go remaining = do
      finished <- getProcessExitCode probe.readerProbeHandle
      case finished of
        Just ExitSuccess -> do
          decoded <- eitherDecodeFileStrict' probe.readerProbeOutcomePath
          either (\message -> probeFailure probe ("recorded no outcome (" <> message <> ")")) pure decoded
        Just code -> probeFailure probe ("exited with " <> show code)
        Nothing
          | remaining <= (0 :: Int) -> probeFailure probe "did not exit"
          | otherwise -> threadDelay pollMicroseconds >> go (remaining - 1)

-- | Waits for a file a probe (or a @gh@ it started) creates, failing with the
-- probe's own output if the probe exits first or the wait runs out.
awaitProbeFile :: ReaderProbe -> String -> FilePath -> IO ()
awaitProbeFile probe state path = go probeAttempts
  where
    go remaining = do
      reached <- doesFileExist path
      unless reached $ do
        exited <- getProcessExitCode probe.readerProbeHandle
        case exited of
          Just code -> probeFailure probe ("exited with " <> show code <> " before it could " <> state)
          Nothing
            | remaining <= (0 :: Int) -> probeFailure probe ("did not " <> state)
            | otherwise -> threadDelay pollMicroseconds >> go (remaining - 1)

-- | Terminates and reaps a probe whatever state it is in.
reapReaderProbe :: ReaderProbe -> IO ()
reapReaderProbe probe = do
  ignoringIOException (terminateProcess probe.readerProbeHandle)
  ignoringIOException (() <$ waitForProcess probe.readerProbeHandle)

probeFailure :: ReaderProbe -> String -> IO result
probeFailure probe state = do
  diagnostics <- readDiagnostics probe.readerProbeDiagnosticsPath
  fail ("the reader probe " <> probe.readerProbeName <> " " <> state <> " (its output: " <> Text.unpack diagnostics <> ")")

-- | How many @gh@ processes have started, by the markers 'readerFakeGh' leaves.
countGhMarkers :: FilePath -> IO Int
countGhMarkers markerDirectory = do
  present <- doesDirectoryExist markerDirectory
  entries <- if present then listDirectory markerDirectory else pure []
  pure (length (filter ("started." `isPrefixOf`) entries))

-- | The fake @gh@ every reader here drives.
--
-- It leaves @started.<pid>@ the moment it runs, holds until at least
-- @quorum@ of those exist, and then answers: an item read with
-- 'readerIssueNumber' as 'readerExpectedTarget' describes it, anything else
-- with one complete, empty board page. It leaves @finished.<pid>@ once it has
-- answered, and @signalled.<pid>@ if anything ever sends it TERM -- which a
-- reader signalling another reader's healthy @gh@ would do first.
--
-- A quorum of one is no hold at all.
readerFakeGh :: FilePath -> Int -> [ByteString.ByteString]
readerFakeGh markerDirectory quorum =
  [ ByteString.pack ("markers=" <> markerDirectory),
    "trap ': > \"$markers/signalled.$$\"' TERM",
    ": > \"$markers/started.$$\"",
    "waited=0",
    ByteString.pack ("while [ \"$(ls \"$markers\" | grep -c '^started\\.')\" -lt " <> show quorum <> " ]; do"),
    "  waited=$((waited + 1))",
    "  [ \"$waited\" -gt 1200 ] && exit 3",
    "  sleep 0.05",
    "done",
    "case \"$1\" in",
    ByteString.pack ("  issue) printf '%s' '" <> itemJson <> "' ;;"),
    ByteString.pack ("  *) printf '%s' '" <> githubIndependentPage (Just ([], Nothing)) (Just ([], Nothing)) <> "' ;;"),
    "esac",
    ": > \"$markers/finished.$$\""
  ]
  where
    itemJson =
      "{\"number\":"
        <> show readerIssueNumber
        <> ",\"updatedAt\":\"2026-09-28T00:00:42Z\",\"state\":\"OPEN\",\"labels\":[]}"

readerIssueNumber :: Int
readerIssueNumber = 742

-- | The reading 'readerFakeGh' gives for 'readerIssueNumber', in the spellings
-- the read under test normalizes it to, so a worker whose launch recorded it
-- finds its precondition still holding.
readerExpectedTarget :: TargetPrecondition
readerExpectedTarget =
  TargetPrecondition
    { preconditionItem = IssueId readerIssueNumber,
      preconditionUpdatedAt = UTCTime (fromGregorian 2026 9 28) (secondsToDiffTime 42),
      preconditionHead = Nothing,
      preconditionLabels = [],
      preconditionState = "open"
    }

-- * The child

-- | The child half, reached from @main@ when 'readerProbeVariable' is set.
runReaderProbe :: FilePath -> IO ()
runReaderProbe planPath = do
  decoded <- eitherDecodeFileStrict' planPath :: IO (Either String ReaderPlan)
  case decoded of
    Left message -> die ("the reader probe could not read its plan at " <> planPath <> ": " <> message)
    Right plan -> do
      setEnv "XDG_CACHE_HOME" plan.readerPlanCacheRoot
      setEnv "XDG_CONFIG_HOME" plan.readerPlanConfigRoot
      -- The process's one record lock, minted where the production process
      -- mints its own: at the top, before any read.
      recordLock <- newGhRecordLock
      steps <- case plan.readerPlanRole of
        DashboardReader -> pure <$> dashboardRead plan recordLock
        RunnerBoardReader -> pure <$> takeRead plan recordLock "runner board read" ReadBoard
        WorkerReader -> pure <$> takeRead plan recordLock "worker precondition reread" ReadPrecondition
        LatchSequence source consumers -> latchSequence plan recordLock source consumers
      recordLoad <- loadGhGroupRecord plan.readerPlanRepository
      let recordEmpty = case recordLoad of
            GhGroupRecordAbsent -> True
            GhGroupRecordLoaded [] -> True
            _ -> False
          partial = plan.readerPlanOutcomePath <> ".partial"
      LazyByteString.writeFile partial (encode (ReaderOutcome steps recordEmpty))
      renameFile partial plan.readerPlanOutcomePath

-- | The first read under a store that can neither record its @gh@ nor confirm
-- it gone -- the production path to a verdict only this process's memory
-- holds -- then each consumer with that store and @ps@ restored, and finally
-- the first consumer again under a lock no read in this process has used.
--
-- The last is the control. Its @gh@ runs in exactly the environment the
-- refused consumers had, so a consumer turned away here is turned away by
-- this process's lock and by nothing ambient.
latchSequence :: ReaderPlan -> GhRecordLock -> ReadKind -> [ReadKind] -> IO [ReaderStep]
latchSequence plan recordLock source consumers = do
  (first, _) <-
    withForcedCleanup plan.readerPlanForcedRoot Nothing termIgnoringGh $
      takeRead plan recordLock "source" source
  later <- forM consumers (takeRead plan recordLock "consumer")
  control <- case consumers of
    [] -> pure []
    kind : _ -> do
      untouched <- newGhRecordLock
      pure <$> takeRead plan untouched "control" kind
  pure ((first : later) <> control)

-- | One read of the given kind through @recordLock@, with the @gh@ processes it
-- started counted around it and its guard's verdict read once it is over.
--
-- The guard is built here over the process's lock and handed to the same
-- production read the lock-taking entry point runs, so the verdict read back
-- is the one that read's own lifecycle left.
takeRead :: ReaderPlan -> GhRecordLock -> Text -> ReadKind -> IO ReaderStep
takeRead plan recordLock label kind = do
  guard <- newGhFetchGuard recordLock
  before <- countGhMarkers plan.readerPlanMarkerDirectory
  -- A @gh@ whose spawn could not be recorded is aborted by an exception rather
  -- than a returned failure, and a single-item read does not catch it; that
  -- is its existing routing and not what these examples are about, so it is
  -- reported here as the failed read it is.
  attempted <- try @SomeException $ case kind of
    ReadBoard -> do
      read' <- missionBoardReadUnder config plan.readerPlanRepository guard
      pure (isRight read', either (Text.pack . show) (const "") read')
    ReadTarget -> do
      read' <- missionTargetObservationUnder config plan.readerPlanRepository target guard
      pure (isRight read', either id (const "") read')
    ReadPrecondition -> do
      refusal <- preconditionStillHoldsUnder guard launched
      pure (isNothing refusal, maybe "" id refusal)
  let (succeeded, detail) = either (\raised -> (False, "raised: " <> Text.pack (show raised))) id attempted
  after <- countGhMarkers plan.readerPlanMarkerDirectory
  verdict <- ghFetchCleanupFailure guard
  pure (ReaderStep (label <> " (" <> Text.pack (show kind) <> ")") succeeded detail (after - before) (Text.pack . show . ghCleanupGuard <$> verdict))
  where
    target = MissionTarget MissionTargetIssue readerIssueNumber Nothing
    launched =
      (workerFixtureSpec plan.readerPlanRepository (WorkerId "solve-742-0001") readerIssueNumber)
        { workerExpectedTarget = Just readerExpectedTarget
        }

-- | One open refresh, run as a dashboard runs it: a job of a refresh
-- coordinator built over the process's record lock.
dashboardRead :: ReaderPlan -> GhRecordLock -> IO ReaderStep
dashboardRead plan recordLock = do
  before <- countGhMarkers plan.readerPlanMarkerDirectory
  traversal <- newHistoryTraversal
  channel <- newBChan 16
  published <- newEmptyMVar
  coordinator <-
    newRefreshCoordinator
      recordLock
      (boardRefreshRunner config {resolvedCache = False} plan.readerPlanRepository traversal channel)
      (\_ outcome -> putMVar published outcome)
      (const (pure ()))
  requestRefreshJob coordinator OpenJob Nothing
  outcome <- takeMVar published
  _ <- shutdownRefreshCoordinator coordinator
  after <- countGhMarkers plan.readerPlanMarkerDirectory
  let succeeded = case outcome of
        BoardRefreshCompleted (Right _) -> True
        _ -> False
  pure (ReaderStep "dashboard open refresh" succeeded (if succeeded then "" else Text.pack (show outcome)) (after - before) Nothing)

-- | Every read here is bounded well above what a held @gh@ needs and well
-- below the suite's own patience.
config :: ResolvedConfig
config = testResolvedConfig {resolvedTimeouts = defaultTimeoutsConfig {timeoutsGithubSeconds = 60}}

-- | A child's stdout and stderr, decoded leniently so a diagnostic the
-- parent's locale cannot decode still reaches the failure it belongs in.
readDiagnostics :: FilePath -> IO Text
readDiagnostics path = do
  present <- doesFileExist path
  if not present
    then pure "no output"
    else Text.strip . TextEncoding.decodeUtf8With lenientDecode <$> ByteString.readFile path
