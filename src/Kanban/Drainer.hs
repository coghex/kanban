module Kanban.Drainer
  ( DirectMergeDecision (..),
    DirectMergeEffect (..),
    DirectMergeOutcome (..),
    DrainerActivity (..),
    DrainerController (..),
    DrainerIncident (..),
    DrainerObservation (..),
    DrainerRecord (..),
    DrainerScriptSource (..),
    DrainerState (..),
    DrainerStatus (..),
    DrainerToggle (..),
    cleanupIncidentKind,
    controllerFromProgramArguments,
    crashIncidentKind,
    decodeDirectMergeResult,
    decodeDrainerStatus,
    directMergeArguments,
    directMergeDecision,
    directMergeEffect,
    discoverDrainerController,
    drainerIsRunning,
    drainerRecordFromBytes,
    drainerRecordPath,
    drainerToggle,
    normalizedRepositoryIdentity,
    queryDrainerStatus,
    resolveDrainerPlist,
    resolveSinglePullRequestDrainer,
    resolveSinglePullRequestDrainerAt,
    runDirectMerge,
    runDrainerCommand,
    selectSinglePullRequestDrainer,
    setDrainerRunning,
    singlePullRequestDrainerPath,
    statusFromControllerExit,
    -- | Exported for the discovery-wording tests, which cannot reach this
    -- branch through 'discoverDrainerController': it needs a plist that
    -- @plutil@ rejects, and the test host may have neither.
    unreadablePlist,
  )
where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, try)
import Control.Monad (void)
import Data.Aeson (FromJSON (..), Value, eitherDecode, eitherDecodeStrict, withObject, (.!=), (.:), (.:?))
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Domain
  ( BoardColumn (..),
    BoardItem (..),
    Issue (..),
    PullRequest (..),
    Repository (..),
    WorkflowConfig,
  )
import Kanban.Process
  ( ProcessIdentity (..),
    defaultProcessSnapshot,
    killVerifiedGroup,
  )
