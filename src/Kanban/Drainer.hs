module Kanban.Drainer
  ( DrainerController (..),
    DrainerState (..),
    DrainerStatus (..),
    DrainerToggle (..),
    controllerFromProgramArguments,
    decodeDrainerStatus,
    discoverDrainerController,
    drainerIsRunning,
    drainerToggle,
    queryDrainerStatus,
    runDrainerCommand,
    setDrainerRunning,
    statusFromControllerExit,
  )
where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, try)
import Control.Monad (void)
import Data.Aeson (FromJSON (..), eitherDecode, withObject, (.:), (.:?))
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Domain (Repository (..))
import Kanban.Process
  ( ProcessIdentity (..),
    defaultProcessSnapshot,
    killVerifiedGroup,
  )
import System.Directory (getHomeDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, hGetContents')
import System.Posix.Process (getProcessGroupIDOf, setProcessGroupIDOf)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (..),
    createProcess,
    getPid,
    proc,
    waitForProcess,
  )
import System.Timeout (timeout)

data DrainerController = DrainerController
  { controllerExecutable :: FilePath,
    controllerArguments :: [String]
  }
  deriving stock (Eq, Show)

data DrainerState
  = DrainerOff
  | DrainerOn
  | DrainerStarting
  | DrainerStopping
  | DrainerWarning
  | DrainerError
  deriving stock (Eq, Show)

data DrainerStatus = DrainerStatus
  { drainerState :: DrainerState,
    drainerDetail :: Text
  }
  deriving stock (Eq, Show)

-- | What pressing @d@ (or clicking the drainer button) should do.
data DrainerToggle
  = StartDrainer
  | StopDrainer
  | -- | Issue nothing and say this instead.
    DrainerToggleBusy Text
  deriving stock (Eq, Show)

-- | Why a controller invocation produced no exit status at all. Rendering is
-- left to the caller because what a timeout means depends on the operation:
-- a killed @status@ query changed nothing, whereas a @start@ or @stop@ cut
-- short mid-transition leaves launchd in a state only the next poll can
-- establish.
data InvocationFailure
  = -- | The controller could not be run, or died taking the invocation with it.
    InvocationFailed Text
  | -- | Timed out, then terminated and confirmed gone.
    InvocationTimedOut
  | -- | Timed out, and termination could not be confirmed — so unlike
    -- 'InvocationTimedOut' the controller may still be running, and the
    -- caller must not report this as a settled timeout.
    InvocationNotTerminated Text

data RawIncident = RawIncident
  { rawIncidentSummary :: Maybe Text
  }
  deriving stock (Eq, Show)

instance FromJSON RawIncident where
  parseJSON = withObject "PR drainer incident" $ \value ->
    RawIncident <$> value .:? "summary"

data RawStatus = RawStatus
  { rawState :: Text,
    rawIncident :: Maybe RawIncident
  }
  deriving stock (Eq, Show)

instance FromJSON RawStatus where
  parseJSON = withObject "PR drainer status" $ \value ->
    RawStatus <$> value .: "state" <*> value .:? "open_incident"

discoverDrainerController :: Repository -> IO (Either Text DrainerController)
discoverDrainerController repository = do
  home <- getHomeDirectory
  let plist = home </> "Library" </> "LaunchAgents" </> "com.coghex.drain-prs.plist"
  result <- runProcess discoveryTimeoutSeconds "/usr/bin/plutil" ["-extract", "ProgramArguments", "json", "-o", "-", plist]
  pure $ do
    output <- case result of
      Left failure -> Left (invocationFailureMessage discoveryTimeoutSeconds "reading the launchd job" False failure)
      Right (ExitSuccess, standardOutput, _) -> Right standardOutput
      Right (ExitFailure _, standardOutput, errors) -> Left (diagnosticMessage standardOutput errors)
    arguments <- case eitherDecode (LazyByteString.pack output) of
      Left message -> Left ("could not decode launchd ProgramArguments: " <> Text.pack message)
      Right values -> Right values
    controllerFromProgramArguments repository arguments

controllerFromProgramArguments :: Repository -> [String] -> Either Text DrainerController
controllerFromProgramArguments repository arguments = case arguments of
  executable : rawControllerArguments
    | not (null controllerArguments) ->
        Right
          ( DrainerController
              executable
              (controllerArguments <> ["--path", repository.repositoryRoot])
          )
    where
      controllerArguments = stripManagedArguments rawControllerArguments
  _ -> Left "launchd ProgramArguments do not identify the PR drainer controller"

