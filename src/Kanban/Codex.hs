module Kanban.Codex
  ( decodeCodexUsageResponse,
    fetchCodexUsage,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (Object, Value (..), eitherDecode, withObject, (.:), (.:?))
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Parser, parseEither, parseMaybe)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (sortOn)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.IO as TextIO
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Kanban.Domain (UsageSnapshot (..), UsageWindow (..))
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import System.Exit (ExitCode)
import System.IO (BufferMode (LineBuffering), Handle, hFlush, hGetLine, hSetBuffering, hSetEncoding, utf8)
import System.IO.Error (isDoesNotExistError)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (CreatePipe, NoStream),
    proc,
    terminateProcess,
    waitForProcess,
    withCreateProcess,
  )
import System.Timeout (timeout)

fetchCodexUsage :: IO (Either ProviderError UsageSnapshot)
fetchCodexUsage = do
  result <- try @IOException (withCreateProcess codexProcess runProcess)
  pure $ case result of
    Left exception
      | isDoesNotExistError exception -> Left (ProviderError ExecutableMissing "codex executable was not found")
      | otherwise -> Left (ProviderError RequestFailed (Text.pack (show exception)))
    Right providerResult -> providerResult

codexProcess :: CreateProcess
codexProcess =
  (proc "codex" ["app-server", "--stdio"])
    { std_in = CreatePipe,
      std_out = CreatePipe,
      std_err = NoStream
    }

runProcess :: Maybe Handle -> Maybe Handle -> Maybe Handle -> ProcessHandle -> IO (Either ProviderError UsageSnapshot)
runProcess (Just input) (Just output) _ processHandle = do
  hSetEncoding input utf8
  hSetEncoding output utf8
  hSetBuffering input LineBuffering
  timedResult <- timeout codexTimeoutMicros (exchange input output)
  _ <- terminateAndWait processHandle
  pure $ case timedResult of
    Nothing -> Left (ProviderError RequestTimedOut "Codex usage refresh timed out after 10 seconds")
    Just result -> result
runProcess _ _ _ processHandle = do
  _ <- terminateAndWait processHandle
  pure (Left (ProviderError RequestFailed "could not open Codex app-server pipes"))

exchange :: Handle -> Handle -> IO (Either ProviderError UsageSnapshot)
exchange input output = do
  sendLine input initializeRequest
  initializeResponse <- awaitResponse 0 output
  case initializeResponse >>= validateInitializeResponse of
    Left providerError -> pure (Left providerError)
    Right () -> do
      sendLine input initializedNotification
      sendLine input rateLimitsRequest
      response <- awaitResponse 1 output
      now <- getCurrentTime
      pure (response >>= decodeCodexUsageResponse now)

sendLine :: Handle -> Text -> IO ()
sendLine handle message = do
  TextIO.hPutStrLn handle message
  hFlush handle

awaitResponse :: Int -> Handle -> IO (Either ProviderError LazyByteString.ByteString)
awaitResponse targetId handle = readMessages 0
  where
    readMessages count
      | count >= maximumMessages = pure (Left (ProviderError InvalidResponse "Codex app-server emitted too many unrelated messages"))
      | otherwise = do
          line <- hGetLine handle
          let bytes = LazyByteString.fromStrict (TextEncoding.encodeUtf8 (Text.pack line))
          case responseId bytes of
            Just responseIdentifier
              | responseIdentifier == targetId -> pure (Right bytes)
            _ -> readMessages (count + 1)

maximumMessages :: Int
maximumMessages = 100

responseId :: LazyByteString.ByteString -> Maybe Int
responseId bytes = do
  value <- either (const Nothing) Just (eitherDecode bytes :: Either String Value)
  parseMaybe (withObject "RPC response" (.: "id")) value

validateInitializeResponse :: LazyByteString.ByteString -> Either ProviderError ()
validateInitializeResponse bytes = case decodeRpcError bytes of
  Just providerError -> Left providerError
  Nothing -> Right ()

