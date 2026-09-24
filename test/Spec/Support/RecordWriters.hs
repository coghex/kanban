{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Independent OS processes rewriting one repository's durable @gh@ record at
-- the same time.
--
-- The defect issue #720 reports is a lost update between two Kanban processes
-- -- a dashboard and a mission runner, say -- each holding an in-process record
-- lock of its own. Nothing inside one suite process can stage that: threads
-- that shared a 'Kanban.GitHub.Guard.GhRecordLock' would be ordered by its
-- mutex, which is not the lock under test, and the production failure is two
-- processes that share nothing but the file.
--
-- So each writer is the test binary run again, taking the branch in @main@
-- that leads to 'runRecordWriter' instead of to hspec, and each rewrites the
-- record through the production transaction, 'Kanban.GitHub.Guard.recordGhGroup',
-- under a record lock it minted itself -- exactly what a second process does.
-- The shape is "Spec.Support.UsageWriters"' and "Spec.Support.LeaseProbes"':
-- a marker in the child's environment, answers carried back through files,
-- every wait bounded, and every assertion made by the parent.
--
-- The overlap is arranged rather than hoped for, and it never asks both
-- writers to be inside the protected section at once -- a staging that needed
-- that could not pass once the section is serialised. Each writer instead
-- keeps rewriting, one new entry per transaction, until it has seen its peer
-- announce that it is rewriting too, and then goes on for a fixed number of
-- transactions more. Whichever starts first is therefore still rewriting when
-- the second begins, and the two run side by side for at least that many
-- transactions: contention is a fact of the schedule, whatever the scheduler
-- does with it. Without the cross-process lock those interleaved
-- read-modify-writes lose entries; with it, every entry either writer was told
-- it recorded is in the file.
module Spec.Support.RecordWriters
  ( RecordWriter (..),
    RecordWriterOutcome (..),
    recordWriterVariable,
    runConcurrentRecordWriters,
    runRecordWriter,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (forM, forM_, unless)
import Data.Aeson (FromJSON, ToJSON, eitherDecodeFileStrict', encode)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import GHC.Generics (Generic)
import Kanban.Domain (Repository)
import Kanban.GitHub (newGhFetchGuard, newGhRecordLock, recordGhGroup)
import Kanban.Process (OwnedProcessGroup (..))
import Spec.Support.Env (ignoringIOException)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
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

-- | One writer: the name its files are keyed by, and the first of the process
-- group ids it records, one per transaction and counting up.
--
-- The ids are never signalled or looked up -- 'recordGhGroup' writes an entry
-- and nothing more -- so they only need to be distinct between writers, which
-- bases far enough apart make them.
data RecordWriter = RecordWriter
  { recordWriterName :: String,
    recordWriterFirstGroup :: Int
  }
  deriving stock (Eq, Show)

-- | What one writer's transactions reported, carried back through a file
-- because the writer is a process rather than a thread.
--
-- Both halves are recorded. An assertion only on the stored record would pass
-- just as well if every transaction had failed and written nothing.
data RecordWriterOutcome = RecordWriterOutcome
  { recordWriterRecorded :: [Int],
    recordWriterFailures :: [Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | What one child is to do and where to leave each of its answers.
data RecordWriterPlan = RecordWriterPlan
  { recordPlanRepository :: Repository,
    recordPlanCacheRoot :: FilePath,
    recordPlanFirstGroup :: Int,
    recordPlanOverlap :: Int,
    recordPlanStartedPath :: FilePath,
    recordPlanGatePath :: FilePath,
    recordPlanRewritingPath :: FilePath,
    recordPlanPeerRewritingPaths :: [FilePath],
    recordPlanOutcomePath :: FilePath
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Set on a child and nothing else: its presence is what tells @main@ this
-- process is a record writer rather than the suite. It carries the path to that
-- child's plan.
recordWriterVariable :: String
recordWriterVariable = "KANBAN_RECORD_WRITER_PROBE"

-- | How long any wait here lasts, in units of the 100ms it polls at. Generous,
-- because a process start on a loaded machine is slow; bounded, because a
-- writer that died quietly must fail the suite rather than hang it.
recordWriterAttempts :: Int
recordWriterAttempts = 600

pollMicroseconds :: Int
pollMicroseconds = 100000

-- | A writer that never sees its peer stops here rather than growing the
-- record forever; it then reports the peer's absence as a failure.
transactionCeiling :: Int
transactionCeiling = 20000

-- * The parent

-- | Runs every writer as its own process against @repository@ under
-- @cacheRoot@, released together, and hands back what each one reported once
-- all of them have exited.
--
-- @overlap@ is how many transactions each writer goes on for after it has seen
-- every other writer rewriting, which is the span the writers are guaranteed
-- to share.
runConcurrentRecordWriters :: FilePath -> FilePath -> Repository -> Int -> [RecordWriter] -> IO [(String, RecordWriterOutcome)]
runConcurrentRecordWriters probeRoot cacheRoot repository overlap writers = do
  createDirectoryIfMissing True probeRoot
  self <- getExecutablePath
  inherited <- getEnvironment
  -- Every child is registered the instant it exists, and the cleanup reads
  -- that register, so a start that failed part way through the list still
  -- leaves the children before it with somebody to reap them.
  launched <- newIORef []
  bracket (pure ()) (const (readIORef launched >>= mapM_ reapHandle)) $ \() -> do
    running <- forM writers $ \writer -> do
      handle <- startWriter self inherited writer
      modifyIORef' launched (handle :)
      pure (writer, handle)
    forM_ running $ \(writer, handle) -> awaitFile writer handle "reach its gate" (startedPath writer)
    touch gatePath
    forM_ running $ \(writer, handle) -> do
      code <- awaitExit writer handle
      unless (code == ExitSuccess) $ writerFailure writer ("exited with " <> show code)
    forM running $ \(writer, _) -> do
      decoded <- eitherDecodeFileStrict' (outcomePath writer) :: IO (Either String RecordWriterOutcome)
      case decoded of
        Left message -> writerFailure writer ("recorded no outcome (" <> message <> ")")
        Right outcome -> pure (writer.recordWriterName, outcome)
  where
    gatePath = probeRoot </> "gate"
    startedPath writer = probeRoot </> (writer.recordWriterName <> "-started")
    rewritingPath writer = probeRoot </> (writer.recordWriterName <> "-rewriting")
    outcomePath writer = probeRoot </> (writer.recordWriterName <> "-outcome.json")
    diagnosticsPath writer = probeRoot </> (writer.recordWriterName <> "-diagnostics.log")

    startWriter self inherited writer = do
      let planPath = probeRoot </> (writer.recordWriterName <> "-plan.json")
      LazyByteString.writeFile
        planPath
        ( encode
            ( RecordWriterPlan
                repository
                cacheRoot
                writer.recordWriterFirstGroup
                overlap
                (startedPath writer)
                gatePath
                (rewritingPath writer)
                [rewritingPath peer | peer <- writers, peer /= writer]
                (outcomePath writer)
            )
        )
      -- Every probe marker the parent may itself be carrying is dropped, so a
      -- child cannot re-enter a branch of @main@ this fixture did not choose.
      let carried = filter (not . ("KANBAN_" `isPrefixOf`) . fst) inherited
      withFile (diagnosticsPath writer) WriteMode $ \diagnostics -> do
        (_, _, _, child) <-
          createProcess
            (proc self [])
              { env = Just (carried <> [(recordWriterVariable, planPath)]),
                std_out = UseHandle diagnostics,
                std_err = UseHandle diagnostics
              }
        pure child

    awaitFile writer handle state path = go recordWriterAttempts
      where
        go remaining = do
          reached <- doesFileExist path
          unless reached $ do
            exited <- getProcessExitCode handle
            case exited of
              Just code -> writerFailure writer ("exited with " <> show code <> " before it could " <> state)
              Nothing
                | remaining <= (0 :: Int) -> writerFailure writer ("did not " <> state)
                | otherwise -> threadDelay pollMicroseconds >> go (remaining - 1)

    awaitExit writer handle = go recordWriterAttempts
      where
        go remaining = do
          finished <- getProcessExitCode handle
          case finished of
            Just code -> pure code
            Nothing
              | remaining <= (0 :: Int) -> writerFailure writer "did not exit"
              | otherwise -> threadDelay pollMicroseconds >> go (remaining - 1)

    -- The child's own output is read into the message, while the file it
    -- wrote is still the reason rather than the remains; the bracket above
    -- reaps every child on the way out.
    writerFailure :: RecordWriter -> String -> IO result
    writerFailure writer state = do
      diagnostics <- readDiagnostics (diagnosticsPath writer)
      fail ("the record writer " <> writer.recordWriterName <> " " <> state <> " (its output: " <> Text.unpack diagnostics <> ")")

-- | Terminates and reaps a writer whatever state it is in. A handle already
-- waited for is closed, which both of these accept.
reapHandle :: ProcessHandle -> IO ()
reapHandle handle = do
  ignoringIOException (terminateProcess handle)
  ignoringIOException (() <$ waitForProcess handle)

-- * The writer

-- | The child half, reached from @main@ when 'recordWriterVariable' is set.
--
-- One guard for the whole run, minted in this process, as a mission runner or a
-- worker's precondition reread would mint one: it shares nothing with the
-- other writer but the files under the cache root.
runRecordWriter :: FilePath -> IO ()
runRecordWriter planPath = do
  decoded <- eitherDecodeFileStrict' planPath :: IO (Either String RecordWriterPlan)
  case decoded of
    Left message -> die ("the record writer could not read its plan at " <> planPath <> ": " <> message)
    Right plan -> do
      -- The writer resolves the record itself, so the root under test is the
      -- plan's rather than whichever one the parent happened to be pinned at.
      setEnv "XDG_CACHE_HOME" plan.recordPlanCacheRoot
      guard <- newGhRecordLock >>= newGhFetchGuard
      touch plan.recordPlanStartedPath
      awaitGate plan.recordPlanGatePath
      let transact groupPid = recordGhGroup guard plan.recordPlanRepository (OwnedProcessGroup groupPid [] False Nothing)
          -- @afterPeers@ counts the transactions since every peer was seen
          -- rewriting; 'Nothing' until then.
          go :: Int -> Maybe Int -> [Int] -> [Text] -> IO RecordWriterOutcome
          go index afterPeers recorded failures
            | Just done <- afterPeers,
              done >= plan.recordPlanOverlap =
                pure (RecordWriterOutcome (reverse recorded) (reverse failures))
            | index >= transactionCeiling =
                pure (RecordWriterOutcome (reverse recorded) (reverse ("never saw every peer rewriting" : failures)))
            | otherwise = do
                let groupPid = plan.recordPlanFirstGroup + index
                written <- transact groupPid
                -- Announced after the first transaction rather than before it,
                -- so a peer that sees this has a writer genuinely mid-run.
                unless (index > 0) (touch plan.recordPlanRewritingPath)
                seen <- case afterPeers of
                  Just done -> pure (Just (done + 1))
                  Nothing -> do
                    peers <- mapM doesFileExist plan.recordPlanPeerRewritingPaths
                    pure (if and peers then Just 0 else Nothing)
                case written of
                  Right () -> go (index + 1) seen (groupPid : recorded) failures
                  Left message -> go (index + 1) seen recorded (message : failures)
      outcome <- go 0 Nothing [] []
      let partial = plan.recordPlanOutcomePath <> ".partial"
      LazyByteString.writeFile partial (encode outcome)
      renameFile partial plan.recordPlanOutcomePath

-- | Waits at the gate, and gives up loudly rather than forever. Polled tightly,
-- since the writers are released together and a coarse poll would stagger them
-- -- harmlessly, since the overlap does not depend on it, but pointlessly.
awaitGate :: FilePath -> IO ()
awaitGate path = go (recordWriterAttempts * 100)
  where
    go remaining = do
      opened <- doesFileExist path
      unless opened $
        if remaining <= (0 :: Int)
          then die ("the record writer waited for " <> path <> " and it never opened")
          else threadDelay (pollMicroseconds `div` 100) >> go (remaining - 1)

touch :: FilePath -> IO ()
touch path = LazyByteString.writeFile path LazyByteString.empty

-- | A child's stdout and stderr, decoded here rather than through 'readFile',
-- so a diagnostic the parent's locale cannot decode still reaches the failure
-- message it belongs in.
readDiagnostics :: FilePath -> IO Text
readDiagnostics path = do
  present <- doesFileExist path
  if not present
    then pure "no output"
    else Text.strip . TextEncoding.decodeUtf8With lenientDecode <$> ByteString.readFile path
