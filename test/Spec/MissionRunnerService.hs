-- | The unattended mission runner, as the dashboard sees it: discovering its
-- installed job, decoding every state its controller publishes, keeping each
-- reason there is no runner distinct from the others, driving a start and a
-- stop through the shared bounded invocation, and replaying a mission's durable
-- events from a cursor.
--
-- Hermetic throughout. Records, status documents and journals are crafted,
-- controllers are shell scripts in a temporary directory, the mission store is
-- resolved under a temporary @$XDG_STATE_HOME@, and nothing here loads a
-- LaunchAgent, reaches a network, or needs a GitHub account.
module Spec.MissionRunnerService (spec) where

import Control.Monad (forM_, void)
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.List (intercalate, nub, sort)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Kanban.Domain (Repository (..))
import Kanban.ManagedPaths (ManagedComponent (MissionRunnerComponent), managedRecordPath)
import Kanban.Mission
  ( MissionArchiveState (..),
    MissionAutonomy (MissionConfirmOnAmbiguity),
    MissionDecisionPolicy (..),
    MissionEvent (..),
    MissionId (..),
    MissionJournalLine (..),
    MissionLeaseAcquisition (..),
    MissionLifecycle (..),
    MissionLogKind (..),
    MissionLogReference (..),
    MissionPause (..),
    MissionPlanStep (..),
    MissionPresentation (..),
    MissionProcessOwnership (..),
    MissionRepository (..),
    MissionSealedArchive (..),
    MissionSelector (..),
    MissionSessionId (..),
    MissionSessionNode (..),
    MissionSnapshot (..),
    MissionSpecification (..),
    MissionStepId (..),
    MissionStore,
    MissionTarget (..),
    MissionTargetKind (..),
    acquireMissionLease,
    createMissionSpecification,
    missionSealedArchivePath,
    openMissionStore,
    recordMissionEvent,
    releaseMissionLease,
    sealMissionLog,
    writeMissionSnapshot,
  )
import Kanban.MissionRunnerService
import Spec.Support.Env
  ( withEnvironmentValue,
    withTemporaryCacheRoot,
    withoutEnvironmentValue,
  )
import Spec.Support.Expect (shouldMention, shouldNotMention)
import Spec.Support.Process (fakeMissionRunnerController)
import System.Directory (createDirectoryIfMissing, createFileLink, doesPathExist, removeFile)
import System.FilePath (takeDirectory, (</>))
import System.Posix.Files (setFileMode)
import Test.Hspec

-- | The two expectations every example here is built from. Spelled locally
-- rather than taken from "Spec.Support.Expect", whose pair is specialised to a
-- @Text@ failure: half the results below refuse with a typed vocabulary
-- instead, and reporting one of those needs its own 'Show'.
expectRight :: Show failure => Either failure value -> IO value
expectRight = either (\failure -> fail ("expected success, got " <> show failure)) pure

expectLeft :: Show value => Either failure value -> IO failure
expectLeft = either pure (\value -> fail ("expected a refusal, got " <> show value))

-- * The board this dashboard is showing

boardRepository :: Repository
boardRepository = Repository "/tmp/example-project" "example" "project"

boardIdentity :: Text
boardIdentity = "example/project"

theMission :: MissionId
theMission = MissionId "mission-0001"

missionRepository :: MissionRepository
missionRepository = MissionRepository "example" "project"

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 9 13) (secondsToDiffTime 42)

-- | Where a launchd host's installer would have written this job's plist, and
-- a systemd host's its unit. Named rather than inlined so a refusal can be
-- asserted to point at them.
installedPlist :: FilePath
installedPlist = "/Users/example/Library/LaunchAgents/com.coghex.mission-runner.example.project.plist"

installedUnit :: FilePath
installedUnit = "/home/example/.config/systemd/user/com.coghex.mission-runner.example.project.service"

-- | The installed controller the definition runs, and the interpreter it runs
-- it on: what @service_definition@ writes, in the order it writes it.
installedInterpreter :: String
installedInterpreter = "/usr/bin/python3"

installedController :: String
installedController = "/home/example/.local/share/kanban/mission-runner/mission_runner_service.py"

-- | The argument vector an installed job's definition carries, with whatever
-- the installer appended after the recorded identity.
installedCommand :: [String] -> [String]
installedCommand extra =
  [installedInterpreter, installedController, "run", "--path", "/Users/example/kanban", "--repo", "example/project"]
    <> extra

-- * Crafted documents

-- | One JSON object, from the fields a test cares to name.
document :: [String] -> String
document fields = "{" <> intercalate "," fields <> "}"

-- | One repository's record entry, keyed under the identity it was installed
-- for.
recordFor :: String -> [String] -> ByteString.ByteString
recordFor identity entry =
  ByteString.pack (document ["\"repositories\":" <> document ["\"" <> identity <> "\":" <> document entry]])

launchdEntry :: [String]
launchdEntry =
  [ "\"backend\":\"launchd\"",
    "\"launchd_label\":\"com.coghex.mission-runner.example.project\"",
    "\"plist_path\":\"" <> installedPlist <> "\"",
    "\"repository\":\"/Users/example/kanban\"",
    "\"install_dir\":\"/Users/example/Library/Application Support/kanban/mission-runner\""
  ]

systemdEntry :: [String]
systemdEntry =
  [ "\"backend\":\"systemd\"",
    "\"systemd_unit\":\"com.coghex.mission-runner.example.project.service\"",
    "\"unit_path\":\"" <> installedUnit <> "\"",
    "\"repository\":\"/home/example/kanban\""
  ]

-- | The three keys every status document this reader accepts has to carry, so
-- a test naming only what it is about still produces an acceptable document.
acceptedStatus :: [String] -> LazyByteString.ByteString
acceptedStatus fields =
  LazyByteString.pack
    ( document
        ( [ "\"schema\":\"kanban-mission-runner-status\"",
            "\"version\":1",
            "\"repository\":\"example/project\""
          ]
            <> fields
        )
    )

-- | One incident document of the shape the controller publishes.
incidentDocument :: [String] -> String
incidentDocument fields =
  document
    ( [ "\"schema\":\"kanban-mission-runner-incident\"",
        "\"version\":1",
        "\"incident_id\":\"incident-20260913T000000Z-4242-error\"",
        "\"kind\":\"mission-pass-failed\"",
        "\"severity\":\"error\"",
        "\"status\":\"open\""
      ]
        <> fields
    )

-- | A systemd unit naming the installed job's command, as the installer writes
-- it.
unitNaming :: [String] -> Text
unitNaming arguments =
  "[Service]\nType=exec\nExecStart=" <> Text.pack (unwords arguments) <> "\n"

spec :: Spec
spec = describe "the mission runner, as the dashboard sees it" $ do
  recordLocationSpec
  recordDecodingSpec
  controllerDiscoverySpec
  statusDecodingSpec
  unavailableVocabularySpec
  transitionSpec
  replaySpec
  advancementAuthoritySpec

-- * Record resolution delegates

recordLocationSpec :: Spec
recordLocationSpec = describe "where the discovery record is" $ do
  -- Asserted by delegation rather than by a second derivation of the probe
  -- order: this module spells no managed location, so what it must be held to
  -- is that it asks 'Kanban.ManagedPaths' and reports that answer. A second
  -- statement of the probe order here would pass even if the two drifted.
  it "is whatever the one Haskell resolution point answers for this component" $
    withTemporaryCacheRoot $ \root ->
      withEnvironmentValue "XDG_DATA_HOME" root $
        withoutEnvironmentValue "KANBAN_MISSION_RUNNER_INSTALL_DIR" $ do
          expected <- managedRecordPath MissionRunnerComponent
          missionRunnerRecordPath `shouldReturn` expected

  it "still delegates when an installation occupies the XDG candidate" $
    withTemporaryCacheRoot $ \root ->
      withEnvironmentValue "XDG_DATA_HOME" root $
        withoutEnvironmentValue "KANBAN_MISSION_RUNNER_INSTALL_DIR" $ do
          let occupied = root </> "kanban" </> "mission-runner" </> "config.json"
          createDirectoryIfMissing True (takeDirectory occupied)
          ByteString.writeFile occupied (recordFor "example/project" launchdEntry)
          expected <- managedRecordPath MissionRunnerComponent
          expected `shouldBe` occupied
          missionRunnerRecordPath `shouldReturn` expected

-- * Record decoding

