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
import System.Directory (createDirectoryIfMissing, doesPathExist, removeFile)
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
    controller <- expectRight (controllerFromMissionRunnerCommand MissionRunnerLaunchd boardRepository (installedCommand []))
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
        (controllerFromMissionRunnerCommand MissionRunnerLaunchd boardRepository (installedCommand ["--config", "/etc/kanban.toml"]))
    controller.missionRunnerControllerArguments `shouldBe` [installedController]
    missionRunnerCommandArguments controller "stop" `shouldNotContain` ["--config"]
    missionRunnerCommandArguments controller "stop" `shouldNotContain` ["run"]

  it "drops a binding a hand edit put ahead of the subcommand rather than naming two checkouts" $ do
    controller <-
      expectRight
        ( controllerFromMissionRunnerCommand
            MissionRunnerLaunchd
            boardRepository
            [installedInterpreter, installedController, "--path", "/somewhere/else", "run", "--repo", "someone/else"]
        )
    controller.missionRunnerControllerArguments `shouldBe` [installedController]
    filter (== "--path") (missionRunnerCommandArguments controller "status") `shouldBe` ["--path"]

  it "refuses a definition that names no run subcommand at all" $ do
    refusal <-
      expectLeft
        (controllerFromMissionRunnerCommand MissionRunnerSystemd boardRepository [installedInterpreter, installedController])
    refusal `shouldMention` "ExecStart"

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
      recorded = map (rebind definition) entry
  ByteString.writeFile definition "the installed job"
  ByteString.writeFile recordPath (recordFor "example/project" recorded)
  action recordPath definition
  where
    rebind definition field
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
  controller <- expectRight (controllerFromMissionRunnerCommand MissionRunnerLaunchd boardRepository (installedCommand []))
  stopped <- expectRight (decodeMissionRunnerStatus boardIdentity (acceptedStatus ["\"state\":\"stopped\""]))
  notRunning <- expectLeft (missionRunnerAvailability controller stopped.observedMissionRunnerStatus)
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
