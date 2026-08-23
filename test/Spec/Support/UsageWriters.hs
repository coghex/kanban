{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Independent OS processes committing to @usage.json@ at the same time.
--
-- The defect issue #477 reports is a lost update between two Kanban processes,
-- and it cannot be reproduced inside one of them: the whole question is what
-- happens when two processes each read the committed map, each merge their own
-- refresh onto it, and each write the result back. Threads in one suite process
-- would exercise a lock this fixture is not about — 'commitUsageSnapshots'
-- serialises through the filesystem, not through anything in-process — and
-- would leave the cross-process claim untested.
--
-- So each writer is the test binary run again, taking the branch in @main@ that
-- leads here instead of to hspec. What each one commits is its own provider's
-- snapshot and nothing else, which is what every production caller now hands
-- over.
--
-- The overlap is arranged rather than hoped for. The parent takes the
-- transaction's own lock before spawning anything, so no child can commit;
-- every child then announces that it is about to, and only once all of them
-- have does the parent release. Whichever order they then run in, each was
-- inside the window the other's commit spans.
module Spec.Support.UsageWriters
  ( UsageWriter (..),
    UsageWriterOutcome (..),
    runConcurrentUsageWriters,
    runUsageWriter,
    usageWriterCommand,
    usageWriterVariable
  )
where

import Control.Exception (onException)
import Control.Monad (unless)
import Data.Aeson (FromJSON, ToJSON, eitherDecodeFileStrict', encode)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import GHC.Generics (Generic)
import GHC.IO.Handle.Lock (LockMode (ExclusiveLock), hLock, hUnlock)
import Kanban.Cache (UsageCommit (..), commitUsageSnapshots, usageCacheLockPath)
import Kanban.Domain (UsageProvider, UsageSnapshot)
import Spec.Support.Env (ignoringIOException, waitForFileToExist)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (ReadWriteMode, WriteMode), hClose, openFile, withFile)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (..), createProcess, proc, terminateProcess, waitForProcess)

-- | One writer: the name its files are keyed by, and the single provider entry
-- it commits.
data UsageWriter = UsageWriter
  { usageWriterName :: String,
    usageWriterProvider :: UsageProvider,
    usageWriterSnapshot :: UsageSnapshot
  }
  deriving stock (Eq, Show)

