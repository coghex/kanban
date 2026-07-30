-- | The §14 external-command usage provider shared by the Codex and Claude
-- usage sources: when a provider has a configured command, this runs it
-- instead of the built-in integration.
module Kanban.UsageCommand
  ( decodeUsageCommandDocument,
    runUsageCommand,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.Aeson (Value, eitherDecode, withObject, (.:))
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, getCurrentTime)
import Kanban.CommandCapture
  ( CommandBounds (..),
    CommandOutcome (..),
    StreamCaptureResult (..),
    awaitCommandOutcome,
    captureGraceMicros,
    capturedBytes,
    decodeCommandText,
    releaseCapture,
    renderWindow,
    startCapture,
  )
import Kanban.Domain (UsageSnapshot (..), UsageWindow (..))
import Kanban.Paths (createPrivateDirectory)
import Kanban.Process
  ( ManagedProcess,
    ProcessIdentity (..),
    defaultProcessSnapshot,
    killManagedProcess,
    managedProcess,
  )
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.Text (sanitizeText)
import System.Directory (XdgDirectory (XdgCache), getXdgDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle)
import System.IO.Error (isDoesNotExistError, isPermissionError)
import System.Process
  ( CreateProcess (..),
    Pid,
    ProcessHandle,
    StdStream (CreatePipe, NoStream),
    createProcess,
    getPid,
    proc,
  )

-- | Runs @argv@ (executable followed by literal arguments, direct-exec'd
-- with normal @PATH@ resolution) as the configured provider, under
-- @timeoutMicros@. The child is placed in its own process group, given
-- closed stdin, and run from a stable application-owned directory rather
-- than the selected repository, so changing @--path@ never changes its
-- working-directory contract.
runUsageCommand :: Int -> [Text] -> IO (Either ProviderError UsageSnapshot)
runUsageCommand _ [] = pure (Left (ProviderError ExecutableMissing "usage command is not configured"))
runUsageCommand timeoutMicros (executableText : argumentTexts) = do
  scratchDirectory <- usageCommandScratchDirectory
  createPrivateDirectory XdgCache scratchDirectory
  let processSpec = usageCommandProcess scratchDirectory (Text.unpack executableText) (map Text.unpack argumentTexts)
  started <- try @IOException (createProcess processSpec)
  case started of
    Left exception -> pure (Left (usageCommandSpawnFailure exception))
    Right (Nothing, Just outputHandle, Just errorHandle, processHandle) ->
      runSpawnedUsageCommand timeoutMicros processHandle outputHandle errorHandle
    Right (_, _, _, processHandle) -> do
      (managed, _) <- managedProcess processHandle
      killManagedProcess managed
      pure (Left (ProviderError RequestFailed "usage command did not provide stdout and stderr pipes"))

-- | Only a launch that failed because there was nothing runnable to launch —
-- no such file, or a file that cannot be executed — is reported as missing;
-- anything else here means a process was never even created, so there is
-- nothing to clean up.
usageCommandSpawnFailure :: IOException -> ProviderError
usageCommandSpawnFailure exception
  | isDoesNotExistError exception || isPermissionError exception =
      ProviderError ExecutableMissing ("usage command executable was not found: " <> Text.pack (show exception))
  | otherwise = ProviderError RequestFailed (Text.pack (show exception))

usageCommandScratchDirectory :: IO FilePath
usageCommandScratchDirectory = do
  cacheRoot <- getXdgDirectory XdgCache "kanban"
  pure (cacheRoot </> "usage-command")

usageCommandProcess :: FilePath -> FilePath -> [String] -> CreateProcess
usageCommandProcess scratchDirectory executable arguments =
  (proc executable arguments)
    { cwd = Just scratchDirectory,
      std_in = NoStream,
      std_out = CreatePipe,
      std_err = CreatePipe,
      create_group = True
    }

runSpawnedUsageCommand :: Int -> ProcessHandle -> Handle -> Handle -> IO (Either ProviderError UsageSnapshot)
runSpawnedUsageCommand timeoutMicros processHandle outputHandle errorHandle = do
  -- Captured before anything can reap the leader: 'getPid' goes 'Nothing'
  -- the moment a clean exit reaps it below, so the pid used to check the
  -- group afterwards is taken now while it is guaranteed available.
  (managed, _groupLeaderProblem) <- managedProcess processHandle
  rootPid <- getPid processHandle
  fetchedAt <- getCurrentTime
  outputCapture <- startCapture outputHandle
  errorCapture <- startCapture errorHandle
  let bounds = CommandBounds {commandDeadlineMicros = timeoutMicros, commandCaptureGraceMicros = captureGraceMicros}
  completed <- awaitCommandOutcome bounds processHandle outputCapture errorCapture
  releaseCapture outputCapture
  releaseCapture errorCapture
  cleanupUsageCommandGroup rootPid managed
  pure (renderUsageCommandResult timeoutMicros fetchedAt completed)