recordDecodingSpec :: Spec
recordDecodingSpec = describe "decoding the discovery record" $ do
  it "reads a launchd entry" $ do
    record <- expectRight (missionRunnerRecordFromBytes boardIdentity (recordFor "example/project" launchdEntry))
    fmap (.missionRunnerRecordBackend) record `shouldBe` Just MissionRunnerLaunchd
    fmap (.missionRunnerRecordIdentifier) record `shouldBe` Just "com.coghex.mission-runner.example.project"
    fmap (.missionRunnerRecordDefinition) record `shouldBe` Just installedPlist
    fmap (.missionRunnerRecordRepository) record `shouldBe` Just "/Users/example/kanban"

  it "reads a systemd entry" $ do
    record <- expectRight (missionRunnerRecordFromBytes boardIdentity (recordFor "example/project" systemdEntry))
    fmap (.missionRunnerRecordBackend) record `shouldBe` Just MissionRunnerSystemd
    fmap (.missionRunnerRecordDefinition) record `shouldBe` Just installedUnit

  it "selects the entry however either side spells the identity" $ do
    record <- expectRight (missionRunnerRecordFromBytes "Example/Project" (recordFor "example/project" launchdEntry))
    fmap (.missionRunnerRecordBackend) record `shouldBe` Just MissionRunnerLaunchd

  it "reads another repository's entry as no installation rather than as this one's" $
    missionRunnerRecordFromBytes boardIdentity (recordFor "someone/else" launchdEntry)
      `shouldBe` Right Nothing

  it "reports a malformed document as unreadable rather than as absent" $ do
    failure <- expectLeft (missionRunnerRecordFromBytes boardIdentity "{not json")
    failure.missionRunnerRecordFailureCase `shouldBe` MissionRunnerRecordUnreadable

  it "reports a declared schema as its own state, naming what was declared" $ do
    let bytes =
          ByteString.pack
            (document ["\"schema\":\"kanban-mission-runner-record\"", "\"repositories\":" <> document []])
    failure <- expectLeft (missionRunnerRecordFromBytes boardIdentity bytes)
    failure.missionRunnerRecordFailureCase `shouldBe` MissionRunnerRecordSchemaUnknown
    failure.missionRunnerRecordFailureDetail `shouldMention` "kanban-mission-runner-record"

  it "reports a declared version as its own state, naming what was declared" $ do
    let bytes = ByteString.pack (document ["\"version\":2", "\"repositories\":" <> document []])
    failure <- expectLeft (missionRunnerRecordFromBytes boardIdentity bytes)
    failure.missionRunnerRecordFailureCase `shouldBe` MissionRunnerRecordVersionUnknown
    failure.missionRunnerRecordFailureDetail `shouldMention` "2"

  -- The discriminators are read before the payload, so a document a later
  -- release wrote is reported as that even when this release's payload parser
  -- can make nothing of what is beside them.
  it "reports a declared schema or version ahead of a payload it cannot parse" $
    forM_
      [ (document ["\"schema\":\"future\"", "\"repositories\":[]"], MissionRunnerRecordSchemaUnknown),
        (document ["\"version\":2", "\"repositories\":[]"], MissionRunnerRecordVersionUnknown),
        (document ["\"schema\":\"future\"", "\"repositories\":null"], MissionRunnerRecordSchemaUnknown)
      ]
      $ \(body, expected) -> do
        failure <- expectLeft (missionRunnerRecordFromBytes boardIdentity (ByteString.pack body))
        failure.missionRunnerRecordFailureCase `shouldBe` expected

  -- A `repositories` key holding something that is not a table was written by
  -- something, so reading it as "nothing is installed" would send an operator
  -- to install over a record that is already damaged.
  it "reports a repositories key that is not a table as a damaged record" $
    forM_ ["\"repositories\":null", "\"repositories\":[]", "\"repositories\":\"none\""] $ \entry -> do
      failure <- expectLeft (missionRunnerRecordFromBytes boardIdentity (ByteString.pack (document [entry])))
      failure.missionRunnerRecordFailureCase `shouldBe` MissionRunnerRecordUnreadable
      failure.missionRunnerRecordFailureDetail `shouldMention` "repositories"

  it "reads a document that simply holds no entries as no installation" $
    forM_ [document [], document ["\"repositories\":" <> document []]] $ \body ->
      missionRunnerRecordFromBytes boardIdentity (ByteString.pack body) `shouldBe` Right Nothing

  it "reports a document that is not a JSON object at all as a damaged record" $ do
    failure <- expectLeft (missionRunnerRecordFromBytes boardIdentity "[]")
    failure.missionRunnerRecordFailureCase `shouldBe` MissionRunnerRecordUnreadable
    failure.missionRunnerRecordFailureDetail `shouldMention` "not a JSON object"

  it "keeps the three record failures apart from one another and from an absent installation" $ do
    let cases =
          [ ("{not json", MissionRunnerRecordUnreadable),
            (ByteString.pack (document ["\"schema\":\"whatever\""]), MissionRunnerRecordSchemaUnknown),
            (ByteString.pack (document ["\"version\":7"]), MissionRunnerRecordVersionUnknown)
          ]
    reported <- mapM (\(bytes, _) -> (.missionRunnerRecordFailureCase) <$> expectLeft (missionRunnerRecordFromBytes boardIdentity bytes)) cases
    reported `shouldBe` map snd cases
    reported `shouldNotContain` [MissionRunnerJobNotInstalled]

  it "refuses an entry that names no service-manager backend" $ do
    let entry = filter (/= "\"backend\":\"launchd\"") launchdEntry
    failure <- expectLeft (missionRunnerRecordFromBytes boardIdentity (recordFor "example/project" entry))
    failure.missionRunnerRecordFailureCase `shouldBe` MissionRunnerRecordUnreadable
    failure.missionRunnerRecordFailureDetail `shouldMention` "names no service-manager backend"

  it "refuses an entry carrying both managers' keys" $ do
    let entry = launchdEntry <> ["\"unit_path\":\"" <> installedUnit <> "\""]
    failure <- expectLeft (missionRunnerRecordFromBytes boardIdentity (recordFor "example/project" entry))
    failure.missionRunnerRecordFailureDetail `shouldMention` "unit_path"

  it "refuses an entry whose definition path is not absolute" $ do
    let entry = map relative launchdEntry
        relative field
          | field == "\"plist_path\":\"" <> installedPlist <> "\"" = "\"plist_path\":\"LaunchAgents/job.plist\""
          | otherwise = field
    failure <- expectLeft (missionRunnerRecordFromBytes boardIdentity (recordFor "example/project" entry))
    failure.missionRunnerRecordFailureDetail `shouldMention` "not absolute"

-- * Controller discovery

