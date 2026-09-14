-- | The unattended mission runner, as the dashboard sees it: the discovery
-- record its installer writes, the controller handle read out of the installed
-- job, the status document that controller publishes, the incidents beside it,
-- and the durable events a console replays out of a mission's own record.
--
-- Deliberately its own module rather than more of "Kanban.Drainer" or
-- "Kanban.ApprovalService", and deliberately sharing no constructor with
-- either. The three services are similar by design — one installer shape, one
-- discovery-record shape, one controller contract — but their states mean
-- different things: a drainer's incident is about a pull request, the approval
-- service's is about an issue whose specification needs repairing, and this
-- one's is about a scheduler pass that failed, and no controller owns another's
-- process. A shared type would let one service's state be assigned to another's
-- field and compile.
--
-- Not to be confused with "Kanban.Mission.Runner", which is the foreground
-- runner /inside/ a mission: that module advances one mission, and this one
-- reads and controls the managed job that repeats scheduler passes. Nothing
-- here advances anything.
--
-- What /is/ shared is spelled as such: 'managedRecordPath' is the one Haskell
-- answer to where a managed component's record is, 'normalizedRepositoryIdentity'
-- the one definition of a canonical repository identity, "Kanban.ServiceProcess"
-- the one definition of a bounded, process-grouped controller invocation,
-- 'unitExecStartArguments' the one reading of what a systemd unit's @ExecStart@
-- names, 'systemdUserManagerIsLive' the one probe of whether @systemctl --user@
-- reaches this account's manager, and "Kanban.Mission"'s own readers the one
-- decoding of a mission's durable records. Only the two-line selection between
-- the managers is restated here, because its answer is this module's own type.
--
-- Two boundaries are deliberate.
--
-- This module acquires no advancement authority. Reading the runner's status,
-- replaying a mission's events, and starting or stopping the job all leave
-- every mission's advancement lease exactly as they found it: none of them
-- attempts 'Kanban.Mission.acquireMissionLease', so none of them can be refused
-- by a lease somebody else holds and none of them can hold one. Observing a
-- runner never makes the observer eligible to advance a mission.
--
-- And it is a reader rather than a follower. It starts no thread, installs no
-- timer, and performs no periodic poll: every function here answers once, when
-- it is called, and the caller decides the cadence. The one place a thread is
-- forked on its behalf is 'runGroupedProcess''s own output drains, which live
-- and die inside a single bounded invocation.
module Kanban.MissionRunnerService
  ( -- * The installed job
    MissionRunnerBackend (..),
    MissionRunnerController (..),
    MissionRunnerRecord (..),
    MissionRunnerRecordFailure (..),
    MissionRunnerUnavailable (..),
    MissionRunnerUnavailableCase (..),
    missionRunnerUnavailableCases,
    missionRunnerUnavailableHeadline,
    missionRunnerBackends,
    missionRunnerDefinitionNoun,
    missionRunnerManagerName,
    missionRunnerRecordPath,
    missionRunnerRecordFromBytes,
    detectMissionRunnerHostBackend,
    resolveMissionRunnerDefinition,
    controllerFromMissionRunnerCommand,
    discoverMissionRunnerController,
    systemdMissionRunnerControllerFromUnit,
    unreadableMissionRunnerDefinition,

    -- * What it reports
    MissionRunnerActivity (..),
    MissionRunnerAttention (..),
    MissionRunnerIncident (..),
    MissionRunnerObservation (..),
    MissionRunnerSeverity (..),
    MissionRunnerStatus (..),
    decodeMissionRunnerStatus,
    missionRunnerAvailability,
    missionRunnerIsRunning,
    missionRunnerStatusFromControllerExit,
    missionRunnerUnavailableStatus,

    -- * Control
    missionRunnerCommandArguments,
    queryMissionRunnerStatus,
    runMissionRunnerCommand,
    setMissionRunnerRunning,

    -- * Replaying a mission's durable events
    MissionReplay (..),
    MissionReplayCursor (..),
    MissionStreamId (..),
    MissionStreamReplay (..),
    MissionStreamSource (..),
    emptyMissionReplayCursor,
    replayMissionRecord,
  )
where

import Control.Applicative ((<|>))
import Control.Exception (IOException, try)
import Data.Aeson (FromJSON (..), Value, eitherDecode, eitherDecodeStrict, encode, withObject, (.:), (.:?))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Kanban.ApprovalService (systemdUserManagerIsLive)
import Kanban.Domain (Repository (..))
import Kanban.Drainer (normalizedRepositoryIdentity, unitExecStartArguments)
import Kanban.ManagedPaths (ManagedComponent (MissionRunnerComponent), managedRecordPath, recordPathOccupied)
import Kanban.Mission
  ( MissionId,
    MissionJournalLine,
    MissionLogKind,
    MissionLogReference (..),
    MissionRead (..),
    MissionSealedArchive (..),
    MissionSessionId,
    MissionSessionNode (..),
    MissionSnapshot (..),
    MissionStore,
    missionSealedArchivePath,
    readMissionJournal,
    readMissionJournalSince,
    readMissionSealedArchives,
    readMissionSnapshot,
    verifyMissionSealedArchive,
  )
import Kanban.ServiceProcess
  ( diagnosticMessage,
    invocationFailureMessage,
    runGroupedProcess,
    serviceTransitionCommand,
  )
import Kanban.Text (sanitizeText, withoutJsonPath)
import System.Directory (findExecutable)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute)
import System.Info (os)

-- * The installed job

-- | Which service manager an installed mission runner job is managed by.
--
-- Read out of the discovery record rather than inferred from the host, exactly
-- as the other two services' are and for the same reason: the record is what
-- @tools\/mission_runner_service.py@ actually wrote, and it selects its backend
-- by probing the host rather than by naming a platform. A separate type from
-- theirs, so neither of their records can ever be read as a mission runner job.
data MissionRunnerBackend
  = MissionRunnerLaunchd
  | MissionRunnerSystemd
  deriving stock (Bounded, Enum, Eq, Ord, Show)

missionRunnerBackends :: [MissionRunnerBackend]
missionRunnerBackends = [minBound .. maxBound]

-- | What each manager calls the file it reads a definition from, so a
-- \"missing\" or \"unreadable\" message names the artifact an operator would go
-- and look at.
missionRunnerDefinitionNoun :: MissionRunnerBackend -> Text
missionRunnerDefinitionNoun MissionRunnerLaunchd = "LaunchAgent"
missionRunnerDefinitionNoun MissionRunnerSystemd = "systemd unit"

-- | What each manager is called where a message names the manager itself.
-- Matches the @backend@ key the record is keyed on.
missionRunnerManagerName :: MissionRunnerBackend -> Text
missionRunnerManagerName MissionRunnerLaunchd = "launchd"
missionRunnerManagerName MissionRunnerSystemd = "systemd"

-- | The controller command one repository's mission runner is driven through.
--
-- The checkout and the identity are fields rather than trailing arguments,
-- which is where this differs from "Kanban.ApprovalService" and why. That
-- controller takes @--path@ and @--repo@ on its /top-level/ parser, so a
-- rebound prefix serves every subcommand; @tools\/mission_runner_service.py@
-- declares both on each subparser instead, so the binding has to follow the
-- subcommand rather than precede it. 'missionRunnerCommandArguments' is the one
-- place that order is spelled.
data MissionRunnerController = MissionRunnerController
  { missionRunnerControllerExecutable :: FilePath,
    -- | Everything the installed definition names before its own subcommand:
    -- the installed controller script, and nothing else this release writes.
    missionRunnerControllerArguments :: [String],
    -- | The checkout every invocation is bound to. This dashboard's own, not
    -- the one the record happens to remember: a second checkout of one
    -- repository is that repository's own service.
    missionRunnerControllerRepository :: FilePath,
    -- | The repository that checkout is expected to be a clone of. It travels
    -- as @--repo@ rather than being trusted: the controller compares it
    -- against the checkout's remote and refuses a mismatch, so containment
    -- lives on the side that owns the job.
    missionRunnerControllerIdentity :: Text,
    -- | The manager whose definition this command was read out of.
    missionRunnerControllerBackend :: MissionRunnerBackend
  }
  deriving stock (Eq, Show)

