{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

module Kanban.Cache
  ( CacheLoad (..),
    CompletedCacheLoad (..),
    GhGroupRecordLoad (..),
    UsageCacheLoad (..),
    UsageCommit (..),
    canonicalRepositoryKey,
    commitUsageSnapshots,
    completedCacheSchemaVersion,
    ghGroupRecordPath,
    ghGroupRecordSchemaVersion,
    legacyGhGroupRecordCandidates,
    loadCompletedCache,
    loadGhGroupRecord,
    loadRepositoryCache,
    loadUsageCache,
    mergeGhGroups,
    mergeUsageSnapshots,
    migrateGhGroupRecord,
    normalizedRepositoryIdentity,
    removeGhGroupRecord,
    repositoryCachePath,
    repositoryCacheSchemaVersion,
    repositoryLeasePath,
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
    doesDirectoryExist,
    doesFileExist,
    getXdgDirectory,
    listDirectory,
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

-- | The one durable key a repository's board authority is spelled with.
--
-- @safeKey@ over @owner\/name@, which every other durable path here still
-- uses, is neither canonical nor injective, and the @gh@ record is the one
-- path where being both is load-bearing:
--
--   * It preserves case, so @Coghex\/Kanban@ and @coghex\/kanban@ -- one
--     GitHub repository, since GitHub's identity is case-insensitive -- resolve
--     two files, and a board opened under the second spelling would miss a
--     possibly-live @gh@ the first recorded.
--   * It replaces @\/@ with @-@ without escaping the @-@ already there, so
--     @coghex-kan\/ban@ and @coghex\/kan-ban@ -- two distinct repositories --
--     resolve one file and would contend over each other's entries.
--
-- ASCII-lowercasing closes the first: it is exactly the equality
-- @docs\/multi_repo_boards_design.md@ D-10 selects for repository identity.
-- @%2F@ closes the second: 'Kanban.Repository.isIdentityCharacter' admits only
-- ASCII letters, digits, @.@, @_@ and @-@ inside an owner or a name, so @%@
-- cannot occur in either component and the separator cannot be forged from
-- one. The mapping is therefore injective over every identity Kanban accepts,
-- and it cannot collide with a legacy basename either, for the same reason.
--
-- Deliberately not applied to 'repositoryCachePath', the worker directories,
-- or anything else: those are snapshots and scratch state, where two spellings
-- resolving two files costs a refetch rather than an unaccounted process.
canonicalRepositoryKey :: Repository -> Text
canonicalRepositoryKey repository =
  asciiLowercase repository.repositoryOwner <> "%2F" <> asciiLowercase repository.repositoryName

-- | The @owner\/name@ a record envelope carries and ownership is decided by.
--
-- The same ASCII-lowercasing 'canonicalRepositoryKey' applies, so the envelope
-- agrees with the path it is written at rather than recording whichever
-- spelling the invocation happened to use.
normalizedRepositoryIdentity :: Repository -> Text
normalizedRepositoryIdentity repository =
  asciiLowercase repository.repositoryOwner <> "/" <> asciiLowercase repository.repositoryName

-- | ASCII case folding, and only ASCII.
--
-- 'Data.Text.toLower' is Unicode-aware, which is the wrong tool for an
-- identity GitHub compares as ASCII: it would fold characters the repository
-- grammar does not admit anyway, and a locale-sensitive fold has no business
-- deciding which file a durable record lives at.
asciiLowercase :: Text -> Text
asciiLowercase = Text.map fold
  where
    fold character
      | character >= 'A' && character <= 'Z' = toEnum (fromEnum character + 32)
      | otherwise = character

-- | The directory the @gh@ record and the lease that guards it share.
ghGroupDirectory :: IO FilePath
ghGroupDirectory = do
  cacheRoot <- getXdgDirectory XdgCache "kanban"
  pure (cacheRoot </> "gh-groups")

-- | The one derivation both of the repository's authority paths come from.
--
-- Written once rather than twice because the record and the lease are only
-- coherent while they name the same repository by the same rule: a lease keyed
-- differently from the record it protects would guard a file nobody else was
-- writing.
ghGroupPath :: Repository -> String -> IO FilePath
ghGroupPath repository extension = do
  directory <- ghGroupDirectory
  pure (directory </> (Text.unpack (canonicalRepositoryKey repository) <> extension))

ghGroupRecordPath :: Repository -> IO FilePath
ghGroupRecordPath repository = ghGroupPath repository ".json"

-- | The file one repository's cross-process authority is taken on.
--
-- Keyed by the repository's identity, so two boards on one repository resolve
-- one file and two repositories resolve two: the authority this path carries
-- is over a repository, never over the machine (issue #354 keys per repository
-- for the same reason).
--
-- Its own file rather than 'ghGroupRecordPath', and for the same reason
-- 'usageCacheLockPath' is not @usage.json@, only stronger here. A POSIX record
-- lock is released when the holding process closes /any/ descriptor referring
-- to the file, so a lock taken on the record would be dropped by the next
-- ordinary read or write of it -- including 'writeCacheFile' renaming a new
-- file over the name, which would leave two processes locking different
-- inodes under one path. This one carries no payload: nothing reads it,
-- nothing writes it, and nothing but the lease opens it.
--
-- It sits beside the record rather than under a directory of its own so that
-- one key, one derivation and one directory cover the pair.
repositoryLeasePath :: Repository -> IO FilePath
repositoryLeasePath repository = ghGroupPath repository ".lock"

-- | The basename a release before the canonical key wrote this repository's
-- record at, spelled from the normalized identity.
--
-- Compared case-insensitively by 'legacyGhGroupRecordCandidates', which is
-- what makes a record written under @Coghex\/Kanban@ discoverable by a board
-- opened as @coghex\/kanban@.
legacyGhGroupRecordName :: Repository -> Text
legacyGhGroupRecordName repository = safeKey (normalizedRepositoryIdentity repository) <> ".json"

-- | Every flat @.json@ file in the @gh@ record directory that a release
-- predating the canonical key could have written for this repository.
--
-- Deliberately a basename comparison rather than a decode: the file has to be
-- /found/ before anything can be said about what is in it, and the old key was
-- lossy, so a match here means "this could be ours" and never "this is
-- ours". 'migrateGhGroupRecord' settles that from the envelope.
--
-- Two things this must not do, both of which would be safe-looking mistakes:
--
--   * It never opens a @.lock@. A POSIX record lock is released the moment the
--     holding process closes /any/ descriptor on the file, so a scan that
--     opened this repository's own lease file would silently drop the
--     authority the caller had just acquired. The comparison is against a
--     whole @.json@ basename, which no lease file can match.
--   * It never descends. The old layout was flat, so a directory entry that is
--     not a file is not a record this project wrote -- but it is also not
--     something that can be proved to hold no live group, so it is offered as
--     a candidate and fails the decode, rather than being skipped quietly.
legacyGhGroupRecordCandidates :: Repository -> IO (Either Text [FilePath])
legacyGhGroupRecordCandidates repository = do
  directory <- ghGroupDirectory
  canonical <- ghGroupRecordPath repository
  present <- doesDirectoryExist directory
  if not present
    then pure (Right [])
    else do
      listed <- try @IOException (listDirectory directory)
      pure $ case listed of
        Left exception ->
          Left ("the gh group record directory " <> Text.pack directory <> " could not be read: " <> Text.pack (show exception))
        Right names ->
          Right
            [ candidate
              | name <- names,
                asciiLowercase (Text.pack name) == asciiLowercase (legacyGhGroupRecordName repository),
                let candidate = directory </> name,
                candidate /= canonical
            ]

-- | Brings every @gh@ group a release before the canonical key recorded for
-- this repository under the canonical record, and clears the files it took
-- them from.
--
-- Run once, by the dashboard that holds the repository's lease, before the
-- first refresh. Under the lease no other board can be writing either file,
-- which is what makes a read-merge-write across two paths safe at all.
--
-- The order is the whole safety argument. Canonical state is written -- and
-- the write reported success through 'writeCacheFile', whose rename is atomic
-- -- before any legacy file is unlinked, and a legacy file is unlinked only
-- once every entry it held is in that canonical state. An interruption
-- anywhere therefore leaves at worst two discoverable copies of an entry,
-- which the next run merges away, and never zero copies of a @gh@ that may
-- still be running.
--
-- 'Left' fails startup. Two cases reach it, and both are the same judgement:
-- a candidate that could be this repository's and cannot be read is a file
-- that cannot be shown to hold no live group, and a canonical record in that
-- state cannot be merged into without discarding whatever it holds. 'Right'
-- carries notices for what went wrong without threatening an entry -- a legacy
-- file that would not unlink is one, since its contents are by then also
-- canonical and the next run will simply merge and try again.
migrateGhGroupRecord :: Repository -> IO (Either Text [Text])
migrateGhGroupRecord repository = do
  discovered <- legacyGhGroupRecordCandidates repository
  case discovered of
    Left message -> pure (Left message)
    Right [] -> pure (Right [])
    Right candidates -> do
      canonicalLoad <- loadGhGroupRecord repository
      canonical <- ghGroupRecordPath repository
      case canonicalLoad of
        GhGroupRecordUnusable message ->
          pure
            ( Left
                ( "the gh group record at "
                    <> Text.pack canonical
                    <> " cannot be read ("
                    <> message
                    <> "), so an older record beside it cannot be merged into it; remove or repair that file and start again"
                )
            )
        _ -> do
          let existing = case canonicalLoad of
                GhGroupRecordLoaded groups -> groups
                _ -> []
          readings <- traverse (readLegacyGhGroupRecord repository) candidates
          case sequence readings of
            Left message -> pure (Left message)
            Right owned -> do
              let ours = [(path, groups) | (path, Just groups) <- zip candidates owned]
                  merged = foldl mergeGhGroups existing (map snd ours)
              written <-
                if merged == existing
                  then pure (Right ())
                  else writeGhGroupRecord repository merged
              case written of
                Left message ->
                  pure
                    ( Left
                        ( "an older gh group record could not be brought under "
                            <> Text.pack canonical
                            <> " ("
                            <> message
                            <> "), so it was left where it is"
                        )
                    )
                Right () -> Right . concat <$> traverse (clearLegacyGhGroupRecord . fst) ours

-- | One legacy candidate, resolved into this repository's entries, somebody
-- else's file, or a refusal.
--
-- The envelope decides ownership, not the path: the old key was lossy, so a
-- basename match is exactly as much evidence as a collision would produce.
-- @Nothing@ is a readable version-1 record naming a different repository --
-- left alone, contributing nothing, and never unlinked.
readLegacyGhGroupRecord :: Repository -> FilePath -> IO (Either Text (Maybe [OwnedProcessGroup]))
readLegacyGhGroupRecord repository path = do
  decoded <- try @IOException (eitherDecodeFileStrict' path :: IO (Either String GhGroupEnvelope))
  pure $ case decoded of
    Left exception -> Left (unreadable (Text.pack (show exception)))
    Right (Left message) -> Left (unreadable (Text.pack message))
    Right (Right envelope)
      | envelope.ghGroupSchemaVersion /= ghGroupRecordSchemaVersion -> Left (unreadable "unsupported schema version")
      | asciiLowercase envelope.ghGroupRepositoryKey == normalizedRepositoryIdentity repository -> Right (Just envelope.ghGroupGroups)
      | otherwise -> Right Nothing
  where
    -- Names the file and says what clears the refusal. This one happens before
    -- Brick draws, so §17 renders no notice that could carry the repair, and a
    -- startup message that only announced a wedge would leave the board
    -- unopenable with nothing to act on.
    unreadable detail =
      "an older gh group record at "
        <> Text.pack path
        <> " may belong to this repository and cannot be read ("
        <> detail
        <> "); Kanban cannot rule out a gh still running from it, so remove or repair that file and start again"

-- | Adds entries to a record without losing one.
--
-- Exact equality is the only duplicate. Two entries that share a pgid but
-- differ in members or in whether they were censused are two different claims
-- about that group, and a pgid-keyed merge would silently drop one of them --
-- including the censused one, whose members are what make the group killable
-- at all. Keeping both is coherent because reclaim verifies every entry
-- independently and clears the record only once all of them are accounted for.
mergeGhGroups :: [OwnedProcessGroup] -> [OwnedProcessGroup] -> [OwnedProcessGroup]
mergeGhGroups = foldl add
  where
    add accumulated group
      | group `elem` accumulated = accumulated
      | otherwise = accumulated <> [group]

-- | Unlinks one migrated legacy record, reporting rather than failing.
--
-- Its entries are canonical by the time this runs, so a file that will not
-- unlink threatens nothing: the next start merges it again, finds every entry
-- already present, writes nothing, and tries the unlink once more. Failing
-- startup over it would wedge the board out of an unopenable state for a
-- reason that costs nothing to carry.
clearLegacyGhGroupRecord :: FilePath -> IO [Text]
clearLegacyGhGroupRecord path = do
  removed <- try @IOException (removeFile path)
  pure $ case removed of
    Left exception ->
      ["an older gh group record at " <> Text.pack path <> " was merged but could not be removed (" <> Text.pack (show exception) <> ")"]
    Right () -> []

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
          -- Case-folded, because the envelope may have been written by a
          -- release that recorded whichever spelling the invocation used --
          -- and, since 'migrateGhGroupRecord' rewrites such a record at the
          -- canonical path, that spelling can be sitting at this path right
          -- now. Comparing exactly would read the board's own migrated record
          -- as somebody else's.
          | asciiLowercase envelope.ghGroupRepositoryKey /= normalizedRepositoryIdentity repository -> GhGroupRecordUnusable "gh group record unreadable: repository identity mismatch"
          | otherwise -> GhGroupRecordLoaded envelope.ghGroupGroups

writeGhGroupRecord :: Repository -> [OwnedProcessGroup] -> IO (Either Text ())
writeGhGroupRecord repository groups = do
  path <- ghGroupRecordPath repository
  -- The normalized identity rather than the resolved spelling: the envelope
  -- and the path it lives at have to agree about which repository this is, and
  -- the path is canonical.
  writeCacheFile path (GhGroupEnvelope ghGroupRecordSchemaVersion (normalizedRepositoryIdentity repository) groups)

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
