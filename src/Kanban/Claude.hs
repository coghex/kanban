module Kanban.Claude
  ( ScriptFlavor (..),
    claudeEnvironment,
    claudeProbeArguments,
    claudeScratchDirectory,
    decodeClaudeUsageText,
    fetchClaudeUsage,
    fetchClaudeUsageWith,
    hostScriptFlavor,
    runClaudeProvider,
    runClaudeProviderWith,
    scriptFlavorFor,
    scriptFlavorLabel,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Control.Monad (void)
import qualified Data.ByteString as ByteString
import Data.Char (isDigit)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (nub)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
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
import System.Info (os)
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
    proc,
    waitForProcess,
    withCreateProcess,
  )
import System.Timeout (timeout)
import Text.Read (readMaybe)

-- | Which dialect of @script@ the host's userland provides, and so which
-- operands compose a pseudo-terminal probe rather than a usage error. BSD
-- @script@ takes the command to run as trailing operands after the
-- typescript file; util-linux @script@ accepts at most one file operand and
-- runs a command only via @-c@, so handing it the BSD operands fails with
-- "unexpected number of arguments" before @claude@ is ever started.
data ScriptFlavor = BsdScript | UtilLinuxScript
  deriving stock (Eq, Show)

-- | The flavor a host provides, decided by platform alone. Probing the
-- installed @script@ for its own dialect is deliberately not done: the
-- dialect is a property of the userland Kanban is built for, and a probe
-- would add a second external invocation to every refresh for a question
-- the platform already answers. macOS is the one BSD-userland host Kanban
-- supports, and Linux -- which CI already builds and tests on -- the other,
-- so every non-darwin host resolves to the util-linux form.
scriptFlavorFor :: String -> ScriptFlavor
scriptFlavorFor "darwin" = BsdScript
scriptFlavorFor _ = UtilLinuxScript

-- | 'scriptFlavorFor' applied to the platform this binary was built for.
hostScriptFlavor :: ScriptFlavor
hostScriptFlavor = scriptFlavorFor os

-- | How a flavor names itself in a diagnostic, so a mismatch between the
-- composed operands and the installed @script@ is distinguishable from a
-- missing executable, a timeout, or output the parser does not recognize.
scriptFlavorLabel :: ScriptFlavor -> Text
scriptFlavorLabel BsdScript = "BSD"
scriptFlavorLabel UtilLinuxScript = "util-linux"

-- | The @script@ operands that run @claude@ under a pseudo-terminal for
-- each flavor. The BSD operands are the argv Kanban has always composed.
--
-- util-linux hands its @-c@ payload to a shell, so the resolved executable
-- path — which is whatever @findExecutable@ or a caller supplied, and can
-- carry whitespace, quotes or any other metacharacter — is single-quoted
-- rather than concatenated, and so are the two literal flags. That keeps
-- the payload exactly three words to the shell: the executable, then
-- @--safe-mode@ and @--ax-screen-reader@, with no splitting and nothing
-- else evaluated.
claudeProbeArguments :: ScriptFlavor -> FilePath -> [String]
claudeProbeArguments BsdScript claudePath =
  ["-q", "/dev/null", claudePath, "--safe-mode", "--ax-screen-reader"]
claudeProbeArguments UtilLinuxScript claudePath =
  ["-q", "-c", unwords (map shellQuoted [claudePath, "--safe-mode", "--ax-screen-reader"]), "/dev/null"]

-- | One shell word, POSIX-quoted: wrapped in single quotes, with each
-- embedded single quote closed, backslash-escaped and reopened.
shellQuoted :: String -> String
shellQuoted value = "'" <> concatMap escape value <> "'"
  where
    escape '\'' = "'\\''"
    escape character = [character]

