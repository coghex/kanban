{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

module Kanban.Cache
  ( CacheLoad (..),
    CompletedCacheLoad (..),
    GhGroupRecordLoad (..),
    UsageCacheLoad (..),
    UsageCommit (..),
    commitUsageSnapshots,
    completedCacheSchemaVersion,
    ghGroupRecordPath,
    loadCompletedCache,
    loadGhGroupRecord,
    loadRepositoryCache,
    loadUsageCache,
    mergeUsageSnapshots,
    removeGhGroupRecord,
    repositoryCachePath,
    repositoryCacheSchemaVersion,
    usageCacheLockPath,
    usageCachePath,
    usageCommitNotes,
    writeCompletedCache,
    writeGhGroupRecord,
  )
where

import Control.Exception (IOException, bracketOnError, catch, finally, onException, try)
import Control.Monad (when)
import Data.Aeson
  ( FromJSON (parseJSON),
    Result (..),
    ToJSON (toJSON),
    Value,
    eitherDecodeFileStrict',
    eitherDecodeStrict',
    encode,
    fromJSON,
    object,
    withObject,
    (.:),
    (.=),
  )
import Data.Aeson.Types (parse)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import GHC.IO.Handle.Lock (FileLockingNotSupported, LockMode (ExclusiveLock), hLock, hUnlock)
import Kanban.Domain (CompletedHistory, RepoSnapshot, Repository (..), UsageProvider, UsageSnapshot (..))
import Kanban.Paths (createPrivateDirectory)
import Kanban.Process (OwnedProcessGroup)
import System.Directory
  ( XdgDirectory (XdgCache),
    doesFileExist,
    getXdgDirectory,
    removeFile,
    renameFile,
  )
import System.FilePath ((</>), takeDirectory, takeFileName)
import System.IO (Handle, hClose, openBinaryTempFile)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (setFdMode, setFileMode)
import System.Posix.IO (OpenFileFlags (..), OpenMode (ReadWrite), closeFd, defaultFileFlags, fdToHandle, openFd)

data CacheLoad
  = CacheAbsent
  | CacheLoaded RepoSnapshot
  | CacheInvalid Text
  deriving stock (Eq, Show)

-- | How reading the completed-history cache turned out.
--
-- The three cases are §16's, and are kept distinct for the reason §16 gives:
-- a file another release wrote is /absent/ and silent, because after an upgrade
-- or a downgrade it is expected; a file this build claims to understand and
-- cannot read is /invalid/ and says so. Neither ever supplies data.
data CompletedCacheLoad
  = CompletedCacheAbsent
  | CompletedCacheLoaded CompletedHistory
  | CompletedCacheInvalid Text
  deriving stock (Eq, Show)

data UsageCacheLoad
  = UsageCacheAbsent
  | UsageCacheLoaded (Map UsageProvider UsageSnapshot)
  | UsageCacheInvalid Text
  deriving stock (Eq, Show)

data CacheEnvelope = CacheEnvelope
  { schemaVersion :: Int,
    repositoryKey :: Text,
    snapshot :: RepoSnapshot
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The completed generation as it is written to the repository cache path.
--
-- Written by hand rather than derived because it shares its two envelope keys
-- with 'CacheEnvelope' — the same file has held both — and the field names a
-- generic instance would produce cannot collide in one module.
data CompletedCacheEnvelope = CompletedCacheEnvelope
  { completedSchemaVersion :: Int,
    completedRepositoryKey :: Text,
    completedHistory :: CompletedHistory
  }
  deriving stock (Eq, Show)

instance FromJSON CompletedCacheEnvelope where
  parseJSON = withObject "completed history cache" $ \cache ->
    CompletedCacheEnvelope <$> cache .: "schemaVersion" <*> cache .: "repositoryKey" <*> cache .: "history"

instance ToJSON CompletedCacheEnvelope where
  toJSON envelope =
    object
      [ "schemaVersion" .= envelope.completedSchemaVersion,
        "repositoryKey" .= envelope.completedRepositoryKey,
        "history" .= envelope.completedHistory
      ]

data UsageCacheEnvelope = UsageCacheEnvelope
  { usageSchemaVersion :: Int,
    usageSnapshots :: Map UsageProvider UsageSnapshot
  }
  deriving stock (Eq, Show)

-- | The @gh@ process groups a board refresh spawned and then failed to
-- confirm dead. Unlike the snapshot caches this is not an optimisation: it
-- is the only thing that carries "a gh of ours may still be running" across
-- a dashboard restart, so a later fetch re-verifies before spawning another.
data GhGroupEnvelope = GhGroupEnvelope
  { ghGroupSchemaVersion :: Int,
    ghGroupRepositoryKey :: Text,
    ghGroupGroups :: [OwnedProcessGroup]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | How a 'loadGhGroupRecord' turned out. An unreadable or unrecognised
-- record is 'GhGroupRecordUnusable', never silently treated as "nothing
-- recorded": the whole point of the file is to refuse a fetch while a gh may
-- still be live, and a caller that cannot read it does not know that it is
-- not.
data GhGroupRecordLoad
  = GhGroupRecordAbsent
  | GhGroupRecordLoaded [OwnedProcessGroup]
  | GhGroupRecordUnusable Text
  deriving stock (Eq, Show)

instance FromJSON UsageCacheEnvelope where
  parseJSON = withObject "usage cache" $ \cache -> UsageCacheEnvelope <$> cache .: "schemaVersion" <*> cache .: "snapshots"

instance ToJSON UsageCacheEnvelope where
  toJSON envelope =
    object
      [ "schemaVersion" .= envelope.usageSchemaVersion,
        "snapshots" .= envelope.usageSnapshots
      ]

-- | Version 3 added the per-check detail 'CheckSummary' retains for the §11
-- details overlay. A version 2 file decodes its check summaries without that
-- detail, so it is not silently reused.
--
-- Version 4 added the per-item 'Kanban.Domain.DataGap' list. Reusing a
-- version 3 entry would restore a card as though every field had arrived,
-- dropping the amber marker and the warning that explain what is missing.
--
-- Version 5 added the native sub-issue relationships §12 resolves fallback
-- tracker membership from. A version 4 entry carries no answer at all, and
-- restoring one as though GitHub had reported no sub-issues would silently
-- claim native membership was checked and absent -- turning a natively
-- tracked epic back into a warned, childless header. Any older file is
-- treated as absent -- the §16 contract for an unknown schema version.
--
-- Version 6 is the version nothing writes. Open cards are live-only (§13):
-- the dashboard neither loads a repository snapshot at startup nor persists
-- one afterwards. Advancing the constant is what makes a version 5 file an
-- earlier release left behind read as absent by the gate below, rather than
-- being decoded, rewritten, or deleted -- the file is simply never consulted
-- again and stays exactly as it was found.
--
-- 'repositoryCacheSchemaVersion' therefore stays at 6 rather than tracking the
-- newest thing the file may hold: it is not a description of the file, it is
-- the open snapshot reader's gate, and its whole job is to answer "absent" for
-- every version that is not the one open snapshots were last written under.
-- A version 7 file is one of those, which is exactly right -- it holds no open
-- snapshot to read.
--
-- Version 7 is the completed generation, and the first thing to be written to
-- the repository cache path since version 5. It is a new version of that path
-- rather than a new file because the two payloads are alternatives, not
-- companions: only one of them is ever the current meaning of the path, and a
-- single version gate is what keeps a reader of either from decoding the other.
repositoryCacheSchemaVersion, completedCacheSchemaVersion, usageCacheSchemaVersion, ghGroupRecordSchemaVersion :: Int
repositoryCacheSchemaVersion = 6
completedCacheSchemaVersion = 7
usageCacheSchemaVersion = 1
ghGroupRecordSchemaVersion = 1

repositoryCachePath :: Repository -> IO FilePath
repositoryCachePath repository = do
  cacheRoot <- getXdgDirectory XdgCache "kanban"
  pure (cacheRoot </> "repos" </> Text.unpack (safeKey (repositoryIdentity repository)) <> ".json")

usageCachePath :: IO FilePath
usageCachePath = do
  cacheRoot <- getXdgDirectory XdgCache "kanban"
  pure (cacheRoot </> "usage.json")

-- | The file every usage-cache transaction serialises on.
--
-- Separate from @usage.json@ rather than the snapshot file itself, because
-- 'writeCacheFile' replaces that file by renaming a new one over it: a lock
-- taken on the snapshot would be held on an inode the next writer has already
-- replaced, and two processes would find themselves locking different files
-- under one path. This one is only ever created, never replaced, so every
-- process that opens it opens the same inode.
--
-- Nothing reads or writes it: it carries no payload, only the exclusive lock
-- 'commitUsageSnapshots' holds across its read, merge, and write.
usageCacheLockPath :: IO FilePath
usageCacheLockPath = do
  cacheRoot <- getXdgDirectory XdgCache "kanban"
  pure (cacheRoot </> "usage.lock")

ghGroupRecordPath :: Repository -> IO FilePath
ghGroupRecordPath repository = do
  cacheRoot <- getXdgDirectory XdgCache "kanban"
  pure (cacheRoot </> "gh-groups" </> Text.unpack (safeKey (repositoryIdentity repository)) <> ".json")

loadGhGroupRecord :: Repository -> IO GhGroupRecordLoad
loadGhGroupRecord repository = do
  path <- ghGroupRecordPath repository
  exists <- doesFileExist path
  if not exists
    then pure GhGroupRecordAbsent
    else do
      result <- try @IOException (eitherDecodeFileStrict' path :: IO (Either String GhGroupEnvelope))
      pure $ case result of
        Left exception -> GhGroupRecordUnusable ("gh group record unreadable: " <> Text.pack (show exception))
        Right (Left message) -> GhGroupRecordUnusable ("gh group record unreadable: " <> Text.pack message)
        Right (Right envelope)
          | envelope.ghGroupSchemaVersion /= ghGroupRecordSchemaVersion -> GhGroupRecordUnusable "gh group record unreadable: unsupported schema version"
          | envelope.ghGroupRepositoryKey /= repositoryIdentity repository -> GhGroupRecordUnusable "gh group record unreadable: repository identity mismatch"
          | otherwise -> GhGroupRecordLoaded envelope.ghGroupGroups

writeGhGroupRecord :: Repository -> [OwnedProcessGroup] -> IO (Either Text ())
writeGhGroupRecord repository groups = do
  path <- ghGroupRecordPath repository
  writeCacheFile path (GhGroupEnvelope ghGroupRecordSchemaVersion (repositoryIdentity repository) groups)

-- | Drops the record once every group in it has been confirmed gone. A
-- missing file is success: there is nothing left to refuse a fetch over.
removeGhGroupRecord :: Repository -> IO (Either Text ())
removeGhGroupRecord repository = do
  path <- ghGroupRecordPath repository
  result <- try @IOException (doesFileExist path >>= \exists -> when exists (removeFile path))
  pure $ case result of
    Left exception -> Left ("gh group record could not be cleared: " <> Text.pack (show exception))
    Right () -> Right ()

-- | Reads whatever repository snapshot is on disk.
--
-- Nothing in the dashboard calls this any more: open cards are live-only, so
-- startup renders nothing from disk and a successful refresh persists nothing
-- (§13). What it remains is the compatibility gate for a file an earlier
-- release wrote — under the current 'repositoryCacheSchemaVersion' that file
-- reads as absent, and reading it neither decodes its payload nor writes to
-- it.
loadRepositoryCache :: Repository -> IO CacheLoad
loadRepositoryCache repository = do
  path <- repositoryCachePath repository
  exists <- doesFileExist path
  if not exists
    then pure CacheAbsent
    else do
      result <- try @IOException (eitherDecodeFileStrict' path :: IO (Either String Value))
      pure $ case result of
        Left exception -> CacheInvalid ("cache ignored: " <> Text.pack (show exception))
        Right (Left message) -> CacheInvalid ("cache ignored: " <> Text.pack message)
        Right (Right value) -> loadDecodedCache repository value

-- | The schema version is read on its own, before the snapshot is decoded at
-- all. An older file's snapshot no longer matches the current shape, so
-- decoding the whole envelope first would report a JSON parse error where the
-- version gate should have answered.
--
-- §16 makes an unrecognised version absent rather than corrupt: after an
-- upgrade or a downgrade a file the running binary cannot read is expected,
-- and greeting the user with a corruption notice would misdescribe it. Only a
-- file we cannot make sense of at all -- unparseable JSON, no integer version,
-- or a payload that fails under a version we do claim to understand -- keeps
-- the warning.
loadDecodedCache :: Repository -> Value -> CacheLoad
loadDecodedCache repository value = case parse (withObject "cache" (.: "schemaVersion")) value :: Result Int of
  Error message -> CacheInvalid ("cache ignored: " <> Text.pack message)
  Success version
    | version /= repositoryCacheSchemaVersion -> CacheAbsent
    | otherwise -> case fromJSON value :: Result CacheEnvelope of
        Error message -> CacheInvalid ("cache ignored: " <> Text.pack message)
        Success envelope
          | envelope.repositoryKey /= repositoryIdentity repository -> CacheInvalid "cache ignored: repository identity mismatch"
          | otherwise -> CacheLoaded envelope.snapshot

-- | Reads the completed generation an earlier run of this build left behind.
--
-- It shares the repository cache path with the open snapshot an earlier
-- /release/ wrote there, and is told apart from it by the version alone. A
-- file under any other version — including the version 6 gate above, and every
-- version that predates it — is absent here for the same reason a version 7
-- file is absent to 'loadRepositoryCache': neither reader may decode the
-- other's payload, and §16 makes an unrecognised version silent rather than
-- corrupt.
loadCompletedCache :: Repository -> IO CompletedCacheLoad
loadCompletedCache repository = do
  path <- repositoryCachePath repository
  exists <- doesFileExist path
  if not exists
    then pure CompletedCacheAbsent
    else do
      result <- try @IOException (eitherDecodeFileStrict' path :: IO (Either String Value))
      pure $ case result of
        Left exception -> CompletedCacheInvalid ("completed history cache ignored: " <> Text.pack (show exception))
        Right (Left message) -> CompletedCacheInvalid ("completed history cache ignored: " <> Text.pack message)
        Right (Right value) -> loadDecodedCompletedCache repository value

-- | The same version-before-payload gate as 'loadDecodedCache', for the same
-- reason and with the same three outcomes.
loadDecodedCompletedCache :: Repository -> Value -> CompletedCacheLoad
loadDecodedCompletedCache repository value = case parse (withObject "completed history cache" (.: "schemaVersion")) value :: Result Int of
  Error message -> CompletedCacheInvalid ("completed history cache ignored: " <> Text.pack message)
  Success version
    | version /= completedCacheSchemaVersion -> CompletedCacheAbsent
    | otherwise -> case fromJSON value :: Result CompletedCacheEnvelope of
        Error message -> CompletedCacheInvalid ("completed history cache ignored: " <> Text.pack message)
        Success envelope
          | envelope.completedRepositoryKey /= repositoryIdentity repository -> CompletedCacheInvalid "completed history cache ignored: repository identity mismatch"
          | otherwise -> CompletedCacheLoaded envelope.completedHistory

-- | Replaces the stored completed generation with a whole one.
--
-- Only a complete generation ever reaches this, and the replacement is the
-- atomic rename every other cache writer here uses, so an interrupted or
-- failed generation leaves whatever was already stored exactly as it was.
writeCompletedCache :: Repository -> CompletedHistory -> IO (Either Text ())
writeCompletedCache repository history = do
  path <- repositoryCachePath repository
  writeCacheFile path (CompletedCacheEnvelope completedCacheSchemaVersion (repositoryIdentity repository) history)

loadUsageCache :: IO UsageCacheLoad
loadUsageCache = do
  path <- usageCachePath
  exists <- doesFileExist path
  if not exists
    then pure UsageCacheAbsent
    else do
      result <- try @IOException (eitherDecodeFileStrict' path :: IO (Either String Value))
      pure $ case result of
        Left exception -> UsageCacheInvalid ("usage cache ignored: " <> Text.pack (show exception))
        Right (Left message) -> UsageCacheInvalid ("usage cache ignored: " <> Text.pack message)
        Right (Right value) -> loadDecodedUsageCache value

-- | The same version-before-payload gate as 'loadDecodedCache', for the same
-- reason: a usage file from another version is absent, not corrupt, however
-- little of its payload the current decoder recognises.
loadDecodedUsageCache :: Value -> UsageCacheLoad
loadDecodedUsageCache value = case parse (withObject "usage cache" (.: "schemaVersion")) value :: Result Int of
  Error message -> UsageCacheInvalid ("usage cache ignored: " <> Text.pack message)
  Success version
    | version /= usageCacheSchemaVersion -> UsageCacheAbsent
    | otherwise -> case fromJSON value :: Result UsageCacheEnvelope of
        Error message -> UsageCacheInvalid ("usage cache ignored: " <> Text.pack message)
        Success envelope -> UsageCacheLoaded envelope.usageSnapshots

-- | What one usage-cache transaction did.
--
-- The two halves are independent on purpose. 'usageCommitResult' is the
-- write: @kanban --ping@ makes a failed one fatal (section 14), so it may not
-- be blurred into anything advisory. 'usageCommitWarning' is the
-- 'UsageCacheInvalid' reading of the file the merge started from, which stays
-- non-fatal exactly as it is on the @--usage@ and ping load paths -- a corrupt
-- file is warned about and then replaced, not refused. A commit can carry
-- both: a corrupt base whose replacement then failed to land.
data UsageCommit = UsageCommit
  { usageCommitResult :: Either Text (),
    usageCommitWarning :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | A commit's failure and warning flattened into the note list the @--usage@
-- path and the dashboard's notice line both carry.
--
-- Ping does not use it: there the failure is fatal and the warning is not, so
-- the two must stay apart.
usageCommitNotes :: UsageCommit -> [Text]
usageCommitNotes commit =
  either (: []) (const []) commit.usageCommitResult
    <> maybe [] (: []) commit.usageCommitWarning

-- | The one way anything mutates @usage.json@.
--
-- The caller hands over the provider entries it just obtained and nothing
-- else. It never composes the whole stored map, because it cannot have one
-- that is still current: every caller reads the file before it probes a
-- provider, and a probe is exactly the window another Kanban process commits
-- its own refresh in. Merging a map read that long ago is how a successful
-- refresh in one process was reverted by another (issue #477).
--
-- So the map the merge happens against is read here, inside an exclusive
-- cross-process lock on 'usageCacheLockPath', and the merged result is written
-- before the lock is released. Two processes committing different providers
-- therefore serialise, each observing what the other committed, and both
-- entries survive.
--
-- The lock spans the read, the merge, and the write and nothing else. No
-- provider probe, subprocess, or redraw happens under it, so a hung provider
-- in one process cannot block another process's commit.
--
-- Establishing the transaction is not optional. A lock that cannot be taken
-- fails the commit in the same @cache write failed: ...@ shape a failed write
-- has always used; it never degrades into the unsynchronised whole-file
-- replacement this exists to remove.
commitUsageSnapshots :: Map UsageProvider UsageSnapshot -> IO UsageCommit
commitUsageSnapshots fresh = do
  path <- usageCachePath
  lockPath <- usageCacheLockPath
  opened <- try @IOException (createPrivateDirectory XdgCache (takeDirectory path) >> openUsageCacheLock lockPath)
  case opened of
    Left exception -> pure (transactionFailed "could not be established" (Text.pack (show exception)))
    Right handle -> (`finally` hClose handle) $ do
      taken <- takeExclusiveLock handle
      case taken of
        Left message -> pure (transactionFailed "could not be established" message)
        Right () -> (`finally` hUnlock handle) $ do
          committed <- readCommittedUsage path
          case committed of
            Left exception -> pure (transactionFailed "found the stored usage cache unreadable" (Text.pack (show exception)))
            Right (base, warning) -> do
              written <- writeCacheFile path (UsageCacheEnvelope usageCacheSchemaVersion (mergeUsageSnapshots fresh base))
              pure (UsageCommit written warning)
  where
    -- The one wording every way of failing to complete the transaction is
    -- reported in, so a caller that only knows "the cache write failed" is
    -- never told anything else and a reader of the message still learns which
    -- step gave way.
    transactionFailed what detail =
      UsageCommit (Left ("cache write failed: usage cache transaction " <> what <> ": " <> detail)) Nothing

-- | Merges freshly obtained provider entries onto the committed map.
--
-- A provider the caller says nothing about keeps its committed entry
-- untouched -- that is the promise sections 14 and 16 make, and the reason a
-- caller submits only what it obtained.
--
-- A provider the caller does name replaces its committed entry only when the
-- incoming snapshot is not older by 'usageFetchedAt'. Equal timestamps take
-- the incoming one: two snapshots of the same instant describe the same
-- windows, and preferring the stored one would make a first write to an
-- entry's own timestamp behave differently from a rewrite of it. A strictly
-- older snapshot -- a slow probe in one process landing after a quick one in
-- another -- leaves the committed entry alone.
mergeUsageSnapshots :: Map UsageProvider UsageSnapshot -> Map UsageProvider UsageSnapshot -> Map UsageProvider UsageSnapshot
mergeUsageSnapshots fresh committed = Map.foldrWithKey accept committed fresh
  where
    accept provider snapshot = Map.insertWith notOlder provider snapshot
    notOlder incoming existing
      | incoming.usageFetchedAt < existing.usageFetchedAt = existing
      | otherwise = incoming

-- | The committed map as the merge must see it, with the three readings the
-- transaction has to keep apart.
--
-- A file that is not there is an empty base and says nothing: that is the
-- ordinary first commit. A file this build does not claim to understand is the
-- same silence 'loadUsageCache' gives it, for the same reason -- the version
-- gate, not the decoder, decides.
--
-- A file that /is/ there and cannot be read at all is neither. Treating an I\/O
-- failure as an empty base would merge onto nothing and replace a stored map
-- whose contents are still unknown, which is the lost update in a different
-- costume, so it fails the commit instead. A file that reads but does not
-- decode is corruption: the warning 'loadUsageCache' already gives it, and the
-- merged result then replaces it.
readCommittedUsage :: FilePath -> IO (Either IOException (Map UsageProvider UsageSnapshot, Maybe Text))
readCommittedUsage path = do
  contents <- try @IOException (ByteString.readFile path)
  pure $ case contents of
    Left exception
      | isDoesNotExistError exception -> Right (Map.empty, Nothing)
      | otherwise -> Left exception
    Right bytes -> Right $ case eitherDecodeStrict' bytes :: Either String Value of
      Left message -> (Map.empty, Just ("usage cache ignored: " <> Text.pack message))
      Right value -> case loadDecodedUsageCache value of
        UsageCacheAbsent -> (Map.empty, Nothing)
        UsageCacheInvalid message -> (Map.empty, Just message)
        UsageCacheLoaded snapshots -> (snapshots, Nothing)

-- | Opens the lock file, creating it private.
--
-- The mode is forced on every acquisition rather than at creation alone: an
-- @O_CREAT@ mode is still reduced by the process umask, and a file an earlier
-- release or a stray umask left at another mode is not re-created by the open
-- that finds it. It is set through the descriptor rather than the path so a
-- concurrent process replacing the name cannot receive the chmod.
--
-- Close-on-exec is set because a leaked descriptor keeps the lock: a
-- @flock@ belongs to the open file description, which @fork@ shares, so a
-- child spawned while the lock is held would hold it for its own lifetime --
-- and this process spawns long-lived agents.
openUsageCacheLock :: FilePath -> IO Handle
openUsageCacheLock path = do
  descriptor <- openFd path ReadWrite defaultFileFlags {creat = Just 0o600, cloexec = True}
  (setFdMode descriptor 0o600 >> fdToHandle descriptor) `onException` closeFd descriptor

-- | Takes the exclusive lock, reporting rather than throwing.
--
-- A platform with no file locking at all is reported like any other failure to
-- establish the transaction, because that is what it is. Falling through to an
-- unsynchronised write there would restore the defect on exactly the platform
-- that cannot be protected from it.
takeExclusiveLock :: Handle -> IO (Either Text ())
takeExclusiveLock handle =
  ((Right <$> hLock handle ExclusiveLock) `catch` (\exception -> pure (Left (Text.pack (show (exception :: IOException))))))
    `catch` (\exception -> pure (Left (Text.pack (show (exception :: FileLockingNotSupported)))))

writeCacheFile :: ToJSON value => FilePath -> value -> IO (Either Text ())
writeCacheFile path value = do
  let directory = takeDirectory path
  result <- try @IOException $ do
    createPrivateDirectory XdgCache directory
    bracketOnError
      (openBinaryTempFile directory (takeFileName path <> ".tmp"))
      cleanupTemporaryFile
      (\(temporaryPath, handle) -> do
         LazyByteString.hPut handle (encode value)
         hClose handle
         setFileMode temporaryPath 0o600
         renameFile temporaryPath path
         setFileMode path 0o600
      )
  pure $ case result of
    Left exception -> Left ("cache write failed: " <> Text.pack (show exception))
    Right () -> Right ()

cleanupTemporaryFile :: (FilePath, Handle) -> IO ()
cleanupTemporaryFile (temporaryPath, handle) = do
  _ <- try @IOException (hClose handle)
  _ <- try @IOException (removeFile temporaryPath)
  pure ()

repositoryIdentity :: Repository -> Text
repositoryIdentity repository = repository.repositoryOwner <> "/" <> repository.repositoryName

safeKey :: Text -> Text
safeKey = Text.map replace
  where
    replace character
      | character `elem` ['/', '\\', ':'] = '-'
      | otherwise = character
