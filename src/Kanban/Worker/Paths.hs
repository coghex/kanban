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
    decodeFile,
    readWorkerState,
    writeState,
    persistState,
    IssueActionClaim (..),
    IssueActionClaimOutcome (..),
    claimIssueAction,
    readIssueActionClaim,
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
import qualified Data.Text.Encoding as TextEncoding
import Data.Time (UTCTime, getCurrentTime)
import Kanban.Domain (Repository (..))
import Kanban.Worker.Types
  ( IssueActionWorkerTask (..),
    PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerDescriptor (..),
    WorkerId (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerTask (..),
  )
import System.Directory (XdgDirectory (XdgCache), doesDirectoryExist, getXdgDirectory, listDirectory, removeFile, renameFile)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.FilePath ((</>))
import System.Posix.Files (createLink, setFileMode)
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
        workerDescriptorPendingTerminationPath = directory </> base <> ".pending-termination",
        workerDescriptorHandoffPath = directory </> base <> ".handing-off",
        workerDescriptorCommandPath = directory </> base <> ".commands.jsonl",
        workerDescriptorCommandAckPath = directory </> base <> ".command-acks.jsonl",
        workerDescriptorAdoptionPath = directory </> base <> ".adoption"
      }

-- | The item a task reserves, which is what the one-live-worker invariant is
-- keyed by.
--
-- An issue action takes @issue-action-\<n\>@ rather than the solver's
-- @issue-\<n\>@ deliberately (requirement 13): a solve and a review of the
-- same issue may run at once, and folding them onto one key would make the
-- second of them refuse. The review host takes one repository-wide key,
-- because the worker directory is already per-repository and the host is the
-- single 'Kanban.Review.ReviewClient' owner within it.
workerLeaseKey :: WorkerTask -> FilePath
workerLeaseKey task = case task of
  SolveWorkerTaskKind solveTask -> "issue-" <> show solveTask.solveWorkerIssueNumber
  PullRequestWorkerTaskKind pullRequestTask -> "pr-" <> show pullRequestTask.pullRequestWorkerNumber
  IssueHostWorkerTaskKind _ -> "issue-host"
  IssueActionWorkerTaskKind actionTask -> "issue-action-" <> show actionTask.issueActionIssueNumber

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

-- | Who has taken an issue action.
data IssueActionClaim
  = -- | The review host with this identity adopted it.
    ClaimedByHost WorkerId
  | -- | Its launch withdrew it after nothing adopted it in time.
    ClaimedByWithdrawal
  deriving stock (Eq, Show)

data IssueActionClaimOutcome
  = -- | This caller's claim is the one that stands.
    IssueActionClaimWon
  | -- | Somebody else's claim was already there.
    IssueActionClaimHeld IssueActionClaim
  | -- | Nothing could be settled: the claim could not be written, or the one
    -- already there could not be read. Never taken as either answer.
    IssueActionClaimUnsettled Text
  deriving stock (Eq, Show)

-- | Takes an issue action for a host or for its launch's withdrawal, unless
-- the other already has.
--
-- A host adopts a child by inserting it into memory and journaling its first
-- event some moments later, and the launch that is waiting for that event
-- gives up after a bound and removes the child. Neither end can see the
-- other's decision from a file it merely reads, so both make it the same
-- way: by creating one file that cannot be created twice. The whole claim is
-- written beside it first and hard-linked into place, so the file is never
-- seen half-written, and a link onto a name that exists fails rather than
-- replacing it.
claimIssueAction :: WorkerDescriptor -> IssueActionClaim -> IO IssueActionClaimOutcome
claimIssueAction descriptor claim = do
  processId <- getProcessID
  now <- getCurrentTime
  let path = descriptor.workerDescriptorAdoptionPath
      staging = path <> ".staging-" <> show processId <> "-" <> Text.unpack (timestampKey now)
  staged <- try @IOException $ do
    ByteString.writeFile staging (claimBytes claim)
    setFileMode staging 0o600
  case staged of
    Left exception -> pure (IssueActionClaimUnsettled ("the adoption claim could not be staged: " <> Text.pack (show exception)))
    Right () -> do
      linked <- try @IOException (createLink staging path)
      ignoreFileOperation (removeFile staging)
      case linked of
        Right () -> pure IssueActionClaimWon
        Left exception
          | isAlreadyExistsError exception -> do
              existing <- readIssueActionClaim descriptor
              pure $ case existing of
                Right (Just held) -> IssueActionClaimHeld held
                Right Nothing -> IssueActionClaimUnsettled "the adoption claim vanished while it was being read"
                Left message -> IssueActionClaimUnsettled message
          | otherwise -> pure (IssueActionClaimUnsettled ("the adoption claim could not be made: " <> Text.pack (show exception)))
  where
    claimBytes (ClaimedByHost host) = TextEncoding.encodeUtf8 ("host " <> host.unWorkerId <> "\n")
    claimBytes ClaimedByWithdrawal = "withdrawn\n"

-- | The claim an issue action carries, 'Nothing' when it carries none.
readIssueActionClaim :: WorkerDescriptor -> IO (Either Text (Maybe IssueActionClaim))
readIssueActionClaim descriptor = do
  loaded <- try @IOException (ByteString.readFile descriptor.workerDescriptorAdoptionPath)
  pure $ case loaded of
    Left exception
      | isDoesNotExistError exception -> Right Nothing
      | otherwise -> Left ("the adoption claim could not be read: " <> Text.pack (show exception))
    Right bytes -> case Text.words (TextEncoding.decodeUtf8With (\_ _ -> Just '\xfffd') bytes) of
      ["withdrawn"] -> Right (Just ClaimedByWithdrawal)
      ["host", host] -> Right (Just (ClaimedByHost (WorkerId host)))
      _ -> Left "the adoption claim is not one this release writes"