-- | Names the flavor whose operands were composed on every way the probe can
-- fail, leaving the 'ProviderErrorKind' — and so every classification built
-- on it — exactly as the failing step reported it.
annotateFlavor :: ScriptFlavor -> Either ProviderError result -> Either ProviderError result
annotateFlavor flavor (Left providerError) =
  Left
    providerError
      { providerErrorMessage =
          providerError.providerErrorMessage <> " (script flavor: " <> scriptFlavorLabel flavor <> ")"
      }
annotateFlavor _ result = result

fetchClaudeUsage :: Int -> IO (Either ProviderError UsageSnapshot)
fetchClaudeUsage = fetchClaudeUsageWith hostScriptFlavor

fetchClaudeUsageWith :: ScriptFlavor -> Int -> IO (Either ProviderError UsageSnapshot)
fetchClaudeUsageWith flavor timeoutMicros = do
  scriptExecutable <- findExecutable "script"
  claudeExecutable <- findExecutable "claude"
  case (scriptExecutable, claudeExecutable) of
    (Nothing, _) -> pure (annotateFlavor flavor (Left (ProviderError ExecutableMissing "script executable was not found")))
    (_, Nothing) -> pure (annotateFlavor flavor (Left (ProviderError ExecutableMissing "claude executable was not found")))
    (Just scriptPath, Just claudePath) -> runClaudeProviderWith flavor timeoutMicros scriptPath claudePath

runClaudeProvider :: Int -> FilePath -> FilePath -> IO (Either ProviderError UsageSnapshot)
runClaudeProvider = runClaudeProviderWith hostScriptFlavor

runClaudeProviderWith :: ScriptFlavor -> Int -> FilePath -> FilePath -> IO (Either ProviderError UsageSnapshot)
runClaudeProviderWith flavor timeoutMicros scriptPath claudePath = do
  scratchDirectory <- claudeScratchDirectory
  createPrivateDirectory XdgCache scratchDirectory
  environment <- claudeEnvironment
  fetchedAt <- getCurrentTime
  timeZone <- getCurrentTimeZone
  let createProcess = claudeProcess flavor scriptPath claudePath scratchDirectory environment
  result <- try @IOException (withCreateProcess createProcess (runProcess timeoutMicros fetchedAt timeZone))
  -- Annotated here rather than at each failing step so the flavor reaches
  -- the transcript-decoding failures too, which are reported by a pure
  -- decoder that knows nothing about how the probe was launched.
  pure . annotateFlavor flavor $ case result of
    Left exception -> Left (ProviderError RequestFailed (Text.pack (show exception)))
    Right providerResult -> providerResult

-- | The fixed directory the probe runs from, so the client's folder-trust
-- prompt happens at most once and session history lands outside the user's
-- project (§14). Shared with @kanban --ping claude@ for exactly that reason: a
-- directory whose trust question is already settled cannot strand a
-- non-interactive run at that prompt.
claudeScratchDirectory :: IO FilePath
claudeScratchDirectory = do
  cacheRoot <- getXdgDirectory XdgCache "kanban"
  pure (cacheRoot </> "claude-probe")

-- | The hardening every Kanban-launched @claude@ runs under: no auto-updater,
-- telemetry, prompt history, or @CLAUDE.md@ loading, with normal OAuth access
-- left intact.
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

claudeProcess :: ScriptFlavor -> FilePath -> FilePath -> FilePath -> [(String, String)] -> CreateProcess
claudeProcess flavor scriptPath claudePath scratchDirectory environment =
  (proc scriptPath (claudeProbeArguments flavor claudePath))
    { cwd = Just scratchDirectory,
      env = Just environment,
      std_in = CreatePipe,
      std_out = CreatePipe,
      std_err = NoStream,
      create_group = True
    }