-- | What the mission runner installer recorded about the job it wrote for one
-- repository. The record carries the job's location, never its content:
-- discovery still reads the command out of the definition itself.
data MissionRunnerRecord = MissionRunnerRecord
  { missionRunnerRecordBackend :: MissionRunnerBackend,
    -- | The launchd label or systemd unit name the definition was written for.
    missionRunnerRecordIdentifier :: Text,
    missionRunnerRecordDefinition :: FilePath,
    -- | Which checkout the job was installed for. Metadata only, for the
    -- reason 'missionRunnerControllerRepository' gives.
    missionRunnerRecordRepository :: FilePath
  }
  deriving stock (Eq, Show)

-- | Why there is no mission runner to observe, as a closed vocabulary.
--
-- Each is a distinct reported state and never an error, because the repairs
-- differ and an operator told only \"unknown\" cannot tell which one they are
-- looking at. A host with no service manager /cannot/ run this job at all,
-- while a record another release wrote, a record naming another manager, an
-- unreadable definition, and a job that is simply stopped are four different
-- things an operator does four different things about — and none of them is a
-- runner reporting its own state.
data MissionRunnerUnavailableCase
  = -- | This host has no service manager that could have installed the job,
    -- so there is nothing to discover and nothing to control.
    MissionRunnerHostHasNoManager
  | -- | No record at all, or a record naming no job for this repository.
    MissionRunnerJobNotInstalled
  | -- | The record is there and will not decode, or its entry for this
    -- repository does not describe a job.
    MissionRunnerRecordUnreadable
  | -- | The record declares a schema this release does not read.
    MissionRunnerRecordSchemaUnknown
  | -- | The record declares a version this release does not read.
    MissionRunnerRecordVersionUnknown
  | -- | The record describes a job managed by a service manager this host does
    -- not have, which is a document that travelled between hosts rather than
    -- an installation.
    MissionRunnerRecordForeignManager
  | -- | The definition the record names is missing, or is there and will not
    -- parse into a controller command.
    MissionRunnerDefinitionUnreadable
  | -- | Discovered, installed, and not running. The one case that keeps its
    -- controller, because starting it is what repairs it.
    MissionRunnerJobStopped
  deriving stock (Bounded, Enum, Eq, Ord, Show)

missionRunnerUnavailableCases :: [MissionRunnerUnavailableCase]
missionRunnerUnavailableCases = [minBound .. maxBound]

-- | The clause that says which case this is, and the whole of what
-- distinguishes one message from another.
--
-- Total over the vocabulary, so a ninth case does not compile until it has a
-- headline of its own, and distinct across it, which 'Spec.MissionRunnerService'
-- enumerates so a ninth case cannot reuse an existing one either.
missionRunnerUnavailableHeadline :: MissionRunnerUnavailableCase -> Text
missionRunnerUnavailableHeadline unavailableCase = case unavailableCase of
  MissionRunnerHostHasNoManager -> "the mission runner is not supported on this host"
  MissionRunnerJobNotInstalled -> "the mission runner is not installed"
  MissionRunnerRecordUnreadable -> "the mission runner's install record is unreadable"
  MissionRunnerRecordSchemaUnknown -> "the mission runner's install record declares another schema"
  MissionRunnerRecordVersionUnknown -> "the mission runner's install record declares another version"
  MissionRunnerRecordForeignManager -> "the mission runner's installed job belongs to another service manager"
  MissionRunnerDefinitionUnreadable -> "the mission runner's installed job definition is not usable"
  MissionRunnerJobStopped -> "the mission runner is installed and stopped"

-- | One reason there is no runner to observe: which case it is, the whole
-- message an operator reads, and the controller it still has.
data MissionRunnerUnavailable = MissionRunnerUnavailable
  { missionRunnerUnavailableCase :: MissionRunnerUnavailableCase,
    -- | The headline, what was wrong here, and — for every case an operator
    -- can act on — the repair.
    missionRunnerUnavailableMessage :: Text,
    -- | Exactly 'MissionRunnerJobStopped' carries one. Every other case is a
    -- runner that was never discovered, so there is nothing to start.
    missionRunnerUnavailableController :: Maybe MissionRunnerController
  }
  deriving stock (Eq, Show)

-- | An unavailable case with nothing to start, composed from its headline.
undiscoverable :: MissionRunnerUnavailableCase -> Text -> MissionRunnerUnavailable
undiscoverable unavailableCase detail =
  MissionRunnerUnavailable
    unavailableCase
    (missionRunnerUnavailableHeadline unavailableCase <> ": " <> detail)
    Nothing

missionRunnerReinstallHint :: Text
missionRunnerReinstallHint = "run `python3 tools/install_mission_runner.py` from the Kanban checkout"

-- | The keys one backend's entry is spelled with, paired here so that the
-- mixed-shape rejection below can be stated against a single readable fact.
-- The pairs are @tools\/service_manager.py@'s @LAUNCHD_RECORD_KEYS@ and
-- @SYSTEMD_RECORD_KEYS@.
missionRunnerRecordKeysFor :: MissionRunnerBackend -> (Key.Key, Key.Key)
missionRunnerRecordKeysFor MissionRunnerLaunchd = ("launchd_label", "plist_path")
missionRunnerRecordKeysFor MissionRunnerSystemd = ("systemd_unit", "unit_path")

-- | What an entry's @backend@ field says, with \"absent\" kept apart from
-- \"present but naming nothing\".
data DeclaredMissionRunnerBackend
  = MissionRunnerBackendAbsent
  | MissionRunnerBackendNull
  | MissionRunnerBackendNamed Text

declaredMissionRunnerBackend :: Aeson.Object -> Parser DeclaredMissionRunnerBackend
declaredMissionRunnerBackend value = case KeyMap.lookup "backend" value of
  Nothing -> pure MissionRunnerBackendAbsent
  Just Aeson.Null -> pure MissionRunnerBackendNull
  Just _ -> MissionRunnerBackendNamed <$> value .: "backend"

-- | Reads one repository's entry as a discriminated union on @backend@.
--
-- An entry naming no backend is refused rather than read as launchd. There is
-- no compatibility case to keep working: this service's installer has written
-- the discriminator since its first release, so an entry without one was not
-- written by it, and guessing a manager for it would control the wrong job or
-- none at all.
parseMissionRunnerRecord :: Value -> Parser (Either Text MissionRunnerRecord)
parseMissionRunnerRecord = withObject "mission runner install record" $ \value -> do
  declared <- declaredMissionRunnerBackend value
  let presentKeys backend =
        filter
          (`KeyMap.member` value)
          [fst (missionRunnerRecordKeysFor backend), snd (missionRunnerRecordKeysFor backend)]
      others backend = filter (/= backend) missionRunnerBackends
      strayKeys backend = concatMap presentKeys (others backend)
      strayDetail backend = Text.intercalate " and " (map Key.toText (strayKeys backend))
      read' backend = do
        let (identifierKey, definitionKey) = missionRunnerRecordKeysFor backend
        identifier <- value .: identifierKey
        definition <- value .: definitionKey
        repository <- value .: "repository"
        pure (MissionRunnerRecord backend identifier definition repository)
  case declared of
    MissionRunnerBackendAbsent ->
      pure (Left "it names no service-manager backend")
    MissionRunnerBackendNull ->
      pure (Left "its backend field is null, which names no service manager")
    MissionRunnerBackendNamed name ->
      case lookup name [(missionRunnerManagerName backend, backend) | backend <- missionRunnerBackends] of
        Nothing ->
          pure (Left ("it names an unknown service-manager backend: " <> sanitizeText name))
        Just backend
          | not (null (strayKeys backend)) ->
              pure
                ( Left
                    ( "it names the "
                        <> missionRunnerManagerName backend
                        <> " backend but also carries "
                        <> strayDetail backend
                    )
                )
          | otherwise -> Right <$> read' backend

