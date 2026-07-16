{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

module Kanban.Cache
  ( CacheLoad (..),
    loadRepositoryCache,
    repositoryCachePath,
    writeRepositoryCache,
  )
where

import Control.Exception (IOException, bracketOnError, try)
import Data.Aeson (FromJSON, ToJSON, eitherDecodeFileStrict', encode)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import Kanban.Domain (RepoSnapshot, Repository (..))
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

data CacheEnvelope = CacheEnvelope
  { schemaVersion :: Int,
    repositoryKey :: Text,
    snapshot :: RepoSnapshot
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

cacheSchemaVersion :: Int
cacheSchemaVersion = 1

repositoryCachePath :: Repository -> IO FilePath
repositoryCachePath repository = do
  cacheRoot <- getXdgDirectory XdgCache "kanban"
  pure (cacheRoot </> "repos" </> Text.unpack (safeKey (repositoryIdentity repository)) <> ".json")

loadRepositoryCache :: Repository -> IO CacheLoad
loadRepositoryCache repository = do
  path <- repositoryCachePath repository
  exists <- doesFileExist path
  if not exists
    then pure CacheAbsent
    else do
      result <- try @IOException (eitherDecodeFileStrict' path :: IO (Either String CacheEnvelope))
      pure $ case result of
        Left exception -> CacheInvalid ("cache ignored: " <> Text.pack (show exception))
        Right (Left message) -> CacheInvalid ("cache ignored: " <> Text.pack message)
        Right (Right envelope)
          | envelope.schemaVersion /= cacheSchemaVersion -> CacheInvalid "cache ignored: unsupported schema version"
          | envelope.repositoryKey /= repositoryIdentity repository -> CacheInvalid "cache ignored: repository identity mismatch"
          | otherwise -> CacheLoaded envelope.snapshot

writeRepositoryCache :: Repository -> RepoSnapshot -> IO (Either Text ())
writeRepositoryCache repository repoSnapshot = do
  path <- repositoryCachePath repository
  let directory = takeDirectory path
      envelope = CacheEnvelope cacheSchemaVersion (repositoryIdentity repository) repoSnapshot
  result <- try @IOException $ do
    createDirectoryIfMissing True directory
    setFileMode directory 0o700
    bracketOnError
      (openBinaryTempFile directory (takeFileName path <> ".tmp"))
      cleanupTemporaryFile
      (\(temporaryPath, handle) -> do
         LazyByteString.hPut handle (encode envelope)
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
