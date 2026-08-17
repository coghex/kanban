-- | The persistent issue approval service, as the dashboard sees it:
-- discovering its installed job, decoding every state its controller
-- publishes, refusing an observation that is not about this repository,
-- deciding what a toggle does, settling a transition race, and asking for the
-- board refresh a result requires.
--
-- Hermetic throughout. Records and status documents are crafted, controllers
-- are shell scripts in a temporary directory, and nothing here loads a
-- LaunchAgent, reaches a network, or needs a GitHub account.
module Spec.ApprovalService (spec) where

import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (intercalate)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.ApprovalService
import qualified Data.Map.Strict as Map
import Kanban.Domain
import Kanban.Drainer
  ( DrainerActivity (..),
    DrainerBackend (..),
    DrainerController (..),
    DrainerState (..),
    DrainerStatus (..),
  )
import Kanban.Process (identityForPid, readProcessSnapshot)
import Kanban.Review (ReviewStage (..))
import Kanban.UI.Approval
  ( ApprovalHandoff (..),
    approvalObservationApplied,
    approvalStatusApplied,
    approvalToggleApplied,
    approvalTogglePress,
  )
import Kanban.UI.PullRequest (drainerTogglePress)
import Kanban.UI.Review (approvalServiceRefusal, canonicalLaunchOutcome)
import Kanban.UI.Types (AppState (..))
import Spec.Support.App (testAppState)
import Spec.Support.Env (withTemporaryCacheRoot)
import Spec.Support.Expect (requireLeft, requireRight, shouldMention, shouldNotMention)
import Spec.Support.Process (fakeApprovalController, readRecordedPid)
import Spec.Support.Env (withEnvironmentValue)
import System.Directory (createDirectory)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import Test.Hspec

-- * Crafted runtime documents

boardRepository :: Repository
boardRepository = Repository "/tmp/example-project" "example" "project"

boardIdentity :: Text
boardIdentity = "example/project"

-- | One status document, from the fields a test cares to name.
document :: [String] -> LazyByteString.ByteString
document fields = LazyByteString.pack ("{" <> intercalate "," fields <> "}")

-- | The three keys every document this reader accepts has to carry, so a test
-- about a state is not also a test about containment.
addressed :: String -> [String] -> LazyByteString.ByteString
addressed state extra =
  document
    ( [ "\"schema\":\"kanban-issue-approval-status\"",
        "\"version\":1",
        "\"repository\":\"example/project\"",
        "\"state\":\"" <> state <> "\""
      ]
        <> extra
    )

barrierIncidentField :: Int -> String
barrierIncidentField issue =
  "\"open_incident\":{\"incident_id\":\"incident-1\",\"kind\":\"issue-changes-requested\""
    <> ",\"severity\":\"warning\",\"issue\":"
    <> show issue
    <> ",\"summary\":\"Issue #"
    <> show issue
    <> " requests changes\"}"

decoded :: LazyByteString.ByteString -> Either Text ApprovalObservation
decoded = decodeApprovalStatus boardIdentity

decodedStatus :: LazyByteString.ByteString -> Either Text ApprovalStatus
decodedStatus = fmap (.observedApprovalStatus) . decoded

-- * Records

launchdEntry :: String -> String -> String
launchdEntry label plist =
  "{\"backend\":\"launchd\",\"launchd_label\":\""
    <> label
    <> "\",\"plist_path\":\""
    <> plist
    <> "\",\"repository\":\"/tmp/example-project\"}"

recordDocument :: [(String, String)] -> ByteString.ByteString
recordDocument entries =
  ByteString.pack
    ( "{\"repositories\":{"
        <> intercalate "," ["\"" <> identity <> "\":" <> entry | (identity, entry) <- entries]
        <> "}}"
    )

-- * Application state

-- | A dashboard whose approval service reports @status@, with a controller
-- installed so the toggle has something to hand off to. The path is never
-- executed: every toggle test reads the handoff rather than running it.
withApproval :: ApprovalStatus -> AppState -> AppState
withApproval status state =
  state
    { appApprovalStatus = status,
      appApprovalController =
        Right (ApprovalController "/nonexistent/kanban-test-approval" [] ApprovalLaunchd)
    }

dashboardShowing :: ApprovalStatus -> IO AppState
dashboardShowing status = withApproval status <$> testAppState (Board Map.empty)

-- | The dashboard, having observed this status with or without a live backend
-- pass under it. The interlock reads that pass rather than the status alone, so
-- a fixture about it has to say which.
observing :: ApprovalStatus -> Bool -> IO AppState
observing status passRunning = do
  state <- dashboardShowing status
  pure
    state
      { appApprovalResult =
          Just (ApprovalResult status.approvalActivity (Just ApprovalOutcomeIdle) passRunning (Just "t1"))
      }

-- | Runs @action@ with a fake @systemctl@ first on @PATH@.
withFakeSystemctl :: [ByteString.ByteString] -> IO result -> IO result
withFakeSystemctl scriptLines action =
  withTemporaryCacheRoot $ \temporaryRoot -> do
    let binaryRoot = temporaryRoot </> "bin"
        fake = binaryRoot </> "systemctl"
    createDirectory binaryRoot
    ByteString.writeFile fake (ByteString.unlines ("#!/bin/sh" : scriptLines))
    setFileMode fake 0o700
    originalPath <- maybe "" id <$> lookupEnv "PATH"
    withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) action

runningStatus :: ApprovalStatus
runningStatus = ApprovalStatus ApprovalOn "on" ApprovalServiceRunning Nothing Nothing

stoppedStatus :: ApprovalStatus
stoppedStatus = ApprovalStatus ApprovalOff "off" ApprovalServiceStopped Nothing Nothing

barrierStatus :: ApprovalStatus
barrierStatus =
  ApprovalStatus
    ApprovalWarning
    "on · unresolved incident · Issue #254 requests changes"
    ApprovalServiceBarrier
    (Just 254)
    Nothing

-- | An observation carrying a chosen result identity, for the refresh
-- decisions that are about the identity rather than about the status.
observationWith :: ApprovalStatus -> ApprovalResult -> ApprovalObservation
observationWith status identity = ApprovalObservation status (Just []) identity

-- | One result identity, as the controller's own document would carry it: the
-- state, what the last pass decided, whether a pass is running under it, and
-- the document's stamp.
resultIdentity :: ApprovalActivity -> Maybe ApprovalOutcome -> Bool -> Text -> ApprovalResult
resultIdentity activity outcome passRunning stamp = ApprovalResult activity outcome passRunning (Just stamp)