controllerDiscoverySpec :: Spec
controllerDiscoverySpec = describe "discovering the installed job" $ do
  it "discovers a launchd job from the record and the definition beside it" $
    withStagedRecord launchdEntry $ \recordPath plist -> do
      resolved <- expectRight =<< resolveMissionRunnerDefinition (Just MissionRunnerLaunchd) boardIdentity recordPath
      resolved `shouldBe` (MissionRunnerLaunchd, plist)

  it "discovers a systemd job on the same terms" $
    withStagedRecord systemdEntry $ \recordPath unit -> do
      resolved <- expectRight =<< resolveMissionRunnerDefinition (Just MissionRunnerSystemd) boardIdentity recordPath
      resolved `shouldBe` (MissionRunnerSystemd, unit)

  it "reports a host with no supported service manager rather than failing" $
    withStagedRecord launchdEntry $ \recordPath _ -> do
      unavailable <- expectLeft =<< resolveMissionRunnerDefinition Nothing boardIdentity recordPath
      unavailable.missionRunnerUnavailableCase `shouldBe` MissionRunnerHostHasNoManager
      unavailable.missionRunnerUnavailableMessage `shouldMention` "systemctl --user"

  it "reports a definition that is not there, naming the path" $
    withTemporaryCacheRoot $ \root -> do
      let recordPath = root </> "config.json"
      ByteString.writeFile recordPath (recordFor "example/project" launchdEntry)
      unavailable <- expectLeft =<< resolveMissionRunnerDefinition (Just MissionRunnerLaunchd) boardIdentity recordPath
      unavailable.missionRunnerUnavailableCase `shouldBe` MissionRunnerDefinitionUnreadable
      unavailable.missionRunnerUnavailableMessage `shouldMention` Text.pack installedPlist

  -- The record's location is selected *because* something is at it, so a
  -- damaged occupant is the one thing a reader must not take for an absent
  -- installation: reporting "not installed" would send an operator to
  -- reinstall over a path the installer itself refuses to write.
  it "reports a record path occupied by a directory as unreadable, not as no installation" $
    withTemporaryCacheRoot $ \root -> do
      let recordPath = root </> "config.json"
      createDirectoryIfMissing True recordPath
      unavailable <- expectLeft =<< resolveMissionRunnerDefinition (Just MissionRunnerLaunchd) boardIdentity recordPath
      unavailable.missionRunnerUnavailableCase `shouldBe` MissionRunnerRecordUnreadable

  it "reports a record path occupied by a link that follows to nothing the same way" $
    withTemporaryCacheRoot $ \root -> do
      let recordPath = root </> "config.json"
      createFileLink (root </> "nothing-is-here") recordPath
      unavailable <- expectLeft =<< resolveMissionRunnerDefinition (Just MissionRunnerLaunchd) boardIdentity recordPath
      unavailable.missionRunnerUnavailableCase `shouldBe` MissionRunnerRecordUnreadable

  it "reads a record path with nothing at all at it as no installation" $
    withTemporaryCacheRoot $ \root -> do
      unavailable <-
        expectLeft =<< resolveMissionRunnerDefinition (Just MissionRunnerLaunchd) boardIdentity (root </> "absent.json")
      unavailable.missionRunnerUnavailableCase `shouldBe` MissionRunnerJobNotInstalled

  it "hands an occupied but unreadable definition to the reader rather than calling it missing" $
    withTemporaryCacheRoot $ \root -> do
      let recordPath = root </> "config.json"
          definition = root </> "definition"
      createDirectoryIfMissing True definition
      ByteString.writeFile
        recordPath
        (recordFor "example/project" (map (rebindDefinition definition) systemdEntry))
      resolved <- expectRight =<< resolveMissionRunnerDefinition (Just MissionRunnerSystemd) boardIdentity recordPath
      resolved `shouldBe` (MissionRunnerSystemd, definition)

  it "reports a record describing the manager this host does not have" $
    withStagedRecord systemdEntry $ \recordPath _ -> do
      unavailable <- expectLeft =<< resolveMissionRunnerDefinition (Just MissionRunnerLaunchd) boardIdentity recordPath
      unavailable.missionRunnerUnavailableCase `shouldBe` MissionRunnerRecordForeignManager
      unavailable.missionRunnerUnavailableMessage `shouldMention` "systemd"

  it "reads the controller command out of a systemd unit through the one ExecStart reader" $ do
    controller <-
      expectRight
        (systemdMissionRunnerControllerFromUnit boardRepository installedUnit (unitNaming (installedCommand [])))
    controller.missionRunnerControllerExecutable `shouldBe` installedInterpreter
    controller.missionRunnerControllerArguments `shouldBe` [installedController]
    controller.missionRunnerControllerBackend `shouldBe` MissionRunnerSystemd

  it "rebinds the command to this dashboard's own checkout and identity" $ do
    controller <- expectRight (controllerFromMissionRunnerCommand MissionRunnerLaunchd installedPlist boardRepository (installedCommand []))
    controller.missionRunnerControllerRepository `shouldBe` boardRepository.repositoryRoot
    controller.missionRunnerControllerIdentity `shouldBe` boardIdentity
    missionRunnerCommandArguments controller "status"
      `shouldBe` [ installedController,
                   "status",
                   "--path",
                   "/tmp/example-project",
                   "--repo",
                   "example/project",
                   "--json"
                 ]

  it "drops the definition's own subcommand and everything it carries for it" $ do
    controller <-
      expectRight
        (controllerFromMissionRunnerCommand MissionRunnerLaunchd installedPlist boardRepository (installedCommand ["--config", "/etc/kanban.toml"]))
    controller.missionRunnerControllerArguments `shouldBe` [installedController]
    missionRunnerCommandArguments controller "stop" `shouldNotContain` ["--config"]
    missionRunnerCommandArguments controller "stop" `shouldNotContain` ["run"]

  it "drops a binding a hand edit put ahead of the subcommand rather than naming two checkouts" $ do
    controller <-
      expectRight
        ( controllerFromMissionRunnerCommand
            MissionRunnerLaunchd
            installedPlist
            boardRepository
            [installedInterpreter, installedController, "--path", "/somewhere/else", "run", "--repo", "someone/else"]
        )
    controller.missionRunnerControllerArguments `shouldBe` [installedController]
    filter (== "--path") (missionRunnerCommandArguments controller "status") `shouldBe` ["--path"]

  it "refuses a definition that names no run subcommand at all, naming the file and the repair" $ do
    refusal <-
      expectLeft
        (controllerFromMissionRunnerCommand MissionRunnerSystemd installedUnit boardRepository [installedInterpreter, installedController])
    refusal `shouldMention` "ExecStart"
    refusal `shouldMention` Text.pack installedUnit
    refusal `shouldMention` "install_mission_runner.py"

  -- Every way a definition can fail to yield a controller reports the same
  -- state and names the same two things. A refusal that named neither the file
  -- nor the repair would be the one failure an operator could not act on.
  it "names the definition and the repair for a command vector on either backend" $
    forM_
      [ (MissionRunnerLaunchd, installedPlist, [] :: [String]),
        (MissionRunnerLaunchd, installedPlist, [installedInterpreter, installedController]),
        (MissionRunnerSystemd, installedUnit, []),
        (MissionRunnerSystemd, installedUnit, ["run", "--path", "/somewhere"])
      ]
      $ \(backend, definition, arguments) -> do
        refusal <- expectLeft (controllerFromMissionRunnerCommand backend definition boardRepository arguments)
        refusal `shouldMention` Text.pack definition
        refusal `shouldMention` "install_mission_runner.py"

  it "refuses a unit whose ExecStart names nothing at all" $ do
    refusal <- expectLeft (systemdMissionRunnerControllerFromUnit boardRepository installedUnit "[Service]\nType=exec\n")
    refusal `shouldMention` Text.pack installedUnit
    refusal `shouldMention` "install_mission_runner.py"

-- | Stages a discovery record naming a definition that really exists beside
-- it, so a resolution that reaches the definition finds one.
withStagedRecord :: [String] -> (FilePath -> FilePath -> IO result) -> IO result
withStagedRecord entry action = withTemporaryCacheRoot $ \root -> do
  let recordPath = root </> "config.json"
      definition = root </> "definition"
      recorded = map (rebindDefinition definition) entry
  ByteString.writeFile definition "the installed job"
  ByteString.writeFile recordPath (recordFor "example/project" recorded)
  action recordPath definition

-- | The three ways a sealed archive can stop being what its seal recorded: it
-- is gone, it is short, or its bytes changed. Each is something a reader that
-- trusted the seal's name alone would replay as this session's own durable
-- history — the first of them as no history at all.
damagedArchives :: [(String, FilePath -> IO ())]
damagedArchives =
  [ ("a missing archive", removeFile),
    ("a truncated archive", \path -> ByteString.writeFile path "on"),
    ("an edited archive", \path -> ByteString.writeFile path "three\n")
  ]

-- | Re-points a record entry's definition path at one a fixture really made.
rebindDefinition :: FilePath -> String -> String
rebindDefinition definition field
  | field == "\"plist_path\":\"" <> installedPlist <> "\"" = "\"plist_path\":\"" <> definition <> "\""
  | field == "\"unit_path\":\"" <> installedUnit <> "\"" = "\"unit_path\":\"" <> definition <> "\""
  | otherwise = field

-- * Status decoding