import Kanban.Text (sanitizeText, withoutJsonPath)
import Kanban.Workflow (classifyPullRequest, itemCompleted, readOnlyHistoryNotice)
import System.Directory (doesFileExist, findExecutable, getHomeDirectory)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, takeDirectory, (</>))
import System.IO (hClose, hGetContents')
import System.Info (os)
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

-- | What the controller reported about the service itself, separated from the
-- prose 'drainerDetail' renders it as. The sidebar wants one string; a
-- decision wants the distinctions that string flattens — "running under
-- launchd" against "running outside it", "off" against "no status at all" —
-- and re-deriving them by reading the prose back would make display wording
-- load-bearing.
data DrainerActivity
  = -- | Settled off, with nothing in the checkout blocking a start.
    DrainerServiceStopped
  | -- | The runner and its drainer child are both alive under launchd.
    DrainerServiceRunning
  | -- | A runner is up without its drainer child, so launchd is mid-start.
    DrainerServiceStarting
  | -- | A stop is still in flight. Only ever set locally: the controller
    -- reports no such state, because a stop it has returned from is settled.
    DrainerServiceStopping
  | -- | A drainer process holds this repository's run lock without launchd
    -- having started it.
    DrainerServiceExternal
  | -- | The checkout is stopped part-way through a git operation, which the
    -- drainer cannot act through.
    DrainerServiceBlocked
  | -- | No usable status: the controller could not be discovered or run, its
    -- document did not decode, or it named a state this does not recognize.
    -- Every one of those is "unknown", never "off".
    DrainerServiceUnknown
  deriving stock (Eq, Show)

data DrainerStatus = DrainerStatus
  { drainerState :: DrainerState,
    drainerDetail :: Text,
    -- | The controller's own state, undecorated.
    drainerActivity :: DrainerActivity,
    -- | The unresolved incident the controller reported, as its summary.
    -- 'Nothing' means there is no open incident — the distinction
    -- 'directMergeDecision' turns on — so an incident that carries no summary
    -- is @Just ""@ rather than 'Nothing'.
    --
    -- This is the sidebar's newest-incident projection of @open_incident@,
    -- not 'DrainerObservation.observedIncidents'. Deliberately: the panel's
    -- set is 'Nothing' for a controller predating @open_incidents@, which
    -- would make @m@ merge straight past an incident such a controller is
    -- still reporting here. Asking the field every controller writes is what
    -- keeps the refusal fail-closed across versions.
    drainerIncident :: Maybe Text
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

-- | One open incident the controller reported, as the incidents panel lists
-- it. Distinct from 'RawIncident', which is only ever the newest incident's
-- summary for the sidebar and stays that way.
--
-- 'incidentPullRequest' is the only navigable field: it is written by the
-- drainer as the pull request an incident is /about/, so a conflict or
-- cleanup incident names a card. A supervisor crash has none, and its
-- 'incidentLastPullRequest' — inferred by grepping @PR #\<n\>@ out of the
-- last log lines — is diagnostic only. Following that would send a user to
-- whichever pull request happened to be mentioned last, which is not what
-- the crash is about.
data DrainerIncident = DrainerIncident
  { -- | The service-provided identity. Required: an incident that names
    -- itself is what lets a selection survive a refresh that reorders the
    -- list, and one that does not cannot be safely selected at all.
    incidentId :: Text,
    incidentKind :: Text,
    incidentSummary :: Maybe Text,
    incidentPullRequest :: Maybe Int,
    incidentLastPullRequest :: Maybe Int,
    incidentActivity :: Maybe Text,
    -- | The failure the drainer recorded on the pass that last kept a
    -- post-merge cleanup from finishing. Written by the service for a
    -- cleanup incident only, refreshed in place on every later pass, and
    -- absent from a document written before the field existed — so this
    -- stays a 'Maybe' and no reader may assume a cleanup incident has one.
    incidentError :: Maybe Text
  }
  deriving stock (Eq, Show)

instance FromJSON DrainerIncident where
  parseJSON = withObject "PR drainer open incident" $ \value ->
    DrainerIncident
      <$> value .: "incident_id"
      <*> value .:? "kind" .!= crashIncidentKind
      <*> value .:? "summary"
      <*> value .:? "pull_request"
      <*> value .:? "last_pr"
      <*> value .:? "last_activity"
      <*> value .:? "last_error"

-- | The kind the service gives an incident written before the field existed,
-- mirrored here so both sides classify a legacy incident the same way.
crashIncidentKind :: Text
crashIncidentKind = "drainer-exit"

-- | The kind the service gives a merged pull request whose post-merge
-- cleanup keeps failing. It is the only kind that records a failure the
-- operator can act on, so it is the only one whose 'incidentError' is read.
cleanupIncidentKind :: Text
cleanupIncidentKind = "cleanup-pending"

-- | One pull request the controller reported as still owing post-merge
-- cleanup. Nothing is carried out of a member: the sidebar states how many
-- pull requests owe, and the steps themselves belong to the controller's own
-- output. It is still held to naming its pull request, exactly as
-- 'DrainerIncident' is held to naming its incident — a member that does not
-- is not a projection this side can report a count of.
data RawObligation = RawObligation
  deriving stock (Eq, Show)

instance FromJSON RawObligation where
  parseJSON = withObject "PR drainer cleanup obligation" $ \value ->
    RawObligation <$ (value .: "pull_request" :: Parser Int)

data RawStatus = RawStatus
  { rawState :: Text,
    -- | Which git operation a @mid_operation@ checkout is stopped part-way
    -- through, so the board can name what has to be finished.
    rawOperation :: Maybe Text,
    rawIncident :: Maybe RawIncident,
    rawIncidents :: Maybe [DrainerIncident],
    -- | The post-merge debt the controller read out of the drainer's queue
    -- state. 'Nothing' is not an empty set: a controller predating the field,
    -- or one that could not read that state, has said nothing about the debt,
    -- and the sidebar then says nothing about it either.
    rawObligations :: Maybe [RawObligation]
  }
  deriving stock (Eq, Show)

instance FromJSON RawStatus where
  parseJSON = withObject "PR drainer status" $ \value ->
    RawStatus
      <$> value .: "state"
      <*> value .:? "operation"
      <*> value .:? "open_incident"
      <*> value .:? "open_incidents"
      <*> value .:? "cleanup_obligations"

-- | One controller response: the sidebar's status projection, and the
-- complete repository-scoped set of open incidents behind it.
--
-- The two are separate fields rather than one enriched status because they
-- answer different questions and must be allowed to differ. 'observedStatus'
-- summarises the /newest/ incident only, and issue #128 keeps that sidebar
-- behavior unchanged; 'observedIncidents' is the whole set the incidents
-- panel lists.
--
-- 'Nothing' is not an empty set. A controller that reported no
-- @open_incidents@ field at all — one predating it — has told this side
-- nothing about the set, and the panel must present that as an unavailable
-- source rather than as "nothing needs attention".
data DrainerObservation = DrainerObservation
  { observedStatus :: DrainerStatus,
    observedIncidents :: Maybe [DrainerIncident]
  }
  deriving stock (Eq, Show)

-- | What the drainer's installer recorded about the launchd job it wrote for
-- one repository. The record carries the job's location, never its content:
-- discovery still reads @ProgramArguments@ out of the plist itself, so a
-- hand-edited plist remains what Kanban reports and controls. Reading the
-- label from here rather than deriving it is what keeps this side from having
-- to reimplement the installer's per-repository naming — a disagreement there
-- would present as "drainer not found" with both sides looking correct in
-- isolation.
data DrainerRecord = DrainerRecord
  { -- | The launchd label the plist was written for. Kanban composes no path
    -- from it — the record carries the plist path directly — but a record
    -- naming no label describes no job, so it is required and checked here
    -- rather than accepted and ignored.
    drainerRecordLabel :: Text,
    drainerRecordPlist :: FilePath,
    -- | Which checkout the job was installed for. Metadata only: the
    -- controller is deliberately rebound to the dashboard's own checkout by
    -- 'controllerFromProgramArguments', and a second checkout of the same
    -- repository is that repository's own drainer rather than a foreign one.
    drainerRecordRepository :: FilePath
  }
  deriving stock (Eq, Show)

instance FromJSON DrainerRecord where
  parseJSON = withObject "PR drainer install record" $ \value ->
    DrainerRecord
      <$> value .: "launchd_label"
      <*> value .: "plist_path"
      <*> value .: "repository"

-- | The installed document, which holds one record per canonical GitHub
-- repository plus the installer's own shared keys. Entries stay unparsed until
-- one is selected, so a malformed record for a repository this dashboard is
-- not about cannot make every other repository's drainer undiscoverable.
newtype DrainerRecordDocument = DrainerRecordDocument (Map Text Value)

instance FromJSON DrainerRecordDocument where
  parseJSON = withObject "PR drainer install record" $ \value ->
    DrainerRecordDocument . fromMaybe Map.empty <$> value .:? "repositories"

-- | The key a repository's record is filed under, and the identity the
-- controller resolves the same checkout's remote to. GitHub owner and
-- repository names are case-insensitive, so the key is case-folded: two
-- spellings that differ only in case name one repository, and must therefore
-- find one drainer rather than two.
normalizedRepositoryIdentity :: Repository -> Text
normalizedRepositoryIdentity repository =
  Text.toLower repository.repositoryOwner <> "/" <> Text.toLower repository.repositoryName

-- | The fixed location the installer writes that document to. Deliberately not
-- derived from @KANBAN_DRAINER_INSTALL_DIR@: an install made with
-- @--install-dir@ still has to be discoverable by a dashboard that never saw
-- that option, so the document's own path is the one thing that cannot move.
drainerRecordPath :: IO FilePath
drainerRecordPath = do
  home <- getHomeDirectory
  pure (home <> "/Library/Application Support/kanban/pr-drainer/config.json")

-- | Selects this repository's record, rejecting a document that cannot name a
-- launchd job for it. A missing entry is reported separately from a malformed
-- one: the first is an uninstalled — or unmigrated — repository, and the
-- second is a record that parses without identifying anything, since an empty
-- label or a relative plist path names no job either. Both send the user back
-- to the installer rather than on to a lookup that cannot succeed.
drainerRecordFromBytes ::
  Text -> ByteString.ByteString -> Either Text (Maybe DrainerRecord)
drainerRecordFromBytes identity bytes = do
  DrainerRecordDocument records <- case eitherDecodeStrict bytes of
    Left message -> Left (withoutJsonPath (Text.pack message))
    Right document -> Right document
  case Map.lookup identity records of
    Nothing -> Right Nothing
    Just value -> Just <$> validated value
  where
    validated value = case parseEither parseJSON value of
      Left message -> Left (withoutJsonPath (Text.pack message))
      Right record
        | Text.null (Text.strip record.drainerRecordLabel) ->
            Left "it names no launchd label"
        | not (isAbsolute record.drainerRecordPlist) ->
            Left ("its plist path is not absolute: " <> Text.pack record.drainerRecordPlist)
        | otherwise -> Right record

-- | Resolves this repository's installed plist through that document, naming
-- the remediation for every way the lookup can fail rather than letting an
-- @IOException@ render itself as the drainer's status. Parameterised by the
-- host operating system, the repository identity, and the document path so
-- each branch is exercisable off a macOS host.
resolveDrainerPlist :: String -> Text -> FilePath -> IO (Either Text FilePath)
resolveDrainerPlist hostOperatingSystem identity recordPath
  | hostOperatingSystem /= "darwin" =
      pure (Left "the PR drainer is a launchd job and needs macOS to run")
  | otherwise = do
      recorded <- doesFileExist recordPath
      if not recorded
        then pure (Left notInstalled)
        else do
          contents <- try @IOException (ByteString.readFile recordPath)
          case fmap (drainerRecordFromBytes identity) contents of
            Left _ -> pure (Left (unreadableRecord "it could not be read"))
            Right (Left message) -> pure (Left (unreadableRecord message))
            Right (Right Nothing) -> pure (Left notInstalled)
            Right (Right (Just record)) -> plistOf record
  where
    notInstalled =
      "the PR drainer is not installed for "
        <> identity
        <> ", or predates its per-repository install record; "
        <> reinstallHint

    plistOf record = do
      installed <- doesFileExist record.drainerRecordPlist
      pure $
        if installed
          then Right record.drainerRecordPlist
          else
            Left
              ( "the PR drainer's LaunchAgent is missing at "
                  <> Text.pack record.drainerRecordPlist
                  <> "; "
                  <> reinstallHint
              )

    unreadableRecord detail =
      "the PR drainer's install record at "
        <> Text.pack recordPath
        <> " is unreadable ("
        <> detail
        <> "); "
        <> reinstallHint

reinstallHint :: Text
reinstallHint = "run `python3 tools/install_drainer.py` from the Kanban checkout"

discoverDrainerController :: Repository -> IO (Either Text DrainerController)
discoverDrainerController repository = do
  recordPath <- drainerRecordPath
  resolved <- resolveDrainerPlist os (normalizedRepositoryIdentity repository) recordPath
  case resolved of
    Left message -> pure (Left message)
    Right plist -> do
      result <- runProcess (Just discoveryTimeoutSeconds) "/usr/bin/plutil" ["-extract", "ProgramArguments", "json", "-o", "-", plist]
      pure $ do
        output <- case result of
          Left failure -> Left (unreadablePlist plist (invocationFailureMessage discoveryTimeoutSeconds "reading the launchd job" False failure))
          Right (ExitSuccess, standardOutput, _) -> Right standardOutput
          Right (ExitFailure _, standardOutput, errors) -> Left (unreadablePlist plist (diagnosticMessage standardOutput errors))
        arguments <- case eitherDecode (LazyByteString.pack output) of
          Left message -> Left ("could not decode launchd ProgramArguments: " <> Text.pack message)
          Right values -> Right values
        controllerFromProgramArguments repository arguments

-- | A plist that is present but will not parse is the one failure the record
-- cannot diagnose, so it carries @plutil@'s own complaint — and, like every
-- other branch, the repair: rewriting the plist is exactly what re-running
-- the installer does.
unreadablePlist :: FilePath -> Text -> Text
unreadablePlist plist detail =
  "could not read the PR drainer's LaunchAgent at "
    <> Text.pack plist
    <> ": "
    <> detail
    <> "; "
    <> reinstallHint

-- | Rebinds the installed job's command to this dashboard's own checkout, and
-- states which repository that checkout is expected to be a clone of.
--
-- The identity travels as @--repo@ rather than being trusted: with
-- @kanban --repo OWNER\/NAME@ the board's identity comes from the user, not
-- from the checkout's remote, and honouring it unchecked would let a
-- dashboard select or create a drainer for a repository its checkout has
-- nothing to do with. The controller compares it against the remote and
-- refuses a mismatch, so the containment lives on the side that owns the job
-- rather than in a check this side could skip.
controllerFromProgramArguments :: Repository -> [String] -> Either Text DrainerController
controllerFromProgramArguments repository arguments = case arguments of
  executable : rawControllerArguments
    | not (null controllerArguments) ->
        Right
          ( DrainerController
              executable
              ( controllerArguments
                  <> [ "--path",
                       repository.repositoryRoot,
                       "--repo",
                       Text.unpack (normalizedRepositoryIdentity repository)
                     ]
              )
          )
    where
      controllerArguments = stripManagedArguments rawControllerArguments
  _ -> Left "launchd ProgramArguments do not identify the PR drainer controller"

queryDrainerStatus :: DrainerController -> IO (Either Text DrainerObservation)
queryDrainerStatus controller = runDrainerCommand statusTimeoutSeconds controller "status"

setDrainerRunning :: DrainerController -> Bool -> IO (Either Text DrainerObservation)
setDrainerRunning controller shouldRun =
  runDrainerCommand transitionTimeoutSeconds controller (if shouldRun then "start" else "stop")

decodeDrainerStatus :: LazyByteString.ByteString -> Either Text DrainerObservation
decodeDrainerStatus bytes = do
  rawStatus <- case eitherDecode bytes of
    Left message -> Left ("could not decode PR drainer status: " <> Text.pack message)
    Right value -> Right value
  pure (DrainerObservation (statusFromRaw rawStatus) rawStatus.rawIncidents)

-- | Whether a drainer is draining this repository right now, by whatever
-- route. Read off 'drainerActivity' rather than off the rendered detail,
-- which is what previously made "on outside launchd" and "on · unresolved
-- incident" depend on both beginning with the word @on@.
drainerIsRunning :: DrainerStatus -> Bool
drainerIsRunning status =
  status.drainerActivity `elem` [DrainerServiceRunning, DrainerServiceExternal]

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
runDrainerCommand :: Int -> DrainerController -> String -> IO (Either Text DrainerObservation)
runDrainerCommand seconds controller command = do
  result <-
    runProcess
      (Just seconds)
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
statusFromControllerExit :: ExitCode -> String -> String -> Either Text DrainerObservation
statusFromControllerExit exitCode output errors =
  case (decodeDrainerStatus (LazyByteString.pack output), exitCode) of
    (Right observation, _) -> Right observation
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
-- | 'Nothing' seconds runs the invocation to completion however long it
-- takes. Exactly one caller wants that — the single-pull-request merge, whose
-- work is irreversible partway through, so abandoning it on a deadline would
-- be worse than waiting. Every other invocation here is a status read or a
-- launchd transition, which has a budget precisely because nothing is lost by
-- cutting it short.
runProcess :: Maybe Int -> FilePath -> [String] -> IO (Either InvocationFailure (ExitCode, String, String))
runProcess seconds executable arguments = do
  spawned <- try @IOException (createProcess groupedProcess)
  case spawned of
    Left exception -> pure (Left (InvocationFailed (Text.pack (show exception))))
    Right handles -> do
      -- Taken before the invocation can finish, so it is still answerable.
      owned <- confirmOwnedGroup (processHandleOf handles)
      completed <- try @IOException (withBudget (collect handles))
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
    -- An unbounded run cannot time out, so 'collect' is simply awaited and
    -- the abandonment branches below stay unreachable for it.
    withBudget action = case seconds of
      Nothing -> Just <$> action
      Just budget -> timeout (budget * 1000 * 1000) action

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

-- | Drops the arguments this side supplies itself, so a plist carrying them
-- cannot make the rebuilt command name two checkouts or two repositories.
stripManagedArguments :: [String] -> [String]
stripManagedArguments = removeBoundArguments . stripRunArgument
  where
    removeBoundArguments (argument : _ : rest)
      | argument `elem` ["--path", "--repo"] = removeBoundArguments rest
    removeBoundArguments (argument : rest) = argument : removeBoundArguments rest
    removeBoundArguments [] = []

-- | The incident is carried on every state, not only the two whose detail
-- interleaves it: the controller reports @open_incident@ independently of
-- @state@, and a decision that has to let an incident outrank the state
-- cannot see one that was dropped for having nowhere to render.
statusFromRaw :: RawStatus -> DrainerStatus
statusFromRaw rawStatus = case (rawStatus.rawState, incident) of
  ("running", Nothing) -> reported DrainerOn DrainerServiceRunning "on"
  ("running", Just _) -> reported DrainerWarning DrainerServiceRunning ("on · unresolved incident" <> incidentDetail)
  ("starting", _) -> reported DrainerStarting DrainerServiceStarting "starting…"
  ("external", _) -> reported DrainerWarning DrainerServiceExternal "on outside launchd"
  ("mid_operation", _) -> reported DrainerError DrainerServiceBlocked (operationDetail rawStatus.rawOperation)
  ("stopped", Nothing) -> reported DrainerOff DrainerServiceStopped "off"
  ("stopped", Just _) -> reported DrainerError DrainerServiceStopped ("stopped · unresolved incident" <> incidentDetail)
  (other, _) -> reported DrainerError DrainerServiceUnknown ("unknown state: " <> other)
  where
    incident = fmap (fromMaybe "" . rawIncidentSummary) rawStatus.rawIncident
    incidentDetail = case incident of
      Just summary | not (Text.null summary) -> " · " <> summary
      _ -> ""
    reported state activity detail =
      DrainerStatus state (detail <> obligationDetail) activity incident
    -- Appended by every branch rather than by the two that mention an
    -- incident: debt survives a stop, so it is owed in every state the
    -- controller can report it from, and it is the state the drainer is *not*
    -- running in that no longer discharges it.
    obligationDetail = case rawStatus.rawObligations of
      Just obligations | not (null obligations) -> " · " <> owingClause (length obligations)
      _ -> ""
    owingClause :: Int -> Text
    owingClause 1 = "1 PR owes cleanup"
    owingClause owing = Text.pack (show owing) <> " PRs owe cleanup"

-- | Uncommitted work is no longer a reason the drainer will not start — its
-- fast-forward stashes and restores it — so the one repository condition left
-- to report is a checkout stopped part-way through a git operation, which
-- blocks that fast-forward until a human finishes it. The controller names
-- the operation; a controller that reports the state without one still gets a
-- message worth acting on.
operationDetail :: Maybe Text -> Text
operationDetail operation = case operation of
  Just name | not (Text.null name) -> name <> " in progress; finish or abort it"
  _ -> "unfinished git operation; finish or abort it"

-- * Merging one pull request directly

-- | The drainer's single-pull-request entry point inside a given install
-- directory. The only path this module composes for it, built with
-- 'System.FilePath' rather than an embedded separator; the directory itself
-- is never reconstructed here, it arrives from the environment, from the
-- discovered controller, or from the record's own location.
singlePullRequestDrainerPath :: FilePath -> FilePath
singlePullRequestDrainerPath installDir = installDir </> "drain_prs.py"

-- | Which of the three sources named the install directory. Carried so a
-- diagnostic can say what was actually consulted: a user who installed with
-- @--install-dir@ must not be told to re-run the bare installer command they
-- deliberately did not use.
data DrainerScriptSource
  = -- | @KANBAN_DRAINER_INSTALL_DIR@ selected this install directory.
    DrainerScriptFromEnvironment FilePath
  | -- | The discovered LaunchAgent runs its controller from this directory,
    -- so the drainer installed beside it is the one that job would run.
    DrainerScriptFromController FilePath
  | -- | Neither was available, so the directory holding the discovery record
    -- is the install.
    DrainerScriptFromDefault FilePath
  deriving stock (Eq, Show)

-- | Select where the installed drainer should be, without yet asking whether
-- it is there, or say why no location could be named at all.
--
-- Precedence is @KANBAN_DRAINER_INSTALL_DIR@, then the discovered
-- controller's own directory, then the directory the discovery record lives
-- in. The middle source is what keeps an install made with @--install-dir@
-- usable: 'tools/install_drainer.py' supplies that variable to the controller
-- installation it runs and writes it into the LaunchAgent's environment, and
-- a separately launched dashboard inherits neither. The plist, which the
-- record already leads to, names the installed controller — and the installer
-- links both scripts into one directory — so the drainer is its sibling.
--
-- A source that is present but names no resolvable directory fails here
-- rather than falling through to the next one. Falling through would run a
-- different installation than the one that was actually configured, which is
-- the one outcome worse than refusing: the merge would succeed, against the
-- wrong copy of the drainer, and say nothing.
selectSinglePullRequestDrainer ::
  Maybe String -> Maybe DrainerController -> FilePath -> Either Text (DrainerScriptSource, FilePath)
selectSinglePullRequestDrainer override controller recordPath = case selectedOverride of
  Just installDir
    -- A relative directory is resolved against whatever directory Kanban
    -- happened to be started from, so it names nothing dependable — and
    -- running the `drain_prs.py` that happens to sit there is exactly the
    -- accident this must not have.
    | not (isAbsolute installDir) ->
        Left
          ( "KANBAN_DRAINER_INSTALL_DIR is set to "
              <> Text.pack installDir
              <> ", which is not an absolute path and so names no install directory; "
              <> "set it to the directory `python3 tools/install_drainer.py --install-dir` "
              <> "installed into, or unset it to use the recorded installation"
          )
    | otherwise -> Right (selected DrainerScriptFromEnvironment installDir)
  Nothing -> case controller of
    Nothing -> Right (selected DrainerScriptFromDefault (takeDirectory recordPath))
    Just discovered -> case controllerInstallDir discovered of
      Just installDir -> Right (selected DrainerScriptFromController installDir)
      Nothing ->
        Left
          ( "the installed LaunchAgent does not run the PR drainer's controller from an "
              <> "absolute path, so the installation it belongs to cannot be located; "
              <> reinstallHint
          )
  where
    -- A blank override is how an unset variable often reaches a process
    -- through a wrapper script; treating it as a selection would resolve
    -- "/drain_prs.py".
    selectedOverride = case override of
      Just installDir | not (null (trimmed installDir)) -> Just installDir
      _ -> Nothing
    selected source installDir = (source installDir, singlePullRequestDrainerPath installDir)
    trimmed = Text.unpack . Text.strip . Text.pack

-- | The directory the discovered controller runs from.
-- 'controllerFromProgramArguments' has already stripped the arguments this
-- side supplies and guaranteed at least one remains, so the first is the
-- installed @drain_prs_service.py@ itself.
controllerInstallDir :: DrainerController -> Maybe FilePath
controllerInstallDir controller = case controller.controllerArguments of
  script : _ | isAbsolute script -> Just (takeDirectory script)
  _ -> Nothing

-- | Why the selected drainer is not where it was selected from. Each source
-- gets its own repair, and every one of them names the installer.
singlePullRequestDrainerNotFound :: DrainerScriptSource -> FilePath -> Text
singlePullRequestDrainerNotFound source scriptPath =
  "the PR drainer is not installed at " <> Text.pack scriptPath <> "; " <> repair
  where
    repair = case source of
      DrainerScriptFromEnvironment installDir ->
        "KANBAN_DRAINER_INSTALL_DIR selected "
          <> Text.pack installDir
          <> ", so install there with `python3 tools/install_drainer.py --install-dir "
          <> Text.pack installDir
          <> "`, or unset that variable to use the recorded installation"
      DrainerScriptFromController installDir ->
        "the installed LaunchAgent still runs its controller from "
          <> Text.pack installDir
          <> ", so that installation is incomplete; "
          <> reinstallHint
      DrainerScriptFromDefault _ -> reinstallHint

-- | 'selectSinglePullRequestDrainer' plus the existence check, parameterised
-- by the override, the discovered controller, and the record path so every
-- branch is exercisable against a temporary directory.
resolveSinglePullRequestDrainerAt ::
  Maybe String -> Maybe DrainerController -> FilePath -> IO (Either Text FilePath)
resolveSinglePullRequestDrainerAt override controller recordPath =
  case selectSinglePullRequestDrainer override controller recordPath of
    Left message -> pure (Left message)
    Right (source, scriptPath) -> do
      -- Absence, a directory occupying the path, and a link whose target is
      -- gone are all "not installed here" — and all fail closed, because the
      -- selection above already committed to one directory and nothing falls
      -- through to another.
      installed <- doesFileExist scriptPath
      pure $
        if installed
          then Right scriptPath
          else Left (singlePullRequestDrainerNotFound source scriptPath)

-- | 'resolveSinglePullRequestDrainerAt' against the real environment.
resolveSinglePullRequestDrainer :: Maybe DrainerController -> IO (Either Text FilePath)
resolveSinglePullRequestDrainer controller = do
  override <- lookupEnv "KANBAN_DRAINER_INSTALL_DIR"
  recordPath <- drainerRecordPath
  resolveSinglePullRequestDrainerAt override controller recordPath

-- | What pressing @m@ on the selected card should do.
data DirectMergeDecision
  = -- | Run the drainer's single-pull-request path for this pull request.
    RunDirectMerge Int
  | -- | Invoke nothing, and say this instead.
    RefuseDirectMerge Text
  deriving stock (Eq, Show)

-- | The whole decision, as a total function of the selection, whatever direct
-- merge is already in flight, and the last status the controller reported.
--
-- The order is the point. Settled history is answered before anything else:
-- a merged or closed pull request has no merge left to run, and so has a
-- closed issue, whatever the service is doing and whichever key reached here.
-- An ineligible selection comes next, because what is wrong is then the card
-- rather than the service, and reporting the drainer's state for an issue card
-- would be a true statement about the wrong thing. An unresolved incident
-- follows and outranks every service state: it is the one condition that says
-- merging is unsafe even though the service is idle. Only a service known to
-- be stopped, with no open incident, may launch — every other state, including
-- one this cannot classify at all, refuses, so a status that could not be read
-- never merges anything.
directMergeDecision ::
  WorkflowConfig ->
  -- | The pull request a direct merge this dashboard started is still
  -- running, if there is one.
  Maybe Int ->
  DrainerStatus ->
  Maybe BoardItem ->
  DirectMergeDecision
directMergeDecision config pending status selection
  | Just item <- selection, itemCompleted item = RefuseDirectMerge (readOnlyHistoryNotice item)
  | otherwise = case eligiblePullRequest config selection of
      Left refusal -> RefuseDirectMerge refusal
      Right number -> case pending of
        Just running ->
          RefuseDirectMerge
            ("PR #" <> showNumber running <> " is already being merged; wait for that run to finish")
        Nothing
          | Just summary <- status.drainerIncident -> RefuseDirectMerge (incidentRefusal summary)
          | otherwise -> case status.drainerActivity of
              DrainerServiceStopped -> RunDirectMerge number
              DrainerServiceRunning ->
                RefuseDirectMerge "the PR drainer is running and merges approved pull requests itself; stop it with d to merge one directly"
              DrainerServiceStarting ->
                RefuseDirectMerge "the PR drainer is starting; wait for it to settle, then stop it with d to merge one directly"
              DrainerServiceStopping ->
                RefuseDirectMerge "the PR drainer is stopping; wait for it to settle"
              DrainerServiceExternal ->
                RefuseDirectMerge "a PR drainer is already running outside launchd and holds this repository"
              DrainerServiceBlocked ->
                RefuseDirectMerge ("this checkout cannot be merged into yet: " <> status.drainerDetail)
              DrainerServiceUnknown ->
                RefuseDirectMerge ("the PR drainer's state could not be established, so nothing was merged: " <> status.drainerDetail)
  where
    incidentRefusal summary
      | Text.null summary = "the PR drainer has an unresolved incident; resolve it before merging"
      | otherwise = "the PR drainer has an unresolved incident: " <> summary

-- | The selected card as a pull request this action may act on, or why it is
-- not one. Eligibility is 'classifyPullRequest' itself rather than a second
-- reading of the same labels, so a card @m@ accepts is exactly a card the
-- board drew in Done.
eligiblePullRequest :: WorkflowConfig -> Maybe BoardItem -> Either Text Int
eligiblePullRequest _ Nothing =
  Left "no card is selected; select an approved pull request in Done to merge it"
eligiblePullRequest _ (Just (IssueItem issue)) =
  Left
    ( "#"
        <> showNumber issue.issueNumber
        <> " is an issue; m merges an approved pull request from Done"
    )
eligiblePullRequest config (Just (PullRequestItem pullRequest))
  | classifyPullRequest config pullRequest == Done = Right pullRequest.pullRequestNumber
  | otherwise =
      Left
        ( "PR #"
            <> showNumber pullRequest.pullRequestNumber
            <> " is not in Done, so it is not an approved pull request ready to merge"
        )

-- | What one @--pr@ run reported, once 'acceptedDirectMergeResult' has
-- established that the document really was this action's own. Only the fields
-- acted on survive that check; the schema, version and pull-request number
-- are what the check is made of and are not carried onward.
data DirectMergeOutcome = DirectMergeOutcome
  { -- | @merged@, @no_action@, or @error@.
    directMergeOutcomeKind :: Text,
    -- | Whether the pull request actually merged. True even for an @error@
    -- whose merge landed before the failure — the post-merge audit and the
    -- outstanding-cleanup reasons are exactly that case.
    directMergeMerged :: Bool,
    -- | The stable reason from the drainer's fixed vocabulary.
    directMergeReason :: Text,
    -- | The human-readable reason, which a caller may present verbatim.
    directMergeMessage :: Text
  }
  deriving stock (Eq, Show)

-- | The document exactly as written, before anything establishes that it is
-- the one this action asked for. Every field the contract promises is
-- required, including the three that identify the document: a run that
-- reports an outcome without saying which schema, which version, or which
-- pull request it is about has not answered this action's question.
data RawDirectMergeResult = RawDirectMergeResult
  { rawResultSchema :: Text,
    rawResultVersion :: Int,
    rawResultPullRequest :: Int,
    rawResultOutcome :: Text,
    rawResultMerged :: Bool,
    rawResultReason :: Text,
    rawResultMessage :: Text,
    rawResultDryRun :: Bool
  }
  deriving stock (Eq, Show)

instance FromJSON RawDirectMergeResult where
  parseJSON = withObject "PR drainer single-PR result" $ \value ->
    RawDirectMergeResult
      <$> value .: "schema"
      <*> value .: "version"
      <*> value .: "pull_request"
      <*> value .: "outcome"
      <*> value .: "merged"
      <*> value .: "reason"
      <*> value .: "message"
      <*> value .: "dry_run"

-- | The document this side knows how to read, and the outcome that means the
-- pull request landed. Spelled once here and used by both the check below and
-- the rendering above, so the two cannot drift apart.
directMergeSchema :: Text
directMergeSchema = "drain-prs-single-pr"

directMergeSchemaVersion :: Int
directMergeSchemaVersion = 1

mergedOutcome :: Text
mergedOutcome = "merged"

-- | Reads what one @--pr@ run reported. Empty stdout is a start-up failure
-- rather than a no-merge result — a usage error exits without writing the
-- document at all — so it is reported with whatever the run last said on
-- stderr instead of being decoded into silence.
decodeDirectMergeResult :: Int -> ExitCode -> String -> String -> Either Text DirectMergeOutcome
decodeDirectMergeResult number exitCode output errors =
  case eitherDecode (LazyByteString.pack output) of
    Right raw -> acceptedDirectMergeResult number raw
    Left message
      | Text.null (Text.strip (Text.pack output)) ->
          Left ("the PR drainer wrote no result and " <> exitDescription exitCode <> lastDiagnostic errors)
      | otherwise ->
          Left ("the PR drainer's result could not be read: " <> withoutJsonPath (Text.pack message))

-- | Establish that the document is the promised one, for the pull request
-- this run actually asked about, before any of it is believed.
--
-- Parsing the four outcome fields alone would let any JSON carrying them be
-- reported as a merge — and a merge is reported to the user and refetches the
-- board, so believing the wrong document is not a cosmetic error. The
-- resolver deliberately runs whatever is installed at the selected path, so
-- "some other script answered" is a reachable state rather than a
-- hypothetical one, and every way the answer can fail to be this action's own
-- is refused here rather than partially trusted.
acceptedDirectMergeResult :: Int -> RawDirectMergeResult -> Either Text DirectMergeOutcome
acceptedDirectMergeResult number raw
  | raw.rawResultSchema /= directMergeSchema =
      refuse ("it is a " <> raw.rawResultSchema <> " document rather than " <> directMergeSchema)
  -- Older and newer are both refused: this side knows what one version means,
  -- and a version it has never seen may have redefined the very fields the
  -- merge is reported through.
  | raw.rawResultVersion /= directMergeSchemaVersion =
      refuse
        ( "it is schema version "
            <> showNumber raw.rawResultVersion
            <> ", and this Kanban reads version "
            <> showNumber directMergeSchemaVersion
        )
  | raw.rawResultPullRequest /= number =
      refuse
        ( "it reports PR #"
            <> showNumber raw.rawResultPullRequest
            <> " rather than the PR #"
            <> showNumber number
            <> " this run asked about"
        )
  | raw.rawResultOutcome `notElem` [mergedOutcome, "no_action", "error"] =
      refuse ("it reports an outcome this Kanban does not know: " <> raw.rawResultOutcome)
  -- The remaining three are documents that contradict themselves. Each would
  -- otherwise resolve to a confident statement about a merge, in one
  -- direction or the other.
  | raw.rawResultOutcome == mergedOutcome, not raw.rawResultMerged =
      refuse "it reports a merged outcome while reporting that nothing merged"
  | raw.rawResultOutcome == "no_action", raw.rawResultMerged =
      refuse "it reports a merge under an outcome that means nothing was merged"
  | raw.rawResultDryRun, raw.rawResultMerged =
      refuse "it reports a merge from a dry run, which mutates nothing"
  | otherwise =
      Right
        ( DirectMergeOutcome
            raw.rawResultOutcome
            raw.rawResultMerged
            raw.rawResultReason
            raw.rawResultMessage
        )
  where
    refuse detail =
      Left
        ( "the PR drainer's result is not the one this action asked for ("
            <> detail
            <> "), so nothing is being reported as merged; check which drainer is "
            <> "installed at the resolved path, and "
            <> reinstallHint
        )

exitDescription :: ExitCode -> Text
exitDescription ExitSuccess = "exited successfully"
exitDescription (ExitFailure code) = "exited " <> Text.pack (show code)

-- | The last thing a run said before it stopped. A single-PR run sends its
-- whole human log to stderr, so the tail is the diagnosis while the head is
-- start-up noise no notice has room for.
lastDiagnostic :: String -> Text
lastDiagnostic errors =
  case reverse (filter (not . Text.null) (map Text.strip (Text.lines (Text.pack errors)))) of
    latest : _ -> ": " <> latest
    [] -> ""

-- | Explicit @--repo@ and @--path@, so the run always acts on the repository
-- Kanban resolved — including a @kanban --repo@ override, which may name
-- something other than the checkout's remote — rather than re-deriving
-- identity from that remote itself. The drainer compares the two and refuses
-- a mismatch, so the containment lives on the side that owns the merge.
-- @--config@ travels for the same reason it does for canonical issue review:
-- both sides must agree on the workflow labels the gates are written in.
directMergeArguments :: FilePath -> Repository -> Maybe FilePath -> Int -> [String]
directMergeArguments scriptPath repository configPath number =
  [ scriptPath,
    "--path",
    repository.repositoryRoot,
    "--repo",
    Text.unpack (normalizedRepositoryIdentity repository),
    "--pr",
    show number
  ]
    <> maybe [] (\path -> ["--config", path]) configPath

-- | Run the drainer's own single-pull-request path once. Deliberately
-- unbounded: every gate re-read, the merge, and the post-merge cleanup happen
-- inside this one invocation, and a deadline that killed it partway through
-- would abandon work that is already irreversible on GitHub.
runDirectMerge ::
  FilePath -> Repository -> Maybe FilePath -> Int -> IO (Either Text DirectMergeOutcome)
runDirectMerge scriptPath repository configPath number = do
  python <- findExecutable "python3"
  case python of
    Nothing -> pure (Left "python3 was not found on PATH")
    Just pythonPath -> do
      result <- runProcess Nothing pythonPath (directMergeArguments scriptPath repository configPath number)
      pure $ case result of
        Left (InvocationFailed message) -> Left ("the PR drainer could not be run: " <> message)
        -- Unreachable for an unbounded run, which has no deadline to miss.
        Left _ -> Left "the PR drainer's invocation ended without an exit status"
        Right (exitCode, output, errors) -> decodeDirectMergeResult number exitCode output errors

-- | What a finished direct merge changes on the board.
data DirectMergeEffect = DirectMergeEffect
  { -- | The notice to show. Sanitized here, once, because the drainer's
    -- message is external text on its way to a Brick widget.
    directMergeNotice :: Text,
    -- | Whether GitHub changed and the board must therefore be refetched.
    -- True for a merge whose post-merge work then failed as well: the merge
    -- itself is what the board is now stale about.
    directMergeRefreshesBoard :: Bool
  }
  deriving stock (Eq, Show)

-- | Renders one result. The drainer's own message is always carried through
-- rather than replaced by a generic sentence — it is the only text that says
-- which gate refused, or which cleanup step is outstanding — and a merge that
-- landed is never reported as a clean success when the run went on to fail.
directMergeEffect :: Int -> Either Text DirectMergeOutcome -> DirectMergeEffect
directMergeEffect number (Left message) =
  DirectMergeEffect (sanitizeText ("PR #" <> showNumber number <> " was not merged: " <> message)) False
directMergeEffect number (Right outcome) =
  DirectMergeEffect (sanitizeText headline) outcome.directMergeMerged
  where
    headline
      | outcome.directMergeMerged, outcome.directMergeOutcomeKind == mergedOutcome =
          "PR #" <> showNumber number <> " merged: " <> outcome.directMergeMessage
      | outcome.directMergeMerged =
          "PR #"
            <> showNumber number
            <> " merged, but the run did not finish cleanly ("
            <> outcome.directMergeReason
            <> "): "
            <> outcome.directMergeMessage
      | otherwise =
          "PR #"
            <> showNumber number
            <> " was not merged ("
            <> outcome.directMergeReason
            <> "): "
            <> outcome.directMergeMessage

showNumber :: Int -> Text
showNumber = Text.pack . show
