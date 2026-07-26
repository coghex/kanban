{-# LANGUAGE DeriveGeneric #-}

module Kanban.Settings
  ( ChatVerbosity (..),
    Settings (..),
    defaultSettings,
    loadSettings,
    saveSettings,
    settingsPath,
    verbosityDescription,
    verbosityLabel,
  )
where

import Control.Exception (IOException, bracketOnError, try)
import Data.Aeson (FromJSON (..), Result (..), ToJSON (..), Value, eitherDecodeFileStrict', encode, fromJSON, object, withObject, (.:), (.:?), (.!=), (.=))
import Data.Aeson.Types (parse)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import Kanban.Paths (createPrivateDirectory)
import System.Directory (XdgDirectory (XdgConfig), doesFileExist, getXdgDirectory, removeFile, renameFile)
import System.FilePath ((</>), takeDirectory, takeFileName)
import System.IO (Handle, hClose, openBinaryTempFile)
import System.Posix.Files (setFileMode)

data ChatVerbosity = CompactChat | StandardChat | FullChat
  deriving stock (Eq, Ord, Show, Generic)

data Settings = Settings
  { settingsChatVerbosity :: ChatVerbosity
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON ChatVerbosity where
  parseJSON value = do
    name <- parseJSON value
    case Text.toCaseFold name of
      "compact" -> pure CompactChat
      "standard" -> pure StandardChat
      "full" -> pure FullChat
      _ -> fail "chat verbosity must be compact, standard, or full"

instance ToJSON ChatVerbosity where
  toJSON CompactChat = toJSON ("compact" :: Text)
  toJSON StandardChat = toJSON ("standard" :: Text)
  toJSON FullChat = toJSON ("full" :: Text)

instance FromJSON Settings where
  parseJSON = withObject "Kanban settings" $ \value ->
    Settings <$> value .:? "chatVerbosity" .!= StandardChat

instance ToJSON Settings where
  toJSON settings = object ["schemaVersion" .= settingsSchemaVersion, "chatVerbosity" .= settings.settingsChatVerbosity]

-- | The version 'ToJSON' stamps on every file written, and the only one
-- 'loadSettings' reads. Emitting it without ever checking it left a future
-- format bump no mechanism at all.
settingsSchemaVersion :: Int
settingsSchemaVersion = 1

defaultSettings :: Settings
defaultSettings = Settings {settingsChatVerbosity = StandardChat}

verbosityLabel :: ChatVerbosity -> Text
verbosityLabel CompactChat = "Compact"
verbosityLabel StandardChat = "Standard"
verbosityLabel FullChat = "Full"

verbosityDescription :: ChatVerbosity -> Text
verbosityDescription CompactChat = "Agent messages and short tool status"
verbosityDescription StandardChat = "Reasoning summaries, commands, tool inputs, and concise results"
verbosityDescription FullChat = "Every formatted detail emitted by the provider"

settingsPath :: IO FilePath
settingsPath = do
  configRoot <- getXdgDirectory XdgConfig "kanban"
  pure (configRoot </> "settings.json")

loadSettings :: IO (Settings, Maybe Text)
loadSettings = do
  path <- settingsPath
  exists <- doesFileExist path
  if not exists
    then pure (defaultSettings, Nothing)
    else do
      result <- try @IOException (eitherDecodeFileStrict' path :: IO (Either String Value))
      pure $ case result of
        Left exception -> (defaultSettings, Just ("settings ignored: " <> Text.pack (show exception)))
        Right (Left message) -> (defaultSettings, Just ("settings ignored: " <> Text.pack message))
        Right (Right value) -> loadDecodedSettings value

-- | The same version-before-payload rule the caches follow: a file written by
-- another version of the format is not something the user needs to hear
-- about, so it silently yields the defaults whatever its payload looks like.
-- A file that claims the current version and still will not decode, or that
-- carries no integer version at all, keeps the existing warning.
loadDecodedSettings :: Value -> (Settings, Maybe Text)
loadDecodedSettings value = case parse (withObject "Kanban settings" (.: "schemaVersion")) value :: Result Int of
  Error message -> (defaultSettings, Just ("settings ignored: " <> Text.pack message))
  Success version
    | version /= settingsSchemaVersion -> (defaultSettings, Nothing)
    | otherwise -> case fromJSON value :: Result Settings of
        Error message -> (defaultSettings, Just ("settings ignored: " <> Text.pack message))
        Success settings -> (settings, Nothing)

saveSettings :: Settings -> IO (Either Text ())
saveSettings settings = do
  path <- settingsPath
  let directory = takeDirectory path
  result <- try @IOException $ do
    createPrivateDirectory XdgConfig directory
    bracketOnError
      (openBinaryTempFile directory (takeFileName path <> ".tmp"))
      cleanup
      (\(temporaryPath, handle) -> do
         LazyByteString.hPut handle (encode settings)
         hClose handle
         setFileMode temporaryPath 0o600
         renameFile temporaryPath path
         setFileMode path 0o600
      )
  pure $ case result of
    Left exception -> Left ("settings write failed: " <> Text.pack (show exception))
    Right () -> Right ()

cleanup :: (FilePath, Handle) -> IO ()
cleanup (path, handle) = do
  _ <- try @IOException (hClose handle)
  _ <- try @IOException (removeFile path)
  pure ()