-- | The installed document: one entry per canonical GitHub repository beside
-- the installer's own shared keys, and whatever shape the writer declared for
-- itself.
--
-- Entries stay unparsed until one is selected, so a malformed entry for another
-- repository cannot make this one's runner undiscoverable.
data MissionRunnerRecordDocument = MissionRunnerRecordDocument
  { recordDocumentSchema :: Maybe Value,
    recordDocumentVersion :: Maybe Value,
    recordDocumentRepositories :: Map Text Value
  }

instance FromJSON MissionRunnerRecordDocument where
  parseJSON = withObject "mission runner install record" $ \value ->
    MissionRunnerRecordDocument (KeyMap.lookup "schema" value) (KeyMap.lookup "version" value)
      . fromMaybe Map.empty
      <$> value .:? "repositories"

-- | Why a record document is not one this release may read.
--
-- Three answers rather than one string, because they are three different
-- reported states: a document this release cannot parse is broken, and a
-- document declaring a schema or a version is one a /later/ release wrote and
-- is intact. Neither is an absent installation, and neither is a decode error a
-- caller has to interpret.
data MissionRunnerRecordFailure = MissionRunnerRecordFailure
  { missionRunnerRecordFailureCase :: MissionRunnerUnavailableCase,
    missionRunnerRecordFailureDetail :: Text
  }
  deriving stock (Eq, Show)

-- | Where this host's mission runner discovery record is.
--
-- Asked of "Kanban.ManagedPaths" rather than spelled here, so this reader and
-- @tools\/mission_runner_service.py@ probe the same pair of locations in the
-- same order and a host discovers one installation rather than two. This module
-- therefore spells no managed location at all, which is what
-- 'Kanban.ManagedPaths' asks of every other module and what
-- "Kanban.Drainer" already does.
missionRunnerRecordPath :: IO FilePath
missionRunnerRecordPath = managedRecordPath MissionRunnerComponent

-- | Selects this repository's entry, rejecting a document that cannot name a
-- job for it.
--
-- The identity is matched case-insensitively on both sides, not only on the
-- caller's: GitHub owner and repository names are case-insensitive, the
-- installer normalizes the key it writes, and a record hand-edited to a
-- different spelling still names one repository. A foreign entry is simply not
-- selected, which reads as \"not installed for this repository\" rather than as
-- somebody else's service.
--
-- The document's own shape is decided before any of that. Nothing this release
-- installs writes a @schema@ or a @version@ key — @write_discovery_record@
-- writes a @repositories@ table and @update_json_document@ preserves whatever
-- else is already there — so a document declaring neither is this release's
-- shape and is read. A document declaring either was written by a release this
-- one has never seen, and its entries cannot be assumed to mean what these do,
-- so it is refused as its own state rather than parsed on the chance that the
-- keys still line up.
missionRunnerRecordFromBytes ::
  Text -> ByteString.ByteString -> Either MissionRunnerRecordFailure (Maybe MissionRunnerRecord)
missionRunnerRecordFromBytes identity bytes = do
  document <- case eitherDecodeStrict bytes :: Either String MissionRunnerRecordDocument of
    Left message -> Left (malformed (withoutJsonPath (Text.pack message)))
    Right decoded -> Right decoded
  case (document.recordDocumentSchema, document.recordDocumentVersion) of
    (Just declared, _) ->
      Left
        ( MissionRunnerRecordFailure
            MissionRunnerRecordSchemaUnknown
            ("it declares the schema " <> describedJson declared <> ", and this release reads a record that declares none")
        )
    (Nothing, Just declared) ->
      Left
        ( MissionRunnerRecordFailure
            MissionRunnerRecordVersionUnknown
            ("it declares the version " <> describedJson declared <> ", and this release reads a record that declares none")
        )
    (Nothing, Nothing) ->
      case [ value
             | (key, value) <- Map.toList document.recordDocumentRepositories,
               Text.toLower key == Text.toLower identity
           ] of
        [] -> Right Nothing
        value : _ -> Just <$> validated value
  where
    malformed = MissionRunnerRecordFailure MissionRunnerRecordUnreadable
    validated value = case parseEither parseMissionRunnerRecord value of
      Left message -> Left (malformed (withoutJsonPath (Text.pack message)))
      Right (Left message) -> Left (malformed message)
      Right (Right record)
        | Text.null (Text.strip record.missionRunnerRecordIdentifier) ->
            Left (malformed ("it names no " <> missionRunnerManagerName record.missionRunnerRecordBackend <> " identifier"))
        | not (isAbsolute record.missionRunnerRecordDefinition) ->
            Left
              ( malformed
                  ( "its "
                      <> missionRunnerDefinitionNoun record.missionRunnerRecordBackend
                      <> " path is not absolute: "
                      <> Text.pack record.missionRunnerRecordDefinition
                  )
              )
        | otherwise -> Right record

-- | One JSON value as a diagnostic names it: re-encoded rather than shown, so
-- the message says what the document actually carries, and bounded and
-- sanitized because it is a document this process did not write.
describedJson :: Value -> Text
describedJson =
  sanitizeText . Text.take 120 . Text.decodeUtf8Lenient . LazyByteString.toStrict . encode

-- | The service manager this host could have installed a mission runner job
-- through, or nothing at all.
--
-- Probed rather than read off @System.Info.os@, because availability is what
-- decides it and the platform's name is not availability: a Linux container
-- with no session bus behind its @systemctl@ manages nothing, and a job
-- installed against it would be a unit no manager ever loads. This mirrors
-- @tools\/service_manager.py@'s @_probe_service_manager@ exactly — macOS with
-- @launchctl@, otherwise a @systemctl@ whose @--user@ manager answers a version
-- read, otherwise neither — so the installer and this reader agree about which
-- hosts have a service at all.
--
-- The probe itself is 'systemdUserManagerIsLive', which is the one reading of
-- that question and is not the approval service's to own; only the selection
-- between the two managers is restated, because its answer is this module's own
-- type and requirement 1 refuses to share another service's.
--
-- Which manager an installed job actually uses stays the record's answer, not
-- this one.
detectMissionRunnerHostBackend :: IO (Maybe MissionRunnerBackend)
detectMissionRunnerHostBackend = do
  launchctl <- if os == "darwin" then findExecutable "launchctl" else pure Nothing
  case launchctl of
    Just _ -> pure (Just MissionRunnerLaunchd)
    Nothing -> do
      systemctl <- findExecutable "systemctl"
      case systemctl of
        Nothing -> pure Nothing
        Just _ -> do
          live <- systemdUserManagerIsLive
          pure (if live then Just MissionRunnerSystemd else Nothing)

-- | Resolves this repository's installed job definition, naming the remediation
-- for every way the lookup can fail.
--
-- Parameterised by the /detected/ host backend rather than by a platform name,
-- so every branch — including a Linux host whose user manager is not reachable,
-- which arrives here as 'Nothing' exactly as an unsupported platform does — is
-- exercisable off any one host.
resolveMissionRunnerDefinition ::
  Maybe MissionRunnerBackend ->
  Text ->
  FilePath ->
  IO (Either MissionRunnerUnavailable (MissionRunnerBackend, FilePath))
