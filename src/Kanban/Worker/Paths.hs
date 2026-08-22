-- | Where a persistent worker's durable artifacts live and how they are read
-- and written: the cache directory and per-worker path set derived from a
-- spec, and the user-only JSON read\/write primitives every other worker
-- module persists through.
--
-- Deliberately the lowest layer above "Kanban.Worker.Types": lease,
-- termination, journal, discovery, and the supervisor core all persist state
-- through these, so keeping them here is what lets those modules depend on
-- one another without a cycle.
--
-- This module is internal — "Kanban.Worker" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Worker.Paths
  ( descriptorForSpec,
    workerDirectory,
    workerLeaseKey,
    newWorkerId,
    safeKey,
    safePathComponent,
    listDirectoryOrEmpty,
    ignoreFileOperation,
    writePrivateJson,
    writeWorkerRoster,
    readWorkerRoster,
    decodeFile,
    readWorkerState,
    writeState,
    persistState,
  )
where

import Control.Concurrent.MVar (MVar, withMVar)
import Control.Exception (IOException, try)
import Control.Monad (void)
import Data.Aeson (FromJSON, ToJSON, eitherDecodeStrict', encode)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import Data.Time (UTCTime, getCurrentTime)
import Kanban.Domain (Repository (..))
import Kanban.Models
  ( ModelRoster,
    decodeRoster,
    encodeRoster,
    rosterFailureMessage,
  )
import Kanban.Worker.Types
  ( PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerDescriptor (..),
    WorkerId (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerTask (..),
  )
import System.Directory (XdgDirectory (XdgCache), doesDirectoryExist, getXdgDirectory, listDirectory, renameFile)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Posix.Process (getProcessID)

descriptorForSpec :: WorkerSpec -> IO WorkerDescriptor
descriptorForSpec spec = do
  directory <- workerDirectory spec.workerRepository
  let base = Text.unpack spec.workerId.unWorkerId
      leasePath = directory </> workerLeaseKey spec.workerTask <> ".lease"
  pure
    WorkerDescriptor
      { workerDescriptorSpec = spec,
        workerDescriptorSpecPath = directory </> base <> ".spec.json",
        workerDescriptorRosterPath = directory </> base <> ".roster.toml",
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

-- | Rejects anything that is not a plain name inside the directory being
-- scanned, including the empty string, the two directory entries every
-- directory has, and any separator a serialized worker id could carry to
-- escape the cache.
safePathComponent :: FilePath -> Bool
safePathComponent name =
  not (null name)
    && name `notElem` [".", ".."]
    && not (any (`elem` ("/\\\NUL" :: String)) name)

listDirectoryOrEmpty :: FilePath -> IO [FilePath]
listDirectoryOrEmpty directory = do
  exists <- doesDirectoryExist directory
  if not exists
    then pure []
    else either (const []) id <$> try @IOException (listDirectory directory)

ignoreFileOperation :: IO () -> IO ()
ignoreFileOperation operation = void (try @IOException operation)

writePrivateJson :: ToJSON value => FilePath -> value -> IO (Either Text ())
writePrivateJson path value = do
  let temporary = path <> ".tmp"
  result <- try @IOException $ do
    LazyByteString.writeFile temporary (encode value)
    setFileMode temporary 0o600
    renameFile temporary path
  pure (either (Left . Text.pack . show) Right result)

-- | Writes the launch-scoped roster snapshot beside the spec, through the
-- same temporary-file, @0600@, rename discipline 'writePrivateJson' uses.
--
-- Deliberately the roster's own TOML rather than a JSON projection of it:
-- 'encodeRoster' and 'decodeRoster' are already each other's inverse and
-- already tested as such, so the snapshot cannot drift from the schema the
-- dashboard validated.
writeWorkerRoster :: WorkerDescriptor -> ModelRoster -> IO (Either Text ())
writeWorkerRoster descriptor roster = do
  let path = descriptor.workerDescriptorRosterPath
      temporary = path <> ".tmp"
  result <- try @IOException $ do
    ByteString.writeFile temporary (Encoding.encodeUtf8 (encodeRoster roster))
    setFileMode temporary 0o600
    renameFile temporary path
  pure (either (Left . Text.pack . show) Right result)

-- | Reads back the snapshot its launcher wrote. Fails closed: a supervisor
-- that cannot read the roster it was launched against spawns nothing, rather
-- than loading the user's current file or the compiled defaults.
readWorkerRoster :: WorkerDescriptor -> IO (Either Text ModelRoster)
readWorkerRoster descriptor = do
  let path = descriptor.workerDescriptorRosterPath
  bytesResult <- try @IOException (ByteString.readFile path)
  pure $ case bytesResult of
    Left exception -> Left ("model roster snapshot " <> Text.pack path <> " could not be read: " <> Text.pack (show exception))
    Right bytes -> case Encoding.decodeUtf8' bytes of
      Left unicodeError -> Left ("model roster snapshot " <> Text.pack path <> " is not UTF-8: " <> Text.pack (show unicodeError))
      Right contents ->
        either (\failure -> Left ("model roster snapshot " <> Text.pack path <> " " <> rosterFailureMessage failure)) Right (decodeRoster contents)

decodeFile :: FromJSON value => FilePath -> IO (Either Text value)
decodeFile path = do
  bytesResult <- try @IOException (ByteString.readFile path)
  pure $ case bytesResult of
    Left exception -> Left (Text.pack (show exception))
    Right bytes -> case eitherDecodeStrict' bytes of
      Left message -> Left (Text.pack message)
      Right value -> Right value

readWorkerState :: WorkerDescriptor -> IO (Either Text WorkerState)
readWorkerState descriptor = decodeFile descriptor.workerDescriptorStatePath

writeState :: WorkerDescriptor -> WorkerState -> IO ()
writeState descriptor = void . writePrivateJson descriptor.workerDescriptorStatePath

persistState :: WorkerDescriptor -> MVar WorkerState -> IO ()
persistState descriptor stateLock = withMVar stateLock (writeState descriptor)