-- | Every way this can return runs 'stopProcess' or 'finishProcess' first,
-- the exception path included. Driving the probe is all handle work --
-- buffering, the capture's reads and its answers to the screen, and the
-- clean-exit write -- and every one of those raises 'IOException' once the
-- far end of the pseudo-terminal has gone away, which is exactly when a
-- @claude@ the pty put in its own session is most likely to be outliving
-- the 'script' that launched it. Letting such an exception escape to
-- 'runClaudeProviderWith' still classified the refresh correctly, but by
-- then no process handle is in scope to clean up through, and
-- 'withCreateProcess''s own cleanup only knows about the direct child.
--
-- Only synchronous 'IOException's are caught. A 'timeout' expiring, or any
-- other asynchronous interruption, still unwinds as it always did rather
-- than being reported as a provider failure.
--
-- Nothing sits between the process being created and the guard going up
-- that could raise one: 'newProbeCensus' only reads the handle's pid and
-- allocates a reference, neither of which touches the outside world, and it
-- has to come first because it is what the handler cleans up through.
runProcess :: Int -> UTCTime -> TimeZone -> Maybe Handle -> Maybe Handle -> Maybe Handle -> ProcessHandle -> IO (Either ProviderError UsageSnapshot)
runProcess timeoutMicros fetchedAt timeZone (Just input) (Just output) _ processHandle = do
  census <- newProbeCensus processHandle
  driven <- try @IOException (driveProbe census timeoutMicros fetchedAt timeZone input output)
  case driven of
    Right result -> pure result
    Left exception -> do
      _ <- stopProcess census
      pure (Left (ProviderError RequestFailed (Text.pack (show exception))))
runProcess _ _ _ _ _ _ processHandle = do
  census <- newProbeCensus processHandle
  _ <- stopProcess census
  pure (Left (ProviderError RequestFailed "could not open Claude pseudo-terminal pipes"))

driveProbe :: ProbeCensus -> Int -> UTCTime -> TimeZone -> Handle -> Handle -> IO (Either ProviderError UsageSnapshot)
driveProbe census timeoutMicros fetchedAt timeZone input output = do
  hSetBuffering input NoBuffering
  hSetBuffering output NoBuffering
  timedCapture <- timeout timeoutMicros (captureUsage census input output)
  case timedCapture of
    Nothing -> do
      _ <- stopProcess census
      pure (Left (ProviderError RequestTimedOut ("Claude usage refresh timed out after " <> Text.pack (show (timeoutMicros `div` 1000000)) <> " seconds")))
    Just transcript -> do
      requestCleanExit input
      forcedKill <- finishProcess census
      pure $
        if forcedKill
          then Left (ProviderError RequestFailed "Claude usage probe did not exit cleanly after /exit and required a forced kill")
          else decodeClaudeUsageText timeZone fetchedAt transcript

data CaptureState = CaptureState
  { captureBytes :: ByteString.ByteString,
    captureTrustAccepted :: Bool,
    captureUsageRequested :: Bool,
    captureLastOutputAt :: UTCTime,
    captureLastCensusAt :: UTCTime
  }

-- | Drives the screen exchange, and keeps the probe's census fresh while it
-- does: this is the only stretch of the probe long enough for 'script' to
-- exit under it, and the only one during which the tree it launched is
-- still forming.
captureUsage :: ProbeCensus -> Handle -> Handle -> IO Text
captureUsage census input output = do
  startedAt <- getCurrentTime
  loop (CaptureState ByteString.empty False False startedAt startedAt)
  where
    loop state = do
      let transcript = decodeTranscript state.captureBytes
      stateAfterInput <- respondToScreen input transcript state
      now <- getCurrentTime
      stateAfterCensus <- refreshCensusIfDue now stateAfterInput
      if captureFailed transcript || (captureComplete transcript && diffMicros stateAfterCensus.captureLastOutputAt now >= quietPeriodMicros)
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
                    stateAfterCensus
                      { captureBytes = stateAfterCensus.captureBytes <> chunk,
                        captureLastOutputAt = receivedAt
                      }
            else loop stateAfterCensus

    -- Two cadences, because the two things a refresh can buy cost very
    -- differently. Until a census has seen anything below 'script' there is
    -- nothing retained that would survive its exit, so the gap between
    -- attempts is the capture's own polling interval; a probe whose client
    -- starts normally pays one or two snapshots for that. Afterwards a
    -- refresh only picks up something spawned later, which is worth a
    -- snapshot every couple of seconds and not worth one every quarter of a
    -- second for the whole of a multi-second probe.
    refreshCensusIfDue now state = do
      acquired <- probeCensusReachedDescendant census
      let interval = if acquired then censusRefreshIntervalMicros else censusAcquireIntervalMicros
      if diffMicros state.captureLastCensusAt now < interval
        then pure state
        else do
          recordProbeCensus census
          recordedAt <- getCurrentTime
          pure state {captureLastCensusAt = recordedAt}

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