queryDrainerStatus :: DrainerController -> IO (Either Text DrainerStatus)
queryDrainerStatus controller = runDrainerCommand statusTimeoutSeconds controller "status"

setDrainerRunning :: DrainerController -> Bool -> IO (Either Text DrainerStatus)
setDrainerRunning controller shouldRun =
  runDrainerCommand transitionTimeoutSeconds controller (if shouldRun then "start" else "stop")

decodeDrainerStatus :: LazyByteString.ByteString -> Either Text DrainerStatus
decodeDrainerStatus bytes = do
  rawStatus <- case eitherDecode bytes of
    Left message -> Left ("could not decode PR drainer status: " <> Text.pack message)
    Right value -> Right value
  pure (statusFromRaw rawStatus)

drainerIsRunning :: DrainerStatus -> Bool
drainerIsRunning status = case status.drainerState of
  DrainerOn -> True
  DrainerWarning -> "on" `Text.isPrefixOf` status.drainerDetail
  _ -> False

-- | A start is only ever issued from a settled off state. @busy@ is a
-- transition this dashboard started and is still waiting on; a reported
-- 'DrainerStarting' is one it did not, seen through the ten-second status
-- poll. 'drainerIsRunning' calls the latter "not running", so without this
-- guard the toggle would answer a start already in flight with a second one
-- and rely on the controller treating that as a no-op.
drainerToggle :: Bool -> DrainerStatus -> DrainerToggle
drainerToggle busy status
  | busy = DrainerToggleBusy "PR drainer is already starting or stopping"
  | status.drainerState == DrainerStarting = DrainerToggleBusy "PR drainer is already starting"
  | drainerIsRunning status = StopDrainer
  | otherwise = StartDrainer

-- | The seconds-parameterised runner behind 'queryDrainerStatus' and
-- 'setDrainerRunning', exported so the termination and timeout-wording tests
-- can drive a wedged controller without waiting out a real transition budget.
runDrainerCommand :: Int -> DrainerController -> String -> IO (Either Text DrainerStatus)
runDrainerCommand seconds controller command = do
  result <-
    runProcess
      seconds
      controller.controllerExecutable
      (controller.controllerArguments <> ["--json", command])
  pure $ case result of
    Left failure -> Left (invocationFailureMessage seconds ("drainer " <> Text.pack command) (isTransition command) failure)
    Right (exitCode, output, errors) -> statusFromControllerExit exitCode output errors

-- | Interprets a controller invocation that ran to completion. A controller
-- that exits nonzero while still printing a status document is reporting
-- state, not failing — "stopped with an unresolved incident" is the natural
-- shape for that — and 'statusFromRaw' already renders exactly that in red
-- with the incident detail attached. So stdout is offered to the decoder
-- first even when stderr carries diagnostics, and only output that does not
-- decode falls back to the opaque error text.
statusFromControllerExit :: ExitCode -> String -> String -> Either Text DrainerStatus
statusFromControllerExit exitCode output errors =
  case (decodeDrainerStatus (LazyByteString.pack output), exitCode) of
    (Right status, _) -> Right status
    (Left decodeFailure, ExitSuccess) -> Left decodeFailure
    (Left _, ExitFailure _) -> Left (diagnosticMessage output errors)

diagnosticMessage :: String -> String -> Text
diagnosticMessage output errors = Text.strip . Text.pack $ if null errors then output else errors

-- | Renders an invocation that never produced an exit status. @reconciles@
-- says the operation has a state consequence the ten-second status poll will
-- settle, which is true of @start@ and @stop@ and of nothing else here: a
-- transition killed part-way through leaves launchd in a state this process
-- genuinely does not know, and saying only "timed out" would read as
-- "nothing happened". A cleanup that could not confirm termination never
-- gets that reconciliation promise, because a controller that may still be
-- running can still change the state the poll is about to read.
invocationFailureMessage :: Int -> Text -> Bool -> InvocationFailure -> Text
invocationFailureMessage seconds label reconciles failure = case failure of
  InvocationFailed message -> message
  InvocationTimedOut
    | reconciles -> timedOut <> "; the outcome is unknown and the next status poll will reconcile it"
    | otherwise -> timedOut
  InvocationNotTerminated message -> timedOut <> "; " <> message
  where
    timedOut = label <> " timed out after " <> Text.pack (show seconds) <> " seconds"

isTransition :: String -> Bool
isTransition command = command == "start" || command == "stop"

