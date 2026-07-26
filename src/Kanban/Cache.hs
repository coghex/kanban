{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

module Kanban.Cache
  ( CacheLoad (..),
    GhGroupRecordLoad (..),
    UsageCacheLoad (..),
    ghGroupRecordPath,
    loadGhGroupRecord,
    loadRepositoryCache,
    loadUsageCache,
    removeGhGroupRecord,
    repositoryCachePath,
    repositoryCacheSchemaVersion,
    usageCachePath,
    writeGhGroupRecord,
    writeRepositoryCache,
    writeUsageCache,
  )
where

import Control.Exception (IOException, bracketOnError, try)
import Control.Monad (when)
import Data.Aeson
  ( FromJSON (parseJSON),
    Result (..),
    ToJSON (toJSON),
    Value,
    eitherDecodeFileStrict',
    encode,
    fromJSON,
    object,
    withObject,
    (.:),
    (.=),
  )
import Data.Aeson.Types (parse)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import Kanban.Domain (RepoSnapshot, Repository (..), UsageProvider, UsageSnapshot)
import Kanban.Process (OwnedProcessGroup)
import System.Directory
  ( XdgDirectory (XdgCache),
    createDirectoryIfMissing,
    doesFileExist,
    getXdgDirectory,
    removeFile,
    renameFile,
  )
import System.FilePath ((</>), takeDirectory, takeFileName)
import System.IO (Handle, hClose, openBinaryTempFile)
import System.Posix.Files (setFileMode)

data CacheLoad
  = CacheAbsent
  | CacheLoaded RepoSnapshot
  | CacheInvalid Text
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
-- detail, so it is rejected as unsupported rather than silently reused.
--
-- Version 4 added the per-item 'Kanban.Domain.DataGap' list. Reusing a
-- version 3 entry would restore a card as though every field had arrived,
-- dropping the amber marker and the warning that explain what is missing, so
-- an older file is treated as absent -- the §17 contract for an unknown
-- schema version -- and the next refresh rebuilds it.
repositoryCacheSchemaVersion, usageCacheSchemaVersion, ghGroupRecordSchemaVersion :: Int
repositoryCacheSchemaVersion = 4
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
-- version gate should have said the schema is unsupported.
loadDecodedCache :: Repository -> Value -> CacheLoad
loadDecodedCache repository value = case parse (withObject "cache" (.: "schemaVersion")) value :: Result Int of
  Error message -> CacheInvalid ("cache ignored: " <> Text.pack message)
  Success version
    | version /= repositoryCacheSchemaVersion -> CacheInvalid "cache ignored: unsupported schema version"
    | otherwise -> case fromJSON value :: Result CacheEnvelope of
        Error message -> CacheInvalid ("cache ignored: " <> Text.pack message)
        Success envelope
          | envelope.repositoryKey /= repositoryIdentity repository -> CacheInvalid "cache ignored: repository identity mismatch"
          | otherwise -> CacheLoaded envelope.snapshot

loadUsageCache :: IO UsageCacheLoad
loadUsageCache = do
  path <- usageCachePath
  exists <- doesFileExist path
  if not exists
    then pure UsageCacheAbsent
    else do
      result <- try @IOException (eitherDecodeFileStrict' path :: IO (Either String UsageCacheEnvelope))
      pure $ case result of
        Left exception -> UsageCacheInvalid ("usage cache ignored: " <> Text.pack (show exception))
        Right (Left message) -> UsageCacheInvalid ("usage cache ignored: " <> Text.pack message)
        Right (Right envelope)
          | envelope.usageSchemaVersion /= usageCacheSchemaVersion -> UsageCacheInvalid "usage cache ignored: unsupported schema version"
          | otherwise -> UsageCacheLoaded envelope.usageSnapshots

writeRepositoryCache :: Repository -> RepoSnapshot -> IO (Either Text ())
writeRepositoryCache repository repoSnapshot = do
  path <- repositoryCachePath repository
  let envelope = CacheEnvelope repositoryCacheSchemaVersion (repositoryIdentity repository) repoSnapshot
  writeCacheFile path envelope

writeUsageCache :: Map UsageProvider UsageSnapshot -> IO (Either Text ())
writeUsageCache snapshots = do
  path <- usageCachePath
  writeCacheFile path (UsageCacheEnvelope usageCacheSchemaVersion snapshots)

writeCacheFile :: ToJSON value => FilePath -> value -> IO (Either Text ())
writeCacheFile path value = do
  let directory = takeDirectory path
  result <- try @IOException $ do
    createDirectoryIfMissing True directory
    setFileMode directory 0o700
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