-- | Everything this probe has been observed to own, accumulated as it runs
-- rather than censused once at cleanup time.
--
-- A census can only reach a separately grouped @claude@ by walking down
-- from 'script': the pty hands that child its own session, so the moment
-- 'script' exits the child is reparented and no walk from 'script''s pid
-- finds it again. Two of the three cleanup branches that already existed
-- census at a moment 'script' is necessarily still there -- the refresh
-- timeout fires while it is wedged, and the missing-pipe branch runs before
-- anything has been written to it -- and the third, 'finishProcess',
-- censuses before it begins waiting for exactly that reason. The exception
-- path has no such moment: an 'IOException' from the capture's own handle
-- work arrives *because* the far end went away, so by then the census that
-- can still see the child is one an earlier refresh took. Retaining those
-- identities is what keeps it reachable.
data ProbeCensus = ProbeCensus
  { probeCensusHandle :: ProcessHandle,
    -- | Read once, while the probe is known to be unreaped, so
    -- 'probeCensusReachedDescendant' can still tell the wrapper apart from
    -- what it launched after 'getPid' has stopped answering.
    probeCensusWrapperPid :: Maybe Int,
    probeCensusRetained :: IORef (Maybe [ProcessIdentity])
  }

newProbeCensus :: ProcessHandle -> IO ProbeCensus
newProbeCensus processHandle = do
  wrapperPid <- getPid processHandle
  ProbeCensus processHandle (fromIntegral <$> wrapperPid) <$> newIORef Nothing

-- | Folds a fresh census into what earlier ones recorded, the newest record
-- of each (pid, start time) winning so a process that has since been
-- reparented or moved group is remembered as the last snapshot actually saw
-- it. A snapshot that could not be taken leaves the retained census exactly
-- as it was, so one failed @ps@ never discards identities an earlier one
-- pinned.
recordProbeCensus :: ProbeCensus -> IO ()
recordProbeCensus census = do
  fresh <- captureProbeCensus census.probeCensusHandle
  case fresh of
    Nothing -> pure ()
    Just identities -> modifyIORef' census.probeCensusRetained (Just . mergeIdentities identities . fromMaybe [])
  where
    mergeIdentities fresh retained = fresh <> filter ((`notElem` map identityKey fresh) . identityKey) retained
    identityKey identity = (identity.processIdentityPid, identity.processIdentityStartedAt)

-- | Whether anything below the wrapper has been pinned yet -- that is,
-- whether the retained census would still reach the client if the wrapper
-- went away now. 'Nothing' for the wrapper's own pid means 'getPid' never
-- answered, in which case 'captureProbeCensus' cannot census either and
-- there is nothing for a slower cadence to preserve.
probeCensusReachedDescendant :: ProbeCensus -> IO Bool
probeCensusReachedDescendant census = do
  retained <- readIORef census.probeCensusRetained
  pure $ case retained of
    Nothing -> False
    Just identities -> any ((/= census.probeCensusWrapperPid) . Just . (.processIdentityPid)) identities