resolveMissionRunnerDefinition detected identity recordPath =
  case detected of
    Nothing ->
      pure
        ( Left
            ( undiscoverable
                MissionRunnerHostHasNoManager
                "it needs macOS launchd or a systemd user session reachable \
                \through `systemctl --user`, and this host has neither"
            )
        )
    Just hostBackend -> do
      -- Occupancy rather than readability, and the difference is the whole of
      -- requirement 3's "never as an absent installation".
      -- 'Kanban.ManagedPaths' selects this location precisely because
      -- something is at it, a directory or a dangling link included, and never
      -- falls through to the other candidate; a reader that asked
      -- @doesFileExist@ would take that damaged record for no record at all,
      -- report a service nobody installed, and leave the thing actually in the
      -- way unmentioned. Only a path with nothing at all at it is an absent
      -- installation here. What is wrong with an occupied one is the read's
      -- answer, below.
      recorded <- recordPathOccupied recordPath
      if not recorded
        then pure (Left notInstalled)
        else do
          contents <- try @IOException (ByteString.readFile recordPath)
          case fmap (missionRunnerRecordFromBytes identity) contents of
            Left _ -> pure (Left (unreadableRecord (MissionRunnerRecordFailure MissionRunnerRecordUnreadable "it could not be read")))
            Right (Left failure) -> pure (Left (unreadableRecord failure))
            Right (Right Nothing) -> pure (Left notInstalled)
            Right (Right (Just record))
              | record.missionRunnerRecordBackend /= hostBackend ->
                  pure (Left (foreignBackend record.missionRunnerRecordBackend hostBackend))
              | otherwise -> definitionOf record
  where
    notInstalled =
      undiscoverable
        MissionRunnerJobNotInstalled
        ( identity
            <> " has no entry in the install record at "
            <> Text.pack recordPath
            <> "; "
            <> missionRunnerReinstallHint
        )

    foreignBackend recorded hostBackend =
      undiscoverable
        MissionRunnerRecordForeignManager
        ( "the install record describes a "
            <> missionRunnerManagerName recorded
            <> " job, which this "
            <> missionRunnerManagerName hostBackend
            <> " host cannot run; "
            <> missionRunnerReinstallHint
        )

    -- The same distinction one level down: a definition path with nothing at
    -- it is missing, and one occupied by something that is not a definition is
    -- handed to the reader, whose own complaint says what is there. Both are
    -- the unreadable-definition state; only one of them is "reinstall".
    definitionOf record = do
      installed <- recordPathOccupied record.missionRunnerRecordDefinition
      pure $
        if installed
          then Right (record.missionRunnerRecordBackend, record.missionRunnerRecordDefinition)
          else
            Left
              ( undiscoverable
                  MissionRunnerDefinitionUnreadable
                  ( "the "
                      <> missionRunnerDefinitionNoun record.missionRunnerRecordBackend
                      <> " is missing at "
                      <> Text.pack record.missionRunnerRecordDefinition
                      <> "; "
                      <> missionRunnerReinstallHint
                  )
              )

    -- Every record failure names the record it was reading. Only the broken
    -- one names the repair: a document a later release wrote is intact, and
    -- reinstalling over it would replace a record this Kanban simply cannot
    -- read with one it can, which is the wrong half of the pair to change.
    unreadableRecord failure =
      undiscoverable
        failure.missionRunnerRecordFailureCase
        ( failure.missionRunnerRecordFailureDetail
            <> " ("
            <> Text.pack recordPath
            <> ")"
            <> case failure.missionRunnerRecordFailureCase of
              MissionRunnerRecordUnreadable -> "; " <> missionRunnerReinstallHint
              _ -> ""
        )

-- | A definition that is present but will not parse is the one failure the
-- record cannot diagnose, so it carries the reader's own complaint — and, like
-- every other branch, the repair.
unreadableMissionRunnerDefinition :: MissionRunnerBackend -> FilePath -> Text -> Text
unreadableMissionRunnerDefinition backend definition detail =
  "could not read the "
    <> missionRunnerDefinitionNoun backend
    <> " at "
    <> Text.pack definition
    <> ": "
    <> detail
    <> "; "
    <> missionRunnerReinstallHint

-- | Rebinds the installed job's command to this dashboard's own checkout, and
-- states which repository that checkout is expected to be a clone of.
--
-- The definition's own @run@ subcommand and everything after it are dropped:
-- @tools\/mission_runner_service.py@ takes @--path@, @--repo@ and @--config@ on
-- each subparser, so what precedes @run@ is exactly the interpreter and the
-- installed controller. Dropping @--config@ with the rest is deliberate and
-- costs nothing — @resolve_job@ falls back to the @config_path@ this
-- repository's own record entry carries, which is the durable selection — while
-- carrying it would make @status@ and @stop@, whose subparsers declare no such
-- option, fail to parse.
--
-- A definition naming no @run@ at all is refused rather than rebound. Every
-- definition this release writes names it, so one that does not was written by
-- something else, and appending a subcommand to whatever it does say would
-- invoke an argument vector nobody planned.
controllerFromMissionRunnerCommand ::
  MissionRunnerBackend -> FilePath -> Repository -> [String] -> Either Text MissionRunnerController
controllerFromMissionRunnerCommand backend definition repository arguments = case arguments of
  executable : rawArguments
    | "run" `elem` rawArguments,
      leading <- takeWhile (/= "run") rawArguments,
      not (null (stripBoundArguments leading)) ->
        Right
          ( MissionRunnerController
              executable
              (stripBoundArguments leading)
              repository.repositoryRoot
              (normalizedRepositoryIdentity repository)
              backend
          )
  -- Reported through 'unreadableMissionRunnerDefinition' like every other way
  -- a definition can fail to yield a controller, so the one state a caller
  -- sees always names the file to go and look at and the command that repairs
  -- it. A bare "these arguments do not identify the controller" names neither.
  _ ->
    Left
      ( unreadableMissionRunnerDefinition
          backend
          definition
          (missionRunnerCommandField backend <> " do not identify the mission runner controller")
      )

missionRunnerCommandField :: MissionRunnerBackend -> Text
missionRunnerCommandField MissionRunnerLaunchd = "launchd ProgramArguments"
missionRunnerCommandField MissionRunnerSystemd = "the systemd unit's ExecStart"

-- | Drops the arguments this side supplies itself, so a hand-edited definition
-- carrying any of them before its subcommand cannot make the rebuilt command
-- name two checkouts or two repositories.
stripBoundArguments :: [String] -> [String]
stripBoundArguments (argument : _ : rest)
  | argument `elem` ["--path", "--repo", "--config"] = stripBoundArguments rest
stripBoundArguments (argument : rest) = argument : stripBoundArguments rest
stripBoundArguments [] = []

-- | The complete argument vector one controller invocation runs with.
--
-- The subcommand first and the binding after it, because that is where this
-- controller's parser declares @--path@, @--repo@ and @--json@. Spelled once so
-- a status read, a start and a stop cannot disagree about the order.
missionRunnerCommandArguments :: MissionRunnerController -> String -> [String]
missionRunnerCommandArguments controller command =
  controller.missionRunnerControllerArguments
    <> [ command,
         "--path",
         controller.missionRunnerControllerRepository,
         "--repo",
         Text.unpack controller.missionRunnerControllerIdentity,
         "--json"
       ]

-- * What it reports

-- | What the controller reported about the runner itself.
--
-- Every state @tools\/mission_runner_service.py@ publishes has its own
-- constructor, so no two are ever flattened together and no absent, malformed,
-- or wrongly versioned document can arrive as one of them.
data MissionRunnerActivity
  = -- | A scheduler pass is in flight, or the last one advanced something and
    -- the next starts immediately.
    MissionRunnerAdvancing
  | -- | Supervising, with nothing to advance.
    MissionRunnerIdle
  | -- | The last pass left a mission waiting on a person.
    MissionRunnerWaiting
  | -- | Stopped on purpose. Distinct from every failure.
    MissionRunnerStopped
  | -- | The run ended in failure.
    MissionRunnerFailed
  | -- | This host cannot run the job at all, which is neither a stopped runner
    -- nor an unknown one.
    MissionRunnerUnsupported
  | -- | No usable status: the controller could not be discovered or run, its
    -- document did not decode, carried another schema or version, named another
    -- repository, or named a state this does not recognize. Every one of those
    -- is \"unknown\", never \"off\".
    MissionRunnerUnknown
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- | Whether an incident is a warning or a run that ended. Carried rather than
-- inferred, because the controller publishes the severity and a reader that
-- guessed would present a failed pass as a healthy pause.
data MissionRunnerSeverity
  = MissionRunnerWarningSeverity
  | MissionRunnerErrorSeverity
  deriving stock (Eq, Show)