statusDecodingSpec :: Spec
statusDecodingSpec = describe "decoding the status document" $ do
  it "gives each published state its own activity" $
    forM_
      [ ("running", MissionRunnerAdvancing),
        ("idle", MissionRunnerIdle),
        ("waiting", MissionRunnerWaiting),
        ("stopped", MissionRunnerStopped),
        ("failed", MissionRunnerFailed)
      ]
      $ \(state, activity) -> do
        observed <- expectRight (decodeMissionRunnerStatus boardIdentity (acceptedStatus ["\"state\":\"" <> state <> "\""]))
        observed.observedMissionRunnerStatus.missionRunnerActivity `shouldBe` activity

  it "treats the three live states as running and the two terminal ones as not" $
    forM_
      [ ("running", True),
        ("idle", True),
        ("waiting", True),
        ("stopped", False),
        ("failed", False)
      ]
      $ \(state, running) -> do
        observed <- expectRight (decodeMissionRunnerStatus boardIdentity (acceptedStatus ["\"state\":\"" <> state <> "\""]))
        missionRunnerIsRunning observed.observedMissionRunnerStatus `shouldBe` running

  it "reports the controller's own message beside the state" $ do
    observed <-
      expectRight
        (decodeMissionRunnerStatus boardIdentity (acceptedStatus ["\"state\":\"idle\"", "\"message\":\"Nothing to advance.\""]))
    observed.observedMissionRunnerStatus.missionRunnerDetail `shouldBe` "Nothing to advance."

  it "is silent about a document another release wrote rather than misreading it" $
    forM_
      [ ( "\"schema\":\"kanban-issue-approval-status\",\"version\":1,\"repository\":\"example/project\",\"state\":\"running\"",
          "schema"
        ),
        ( "\"schema\":\"kanban-mission-runner-status\",\"version\":2,\"repository\":\"example/project\",\"state\":\"running\"",
          "version"
        )
      ]
      $ \(fields, mentioned) -> do
        observed <- expectRight (decodeMissionRunnerStatus boardIdentity (LazyByteString.pack (document [fields])))
        observed.observedMissionRunnerStatus.missionRunnerActivity `shouldBe` MissionRunnerUnknown
        observed.observedMissionRunnerStatus.missionRunnerDetail `shouldMention` mentioned
        observed.observedMissionRunnerIncidents `shouldBe` Nothing

  -- The envelope check is first so that nothing past it is interpreted. A
  -- document this reader may not read is some other runner's, and its
  -- incidents, attention, process identifiers and stamps are that runner's
  -- too — the incident most of all, since it is the field an operator acts on.
  it "carries nothing out of a document it may not read" $
    forM_
      [ "\"schema\":\"kanban-issue-approval-status\",\"version\":1,\"repository\":\"example/project\"",
        "\"schema\":\"kanban-mission-runner-status\",\"version\":2,\"repository\":\"example/project\"",
        "\"schema\":\"kanban-mission-runner-status\",\"version\":1,\"repository\":\"someone/else\""
      ]
      $ \envelope -> do
        let payload =
              [ "\"state\":\"running\"",
                "\"reason\":\"a reason from a document this reader may not read\"",
                "\"runner_pid\":4242",
                "\"pass_pid\":4243",
                "\"passes\":7",
                "\"started_at\":\"2026-09-13T00:00:00Z\"",
                "\"updated_at\":\"2026-09-13T00:00:42Z\"",
                "\"open_incident\":" <> incidentDocument ["\"summary\":\"another runner's incident\""],
                "\"open_incidents\":[" <> incidentDocument [] <> "]",
                "\"attention\":["
                  <> document ["\"mission\":\"mission-9999\"", "\"attention_id\":\"someone/else#mission-9999@2026-09-13T00:00:42Z\""]
                  <> "]"
              ]
        observed <- expectRight (decodeMissionRunnerStatus boardIdentity (LazyByteString.pack (document (envelope : payload))))
        let reported = observed.observedMissionRunnerStatus
        reported.missionRunnerActivity `shouldBe` MissionRunnerUnknown
        observed.observedMissionRunnerIncidents `shouldBe` Nothing
        reported.missionRunnerIncident `shouldBe` Nothing
        reported.missionRunnerAttention `shouldBe` []
        reported.missionRunnerReason `shouldBe` Nothing
        reported.missionRunnerPid `shouldBe` Nothing
        reported.missionRunnerPassPid `shouldBe` Nothing
        reported.missionRunnerPasses `shouldBe` Nothing
        reported.missionRunnerStartedAt `shouldBe` Nothing
        reported.missionRunnerUpdatedAt `shouldBe` Nothing

  it "refuses a document about another repository" $ do
    observed <-
      expectRight
        ( decodeMissionRunnerStatus
            boardIdentity
            ( LazyByteString.pack
                ( document
                    [ "\"schema\":\"kanban-mission-runner-status\"",
                      "\"version\":1",
                      "\"repository\":\"someone/else\"",
                      "\"state\":\"running\""
                    ]
                )
            )
        )
    observed.observedMissionRunnerStatus.missionRunnerActivity `shouldBe` MissionRunnerUnknown
    observed.observedMissionRunnerStatus.missionRunnerDetail `shouldMention` "someone/else"

  it "reports a state it does not recognize as unknown rather than as off" $ do
    observed <- expectRight (decodeMissionRunnerStatus boardIdentity (acceptedStatus ["\"state\":\"reticulating\""]))
    observed.observedMissionRunnerStatus.missionRunnerActivity `shouldBe` MissionRunnerUnknown
    observed.observedMissionRunnerStatus.missionRunnerDetail `shouldMention` "reticulating"

  it "carries the controller's own reason for an unknown it published itself" $ do
    observed <-
      expectRight
        ( decodeMissionRunnerStatus
            boardIdentity
            (acceptedStatus ["\"state\":\"unknown\"", "\"reason\":\"no status document has been written yet\""])
        )
    observed.observedMissionRunnerStatus.missionRunnerActivity `shouldBe` MissionRunnerUnknown
    observed.observedMissionRunnerStatus.missionRunnerDetail `shouldBe` "no status document has been written yet"
    observed.observedMissionRunnerStatus.missionRunnerReason `shouldBe` Just "no status document has been written yet"

  it "decodes the open incidents beside the status" $ do
    let incidents = "\"open_incidents\":[" <> incidentDocument ["\"summary\":\"A mission scheduler pass failed\""] <> "]"
    observed <- expectRight (decodeMissionRunnerStatus boardIdentity (acceptedStatus ["\"state\":\"failed\"", incidents]))
    fmap (map (.missionRunnerIncidentKind)) observed.observedMissionRunnerIncidents `shouldBe` Just ["mission-pass-failed"]
    fmap (.missionRunnerIncidentSummary) observed.observedMissionRunnerStatus.missionRunnerIncident
      `shouldBe` Just (Just "A mission scheduler pass failed")
    fmap (.missionRunnerIncidentSeverity) observed.observedMissionRunnerStatus.missionRunnerIncident
      `shouldBe` Just MissionRunnerErrorSeverity

  it "drops an incident another release wrote rather than decoding it into this shape" $ do
    let foreign' = document ["\"schema\":\"kanban-issue-approval-incident\"", "\"version\":1", "\"incident_id\":\"x\"", "\"kind\":\"y\""]
        stale = document ["\"schema\":\"kanban-mission-runner-incident\"", "\"version\":9", "\"incident_id\":\"x\"", "\"kind\":\"y\""]
        mine = incidentDocument []
        incidents = "\"open_incidents\":[" <> intercalate "," [foreign', stale, mine] <> "]"
    observed <- expectRight (decodeMissionRunnerStatus boardIdentity (acceptedStatus ["\"state\":\"failed\"", incidents]))
    fmap (map (.missionRunnerIncidentKind)) observed.observedMissionRunnerIncidents `shouldBe` Just ["mission-pass-failed"]

  it "decodes the attention the last pass reported" $ do
    let attention =
          "\"attention\":["
            <> document
              [ "\"mission\":\"mission-0001\"",
                "\"attention_id\":\"example/project#mission-0001@2026-09-13T00:00:42Z\"",
                "\"notification\":\"delivered\"",
                "\"detail\":\"the reviewer asked a product question\""
              ]
            <> "]"
    observed <- expectRight (decodeMissionRunnerStatus boardIdentity (acceptedStatus ["\"state\":\"waiting\"", attention]))
    map (.missionRunnerAttentionMission) observed.observedMissionRunnerStatus.missionRunnerAttention
      `shouldBe` ["mission-0001"]
    map (.missionRunnerAttentionNotification) observed.observedMissionRunnerStatus.missionRunnerAttention
      `shouldBe` [Just "delivered"]

  it "reads a wrongly typed schema or version as a document it may not read, not a broken one" $
    forM_
      [ "\"schema\":42,\"version\":1,\"repository\":\"example/project\",\"state\":\"running\"",
        "\"schema\":\"kanban-mission-runner-status\",\"version\":\"one\",\"repository\":\"example/project\",\"state\":\"running\""
      ]
      $ \fields -> do
        observed <- expectRight (decodeMissionRunnerStatus boardIdentity (LazyByteString.pack (document [fields])))
        observed.observedMissionRunnerStatus.missionRunnerActivity `shouldBe` MissionRunnerUnknown
        observed.observedMissionRunnerStatus.missionRunnerDetail `shouldMention` "none"

  it "drops a field it cannot use rather than refusing the document around it" $ do
    observed <-
      expectRight
        ( decodeMissionRunnerStatus
            boardIdentity
            (acceptedStatus ["\"state\":\"idle\"", "\"passes\":\"many\"", "\"pass_pid\":null"])
        )
    observed.observedMissionRunnerStatus.missionRunnerActivity `shouldBe` MissionRunnerIdle
    observed.observedMissionRunnerStatus.missionRunnerPasses `shouldBe` Nothing
    observed.observedMissionRunnerStatus.missionRunnerPassPid `shouldBe` Nothing

  it "drops an attention entry that names nothing rather than the set beside it" $ do
    let attention =
          "\"attention\":["
            <> intercalate
              ","
              [ document ["\"detail\":\"an entry naming no mission at all\""],
                document ["\"mission\":\"mission-0001\"", "\"attention_id\":\"example/project#mission-0001@2026-09-13T00:00:42Z\""]
              ]
            <> "]"
    observed <- expectRight (decodeMissionRunnerStatus boardIdentity (acceptedStatus ["\"state\":\"waiting\"", attention]))
    map (.missionRunnerAttentionMission) observed.observedMissionRunnerStatus.missionRunnerAttention
      `shouldBe` ["mission-0001"]

  it "reports a document that will not parse at all as a decode failure" $ do
    message <- expectLeft (decodeMissionRunnerStatus boardIdentity "{not json")
    message `shouldMention` "could not decode mission runner status"

-- * The unavailable vocabulary

unavailableVocabularySpec :: Spec
unavailableVocabularySpec = describe "why there is no runner to observe" $ do
  -- The enumeration is what stops a ninth case reusing an eighth's message.
  -- 'missionRunnerUnavailableHeadline' is total over the vocabulary, so a case
  -- added without a headline does not compile; this is the other half, and it
  -- is the half a copied headline would slip past.
  it "gives every case in the vocabulary a message of its own" $ do
    let headlines = map missionRunnerUnavailableHeadline missionRunnerUnavailableCases
    length missionRunnerUnavailableCases `shouldSatisfy` (>= 8)
    sort (nub headlines) `shouldBe` sort headlines
    headlines `shouldNotContain` [""]

  it "reports each case from a producer that really reaches it, carrying its own headline" $ do
    reached <- everyUnavailableCase
    map fst reached `shouldBe` missionRunnerUnavailableCases
    forM_ reached $ \(expected, unavailable) -> do
      unavailable.missionRunnerUnavailableCase `shouldBe` expected
      unavailable.missionRunnerUnavailableMessage `shouldMention` missionRunnerUnavailableHeadline expected

  it "keeps the discovered controller only for the case a start can repair" $ do
    reached <- everyUnavailableCase
    [expected | (expected, unavailable) <- reached, Just _ <- [unavailable.missionRunnerUnavailableController]]
      `shouldBe` [MissionRunnerJobStopped]

  -- The one activity that becomes an unavailability. A rule that turned every
  -- non-live activity into "installed and stopped" would report a failed run as
  -- a deliberate stop, which is the reading that tells nobody anything went
  -- wrong — and 'missionRunnerUnavailableStatus' would then hand back
  -- 'MissionRunnerStopped' for it, erasing the failure a second time.
  it "makes an unavailability of a stopped runner and of nothing else" $
    forM_
      [ ("running", Nothing),
        ("idle", Nothing),
        ("waiting", Nothing),
        ("failed", Nothing),
        ("unknown", Nothing),
        ("reticulating", Nothing),
        ("stopped", Just MissionRunnerJobStopped)
      ]
      $ \(state, expected) -> do
        controller <- expectRight (controllerFromMissionRunnerCommand MissionRunnerLaunchd installedPlist boardRepository (installedCommand []))
        observed <- expectRight (decodeMissionRunnerStatus boardIdentity (acceptedStatus ["\"state\":\"" <> state <> "\""]))
        let reported = missionRunnerStoppedJob controller observed.observedMissionRunnerStatus
        fmap (.missionRunnerUnavailableCase) reported `shouldBe` expected
        -- And the activity a status of its own carries survives untouched.
        case reported of
          Nothing -> pure ()
          Just unavailable ->
            (missionRunnerUnavailableStatus unavailable).missionRunnerActivity `shouldBe` MissionRunnerStopped

  it "shows an unsupported host and a stopped job as their own activities, and every other case as unknown" $ do
    reached <- everyUnavailableCase
    [ (expected, (missionRunnerUnavailableStatus unavailable).missionRunnerActivity)
      | (expected, unavailable) <- reached
      ]
      `shouldBe` [ (MissionRunnerHostHasNoManager, MissionRunnerUnsupported),
                   (MissionRunnerJobNotInstalled, MissionRunnerUnknown),
                   (MissionRunnerRecordUnreadable, MissionRunnerUnknown),
                   (MissionRunnerRecordSchemaUnknown, MissionRunnerUnknown),
                   (MissionRunnerRecordVersionUnknown, MissionRunnerUnknown),
                   (MissionRunnerRecordForeignManager, MissionRunnerUnknown),
                   (MissionRunnerDefinitionUnreadable, MissionRunnerUnknown),
                   (MissionRunnerJobStopped, MissionRunnerStopped)
                 ]

-- | One of every unavailable case, each produced by the code path that really
-- reaches it rather than by constructing the value here — so a case this module
-- can no longer produce fails rather than passing on a hand-built witness.
--
-- Ordered as 'missionRunnerUnavailableCases' is, which is what lets the
-- examples above compare the two and catch a case nothing here reaches.
everyUnavailableCase :: IO [(MissionRunnerUnavailableCase, MissionRunnerUnavailable)]
everyUnavailableCase = withTemporaryCacheRoot $ \root -> do
  let recordAt name bytes = do
        let path = root </> name
        ByteString.writeFile path bytes
        pure path
  let absentRecord = root </> "no-record-here.json"
  emptyRecord <- recordAt "empty.json" (ByteString.pack (document ["\"repositories\":" <> document []]))
  malformed <- recordAt "malformed.json" "{not json"
  schemaRecord <- recordAt "schema.json" (ByteString.pack (document ["\"schema\":\"kanban-mission-runner-record\""]))
  versionRecord <- recordAt "version.json" (ByteString.pack (document ["\"version\":2"]))
  systemdRecord <- recordAt "systemd.json" (recordFor "example/project" systemdEntry)
  missingDefinition <- recordAt "missing.json" (recordFor "example/project" launchdEntry)
  hostless <- expectLeft =<< resolveMissionRunnerDefinition Nothing boardIdentity emptyRecord
  noRecord <- expectLeft =<< resolveMissionRunnerDefinition (Just MissionRunnerLaunchd) boardIdentity absentRecord
  noEntry <- expectLeft =<< resolveMissionRunnerDefinition (Just MissionRunnerLaunchd) boardIdentity emptyRecord
  unreadable <- expectLeft =<< resolveMissionRunnerDefinition (Just MissionRunnerLaunchd) boardIdentity malformed
  otherSchema <- expectLeft =<< resolveMissionRunnerDefinition (Just MissionRunnerLaunchd) boardIdentity schemaRecord
  otherVersion <- expectLeft =<< resolveMissionRunnerDefinition (Just MissionRunnerLaunchd) boardIdentity versionRecord
  otherManager <- expectLeft =<< resolveMissionRunnerDefinition (Just MissionRunnerLaunchd) boardIdentity systemdRecord
  noDefinition <- expectLeft =<< resolveMissionRunnerDefinition (Just MissionRunnerLaunchd) boardIdentity missingDefinition
  controller <- expectRight (controllerFromMissionRunnerCommand MissionRunnerLaunchd installedPlist boardRepository (installedCommand []))
  stopped <- expectRight (decodeMissionRunnerStatus boardIdentity (acceptedStatus ["\"state\":\"stopped\""]))
  notRunning <-
    maybe (fail "expected a stopped job to be an unavailability") pure
      (missionRunnerStoppedJob controller stopped.observedMissionRunnerStatus)
  -- Both ways of having no entry report the same case, which is the claim that
  -- an absent record and a record without this repository are one condition.
  noRecord.missionRunnerUnavailableCase `shouldBe` noEntry.missionRunnerUnavailableCase
  pure
    [ (MissionRunnerHostHasNoManager, hostless),
      (MissionRunnerJobNotInstalled, noEntry),
      (MissionRunnerRecordUnreadable, unreadable),
      (MissionRunnerRecordSchemaUnknown, otherSchema),
      (MissionRunnerRecordVersionUnknown, otherVersion),
      (MissionRunnerRecordForeignManager, otherManager),
      (MissionRunnerDefinitionUnreadable, noDefinition),
      (MissionRunnerJobStopped, notRunning)
    ]

-- * Start and stop

transitionSpec :: Spec
transitionSpec = describe "starting and stopping the job" $ do
  it "runs a start and a stop through the controller, each naming its own subcommand" $
    withTemporaryCacheRoot $ \root -> do
      let recorded = root </> "argv"
      controller <-
        fakeMissionRunnerController
          root
          boardRepository
          [ ByteString.pack ("printf '%s\\n' \"$@\" >> " <> recorded),
            ByteString.pack ("printf '%s' '" <> document ["\"schema\":\"kanban-mission-runner-status\"", "\"version\":1", "\"repository\":\"example/project\"", "\"state\":\"idle\""] <> "'")
          ]
      started <- expectRight =<< setMissionRunnerRunning controller True
      started.observedMissionRunnerStatus.missionRunnerActivity `shouldBe` MissionRunnerIdle
      void (expectRight =<< setMissionRunnerRunning controller False)
      void (expectRight =<< queryMissionRunnerStatus controller)
      argv <- lines <$> readFile recorded
      argv `shouldContain` ["start"]
      argv `shouldContain` ["stop"]
      argv `shouldContain` ["status"]
      argv `shouldContain` ["--json"]

  it "promises reconciliation for a transition that produced no exit status, and not for a status read" $
    withTemporaryCacheRoot $ \root -> do
      controller <- fakeMissionRunnerController root boardRepository ["sleep 30"]
      stopFailure <- expectLeft =<< runMissionRunnerCommand 1 controller "stop"
      stopFailure `shouldMention` "the next status poll will reconcile it"
      statusFailure <- expectLeft =<< runMissionRunnerCommand 1 controller "status"
      statusFailure `shouldMention` "timed out after 1 seconds"
      statusFailure `shouldNotMention` "reconcile"

  it "reports a controller that failed and printed no document with its own diagnostics" $
    withTemporaryCacheRoot $ \root -> do
      controller <-
        fakeMissionRunnerController
          root
          boardRepository
          ["echo 'mission_runner_service.py: refusing an unsafe discovery record path' >&2", "exit 1"]
      failure <- expectLeft =<< queryMissionRunnerStatus controller
      failure `shouldMention` "unsafe discovery record path"

-- * Replaying a mission's durable events

replaySpec :: Spec
replaySpec = describe "replaying a mission's durable record" $ do
  it "returns the records appended since the cursor, and the cursor to continue from" $
    withStore $ \_ store -> do
      void (expectRight =<< recordMissionEvent store (event "dispatched"))
      first <- replayMissionRecord store theMission emptyMissionReplayCursor
      eventKinds first.missionReplayEvents `shouldBe` ["dispatched"]
      first.missionReplayFailures `shouldBe` []
      void (expectRight =<< recordMissionEvent store (event "observed"))
      second <- replayMissionRecord store theMission first.missionReplayCursor
      eventKinds second.missionReplayEvents `shouldBe` ["observed"]
      third <- replayMissionRecord store theMission second.missionReplayCursor
      third.missionReplayEvents `shouldBe` []
      third.missionReplayCursor `shouldBe` second.missionReplayCursor

  it "leaves an unterminated trailing record unconsumed and does not advance past it" $
    withStore $ \root store -> do
      void (expectRight =<< recordMissionEvent store (event "dispatched"))
      journal <- pure (missionJournalOf root)
      whole <- ByteString.readFile journal
      ByteString.appendFile journal (ByteString.take 20 whole)
      replayed <- replayMissionRecord store theMission emptyMissionReplayCursor
      eventKinds replayed.missionReplayEvents `shouldBe` ["dispatched"]
      replayed.missionReplayCursor.missionJournalConsumed `shouldBe` ByteString.length whole
      -- And the fragment is read once, whole, when the append that was in
      -- flight completes.
      ByteString.writeFile journal whole
      void (expectRight =<< recordMissionEvent store (event "observed"))
      resumed <- replayMissionRecord store theMission replayed.missionReplayCursor
      eventKinds resumed.missionReplayEvents `shouldBe` ["observed"]

  it "reads an absent journal as nothing yet rather than as a failure" $
    withStore $ \_ store -> do
      replayed <- replayMissionRecord store theMission emptyMissionReplayCursor
      replayed.missionReplayEvents `shouldBe` []
      replayed.missionReplayStreams `shouldBe` []
      replayed.missionReplayFailures `shouldBe` []
      replayed.missionReplayCursor `shouldBe` emptyMissionReplayCursor

  it "reports a malformed journal line without emitting it as an event" $
    withStore $ \root store -> do
      void (expectRight =<< recordMissionEvent store (event "dispatched"))
      ByteString.appendFile (missionJournalOf root) "{\"schemaVersion\":1,\"payload\":{}}\n"
      replayed <- replayMissionRecord store theMission emptyMissionReplayCursor
      eventKinds replayed.missionReplayEvents `shouldBe` ["dispatched"]
      [detail | MissionJournalMalformed detail <- replayed.missionReplayEvents]
        `shouldSatisfy` ((== 1) . length)

  it "skips a line another release wrote while consuming its bytes" $
    withStore $ \root store -> do
      ByteString.appendFile (missionJournalOf root) "{\"schemaVersion\":99,\"payload\":{}}\n"
      void (expectRight =<< recordMissionEvent store (event "dispatched"))
      replayed <- replayMissionRecord store theMission emptyMissionReplayCursor
      -- Absent means absent: the line is neither emitted as an event nor
      -- reported as a broken one, and the record after it is examined exactly
      -- as it would have been.
      eventKinds replayed.missionReplayEvents `shouldBe` ["dispatched"]
      length replayed.missionReplayEvents `shouldBe` 1
      replayed.missionReplayFailures `shouldBe` []

  it "covers the session tree, keeping each session's identity and parentage" $
    withStore $ \root store -> do
      let parentLog = root </> "parent.log"
          childLog = root </> "child.log"
      ByteString.writeFile parentLog "parent one\n"
      ByteString.writeFile childLog "child one\n"
      void
        ( expectRight
            =<< writeMissionSnapshot
              store
              ( snapshotWith
                  [ sessionWith "session-a" Nothing (Just (MissionLogReference parentLog MissionEventStreamLog)),
                    sessionWith "session-b" (Just (MissionSessionId "session-a")) (Just (MissionLogReference childLog MissionEventStreamLog))
                  ]
              )
        )
      replayed <- replayMissionRecord store theMission emptyMissionReplayCursor
      map (.missionStreamReplayId.missionStreamSession) replayed.missionReplayStreams
        `shouldBe` [MissionSessionId "session-a", MissionSessionId "session-b"]
      map (.missionStreamReplayParent) replayed.missionReplayStreams
        `shouldBe` [Nothing, Just (MissionSessionId "session-a")]
      map (.missionStreamReplayLines) replayed.missionReplayStreams
        `shouldBe` [["parent one"], ["child one"]]

  it "advances each stream independently, and replays a session discovered later from its beginning" $
    withStore $ \root store -> do
      let parentLog = root </> "parent.log"
          childLog = root </> "child.log"
      ByteString.writeFile parentLog "parent one\n"
      void
        ( expectRight
            =<< writeMissionSnapshot
              store
              (snapshotWith [sessionWith "session-a" Nothing (Just (MissionLogReference parentLog MissionEventStreamLog))])
        )
      first <- replayMissionRecord store theMission emptyMissionReplayCursor
      map (.missionStreamReplayLines) first.missionReplayStreams `shouldBe` [["parent one"]]
      -- One stream grows; a second session appears beside it.
      ByteString.appendFile parentLog "parent two\n"
      ByteString.writeFile childLog "child one\n"
      void
        ( expectRight
            =<< writeMissionSnapshot
              store
              ( snapshotWith
                  [ sessionWith "session-a" Nothing (Just (MissionLogReference parentLog MissionEventStreamLog)),
                    sessionWith "session-b" (Just (MissionSessionId "session-a")) (Just (MissionLogReference childLog MissionEventStreamLog))
                  ]
              )
        )
      second <- replayMissionRecord store theMission first.missionReplayCursor
      map (.missionStreamReplayLines) second.missionReplayStreams
        `shouldBe` [["parent two"], ["child one"]]
      -- Reopening with the returned cursor duplicates nothing and omits
      -- nothing.
      third <- replayMissionRecord store theMission second.missionReplayCursor
      concatMap (.missionStreamReplayLines) third.missionReplayStreams `shouldBe` []
      third.missionReplayCursor `shouldBe` second.missionReplayCursor

  it "reads a collected session's content out of the mission's own sealed copy" $
    withStore $ \root store -> do
      let sessionLog = root </> "session.log"
      ByteString.writeFile sessionLog "one\ntwo\n"
      void
        ( expectRight
            =<< writeMissionSnapshot
              store
              (snapshotWith [sessionWith "session-a" Nothing (Just (MissionLogReference sessionLog MissionEventStreamLog))])
        )
      first <- replayMissionRecord store theMission emptyMissionReplayCursor
      map (.missionStreamReplayLines) first.missionReplayStreams `shouldBe` [["one", "two"]]
      map (.missionStreamReplaySource) first.missionReplayStreams `shouldBe` [MissionStreamLive sessionLog]
      -- The source grows, is sealed, and is then collected.
      ByteString.appendFile sessionLog "three\n"
      sealed <- expectRight =<< sealMissionLog store theMission (MissionSessionId "session-a") MissionEventStreamLog sessionLog
      sealed.missionSealedSession `shouldBe` MissionSessionId "session-a"
      removeFile sessionLog
      second <- replayMissionRecord store theMission first.missionReplayCursor
      map (.missionStreamReplayLines) second.missionReplayStreams `shouldBe` [["three"]]
      map (.missionStreamReplayId.missionStreamSession) second.missionReplayStreams
        `shouldBe` [MissionSessionId "session-a"]
      map (.missionStreamReplayParent) second.missionReplayStreams `shouldBe` [Nothing]
      [source | MissionStreamSealed source <- map (.missionStreamReplaySource) second.missionReplayStreams]
        `shouldSatisfy` ((== 1) . length)

  -- A pass that cannot read the snapshot plans no streams at all. A cursor
  -- rebuilt from what this pass planned would therefore throw away every
  -- offset the passes before it earned, and the read after the snapshot came
  -- back would replay the whole of each stream a second time.
  it "keeps the offsets of streams a failed snapshot read left it unable to plan" $
    withStore $ \root store -> do
      let sessionLog = root </> "session.log"
      ByteString.writeFile sessionLog "one\n"
      void
        ( expectRight
            =<< writeMissionSnapshot
              store
              (snapshotWith [sessionWith "session-a" Nothing (Just (MissionLogReference sessionLog MissionEventStreamLog))])
        )
      first <- replayMissionRecord store theMission emptyMissionReplayCursor
      map (.missionStreamReplayLines) first.missionReplayStreams `shouldBe` [["one"]]
      -- The snapshot becomes unreadable, and the log grows while it is.
      ByteString.writeFile (missionSnapshotOf root) "{not a snapshot"
      ByteString.appendFile sessionLog "two\n"
      blind <- replayMissionRecord store theMission first.missionReplayCursor
      blind.missionReplayStreams `shouldBe` []
      blind.missionReplayFailures `shouldSatisfy` (not . null)
      blind.missionReplayCursor.missionStreamsConsumed
        `shouldBe` first.missionReplayCursor.missionStreamsConsumed
      -- And when it comes back, only what was appended since is replayed.
      void
        ( expectRight
            =<< writeMissionSnapshot
              store
              (snapshotWith [sessionWith "session-a" Nothing (Just (MissionLogReference sessionLog MissionEventStreamLog))])
        )
      resumed <- replayMissionRecord store theMission blind.missionReplayCursor
      map (.missionStreamReplayLines) resumed.missionReplayStreams `shouldBe` [["two"]]

  -- The archive is the only copy left once the source is collected, so it is
  -- exactly the thing a reader must not believe on the strength of its name.
  it "refuses a sealed archive that is not what its seal recorded" $
    forM_ (damagedArchives :: [(String, FilePath -> IO ())]) $ \(_shape, damage) ->
        withStore $ \root store -> do
          let sessionLog = root </> "session.log"
          ByteString.writeFile sessionLog "one\n"
          void
            ( expectRight
                =<< writeMissionSnapshot
                  store
                  (snapshotWith [sessionWith "session-a" Nothing (Just (MissionLogReference sessionLog MissionEventStreamLog))])
            )
          sealed <- expectRight =<< sealMissionLog store theMission (MissionSessionId "session-a") MissionEventStreamLog sessionLog
          removeFile sessionLog
          archive <- expectRight =<< missionSealedArchivePath store theMission sealed
          damage archive
          replayed <- replayMissionRecord store theMission emptyMissionReplayCursor
          replayed.missionReplayStreams `shouldBe` []
          replayed.missionReplayFailures `shouldSatisfy` (not . null)
          -- And the cursor is exactly where it was, so a repaired archive is
          -- replayed whole rather than from wherever a believed read left off.
          Map.lookup
            (MissionStreamId (MissionSessionId "session-a") MissionEventStreamLog)
            replayed.missionReplayCursor.missionStreamsConsumed
            `shouldBe` Just 0

  -- A link that follows to nothing is occupied, so it is not a collected
  -- source. A reader that let the read decide would map its ENOENT to an empty
  -- stream and report neither the damage nor the archive beside it, pass after
  -- pass.
  it "reports a live source that is there and will not open, rather than reading it as empty" $
    withStore $ \root store -> do
      let sessionLog = root </> "session.log"
      createFileLink (root </> "nothing-is-here") sessionLog
      void
        ( expectRight
            =<< writeMissionSnapshot
              store
              (snapshotWith [sessionWith "session-a" Nothing (Just (MissionLogReference sessionLog MissionEventStreamLog))])
        )
      replayed <- replayMissionRecord store theMission emptyMissionReplayCursor
      replayed.missionReplayStreams `shouldBe` []
      replayed.missionReplayFailures `shouldSatisfy` (not . null)
      Text.concat replayed.missionReplayFailures `shouldMention` Text.pack sessionLog
      Map.lookup (MissionStreamId (MissionSessionId "session-a") MissionEventStreamLog) replayed.missionReplayCursor.missionStreamsConsumed
        `shouldBe` Just 0

  it "says which sealed copy it did not read in a damaged live source's place" $
    withStore $ \root store -> do
      let sessionLog = root </> "session.log"
      ByteString.writeFile sessionLog "one\n"
      void
        ( expectRight
            =<< writeMissionSnapshot
              store
              (snapshotWith [sessionWith "session-a" Nothing (Just (MissionLogReference sessionLog MissionEventStreamLog))])
        )
      void (expectRight =<< sealMissionLog store theMission (MissionSessionId "session-a") MissionEventStreamLog sessionLog)
      -- The source is replaced by a link to nothing: still occupied, so still
      -- not the collected source the archive stands in for.
      removeFile sessionLog
      createFileLink (root </> "nothing-is-here") sessionLog
      replayed <- replayMissionRecord store theMission emptyMissionReplayCursor
      replayed.missionReplayStreams `shouldBe` []
      Text.concat replayed.missionReplayFailures `shouldMention` "sealed copy"
      Map.lookup (MissionStreamId (MissionSessionId "session-a") MissionEventStreamLog) replayed.missionReplayCursor.missionStreamsConsumed
        `shouldBe` Just 0

  -- One damaged index entry must not make every other collected session's
  -- archive unreadable. The store's strict reader is the collector's, because
  -- a collector is about to delete sources; a reader deletes nothing.
  it "replays the collected sessions whose seals read, beside the one whose seal did not" $
    withStore $ \root store -> do
      let sessionLog session = root </> (session <> ".log")
          sessions = ["session-a", "session-b"]
      forM_ sessions $ \session -> ByteString.writeFile (sessionLog session) (ByteString.pack (session <> " one\n"))
      void
        ( expectRight
            =<< writeMissionSnapshot
              store
              ( snapshotWith
                  [ sessionWith (Text.pack session) Nothing (Just (MissionLogReference (sessionLog session) MissionEventStreamLog))
                    | session <- sessions
                  ]
              )
        )
      forM_ sessions $ \session -> do
        void (expectRight =<< sealMissionLog store theMission (MissionSessionId (Text.pack session)) MissionEventStreamLog (sessionLog session))
        removeFile (sessionLog session)
      -- One session's seal record is damaged; the other's archive is intact.
      ByteString.writeFile
        (missionDirectoryOf root </> "archive" </> "session-b-event_stream.seal.json")
        "{not a seal record"
      replayed <- replayMissionRecord store theMission emptyMissionReplayCursor
      map (.missionStreamReplayId.missionStreamSession) replayed.missionReplayStreams
        `shouldBe` [MissionSessionId "session-a"]
      map (.missionStreamReplayLines) replayed.missionReplayStreams `shouldBe` [["session-a one"]]
      replayed.missionReplayFailures `shouldSatisfy` (not . null)
      -- And only the session that replayed advanced.
      Map.toAscList replayed.missionReplayCursor.missionStreamsConsumed
        `shouldBe` [ (MissionStreamId (MissionSessionId "session-a") MissionEventStreamLog, length ("session-a one\n" :: String)),
                     (MissionStreamId (MissionSessionId "session-b") MissionEventStreamLog, 0)
                   ]

  -- An archive directory that cannot be listed is not an empty archive. Read
  -- as one, every collected session's history disappears and nothing says so.
  it "reports an archive directory it could not list rather than reading it as empty" $
    withStore $ \root store -> do
      let sessionLog = root </> "session.log"
      ByteString.writeFile sessionLog "one\n"
      void
        ( expectRight
            =<< writeMissionSnapshot
              store
              (snapshotWith [sessionWith "session-a" Nothing (Just (MissionLogReference sessionLog MissionEventStreamLog))])
        )
      -- The source is collected, so an archive is the only place its history
      -- could come from — and something is occupying the archive's own path.
      removeFile sessionLog
      ByteString.writeFile (missionDirectoryOf root </> "archive") "not a directory"
      replayed <- replayMissionRecord store theMission emptyMissionReplayCursor
      replayed.missionReplayStreams `shouldBe` []
      Text.concat replayed.missionReplayFailures `shouldMention` "archive"

  -- A seal the archive still advertises and nothing can read is a damaged
  -- entry, not the silence §16 grants a record another release wrote. The two
  -- arrive as one value, so they are told apart by whether the bytes are there.
  it "reports a seal entry whose bytes are not there, beside the one that reads" $
    withStore $ \root store -> do
      let sessionLog session = root </> (session <> ".log")
          sessions = ["session-a", "session-b"]
      forM_ sessions $ \session -> ByteString.writeFile (sessionLog session) (ByteString.pack (session <> " one\n"))
      void
        ( expectRight
            =<< writeMissionSnapshot
              store
              ( snapshotWith
                  [ sessionWith (Text.pack session) Nothing (Just (MissionLogReference (sessionLog session) MissionEventStreamLog))
                    | session <- sessions
                  ]
              )
        )
      forM_ sessions $ \session -> do
        void (expectRight =<< sealMissionLog store theMission (MissionSessionId (Text.pack session)) MissionEventStreamLog (sessionLog session))
        removeFile (sessionLog session)
      let danglingSeal = missionDirectoryOf root </> "archive" </> "session-b-event_stream.seal.json"
      removeFile danglingSeal
      createFileLink (root </> "nothing-is-here") danglingSeal
      replayed <- replayMissionRecord store theMission emptyMissionReplayCursor
      map (.missionStreamReplayId.missionStreamSession) replayed.missionReplayStreams
        `shouldBe` [MissionSessionId "session-a"]
      Text.concat replayed.missionReplayFailures `shouldMention` "session-b-event_stream.seal.json"
      Map.toAscList replayed.missionReplayCursor.missionStreamsConsumed
        `shouldBe` [ (MissionStreamId (MissionSessionId "session-a") MissionEventStreamLog, length ("session-a one\n" :: String)),
                     (MissionStreamId (MissionSessionId "session-b") MissionEventStreamLog, 0)
                   ]

  it "reports one unreadable stream without hiding what the others appended, and keeps its cursor" $
    withStore $ \root store -> do
      let readable = root </> "readable.log"
          unreadable = root </> "unreadable.log"
      ByteString.writeFile readable "one\n"
      ByteString.writeFile unreadable "two\n"
      setFileMode unreadable 0o000
      void
        ( expectRight
            =<< writeMissionSnapshot
              store
              ( snapshotWith
                  [ sessionWith "session-a" Nothing (Just (MissionLogReference readable MissionEventStreamLog)),
                    sessionWith "session-b" Nothing (Just (MissionLogReference unreadable MissionEventStreamLog))
                  ]
              )
        )
      replayed <- replayMissionRecord store theMission emptyMissionReplayCursor
      concatMap (.missionStreamReplayLines) replayed.missionReplayStreams `shouldBe` ["one"]
      replayed.missionReplayFailures `shouldSatisfy` (not . null)
      Map.lookup (MissionStreamId (MissionSessionId "session-b") MissionEventStreamLog) replayed.missionReplayCursor.missionStreamsConsumed
        `shouldBe` Just 0

-- * No advancement authority

advancementAuthoritySpec :: Spec
advancementAuthoritySpec = describe "what observing the runner is allowed to take" $ do
  it "takes no mission lease, so none is left behind and none is ever created" $
    withStore $ \root store -> do
      controller <- fakeMissionRunnerController root boardRepository ["printf '%s' '{}'"]
      void (recordMissionEvent store (event "dispatched"))
      void (replayMissionRecord store theMission emptyMissionReplayCursor)
      void (queryMissionRunnerStatus controller)
      void (setMissionRunnerRunning controller True)
      void (setMissionRunnerRunning controller False)
      doesPathExist (missionLeaseOf root) `shouldReturn` False
      acquired <- acquireMissionLease store theMission
      case acquired of
        MissionLeaseAcquired lease -> releaseMissionLease lease
        other -> expectationFailure ("expected the lease to be free, got " <> show other)

  -- The stronger half of the claim, and the one a "nobody holds it afterwards"
  -- assertion cannot make: an observer that *attempted* acquisition while
  -- somebody else held the lease would be refused, and the refusal would show
  -- up as a failed observation. Every operation below is performed with the
  -- lease held by another acquirer, and every one of them still answers.
  it "answers while another acquirer holds the lease, because it never asks for it" $
    withStore $ \root store -> do
      controller <- fakeMissionRunnerController root boardRepository ["printf '%s' '" <> ByteString.pack (document ["\"schema\":\"kanban-mission-runner-status\"", "\"version\":1", "\"repository\":\"example/project\"", "\"state\":\"idle\""]) <> "'"]
      void (expectRight =<< recordMissionEvent store (event "dispatched"))
      held <- acquireMissionLease store theMission
      case held of
        MissionLeaseAcquired lease -> do
          replayed <- replayMissionRecord store theMission emptyMissionReplayCursor
          eventKinds replayed.missionReplayEvents `shouldBe` ["dispatched"]
          replayed.missionReplayFailures `shouldBe` []
          observed <- expectRight =<< queryMissionRunnerStatus controller
          observed.observedMissionRunnerStatus.missionRunnerActivity `shouldBe` MissionRunnerIdle
          void (expectRight =<< setMissionRunnerRunning controller True)
          void (expectRight =<< setMissionRunnerRunning controller False)
          -- The lease is still the one that was taken: nothing above replaced
          -- it, retired it, or waited on it.
          contended <- acquireMissionLease store theMission
          case contended of
            MissionLeaseHeld _ -> pure ()
            other -> expectationFailure ("expected the lease to still be held, got " <> show other)
          releaseMissionLease lease
        other -> expectationFailure ("expected to take the lease, got " <> show other)

-- * Mission-store fixtures

-- | Runs @action@ against a store resolved the way a real run resolves one,
-- under a temporary state root nothing else can see.
withStore :: (FilePath -> MissionStore -> IO result) -> IO result
withStore action = withTemporaryCacheRoot $ \root ->
  withEnvironmentValue "XDG_STATE_HOME" (root </> "state") $ do
    opened <- openMissionStore boardRepository
    case opened of
      Left message -> fail ("could not open the mission store: " <> Text.unpack message)
      Right store -> do
        created <- createMissionSpecification store specification
        case created of
          Left message -> fail ("could not create the mission: " <> Text.unpack message)
          Right _ -> action root store

-- | Where the fixtures above stage bytes this release's writers would not:
-- the journal's own path, and the lease directory whose absence is the proof
-- that nothing here acquired one.
missionDirectoryOf :: FilePath -> FilePath
missionDirectoryOf root =
  root </> "state" </> "kanban" </> "missions" </> "repositories" </> "example" </> "project" </> "mission-0001"

missionJournalOf :: FilePath -> FilePath
missionJournalOf root = missionDirectoryOf root </> "events.jsonl"

missionSnapshotOf :: FilePath -> FilePath
missionSnapshotOf root = missionDirectoryOf root </> "snapshot.json"

missionLeaseOf :: FilePath -> FilePath
missionLeaseOf root = missionDirectoryOf root </> "lease"

specification :: MissionSpecification
specification =
  MissionSpecification
    { missionSpecificationId = theMission,
      missionSpecificationRepository = missionRepository,
      missionSpecificationRequest = "take #668 to a pull request",
      missionSpecificationSelector =
        MissionSelector
          { missionSelectorKind = "issues",
            missionSelectorQuery = Just "label:reviewed:approve",
            missionSelectorTargets =
              [MissionTarget {missionTargetKind = MissionTargetIssue, missionTargetNumber = 668, missionTargetTitle = Just "the dashboard reader"}]
          },
      missionSpecificationPolicy =
        MissionDecisionPolicy
          { missionDecisionAutonomy = MissionConfirmOnAmbiguity,
            missionDecisionMaxReviewRounds = 5,
            missionDecisionStopOnFailure = True
          },
      missionSpecificationCreatedAt = fixedTime,
      missionSpecificationPlan =
        [ MissionPlanStep
            { missionPlanStepId = MissionStepId "solve-668",
              missionPlanStepAction = "solve",
              missionPlanStepSummary = "take #668 to a pull request",
              missionPlanStepTarget = Nothing,
              missionPlanStepDependsOn = []
            }
        ]
    }

snapshotWith :: [MissionSessionNode] -> MissionSnapshot
snapshotWith sessions =
  MissionSnapshot
    { missionSnapshotId = theMission,
      missionSnapshotRepository = missionRepository,
      missionSnapshotLifecycle = MissionRunning,
      missionSnapshotCurrentStep = Just (MissionStepId "solve-668"),
      missionSnapshotNextSteps = [],
      missionSnapshotSteps = [],
      missionSnapshotPause = MissionPause {missionPauseRequested = False, missionPauseReason = Nothing, missionPauseAt = Nothing},
      missionSnapshotAttention = Nothing,
      missionSnapshotPlannerSummary = Nothing,
      missionSnapshotRetries = [],
      missionSnapshotLastReconciliation = Nothing,
      missionSnapshotSessions = sessions,
      missionSnapshotArchive =
        MissionArchiveState
          { missionArchivePresentation = MissionPresentationActive,
            missionArchiveWorktrees = [],
            missionArchiveLastAccessedAt = Nothing
          },
      missionSnapshotUpdatedAt = fixedTime
    }

sessionWith :: Text -> Maybe MissionSessionId -> Maybe MissionLogReference -> MissionSessionNode
sessionWith identity parent reference =
  MissionSessionNode
    { missionSessionId = MissionSessionId identity,
      missionSessionMission = theMission,
      missionSessionParent = parent,
      missionSessionStep = Just (MissionStepId "solve-668"),
      missionSessionProvider = "claude",
      missionSessionProviderSessionId = Just ("provider-" <> identity),
      missionSessionOwnership = MissionProcessOwnership {missionProcessIdentity = Nothing, missionProcessGroup = Nothing},
      missionSessionLog = reference,
      missionSessionObservation = Nothing
    }

event :: Text -> MissionEvent
event kind =
  MissionEvent
    { missionEventAt = fixedTime,
      missionEventMission = theMission,
      missionEventRepository = missionRepository,
      missionEventStep = Just (MissionStepId "solve-668"),
      missionEventSession = Nothing,
      missionEventKind = kind,
      missionEventDetail = Nothing
    }

-- | The kinds of the lines that really were events. A malformed or foreign
-- line is reported as itself rather than as an event, so it is deliberately
-- not in this list — and the examples that care assert its presence
-- separately.
eventKinds :: [MissionJournalLine] -> [Text]
eventKinds lines' = [recorded.missionEventKind | MissionJournalEvent recorded <- lines']
