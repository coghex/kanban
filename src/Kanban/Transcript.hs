module Kanban.Transcript
  ( SessionLog,
    closeSessionLog,
    logMessage,
    logRawLine,
    openSessionLog,
    sessionLogPath,
    transcriptRoot,
  )
where

import Control.Concurrent (MVar, newMVar, withMVar)
import Control.Exception (IOException, try)
import Data.Aeson (Value, encode, object, (.=))
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Kanban.Domain (Repository (..))
import System.Directory (XdgDirectory (XdgCache), createDirectoryIfMissing, getXdgDirectory)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), Handle, IOMode (AppendMode), hClose, hSetBuffering, openBinaryFile)
import System.Posix.Files (setFileMode)
import System.Posix.Process (getProcessID)

data SessionLog = SessionLog
  { sessionLogPath :: FilePath,
    sessionLogHandle :: Handle,
    sessionLogLock :: MVar ()
  }

transcriptRoot :: Repository -> IO FilePath
transcriptRoot repository = do
  cacheRoot <- getXdgDirectory XdgCache "kanban"
  pure (cacheRoot </> "logs" </> Text.unpack (safeKey (repository.repositoryOwner <> "-" <> repository.repositoryName)))

openSessionLog :: Repository -> Text -> Int -> Maybe FilePath -> IO (Either Text SessionLog)
openSessionLog repository category itemNumber existingPath = do
  result <- try @IOException $ do
    directory <- transcriptRoot repository
    createDirectoryIfMissing True directory
    setFileMode directory 0o700
    path <- case existingPath of
      Just value -> pure value
      Nothing -> do
        now <- getCurrentTime
        processId <- getProcessID
        let timestamp = formatTime defaultTimeLocale "%Y%m%dT%H%M%S%q" now
        pure (directory </> Text.unpack (safeKey category) <> "-" <> show itemNumber <> "-" <> timestamp <> "-" <> show processId <> ".jsonl")
    handle <- openBinaryFile path AppendMode
    hSetBuffering handle LineBuffering
    setFileMode path 0o600
    lock <- newMVar ()
    pure (SessionLog path handle lock)
  pure $ case result of
    Left exception -> Left ("could not open full session log: " <> Text.pack (show exception))
    Right sessionLog -> Right sessionLog

logRawLine :: SessionLog -> Text -> ByteString.ByteString -> IO ()
logRawLine sessionLog stream bytes = do
  timestamp <- timestampText
  appendRecord
    sessionLog
    ( object
        [ "timestamp" .= timestamp,
          "stream" .= stream,
          "raw" .= TextEncoding.decodeUtf8With lenientDecode bytes
        ]
    )

logMessage :: SessionLog -> Text -> Text -> IO ()
logMessage sessionLog event message = do
  timestamp <- timestampText
  appendRecord sessionLog (object ["timestamp" .= timestamp, "stream" .= ("kanban" :: Text), "event" .= event, "message" .= message])

closeSessionLog :: SessionLog -> IO ()
closeSessionLog sessionLog = withMVar sessionLog.sessionLogLock (const (hClose sessionLog.sessionLogHandle))

appendRecord :: SessionLog -> Value -> IO ()
appendRecord sessionLog value =
  withMVar sessionLog.sessionLogLock $ \() -> do
    LazyByteString.hPut sessionLog.sessionLogHandle (encode value)
    LazyByteString.hPut sessionLog.sessionLogHandle "\n"

timestampText :: IO Text
timestampText = Text.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S.%qZ" <$> getCurrentTime

safeKey :: Text -> Text
safeKey = Text.map replace
  where
    replace character
      | character `elem` ['/', '\\', ':', ' '] = '-'
      | otherwise = character