-- | One incident the controller recorded.
data MissionRunnerIncident = MissionRunnerIncident
  { -- | The service-provided identity. Required: an incident that cannot name
    -- itself cannot be safely selected or acknowledged.
    missionRunnerIncidentId :: Text,
    missionRunnerIncidentKind :: Text,
    missionRunnerIncidentSeverity :: MissionRunnerSeverity,
    -- | @open@ or @resolved@, as the controller records it.
    missionRunnerIncidentStatus :: Text,
    missionRunnerIncidentSummary :: Maybe Text,
    missionRunnerIncidentDetail :: Maybe Text,
    missionRunnerIncidentOccurredAt :: Maybe Text
  }
  deriving stock (Eq, Show)

instance FromJSON MissionRunnerIncident where
  parseJSON = withObject "mission runner incident" $ \value ->
    MissionRunnerIncident
      <$> value .: "incident_id"
      <*> value .: "kind"
      <*> (severityFrom <$> value .:? "severity")
      <*> (fromMaybe "open" <$> value .:? "status")
      <*> value .:? "summary"
      <*> value .:? "detail"
      <*> value .:? "occurred_at"
    where
      -- An incident whose severity is absent or unrecognized is an error, not a
      -- warning: a warning is the one severity that says \"nothing failed\", and
      -- guessing it would present a failed run as a healthy pause.
      severityFrom :: Maybe Text -> MissionRunnerSeverity
      severityFrom (Just "warning") = MissionRunnerWarningSeverity
      severityFrom _ = MissionRunnerErrorSeverity

-- | One mission the last pass reported as waiting on a person.
data MissionRunnerAttention = MissionRunnerAttention
  { missionRunnerAttentionMission :: Text,
    missionRunnerAttentionId :: Text,
    -- | The notification state the pass recorded, undecoded: this module reads
    -- the runner's documents and does not own that vocabulary.
    missionRunnerAttentionNotification :: Maybe Text,
    missionRunnerAttentionDetail :: Maybe Text
  }
  deriving stock (Eq, Show)

instance FromJSON MissionRunnerAttention where
  parseJSON = withObject "mission runner attention" $ \value ->
    MissionRunnerAttention
      <$> value .: "mission"
      <*> value .: "attention_id"
      <*> value .:? "notification"
      <*> value .:? "detail"

data MissionRunnerStatus = MissionRunnerStatus
  { missionRunnerActivity :: MissionRunnerActivity,
    -- | What to show beside the activity: the controller's own message, or why
    -- its stored document was not believed.
    missionRunnerDetail :: Text,
    -- | The controller's own reason for not believing its stored document,
    -- kept apart from the detail so a caller can tell a reported reason from a
    -- reason this reader composed.
    missionRunnerReason :: Maybe Text,
    missionRunnerPid :: Maybe Int,
    missionRunnerPassPid :: Maybe Int,
    missionRunnerPasses :: Maybe Int,
    missionRunnerStartedAt :: Maybe Text,
    missionRunnerUpdatedAt :: Maybe Text,
    missionRunnerAttention :: [MissionRunnerAttention],
    -- | The newest open incident, kept beside the activity rather than folded
    -- into it: a stopped runner with an unresolved incident is both, and
    -- neither fact may erase the other.
    missionRunnerIncident :: Maybe MissionRunnerIncident
  }
  deriving stock (Eq, Show)

-- | One controller response: the status projection and the complete set of open
-- incidents behind it.
--
-- 'observedMissionRunnerIncidents' is 'Nothing' whenever the document was not
-- this repository's to read, which is not the same as a runner reporting none.
data MissionRunnerObservation = MissionRunnerObservation
  { observedMissionRunnerStatus :: MissionRunnerStatus,
    observedMissionRunnerIncidents :: Maybe [MissionRunnerIncident]
  }
  deriving stock (Eq, Show)

-- | The schema and version this Kanban reads, mirrored from
-- @tools\/mission_runner_service.py@'s @STATUS_SCHEMA@ and @STATUS_VERSION@.
-- Pinned rather than tolerated: a document of another shape may spell @state@
-- the same way and mean something else, and a reader that accepted it would
-- report a guess as a fact.
missionRunnerStatusSchema :: Text
missionRunnerStatusSchema = "kanban-mission-runner-status"

missionRunnerStatusVersion :: Int
missionRunnerStatusVersion = 1

-- | The same, for the incident documents the status carries. An incident of
-- another schema or version is dropped silently rather than reported: it is a
-- record another release wrote, and §16's rule for one of those is that it says
-- nothing rather than complaining.
missionRunnerIncidentSchema :: Text
missionRunnerIncidentSchema = "kanban-mission-runner-incident"

missionRunnerIncidentVersion :: Int
missionRunnerIncidentVersion = 1

data RawMissionRunnerStatus = RawMissionRunnerStatus
  { rawSchema :: Maybe Text,
    rawVersion :: Maybe Int,
    rawRepository :: Maybe Text,
    rawState :: Maybe Text,
    rawReason :: Maybe Text,
    rawMessage :: Maybe Text,
    rawRunnerPid :: Maybe Int,
    rawPassPid :: Maybe Int,
    rawPasses :: Maybe Int,
    rawStartedAt :: Maybe Text,
    rawUpdatedAt :: Maybe Text,
    rawAttention :: Maybe [Value],
    rawOpenIncident :: Maybe Value,
    rawOpenIncidents :: Maybe [Value]
  }

instance FromJSON RawMissionRunnerStatus where
  parseJSON = withObject "mission runner status" $ \value ->
    pure
      RawMissionRunnerStatus
        { rawSchema = usableField value "schema",
          rawVersion = usableField value "version",
          rawRepository = usableField value "repository",
          rawState = usableField value "state",
          rawReason = usableField value "reason",
          rawMessage = usableField value "message",
          rawRunnerPid = usableField value "runner_pid",
          rawPassPid = usableField value "pass_pid",
          rawPasses = usableField value "passes",
          rawStartedAt = usableField value "started_at",
          rawUpdatedAt = usableField value "updated_at",
          rawAttention = usableField value "attention",
          rawOpenIncident = usableField value "open_incident",
          rawOpenIncidents = usableField value "open_incidents"
        }

-- | One optional field, absent when the key is missing /or/ when what is there
-- is not a shape this reader can use.
--
-- Deliberately not aeson's '.:?', which fails the whole decode over a single
-- field of the wrong type. This is a document another process wrote: a reader
-- that refused to say anything at all because @passes@ was a string would
-- report the whole runner as unreadable over a field nothing depends on, and a
-- @schema@ or @version@ of the wrong type would arrive as a decode failure
-- rather than as the containment refusal below. The controller also writes
-- explicit nulls — @pass_pid@ is null whenever no pass is live — and those are
-- absent for the same reason a missing key is.
usableField :: FromJSON value => Aeson.Object -> Key.Key -> Maybe value
usableField fields key = KeyMap.lookup key fields >>= usableValue

-- | One value, or nothing when it will not decode into what was asked for.
usableValue :: FromJSON value => Value -> Maybe value
usableValue value = case Aeson.fromJSON value of
  Aeson.Success decoded -> Just decoded
  Aeson.Error _ -> Nothing

-- | Decodes one controller status document against the repository the board is
-- showing.
--
-- Every way the document can fail to describe /this/ runner now — it will not
-- parse, carries another schema or another version, records another repository,
-- or names a state this reader does not know — resolves to an explicit unknown
-- naming what was wrong, never to a healthy or stopped guess.
decodeMissionRunnerStatus :: Text -> LazyByteString.ByteString -> Either Text MissionRunnerObservation
decodeMissionRunnerStatus identity bytes = case eitherDecode bytes of
  Left message -> Left ("could not decode mission runner status: " <> withoutJsonPath (Text.pack message))
  Right raw -> Right (observationFrom identity raw)