spec :: Spec
spec = do
  describe "issue approval service discovery" $ do
    it "reads the backend, identifier, definition path, and checkout the installer recorded" $
      approvalRecordFromBytes
        boardIdentity
        (recordDocument [("example/project", launchdEntry "com.coghex.issue-approval.example.project" "/Users/example/Library/LaunchAgents/a.plist")])
        `shouldBe` Right
          ( Just
              ( ApprovalRecord
                  ApprovalLaunchd
                  "com.coghex.issue-approval.example.project"
                  "/Users/example/Library/LaunchAgents/a.plist"
                  "/tmp/example-project"
              )
          )

    it "reads a systemd entry as its own backend, unit, and unit path" $
      approvalRecordFromBytes
        boardIdentity
        ( recordDocument
            [ ( "example/project",
                "{\"backend\":\"systemd\",\"systemd_unit\":\"kanban-issue-approval.service\"\
                \,\"unit_path\":\"/home/example/.config/systemd/user/kanban-issue-approval.service\"\
                \,\"repository\":\"/tmp/example-project\"}"
              )
            ]
        )
        `shouldBe` Right
          ( Just
              ( ApprovalRecord
                  ApprovalSystemd
                  "kanban-issue-approval.service"
                  "/home/example/.config/systemd/user/kanban-issue-approval.service"
                  "/tmp/example-project"
              )
          )

    it "fails closed on an entry that names no backend, an unknown one, or two" $ do
      -- Unlike the drainer's record there is no compatibility case to keep
      -- working: this installer has written the discriminator since its first
      -- release, so an entry without one was not written by it.
      let refusal entry =
            either id (const "unexpectedly resolved") (approvalRecordFromBytes boardIdentity (recordDocument [("example/project", entry)]))
      refusal "{\"launchd_label\":\"a\",\"plist_path\":\"/a.plist\",\"repository\":\"/tmp/example-project\"}"
        `shouldMention` "names no service-manager backend"
      refusal "{\"backend\":null,\"launchd_label\":\"a\",\"plist_path\":\"/a.plist\",\"repository\":\"/tmp/example-project\"}"
        `shouldMention` "backend field is null"
      refusal "{\"backend\":\"upstart\",\"repository\":\"/tmp/example-project\"}"
        `shouldMention` "unknown service-manager backend"
      refusal "{\"backend\":\"launchd\",\"launchd_label\":\"a\",\"plist_path\":\"/a.plist\",\"unit_path\":\"/a.service\",\"repository\":\"/tmp/example-project\"}"
        `shouldMention` "also carries unit_path"

    it "refuses an entry that names no job even though it parses" $ do
      let refusal entry =
            either id (const "unexpectedly resolved") (approvalRecordFromBytes boardIdentity (recordDocument [("example/project", entry)]))
      refusal (launchdEntry "" "/a.plist") `shouldMention` "names no launchd identifier"
      refusal (launchdEntry "a" "relative.plist") `shouldMention` "is not absolute"

    it "selects this repository's entry and never another repository's" $ do
      -- Requirement 2's first half: a document holding only a foreign entry is
      -- an uninstalled repository, not somebody else's service.
      approvalRecordFromBytes
        boardIdentity
        (recordDocument [("other/repo", launchdEntry "com.coghex.issue-approval.other.repo" "/other.plist")])
        `shouldBe` Right Nothing
      -- And a foreign entry beside this one changes nothing about which is
      -- selected.
      fmap (fmap (.approvalRecordIdentifier))
        ( approvalRecordFromBytes
            boardIdentity
            ( recordDocument
                [ ("other/repo", launchdEntry "com.coghex.issue-approval.other.repo" "/other.plist"),
                  ("example/project", launchdEntry "com.coghex.issue-approval.example.project" "/mine.plist")
                ]
            )
        )
        `shouldBe` Right (Just "com.coghex.issue-approval.example.project")

    it "selects by a case-folded identity, so one repository has one service" $
      fmap (fmap (.approvalRecordIdentifier))
        (approvalRecordFromBytes "Example/Project" (recordDocument [("example/project", launchdEntry "installed" "/mine.plist")]))
        `shouldBe` Right (Just "installed")

    it "decides a systemd host on whether its user manager actually answers" $ do
      -- The platform's name is not the question. A `systemctl` with no session
      -- bus behind it manages nothing, so the probe reads the manager's own
      -- version exactly as `tools/service_manager.py` does and believes only a
      -- clean exit. Driven through a fake `systemctl` so both answers are
      -- reachable on any host.
      withFakeSystemctl ["exit 0"] systemdUserManagerIsLive `shouldReturn` True
      withFakeSystemctl ["echo 'Failed to connect to bus' >&2", "exit 1"] systemdUserManagerIsLive
        `shouldReturn` False

    it "reports a host with no reachable manager as its own condition" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- Requirement 10, and the shape a Linux host without a user session
        -- arrives in: the probe found no manager, which is the same 'Nothing'
        -- an unsupported platform produces. It is a distinct answer, so nothing
        -- downstream can present it as an ordinary missing installation the
        -- operator could install their way out of — and the message names the
        -- session requirement rather than the installer.
        resolved <- resolveApprovalDefinition Nothing boardIdentity (temporaryRoot </> "config.json")
        case resolved of
          Left (ApprovalHostUnsupported message) -> do
            message `shouldMention` "not supported on this host"
            message `shouldMention` "systemctl --user"
            message `shouldNotMention` "install_issue_approval.py"
          other -> expectationFailure ("expected an unsupported host, got " <> show other)

    it "offers no control at all for a host with no reachable manager" $ do
      -- And the whole of "offers no control": the seam refuses and hands off
      -- nothing, so no controller process can be spawned there.
      resolved <- resolveApprovalDefinition Nothing boardIdentity "/nonexistent/config.json"
      unavailable <- either pure (const (fail "expected an unsupported host")) resolved
      state <-
        (\base -> base {appApprovalController = Left unavailable, appApprovalStatus = approvalUnavailableStatus unavailable})
          <$> dashboardShowing stoppedStatus
      state.appApprovalStatus.approvalActivity `shouldBe` ApprovalServiceUnsupported
      let (pressed, handoff) = approvalTogglePress state
      handoffStart handoff `shouldBe` Nothing
      pressed.appNotice `shouldMentionJust` "not supported on this host"

    it "names the remediation for every way an installed lookup can fail" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let recordPath = temporaryRoot </> "config.json"
            failureFor = fmap (either approvalUnavailableMessage (const "unexpectedly resolved"))
        absent <- failureFor (resolveApprovalDefinition (Just ApprovalLaunchd) boardIdentity recordPath)
        absent `shouldMention` "not installed for example/project"
        absent `shouldMention` "install_issue_approval.py"

        ByteString.writeFile recordPath (ByteString.pack "{ not json")
        unreadable <- failureFor (resolveApprovalDefinition (Just ApprovalLaunchd) boardIdentity recordPath)
        unreadable `shouldMention` "is unreadable"

        ByteString.writeFile recordPath (recordDocument [("example/project", launchdEntry "installed" (temporaryRoot </> "gone.plist"))])
        stale <- failureFor (resolveApprovalDefinition (Just ApprovalLaunchd) boardIdentity recordPath)
        stale `shouldMention` "LaunchAgent is missing at"

        foreign' <- failureFor (resolveApprovalDefinition (Just ApprovalSystemd) boardIdentity recordPath)
        foreign' `shouldMention` "describes a launchd job, which this systemd host cannot run"

    it "resolves the definition the record names, wherever the installer put it" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let recordPath = temporaryRoot </> "config.json"
            plist = temporaryRoot </> "installed.plist"
        ByteString.writeFile plist (ByteString.pack "<plist/>")
        ByteString.writeFile recordPath (recordDocument [("example/project", launchdEntry "installed" plist)])
        resolveApprovalDefinition (Just ApprovalLaunchd) boardIdentity recordPath
          `shouldReturn` Right (ApprovalLaunchd, plist)

    it "rebinds the installed command to this checkout and drops what it supplies itself" $
      -- The definition runs `run`; a status query that inherited it would
      -- start a service instead of reading one. The bound arguments are
      -- dropped for the same reason the drainer drops them: a definition
      -- carrying them would name two checkouts.
      controllerFromApprovalCommand
        ApprovalLaunchd
        boardRepository
        [ "/usr/bin/python3",
          "/installed/approve_issues_service.py",
          "--config",
          "/etc/kanban.toml",
          "--path",
          "/somewhere/else",
          "--repo",
          "other/repo",
          "run"
        ]
        `shouldBe` Right
          ( ApprovalController
              "/usr/bin/python3"
              [ "/installed/approve_issues_service.py",
                "--config",
                "/etc/kanban.toml",
                "--path",
                "/tmp/example-project",
                "--repo",
                "example/project"
              ]
              ApprovalLaunchd
          )

    it "refuses a definition whose command identifies no controller" $
      controllerFromApprovalCommand ApprovalLaunchd boardRepository ["/usr/bin/python3"]
        `shouldSatisfy` either (Text.isInfixOf "do not identify the issue approval controller") (const False)

  describe "issue approval status decoding" $ do
    it "gives every state the controller publishes its own distinct value" $ do
      -- Requirement 3. Six states, six activities, and no two collapsed
      -- together: a reader that flattened any pair would report a service that
      -- died as one that was told to stop.
      let activityOf state = fmap (.approvalActivity) (decodedStatus (addressed state []))
      activityOf "starting" `shouldBe` Right ApprovalServiceStarting
      activityOf "running" `shouldBe` Right ApprovalServiceRunning
      activityOf "barrier" `shouldBe` Right ApprovalServiceBarrier
      activityOf "stopped" `shouldBe` Right ApprovalServiceStopped
      activityOf "child_failure" `shouldBe` Right ApprovalServiceChildFailure
      activityOf "controller_failure" `shouldBe` Right ApprovalServiceControllerFailure

    it "renders the ordinary running and stopped states in the drainer's vocabulary" $ do
      decodedStatus (addressed "running" []) `shouldBe` Right (ApprovalStatus ApprovalOn "on" ApprovalServiceRunning Nothing Nothing)
      decodedStatus (addressed "stopped" []) `shouldBe` Right (ApprovalStatus ApprovalOff "off" ApprovalServiceStopped Nothing Nothing)
      decodedStatus (addressed "starting" []) `shouldBe` Right (ApprovalStatus ApprovalStarting "starting…" ApprovalServiceStarting Nothing Nothing)

    it "decodes an absent, malformed, or wrongly versioned document to an explicit unknown" $ do
      -- Never to a healthy or stopped guess. The first two cannot decode at
      -- all and say so; the rest decode and are refused on their own terms.
      decodedStatus (LazyByteString.pack "") `shouldSatisfy` either (Text.isInfixOf "could not decode issue approval status") (const False)
      decodedStatus (LazyByteString.pack "{\"state\":") `shouldSatisfy` either (Text.isInfixOf "could not decode issue approval status") (const False)

      let unknownFor fields = fmap (.approvalActivity) (decodedStatus (document fields))
          detailFor fields = fmap (.approvalDetail) (decodedStatus (document fields))
          withSchema = "\"schema\":\"kanban-issue-approval-status\""
          withVersion = "\"version\":1"
          withRepository = "\"repository\":\"example/project\""
      unknownFor [withVersion, withRepository, "\"state\":\"running\""] `shouldBe` Right ApprovalServiceUnknown
      detailFor [withVersion, withRepository, "\"state\":\"running\""] `shouldMentionRight` "reported schema none"
      unknownFor [withSchema, "\"version\":2", withRepository, "\"state\":\"running\""] `shouldBe` Right ApprovalServiceUnknown
      detailFor [withSchema, "\"version\":2", withRepository, "\"state\":\"running\""] `shouldMentionRight` "status version 2"
      unknownFor [withSchema, withVersion, withRepository] `shouldBe` Right ApprovalServiceUnknown
      unknownFor [withSchema, withVersion, withRepository, "\"state\":\"paused\""] `shouldBe` Right ApprovalServiceUnknown
      detailFor [withSchema, withVersion, withRepository, "\"state\":\"paused\""] `shouldMentionRight` "unknown state: paused"

    it "refuses an observation recorded for another repository" $ do
      -- Requirement 2's second half. The identity is compared case-folded on
      -- both sides, so one repository's two spellings are one repository, and
      -- a genuinely foreign one is never believed.
      let foreignDocument =
            document
              [ "\"schema\":\"kanban-issue-approval-status\"",
                "\"version\":1",
                "\"repository\":\"other/repo\"",
                "\"state\":\"running\""
              ]
      fmap (.approvalActivity) (decodedStatus foreignDocument) `shouldBe` Right ApprovalServiceUnknown
      fmap (.approvalDetail) (decodedStatus foreignDocument) `shouldMentionRight` "reported repository other/repo"
      let uppercased =
            document
              [ "\"schema\":\"kanban-issue-approval-status\"",
                "\"version\":1",
                "\"repository\":\"Example/Project\"",
                "\"state\":\"running\""
              ]
      fmap (.approvalActivity) (decodedStatus uppercased) `shouldBe` Right ApprovalServiceRunning

    it "drops a refused observation's incident set rather than showing another service's" $
      fmap (.observedApprovalIncidents)
        ( decoded
            ( document
                [ "\"schema\":\"kanban-issue-approval-status\"",
                  "\"version\":1",
                  "\"repository\":\"other/repo\"",
                  "\"state\":\"running\"",
                  "\"open_incidents\":[]"
                ]
            )
        )
        `shouldBe` Right Nothing

    it "reports the ordered barrier as a warning naming its issue" $ do
      -- Requirement 7: warning severity, the issue number, and not a process
      -- failure. The exact composition is the drainer's, which is what D-5
      -- asks the sidebar to reuse.
      status <- requireRight "barrier" (decodedStatus (addressed "barrier" ["\"barrier_issue\":254", barrierIncidentField 254]))
      status.approvalState `shouldBe` ApprovalWarning
      status.approvalActivity `shouldBe` ApprovalServiceBarrier
      status.approvalDetail `shouldBe` "on · unresolved incident · Issue #254 requests changes"
      status.approvalBarrierIssue `shouldBe` Just 254
      fmap (.approvalIncidentSeverity) status.approvalIncident `shouldBe` Just ApprovalWarningSeverity
      fmap (.approvalIncidentIssue) status.approvalIncident `shouldBe` Just (Just 254)

    it "keeps the barrier and its warning across an intentional stop" $ do
      -- The barrier is read from the durable record rather than from live
      -- state, so stopping the service does not resolve it. Both facts are
      -- kept: the service is stopped *and* the warning still names its issue,
      -- rather than either flattening the other.
      status <- requireRight "stopped barrier" (decodedStatus (addressed "stopped" ["\"barrier_issue\":254", barrierIncidentField 254]))
      status.approvalActivity `shouldBe` ApprovalServiceStopped
      status.approvalBarrierIssue `shouldBe` Just 254
      status.approvalDetail `shouldBe` "stopped · unresolved incident · Issue #254 requests changes"
      status.approvalState `shouldBe` ApprovalError
      fmap (.approvalIncidentSeverity) status.approvalIncident `shouldBe` Just ApprovalWarningSeverity

    it "restores the barrier from the record alone when its warning was acknowledged" $ do
      -- The record is the authority and the warning is only its display, so an
      -- acknowledged barrier is still a barrier and still names its issue.
      status <- requireRight "acknowledged barrier" (decodedStatus (addressed "barrier" ["\"barrier_issue\":254"]))
      status.approvalActivity `shouldBe` ApprovalServiceBarrier
      status.approvalDetail `shouldBe` "on · unresolved incident · Issue #254 requests changes"
      fmap (.approvalIncidentIssue) status.approvalIncident `shouldBe` Just (Just 254)

    it "treats a running document with a durable barrier as barriered" $
      -- A restart writes `running` before it has reconciled its barrier. The
      -- record outranks that, so the queue is never reported as moving past an
      -- issue it is still stopped at.
      fmap (.approvalActivity) (decodedStatus (addressed "running" ["\"barrier_issue\":254"]))
        `shouldBe` Right ApprovalServiceBarrier

    it "refuses a document whose own barrier record could not be read" $
      fmap (.approvalActivity) (decodedStatus (addressed "running" ["\"barrier_unreadable\":\"the barrier record could not be read\""]))
        `shouldBe` Right ApprovalServiceUnknown

    it "names what a failed run reported rather than a generic failure" $ do
      fmap (.approvalDetail) (decodedStatus (addressed "child_failure" ["\"reason\":null", "\"message\":\"m\"", barrierIncidentField 9]))
        `shouldMentionRight` "Issue #9 requests changes"
      fmap (.approvalDetail) (decodedStatus (addressed "controller_failure" []))
        `shouldMentionRight` "the controller failed"

    it "decodes the whole open incident set beside the newest-only projection" $ do
      observation <-
        requireRight "incident set" $
          decoded
            ( addressed
                "stopped"
                [ "\"open_incidents\":[{\"incident_id\":\"incident-2\",\"kind\":\"approval-error\",\"severity\":\"error\",\"summary\":\"model failed\"}"
                    <> ",{\"incident_id\":\"incident-1\",\"kind\":\"issue-changes-requested\",\"severity\":\"warning\",\"issue\":7,\"summary\":\"Issue #7 requests changes\"}]"
                ]
            )
      fmap (map (.approvalIncidentId)) observation.observedApprovalIncidents `shouldBe` Just ["incident-2", "incident-1"]
      fmap (map (.approvalIncidentSeverity)) observation.observedApprovalIncidents
        `shouldBe` Just [ApprovalErrorSeverity, ApprovalWarningSeverity]

    it "tells a controller that reported no incidents apart from one that reported no set" $ do
      fmap (.observedApprovalIncidents) (decoded (addressed "running" ["\"open_incidents\":[]"])) `shouldBe` Right (Just [])
      fmap (.observedApprovalIncidents) (decoded (addressed "running" [])) `shouldBe` Right Nothing

    it "reads an incident with no severity as an error rather than as a warning" $
      -- A warning is the one severity that says nothing failed, so it is never
      -- the guess a missing field resolves to.
      fmap (fmap (.approvalIncidentSeverity) . (.approvalIncident))
        (decodedStatus (addressed "stopped" ["\"open_incident\":{\"incident_id\":\"incident-3\",\"kind\":\"approval-error\"}"]))
        `shouldBe` Right (Just ApprovalErrorSeverity)

    it "keeps a status document the controller printed while exiting nonzero" $
      fmap (.observedApprovalStatus.approvalActivity)
        ( approvalStatusFromControllerExit
            boardIdentity
            (ExitFailure 1)
            (LazyByteString.unpack (addressed "stopped" []))
            "the job is not loaded"
        )
        `shouldBe` Right ApprovalServiceStopped

  describe "issue approval controller invocations" $ do
    it "decodes the status a real controller process prints while exiting nonzero" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        controller <-
          fakeApprovalController
            temporaryRoot
            [ ByteString.pack ("printf '%s' '" <> LazyByteString.unpack (addressed "stopped" ["\"barrier_issue\":254"]) <> "'"),
              "echo 'the job is not loaded' >&2",
              "exit 4"
            ]
        observation <- requireRight "nonzero controller" =<< runApprovalCommand 5 boardIdentity controller "status"
        observation.observedApprovalStatus.approvalBarrierIssue `shouldBe` Just 254
        observation.observedApprovalStatus.approvalDetail
          `shouldBe` "stopped · unresolved incident · Issue #254 requests changes"

    it "reports a failing controller's diagnostics when it printed nothing decodable" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        controller <- fakeApprovalController temporaryRoot ["echo 'the job is not loaded' >&2", "exit 1"]
        runApprovalCommand 5 boardIdentity controller "status" `shouldReturn` Left "the job is not loaded"

    it "leaves no survivor from a wedged controller's process group, and says the transition's outcome is unknown" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- Requirement 6, and the same shape the drainer is held to: the
        -- controller and something it started both ignore TERM, and the
        -- descendant holds the inherited pipes open, so nothing about the
        -- invocation ending implies either stopped.
        let leaderFile = temporaryRoot </> "approval-leader-pid"
            descendantFile = temporaryRoot </> "approval-descendant-pid"
        controller <-
          fakeApprovalController
            temporaryRoot
            [ "trap '' TERM",
              "sh -c \"trap '' TERM; while :; do sleep 1; done\" &",
              ByteString.pack ("echo $! > " <> descendantFile),
              ByteString.pack ("echo $$ > " <> leaderFile),
              "while :; do sleep 1; done"
            ]
        outcome <- runApprovalCommand 3 boardIdentity controller "start"
        -- Taken the instant the invocation returns, so this proves the group
        -- was already empty when the timeout was reported.
        snapshot <- readProcessSnapshot >>= requireRight "process snapshot after the approval timeout"
        leaderPid <- readRecordedPid leaderFile
        descendantPid <- readRecordedPid descendantFile
        descendantPid `shouldNotBe` leaderPid
        identityForPid leaderPid snapshot `shouldBe` Nothing
        identityForPid descendantPid snapshot `shouldBe` Nothing
        message <- requireLeft "a wedged controller reported success" outcome
        message `shouldMention` "issue approval start timed out after 3 seconds"
        message `shouldMention` "the outcome is unknown"
        message `shouldNotMention` "still running"

    it "keeps the outcome-unknown wording generic for a timed-out status query" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        controller <- fakeApprovalController temporaryRoot ["while :; do sleep 1; done"]
        outcome <- runApprovalCommand 1 boardIdentity controller "status"
        message <- requireLeft "a wedged status query reported success" outcome
        message `shouldMention` "issue approval status timed out after 1 seconds"
        message `shouldNotMention` "reconcile"

  describe "issue approval toggle decisions" $ do
    it "starts a settled stopped service and stops a settled running one" $ do
      approvalToggle False stoppedStatus `shouldBe` StartApprovalService
      approvalToggle False runningStatus `shouldBe` StopApprovalService
      -- A barriered service is running, so the toggle stops it, exactly as the
      -- drainer's yellow button does.
      approvalToggle False barrierStatus `shouldBe` StopApprovalService

    it "refuses a second toggle while one is in flight, however it is reported" $ do
      approvalToggle True stoppedStatus `shouldBe` ApprovalToggleBusy "Issue approval service is already starting or stopping"
      approvalToggle False (ApprovalStatus ApprovalStarting "starting…" ApprovalServiceStarting Nothing Nothing)
        `shouldBe` ApprovalToggleBusy "Issue approval service is already starting"

    it "offers no control at all on a host that cannot run the service" $ do
      -- Requirement 10: the refusal is a distinct state's, not a stopped
      -- service's, so a press reports the condition rather than starting one.
      let unsupported = approvalUnavailableStatus (ApprovalHostUnsupported "the issue approval service is not supported on this host")
      unsupported.approvalActivity `shouldBe` ApprovalServiceUnsupported
      approvalToggle False unsupported `shouldBe` ApprovalToggleBusy "Issue approval service is not supported on this host"

    it "spawns nothing when there is no controller to spawn" $ do
      -- The press is taken and inspected; the handoff is what would have run a
      -- controller, and there is none. That is the whole of requirement 10's
      -- "offers no control".
      unsupported <-
        withApproval (approvalUnavailableStatus (ApprovalHostUnsupported "unsupported host"))
          . (\state -> state {appApprovalController = Left (ApprovalHostUnsupported "unsupported host")})
          <$> testAppState (Board Map.empty)
      let (pressed, handoff) = approvalTogglePress unsupported
      handoffStart handoff `shouldBe` Nothing
      pressed.appApprovalBusy `shouldBe` False
      pressed.appNotice `shouldBe` Just "Issue approval service is not supported on this host"

      uninstalled <-
        (\state -> state {appApprovalController = Left (ApprovalUndiscoverable "not installed for example/project")})
          <$> dashboardShowing stoppedStatus
      let (refused, noHandoff) = approvalTogglePress uninstalled
      handoffStart noHandoff `shouldBe` Nothing
      refused.appNotice `shouldMentionJust` "control unavailable"
      refused.appApprovalBusy `shouldBe` False

    it "holds an optimistic transition and refuses a second press behind it" $ do
      state <- dashboardShowing stoppedStatus
      let (pressed, handoff) = approvalTogglePress state
      handoffStart handoff `shouldBe` Just True
      fmap (.approvalHandoffTransition) handoff `shouldBe` Just 1
      pressed.appApprovalStatus.approvalActivity `shouldBe` ApprovalServiceStarting
      pressed.appApprovalStatus.approvalDetail `shouldBe` "starting…"
      pressed.appApprovalBusy `shouldBe` True
      -- The second press issues nothing: it reports the transition instead.
      let (again, secondHandoff) = approvalTogglePress pressed
      handoffStart secondHandoff `shouldBe` Nothing
      again.appApprovalStatus `shouldBe` pressed.appApprovalStatus
      again.appNotice `shouldBe` Just "Issue approval service is already starting or stopping"

    it "carries the durable barrier through an optimistic stop" $ do
      state <- dashboardShowing barrierStatus
      let (pressed, _) = approvalTogglePress state
      pressed.appApprovalStatus.approvalActivity `shouldBe` ApprovalServiceStopping
      pressed.appApprovalStatus.approvalBarrierIssue `shouldBe` Just 254

  describe "issue approval transition races" $ do
    it "resolves a race to the authoritative observation rather than to the optimistic one" $ do
      state <- dashboardShowing stoppedStatus
      let (pressed, handoff) = approvalTogglePress state
          transition = maybe 0 (.approvalHandoffTransition) handoff
          authoritative = ApprovalObservation runningStatus (Just []) (resultIdentity ApprovalServiceRunning Nothing False "t1")
          (settled, _) = approvalToggleApplied transition (Right authoritative) pressed
      settled.appApprovalStatus `shouldBe` runningStatus
      settled.appApprovalBusy `shouldBe` False
      settled.appNotice `shouldBe` Just "Issue approval service is on"

    it "lets an authoritative poll supersede the optimistic transition and free the control" $ do
      state <- dashboardShowing stoppedStatus
      let (pressed, _) = approvalTogglePress state
          observation = ApprovalObservation runningStatus (Just []) (resultIdentity ApprovalServiceRunning Nothing False "t1")
          (polled, _) = polledAfter pressed (Right observation)
      polled.appApprovalStatus `shouldBe` runningStatus
      polled.appApprovalBusy `shouldBe` False

    it "ignores a failed poll while a transition it cannot see is still in flight" $ do
      state <- dashboardShowing stoppedStatus
      let (pressed, _) = approvalTogglePress state
          (polled, refresh) = polledAfter pressed (Left "issue approval status timed out after 4 seconds")
      polled.appApprovalStatus `shouldBe` pressed.appApprovalStatus
      polled.appApprovalBusy `shouldBe` True
      refresh `shouldBe` False

    it "discards a late completion belonging to a superseded transition" $ do
      state <- dashboardShowing stoppedStatus
      let (started, _) = approvalTogglePress state
          -- The start is given up on by a poll, and the user presses again.
          (settled, _) = polledAfter started (Right (ApprovalObservation runningStatus (Just []) (resultIdentity ApprovalServiceRunning Nothing False "t1")))
          (stopping, secondHandoff) = approvalTogglePress settled
          stale = ApprovalObservation stoppedStatus (Just []) (resultIdentity ApprovalServiceStopped Nothing False "t0")
          (applied, _) = approvalToggleApplied 1 (Right stale) stopping
      fmap (.approvalHandoffTransition) secondHandoff `shouldBe` Just 2
      -- The stale start's completion restores neither its optimistic state nor
      -- its observation over the newer press.
      applied.appApprovalStatus `shouldBe` stopping.appApprovalStatus
      applied.appApprovalIncidents `shouldBe` stopping.appApprovalIncidents
      applied.appApprovalResult `shouldBe` stopping.appApprovalResult
      applied.appApprovalTransition `shouldBe` stopping.appApprovalTransition
      applied.appNotice `shouldBe` stopping.appNotice
      applied.appApprovalStatus.approvalActivity `shouldBe` ApprovalServiceStopping
      applied.appApprovalBusy `shouldBe` True

    it "clears busy on a failed toggle so control can never stay refused" $ do
      state <- dashboardShowing stoppedStatus
      let (pressed, handoff) = approvalTogglePress state
          transition = maybe 0 (.approvalHandoffTransition) handoff
          (failed, _) = approvalToggleApplied transition (Left "the job is not loaded") pressed
      failed.appApprovalBusy `shouldBe` False
      failed.appApprovalStatus.approvalActivity `shouldBe` ApprovalServiceUnknown
      failed.appNotice `shouldMentionJust` "control failed"
      -- And the toggle is usable again, rather than answering "already
      -- starting" forever.
      approvalToggle failed.appApprovalBusy failed.appApprovalStatus `shouldBe` StartApprovalService

    it "discards a poll whose query began before the press it landed after" $ do
      -- The controller query was issued while the service was still stopped;
      -- the press happened while it was in flight. Letting that pre-press read
      -- through would clear the busy flag on a view of the service from before
      -- the toggle, which then makes the real start's completion look late —
      -- leaving the board reporting off while the service runs.
      state <- dashboardShowing stoppedStatus
      let (pressed, handoff) = approvalTogglePress state
          transition = maybe 0 (.approvalHandoffTransition) handoff
          prePress =
            ApprovalObservation
              stoppedStatus
              (Just [])
              (resultIdentity ApprovalServiceStopped Nothing False "t0")
          (afterStalePoll, _) = approvalStatusApplied 0 (Right prePress) pressed
      transition `shouldBe` 1
      afterStalePoll.appApprovalStatus.approvalActivity `shouldBe` ApprovalServiceStarting
      afterStalePoll.appApprovalBusy `shouldBe` True
      -- And because it changed nothing, the start's own completion is still
      -- the current transition's and still lands.
      let running =
            ApprovalObservation
              runningStatus
              (Just [])
              (resultIdentity ApprovalServiceRunning Nothing False "t2")
          (settled, _) = approvalToggleApplied transition (Right running) afterStalePoll
      settled.appApprovalStatus `shouldBe` runningStatus
      settled.appApprovalBusy `shouldBe` False

    it "discards a completion a poll has already superseded" $ do
      -- The completion belongs to this very transition, so its generation
      -- matches. It is still late: the poll that cleared busy carried a read
      -- taken after it, and applying the completion would put the older answer
      -- back — here, replacing a newly observed barrier with the running state
      -- the start itself returned.
      state <- dashboardShowing stoppedStatus
      let (pressed, handoff) = approvalTogglePress state
          transition = maybe 0 (.approvalHandoffTransition) handoff
          barriered =
            ApprovalObservation
              barrierStatus
              (Just [])
              (resultIdentity ApprovalServiceBarrier (Just ApprovalOutcomeChangesRequested) False "t2")
          (polled, _) = polledAfter pressed (Right barriered)
          stale =
            ApprovalObservation
              runningStatus
              (Just [])
              (resultIdentity ApprovalServiceRunning Nothing False "t1")
          (settled, refresh) = approvalToggleApplied transition (Right stale) polled
      polled.appApprovalStatus `shouldBe` barrierStatus
      settled.appApprovalStatus `shouldBe` barrierStatus
      settled.appApprovalResult `shouldBe` polled.appApprovalResult
      settled.appApprovalBusy `shouldBe` False
      refresh `shouldBe` False

    it "leaves a newer observation alone when its own transition then fails" $ do
      state <- dashboardShowing stoppedStatus
      let (pressed, handoff) = approvalTogglePress state
          transition = maybe 0 (.approvalHandoffTransition) handoff
          (polled, _) = polledAfter pressed (Right (ApprovalObservation runningStatus (Just []) (resultIdentity ApprovalServiceRunning Nothing False "t1")))
          (failed, _) = approvalToggleApplied transition (Left "the transition timed out") polled
      failed.appApprovalStatus `shouldBe` runningStatus
      failed.appApprovalBusy `shouldBe` False
      -- Nothing was owed to that completion: the busy flag it would have
      -- cleared was already clear, so control is not refused either.
      approvalToggle failed.appApprovalBusy failed.appApprovalStatus `shouldBe` StopApprovalService

  describe "competing canonical work while the service is live" $ do
    it "refuses a canonical stage only while a backend pass is actually running" $ do
      -- Requirement 8 is about a review in flight, not about the service being
      -- switched on. The controller sleeps between passes with no child at
      -- all, so a running service with no live pass must let a card review
      -- through; only the pass itself contends for the backend's lock.
      reviewing <- observing runningStatus True
      approvalServiceRefusal reviewing InitialReview `shouldMentionJust` "wait for it to finish or stop the service"
      approvalServiceRefusal reviewing IssueRereview `shouldMentionJust` "canonical review in flight"

      idle <- observing runningStatus False
      approvalServiceRefusal idle InitialReview `shouldBe` Nothing
      approvalServiceRefusal idle IssueRereview `shouldBe` Nothing

    it "refuses the same issue too, not only another one" $ do
      -- The service reviews in numeric order and cannot be asked to skip to
      -- the card's issue, so a second canonical child for it is the same
      -- contention as for any other.
      reviewing <- observing runningStatus True
      approvalServiceRefusal reviewing InitialReview `shouldBe` approvalServiceRefusal reviewing IssueRereview

    it "keeps the selected-card workflow available at a barrier, pass or no pass" $ do
      -- A barriered controller's child is the read-only gate check: no model
      -- work, and the lock released between checks, so the repair of the
      -- barriered issue and the rereview after it both stay launchable (D-10).
      checking <- observing barrierStatus True
      approvalServiceRefusal checking InitialReview `shouldBe` Nothing
      approvalServiceRefusal checking IssueRereview `shouldBe` Nothing
      approvalServiceRefusal checking IssueRevision `shouldBe` Nothing

      waiting <- observing barrierStatus False
      approvalServiceRefusal waiting IssueRereview `shouldBe` Nothing

    it "never refuses a revision, whatever the service is doing" $ do
      -- A revision runs the interactive coordinator and performs no canonical
      -- backend review, so it contends for nothing.
      reviewing <- observing runningStatus True
      approvalServiceRefusal reviewing IssueRevision `shouldBe` Nothing

    it "permits canonical work against every settled or unknowable state" $ do
      stopped <- observing stoppedStatus False
      approvalServiceRefusal stopped InitialReview `shouldBe` Nothing
      unsupported <- observing (approvalUnavailableStatus (ApprovalHostUnsupported "unsupported")) False
      approvalServiceRefusal unsupported InitialReview `shouldBe` Nothing
      unknown <- observing (ApprovalStatus ApprovalError "no answer" ApprovalServiceUnknown Nothing Nothing) False
      approvalServiceRefusal unknown InitialReview `shouldBe` Nothing
      failed <- observing (ApprovalStatus ApprovalError "stopped · a backend pass failed" ApprovalServiceChildFailure Nothing Nothing) False
      approvalServiceRefusal failed InitialReview `shouldBe` Nothing

    it "permits canonical work before any observation has been applied" $ do
      -- No evidence of a review is not evidence of one, and the backend's own
      -- approval lock is what actually decides contention.
      unobserved <- dashboardShowing stoppedStatus
      unobserved.appApprovalResult `shouldBe` Nothing
      approvalServiceRefusal unobserved InitialReview `shouldBe` Nothing

    it "asks the controller again at the asynchronous launch boundary" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- The board's own observation is up to ten seconds old, and the
        -- service can spawn a canonical child inside that window. The check
        -- taken at the launch itself therefore reads the controller rather
        -- than the last poll: a service that was idle when the key was pressed
        -- and is reviewing by the time the launch runs is still refused.
        reviewing <-
          fakeApprovalController
            temporaryRoot
            [ByteString.pack ("printf '%s' '" <> LazyByteString.unpack (addressed "running" ["\"backend_pid\":424242"]) <> "'")]
        contention <- liveApprovalContention boardIdentity (Right reviewing)
        contention `shouldMentionJust` "canonical review in flight"

    it "lets the launch through when that live read finds no pass" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        idle <-
          fakeApprovalController
            temporaryRoot
            [ByteString.pack ("printf '%s' '" <> LazyByteString.unpack (addressed "running" []) <> "'")]
        liveApprovalContention boardIdentity (Right idle) `shouldReturn` Nothing

    it "lets the launch through when there is no controller or none can be read" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- Fails open in both directions on purpose. A repository with no
        -- installed service contends with nothing, and a controller that
        -- cannot be read has said nothing — refusing on it would let one
        -- broken service block every card review indefinitely. The backend's
        -- approval lock is what makes that safe.
        liveApprovalContention boardIdentity (Left (ApprovalUndiscoverable "not installed")) `shouldReturn` Nothing
        broken <- fakeApprovalController temporaryRoot ["echo 'the job is not loaded' >&2", "exit 1"]
        liveApprovalContention boardIdentity (Right broken) `shouldReturn` Nothing

    it "asks the service again after the preflight, not only before it" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- The preflight runs several probes, and the service can take the
        -- backend's lock while they do. A check taken before it would still
        -- have seen an idle service and spawned a competing child; the one
        -- taken directly before the spawn sees what the preflight's own
        -- duration let happen.
        let marker = temporaryRoot </> "service-took-the-lock"
        controller <- switchingApprovalController temporaryRoot marker
        spawned <- newIORef False
        outcome <-
          canonicalLaunchOutcome
            InitialReview
            boardIdentity
            (Right controller)
            (writeFile marker "" >> pure Nothing)
            (writeIORef spawned True >> pure (Right ()))
        outcome `shouldSatisfy` either (Text.isInfixOf "canonical review in flight") (const False)
        readIORef spawned `shouldReturn` False

    it "spawns when the service is still idle by the time the preflight ends" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let marker = temporaryRoot </> "service-took-the-lock"
        controller <- switchingApprovalController temporaryRoot marker
        spawned <- newIORef False
        outcome <-
          canonicalLaunchOutcome
            InitialReview
            boardIdentity
            (Right controller)
            (pure Nothing)
            (writeIORef spawned True >> pure (Right ()))
        outcome `shouldBe` Right ()
        readIORef spawned `shouldReturn` True

    it "never reaches the service, or the spawn, when the preflight blocks" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let marker = temporaryRoot </> "service-took-the-lock"
        controller <- switchingApprovalController temporaryRoot marker
        spawned <- newIORef False
        outcome <-
          canonicalLaunchOutcome
            InitialReview
            boardIdentity
            (Right controller)
            (pure (Just "Install the canonical review backend first"))
            (writeIORef spawned True >> pure (Right ()))
        outcome `shouldBe` Left "Install the canonical review backend first"
        readIORef spawned `shouldReturn` False

    it "launches a revision without asking the service at all" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- A revision performs no canonical backend review, so a service that
        -- is reviewing right now does not hold it up.
        let marker = temporaryRoot </> "service-took-the-lock"
        controller <- switchingApprovalController temporaryRoot marker
        writeFile marker ""
        spawned <- newIORef False
        outcome <-
          canonicalLaunchOutcome
            IssueRevision
            boardIdentity
            (Right controller)
            (pure Nothing)
            (writeIORef spawned True >> pure (Right ()))
        outcome `shouldBe` Right ()
        readIORef spawned `shouldReturn` True

    it "reads that live check against this repository, never another's" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- A foreign document decodes to unknown, which is not a live pass, so
        -- the launch is never refused on another repository's service.
        foreignController <-
          fakeApprovalController
            temporaryRoot
            [ ByteString.pack
                ( "printf '%s' '"
                    <> "{\"schema\":\"kanban-issue-approval-status\",\"version\":1"
                    <> ",\"repository\":\"other/repo\",\"state\":\"running\",\"backend_pid\":424242}'"
                )
            ]
        liveApprovalContention boardIdentity (Right foreignController) `shouldReturn` Nothing

    it "stops refusing card reviews once the service can no longer be read" $ do
      -- The last good observation had a live backend pass, so the interlock was
      -- refusing. A failed poll says this end cannot vouch for that any more,
      -- and a reading it has disowned must not go on blocking explicit work —
      -- the live check at the launch boundary fails open for the same reason.
      reviewing <- observing runningStatus True
      approvalServiceRefusal reviewing InitialReview `shouldMentionJust` "canonical review in flight"
      let (lost, _) = polledAfter reviewing (Left "issue approval status timed out after 4 seconds")
      lost.appApprovalStatus.approvalActivity `shouldBe` ApprovalServiceUnknown
      lost.appApprovalResult `shouldBe` Nothing
      approvalServiceRefusal lost InitialReview `shouldBe` Nothing

    it "stops refusing card reviews when a transition fails instead" $ do
      reviewing <- observing runningStatus True
      let (pressed, handoff) = approvalTogglePress reviewing
          transition = maybe 0 (.approvalHandoffTransition) handoff
          (failed, _) = approvalToggleApplied transition (Left "the job is not loaded") pressed
      failed.appApprovalResult `shouldBe` Nothing
      approvalServiceRefusal failed InitialReview `shouldBe` Nothing

  describe "board refresh after a service result" $ do
    it "refreshes for a first observation that already reports a mutation" $ do
      -- The startup fetch and the first poll are started concurrently, so a
      -- review the service published after that fetch read GitHub and before
      -- the first poll answered falls between them. Treating the first
      -- observation as a silent baseline would lose it permanently: every
      -- document after it is unchanged, and an unchanged document reports
      -- nothing new.
      state <- dashboardShowing stoppedStatus
      state.appApprovalResult `shouldBe` Nothing
      let firstSeen observation = snd (approvalObservationApplied observation state)
      firstSeen (observationWith runningStatus (resultIdentity ApprovalServiceRunning (Just ApprovalOutcomeAdvanced) True "t1"))
        `shouldBe` True
      firstSeen (observationWith barrierStatus (resultIdentity ApprovalServiceBarrier (Just ApprovalOutcomeChangesRequested) False "t1"))
        `shouldBe` True
      let failedStatus = ApprovalStatus ApprovalError "stopped · a backend pass failed" ApprovalServiceChildFailure Nothing Nothing
      firstSeen (observationWith failedStatus (resultIdentity ApprovalServiceChildFailure (Just ApprovalOutcomeIdle) False "t1"))
        `shouldBe` True

    it "asks for nothing on a first observation that reports no mutation" $ do
      -- And it stays cheap: a service that is simply off, or running an idle
      -- queue, has changed nothing for the startup refresh to have missed.
      state <- dashboardShowing stoppedStatus
      let firstSeen observation = snd (approvalObservationApplied observation state)
      firstSeen (observationWith stoppedStatus (resultIdentity ApprovalServiceStopped Nothing False "t1")) `shouldBe` False
      firstSeen (observationWith runningStatus (resultIdentity ApprovalServiceRunning (Just ApprovalOutcomeIdle) True "t1")) `shouldBe` False
      firstSeen (observationWith runningStatus (resultIdentity ApprovalServiceRunning (Just ApprovalOutcomeBusy) True "t1")) `shouldBe` False

    it "does not repeat that first refresh for the documents that follow it" $ do
      state <- dashboardShowing stoppedStatus
      let barriered stamp = observationWith barrierStatus (resultIdentity ApprovalServiceBarrier (Just ApprovalOutcomeChangesRequested) False stamp)
          (afterFirst, firstRefresh) = approvalObservationApplied (barriered "t1") state
          (afterSame, sameRefresh) = approvalObservationApplied (barriered "t1") afterFirst
          (_, recheckRefresh) = approvalObservationApplied (barriered "t2") afterSame
      firstRefresh `shouldBe` True
      sameRefresh `shouldBe` False
      recheckRefresh `shouldBe` False

    it "refreshes once per advancing pass and never twice for the same document" $ do
      -- The mutating outcome is read off the document written when the *next*
      -- pass spawns: an advance is followed immediately by the next spawn, so
      -- the settled document between them exists for microseconds and a
      -- ten-second poll would never see it.
      state <- dashboardShowing runningStatus
      let advanced stamp = observationWith runningStatus (resultIdentity ApprovalServiceRunning (Just ApprovalOutcomeAdvanced) True stamp)
          (afterFirst, firstRefresh) = approvalObservationApplied (advanced "t1") state {appApprovalResult = Just (resultIdentity ApprovalServiceRunning Nothing True "t0")}
          (afterRepeat, repeatRefresh) = approvalObservationApplied (advanced "t1") afterFirst
          (_, secondRefresh) = approvalObservationApplied (advanced "t2") afterRepeat
      firstRefresh `shouldBe` True
      repeatRefresh `shouldBe` False
      secondRefresh `shouldBe` True

    it "tells two same-second documents apart by more than their stamp" $ do
      -- `utc_stamp` is second-granular and the controller writes several states
      -- per pass, so an idle result and the advancing pass that follows it can
      -- share a stamp. Comparing stamps alone would suppress the refresh that
      -- second document is the only report of.
      state <- dashboardShowing runningStatus
      let idle = resultIdentity ApprovalServiceRunning (Just ApprovalOutcomeIdle) False "t1"
          advanced = resultIdentity ApprovalServiceRunning (Just ApprovalOutcomeAdvanced) True "t1"
          seenIdle = state {appApprovalResult = Just idle}
      snd (approvalObservationApplied (observationWith runningStatus advanced) seenIdle) `shouldBe` True
      -- The genuinely repeated document still reports nothing new.
      snd (approvalObservationApplied (observationWith runningStatus idle) seenIdle) `shouldBe` False

    it "asks for nothing on an idle or contended queue" $ do
      state <- dashboardShowing runningStatus
      let baseline = state {appApprovalResult = Just (resultIdentity ApprovalServiceRunning Nothing True "t0")}
          quiet outcome stamp = observationWith runningStatus (resultIdentity ApprovalServiceRunning (Just outcome) True stamp)
      snd (approvalObservationApplied (quiet ApprovalOutcomeIdle "t1") baseline) `shouldBe` False
      snd (approvalObservationApplied (quiet ApprovalOutcomeBusy "t1") baseline) `shouldBe` False

    it "refreshes once when the queue enters a barrier and not for its rechecks" $ do
      state <- dashboardShowing runningStatus
      let baseline = state {appApprovalResult = Just (resultIdentity ApprovalServiceRunning (Just ApprovalOutcomeIdle) False "t0")}
          barriered stamp inFlight =
            observationWith barrierStatus (resultIdentity ApprovalServiceBarrier (Just ApprovalOutcomeChangesRequested) inFlight stamp)
          (afterOpen, openRefresh) = approvalObservationApplied (barriered "t1" False) baseline
          (afterCheck, checkRefresh) = approvalObservationApplied (barriered "t2" True) afterOpen
          (_, recheckRefresh) = approvalObservationApplied (barriered "t3" False) afterCheck
      openRefresh `shouldBe` True
      checkRefresh `shouldBe` False
      recheckRefresh `shouldBe` False

    it "refreshes once when a run ends in a way whose outcome is unknown" $ do
      state <- dashboardShowing runningStatus
      let baseline = state {appApprovalResult = Just (resultIdentity ApprovalServiceRunning (Just ApprovalOutcomeIdle) True "t0")}
          failedStatus = ApprovalStatus ApprovalError "stopped · a backend pass failed" ApprovalServiceChildFailure Nothing Nothing
          failed stamp = observationWith failedStatus (resultIdentity ApprovalServiceChildFailure (Just ApprovalOutcomeIdle) False stamp)
          (afterFailure, failureRefresh) = approvalObservationApplied (failed "t1") baseline
          (_, repeatRefresh) = approvalObservationApplied (failed "t2") afterFailure
      failureRefresh `shouldBe` True
      repeatRefresh `shouldBe` False

    it "refreshes for a mutating pass that a stop landed on top of" $ do
      -- The one case with no following spawn to read the outcome off.
      state <- dashboardShowing runningStatus
      let baseline = state {appApprovalResult = Just (resultIdentity ApprovalServiceRunning (Just ApprovalOutcomeIdle) True "t0")}
          stopped = observationWith stoppedStatus (resultIdentity ApprovalServiceStopped (Just ApprovalOutcomeAdvanced) False "t1")
      snd (approvalObservationApplied stopped baseline) `shouldBe` True

    it "keeps the service's durable warning through the refresh it required" $ do
      -- Requirement 9's second half. The refresh is a request the transition
      -- returns, not something it writes over its own status with, so the
      -- barrier the observation reported is still what stands afterwards.
      state <- dashboardShowing runningStatus
      let baseline = state {appApprovalResult = Just (resultIdentity ApprovalServiceRunning (Just ApprovalOutcomeIdle) False "t0")}
          barriered = observationWith barrierStatus (resultIdentity ApprovalServiceBarrier (Just ApprovalOutcomeChangesRequested) False "t1")
          (applied, refresh) = approvalObservationApplied barriered baseline
      refresh `shouldBe` True
      applied.appApprovalStatus `shouldBe` barrierStatus
      applied.appApprovalStatus.approvalBarrierIssue `shouldBe` Just 254

  describe "the two services stay each other's business" $ do
    it "leaves every drainer field alone when an approval observation arrives" $ do
      state <- dashboardShowing stoppedStatus
      let (applied, _) = approvalObservationApplied (observationWith runningStatus (resultIdentity ApprovalServiceRunning Nothing False "t1")) state
      applied.appDrainerController `shouldSatisfy` either (const True) (const False)
      applied.appDrainerStatus `shouldBe` state.appDrainerStatus
      applied.appDrainerIncidents `shouldBe` state.appDrainerIncidents
      applied.appDrainerBusy `shouldBe` state.appDrainerBusy

    it "leaves every approval field alone when the drainer's own toggle is pressed" $ do
      state <- dashboardShowing barrierStatus
      let installed = state {appDrainerController = Right (DrainerController "/nonexistent/kanban-test-drainer" [] DrainerLaunchd)}
          (pressed, _) = drainerTogglePress installed
      pressed.appDrainerStatus.drainerState `shouldBe` DrainerStarting
      pressed.appApprovalStatus `shouldBe` barrierStatus
      pressed.appApprovalBusy `shouldBe` False
      pressed.appApprovalTransition `shouldBe` state.appApprovalTransition

    it "leaves every drainer field alone when the approval toggle is pressed" $ do
      state <- dashboardShowing stoppedStatus
      let installed = state {appDrainerStatus = DrainerStatus DrainerOn "on" DrainerServiceRunning Nothing}
          (pressed, _) = approvalTogglePress installed
      pressed.appApprovalBusy `shouldBe` True
      pressed.appDrainerStatus `shouldBe` installed.appDrainerStatus
      pressed.appDrainerBusy `shouldBe` False

