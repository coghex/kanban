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
    identityForPid,
    killVerifiedGroup,
  )
import System.Directory (getHomeDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, hGetContents')
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
      completed <- try @IOException (timeout (seconds * 1000 * 1000) (collect handles))
      case completed of
        Left exception -> do
          void (abandonController (processHandleOf handles))
          pure (Left (InvocationFailed (Text.pack (show exception))))
        Right (Just outcome) -> pure (Right outcome)
        Right Nothing -> do
          terminated <- abandonController (processHandleOf handles)
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

-- | Terminates a timed-out controller and everything it left running, then
-- proves the group is empty rather than inferring it from having signalled.
-- Every branch that cannot establish what happened fails closed with a
-- message, because the caller's alternative — reporting a settled timeout —
-- would be a claim about a process this never actually accounted for.
abandonController :: ProcessHandle -> IO (Either Text ())
abandonController processHandle = do
  spawnedPid <- getPid processHandle
  case spawnedPid of
    Nothing -> pure (Left "the timed-out drainer controller no longer had a PID to terminate")
    Just pid -> do
      let groupPid = fromIntegral pid
      snapshot <- defaultProcessSnapshot
      case snapshot of
        Left message -> pure (Left ("could not take a process snapshot to terminate it: " <> message))
        Right processes -> case identityForPid groupPid processes of
          -- Fail closed. The handle is unreaped, so the PID cannot have been
          -- reused — but without the controller itself in the snapshot
          -- nothing here can show that @groupPid@ names its group rather
          -- than the dashboard's own, and a TERM/KILL aimed at the wrong
          -- group would take the dashboard down with it. Reaching this at
          -- all means something outlived the controller and is holding its
          -- pipes open, which is the case worth refusing on.
          Nothing -> pure (Left "the timed-out drainer controller left the process table before its process group could be identified")
          Just identity
            | identity.processIdentityGroupPid /= groupPid ->
                pure (Left "the timed-out drainer controller did not lead its own process group, so what it started could not be terminated with it")
            | otherwise -> do
                killed <- killVerifiedGroup groupPid (groupMembers groupPid processes)
                either (pure . Left) (const (confirmGroupEmpty groupPid)) killed

groupMembers :: Int -> [ProcessIdentity] -> [ProcessIdentity]
groupMembers groupPid = filter ((== groupPid) . processIdentityGroupPid)

-- | 'killVerifiedGroup' proves only that the members censused before it
-- signalled are gone; one forked between that census and the signal was
-- never in its list. The group signals themselves did reach it — a group
-- signal goes to whatever is in the group when it is sent — but only a fresh
-- census showing the group actually empty establishes that, and a snapshot
-- that could not be taken is not an empty group.
confirmGroupEmpty :: Int -> IO (Either Text ())
confirmGroupEmpty groupPid = do
  snapshot <- defaultProcessSnapshot
  pure $ case snapshot of
    Left message -> Left ("could not confirm the drainer controller's process group was empty: " <> message)
    Right processes -> case groupMembers groupPid processes of
      [] -> Right ()
      survivors ->
        Left
          ( Text.pack (show (length survivors))
              <> " process(es) the drainer controller led are still running"
          )

ignoreIOException :: IO () -> IO ()
ignoreIOException action = void (try @IOException action)

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