-- | Sweeps the launched process group after every completion path -- success,
-- invalid output, nonzero exit, or timeout -- so a descendant the command
-- left behind (e.g. one it backgrounded before exiting) is caught too, not
-- just a direct process that is itself still running. This checks group
-- occupancy directly with a fresh process-table read rather than a
-- discovered descendant list: group membership survives a leader's exit
-- reparenting its children, so it stays correct however late the command
-- forked whatever it left behind, while a list built by walking parent links
-- once would not. The common case -- nothing left -- costs one read; only an
-- occupied group pays 'killManagedProcess's TERM/KILL escalation.
cleanupUsageCommandGroup :: Maybe Pid -> ManagedProcess -> IO ()
cleanupUsageCommandGroup Nothing managed = killManagedProcess managed
cleanupUsageCommandGroup (Just pid) managed = do
  occupied <- groupStillOccupied (fromIntegral pid)
  when occupied (killManagedProcess managed)

groupStillOccupied :: Int -> IO Bool
groupStillOccupied groupPid = do
  snapshotResult <- defaultProcessSnapshot
  pure $ case snapshotResult of
    Left _ -> True
    Right snapshot -> any ((== groupPid) . (.processIdentityGroupPid)) snapshot

renderUsageCommandResult :: Int -> UTCTime -> CommandOutcome -> Either ProviderError UsageSnapshot
renderUsageCommandResult timeoutMicros _ CommandUnfinished =
  Left (ProviderError RequestTimedOut ("usage command timed out after " <> renderWindow timeoutMicros))
renderUsageCommandResult _ fetchedAt (CommandExited exitCode output errors) = case (exitCode, output, errors) of
  (_, StreamUnreadable exception, _) ->
    Left (ProviderError RequestFailed ("could not read usage command output: " <> Text.pack (show exception)))
  (ExitSuccess, StreamComplete outputBytes, _) ->
    decodeUsageCommandDocument fetchedAt (LazyByteString.fromStrict outputBytes)
  (ExitSuccess, StreamTruncated _, _) ->
    Left (ProviderError RequestFailed "usage command exited but its output was still incomplete")
  (_, _, StreamUnreadable exception) ->
    Left (ProviderError RequestFailed ("could not read usage command diagnostics: " <> Text.pack (show exception)))
  (ExitFailure code, _, errorsResult) ->
    Left (ProviderError RequestFailed ("usage command exited with status " <> Text.pack (show code) <> stderrDetail errorsResult))

-- | A bounded, sanitized excerpt of stderr for a failing exit's diagnostic.
-- The protocol only ever consumes stdout, so this never reaches the terminal
-- on its own and is never trusted to carry the response itself.
stderrDetail :: StreamCaptureResult -> Text
stderrDetail errorsResult
  | Text.null trimmed = ""
  | otherwise = ": " <> trimmed
  where
    trimmed = Text.strip (Text.take stderrExcerptLength (sanitizeText (decodeCommandText (capturedBytes errorsResult))))

stderrExcerptLength :: Int
stderrExcerptLength = 500

-- | The shared decoder for the §14 document: a nonempty @windows@ array,
-- each element a nonempty string @label@, an integer @pct_left@ in 0-100,
-- and an ISO-8601 UTC @resets_at@. Any decode failure -- malformed JSON, a
-- missing or out-of-range field, or an empty array -- fails closed as
-- 'UnsupportedVersion' rather than inventing a partial snapshot.
-- @fetchedAt@ comes from the refresh clock, not the document: the command
-- supplies only windows.
decodeUsageCommandDocument :: UTCTime -> LazyByteString.ByteString -> Either ProviderError UsageSnapshot
decodeUsageCommandDocument fetchedAt bytes = case eitherDecode bytes of
  Left message -> Left (ProviderError UnsupportedVersion ("unsupported usage command output: " <> Text.pack message))
  Right value -> case parseEither parseUsageWindows value of
    Left message -> Left (ProviderError UnsupportedVersion ("unsupported usage command output: " <> Text.pack message))
    Right windows -> Right (UsageSnapshot windows fetchedAt)

parseUsageWindows :: Value -> Parser [UsageWindow]
parseUsageWindows = withObject "usage command document" $ \document -> do
  windowValues <- document .: "windows" :: Parser [Value]
  windows <- mapM parseUsageWindow windowValues
  if null windows then fail "windows must be a nonempty array" else pure windows

parseUsageWindow :: Value -> Parser UsageWindow
parseUsageWindow = withObject "usage window" $ \window -> do
  label <- window .: "label"
  when (Text.null label) (fail "label must be a nonempty string")
  pctLeft <- window .: "pct_left"
  when (pctLeft < 0 || pctLeft > 100) (fail "pct_left must be within 0-100")
  resetsAt <- window .: "resets_at"
  pure UsageWindow {usageWindowLabel = label, usagePercentLeft = pctLeft, usageResetsAt = resetsAt}