-- | Runs one controller invocation as the leader of its own process group,
-- so a wedged one can be cleaned up as a group rather than as a lone child.
-- 'System.Process.readProcessWithExitCode', which this replaces, terminates
-- only the direct child on abandonment and never confirms it exited: a
-- controller ignoring TERM, or one that has left a @launchctl@ behind, could
-- outlive the timeout that reported it dead and still be running when the
-- next ten-second poll starts another one.
runProcess :: Int -> FilePath -> [String] -> IO (Either InvocationFailure (ExitCode, String, String))
runProcess seconds executable arguments = do
  spawned <- try @IOException (createProcess groupedProcess)
  case spawned of
    Left exception -> pure (Left (InvocationFailed (Text.pack (show exception))))
    Right handles -> do
      -- Taken before the invocation can finish, so it is still answerable.
      owned <- confirmOwnedGroup (processHandleOf handles)
      completed <- try @IOException (timeout (seconds * 1000 * 1000) (collect handles))
      case completed of
        Left exception -> do
          void (abandonController owned)
          pure (Left (InvocationFailed (Text.pack (show exception))))
        Right (Just outcome) -> pure (Right outcome)
        Right Nothing -> do
          terminated <- abandonController owned
          case terminated of
            Left message -> pure (Left (InvocationNotTerminated message))
            -- Confirmed gone, so the handle is at most an unreaped zombie and
            -- waiting on it cannot block. Skipped entirely when termination
            -- was not confirmed, where it could block forever.
            Right () -> do
              void (try @IOException (waitForProcess (processHandleOf handles)))
              pure (Left InvocationTimedOut)
  where
    groupedProcess =
      (proc executable arguments)
        { std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }

    processHandleOf (_, _, _, processHandle) = processHandle

    -- Both pipes are drained concurrently and to EOF before the exit status
    -- is collected, exactly as 'readProcessWithExitCode' did, so output
    -- larger than a pipe buffer cannot deadlock the controller against a
    -- reader that has not run yet.
    collect (input, output, errors, processHandle) = do
      mapM_ (ignoreIOException . hClose) input
      standardOutput <- drain output
      standardError <- drain errors
      capturedOutput <- takeMVar standardOutput
      capturedError <- takeMVar standardError
      exitCode <- waitForProcess processHandle
      pure (exitCode, capturedOutput, capturedError)

    -- Each reader owns its handle for the handle's whole life, including
    -- closing it. Closing from here instead would take a lock a reader
    -- thread may still be blocked on, and would hang the cleanup that has to
    -- finish promptly. A read that fails contributes nothing rather than
    -- killing the invocation: the exit status and the other stream still say
    -- something worth reporting.
    drain Nothing = newEmptyMVar >>= \captured -> putMVar captured "" >> pure captured
    drain (Just handle) = do
      captured <- newEmptyMVar
      void . forkIO $ do
        text <- try @IOException (hGetContents' handle)
        ignoreIOException (hClose handle)
        putMVar captured (either (const "") id text)
      pure captured

-- | Establishes that the controller leads the process group named by its own
-- PID, while it is still known alive and before anything depends on the
-- answer. Taking ownership here rather than at cleanup time is what lets a
-- timeout terminate the group even after the controller itself has exited:
-- a leader that exits into a zombie is gone from every process snapshot, yet
-- a descendant holding the inherited pipes open is exactly what kept the
-- read blocked long enough to time out. Asked only at cleanup, that case is
-- indistinguishable from a pgid this process never owned, and refusing it
-- would leave the descendant running for the next poll to overlap.
--
-- The recorded pgid stays valid for the rest of the invocation because the
-- handle is not reaped until after cleanup: the leader keeps its PID, and a
-- zombie remains a member of its own group, so neither the PID nor the group
-- id it names can be recycled underneath this.
confirmOwnedGroup :: ProcessHandle -> IO (Either Text Int)
confirmOwnedGroup processHandle = do
  spawnedPid <- getPid processHandle
  case spawnedPid of
    Nothing -> pure (Left "the drainer controller reported no PID to take ownership of")
    Just pid -> do
      -- @create_group@ has the child call @setpgid(0, 0)@ itself, but that
      -- happens after the fork, so a read taken right now could still see
      -- the old group and wrongly conclude the child leads nothing. POSIX
      -- allows the parent to set the same group for a child that has not
      -- exec'd, which closes precisely that window. The attempt is not
      -- itself the verdict — failing with EACCES only means the child got
      -- there first — so the read below is the sole authority either way.
      void (try @IOException (setProcessGroupIDOf pid pid))
      actual <- try @IOException (getProcessGroupIDOf pid)
      pure $ case actual of
        Left exception -> Left ("could not read the drainer controller's process group: " <> Text.pack (show exception))
        Right groupId
          | groupId == pid -> Right (fromIntegral pid)
          | otherwise -> Left "the drainer controller did not lead its own process group, so what it starts cannot be terminated with it"

-- | Terminates a timed-out controller and everything it left running,
-- re-censusing and re-killing until a fresh snapshot shows the group empty
-- or the pass budget runs out. An ownership failure carried in from
-- 'confirmOwnedGroup' fails closed here, because the caller's alternative —
-- reporting a settled timeout — would be a claim about a process this never
-- actually accounted for.
--
-- One pass is not enough, and not merely as a race technicality.
-- 'killVerifiedGroup' stops as soon as the members it censused before
-- signalling are gone, which means a TERM handler that forks a fresh
-- same-group child and then lets the censused members exit satisfies that
-- pass without SIGKILL ever being sent — leaving the group occupied by a
-- process no signal has yet reached. Each pass therefore begins with a new
-- census, and only a snapshot showing the group actually empty ends the
-- loop: a snapshot that could not be taken is not an empty group, and
-- neither is one this stopped looking at.
abandonController :: Either Text Int -> IO (Either Text ())
abandonController (Left ownership) = pure (Left ownership)
abandonController (Right groupPid) = terminatePass terminationPasses
  where
    terminatePass passesLeft = do
      snapshot <- defaultProcessSnapshot
      case snapshot of
        Left message -> pure (Left ("could not take a process snapshot to terminate it: " <> message))
        -- An empty census is the confirmation, not a precondition: the
        -- leader may already be a zombie, which every snapshot here
        -- excludes, so this never requires it to be present.
        Right processes -> case groupMembers groupPid processes of
          [] -> pure (Right ())
          members
            | passesLeft <= (0 :: Int) -> pure (Left (survivorMessage members))
            | otherwise -> do
                killed <- killVerifiedGroup groupPid members
                either (pure . Left) (const (terminatePass (passesLeft - 1))) killed

    survivorMessage members =
      Text.pack (show (length members))
        <> " process(es) the drainer controller led were still running after "
        <> Text.pack (show terminationPasses)
        <> " termination passes"

groupMembers :: Int -> [ProcessIdentity] -> [ProcessIdentity]
groupMembers groupPid = filter ((== groupPid) . processIdentityGroupPid)

ignoreIOException :: IO () -> IO ()
ignoreIOException action = void (try @IOException action)

-- | How many escalation passes a timed-out invocation gets before it reports
-- survivors; a final census after the last one decides the verdict. Two is
-- the minimum that can settle a TERM handler which forks a replacement and
-- exits — the first pass ends on the censused members' departure without
-- ever reaching SIGKILL, and the second finds and kills what it left behind
-- — so three leaves one pass of margin without letting a controller that
-- forks on every signal hold the cleanup open indefinitely.
terminationPasses :: Int
terminationPasses = 3

discoveryTimeoutSeconds :: Int
discoveryTimeoutSeconds = 3

statusTimeoutSeconds :: Int
statusTimeoutSeconds = 4

transitionTimeoutSeconds :: Int
transitionTimeoutSeconds = 30

stripRunArgument :: [String] -> [String]
stripRunArgument arguments = case reverse arguments of
  "run" : rest -> reverse rest
  _ -> arguments

stripManagedArguments :: [String] -> [String]
stripManagedArguments = removePathArgument . stripRunArgument
  where
    removePathArgument ("--path" : _ : rest) = removePathArgument rest
    removePathArgument (argument : rest) = argument : removePathArgument rest
    removePathArgument [] = []

statusFromRaw :: RawStatus -> DrainerStatus
statusFromRaw rawStatus = case (rawStatus.rawState, rawStatus.rawIncident) of
  ("running", Nothing) -> DrainerStatus DrainerOn "on"
  ("running", Just incident) -> DrainerStatus DrainerWarning ("on · unresolved incident" <> incidentDetail incident)
  ("starting", _) -> DrainerStatus DrainerStarting "starting…"
  ("external", _) -> DrainerStatus DrainerWarning "on outside launchd"
  ("foreign", _) -> DrainerStatus DrainerWarning "another repository is running"
  ("dirty", _) -> DrainerStatus DrainerError "uncommitted changes; drainer will not start"
  ("stopped", Nothing) -> DrainerStatus DrainerOff "off"
  ("stopped", Just incident) -> DrainerStatus DrainerError ("stopped · unresolved incident" <> incidentDetail incident)
  (other, _) -> DrainerStatus DrainerError ("unknown state: " <> other)

incidentDetail :: RawIncident -> Text
incidentDetail incident = maybe "" (" · " <>) incident.rawIncidentSummary