observationFrom :: Text -> RawMissionRunnerStatus -> MissionRunnerObservation
observationFrom identity raw = MissionRunnerObservation status incidents
  where
    -- Only ever reported for a document this reader accepted. A rejected one
    -- describes some other runner, so its incident set is not this
    -- repository's to show.
    incidents = case containment of
      Just _ -> Nothing
      Nothing -> Just (maybe [] readableIncidents raw.rawOpenIncidents)

    incident = case raw.rawOpenIncident >>= readableIncident of
      Just newest -> Just newest
      Nothing -> case incidents of
        Just (newest : _) -> Just newest
        _ -> Nothing

    -- Per entry rather than per list, for 'usableField''s reason one level
    -- down: an attention entry naming no mission is the one this reader drops,
    -- not the whole set beside it.
    attention = maybe [] (mapMaybe usableValue) raw.rawAttention

    -- Every reason this document is not an answer about this repository's
    -- runner, in the order that makes the message actionable. Schema and
    -- version come before the payload so a document another release wrote is
    -- silent rather than misread.
    containment
      | raw.rawSchema /= Just missionRunnerStatusSchema =
          Just
            ( "the mission runner controller reported schema "
                <> maybe "none" sanitizeText raw.rawSchema
                <> ", not "
                <> missionRunnerStatusSchema
            )
      | raw.rawVersion /= Just missionRunnerStatusVersion =
          Just
            ( "the mission runner controller reported status version "
                <> maybe "none" (Text.pack . show) raw.rawVersion
                <> ", not "
                <> Text.pack (show missionRunnerStatusVersion)
            )
      | not (identityMatches raw.rawRepository) =
          Just
            ( "the mission runner controller reported repository "
                <> maybe "none" sanitizeText raw.rawRepository
                <> ", not "
                <> identity
            )
      | otherwise = Nothing

    identityMatches (Just recorded) = Text.toLower recorded == Text.toLower identity
    identityMatches Nothing = False

    status = case containment of
      Just message -> reported MissionRunnerUnknown message
      Nothing -> stateFrom raw.rawState

    -- The controller's own `unknown` carries the reason it did not believe its
    -- stored document, and that reason is the whole of what a reader can say
    -- about it.
    stateFrom (Just "running") = live MissionRunnerAdvancing "advancing"
    stateFrom (Just "idle") = live MissionRunnerIdle "idle"
    stateFrom (Just "waiting") = live MissionRunnerWaiting "waiting on input"
    stateFrom (Just "stopped") = live MissionRunnerStopped "stopped"
    stateFrom (Just "failed") = live MissionRunnerFailed "failed"
    stateFrom (Just "unknown") =
      reported MissionRunnerUnknown (maybe "the mission runner controller could not say" sanitizeText raw.rawReason)
    stateFrom (Just other) = reported MissionRunnerUnknown ("unknown state: " <> sanitizeText other)
    stateFrom Nothing = reported MissionRunnerUnknown "the mission runner controller reported no state"

    -- The controller's own message when it wrote one, and the state's own
    -- wording when it did not.
    live activity fallback = reported activity (maybe fallback sanitizeText (nonBlank raw.rawMessage))

    nonBlank (Just value) | not (Text.null (Text.strip value)) = Just value
    nonBlank _ = Nothing

    reported activity detail =
      MissionRunnerStatus
        activity
        detail
        (sanitizeText <$> raw.rawReason)
        raw.rawRunnerPid
        raw.rawPassPid
        raw.rawPasses
        raw.rawStartedAt
        raw.rawUpdatedAt
        attention
        incident

-- | The incidents in one reported set that this release may read.
--
-- Each is checked for its own schema and version before its payload, exactly as
-- the controller checks them before publishing: a record another release wrote
-- is absent rather than decoded into a shape it was not written in.
readableIncidents :: [Value] -> [MissionRunnerIncident]
readableIncidents = mapMaybe readableIncident

readableIncident :: Value -> Maybe MissionRunnerIncident
readableIncident value = case value of
  Aeson.Object fields
    | usableField fields "schema" == Just missionRunnerIncidentSchema,
      usableField fields "version" == Just missionRunnerIncidentVersion ->
        usableValue value
  _ -> Nothing

-- | The status a dashboard shows for a runner it has no live controller for.
--
-- An unsupported host and a stopped job each get their own activity, so nothing
-- downstream can mistake either for the other or for a runner whose state
-- simply could not be read; every remaining discovery failure is unknown for
-- the same reason a failed poll is.
missionRunnerUnavailableStatus :: MissionRunnerUnavailable -> MissionRunnerStatus
missionRunnerUnavailableStatus unavailable =
  MissionRunnerStatus
    activity
    (sanitizeText unavailable.missionRunnerUnavailableMessage)
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing
    Nothing
    []
    Nothing
  where
    activity = case unavailable.missionRunnerUnavailableCase of
      MissionRunnerHostHasNoManager -> MissionRunnerUnsupported
      MissionRunnerJobStopped -> MissionRunnerStopped
      MissionRunnerJobNotInstalled -> MissionRunnerUnknown
      MissionRunnerRecordUnreadable -> MissionRunnerUnknown
      MissionRunnerRecordSchemaUnknown -> MissionRunnerUnknown
      MissionRunnerRecordVersionUnknown -> MissionRunnerUnknown
      MissionRunnerRecordForeignManager -> MissionRunnerUnknown
      MissionRunnerDefinitionUnreadable -> MissionRunnerUnknown

-- | Whether the runner is supervising this repository right now, read off the
-- activity rather than off the rendered detail. The three live states are
-- @tools\/mission_runner_service.py@'s @LIVE_STATES@.
missionRunnerIsRunning :: MissionRunnerStatus -> Bool
missionRunnerIsRunning status = case status.missionRunnerActivity of
  MissionRunnerAdvancing -> True
  MissionRunnerIdle -> True
  MissionRunnerWaiting -> True
  MissionRunnerStopped -> False
  MissionRunnerFailed -> False
  MissionRunnerUnsupported -> False
  MissionRunnerUnknown -> False

-- | What a discovered controller and the status it reported say about whether
-- there is a runner to observe.
--
-- The one producer of 'MissionRunnerJobStopped', and the reason that case keeps
-- its controller: the job was discovered, so starting it is something this
-- dashboard can still do, and an unavailability that threw the handle away
-- would make the one repair unreachable.
missionRunnerAvailability ::
  MissionRunnerController -> MissionRunnerStatus -> Either MissionRunnerUnavailable MissionRunnerController
missionRunnerAvailability controller status
  | missionRunnerIsRunning status = Right controller
  | otherwise =
      Left
        ( MissionRunnerUnavailable
            MissionRunnerJobStopped
            ( missionRunnerUnavailableHeadline MissionRunnerJobStopped
                <> ": "
                <> sanitizeText status.missionRunnerDetail
            )
            (Just controller)
        )

-- * Control

-- | What the ownership diagnostics of a timed-out invocation call the process
-- they are about, so a mission runner message is never the shape \"the drainer
-- controller led\".
missionRunnerControllerSubject :: Text
missionRunnerControllerSubject = "the mission runner controller"

missionRunnerDiscoveryTimeoutSeconds :: Int
missionRunnerDiscoveryTimeoutSeconds = 3

missionRunnerStatusTimeoutSeconds :: Int
missionRunnerStatusTimeoutSeconds = 4

-- | Longer than the other two services'. This controller's own @start@ waits up
-- to @START_TIMEOUT_SECONDS@ for the job it kicked to announce itself and its
-- @stop@ up to @STOP_TIMEOUT_SECONDS@ for the run to be confirmed gone, so a
-- budget of theirs would cut every successful slow stop short and report an
-- outcome the next status read would have to reconcile.
missionRunnerTransitionTimeoutSeconds :: Int
missionRunnerTransitionTimeoutSeconds = 45

queryMissionRunnerStatus :: MissionRunnerController -> IO (Either Text MissionRunnerObservation)
queryMissionRunnerStatus controller =
  runMissionRunnerCommand missionRunnerStatusTimeoutSeconds controller "status"

setMissionRunnerRunning :: MissionRunnerController -> Bool -> IO (Either Text MissionRunnerObservation)
setMissionRunnerRunning controller shouldRun =
  runMissionRunnerCommand
    missionRunnerTransitionTimeoutSeconds
    controller
    (if shouldRun then "start" else "stop")