-- | Waits out a clean @/exit@, then verifies -- and, if needed, escalates --
-- unconditionally. Identities are censused before this wait even starts, not
-- after: 'script' can be reaped by it (or, if the wait is itself interrupted
-- by its own timeout, reaped moments later by an abandoned reaping thread),
-- and by then its @claude@ child -- handed its own session and process group
-- by 'script''s pty, so a signal to 'script''s group never reaches it --
-- would be reparented and unreachable by parent-walking. 'script' having
-- already been reaped by the wait above is never itself treated as cleanup
-- completion: 'terminateWithCensus' re-checks every censused identity
-- against a fresh snapshot regardless, so a @claude@ that outlives a
-- vanished 'script' is still caught and escalated against. Returns whether
-- SIGKILL was required to reach a confirmed-clear state; the normal fast
-- path (everyone already gone) sends no signal at all, just the one
-- verifying snapshot.
finishProcess :: ProbeCensus -> IO Bool
finishProcess census = do
  recordProbeCensus census
  _ <- timeout cleanExitMicros (waitForProcess census.probeCensusHandle)
  terminateWithCensus census

-- | Escalates termination for a probe that has not exited on its own.
-- Returns whether SIGKILL was required.
stopProcess :: ProbeCensus -> IO Bool
stopProcess census = recordProbeCensus census >> terminateWithCensus census

-- | Census of 'script' and every descendant it has spawned by the time this
-- is called (walked recursively by parent pid, so a grandchild -- e.g. a
-- helper @claude@ itself spawns -- is covered too), pinned by pid and start
-- time so a later phase's signal can never land on a recycled identifier.
-- 'script' itself is included only if the snapshot still shows it as a live
-- (non-zombie) process; if 'script' has already exited and not yet been
-- reaped, its own entry is absent but its descendants remain discoverable by
-- their recorded parent pid, so they are still censused rather than lost to
-- a leader that is merely between exit and reap. 'Nothing' means the
-- handle's pid could not be read at all (already reaped) or a process
-- snapshot could not be taken; either way there is nothing safe to census
-- against, and the caller falls back to a best-effort raw signal.
captureProbeCensus :: ProcessHandle -> IO (Maybe [ProcessIdentity])
captureProbeCensus processHandle = do
  maybePid <- getPid processHandle
  case maybePid of
    Nothing -> pure Nothing
    Just pid -> do
      snapshotResult <- defaultProcessSnapshot
      pure $ case snapshotResult of
        Left _ -> Nothing
        Right snapshot ->
          let rootPid = fromIntegral pid
              descendants = descendantProcesses [rootPid] snapshot
           in Just (maybe descendants (: descendants) (identityForPid rootPid snapshot))

-- | Runs the censused escalation (or, lacking a census, the raw fallback),
-- then reaps 'script' -- this process's own direct child -- within a fixed
-- deadline so it can never linger as a zombie. Reporting is unconditional:
-- this cannot itself confirm the reap succeeded (a wedged 'script' would
-- make it time out), but by that point every group it or its descendants
-- held has already been verified clear or force-killed.
--
-- The fallback is reserved for a probe nothing was *ever* censused for. A
-- retained census whose members have all since exited is not that case: it
-- escalates against them, which costs one verifying snapshot and sends no
-- signal, rather than signalling a bare pid unverified.
terminateWithCensus :: ProbeCensus -> IO Bool
terminateWithCensus census = do
  retained <- readIORef census.probeCensusRetained
  forced <- case retained of
    Just identities -> escalateProbeTermination identities
    Nothing -> fallbackTerminate census.probeCensusHandle
  _ <- timeout reapTimeoutMicros (waitForProcess census.probeCensusHandle)
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

-- | How long the capture goes between census refreshes, before and after it
-- has pinned something below the wrapper. See 'captureUsage'.
censusAcquireIntervalMicros, censusRefreshIntervalMicros :: Int
censusAcquireIntervalMicros = 250 * 1000
censusRefreshIntervalMicros = 2 * 1000 * 1000

inputWaitMillis, captureChunkSize :: Int
inputWaitMillis = 250
captureChunkSize = 8192
