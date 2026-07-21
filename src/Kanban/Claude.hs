module Kanban.Claude
  ( decodeClaudeUsageText,
    fetchClaudeUsage,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import qualified Data.ByteString as ByteString
import Data.Char (isDigit)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time
  ( LocalTime (..),
    TimeOfDay,
    TimeZone,
    UTCTime (..),
    addDays,
    defaultTimeLocale,
    diffUTCTime,
    getCurrentTime,
    getCurrentTimeZone,
    localTimeToUTC,
    parseTimeM,
    timeToTimeOfDay,
    utcToLocalTime,
  )
import Data.Time.Calendar (fromGregorian, toGregorian)
import Kanban.Domain (UsageSnapshot (..), UsageWindow (..))
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.Text (sanitizeText)
import System.Directory
  ( XdgDirectory (XdgCache),
    createDirectoryIfMissing,
    findExecutable,
    getXdgDirectory,
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode)
import System.FilePath ((</>))
import System.IO
  ( BufferMode (NoBuffering),
    Handle,
    hFlush,
    hSetBuffering,
    hWaitForInput,
  )
import System.Posix.Files (setFileMode)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (CreatePipe, NoStream),
    getProcessExitCode,
    interruptProcessGroupOf,
    proc,
    terminateProcess,
    waitForProcess,
    withCreateProcess,
  )
import System.Timeout (timeout)
import Text.Read (readMaybe)

fetchClaudeUsage :: Int -> IO (Either ProviderError UsageSnapshot)
fetchClaudeUsage timeoutMicros = do
  scriptExecutable <- findExecutable "script"
  claudeExecutable <- findExecutable "claude"
  case (scriptExecutable, claudeExecutable) of
    (Nothing, _) -> pure (Left (ProviderError ExecutableMissing "script executable was not found"))
    (_, Nothing) -> pure (Left (ProviderError ExecutableMissing "claude executable was not found"))
    (Just scriptPath, Just claudePath) -> runClaudeProvider timeoutMicros scriptPath claudePath

runClaudeProvider :: Int -> FilePath -> FilePath -> IO (Either ProviderError UsageSnapshot)
runClaudeProvider timeoutMicros scriptPath claudePath = do
  scratchDirectory <- claudeScratchDirectory
  createDirectoryIfMissing True scratchDirectory
  setFileMode scratchDirectory 0o700
  environment <- claudeEnvironment
  fetchedAt <- getCurrentTime
  timeZone <- getCurrentTimeZone
  let createProcess = claudeProcess scriptPath claudePath scratchDirectory environment
  result <- try @IOException (withCreateProcess createProcess (runProcess timeoutMicros fetchedAt timeZone))
  pure $ case result of
    Left exception -> Left (ProviderError RequestFailed (Text.pack (show exception)))
    Right providerResult -> providerResult

claudeScratchDirectory :: IO FilePath
claudeScratchDirectory = do
  cacheRoot <- getXdgDirectory XdgCache "kanban"
  pure (cacheRoot </> "claude-probe")