-- | The seconds-parameterised runner behind the two above, exported so the
-- termination and timeout-wording tests can drive a wedged controller without
-- waiting out a real transition budget.
--
-- Every invocation runs through "Kanban.ServiceProcess", so it is bounded and
-- leads its own process group, and an invocation that produced no exit status
-- is reported with 'serviceTransitionCommand''s distinction intact: a @start@
-- or a @stop@ cut short leaves a consequence the next status read settles and
-- says so, while a @status@ that timed out changed nothing and gets no such
-- promise.
runMissionRunnerCommand :: Int -> MissionRunnerController -> String -> IO (Either Text MissionRunnerObservation)
runMissionRunnerCommand seconds controller command = do
  result <-
    runGroupedProcess
      missionRunnerControllerSubject
      (Just seconds)
      controller.missionRunnerControllerExecutable
      (missionRunnerCommandArguments controller command)
  pure $ case result of
    Left failure ->
      Left
        ( invocationFailureMessage
            seconds
            ("mission runner " <> Text.pack command)
            (serviceTransitionCommand command)
            failure
        )
    Right (exitCode, output, errors) ->
      missionRunnerStatusFromControllerExit
        controller.missionRunnerControllerIdentity
        exitCode
        output
        errors

-- | Interprets a controller invocation that ran to completion. A controller
-- that exits nonzero while still printing a status document is reporting state
-- rather than failing, so stdout is offered to the decoder first even when
-- stderr carries diagnostics.
missionRunnerStatusFromControllerExit ::
  Text -> ExitCode -> String -> String -> Either Text MissionRunnerObservation
missionRunnerStatusFromControllerExit identity exitCode output errors =
  case (decodeMissionRunnerStatus identity (LazyByteString.pack output), exitCode) of
    (Right observation, _) -> Right observation
    (Left decodeFailure, ExitSuccess) -> Left decodeFailure
    (Left _, ExitFailure _) -> Left (diagnosticMessage output errors)

-- | Discovers this repository's mission runner controller: the record, the
-- definition it names, and the command inside that definition, rebound to this
-- dashboard's own checkout.
discoverMissionRunnerController :: Repository -> IO (Either MissionRunnerUnavailable MissionRunnerController)
discoverMissionRunnerController repository = do
  recordPath <- missionRunnerRecordPath
  detected <- detectMissionRunnerHostBackend
  resolved <- resolveMissionRunnerDefinition detected (normalizedRepositoryIdentity repository) recordPath
  case resolved of
    Left unavailable -> pure (Left unavailable)
    Right (MissionRunnerLaunchd, plist) -> do
      result <-
        runGroupedProcess
          missionRunnerControllerSubject
          (Just missionRunnerDiscoveryTimeoutSeconds)
          "/usr/bin/plutil"
          ["-extract", "ProgramArguments", "json", "-o", "-", plist]
      pure . asUnreadableDefinition $ do
        output <- case result of
          Left failure ->
            Left
              ( unreadableMissionRunnerDefinition
                  MissionRunnerLaunchd
                  plist
                  (invocationFailureMessage missionRunnerDiscoveryTimeoutSeconds "reading the launchd job" False failure)
              )
          Right (ExitSuccess, standardOutput, _) -> Right standardOutput
          Right (ExitFailure _, standardOutput, errors) ->
            Left (unreadableMissionRunnerDefinition MissionRunnerLaunchd plist (diagnosticMessage standardOutput errors))
        arguments <- case eitherDecode (LazyByteString.pack output) of
          Left message ->
            Left
              ( unreadableMissionRunnerDefinition
                  MissionRunnerLaunchd
                  plist
                  ("its ProgramArguments did not decode: " <> Text.pack message)
              )
          Right values -> Right values
        controllerFromMissionRunnerCommand MissionRunnerLaunchd plist repository arguments
    Right (MissionRunnerSystemd, unit) -> do
      contents <- try @IOException (ByteString.readFile unit)
      pure . asUnreadableDefinition $ do
        text <- case contents of
          Left _ -> Left (unreadableMissionRunnerDefinition MissionRunnerSystemd unit "it could not be read")
          Right bytes -> Right (Text.decodeUtf8Lenient bytes)
        systemdMissionRunnerControllerFromUnit repository unit text
  where
    asUnreadableDefinition = either (Left . undiscoverable MissionRunnerDefinitionUnreadable) Right

-- | The controller a systemd unit's own text names, for this service: the
-- shared reader's rules and this service's own rebinding and diagnostics.
--
-- Separated from the file read above for the same reason the other two
-- services' counterparts are — it is what @status@, @start@, and @stop@ go on
-- to invoke, and it has to be assertable from a host running the other service
-- manager.
systemdMissionRunnerControllerFromUnit ::
  Repository -> FilePath -> Text -> Either Text MissionRunnerController
systemdMissionRunnerControllerFromUnit repository unit text = do
  arguments <- case unitExecStartArguments text of
    Left message -> Left (unreadableMissionRunnerDefinition MissionRunnerSystemd unit message)
    Right values -> Right values
  controllerFromMissionRunnerCommand MissionRunnerSystemd unit repository arguments

-- * Replaying a mission's durable events

-- | One durable stream of a mission's record: a session's log, named by the
-- session it belongs to and the kind of log it is.
--
-- A session can leave two behind — its event stream and the provider's own raw
-- log — so the kind is part of the identity rather than a property of the
-- session.
data MissionStreamId = MissionStreamId
  { missionStreamSession :: MissionSessionId,
    missionStreamKind :: MissionLogKind
  }
  deriving stock (Eq, Ord, Show)

-- | Where a stream's bytes were read from on one pass.
--
-- Which of the two it is matters to a reader: a sealed archive is complete and
-- will not grow, while a live source may still be being appended to.
data MissionStreamSource
  = -- | The session's own log, still where the snapshot says it is.
    MissionStreamLive FilePath
  | -- | The mission's own sealed copy, read because the live source is gone.
    MissionStreamSealed FilePath
  deriving stock (Eq, Show)

-- | What one stream appended since the cursor it was last read with.
data MissionStreamReplay = MissionStreamReplay
  { missionStreamReplayId :: MissionStreamId,
    -- | The session's parent, carried so a console can place the stream in the
    -- tree without a second read of the snapshot. 'Nothing' for a root session,
    -- and for a stream whose session the snapshot no longer describes.
    missionStreamReplayParent :: Maybe MissionSessionId,
    missionStreamReplaySource :: MissionStreamSource,
    missionStreamReplayLines :: [ByteString.ByteString]
  }
  deriving stock (Eq, Show)

-- | Where a replay left off, per durable stream.
--
-- Not one shared offset: the mission's journal and every session's log are
-- separate files appended to independently, and a single number could only ever
-- be right about one of them. A stream with no entry has never been read, which
-- is what makes a session discovered after the first pass replay from its
-- beginning.
data MissionReplayCursor = MissionReplayCursor
  { missionJournalConsumed :: Int,
    missionStreamsConsumed :: Map MissionStreamId Int
  }
  deriving stock (Eq, Show)

emptyMissionReplayCursor :: MissionReplayCursor
emptyMissionReplayCursor = MissionReplayCursor 0 Map.empty

-- | Everything one mission's durable record appended since a cursor, and the
-- cursor to continue from.
data MissionReplay = MissionReplay
  { -- | The mission's own journal records, decoded under the store's rules: a
    -- line another release wrote is absent, a malformed or foreign one is
    -- reported rather than emitted as an event.
    missionReplayEvents :: [MissionJournalLine],
    -- | One entry per stream that had something to read, ordered by session and
    -- log kind so two passes over one record report in one order.
    missionReplayStreams :: [MissionStreamReplay],
    missionReplayCursor :: MissionReplayCursor,
    -- | What could not be read on this pass, each naming its subject.
    --
    -- Reported beside the rest rather than in place of it: one unreadable
    -- stream must not hide the records every other one appended, and the cursor
    -- of whatever failed is carried forward untouched so the next pass reads
    -- exactly what this one could not.
    missionReplayFailures :: [Text]
  }
  deriving stock (Eq, Show)

