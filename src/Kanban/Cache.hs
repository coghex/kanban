{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

module Kanban.Cache
  ( CacheLoad (..),
    UsageCacheLoad (..),
    loadRepositoryCache,
    loadUsageCache,
    repositoryCachePath,
    repositoryCacheSchemaVersion,
    usageCachePath,
    writeRepositoryCache,
    writeUsageCache,
  )
where

import Control.Exception (IOException, bracketOnError, try)
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
repositoryCacheSchemaVersion, usageCacheSchemaVersion :: Int
repositoryCacheSchemaVersion = 3
usageCacheSchemaVersion = 1

repositoryCachePath :: Repository -> IO FilePath
repositoryCachePath repository = do
  cacheRoot <- getXdgDirectory XdgCache "kanban"
  pure (cacheRoot </> "repos" </> Text.unpack (safeKey (repositoryIdentity repository)) <> ".json")

usageCachePath :: IO FilePath
usageCachePath = do
  cacheRoot <- getXdgDirectory XdgCache "kanban"
  pure (cacheRoot </> "usage.json")

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