claudeEnvironment :: IO [(String, String)]
claudeEnvironment = do
  inherited <- getEnvironment
  pure (foldl' setEnvironmentValue inherited providerEnvironment)
  where
    providerEnvironment =
      [ ("DISABLE_AUTOUPDATER", "1"),
        ("DISABLE_TELEMETRY", "1"),
        ("CLAUDE_CODE_DISABLE_CLAUDE_MDS", "1"),
        ("CLAUDE_CODE_SKIP_PROMPT_HISTORY", "1")
      ]

setEnvironmentValue :: [(String, String)] -> (String, String) -> [(String, String)]
setEnvironmentValue environment value@(name, _) = value : filter ((/= name) . fst) environment

claudeProcess :: FilePath -> FilePath -> FilePath -> [(String, String)] -> CreateProcess
claudeProcess scriptPath claudePath scratchDirectory environment =
  (proc scriptPath ["-q", "/dev/null", claudePath, "--safe-mode", "--ax-screen-reader"])
    { cwd = Just scratchDirectory,
      env = Just environment,
      std_in = CreatePipe,
      std_out = CreatePipe,
      std_err = NoStream,
      create_group = True
    }

runProcess :: Int -> UTCTime -> TimeZone -> Maybe Handle -> Maybe Handle -> Maybe Handle -> ProcessHandle -> IO (Either ProviderError UsageSnapshot)
runProcess timeoutMicros fetchedAt timeZone (Just input) (Just output) _ processHandle = do
  hSetBuffering input NoBuffering
  hSetBuffering output NoBuffering
  timedCapture <- timeout timeoutMicros (captureUsage input output)
  case timedCapture of
    Nothing -> do
      _ <- stopProcess processHandle
      pure (Left (ProviderError RequestTimedOut ("Claude usage refresh timed out after " <> Text.pack (show (timeoutMicros `div` 1000000)) <> " seconds")))
    Just transcript -> do
      requestCleanExit input
      _ <- finishProcess processHandle
      pure (decodeClaudeUsageText timeZone fetchedAt transcript)
runProcess _ _ _ _ _ _ processHandle = do
  _ <- stopProcess processHandle
  pure (Left (ProviderError RequestFailed "could not open Claude pseudo-terminal pipes"))

data CaptureState = CaptureState
  { captureBytes :: ByteString.ByteString,
    captureTrustAccepted :: Bool,
    captureUsageRequested :: Bool,
    captureLastOutputAt :: UTCTime
  }

captureUsage :: Handle -> Handle -> IO Text
captureUsage input output = do
  startedAt <- getCurrentTime
  loop (CaptureState ByteString.empty False False startedAt)
  where
    loop state = do
      let transcript = decodeTranscript state.captureBytes
      stateAfterInput <- respondToScreen input transcript state
      now <- getCurrentTime
      if captureFailed transcript || (captureComplete transcript && diffMicros stateAfterInput.captureLastOutputAt now >= quietPeriodMicros)
        then pure transcript
        else do
          ready <- hWaitForInput output inputWaitMillis
          if ready
            then do
              chunk <- ByteString.hGetSome output captureChunkSize
              if ByteString.null chunk
                then pure transcript
                else do
                  receivedAt <- getCurrentTime
                  loop
                    stateAfterInput
                      { captureBytes = stateAfterInput.captureBytes <> chunk,
                        captureLastOutputAt = receivedAt
                      }
            else loop stateAfterInput

respondToScreen :: Handle -> Text -> CaptureState -> IO CaptureState
respondToScreen input transcript state
  | not state.captureTrustAccepted && trustPromptVisible transcript = do
      sendInput input "\r"
      pure state {captureTrustAccepted = True}
  | not state.captureUsageRequested && promptVisible transcript = do
      sendInput input "/usage\r"
      pure state {captureUsageRequested = True}
  | otherwise = pure state

sendInput :: Handle -> ByteString.ByteString -> IO ()
sendInput handle bytes = ByteString.hPut handle bytes >> hFlush handle

decodeTranscript :: ByteString.ByteString -> Text
decodeTranscript = sanitizeText . TextEncoding.decodeUtf8With lenientDecode

trustPromptVisible :: Text -> Bool
trustPromptVisible transcript = "Yes, I trust this folder" `Text.isInfixOf` transcript

promptVisible :: Text -> Bool
promptVisible = any ((== "$") . Text.strip) . Text.lines

captureComplete :: Text -> Bool
captureComplete transcript =
  "Current session" `Text.isInfixOf` transcript
    && "Current week" `Text.isInfixOf` transcript
    && length (usagePairs transcript) >= 2

captureFailed :: Text -> Bool
captureFailed transcript =
  "Failed to load usage data" `Text.isInfixOf` transcript
    || hasAuthenticationFailure transcript

requestCleanExit :: Handle -> IO ()
requestCleanExit input = do
  sendInput input "\ESC"
  threadDelay 100000
  sendInput input "/exit\r"

finishProcess :: ProcessHandle -> IO ExitCode
finishProcess processHandle = do
  cleanExit <- timeout cleanExitMicros (waitForProcess processHandle)
  case cleanExit of
    Just exitCode -> pure exitCode
    Nothing -> stopProcess processHandle

stopProcess :: ProcessHandle -> IO ExitCode
stopProcess processHandle = do
  processExit <- getProcessExitCode processHandle
  case processExit of
    Just exitCode -> pure exitCode
    Nothing -> do
      interruptProcessGroupOf processHandle
      interrupted <- timeout interruptGraceMicros (waitForProcess processHandle)
      case interrupted of
        Just exitCode -> pure exitCode
        Nothing -> terminateProcess processHandle >> waitForProcess processHandle

decodeClaudeUsageText :: TimeZone -> UTCTime -> Text -> Either ProviderError UsageSnapshot
decodeClaudeUsageText timeZone fetchedAt rawTranscript
  | hasAuthenticationFailure transcript = Left (ProviderError AuthenticationRequired "Claude authentication is required")
  | "Failed to load usage data" `Text.isInfixOf` transcript = Left (ProviderError RequestFailed "Claude failed to load usage data")
  | not ("Current session" `Text.isInfixOf` transcript && "Current week" `Text.isInfixOf` transcript) =
      Left (ProviderError UnsupportedVersion "unsupported Claude /usage output")
  | otherwise = do
      session <- latestWindow SessionWindow pairs
      week <- latestWindow WeekWindow pairs
      pure (UsageSnapshot [toUsageWindow session, toUsageWindow week] fetchedAt)
  where
    transcript = sanitizeText rawTranscript
    pairs = usagePairs transcript
    toUsageWindow parsedWindow =
      UsageWindow
        { usageWindowLabel = windowLabel parsedWindow.parsedWindowKind,
          usagePercentLeft = max 0 (min 100 (100 - parsedWindow.parsedUsedPercent)),
          usageResetsAt = inferResetTime timeZone fetchedAt parsedWindow.parsedReset
        }

hasAuthenticationFailure :: Text -> Bool
hasAuthenticationFailure transcript =
  let folded = Text.toCaseFold transcript
   in any (`Text.isInfixOf` folded) ["not logged in", "please log in", "authentication required"]

data WindowKind = SessionWindow | WeekWindow
  deriving stock (Eq, Show)

data ResetTime = TimeOnly TimeOfDay | MonthDay LocalTime
  deriving stock (Eq, Show)

data ParsedWindow = ParsedWindow
  { parsedWindowKind :: WindowKind,
    parsedUsedPercent :: Int,
    parsedReset :: ResetTime
  }
  deriving stock (Eq, Show)

latestWindow :: WindowKind -> [ParsedWindow] -> Either ProviderError ParsedWindow
latestWindow kind windows = case filter ((== kind) . (.parsedWindowKind)) windows of
  [] -> Left (ProviderError UnsupportedVersion ("Claude /usage omitted the " <> windowLabel kind <> " window"))
  matches -> Right (last matches)

windowLabel :: WindowKind -> Text
windowLabel SessionWindow = "5 hour"
windowLabel WeekWindow = "week"

usagePairs :: Text -> [ParsedWindow]
usagePairs = collect Nothing . map Text.strip . Text.lines
  where
    collect _ [] = []
    collect pendingPercent (line : rest)
      | Just usedPercent <- parseUsedPercent line = collect (Just usedPercent) rest
      | Just resetText <- Text.stripPrefix "Resets " line,
        Just usedPercent <- pendingPercent,
        Just (kind, resetTime) <- parseResetTime resetText =
          ParsedWindow kind usedPercent resetTime : collect Nothing rest
      | otherwise = collect pendingPercent rest

parseUsedPercent :: Text -> Maybe Int
parseUsedPercent line
  | "% used" `Text.isInfixOf` Text.toCaseFold line = do
      let beforePercent = fst (Text.breakOn "%" line)
          digits = Text.reverse (Text.takeWhile isDigit (Text.dropWhile (not . isDigit) (Text.reverse beforePercent)))
      readMaybe (Text.unpack digits)
  | otherwise = Nothing

parseResetTime :: Text -> Maybe (WindowKind, ResetTime)
parseResetTime value =
  let withoutZone = Text.strip (fst (Text.breakOn " (" value))
   in case parseTimeOfDay withoutZone of
        Just timeOfDay -> Just (SessionWindow, TimeOnly timeOfDay)
        Nothing -> do
          parsed <- parseMonthDay withoutZone
          pure (WeekWindow, MonthDay parsed)

parseTimeOfDay :: Text -> Maybe TimeOfDay
parseTimeOfDay value =
  timeToTimeOfDay . utctDayTime
    <$> firstParsed ["%Y-%m-%d %-I:%M%p", "%Y-%m-%d %-I%p"] ("2000-01-01 " <> Text.unpack value)

parseMonthDay :: Text -> Maybe LocalTime
parseMonthDay value = do
  parsed <- firstParsed ["%Y %b %e at %-I:%M%p", "%Y %b %e at %-I%p"] ("2000 " <> Text.unpack value)
  pure (LocalTime parsed.utctDay (timeToTimeOfDay parsed.utctDayTime))

firstParsed :: [String] -> String -> Maybe UTCTime
firstParsed formats value = listToMaybe (mapMaybe (\format -> parseTimeM True defaultTimeLocale format value) formats)

inferResetTime :: TimeZone -> UTCTime -> ResetTime -> UTCTime
inferResetTime timeZone fetchedAt resetTime = localTimeToUTC timeZone resetLocalTime
  where
    fetchedLocal = utcToLocalTime timeZone fetchedAt
    resetLocalTime = case resetTime of
      TimeOnly timeOfDay ->
        let candidate = LocalTime fetchedLocal.localDay timeOfDay
         in if candidate > fetchedLocal then candidate else candidate {localDay = addDays 1 candidate.localDay}
      MonthDay parsed ->
        let (year, _, _) = toGregorian fetchedLocal.localDay
            (_, month, dayOfMonth) = toGregorian parsed.localDay
            candidate = LocalTime (fromGregorian year month dayOfMonth) parsed.localTimeOfDay
         in if candidate > fetchedLocal
              then candidate
              else candidate {localDay = fromGregorian (year + 1) month dayOfMonth}

diffMicros :: UTCTime -> UTCTime -> Int
diffMicros earlier later = floor (realToFrac (later `diffUTCTime` earlier) * (1000000 :: Double))

cleanExitMicros, interruptGraceMicros, quietPeriodMicros :: Int
cleanExitMicros = 2 * 1000 * 1000
interruptGraceMicros = 1 * 1000 * 1000
quietPeriodMicros = 2 * 1000 * 1000

inputWaitMillis, captureChunkSize :: Int
inputWaitMillis = 250
captureChunkSize = 8192