-- | What one writer's commit reported, carried back through a file because the
-- writer is a process rather than a thread.
--
-- Both halves of 'UsageCommit' are recorded. A test that asserted only on the
-- stored map would pass just as well if every commit had failed.
data UsageWriterOutcome = UsageWriterOutcome
  { usageWriterFailure :: Maybe Text,
    usageWriterWarning :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | What one child is to commit and where to leave its answer.
data UsageWriterPlan = UsageWriterPlan
  { usagePlanProvider :: UsageProvider,
    usagePlanSnapshot :: UsageSnapshot,
    usagePlanReadyPath :: FilePath,
    usagePlanOutcomePath :: FilePath
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Set on a child and nothing else: its presence is what tells @main@ it is a
-- writer rather than the suite, which is also what stops a child from spawning
-- writers of its own. It carries the path to that child's plan.
usageWriterVariable :: String
usageWriterVariable = "KANBAN_USAGE_WRITER_PROBE"

-- | How long the parent waits for a child to announce itself, in units of the
-- 100ms 'waitForFileToExist' polls at. Generous on purpose: this is a process
-- start, and a loaded machine is a slow one, but it must not be unbounded or a
-- child that died silently would hang the suite instead of failing it.
usageWriterAttempts :: Int
usageWriterAttempts = 600

-- | The parent half. Runs every writer as its own process, released together,
-- and hands back what each one reported.
--
-- The writers share whatever @XDG_CACHE_HOME@ the caller has established, so
-- the cache they contend over is the fixture's own.
runConcurrentUsageWriters :: FilePath -> [UsageWriter] -> IO [(String, UsageWriterOutcome)]
runConcurrentUsageWriters probeRoot writers = do
  createDirectoryIfMissing True probeRoot
  lockPath <- usageCacheLockPath
  self <- getExecutablePath
  inherited <- getEnvironment
  -- Taken before anything is spawned. A lock taken afterwards would be a race
  -- with the very children it is supposed to hold back.
  barrier <- openFile lockPath ReadWriteMode
  let release = ignoringIOException (hUnlock barrier) >> ignoringIOException (hClose barrier)
  hLock barrier ExclusiveLock `onException` release
  outcomes <-
    ( do
        children <- mapM (spawnWriter self inherited probeRoot) writers
        ( do
            mapM_ (waitForReady probeRoot) writers
            release
            mapM_ (awaitWriter probeRoot) children
          )
          `onException` (release >> mapM_ (\(_, handle) -> terminateProcess handle) children)
        mapM (readOutcome probeRoot) writers
      )
      `onException` release
  release
  pure outcomes

-- | The child half, reached from @main@ when 'usageWriterVariable' is set.
--
-- The announcement is the last thing before the commit, so the parent's
-- release cannot land while a child is still starting up.
runUsageWriter :: FilePath -> IO ()
runUsageWriter planPath = do
  decoded <- eitherDecodeFileStrict' planPath :: IO (Either String UsageWriterPlan)
  case decoded of
    Left message -> fail ("the usage writer could not read its plan at " <> planPath <> ": " <> message)
    Right plan -> do
      writeFile plan.usagePlanReadyPath ""
      commit <- commitUsageSnapshots (Map.singleton plan.usagePlanProvider plan.usagePlanSnapshot)
      LazyByteString.writeFile
        plan.usagePlanOutcomePath
        (encode (UsageWriterOutcome (either Just (const Nothing) commit.usageCommitResult) commit.usageCommitWarning))

-- | The shell command one writer runs as, for a fixture that must commit from
-- another process while the code under test sits between its own read and its
-- own write.
--
-- This needs no barrier. The caller drops the line into a provider command the
-- code under test spawns and waits for, so the outside commit is finished
-- before the caller's own probe returns and the interleaving is decided by
-- that sequence rather than by timing. A writer that fails takes the provider
-- command down with it, so a fixture that stopped committing is a failure
-- rather than a quietly weaker test.
usageWriterCommand :: FilePath -> UsageWriter -> IO Char8.ByteString
usageWriterCommand probeRoot writer = do
  createDirectoryIfMissing True probeRoot
  planPath <- writePlan probeRoot writer
  self <- getExecutablePath
  pure (Char8.pack (usageWriterVariable <> "=" <> shellQuoted planPath <> " " <> shellQuoted self <> " >/dev/null 2>&1 || exit 1"))

shellQuoted :: String -> String
shellQuoted value = "'" <> concatMap escaped value <> "'"
  where
    escaped '\'' = "'\\''"
    escaped character = [character]

writePlan :: FilePath -> UsageWriter -> IO FilePath
writePlan probeRoot writer = do
  let planPath = probeRoot </> (writer.usageWriterName <> "-plan.json")
  LazyByteString.writeFile
    planPath
    ( encode
        ( UsageWriterPlan
            writer.usageWriterProvider
            writer.usageWriterSnapshot
            (readyPath probeRoot writer)
            (outcomePath probeRoot writer)
        )
    )
  pure planPath

spawnWriter :: FilePath -> [(String, String)] -> FilePath -> UsageWriter -> IO (UsageWriter, ProcessHandle)
spawnWriter self inherited probeRoot writer = do
  planPath <- writePlan probeRoot writer
  -- Every probe marker the parent may itself be carrying is dropped, so a
  -- child cannot re-enter a branch of @main@ this fixture did not choose.
  let carried = filter (not . ("KANBAN_" `isPrefixOf`) . fst) inherited
      childEnvironment = carried <> [(usageWriterVariable, planPath)]
  handle <-
    withFile (diagnosticsPath probeRoot writer) WriteMode $ \diagnostics -> do
      (_, _, _, child) <-
        createProcess
          (proc self [])
            { env = Just childEnvironment,
              std_out = UseHandle diagnostics,
              std_err = UseHandle diagnostics
            }
      pure child
  pure (writer, handle)

waitForReady :: FilePath -> UsageWriter -> IO ()
waitForReady probeRoot writer = waitForFileToExist (readyPath probeRoot writer) usageWriterAttempts

awaitWriter :: FilePath -> (UsageWriter, ProcessHandle) -> IO ()
awaitWriter probeRoot (writer, handle) = do
  exitCode <- waitForProcess handle
  unless (exitCode == ExitSuccess) $ do
    diagnostics <- readDiagnostics (diagnosticsPath probeRoot writer)
    fail ("the usage writer " <> writer.usageWriterName <> " exited with " <> show exitCode <> ": " <> Text.unpack diagnostics)

readOutcome :: FilePath -> UsageWriter -> IO (String, UsageWriterOutcome)
readOutcome probeRoot writer = do
  decoded <- eitherDecodeFileStrict' (outcomePath probeRoot writer) :: IO (Either String UsageWriterOutcome)
  case decoded of
    Left message -> do
      diagnostics <- readDiagnostics (diagnosticsPath probeRoot writer)
      fail ("the usage writer " <> writer.usageWriterName <> " recorded no outcome (" <> message <> "): " <> Text.unpack diagnostics)
    Right outcome -> pure (writer.usageWriterName, outcome)

readyPath, outcomePath, diagnosticsPath :: FilePath -> UsageWriter -> FilePath
readyPath probeRoot writer = probeRoot </> (writer.usageWriterName <> "-ready")
outcomePath probeRoot writer = probeRoot </> (writer.usageWriterName <> "-outcome.json")
diagnosticsPath probeRoot writer = probeRoot </> (writer.usageWriterName <> "-diagnostics.log")

-- | A child's stdout and stderr, decoded here rather than through 'readFile',
-- so a diagnostic the parent's locale cannot decode still reaches the failure
-- message it belongs in.
readDiagnostics :: FilePath -> IO Text
readDiagnostics path = Text.strip . TextEncoding.decodeUtf8With lenientDecode <$> ByteString.readFile path