-- | Replays one mission's durable record from a cursor: its own journal, and
-- every session's log in its tree.
--
-- Nothing here inspects a live process, contacts GitHub, or advances anything,
-- and no mission lease is taken: this is the same read a collector performs,
-- driven from the dashboard side. The reads go through "Kanban.Mission"'s own
-- decoders rather than the byte-offset primitive alone, so a journal line
-- another release wrote is skipped with its bytes consumed, and a malformed or
-- foreign one is reported without being emitted as a valid event.
--
-- A session's own log is not a mission journal and is not decoded as one: its
-- bytes belong to the provider that wrote them, so what is replayed is the
-- complete lines it appended. An unterminated trailing line is left for the
-- pass after this one, so the same record is delivered once and whole.
--
-- A live source that has been collected falls back to the mission's sealed copy
-- of it, resolved through the store rather than joined from the name the seal
-- carries, and checked against the digest and byte length the seal records
-- before a byte of it is believed. The seal is a copy of the whole source, so
-- the cursor carries across the switch unchanged and the reader continues
-- exactly where it stopped.
--
-- What cannot be read is reported rather than returned as nothing: an
-- unreadable journal, an unreadable snapshot, a stream whose source is there
-- and will not open, and an archive that does not match its seal each leave
-- their own cursor exactly where it was, so the pass after this one reads
-- precisely what this one could not.
replayMissionRecord :: MissionStore -> MissionId -> MissionReplayCursor -> IO MissionReplay
replayMissionRecord store mission cursor = do
  journalResult <- readMissionJournal store mission cursor.missionJournalConsumed
  snapshotResult <- readMissionSnapshot store mission
  sealsResult <- readMissionSealedArchives store mission
  let (events, journalConsumed, journalFailures) = case journalResult of
        -- The cursor does not move on a failed read, so the next pass reads
        -- exactly what this one could not rather than starting past it.
        Left message -> ([], cursor.missionJournalConsumed, [message])
        Right (lines', consumed) -> (lines', consumed, [])
      (sessions, snapshotFailures) = case snapshotResult of
        MissionPresent snapshot -> (snapshot.missionSnapshotSessions, [])
        -- A mission with no snapshot yet has no session tree, which is not a
        -- failure: its journal is still replayed above.
        MissionAbsent -> ([], [])
        MissionRefused message -> ([], [message])
        MissionUnreadable message -> ([], [message])
      (seals, sealFailures) = case sealsResult of
        Left message -> ([], [message])
        Right entries -> (entries, [])
  read' <- mapM (readPlannedStream store mission cursor) (plannedStreams sessions seals)
  pure
    MissionReplay
      { missionReplayEvents = events,
        missionReplayStreams = [stream | (Just stream, _, _) <- read'],
        missionReplayCursor =
          MissionReplayCursor
            journalConsumed
            -- This pass's offsets over the ones it was given, not instead of
            -- them. A pass that could not read the snapshot plans no streams
            -- at all, and a cursor rebuilt from what it planned would drop
            -- every offset the passes before it earned -- so the read after
            -- the snapshot became readable again would replay each of those
            -- streams from byte zero. 'Map.union' is left-biased, so a stream
            -- this pass did read still supersedes its old entry.
            ( Map.union
                (Map.fromList [advanced | (_, advanced, _) <- read'])
                cursor.missionStreamsConsumed
            ),
        missionReplayFailures =
          journalFailures
            <> snapshotFailures
            <> sealFailures
            <> concat [failures | (_, _, failures) <- read']
      }

-- | One stream this pass intends to read, and the two places its bytes can be.
--
-- Both are carried rather than one being resolved up front, because which
-- applies is a question about the filesystem now: a source recorded in the
-- snapshot may since have been collected, and the seal beside it is what
-- outlives that.
data PlannedStream = PlannedStream
  { plannedStreamId :: MissionStreamId,
    plannedStreamParent :: Maybe MissionSessionId,
    plannedStreamLive :: Maybe FilePath,
    plannedStreamSeal :: Maybe MissionSealedArchive
  }

-- | Every stream one mission's record can offer, from both sides of it.
--
-- The session tree contributes the live sources and the parentage; the sealed
-- archives contribute the streams whose sources are gone, and a seal for a
-- session the snapshot no longer describes still appears — with no parent,
-- which is the honest answer rather than a guessed one.
--
-- Ordered by session and log kind, so two passes over one record report in one
-- order and a caller diffing them is comparing like with like.
plannedStreams :: [MissionSessionNode] -> [MissionSealedArchive] -> [PlannedStream]
plannedStreams sessions seals =
  [ PlannedStream streamId (fromMaybe Nothing (Map.lookup streamId.missionStreamSession parents)) live sealed
    | (streamId, (live, sealed)) <- Map.toAscList located
  ]
  where
    parents = Map.fromList [(node.missionSessionId, node.missionSessionParent) | node <- sessions]

    located =
      Map.unionWith
        (\(live, sealed) (live', sealed') -> (live <|> live', sealed <|> sealed'))
        ( Map.fromList
            [ (MissionStreamId node.missionSessionId reference.missionLogKind, (Just reference.missionLogPath, Nothing))
              | node <- sessions,
                Just reference <- [node.missionSessionLog]
            ]
        )
        ( Map.fromList
            [ (MissionStreamId sealed.missionSealedSession sealed.missionSealedKind, (Nothing, Just sealed))
              | sealed <- seals
            ]
        )

-- | Reads one stream from wherever its bytes are now.
--
-- The live source wins whenever it is still there, because it is the one that
-- may still be growing; the sealed copy is the fallback for a source that has
-- been collected, and it holds the whole source, so the cursor carries straight
-- across the switch. A stream with neither is nothing to read rather than a
-- failure: a session that has recorded no log yet and one whose source went
-- without a seal both leave the cursor where it was, so a source that appears
-- later resumes rather than replays.
readPlannedStream ::
  MissionStore ->
  MissionId ->
  MissionReplayCursor ->
  PlannedStream ->
  IO (Maybe MissionStreamReplay, (MissionStreamId, Int), [Text])
readPlannedStream store mission cursor planned = do
  live <- case planned.plannedStreamLive of
    Nothing -> pure Nothing
    Just path -> do
      -- Occupancy again, for the reason 'resolveMissionRunnerDefinition' gives:
      -- the fallback below is for a source that has been *collected*, and a
      -- source that is still there but cannot be read is not that. Reading it
      -- and reporting the failure is what keeps a replaced or damaged live log
      -- from being silently answered with an archive of some earlier one.
      present <- recordPathOccupied path
      pure (if present then Just path else Nothing)
  case live of
    Just path -> consume (MissionStreamLive path) path
    Nothing -> case planned.plannedStreamSeal of
      Nothing -> pure (Nothing, (streamId, consumed), [])
      Just sealed -> do
        -- Verified before a byte of it is emitted, and before the cursor moves
        -- past one. A seal records the digest and the byte length of what was
        -- copied, and the archive is the only copy left once the source has
        -- been collected: an archive that is missing, truncated, or edited
        -- would otherwise be replayed as this session's durable history, and
        -- a missing one would be replayed as *nothing at all*, since an absent
        -- file is an empty read rather than a failure. Re-read per pass rather
        -- than remembered, because there is nowhere durable to remember it and
        -- the caller decides how often this runs.
        verified <- verifyMissionSealedArchive store mission sealed
        case verified of
          Left message -> pure (Nothing, (streamId, consumed), [message])
          Right () -> do
            resolved <- missionSealedArchivePath store mission sealed
            case resolved of
              Left message -> pure (Nothing, (streamId, consumed), [message])
              Right path -> consume (MissionStreamSealed path) path
  where
    streamId = planned.plannedStreamId
    consumed = Map.findWithDefault 0 streamId cursor.missionStreamsConsumed

    consume source path = do
      result <- readMissionJournalSince path consumed
      pure $ case result of
        Left message -> (Nothing, (streamId, consumed), [message])
        Right (lines', advanced) ->
          ( Just (MissionStreamReplay streamId planned.plannedStreamParent source lines'),
            (streamId, advanced),
            []
          )
