-- | The persistent per-repository issue approval service, as the dashboard
-- sees it: the discovery record its installer writes, the controller handle
-- read out of the installed job, the status document that controller
-- publishes, the incidents beside it, and what a toggle press decides.
--
-- Deliberately its own module rather than more of "Kanban.Drainer", and
-- deliberately sharing no constructor with it. The two services are similar by
-- design — one installer shape, one discovery-record shape, one controller
-- contract — but their states mean different things: a drainer's incident is
-- about a pull request and this one's is about an issue whose specification
-- needs repairing, and neither controller owns the other's process. A shared
-- type would let one service's state be assigned to the other's field and
-- compile.
--
-- What /is/ shared is spelled as such: 'normalizedRepositoryIdentity' is the
-- one definition of a canonical repository identity, and
-- "Kanban.ServiceProcess" is the one definition of a bounded, process-grouped
-- controller invocation.
module Kanban.ApprovalService
  ( -- * The installed job
    ApprovalBackend (..),
    ApprovalController (..),
    ApprovalRecord (..),
    ApprovalUnavailable (..),
    approvalDefinitionNoun,
    detectApprovalHostBackend,
    systemdUserManagerIsLive,
    approvalManagerName,
    approvalRecordFromBytes,
    approvalRecordPath,
    approvalUnavailableMessage,
    controllerFromApprovalCommand,
    discoverApprovalController,
    resolveApprovalDefinition,
    unreadableApprovalDefinition,

    -- * What it reports
    ApprovalActivity (..),
    ApprovalIncident (..),
    ApprovalObservation (..),
    ApprovalOutcome (..),
    ApprovalSeverity (..),
    ApprovalState (..),
    ApprovalStatus (..),
    approvalBarrierSummary,
    approvalUnavailableStatus,
    decodeApprovalStatus,
    approvalStatusFromControllerExit,

    -- * Control
    ApprovalToggle (..),
    approvalContentionNotice,
    approvalObservationSettles,
    approvalOwnsCanonicalReview,
    approvalServiceIsRunning,
    liveApprovalContention,
    approvalToggle,
    queryApprovalStatus,
    runApprovalCommand,
    setApprovalServiceRunning,

    -- * Board refresh
    ApprovalResult (..),
    approvalRefreshRequired,
    approvalResultPassRunning,
    approvalResultOf,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (FromJSON (..), Value, eitherDecode, eitherDecodeStrict, withObject, (.:), (.:?))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kanban.Domain (Repository (..))
import Kanban.Drainer (normalizedRepositoryIdentity)
import Kanban.ServiceProcess
  ( diagnosticMessage,
    invocationFailureMessage,
    runGroupedProcess,
    serviceTransitionCommand,
  )
import Kanban.Text (sanitizeText, withoutJsonPath)
import System.Directory (doesFileExist, findExecutable, getHomeDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, (</>))
import System.Info (os)

-- * The installed job

-- | Which service manager an installed approval job is managed by.
--
-- Read out of the discovery record rather than inferred from the host, exactly
-- as the drainer's is and for the same reason: the record is what
-- @tools\/install_issue_approval.py@ actually wrote, and it selects its backend
-- by probing the host rather than by naming a platform. A separate type from
-- the drainer's, so a drainer record can never be read as an approval job.
data ApprovalBackend
  = ApprovalLaunchd
  | ApprovalSystemd
  deriving stock (Eq, Show)

-- | What each manager calls the file it reads a definition from, so a
-- "missing" or "unreadable" message names the artifact the operator would go
-- and look at.
approvalDefinitionNoun :: ApprovalBackend -> Text
approvalDefinitionNoun ApprovalLaunchd = "LaunchAgent"
approvalDefinitionNoun ApprovalSystemd = "systemd unit"

-- | What each manager is called where a message names the manager itself.
-- Matches the @backend@ key the record is keyed on.
approvalManagerName :: ApprovalBackend -> Text
approvalManagerName ApprovalLaunchd = "launchd"
approvalManagerName ApprovalSystemd = "systemd"

-- | The controller command one repository's approval service is driven
-- through.
data ApprovalController = ApprovalController
  { approvalControllerExecutable :: FilePath,
    approvalControllerArguments :: [String],
    -- | The manager whose definition this command was read out of.
    approvalControllerBackend :: ApprovalBackend
  }
  deriving stock (Eq, Show)

-- | What the approval installer recorded about the job it wrote for one
-- repository. The record carries the job's location, never its content:
-- discovery still reads the command out of the definition itself.
data ApprovalRecord = ApprovalRecord
  { approvalRecordBackend :: ApprovalBackend,
    -- | The launchd label or systemd unit name the definition was written for.
    approvalRecordIdentifier :: Text,
    approvalRecordDefinition :: FilePath,
    -- | Which checkout the job was installed for. Metadata only: the
    -- controller is rebound to this dashboard's own checkout below, and a
    -- second checkout of one repository is that repository's own service.
    approvalRecordRepository :: FilePath
  }
  deriving stock (Eq, Show)

-- | Why no controller could be offered, kept as two distinct answers rather
-- than one string.
--
-- The distinction is requirement 10's whole point. A host with no service
-- manager /cannot/ run this service at all, and a dashboard that reported that
-- as an ordinary lookup failure would invite an operator to reinstall their
-- way out of it; every other failure is an installation this host could
-- actually have. Neither is ever an "off" service.
data ApprovalUnavailable
  = -- | This host has no service manager that could have installed the job,
    -- so there is nothing to discover and nothing to control.
    ApprovalHostUnsupported Text
  | -- | The job could not be discovered, read, or bound on a host that
    -- supports one.
    ApprovalUndiscoverable Text
  deriving stock (Eq, Show)

approvalUnavailableMessage :: ApprovalUnavailable -> Text
approvalUnavailableMessage (ApprovalHostUnsupported message) = message
approvalUnavailableMessage (ApprovalUndiscoverable message) = message

-- | The keys one backend's entry is spelled with, paired here so that the
-- mixed-shape rejection below can be stated against a single readable fact.
approvalRecordKeysFor :: ApprovalBackend -> (Key.Key, Key.Key)
approvalRecordKeysFor ApprovalLaunchd = ("launchd_label", "plist_path")
approvalRecordKeysFor ApprovalSystemd = ("systemd_unit", "unit_path")

allApprovalBackends :: [ApprovalBackend]
allApprovalBackends = [ApprovalLaunchd, ApprovalSystemd]

-- | What an entry's @backend@ field says, with "absent" kept apart from
-- "present but naming nothing".
data DeclaredApprovalBackend
  = ApprovalBackendAbsent
  | ApprovalBackendNull
  | ApprovalBackendNamed Text

declaredApprovalBackend :: Aeson.Object -> Parser DeclaredApprovalBackend
declaredApprovalBackend value = case KeyMap.lookup "backend" value of
  Nothing -> pure ApprovalBackendAbsent
  Just Aeson.Null -> pure ApprovalBackendNull
  Just _ -> ApprovalBackendNamed <$> value .: "backend"

-- | Reads one repository's entry as a discriminated union on @backend@.
--
-- Unlike the drainer's, an entry naming no backend is /refused/ rather than
-- read as launchd. There is no compatibility case to keep working: this
-- service's installer has written the discriminator since its first release,
-- so an entry without one was not written by it, and guessing a manager for it
-- would control the wrong job or none at all.
parseApprovalRecord :: Value -> Parser (Either Text ApprovalRecord)
parseApprovalRecord = withObject "issue approval install record" $ \value -> do
  declared <- declaredApprovalBackend value
  let presentKeys backend =
        filter (`KeyMap.member` value) [fst (approvalRecordKeysFor backend), snd (approvalRecordKeysFor backend)]
      others backend = filter (/= backend) allApprovalBackends
      strayKeys backend = concatMap presentKeys (others backend)
      strayDetail backend = Text.intercalate " and " (map Key.toText (strayKeys backend))
      read' backend = do
        let (identifierKey, definitionKey) = approvalRecordKeysFor backend
        identifier <- value .: identifierKey
        definition <- value .: definitionKey
        repository <- value .: "repository"
        pure (ApprovalRecord backend identifier definition repository)
  case declared of
    ApprovalBackendAbsent ->
      pure (Left "it names no service-manager backend")
    ApprovalBackendNull ->
      pure (Left "its backend field is null, which names no service manager")
    ApprovalBackendNamed name -> case lookup name [(approvalManagerName backend, backend) | backend <- allApprovalBackends] of
      Nothing ->
        pure (Left ("it names an unknown service-manager backend: " <> sanitizeText name))
      Just backend
        | not (null (strayKeys backend)) ->
            pure
              ( Left
                  ( "it names the "
                      <> approvalManagerName backend
                      <> " backend but also carries "
                      <> strayDetail backend
                  )
              )
        | otherwise -> Right <$> read' backend

-- | The installed document, holding one entry per canonical GitHub repository
-- beside the installer's own shared keys. Entries stay unparsed until one is
-- selected, so a malformed entry for another repository cannot make this one's
-- service undiscoverable.
newtype ApprovalRecordDocument = ApprovalRecordDocument (Map Text Value)

instance FromJSON ApprovalRecordDocument where
  parseJSON = withObject "issue approval install record" $ \value ->
    ApprovalRecordDocument . fromMaybe Map.empty <$> value .:? "repositories"

-- | The fixed location the installer writes that document to. Deliberately not
-- derived from @KANBAN_ISSUE_APPROVAL_INSTALL_DIR@: an install made with
-- @--install-dir@ still has to be discoverable by a dashboard that never saw
-- that option, which is exactly why the controller fixes the record's path.
approvalRecordPath :: IO FilePath
approvalRecordPath = do
  home <- getHomeDirectory
  pure (home </> "Library/Application Support/kanban/issue-approval/config.json")

-- | Selects this repository's entry, rejecting a document that cannot name a
-- job for it.
--
-- The identity is matched case-insensitively on both sides, not only on the
-- caller's: GitHub owner and repository names are case-insensitive, the
-- installer normalizes the key it writes, and a record hand-edited to a
-- different spelling still names one repository. A foreign entry is simply not
-- selected, which reads as "not installed for this repository" rather than as
-- somebody else's service (requirement 2).
approvalRecordFromBytes ::
  Text -> ByteString.ByteString -> Either Text (Maybe ApprovalRecord)
approvalRecordFromBytes identity bytes = do
  ApprovalRecordDocument records <- case eitherDecodeStrict bytes of
    Left message -> Left (withoutJsonPath (Text.pack message))
    Right document -> Right document
  case [value | (key, value) <- Map.toList records, Text.toLower key == Text.toLower identity] of
    [] -> Right Nothing
    value : _ -> Just <$> validated value
  where
    validated value = case parseEither parseApprovalRecord value of
      Left message -> Left (withoutJsonPath (Text.pack message))
      Right (Left message) -> Left message
      Right (Right record)
        | Text.null (Text.strip record.approvalRecordIdentifier) ->
            Left ("it names no " <> approvalManagerName record.approvalRecordBackend <> " identifier")
        | not (isAbsolute record.approvalRecordDefinition) ->
            Left
              ( "its "
                  <> approvalDefinitionNoun record.approvalRecordBackend
                  <> " path is not absolute: "
                  <> Text.pack record.approvalRecordDefinition
              )
        | otherwise -> Right record

-- | The service manager this host could have installed an approval job
-- through, or nothing at all.
--
-- Probed rather than read off @System.Info.os@, because availability is what
-- decides it and the platform's name is not availability: a Linux container
-- with no session bus behind its @systemctl@ manages nothing, and a job
-- installed against it would be a unit no manager ever loads. This mirrors
-- @tools\/service_manager.py@'s @_probe_service_manager@ exactly — macOS with
-- @launchctl@, otherwise a @systemctl@ whose @--user@ manager answers a
-- version read, otherwise neither — so the installer and this reader agree
-- about which hosts have a service at all.
--
-- Ordered rather than exclusive, and falling through the same way: a macOS
-- host without @launchctl@ gets the systemd question asked of it too, which is
-- what keeps the two implementations from disagreeing on an odd host.
--
-- Which manager an installed job actually uses stays the record's answer, not
-- this one.
detectApprovalHostBackend :: IO (Maybe ApprovalBackend)
detectApprovalHostBackend = do
  launchctl <- if os == "darwin" then findExecutable "launchctl" else pure Nothing
  case launchctl of
    Just _ -> pure (Just ApprovalLaunchd)
    Nothing -> do
      systemctl <- findExecutable "systemctl"
      case systemctl of
        Nothing -> pure Nothing
        Just _ -> do
          live <- systemdUserManagerIsLive
          pure (if live then Just ApprovalSystemd else Nothing)

-- | Whether @systemctl --user@ reaches this account's own systemd manager.
--
-- A read of the manager's own version, which needs the session bus and nothing
-- else, exactly as the installer's probe does. @systemctl@ exits nonzero when
-- it cannot connect — no @XDG_RUNTIME_DIR@, no user manager, a container
-- without one — and that is precisely the host that has to be reported as
-- unsupported rather than as an uninstalled service.
systemdUserManagerIsLive :: IO Bool
systemdUserManagerIsLive = do
  probed <-
    runGroupedProcess
      "the systemd user-manager probe"
      (Just approvalProbeTimeoutSeconds)
      "systemctl"
      ["--user", "show", "--property", "Version", "--value"]
  pure $ case probed of
    Right (ExitSuccess, _, _) -> True
    _ -> False

approvalReinstallHint :: Text
approvalReinstallHint = "run `python3 tools/install_issue_approval.py` from the Kanban checkout"

-- | Resolves this repository's installed service definition, naming the
-- remediation for every way the lookup can fail.
--
-- Parameterised by the /detected/ host backend rather than by a platform name,
-- so every branch — including a Linux host whose user manager is not reachable,
-- which arrives here as 'Nothing' exactly as an unsupported platform does — is
-- exercisable off any one host.
resolveApprovalDefinition ::
  Maybe ApprovalBackend -> Text -> FilePath -> IO (Either ApprovalUnavailable (ApprovalBackend, FilePath))
resolveApprovalDefinition detected identity recordPath =
  case detected of
    Nothing ->
      pure
        ( Left
            ( ApprovalHostUnsupported
                "the issue approval service is not supported on this host; it \
                \needs macOS launchd or a systemd user session reachable \
                \through `systemctl --user`"
            )
        )
    Just hostBackend -> do
      recorded <- doesFileExist recordPath
      if not recorded
        then pure (Left (ApprovalUndiscoverable notInstalled))
        else do
          contents <- try @IOException (ByteString.readFile recordPath)
          case fmap (approvalRecordFromBytes identity) contents of
            Left _ -> pure (Left (ApprovalUndiscoverable (unreadableRecord "it could not be read")))
            Right (Left message) -> pure (Left (ApprovalUndiscoverable (unreadableRecord message)))
            Right (Right Nothing) -> pure (Left (ApprovalUndiscoverable notInstalled))
            Right (Right (Just record))
              -- A record written by the manager this host does not have is a
              -- document that travelled between hosts, not an install.
              | record.approvalRecordBackend /= hostBackend ->
                  pure (Left (ApprovalUndiscoverable (foreignBackend record.approvalRecordBackend hostBackend)))
              | otherwise -> definitionOf record
  where
    notInstalled =
      "the issue approval service is not installed for "
        <> identity
        <> "; "
        <> approvalReinstallHint

    foreignBackend recorded hostBackend =
      "the issue approval service's install record describes a "
        <> approvalManagerName recorded
        <> " job, which this "
        <> approvalManagerName hostBackend
        <> " host cannot run; "
        <> approvalReinstallHint

    definitionOf record = do
      installed <- doesFileExist record.approvalRecordDefinition
      pure $
        if installed
          then Right (record.approvalRecordBackend, record.approvalRecordDefinition)
          else
            Left
              ( ApprovalUndiscoverable
                  ( "the issue approval service's "
                      <> approvalDefinitionNoun record.approvalRecordBackend
                      <> " is missing at "
                      <> Text.pack record.approvalRecordDefinition
                      <> "; "
                      <> approvalReinstallHint
                  )
              )

    unreadableRecord detail =
      "the issue approval service's install record at "
        <> Text.pack recordPath
        <> " is unreadable ("
        <> detail
        <> "); "
        <> approvalReinstallHint

-- | A definition that is present but will not parse is the one failure the
-- record cannot diagnose, so it carries the reader's own complaint — and, like
-- every other branch, the repair.
unreadableApprovalDefinition :: ApprovalBackend -> FilePath -> Text -> Text
unreadableApprovalDefinition backend definition detail =
  "could not read the issue approval service's "
    <> approvalDefinitionNoun backend
    <> " at "
    <> Text.pack definition
    <> ": "
    <> detail
    <> "; "
    <> approvalReinstallHint

-- | Rebinds the installed job's command to this dashboard's own checkout, and
-- states which repository that checkout is expected to be a clone of.
--
-- The identity travels as @--repo@ rather than being trusted: the controller
-- compares it against the checkout's remote and refuses a mismatch, so
-- containment lives on the side that owns the job.
--
-- The controller's own subcommand is dropped along with the bound arguments.
-- The installed definition runs @run@, and a status query that inherited it
-- would start a service instead of reading one.
controllerFromApprovalCommand ::
  ApprovalBackend -> Repository -> [String] -> Either Text ApprovalController
controllerFromApprovalCommand backend repository arguments = case arguments of
  executable : rawArguments
    | not (null controllerArguments) ->
        Right
          ( ApprovalController
              executable
              ( controllerArguments
                  <> [ "--path",
                       repository.repositoryRoot,
                       "--repo",
                       Text.unpack (normalizedRepositoryIdentity repository)
                     ]
              )
              backend
          )
    where
      controllerArguments = stripManagedApprovalArguments rawArguments
  _ -> Left (approvalCommandField backend <> " do not identify the issue approval controller")

approvalCommandField :: ApprovalBackend -> Text
approvalCommandField ApprovalLaunchd = "launchd ProgramArguments"
approvalCommandField ApprovalSystemd = "the systemd unit's ExecStart"

-- | Drops the arguments this side supplies itself, plus the subcommand and its
-- run-only options, so a definition carrying them cannot make the rebuilt
-- command name two checkouts, two repositories, or a second @run@.
stripManagedApprovalArguments :: [String] -> [String]
stripManagedApprovalArguments = removeBound . removeRunCommand
  where
    removeRunCommand = takeWhile (/= "run")

    removeBound (argument : _ : rest)
      | argument `elem` ["--path", "--repo"] = removeBound rest
    removeBound (argument : rest) = argument : removeBound rest
    removeBound [] = []

-- * What it reports

-- | The colour class the sidebar draws a status in. Its own type rather than
-- the drainer's, because the two services reach these from different facts.
data ApprovalState
  = ApprovalOff
  | ApprovalOn
  | ApprovalStarting
  | ApprovalStopping
  | ApprovalWarning
  | ApprovalError
  deriving stock (Eq, Show)

-- | What the controller reported about the service itself, separated from the
-- prose 'approvalDetail' renders it as.
--
-- Every state @tools\/approve_issues_service.py@ publishes has its own
-- constructor here (requirement 3), so no two are ever flattened together and
-- no absent, malformed, or unknown-version document can arrive as one of them.
data ApprovalActivity
  = -- | A run is coming up and has not yet completed a pass.
    ApprovalServiceStarting
  | -- | The queue is being worked.
    ApprovalServiceRunning
  | -- | Paused at an ordered barrier, doing read-only gate checks only.
    ApprovalServiceBarrier
  | -- | Stopped on purpose. Distinct from every failure below.
    ApprovalServiceStopped
  | -- | A backend pass failed and ended the run.
    ApprovalServiceChildFailure
  | -- | The controller itself failed and ended the run.
    ApprovalServiceControllerFailure
  | -- | A stop this dashboard started is still in flight. Only ever set
    -- locally: the controller reports no such state.
    ApprovalServiceStopping
  | -- | This host cannot run the service at all, which is neither a stopped
    -- service nor an unknown one (requirement 10).
    ApprovalServiceUnsupported
  | -- | No usable status: the controller could not be discovered or run, its
    -- document did not decode, carried another schema or version, named
    -- another repository, or named a state this does not recognize. Every one
    -- of those is "unknown", never "off".
    ApprovalServiceUnknown
  deriving stock (Eq, Show)

-- | Whether an incident is a healthy service waiting or a run that ended.
-- Carried rather than inferred from the state, because requirement 7's barrier
-- is a warning while the service around it may be running /or/ stopped.
data ApprovalSeverity
  = ApprovalWarningSeverity
  | ApprovalErrorSeverity
  deriving stock (Eq, Show)

-- | One open incident the controller reported.
data ApprovalIncident = ApprovalIncident
  { -- | The service-provided identity. Required: an incident that cannot name
    -- itself cannot be safely selected or acknowledged.
    approvalIncidentId :: Text,
    approvalIncidentKind :: Text,
    approvalIncidentSeverity :: ApprovalSeverity,
    approvalIncidentSummary :: Maybe Text,
    -- | The issue a barrier is about. Absent on an error incident that is not
    -- issue-scoped.
    approvalIncidentIssue :: Maybe Int
  }
  deriving stock (Eq, Show)

instance FromJSON ApprovalIncident where
  parseJSON = withObject "issue approval open incident" $ \value ->
    ApprovalIncident
      <$> value .: "incident_id"
      <*> value .: "kind"
      <*> (severityFrom <$> value .:? "severity")
      <*> value .:? "summary"
      <*> value .:? "issue"
    where
      -- An incident whose severity is absent or unrecognized is an error, not
      -- a warning: a warning is the one severity that says "nothing failed",
      -- and guessing it would present a stopped run as a healthy pause.
      severityFrom :: Maybe Text -> ApprovalSeverity
      severityFrom (Just "warning") = ApprovalWarningSeverity
      severityFrom _ = ApprovalErrorSeverity

-- | What one backend pass last decided, as the controller records it.
data ApprovalOutcome
  = ApprovalOutcomeIdle
  | ApprovalOutcomeAdvanced
  | ApprovalOutcomeChangesRequested
  | ApprovalOutcomeRetry
  | ApprovalOutcomeBusy
  | -- | An outcome this Kanban does not know. Never treated as one it does.
    ApprovalOutcomeUnrecognized Text
  deriving stock (Eq, Show)

approvalOutcomeFrom :: Text -> ApprovalOutcome
approvalOutcomeFrom "idle" = ApprovalOutcomeIdle
approvalOutcomeFrom "advanced" = ApprovalOutcomeAdvanced
approvalOutcomeFrom "changes_requested" = ApprovalOutcomeChangesRequested
approvalOutcomeFrom "retry" = ApprovalOutcomeRetry
approvalOutcomeFrom "busy" = ApprovalOutcomeBusy
approvalOutcomeFrom other = ApprovalOutcomeUnrecognized other

data ApprovalStatus = ApprovalStatus
  { approvalState :: ApprovalState,
    approvalDetail :: Text,
    -- | The controller's own state, undecorated.
    approvalActivity :: ApprovalActivity,
    -- | The durable ordered barrier, read from the controller's barrier record
    -- rather than from live state, so it survives a stop and a restart
    -- (requirement 7).
    approvalBarrierIssue :: Maybe Int,
    -- | The newest open incident, kept beside the activity rather than folded
    -- into it: an intentional stop with an unresolved barrier is both a
    -- stopped service and an open warning, and neither fact may erase the
    -- other.
    approvalIncident :: Maybe ApprovalIncident
  }
  deriving stock (Eq, Show)

-- | One controller response: the sidebar's status projection, the complete set
-- of open incidents behind it, and the result identity a refresh decision is
-- taken on.
--
-- 'observedApprovalIncidents' is 'Nothing' rather than @Just []@ whenever no
-- set was reported at all, which is not the same as a service reporting none.
data ApprovalObservation = ApprovalObservation
  { observedApprovalStatus :: ApprovalStatus,
    observedApprovalIncidents :: Maybe [ApprovalIncident],
    observedApprovalResult :: ApprovalResult
  }
  deriving stock (Eq, Show)

-- | The exact wording the controller composes for a barrier, mirrored here so
-- both sides name the issue the same way. Held equal to
-- @approve_issues_service.barrier_summary@ by that side's own tests and by
-- this side's fixtures.
approvalBarrierSummary :: Int -> Text
approvalBarrierSummary issue = "Issue #" <> Text.pack (show issue) <> " requests changes"

data RawApprovalStatus = RawApprovalStatus
  { rawApprovalSchema :: Maybe Text,
    rawApprovalVersion :: Maybe Int,
    rawApprovalRepository :: Maybe Text,
    rawApprovalState :: Maybe Text,
    rawApprovalReason :: Maybe Text,
    rawApprovalBarrierIssue :: Maybe Int,
    rawApprovalBarrierUnreadable :: Maybe Text,
    rawApprovalBackendPid :: Maybe Int,
    rawApprovalLastOutcome :: Maybe Text,
    rawApprovalUpdatedAt :: Maybe Text,
    rawApprovalIncident :: Maybe ApprovalIncident,
    rawApprovalIncidents :: Maybe [ApprovalIncident]
  }
  deriving stock (Eq, Show)

instance FromJSON RawApprovalStatus where
  parseJSON = withObject "issue approval status" $ \value ->
    RawApprovalStatus
      <$> value .:? "schema"
      <*> value .:? "version"
      <*> value .:? "repository"
      <*> value .:? "state"
      <*> value .:? "reason"
      <*> value .:? "barrier_issue"
      <*> value .:? "barrier_unreadable"
      <*> value .:? "backend_pid"
      <*> value .:? "last_outcome"
      <*> value .:? "updated_at"
      <*> value .:? "open_incident"
      <*> value .:? "open_incidents"

-- | The schema and version this Kanban reads. Pinned rather than tolerated: a
-- document of another shape may spell @state@ the same way and mean something
-- else, and a reader that accepted it would report a guess as a fact.
approvalStatusSchema :: Text
approvalStatusSchema = "kanban-issue-approval-status"

approvalStatusVersion :: Int
approvalStatusVersion = 1

-- | Decodes one controller status document against the repository the board is
-- showing.
--
-- Every way the document can fail to describe /this/ service now — it will not
-- parse, carries another schema or another version, records another
-- repository, or names a state this reader does not know — resolves to an
-- explicit unknown naming what was wrong, never to a healthy or stopped guess
-- (requirements 2 and 3).
decodeApprovalStatus :: Text -> LazyByteString.ByteString -> Either Text ApprovalObservation
decodeApprovalStatus identity bytes = case eitherDecode bytes of
  Left message -> Left ("could not decode issue approval status: " <> withoutJsonPath (Text.pack message))
  Right raw -> Right (observationFrom identity raw)

observationFrom :: Text -> RawApprovalStatus -> ApprovalObservation
observationFrom identity raw =
  ApprovalObservation status incidents (approvalResultOf status raw.rawApprovalBackendPid outcome raw.rawApprovalUpdatedAt)
  where
    outcome = fmap approvalOutcomeFrom raw.rawApprovalLastOutcome
    -- Only ever reported for a document this reader accepted. A rejected one
    -- describes some other service, so its incident set is not this
    -- repository's to show.
    incidents = case containment of
      Just _ -> Nothing
      Nothing -> raw.rawApprovalIncidents
    barrier = raw.rawApprovalBarrierIssue
    incident = case raw.rawApprovalIncident of
      Just openIncident -> Just openIncident
      -- A controller that reported a barrier without an incident document —
      -- one whose warning was acknowledged, and one whose incident directory
      -- could not be listed — is still barriered, and requirement 7 says the
      -- barrier is what has to be named. So the record itself supplies one.
      Nothing -> fmap barrierIncident barrier
    barrierIncident issue =
      ApprovalIncident
        ("barrier-issue-" <> Text.pack (show issue))
        "issue-changes-requested"
        ApprovalWarningSeverity
        (Just (approvalBarrierSummary issue))
        (Just issue)

    -- Every reason this document is not an answer about this repository's
    -- service, in the order that makes the message actionable.
    containment
      | raw.rawApprovalSchema /= Just approvalStatusSchema =
          Just
            ( "the issue approval controller reported schema "
                <> maybe "none" sanitizeText raw.rawApprovalSchema
                <> ", not "
                <> approvalStatusSchema
            )
      | raw.rawApprovalVersion /= Just approvalStatusVersion =
          Just
            ( "the issue approval controller reported status version "
                <> maybe "none" (Text.pack . show) raw.rawApprovalVersion
                <> ", not "
                <> Text.pack (show approvalStatusVersion)
            )
      | not (identityMatches raw.rawApprovalRepository) =
          Just
            ( "the issue approval controller reported repository "
                <> maybe "none" sanitizeText raw.rawApprovalRepository
                <> ", not "
                <> identity
            )
      | otherwise = Nothing

    identityMatches (Just recorded) = Text.toLower recorded == Text.toLower identity
    identityMatches Nothing = False

    status = case containment of
      Just message -> unknownStatus message
      Nothing -> case raw.rawApprovalBarrierUnreadable of
        -- The controller could not read its own barrier record. It says so
        -- separately from the state, and a queue whose barrier cannot be read
        -- is not a queue anyone may report as running.
        Just detail -> unknownStatus (sanitizeText detail)
        Nothing -> statusFrom raw.rawApprovalState

    unknownStatus message =
      ApprovalStatus ApprovalError message ApprovalServiceUnknown barrier incident

    statusFrom (Just "starting") = reported ApprovalStarting ApprovalServiceStarting "starting…"
    statusFrom (Just "running") = case barrier of
      -- A barrier the controller has not yet moved into its own state is
      -- still a barrier: the record is the authority (requirement 7).
      Just issue -> reported ApprovalWarning ApprovalServiceBarrier (barrierDetail "on" issue)
      Nothing -> reported ApprovalOn ApprovalServiceRunning "on"
    statusFrom (Just "barrier") =
      reported ApprovalWarning ApprovalServiceBarrier (maybe "on · unresolved incident" (barrierDetail "on") barrier)
    statusFrom (Just "stopped") = case barrier of
      -- The barrier outlives the stop that did not resolve it, so a stopped
      -- service still reports it — in red, because a stopped service is not
      -- working through it (D-8).
      Just issue -> reported ApprovalError ApprovalServiceStopped (barrierDetail "stopped" issue)
      Nothing -> reported ApprovalOff ApprovalServiceStopped "off"
    statusFrom (Just "child_failure") =
      reported ApprovalError ApprovalServiceChildFailure (failureDetail "a backend pass failed")
    statusFrom (Just "controller_failure") =
      reported ApprovalError ApprovalServiceControllerFailure (failureDetail "the controller failed")
    statusFrom (Just other) =
      ApprovalStatus ApprovalError ("unknown state: " <> sanitizeText other) ApprovalServiceUnknown barrier incident
    statusFrom Nothing =
      ApprovalStatus ApprovalError "the issue approval controller reported no state" ApprovalServiceUnknown barrier incident

    reported state activity detail = ApprovalStatus state detail activity barrier incident

    barrierDetail prefix issue = prefix <> " · unresolved incident · " <> approvalBarrierSummary issue

    -- A failure names what the controller said went wrong when it said
    -- anything; the reason field is what a synthesized unknown carries and a
    -- recorded failure's message is what the incident carries.
    failureDetail fallback =
      "stopped · "
        <> case (raw.rawApprovalReason, incident >>= (.approvalIncidentSummary)) of
          (Just reason, _) | not (Text.null (Text.strip reason)) -> sanitizeText reason
          (_, Just summary) | not (Text.null (Text.strip summary)) -> sanitizeText summary
          _ -> fallback

-- | The status a dashboard shows for a service it has no controller for.
--
-- An unsupported host gets its own activity, so nothing downstream can mistake
-- it for a service that is merely off; every other discovery failure is
-- unknown for the same reason a failed poll is (requirement 10).
approvalUnavailableStatus :: ApprovalUnavailable -> ApprovalStatus
approvalUnavailableStatus unavailable =
  ApprovalStatus ApprovalError (sanitizeText (approvalUnavailableMessage unavailable)) activity Nothing Nothing
  where
    activity = case unavailable of
      ApprovalHostUnsupported _ -> ApprovalServiceUnsupported
      ApprovalUndiscoverable _ -> ApprovalServiceUnknown

-- * Control

-- | What pressing the approval toggle should do.
data ApprovalToggle
  = StartApprovalService
  | StopApprovalService
  | -- | Issue nothing and say this instead.
    ApprovalToggleBusy Text
  deriving stock (Eq, Show)

-- | Whether the service is working this repository's queue right now, read off
-- the activity rather than off the rendered detail.
approvalServiceIsRunning :: ApprovalStatus -> Bool
approvalServiceIsRunning status = case status.approvalActivity of
  ApprovalServiceRunning -> True
  ApprovalServiceBarrier -> True
  _ -> False

-- | Whether the service owns a canonical review right now, so a canonical
-- stage started from a card would contend with it for the backend's approval
-- lock (requirement 8).
--
-- Read off the live backend child, not off the service being up. The
-- controller sleeps between passes with no child at all — a whole poll
-- interval of @running@ can contain no review — and a running service is not
-- the same claim as a review in flight. Taking one for the other would refuse
-- every card review for as long as the service was merely enabled.
--
-- A barrier is deliberately not ownership even while it /does/ have a child: at
-- a barrier that child is the read-only gate check, which performs no model
-- work and releases the lock between checks, so the selected-card workflow
-- that repairs the barrier stays reachable (D-10).
--
-- 'Nothing' — no observation has been applied yet — is not ownership either. A
-- dashboard that has heard nothing from the service has no evidence of a
-- review, and the backend's approval lock remains the cross-process authority
-- that actually decides contention.
approvalOwnsCanonicalReview :: Maybe ApprovalResult -> Bool
approvalOwnsCanonicalReview Nothing = False
approvalOwnsCanonicalReview (Just observed) =
  approvalResultPassRunning observed && case observed.approvalResultActivity of
    ApprovalServiceRunning -> True
    ApprovalServiceBarrier -> False
    ApprovalServiceStarting -> False
    ApprovalServiceStopping -> False
    ApprovalServiceStopped -> False
    ApprovalServiceChildFailure -> False
    ApprovalServiceControllerFailure -> False
    ApprovalServiceUnsupported -> False
    ApprovalServiceUnknown -> False

-- | Whether an observation is evidence that the transition now in flight has
-- actually happened.
--
-- Stamping a poll with the transition it was issued under establishes that its
-- query began after the press. It does not establish that the query began after
-- the /command/ that press handed off: the start or stop runs in its own
-- thread, and a poll issued in the window between the press and the service
-- actually moving is stamped with the current transition and still reports the
-- state the press is about to change.
--
-- So the content decides it. A start is settled only by an observation of a
-- service that is up, a stop only by one of a service that is down, and
-- anything else — including an unknown — leaves the optimistic state standing
-- for the completion to settle. That completion always arrives, whether the
-- command succeeded or failed, so nothing here can leave the busy flag set
-- forever.
approvalObservationSettles :: ApprovalActivity -> ApprovalActivity -> Bool
approvalObservationSettles inFlight observed = case inFlight of
  ApprovalServiceStarting -> observed `elem` up
  ApprovalServiceStopping -> observed `elem` down
  -- Not a transition this dashboard started, so there is nothing to be
  -- premature about.
  _ -> True
  where
    up = [ApprovalServiceRunning, ApprovalServiceBarrier, ApprovalServiceStarting]
    down =
      [ ApprovalServiceStopped,
        ApprovalServiceChildFailure,
        ApprovalServiceControllerFailure
      ]

-- | What the operator is told when the service holds the review they asked
-- for. Spelled once, because the press, the spawn boundary, and the live
-- recheck all report the same condition and a second wording would read as a
-- second cause.
approvalContentionNotice :: Text
approvalContentionNotice =
  "The issue approval service has a canonical review in flight; wait for it to \
  \finish or stop the service before starting another"

-- | Whether the service owns a canonical review /now/, asked of the controller
-- rather than of the last poll.
--
-- The poll is ten seconds apart, and a canonical child is spawned and finished
-- inside that window all the time, so a check taken at an asynchronous launch
-- boundary has to read live state rather than the newest observation the board
-- happens to hold.
--
-- Fails open on purpose, in both directions. A repository with no installed
-- service contends with nothing; and a controller that cannot be read has told
-- this side nothing, so refusing on it would make an unreadable service block
-- every card review indefinitely. Neither is a correctness risk: the backend's
-- own approval lock is the cross-process authority between the service, the
-- selected card, and every other caller, so the worst a fail-open costs is one
-- backend pass reporting contention and backing off.
liveApprovalContention ::
  Text -> Either ApprovalUnavailable ApprovalController -> IO (Maybe Text)
liveApprovalContention _ (Left _) = pure Nothing
liveApprovalContention identity (Right controller) = do
  observed <- queryApprovalStatus identity controller
  pure $ case observed of
    Left _ -> Nothing
    Right observation
      | approvalOwnsCanonicalReview (Just observation.observedApprovalResult) ->
          Just approvalContentionNotice
      | otherwise -> Nothing

-- | A start is only ever issued from a settled state this dashboard is not
-- already transitioning. @busy@ is a transition it started; a reported
-- 'ApprovalStarting' is one it did not, seen through the status poll.
approvalToggle :: Bool -> ApprovalStatus -> ApprovalToggle
approvalToggle busy status
  | busy = ApprovalToggleBusy "Issue approval service is already starting or stopping"
  | status.approvalActivity == ApprovalServiceUnsupported =
      ApprovalToggleBusy "Issue approval service is not supported on this host"
  | status.approvalState == ApprovalStarting = ApprovalToggleBusy "Issue approval service is already starting"
  | approvalServiceIsRunning status = StopApprovalService
  | otherwise = StartApprovalService

-- | What the ownership diagnostics of a timed-out invocation call the process
-- they are about, so an approval message is never the shape "the drainer
-- controller led".
approvalControllerSubject :: Text
approvalControllerSubject = "the issue approval controller"

queryApprovalStatus :: Text -> ApprovalController -> IO (Either Text ApprovalObservation)
queryApprovalStatus identity controller =
  runApprovalCommand approvalStatusTimeoutSeconds identity controller "status"

setApprovalServiceRunning :: Text -> ApprovalController -> Bool -> IO (Either Text ApprovalObservation)
setApprovalServiceRunning identity controller shouldRun =
  runApprovalCommand approvalTransitionTimeoutSeconds identity controller (if shouldRun then "start" else "stop")

-- | The seconds-parameterised runner behind the two above, exported so the
-- termination and timeout-wording tests can drive a wedged controller without
-- waiting out a real transition budget (requirement 6).
runApprovalCommand :: Int -> Text -> ApprovalController -> String -> IO (Either Text ApprovalObservation)
runApprovalCommand seconds identity controller command = do
  result <-
    runGroupedProcess
      approvalControllerSubject
      (Just seconds)
      controller.approvalControllerExecutable
      (controller.approvalControllerArguments <> ["--json", command])
  pure $ case result of
    Left failure ->
      Left
        ( invocationFailureMessage
            seconds
            ("issue approval " <> Text.pack command)
            (serviceTransitionCommand command)
            failure
        )
    Right (exitCode, output, errors) -> approvalStatusFromControllerExit identity exitCode output errors

-- | Interprets a controller invocation that ran to completion. A controller
-- that exits nonzero while still printing a status document is reporting state
-- rather than failing, so stdout is offered to the decoder first even when
-- stderr carries diagnostics.
approvalStatusFromControllerExit :: Text -> ExitCode -> String -> String -> Either Text ApprovalObservation
approvalStatusFromControllerExit identity exitCode output errors =
  case (decodeApprovalStatus identity (LazyByteString.pack output), exitCode) of
    (Right observation, _) -> Right observation
    (Left decodeFailure, ExitSuccess) -> Left decodeFailure
    (Left _, ExitFailure _) -> Left (diagnosticMessage output errors)

approvalDiscoveryTimeoutSeconds :: Int
approvalDiscoveryTimeoutSeconds = 3

-- | The host probe's budget. Short: it is a local version read, and a
-- @systemctl@ that cannot answer it promptly is exactly the unreachable
-- manager the probe exists to refuse.
approvalProbeTimeoutSeconds :: Int
approvalProbeTimeoutSeconds = 3

approvalStatusTimeoutSeconds :: Int
approvalStatusTimeoutSeconds = 4

approvalTransitionTimeoutSeconds :: Int
approvalTransitionTimeoutSeconds = 30

-- | Discovers this repository's approval controller: the record, the
-- definition it names, and the command inside that definition, rebound to this
-- dashboard's own checkout.
discoverApprovalController :: Repository -> IO (Either ApprovalUnavailable ApprovalController)
discoverApprovalController repository = do
  recordPath <- approvalRecordPath
  detected <- detectApprovalHostBackend
  resolved <- resolveApprovalDefinition detected (normalizedRepositoryIdentity repository) recordPath
  case resolved of
    Left unavailable -> pure (Left unavailable)
    Right (ApprovalLaunchd, plist) -> do
      result <-
        runGroupedProcess
          approvalControllerSubject
          (Just approvalDiscoveryTimeoutSeconds)
          "/usr/bin/plutil"
          ["-extract", "ProgramArguments", "json", "-o", "-", plist]
      pure . mapLeftUndiscoverable $ do
        output <- case result of
          Left failure ->
            Left
              ( unreadableApprovalDefinition
                  ApprovalLaunchd
                  plist
                  (invocationFailureMessage approvalDiscoveryTimeoutSeconds "reading the launchd job" False failure)
              )
          Right (ExitSuccess, standardOutput, _) -> Right standardOutput
          Right (ExitFailure _, standardOutput, errors) ->
            Left (unreadableApprovalDefinition ApprovalLaunchd plist (diagnosticMessage standardOutput errors))
        arguments <- case eitherDecode (LazyByteString.pack output) of
          Left message -> Left ("could not decode launchd ProgramArguments: " <> Text.pack message)
          Right values -> Right values
        controllerFromApprovalCommand ApprovalLaunchd repository arguments
    Right (ApprovalSystemd, unit) -> do
      contents <- try @IOException (ByteString.readFile unit)
      pure . mapLeftUndiscoverable $ do
        text <- case contents of
          Left _ -> Left (unreadableApprovalDefinition ApprovalSystemd unit "it could not be read")
          Right bytes -> Right (Text.decodeUtf8Lenient bytes)
        arguments <- case unitApprovalArguments text of
          Left message -> Left (unreadableApprovalDefinition ApprovalSystemd unit message)
          Right values -> Right values
        controllerFromApprovalCommand ApprovalSystemd repository arguments
  where
    mapLeftUndiscoverable = either (Left . ApprovalUndiscoverable) Right

-- | The argument vector a systemd unit's @ExecStart@ names, under systemd's own
-- quoting. Kept beside this service's own reader rather than shared with the
-- drainer's, because what is being parsed is the unit /this/ installer wrote.
unitApprovalArguments :: Text -> Either Text [String]
unitApprovalArguments contents = case execStartValues of
  [] -> Left "it declares no ExecStart"
  values -> case concatMap unitWords values of
    [] -> Left "its ExecStart names no command"
    arguments -> Right (map Text.unpack arguments)
  where
    execStartValues =
      [ Text.strip value
        | line <- Text.lines contents,
          let stripped = Text.strip line,
          Just value <- [Text.stripPrefix "ExecStart=" stripped],
          not (Text.null (Text.strip value))
      ]

unitWords :: Text -> [Text]
unitWords = go . Text.unpack
  where
    go [] = []
    go (character : rest)
      | character `elem` (" \t" :: String) = go rest
      | character == '"' = let (word, remaining) = quoted rest "" in word : go remaining
      | otherwise = let (word, remaining) = bare (character : rest) "" in word : go remaining

    quoted [] acc = (finish acc, [])
    quoted ('\\' : escaped : rest) acc = quoted rest (escaped : acc)
    quoted ('"' : rest) acc = (finish acc, rest)
    quoted (character : rest) acc = quoted rest (character : acc)

    bare [] acc = (finish acc, [])
    bare (character : rest) acc
      | character `elem` (" \t" :: String) = (finish acc, rest)
      | otherwise = bare rest (character : acc)

    finish = Text.replace "%%" "%" . Text.pack . reverse

-- * Board refresh

-- | The part of an observation a board-refresh decision is taken on, and the
-- durable identity that keeps one result from being refreshed for twice
-- (requirement 9).
--
-- All four fields are needed. The activity says which durable state the
-- service is in, the outcome says what the last completed pass decided,
-- 'approvalResultPassRunning' says whether that outcome belongs to a pass that
-- has finished, and 'approvalResultUpdatedAt' is the controller's own stamp —
-- the only thing that distinguishes two passes that decided the same way.
data ApprovalResult = ApprovalResult
  { approvalResultActivity :: ApprovalActivity,
    approvalResultOutcome :: Maybe ApprovalOutcome,
    -- | The backend pass running under this document, by PID, or 'Nothing'
    -- when none is. The controller nulls the PID unless the child is really
    -- alive, so this is a live fact rather than a leftover.
    --
    -- The PID itself rather than a flag, because it is the only thing that
    -- distinguishes two /passes/. @ADVANCE_DELAY_SECONDS@ is zero, so the
    -- controller starts the next pass the instant one advances, and its stamps
    -- are second-granular: two consecutive advancing passes can otherwise
    -- project to exactly the same identity and the second one's refresh would
    -- be suppressed as a repeat of the first.
    approvalResultBackendPid :: Maybe Int,
    approvalResultUpdatedAt :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | Whether a backend pass is running under this result.
approvalResultPassRunning :: ApprovalResult -> Bool
approvalResultPassRunning = isJust . (.approvalResultBackendPid)

approvalResultOf :: ApprovalStatus -> Maybe Int -> Maybe ApprovalOutcome -> Maybe Text -> ApprovalResult
approvalResultOf status backendPid outcome updatedAt =
  ApprovalResult status.approvalActivity outcome backendPid updatedAt

-- | Whether a newly observed result reports something that may have changed
-- GitHub and has not already been refreshed for.
--
-- The controller publishes no per-result identity, so this uses one: the
-- document's own @updated_at@ together with the state and outcome it carries.
-- The clauses below are what that identity has to be read through, because the
-- controller rewrites its status several times per pass:
--
-- * A document this dashboard has already seen — same @updated_at@ — reports
--   nothing new, which is what makes an idle poll every ten seconds free.
-- * Entering the barrier state is how a @changes_requested@ pass is durably
--   reported. The barrier persists, so a poll cannot miss it, and the state is
--   only entered once, so the repeated writes a barriered controller makes
--   while rechecking its gate do not refresh again.
-- * Entering a failure state is outcome-indeterminate: a pass that died
--   mid-publication may have posted a review, so it is refreshed for once.
-- * A mutating outcome is read off the document written when the /next/ pass
--   spawns, not off the momentary one written between passes. An @advanced@
--   pass is followed immediately by the next spawn, so the settled document
--   exists for microseconds and a ten-second poll would never see it, while
--   the in-flight one stands for the whole of the following pass.
-- * A stop landing right after a mutating pass is the one case with no
--   following spawn, so the settled document is refreshed for there.
--
-- The /first/ observation is judged by those same clauses rather than taken as
-- a silent baseline. It is tempting to treat it as one, on the grounds that the
-- dashboard's own startup refresh covers whatever the service did while
-- nothing was watching — but that refresh and the first poll are started
-- concurrently, so a review the service published after the startup fetch read
-- GitHub and before the first poll answered would fall in the gap between
-- them, and no later observation repairs it: the documents that follow are
-- unchanged, and an unchanged document reports nothing new by the first clause
-- above. Asking the clauses instead costs at most one queued follow-up refresh
-- at launch, and only when the service is actually reporting a barrier, a
-- failure, or a mutating pass.
approvalRefreshRequired :: Maybe ApprovalResult -> ApprovalResult -> Bool
approvalRefreshRequired previous current
  | sameDocument = False
  | enteredBarrier = True
  | enteredFailure = True
  | mutatingPassSpawned = True
  | stoppedAfterMutation = True
  | otherwise = False
  where
    -- The whole identity, not the stamp alone. @utc_stamp@ is second-granular
    -- and the controller writes several states inside one pass, so an idle
    -- result and the @advanced@ running pass that follows it in the same
    -- second carry the same stamp — and comparing stamps would suppress the
    -- refresh that second document is the only report of. The pass's PID is
    -- part of that identity for the same reason one step further out: two
    -- consecutive advancing passes differ in nothing else.
    sameDocument = previous == Just current

    -- "Already in that state" rather than "in some previous state": with no
    -- previous observation at all, every transition below is one this
    -- dashboard is seeing for the first time and has therefore not refreshed
    -- for.
    wasAlready activity = maybe False ((== activity) . (.approvalResultActivity)) previous

    enteredBarrier =
      current.approvalResultActivity == ApprovalServiceBarrier
        && not (wasAlready ApprovalServiceBarrier)

    enteredFailure =
      current.approvalResultActivity
        `elem` [ApprovalServiceChildFailure, ApprovalServiceControllerFailure]
        && not (wasAlready current.approvalResultActivity)

    mutatingPassSpawned = approvalResultPassRunning current && mutating current.approvalResultOutcome

    stoppedAfterMutation =
      current.approvalResultActivity == ApprovalServiceStopped
        && not (wasAlready ApprovalServiceStopped)
        && mutating current.approvalResultOutcome

    -- `changes_requested` is deliberately absent: it is reported by the
    -- barrier state above, and reading it here as well would refresh again on
    -- every gate recheck a barriered controller performs. `busy` and `idle`
    -- made no model call and changed nothing.
    mutating (Just ApprovalOutcomeAdvanced) = True
    mutating (Just ApprovalOutcomeRetry) = True
    mutating (Just (ApprovalOutcomeUnrecognized _)) = True
    mutating _ = False
