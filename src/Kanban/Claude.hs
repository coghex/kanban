module Kanban.Claude
  ( decodeClaudeUsageText,
    fetchClaudeUsage,
    runClaudeProvider,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Control.Monad (void)
import qualified Data.ByteString as ByteString
import Data.Char (isDigit)
import Data.List (nub)
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
import Kanban.Paths (createPrivateDirectory)
import Kanban.Process
  ( ProcessIdentity (..),
    defaultProcessSnapshot,
    descendantProcesses,
    identityForPid,
    matchingIdentities,
    membersStillInGroup,
  )
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.Text (sanitizeText)
import System.Directory
  ( XdgDirectory (XdgCache),
    findExecutable,
    getXdgDirectory,
  )
import System.Environment (getEnvironment)
import System.FilePath ((</>))
import System.IO
  ( BufferMode (NoBuffering),
    Handle,
    hFlush,
    hSetBuffering,
    hWaitForInput,
  )
import System.Posix.Signals (Signal, sigINT, sigKILL, sigTERM, signalProcess, signalProcessGroup)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (CreatePipe, NoStream),
    getPid,
    getProcessExitCode,
    proc,
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
  createPrivateDirectory XdgCache scratchDirectory
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
      forcedKill <- finishProcess processHandle
      pure $
        if forcedKill
          then Left (ProviderError RequestFailed "Claude usage probe did not exit cleanly after /exit and required a forced kill")
          else decodeClaudeUsageText timeZone fetchedAt transcript
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

-- | Waits out a clean @/exit@, escalating group-wide only if that fails.
-- Identities are censused before this wait even starts, not after: 'script'
-- can be reaped by it (or, if the wait is itself interrupted by its own
-- timeout, reaped moments later by an abandoned reaping thread), and by then
-- its @claude@ child -- handed its own session and process group by
-- 'script''s pty, so a signal to 'script''s group never reaches it -- would
-- be reparented and unreachable by parent-walking. Returns whether SIGKILL
-- was required to reach a confirmed-clear state; the normal fast path (a
-- clean exit within the grace window) never touches the census or signals
-- anything.
finishProcess :: ProcessHandle -> IO Bool
finishProcess processHandle = do
  alreadyExited <- getProcessExitCode processHandle
  case alreadyExited of
    Just _ -> pure False
    Nothing -> do
      census <- captureProbeCensus processHandle
      cleanExit <- timeout cleanExitMicros (waitForProcess processHandle)
      case cleanExit of
        Just _ -> pure False
        Nothing -> terminateWithCensus processHandle census

-- | Escalates termination for a probe that has not exited on its own.
-- Returns whether SIGKILL was required.
stopProcess :: ProcessHandle -> IO Bool
stopProcess processHandle = do
  alreadyExited <- getProcessExitCode processHandle
  case alreadyExited of
    Just _ -> pure False
    Nothing -> captureProbeCensus processHandle >>= terminateWithCensus processHandle

-- | Census of 'script' and every descendant it has spawned by the time this
-- is called (walked recursively by parent pid, so a grandchild -- e.g. a
-- helper @claude@ itself spawns -- is covered too), pinned by pid and start
-- time so a later phase's signal can never land on a recycled identifier.
-- 'Nothing' means the handle's pid could not be read (already reaped) or a
-- process snapshot could not be taken; either way there is nothing safe to
-- census against, and the caller falls back to a best-effort raw signal.
captureProbeCensus :: ProcessHandle -> IO (Maybe [ProcessIdentity])
captureProbeCensus processHandle = do
  maybePid <- getPid processHandle
  case maybePid of
    Nothing -> pure Nothing
    Just pid -> do
      snapshotResult <- defaultProcessSnapshot
      pure $ do
        snapshot <- either (const Nothing) Just snapshotResult
        leader <- identityForPid (fromIntegral pid) snapshot
        pure (leader : descendantProcesses [leader.processIdentityPid] snapshot)

-- | Runs the censused escalation (or, lacking a census, the raw fallback),
-- then reaps 'script' -- this process's own direct child -- within a fixed
-- deadline so it can never linger as a zombie. Reporting is unconditional:
-- this cannot itself confirm the reap succeeded (a wedged 'script' would
-- make it time out), but by that point every group it or its descendants
-- held has already been verified clear or force-killed.
terminateWithCensus :: ProcessHandle -> Maybe [ProcessIdentity] -> IO Bool
terminateWithCensus processHandle census = do
  forced <- case census of
    Just identities -> escalateProbeTermination identities
    Nothing -> fallbackTerminate processHandle
  _ <- timeout reapTimeoutMicros (waitForProcess processHandle)
  pure forced

-- | INT every owned group, grace, verify; then TERM, grace, verify; then
-- KILL, grace, verify -- the same per-group cadence
-- 'Kanban.Process.killVerifiedGroupWith' uses, with an INT phase ahead of it.
-- Every recorded identity is checked at each phase regardless of which
-- process group it started in, so 'script' and a @claude@ that pty gave a
-- separate session are both reached. Returns whether the escalation reached
-- SIGKILL.
escalateProbeTermination :: [ProcessIdentity] -> IO Bool
escalateProbeTermination identities = do
  intGone <- signalOwnedGroupsThenCheck sigINT interruptGraceMicros identities
  if intGone
    then pure False
    else do
      termGone <- signalOwnedGroupsThenCheck sigTERM terminationGraceMicros identities
      if termGone
        then pure False
        else do
          _ <- signalOwnedGroupsThenCheck sigKILL killGraceMicros identities
          pure True

-- | Signals only the process groups a fresh snapshot still shows one of
-- `identities`' members actually occupying -- never a group recalled from an
-- earlier phase, so a group that emptied and had its id reissued to some
-- unrelated process is never resignalled -- waits out the grace window, and
-- reports whether every recorded identity is now gone. A snapshot failure,
-- before or after, reports "not gone" rather than guessing, so escalation
-- keeps proceeding instead of quietly declaring success.
signalOwnedGroupsThenCheck :: Signal -> Int -> [ProcessIdentity] -> IO Bool
signalOwnedGroupsThenCheck signal graceMicros identities = do
  before <- defaultProcessSnapshot
  case before of
    Left _ -> pure False
    Right snapshot -> do
      let liveGroups = [g | g <- distinctGroups identities, not (null (membersStillInGroup g snapshot identities))]
      if null liveGroups
        then pure True
        else do
          mapM_ (ignoreIOException . signalProcessGroup signal . fromIntegral) liveGroups
          threadDelay graceMicros
          after <- defaultProcessSnapshot
          pure $ case after of
            Left _ -> False
            Right snapshot' -> null (matchingIdentities snapshot' identities)