-- | One poll issued under the state's current transition — that is, after
-- whatever press it lands beside. The epoch is what separates that from a poll
-- issued before the press, which is a different test.
polledAfter :: AppState -> Either Text ApprovalObservation -> (AppState, Bool)
polledAfter state result = approvalStatusApplied state.appApprovalTransition result state

-- | A controller that reports a live canonical pass once @marker@ exists, and
-- an idle service before that. Standing in for the service taking the
-- backend's approval lock partway through a launch.
switchingApprovalController :: FilePath -> FilePath -> IO ApprovalController
switchingApprovalController temporaryRoot marker =
  fakeApprovalController
    temporaryRoot
    [ ByteString.pack ("if [ -e " <> marker <> " ]; then"),
      ByteString.pack ("  printf '%s' '" <> LazyByteString.unpack (addressed "running" ["\"backend_pid\":424242"]) <> "'"),
      "else",
      ByteString.pack ("  printf '%s' '" <> LazyByteString.unpack (addressed "running" []) <> "'"),
      "fi"
    ]

-- | Whether a press handed controller work off, and which way. The handoff
-- has no 'Eq' instance and deliberately never gets one: what a test cares
-- about is that a refusal handed nothing off at all.
handoffStart :: Maybe ApprovalHandoff -> Maybe Bool
handoffStart = fmap (.approvalHandoffStart)

-- | @shouldMention@ through a 'Right', so a decode that failed is reported as
-- the failure it is rather than as a missing substring.
shouldMentionRight :: Either Text Text -> Text -> Expectation
shouldMentionRight actual fragment = case actual of
  Left message -> expectationFailure ("expected a decoded status, got: " <> Text.unpack message)
  Right value -> value `shouldMention` fragment

shouldMentionJust :: Maybe Text -> Text -> Expectation
shouldMentionJust actual fragment = case actual of
  Nothing -> expectationFailure ("expected a notice mentioning " <> Text.unpack fragment)
  Just value -> value `shouldMention` fragment