decodeCodexUsageResponse :: UTCTime -> LazyByteString.ByteString -> Either ProviderError UsageSnapshot
decodeCodexUsageResponse fetchedAt bytes = do
  value <- case eitherDecode bytes of
    Left message -> Left (ProviderError InvalidResponse ("Codex returned invalid JSON: " <> Text.pack message))
    Right decoded -> Right decoded
  case parseMaybe parseRpcError value of
    Just errorMessage -> Left (ProviderError (classifyRpcError errorMessage) errorMessage)
    Nothing -> case parseEither (parseUsageSnapshot fetchedAt) value of
      Left message -> Left (ProviderError UnsupportedVersion ("unsupported Codex rate-limit response: " <> Text.pack message))
      Right snapshot -> Right snapshot

parseUsageSnapshot :: UTCTime -> Value -> Parser UsageSnapshot
parseUsageSnapshot fetchedAt = withObject "Codex RPC response" $ \response -> do
  result <- response .: "result"
  rateLimits <- selectRateLimits result
  windows <- withObject "rate-limit snapshot" parseWindows rateLimits
  if null windows
    then fail "response contained no complete rate-limit windows"
    else pure (UsageSnapshot (map snd (sortOn fst windows)) fetchedAt)

selectRateLimits :: Object -> Parser Value
selectRateLimits result = do
  fallback <- result .: "rateLimits"
  byLimitId <- result .:? "rateLimitsByLimitId"
  pure $ case byLimitId of
    Just (Object buckets) -> maybe fallback id (KeyMap.lookup "codex" buckets)
    _ -> fallback

parseWindows :: Object -> Parser [(Integer, UsageWindow)]
parseWindows snapshot = do
  primary <- snapshot .:? "primary"
  secondary <- snapshot .:? "secondary"
  catMaybes <$> traverse parseWindow [primary, secondary]

parseWindow :: Maybe Value -> Parser (Maybe (Integer, UsageWindow))
parseWindow Nothing = pure Nothing
parseWindow (Just value) = Just <$> withObject "rate-limit window" parseFields value
  where
    parseFields window = do
      usedPercent <- window .: "usedPercent"
      durationMinutes <- window .: "windowDurationMins"
      resetSeconds <- window .: "resetsAt"
      pure
        ( durationMinutes,
          UsageWindow
            { usageWindowLabel = durationLabel durationMinutes,
              usagePercentLeft = max 0 (min 100 (100 - usedPercent)),
              usageResetsAt = posixSecondsToUTCTime (fromInteger resetSeconds)
            }
        )

durationLabel :: Integer -> Text
durationLabel 300 = "5 hour"
durationLabel 10080 = "week"
durationLabel minutes
  | minutes > 0 && minutes `mod` 1440 == 0 = showText (minutes `div` 1440) <> " day"
  | minutes > 0 && minutes `mod` 60 == 0 = showText (minutes `div` 60) <> " hour"
  | otherwise = showText minutes <> " min"

decodeRpcError :: LazyByteString.ByteString -> Maybe ProviderError
decodeRpcError bytes = do
  value <- either (const Nothing) Just (eitherDecode bytes :: Either String Value)
  message <- parseMaybe parseRpcError value
  pure (ProviderError (classifyRpcError message) message)

parseRpcError :: Value -> Parser Text
parseRpcError = withObject "RPC response" $ \response -> do
  rpcError <- response .: "error"
  withObject "RPC error" (.: "message") rpcError

classifyRpcError :: Text -> ProviderErrorKind
classifyRpcError message
  | any (`Text.isInfixOf` Text.toCaseFold message) ["auth", "login", "credential", "token"] = AuthenticationRequired
  | otherwise = RequestFailed

terminateAndWait :: ProcessHandle -> IO ExitCode
terminateAndWait processHandle = do
  terminateProcess processHandle
  waitForProcess processHandle

codexTimeoutMicros :: Int
codexTimeoutMicros = 10 * 1000 * 1000

initializeRequest, initializedNotification, rateLimitsRequest :: Text
initializeRequest =
  "{\"method\":\"initialize\",\"id\":0,\"params\":{\"clientInfo\":{\"name\":\"kanban\",\"title\":\"Kanban\",\"version\":\"0.1.0\"}}}"
initializedNotification = "{\"method\":\"initialized\",\"params\":{}}"
rateLimitsRequest = "{\"method\":\"account/rateLimits/read\",\"id\":1,\"params\":null}"

showText :: Show value => value -> Text
showText = Text.pack . show