distinctGroups :: [ProcessIdentity] -> [Int]
distinctGroups = nub . map (.processIdentityGroupPid)

-- | The last resort when nothing could be censused (no pid, or `ps` itself
-- failed): with no fresh snapshot, there is no way to confirm which process
-- group a bare pid still denotes -- a group that emptied when its process
-- exited can have its id reissued to a same-user process this fetch never
-- spawned, so signalling it as a group could hit that unrelated process,
-- exactly what the approved issue requires this never do. Group semantics
-- are therefore never used here: only the wrapper's own pid is signalled,
-- individually, which needs no snapshot to be safe -- as this process's own
-- still-unreaped child, POSIX guarantees its pid stays reserved to it
-- (running or a zombie) until 'waitForProcess' actually reaps it, which does
-- not happen until after this returns. Nothing here is verified either way,
-- so the escalation is always reported as unconfirmed.
fallbackTerminate :: ProcessHandle -> IO Bool
fallbackTerminate processHandle = do
  maybePid <- getPid processHandle
  case maybePid of
    Nothing -> pure ()
    Just pid -> do
      ignoreIOException (signalProcess sigINT pid)
      threadDelay interruptGraceMicros
      ignoreIOException (signalProcess sigTERM pid)
      threadDelay terminationGraceMicros
      ignoreIOException (signalProcess sigKILL pid)
      threadDelay killGraceMicros
  pure True

ignoreIOException :: IO () -> IO ()
ignoreIOException action = void (try @IOException action :: IO (Either IOException ()))

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

cleanExitMicros, interruptGraceMicros, terminationGraceMicros, killGraceMicros, reapTimeoutMicros, quietPeriodMicros :: Int
cleanExitMicros = 2 * 1000 * 1000
interruptGraceMicros = 1 * 1000 * 1000
terminationGraceMicros = 1 * 1000 * 1000
killGraceMicros = 1 * 1000 * 1000
reapTimeoutMicros = 2 * 1000 * 1000
quietPeriodMicros = 2 * 1000 * 1000

inputWaitMillis, captureChunkSize :: Int
inputWaitMillis = 250
captureChunkSize = 8192
