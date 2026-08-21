-- | The service-managed pull request drainer: discovering its LaunchAgent or
-- its systemd unit, decoding its status, and deciding what a toggle does. The
-- direct single-pull-request merge behind @m@ is the group's other half, in
-- "Spec.Drainer.DirectMerge".
module Spec.Drainer (spec) where

import qualified Data.ByteString.Char8 as ByteString
import qualified Data.Text
import Kanban.Domain
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.Text (Text)
import Kanban.Drainer
  ( DrainerActivity (..),
    DrainerBackend (..),
    DrainerController (..),
    DrainerIncident (..),
    DrainerObservation (..),
    DrainerRecord (..),
    DrainerState (..),
    DrainerStatus (..),
    DrainerToggle (..),
    controllerFromProgramArguments,
    decodeDrainerStatus,
    drainerIsRunning,
    drainerRecordFromBytes,
    drainerRecordPath,
    drainerToggle,
    hostServiceManager,
    normalizedRepositoryIdentity,
    resolveDrainerDefinition,
    runDrainerCommand,
    statusFromControllerExit,
    unitExecStartArguments,
    unreadableDefinition
  )
import Kanban.Process (identityForPid, readProcessSnapshot)
import qualified Spec.Drainer.DirectMerge as DirectMerge
import Spec.Support.Env (withEnvironmentValue, withManagedRecordHome, withTemporaryCacheRoot)
import Spec.Support.Expect (isLeft, requireLeft, requireRight, shouldMention, shouldNotMention)
import Spec.Support.Process (fakeController, readRecordedPid, shouldNotHaveSwept, withSurvivingGroupLeader)
import System.Exit (ExitCode (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import Test.Hspec

spec :: Spec
spec = do
  describe "PR drainer service-definition discovery" $ do
    let entryFor label plist =
          "{\"launchd_label\":\""
            <> label
            <> "\",\"plist_path\":\""
            <> plist
            <> "\",\"repository\":\"/tmp/example-project\"}"
        unitEntryFor unit path =
          "{\"backend\":\"systemd\",\"systemd_unit\":\""
            <> unit
            <> "\",\"unit_path\":\""
            <> path
            <> "\",\"repository\":\"/tmp/example-project\"}"
        documentFor identity body =
          ByteString.pack
            ( "{\"ntfy_url\":\"https://notify.example.test/topic\",\"repositories\":{\""
                <> identity
                <> "\":"
                <> body
                <> "}}"
            )
        recordFor identity label plist = documentFor identity (entryFor label plist)
        recordDocument = recordFor "example/project"
        unitDocument unit path = documentFor "example/project" (unitEntryFor unit path)
        failureFor = either id (\resolved -> "unexpectedly resolved " <> Data.Text.pack (show resolved))

    it "reads the label, plist path, and repository the installer recorded" $
      -- The shape every installed macOS drainer already carries, and the one a
      -- record predating the backend field can only have: no discriminator at
      -- all, which is exactly what makes it launchd's.
      drainerRecordFromBytes
        "example/project"
        (recordDocument "com.example.drain" "/Users/example/Library/LaunchAgents/com.example.drain.plist")
        `shouldBe` Right
          ( Just
              ( DrainerRecord
                  DrainerLaunchd
                  "com.example.drain"
                  "/Users/example/Library/LaunchAgents/com.example.drain.plist"
                  "/tmp/example-project"
              )
          )

    it "reads a systemd entry as its own backend, unit, and unit path" $
      drainerRecordFromBytes
        "example/project"
        (unitDocument
           "com.coghex.drain-prs.example.project.service"
           "/home/example/.config/systemd/user/com.coghex.drain-prs.example.project.service")
        `shouldBe` Right
          ( Just
              ( DrainerRecord
                  DrainerSystemd
                  "com.coghex.drain-prs.example.project.service"
                  "/home/example/.config/systemd/user/com.coghex.drain-prs.example.project.service"
                  "/tmp/example-project"
              )
          )

    it "reads an explicit launchd discriminator the same way as none at all" $ do
      -- Both spellings describe one install: a record written before the
      -- discriminator existed and one written after it must resolve to the
      -- same job, or upgrading Kanban would strand a live macOS drainer.
      let explicit =
            documentFor
              "example/project"
              "{\"backend\":\"launchd\",\"launchd_label\":\"com.example.drain\",\
              \\"plist_path\":\"/tmp/x.plist\",\"repository\":\"/tmp/example-project\"}"
      drainerRecordFromBytes "example/project" explicit
        `shouldBe` drainerRecordFromBytes "example/project" (recordDocument "com.example.drain" "/tmp/x.plist")

    it "selects each installed repository's own record out of the shared document" $ do
      -- The property per-repository jobs rest on: installing a second
      -- repository adds an entry rather than replacing the first, so both
      -- stay separately resolvable from the one document.
      let document =
            ByteString.pack
              ( "{\"repositories\":{\"example/project\":"
                  <> entryFor "com.example.drain.example.project" "/tmp/a.plist"
                  <> ",\"other/thing\":"
                  <> entryFor "com.example.drain.other.thing" "/tmp/b.plist"
                  <> "}}"
              )
      fmap (fmap (.drainerRecordIdentifier)) (drainerRecordFromBytes "example/project" document)
        `shouldBe` Right (Just "com.example.drain.example.project")
      fmap (fmap (.drainerRecordDefinition)) (drainerRecordFromBytes "other/thing" document)
        `shouldBe` Right (Just "/tmp/b.plist")
      -- A repository with no entry is uninstalled, not malformed: it is the
      -- one failure whose repair is installing rather than reinstalling.
      drainerRecordFromBytes "third/repo" document `shouldBe` Right Nothing

    it "rejects a record that cannot name the installed job" $ do
      -- Each of these parses as JSON, or as an object, without identifying a
      -- job — so each has to be an unreadable record rather than a lookup that
      -- proceeds on a value it cannot use.
      let rejects document =
            drainerRecordFromBytes "example/project" document `shouldSatisfy` isLeft
          entry body = ByteString.pack ("{\"repositories\":{\"example/project\":" <> body <> "}}")
      rejects "[\"com.example.drain\"]"
      rejects "\"com.example.drain\""
      rejects "{\"repositories\":[]}"
      rejects (entry "[\"com.example.drain\"]")
      rejects (entry "{\"plist_path\":\"/tmp/x.plist\",\"repository\":\"/tmp/r\"}")
      rejects (entry "{\"launchd_label\":\"com.example.drain\",\"repository\":\"/tmp/r\"}")
      rejects (entry "{\"launchd_label\":\"com.example.drain\",\"plist_path\":\"/tmp/x.plist\"}")
      rejects (entry "{\"launchd_label\":42,\"plist_path\":\"/tmp/x.plist\",\"repository\":\"/tmp/r\"}")
      rejects (entry "{\"launchd_label\":\"com.example.drain\",\"plist_path\":[],\"repository\":\"/tmp/r\"}")
      rejects (recordDocument "   " "/tmp/x.plist")
      rejects (recordDocument "com.example.drain" "Library/LaunchAgents/x.plist")
      -- The systemd half of the same rules, so neither backend's entry is
      -- held to a weaker standard than the other's.
      rejects (entry "{\"backend\":\"systemd\",\"unit_path\":\"/tmp/x.service\",\"repository\":\"/tmp/r\"}")
      rejects (entry "{\"backend\":\"systemd\",\"systemd_unit\":\"x.service\",\"repository\":\"/tmp/r\"}")
      rejects (unitDocument " " "/tmp/x.service")
      rejects (unitDocument "x.service" ".config/systemd/user/x.service")

    it "fails closed on an unknown or mixed backend rather than assuming launchd" $ do
      -- Assuming launchd is the one repair that is worse than refusing: it
      -- would send `launchctl` at a host that has none, or read a unit file as
      -- a plist, and report either as the drainer's state. An entry that
      -- cannot say unambiguously which job it names sends the user back to the
      -- installer instead.
      let entry body = ByteString.pack ("{\"repositories\":{\"example/project\":" <> body <> "}}")
          message document = either id (const "unexpectedly accepted") (drainerRecordFromBytes "example/project" document)
          unknown =
            entry
              "{\"backend\":\"upstart\",\"launchd_label\":\"com.example.drain\",\
              \\"plist_path\":\"/tmp/x.plist\",\"repository\":\"/tmp/r\"}"
          launchdWithUnit =
            entry
              "{\"backend\":\"launchd\",\"launchd_label\":\"com.example.drain\",\
              \\"plist_path\":\"/tmp/x.plist\",\"unit_path\":\"/tmp/x.service\",\"repository\":\"/tmp/r\"}"
          undeclaredWithUnit =
            entry
              "{\"launchd_label\":\"com.example.drain\",\"plist_path\":\"/tmp/x.plist\",\
              \\"systemd_unit\":\"x.service\",\"repository\":\"/tmp/r\"}"
      message unknown `shouldMention` "unknown service-manager backend"
      message unknown `shouldMention` "upstart"
      message launchdWithUnit `shouldMention` "unit_path"
      message undeclaredWithUnit `shouldMention` "systemd"

    it "tells an absent backend field apart from one explicitly set to null" $ do
      -- Only *absent* is the legacy shape. A null was written by something
      -- that knew the field existed and still named no manager, so reading it
      -- as launchd would resolve a record nobody can vouch for — and the two
      -- are the same value to a decoder that asks with `.:?`.
      let entry body = ByteString.pack ("{\"repositories\":{\"example/project\":" <> body <> "}}")
          nulled =
            entry
              "{\"backend\":null,\"launchd_label\":\"com.example.drain\",\
              \\"plist_path\":\"/tmp/x.plist\",\"repository\":\"/tmp/r\"}"
          absent =
            entry
              "{\"launchd_label\":\"com.example.drain\",\
              \\"plist_path\":\"/tmp/x.plist\",\"repository\":\"/tmp/r\"}"
      fmap (fmap (.drainerRecordBackend)) (drainerRecordFromBytes "example/project" absent)
        `shouldBe` Right (Just DrainerLaunchd)
      either id (const "unexpectedly accepted") (drainerRecordFromBytes "example/project" nulled)
        `shouldMention` "backend field is null"

    it "selects the record by a case-folded identity, so one repository has one drainer" $ do
      -- GitHub owner and repository names are case-insensitive, and the
      -- controller case-folds the identity it derives its label from. A
      -- dashboard that looked up the raw spelling would report a repository
      -- spelled `Example/Project` as having no drainer at all.
      let repository = Repository "/tmp/current-project" "Example" "Project"
      normalizedRepositoryIdentity repository `shouldBe` "example/project"

    it "looks for that record where the installer fixes it, not where --install-dir moved" $
      withTemporaryCacheRoot $ \home -> do
        -- Stated rather than inherited: the `~/Library` location is the
        -- occupied one, which is the answer on macOS and on Linux alike, so
        -- what this asserts about is the override and not the host. Which
        -- location an empty host answers with is "Spec.ManagedPaths"'s.
        let recordPath = home <> "/Library/Application Support/kanban/pr-drainer/config.json"
        createDirectoryIfMissing True (takeDirectory recordPath)
        ByteString.writeFile recordPath "{}"
        withManagedRecordHome home $
          withEnvironmentValue "KANBAN_DRAINER_INSTALL_DIR" (home </> "elsewhere") $
            drainerRecordPath `shouldReturn` recordPath

    it "maps each supported host to the manager that could have installed there" $ do
      -- The only platform question this side asks, and it is about capability:
      -- macOS could have a LaunchAgent and Linux a user unit, and every other
      -- host has no backend that could have written a record at all.
      hostServiceManager "darwin" `shouldBe` Just DrainerLaunchd
      hostServiceManager "linux" `shouldBe` Just DrainerSystemd
      hostServiceManager "mingw32" `shouldBe` Nothing

    it "names the absent service manager rather than macOS on an unsupported host" $ do
      -- The refusal issue #329 replaced said "needs macOS to run", which was
      -- false the moment a systemd install existed. What is true on every
      -- unsupported host is that neither manager is there.
      outcome <-
        resolveDrainerDefinition "mingw32" "example/project" "/nonexistent/pr-drainer/config.json"
      failureFor outcome `shouldMention` "no supported service manager"
      failureFor outcome `shouldMention` "systemd"
      failureFor outcome `shouldNotMention` "is a launchd job"

    it "says the drainer is not installed when no record was written" $
      withTemporaryCacheRoot $ \root -> do
        outcome <- resolveDrainerDefinition "darwin" "example/project" (root </> "config.json")
        failureFor outcome `shouldMention` "not installed"
        failureFor outcome `shouldMention` "tools/install_drainer.py"

    it "names the repository a document with no entry for it is not installed for" $
      withTemporaryCacheRoot $ \root -> do
        -- Another repository's drainer being installed says nothing about
        -- this one, and the message has to name which repository is missing
        -- or it reads as "the drainer is broken".
        let recordPath = root </> "config.json"
        ByteString.writeFile
          recordPath
          (recordFor "other/thing" "com.example.drain" "/tmp/b.plist")
        outcome <- resolveDrainerDefinition "darwin" "example/project" recordPath
        failureFor outcome `shouldMention` "not installed for example/project"
        failureFor outcome `shouldMention` "tools/install_drainer.py"

    it "distinguishes an unreadable record from an absent one" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
        ByteString.writeFile recordPath (recordDocument "" "/tmp/x.plist")
        outcome <- resolveDrainerDefinition "darwin" "example/project" recordPath
        failureFor outcome `shouldMention` "unreadable"
        failureFor outcome `shouldMention` "tools/install_drainer.py"

    it "reports an installation predating the per-repository record" $
      withTemporaryCacheRoot $ \root -> do
        -- What a pre-#147 install actually looks like: the singleton's own
        -- keys at the top level, and no repositories table at all. That is an
        -- unmigrated installation, which the installer repairs, rather than a
        -- document this version should try to read a job out of.
        let recordPath = root </> "config.json"
        ByteString.writeFile
          recordPath
          "{\"ntfy_url\":\"https://notify.example.test/topic\",\"launchd_label\":\"com.coghex.drain-prs\",\"plist_path\":\"/tmp/x.plist\",\"repository\":\"/tmp/example-project\"}"
        outcome <- resolveDrainerDefinition "darwin" "example/project" recordPath
        failureFor outcome `shouldMention` "not installed for example/project"
        failureFor outcome `shouldMention` "tools/install_drainer.py"
        failureFor outcome `shouldNotMention` "Error in $"

    it "reports a malformed entry without Aeson's JSONPath" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
        ByteString.writeFile
          recordPath
          (ByteString.pack "{\"repositories\":{\"example/project\":{\"plist_path\":\"/tmp/x.plist\"}}}")
        outcome <- resolveDrainerDefinition "darwin" "example/project" recordPath
        failureFor outcome `shouldMention` "unreadable"
        failureFor outcome `shouldMention` "launchd_label"
        failureFor outcome `shouldNotMention` "Error in $"

    it "refuses a record describing the manager this host does not have" $
      withTemporaryCacheRoot $ \root -> do
        -- A discovery record that travelled between hosts, which is the only
        -- way this shape arises. Reading it anyway would parse a unit file as
        -- a plist and report the result as the drainer's state.
        let recordPath = root </> "config.json"
            unit = root </> "com.example.drain.service"
        ByteString.writeFile unit "[Service]\nExecStart=\"/usr/bin/python3\" \"/tmp/c.py\"\n"
        ByteString.writeFile recordPath (unitDocument "com.example.drain.service" unit)
        outcome <- resolveDrainerDefinition "darwin" "example/project" recordPath
        failureFor outcome `shouldMention` "systemd job"
        failureFor outcome `shouldMention` "launchd host"
        failureFor outcome `shouldMention` "tools/install_drainer.py"

    it "reports a stale install when the recorded definition is gone" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
            plist = root </> "com.example.drain.plist"
            unit = root </> "com.example.drain.service"
        ByteString.writeFile recordPath (recordDocument "com.example.drain" plist)
        launchd <- resolveDrainerDefinition "darwin" "example/project" recordPath
        failureFor launchd `shouldMention` "LaunchAgent is missing"
        failureFor launchd `shouldMention` "tools/install_drainer.py"
        -- The same branch on the other host names the artifact that host
        -- actually has, rather than sending a Linux user to look for a
        -- LaunchAgent.
        ByteString.writeFile recordPath (unitDocument "com.example.drain.service" unit)
        systemd <- resolveDrainerDefinition "linux" "example/project" recordPath
        failureFor systemd `shouldMention` "systemd unit is missing"
        failureFor systemd `shouldNotMention` "LaunchAgent"

    it "keeps a definition that will not parse distinct, and still names the repair" $ do
      -- The one failure the record cannot diagnose: it located the definition
      -- correctly and the file is there. The reader's own complaint is carried
      -- through, but re-running the installer rewrites that file, so this
      -- branch is no less actionable than the others.
      let message =
            unreadableDefinition
              DrainerLaunchd
              "/Users/example/Library/LaunchAgents/com.example.drain.plist"
              "Property List error: Unexpected character b at line 1"
      message `shouldMention` "com.example.drain.plist"
      message `shouldMention` "Unexpected character"
      message `shouldMention` "tools/install_drainer.py"
      message `shouldNotMention` "install record"
      unreadableDefinition DrainerSystemd "/tmp/x.service" "it declares no ExecStart"
        `shouldMention` "systemd unit"

    it "resolves the definition the record names, wherever the installer put it" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
            plist = root </> "com.example.drain.plist"
            unit = root </> "com.example.drain.service"
        ByteString.writeFile plist "<plist/>"
        ByteString.writeFile recordPath (recordDocument "com.example.drain" plist)
        resolveDrainerDefinition "darwin" "example/project" recordPath
          `shouldReturn` Right (DrainerLaunchd, plist)
        ByteString.writeFile unit "[Service]\nExecStart=\"/usr/bin/python3\"\n"
        ByteString.writeFile recordPath (unitDocument "com.example.drain.service" unit)
        resolveDrainerDefinition "linux" "example/project" recordPath
          `shouldReturn` Right (DrainerSystemd, unit)

  describe "the command a systemd unit names" $ do
    -- The systemd counterpart of reading ProgramArguments out of a plist. The
    -- unit is authoritative for what would actually run, so this has to read
    -- systemd's own quoting rather than a convenient subset of it.
    it "splits a quoted ExecStart into the exact argument vector" $
      unitExecStartArguments
        "[Service]\nType=exec\nExecStart=\"/usr/bin/python3\" \"/install dir/c.py\" \"--repo\" \"a/b\" \"run\"\nRestart=no\n"
        `shouldBe` Right ["/usr/bin/python3", "/install dir/c.py", "--repo", "a/b", "run"]

    it "reads unquoted words, escapes, and systemd's %% the way systemd does" $ do
      -- A hand-edited unit is as authoritative as a written one, so the
      -- ordinary unquoted spelling has to work; `%%` is systemd's own escape
      -- for a literal per cent, and a reader that kept it doubled would report
      -- a path that does not exist.
      unitExecStartArguments "[Service]\nExecStart=/usr/bin/python3 /tmp/c.py run\n"
        `shouldBe` Right ["/usr/bin/python3", "/tmp/c.py", "run"]
      unitExecStartArguments "[Service]\nExecStart=\"/tmp/100%%/c.py\"\n"
        `shouldBe` Right ["/tmp/100%/c.py"]
      unitExecStartArguments "[Service]\nExecStart=\"/tmp/say \\\"hi\\\"/c.py\"\n"
        `shouldBe` Right ["/tmp/say \"hi\"/c.py"]

    it "refuses a unit that names no command rather than reporting an empty one" $ do
      unitExecStartArguments "[Service]\nType=exec\nRestart=no\n"
        `shouldSatisfy` isLeft
      unitExecStartArguments "[Service]\nExecStart=\nRestart=no\n"
        `shouldSatisfy` isLeft

  describe "PR drainer status decoding" $ do
    it "replaces the definition's managed repository with the current one" $ do
      let repository = Repository "/tmp/current-project" "example" "project"
          expected =
            Right
              ( DrainerController
                  "/usr/bin/python3"
                  [ "/tmp/drain_prs_service.py",
                    "--path",
                    "/tmp/current-project",
                    "--repo",
                    "example/project"
                  ]
                  DrainerLaunchd
              )
      controllerFromProgramArguments
        DrainerLaunchd
        repository
        ["/usr/bin/python3", "/tmp/drain_prs_service.py", "run"]
        `shouldBe` expected
      controllerFromProgramArguments
        DrainerLaunchd
        repository
        ["/usr/bin/python3", "/tmp/drain_prs_service.py", "--path", "/tmp/previous-project", "run"]
        `shouldBe` expected
      -- Both bound arguments are re-supplied from this dashboard, so a plist
      -- that already carries one cannot make the command name two checkouts
      -- or two repositories.
      controllerFromProgramArguments
        DrainerLaunchd
        repository
        ["/usr/bin/python3", "/tmp/drain_prs_service.py", "--repo", "other/thing", "run"]
        `shouldBe` expected

    it "asserts the board's repository identity rather than trusting --repo" $ do
      -- `kanban --repo OWNER/NAME` bypasses remote resolution for the board,
      -- so the identity reaching the controller may name a repository this
      -- checkout is not a clone of. Passing it lets the controller — which
      -- owns the job — refuse, instead of silently selecting or creating a
      -- drainer for the other repository.
      let repository = Repository "/tmp/current-project" "Other" "Thing"
      fmap (.controllerArguments)
        ( controllerFromProgramArguments
            DrainerLaunchd
            repository
            ["/usr/bin/python3", "/tmp/drain_prs_service.py", "run"]
        )
        `shouldBe` Right
          ["/tmp/drain_prs_service.py", "--path", "/tmp/current-project", "--repo", "other/thing"]

    it "maps a running managed drainer to green/on" $ do
      let result = decodedStatus "{\"state\":\"running\",\"open_incident\":null}"
      result `shouldBe` Right (DrainerStatus DrainerOn "on" DrainerServiceRunning Nothing)
      result `shouldSatisfy` either (const False) drainerIsRunning

    it "makes a running drainer with an unresolved incident a warning" $ do
      let result = decodedStatus "{\"state\":\"running\",\"open_incident\":{\"summary\":\"prior crash\"}}"
      result `shouldBe` Right (DrainerStatus DrainerWarning "on · unresolved incident · prior crash" DrainerServiceRunning (Just "prior crash"))
      result `shouldSatisfy` either (const False) drainerIsRunning

    it "surfaces a per-pull-request merge-conflict incident on the board" $ do
      let result =
            decodedStatus
              "{\"state\":\"running\",\"open_incident\":{\"summary\":\"PR #42 has a merge conflict in README; the drainer left it unmerged.\",\"pull_request\":42,\"kind\":\"merge-conflict\"}}"
      result
        `shouldBe` Right
          ( DrainerStatus
              DrainerWarning
              "on · unresolved incident · PR #42 has a merge conflict in README; the drainer left it unmerged."
              DrainerServiceRunning
              (Just "PR #42 has a merge conflict in README; the drainer left it unmerged.")
          )
      result `shouldSatisfy` either (const False) drainerIsRunning

    it "makes a stopped drainer with an unresolved incident an error" $
      decodedStatus "{\"state\":\"stopped\",\"open_incident\":{\"summary\":\"model failed\"}}"
        `shouldBe` Right (DrainerStatus DrainerError "stopped · unresolved incident · model failed" DrainerServiceStopped (Just "model failed"))

    it "names the git operation a checkout stopped mid-operation has to finish" $ do
      let render operation =
            decodedStatus
              ( "{\"state\":\"mid_operation\",\"operation\":\""
                  <> operation
                  <> "\",\"open_incident\":null}"
              )
      render "merge" `shouldBe` Right (DrainerStatus DrainerError "merge in progress; finish or abort it" DrainerServiceBlocked Nothing)
      render "rebase" `shouldBe` Right (DrainerStatus DrainerError "rebase in progress; finish or abort it" DrainerServiceBlocked Nothing)
      render "cherry-pick" `shouldBe` Right (DrainerStatus DrainerError "cherry-pick in progress; finish or abort it" DrainerServiceBlocked Nothing)
      render "bisect" `shouldBe` Right (DrainerStatus DrainerError "bisect in progress; finish or abort it" DrainerServiceBlocked Nothing)

    it "still says something actionable when the controller names no operation" $ do
      decodedStatus "{\"state\":\"mid_operation\",\"operation\":null,\"open_incident\":null}"
        `shouldBe` Right (DrainerStatus DrainerError "unfinished git operation; finish or abort it" DrainerServiceBlocked Nothing)
      decodedStatus "{\"state\":\"mid_operation\",\"open_incident\":null}"
        `shouldBe` Right (DrainerStatus DrainerError "unfinished git operation; finish or abort it" DrainerServiceBlocked Nothing)

    it "no longer recognises the uncommitted-changes state the removed gate produced" $
      -- Ordinary uncommitted work is carried across the post-merge
      -- fast-forward by the drainer's own autostash, so a controller still
      -- reporting `dirty` is one that has had the blanket gate put back. The
      -- board must not have a rendering waiting for it.
      decodedStatus "{\"state\":\"dirty\",\"open_incident\":null}"
        `shouldBe` Right (DrainerStatus DrainerError "unknown state: dirty" DrainerServiceUnknown Nothing)

    it "no longer recognises the cross-repository state the singleton produced" $
      -- Every repository now has its own job, status file, and logs, so
      -- another repository's running drainer is invisible here rather than a
      -- warning — and a controller still reporting `foreign` is one that has
      -- had the singleton put back. The board must not have a rendering
      -- waiting for it.
      decodedStatus "{\"state\":\"foreign\",\"open_incident\":null}"
        `shouldBe` Right (DrainerStatus DrainerError "unknown state: foreign" DrainerServiceUnknown Nothing)

    it "renders a state the controller reports but this version does not know as an error" $
      decodedStatus "{\"state\":\"paused\"}"
        `shouldBe` Right (DrainerStatus DrainerError "unknown state: paused" DrainerServiceUnknown Nothing)

    it "keeps a status document the controller printed while exiting nonzero" $ do
      -- Exiting nonzero while reporting "stopped with an unresolved incident"
      -- is the natural convention for that state, and the state machine
      -- already renders it in red with the incident attached. Collapsing it
      -- to an opaque error blob would discard exactly the detail the nonzero
      -- exit is flagging.
      statusFromExit (ExitFailure 3) "{\"state\":\"stopped\",\"open_incident\":{\"summary\":\"model failed\"}}" ""
        `shouldBe` Right (DrainerStatus DrainerError "stopped · unresolved incident · model failed" DrainerServiceStopped (Just "model failed"))

    it "prefers a decodable status over diagnostics the same failing run wrote to stderr" $
      statusFromExit
        (ExitFailure 1)
        "{\"state\":\"running\",\"open_incident\":{\"summary\":\"prior crash\"}}"
        "launchctl: warning\n"
        `shouldBe` Right (DrainerStatus DrainerWarning "on · unresolved incident · prior crash" DrainerServiceRunning (Just "prior crash"))

    it "falls back to stderr when a failing run's output does not decode" $
      statusFromExit (ExitFailure 2) "not json at all\n" "  controller exploded\n"
        `shouldBe` Left "controller exploded"

    it "falls back to stdout when a failing run wrote no diagnostics" $
      statusFromExit (ExitFailure 2) "  not json at all\n" ""
        `shouldBe` Left "not json at all"

    it "still reports undecodable output from a successful run as a decode failure" $
      statusFromExit ExitSuccess "not json at all\n" ""
        `shouldSatisfy` either (Data.Text.isPrefixOf "could not decode PR drainer status") (const False)

    it "decodes the status a real controller process prints while exiting nonzero" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- The interpreter above is pure, so only an actual process proves the
        -- exit code and the stream reach it the way they are produced.
        controller <-
          fakeController
            temporaryRoot
            [ "printf '%s' '{\"state\":\"stopped\",\"open_incident\":{\"summary\":\"model failed\"}}'",
              "echo 'controller reported a failure' >&2",
              "exit 4"
            ]
        runDrainerStatus 5 controller "status"
          `shouldReturn` Right (DrainerStatus DrainerError "stopped · unresolved incident · model failed" DrainerServiceStopped (Just "model failed"))

    it "reports a failing controller's diagnostics when it printed nothing decodable" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        controller <- fakeController temporaryRoot ["echo 'launchd job is not loaded' >&2", "exit 1"]
        runDrainerStatus 5 controller "status" `shouldReturn` Left "launchd job is not loaded"

    it "leaves no survivor from a wedged controller's process group, and says the transition's outcome is unknown" $
      -- The bystander runs for the whole escalation and is shaped exactly like
      -- what the escalation is aimed at, so the snapshot below has to show the
      -- sweep reached this invocation's group and stopped there.
      withSurvivingGroupLeader $ \bystanderPid ->
        withTemporaryCacheRoot $ \temporaryRoot -> do
          let leaderFile = temporaryRoot </> "leader-pid"
              descendantFile = temporaryRoot </> "descendant-pid"
          -- Both the controller and something it started ignore TERM, and the
          -- descendant holds the inherited pipes open, so nothing about the
          -- invocation ending implies either of them stopped. `create_group`
          -- puts both in the invocation's own group; the escalation has to
          -- reach the whole group and prove it empty, not just TERM the child.
          controller <-
            fakeController
              temporaryRoot
              [ "trap '' TERM",
                "sh -c \"trap '' TERM; while :; do sleep 1; done\" &",
                ByteString.pack ("echo $! > " <> descendantFile),
                ByteString.pack ("echo $$ > " <> leaderFile),
                "while :; do sleep 1; done"
              ]
          outcome <- runDrainerStatus 3 controller "start"
          -- Taken the instant the invocation returns, so this proves the group
          -- was already empty when the timeout was reported -- not merely that
          -- it emptied by the time an assertion got around to looking.
          snapshot <- readProcessSnapshot >>= requireRight "process snapshot after the drainer timeout"
          leaderPid <- readRecordedPid leaderFile
          descendantPid <- readRecordedPid descendantFile
          descendantPid `shouldNotBe` leaderPid
          identityForPid leaderPid snapshot `shouldBe` Nothing
          identityForPid descendantPid snapshot `shouldBe` Nothing
          snapshot `shouldNotHaveSwept` bystanderPid
          message <- requireLeft "a wedged controller reported success" outcome
          message `shouldMention` "drainer start timed out after 3 seconds"
          message `shouldMention` "the outcome is unknown"
          message `shouldMention` "the next status poll will reconcile it"

    it "terminates a descendant still holding the pipes after the controller itself exits" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let descendantFile = temporaryRoot </> "orphan-pid"
        -- The controller exits promptly and cleanly; what keeps the read
        -- blocked to the timeout is the TERM-resistant descendant holding
        -- the inherited pipes open. Its leader is a zombie by then and so is
        -- absent from every process snapshot -- which is exactly why group
        -- ownership has to be established at spawn. Deciding it here instead
        -- could not tell this case apart from a pgid this process never
        -- owned, and refusing would leave the descendant running for the
        -- next ten-second poll to overlap.
        controller <-
          fakeController
            temporaryRoot
            [ "sh -c \"trap '' TERM; while :; do sleep 1; done\" &",
              ByteString.pack ("echo $! > " <> descendantFile),
              "exit 0"
            ]
        outcome <- runDrainerStatus 3 controller "status"
        snapshot <- readProcessSnapshot >>= requireRight "process snapshot after the orphaned-descendant timeout"
        descendantPid <- readRecordedPid descendantFile
        identityForPid descendantPid snapshot `shouldBe` Nothing
        message <- requireLeft "an orphaned descendant reported success" outcome
        message `shouldMention` "drainer status timed out after 3 seconds"
        -- A terminated group is a settled timeout, not a cleanup failure.
        message `shouldNotMention` "could not"
        message `shouldNotMention` "still running"

    it "terminates a replacement the controller's own TERM handler forked before exiting" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let leaderFile = temporaryRoot </> "handler-leader-pid"
            forkedFile = temporaryRoot </> "handler-forked-pid"
        -- The nastiest shape a single pass cannot settle. Escalation stops
        -- as soon as the members censused before it signalled are gone, so a
        -- TERM handler that forks a replacement and *then* exits satisfies
        -- that pass without SIGKILL ever being sent -- and the replacement,
        -- which no signal has yet reached, is left holding the group. Only a
        -- second census finds it.
        controller <-
          fakeController
            temporaryRoot
            [ "spawn_replacement() {",
              "  sh -c 'trap \"\" TERM; while :; do sleep 1; done' &",
              ByteString.pack ("  echo $! > " <> forkedFile),
              "  exit 0",
              "}",
              "trap spawn_replacement TERM",
              ByteString.pack ("echo $$ > " <> leaderFile),
              "while :; do sleep 1; done"
            ]
        outcome <- runDrainerStatus 3 controller "status"
        snapshot <- readProcessSnapshot >>= requireRight "process snapshot after the forking-handler timeout"
        leaderPid <- readRecordedPid leaderFile
        forkedPid <- readRecordedPid forkedFile
        forkedPid `shouldNotBe` leaderPid
        identityForPid leaderPid snapshot `shouldBe` Nothing
        identityForPid forkedPid snapshot `shouldBe` Nothing
        message <- requireLeft "a forking TERM handler reported success" outcome
        message `shouldMention` "drainer status timed out after 3 seconds"
        message `shouldNotMention` "still running"

    it "keeps the outcome-unknown wording generic for a timed-out status query" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- A killed status query changed nothing, so there is no transition
        -- for the poll to reconcile and nothing unknown to promise about.
        controller <- fakeController temporaryRoot ["while :; do sleep 1; done"]
        outcome <- runDrainerStatus 1 controller "status"
        message <- requireLeft "a wedged status query reported success" outcome
        message `shouldMention` "drainer status timed out after 1 seconds"
        message `shouldNotMention` "reconcile"

  describe "PR drainer toggle decisions" $ do
    it "issues no second start while a reported start is still in flight" $
      -- The status poll can report `starting` for a transition this
      -- dashboard never began, and `drainerIsRunning` calls that "not
      -- running" -- which is precisely how the toggle used to answer a start
      -- already under way with another one.
      case drainerToggle False (DrainerStatus DrainerStarting "starting…" DrainerServiceStarting Nothing) of
        DrainerToggleBusy notice -> notice `shouldBe` "PR drainer is already starting"
        decision -> expectationFailure ("a reported starting drainer produced " <> show decision)

    it "issues nothing while this dashboard's own toggle is still in flight" $
      case drainerToggle True (DrainerStatus DrainerOff "off" DrainerServiceStopped Nothing) of
        DrainerToggleBusy notice -> notice `shouldBe` "PR drainer is already starting or stopping"
        decision -> expectationFailure ("a busy toggle produced " <> show decision)

    it "starts a settled off drainer and stops a settled running one" $ do
      drainerToggle False (DrainerStatus DrainerOff "off" DrainerServiceStopped Nothing) `shouldBe` StartDrainer
      drainerToggle False (DrainerStatus DrainerOn "on" DrainerServiceRunning Nothing) `shouldBe` StopDrainer
      drainerToggle False (DrainerStatus DrainerWarning "on · unresolved incident" DrainerServiceRunning (Just "")) `shouldBe` StopDrainer
      drainerToggle False (DrainerStatus DrainerError "merge in progress; finish or abort it" DrainerServiceBlocked Nothing) `shouldBe` StartDrainer

  describe "PR drainer open incident set" $ do
    let incidents = fmap (.observedIncidents) . decodeDrainerStatus
        crash =
          "{\"incident_id\":\"incident-A\",\"kind\":\"drainer-exit\","
            <> "\"summary\":\"drain_prs.py exited unexpectedly with code 1\","
            <> "\"exit_code\":1,\"last_pr\":7,\"last_activity\":\"merging PR #7\"}"
        conflict =
          "{\"incident_id\":\"incident-B\",\"kind\":\"merge-conflict\","
            <> "\"summary\":\"PR #42 has a merge conflict in README.\",\"pull_request\":42}"

    it "decodes every open incident while leaving the newest-only sidebar projection alone" $ do
      let document =
            "{\"state\":\"running\",\"open_incident\":"
              <> crash
              <> ",\"open_incidents\":["
              <> crash
              <> ","
              <> conflict
              <> "]}"
      -- The sidebar keeps summarising exactly one incident, the newest.
      decodedStatus document
        `shouldBe` Right
          ( DrainerStatus
              DrainerWarning
              "on · unresolved incident · drain_prs.py exited unexpectedly with code 1"
              DrainerServiceRunning
              (Just "drain_prs.py exited unexpectedly with code 1")
          )
      incidents document
        `shouldBe` Right
          ( Just
              [ DrainerIncident
                  { incidentId = "incident-A",
                    incidentKind = "drainer-exit",
                    incidentSummary = Just "drain_prs.py exited unexpectedly with code 1",
                    incidentPullRequest = Nothing,
                    incidentLastPullRequest = Just 7,
                    incidentActivity = Just "merging PR #7",
                    incidentError = Nothing
                  },
                DrainerIncident
                  { incidentId = "incident-B",
                    incidentKind = "merge-conflict",
                    incidentSummary = Just "PR #42 has a merge conflict in README.",
                    incidentPullRequest = Just 42,
                    incidentLastPullRequest = Nothing,
                    incidentActivity = Nothing,
                    incidentError = Nothing
                  }
              ]
          )

    it "carries a cleanup incident's recorded failure, and distinguishes every way it can be absent" $ do
      -- The four shapes the service and its own history produce: the field
      -- present with the refusal #200 words, a document written before the
      -- field existed, an explicit null from a pass that recorded no error,
      -- and an empty string. Only the first is a failure the panel can state,
      -- and the decoder must not collapse the other three into it.
      let cleanup recorded =
            "{\"state\":\"running\",\"open_incidents\":[{\"incident_id\":\"incident-D\","
              <> "\"kind\":\"cleanup-pending\",\"pull_request\":1079,"
              <> "\"summary\":\"PR #1079 merged, but its post-merge cleanup keeps failing: "
              <> "fast-forwarding the default branch.\""
              <> recorded
              <> "}]}"
          decoded recorded =
            fmap (fmap (map (.incidentError))) (incidents (cleanup recorded))
      decoded ",\"last_error\":\"Local changes are not what blocked this. Resolve these paths and `git add` them: src/Kanban/UI.hs\""
        `shouldBe` Right
          ( Just
              [ Just
                  "Local changes are not what blocked this. Resolve these paths and \
                  \`git add` them: src/Kanban/UI.hs"
              ]
          )
      decoded "" `shouldBe` Right (Just [Nothing])
      decoded ",\"last_error\":null" `shouldBe` Right (Just [Nothing])
      decoded ",\"last_error\":\"\"" `shouldBe` Right (Just [Just ""])

    it "tells a controller that reported no incidents apart from one that reported no set" $ do
      -- The distinction the incidents panel needs: only the first of these is
      -- a verified-empty source.
      incidents "{\"state\":\"running\",\"open_incident\":null,\"open_incidents\":[]}"
        `shouldBe` Right (Just [])
      incidents "{\"state\":\"running\",\"open_incident\":null}" `shouldBe` Right Nothing

    it "classifies an incident predating the kind field as a crash, exactly as the service does" $
      incidents "{\"state\":\"stopped\",\"open_incidents\":[{\"incident_id\":\"incident-C\"}]}"
        `shouldBe` Right
          ( Just
              [ DrainerIncident
                  { incidentId = "incident-C",
                    incidentKind = "drainer-exit",
                    incidentSummary = Nothing,
                    incidentPullRequest = Nothing,
                    incidentLastPullRequest = Nothing,
                    incidentActivity = Nothing,
                    incidentError = Nothing
                  }
              ]
          )

    it "fails the whole observation on an incident that names no identity" $ do
      -- A row whose identity a refresh cannot re-find is one a keyboard or
      -- mouse action cannot be held to, so the response is refused rather
      -- than listed. The panel then reports the source as unavailable, which
      -- is the truth, instead of an incident set missing a member.
      let document = "{\"state\":\"running\",\"open_incidents\":[{\"summary\":\"nameless\"}]}"
      decodeDrainerStatus document
        `shouldSatisfy` either (Data.Text.isPrefixOf "could not decode PR drainer status") (const False)

    it "carries the incident set through a controller that exits nonzero" $
      -- The same convention the sidebar already relies on: a nonzero exit
      -- that still printed a status document is reporting state.
      fmap
        (.observedIncidents)
        ( statusFromControllerExit
            (ExitFailure 3)
            "{\"state\":\"stopped\",\"open_incidents\":[{\"incident_id\":\"incident-B\",\"kind\":\"merge-conflict\",\"pull_request\":42}]}"
            ""
        )
        `shouldBe` Right (Just [DrainerIncident "incident-B" "merge-conflict" Nothing (Just 42) Nothing Nothing Nothing])

  describe "PR drainer post-merge cleanup obligations" $ do
    let obligation number =
          "{\"pull_request\":"
            <> LazyByteString.pack (show (number :: Int))
            <> ",\"steps\":[\"fast-forwarding the default branch\"],"
            <> "\"failed_passes\":9,\"last_error\":\"exit code 1\"}"
        owing numbers =
          ",\"cleanup_obligations\":["
            <> LazyByteString.intercalate "," (map obligation numbers)
            <> "]"
        conflict =
          "{\"incident_id\":\"incident-B\",\"kind\":\"merge-conflict\","
            <> "\"summary\":\"PR #42 has a merge conflict in README.\",\"pull_request\":42}"

    it "adds a clause counting the pull requests that owe cleanup" $ do
      -- Debt alone leaves the state — and so the button's colour — exactly
      -- what the service state made it. Retrying obligations are ordinary
      -- behavior; escalation stays the open incident's job.
      decodedStatus ("{\"state\":\"stopped\"" <> owing [12] <> "}")
        `shouldBe` Right (DrainerStatus DrainerOff "off · 1 PR owes cleanup" DrainerServiceStopped Nothing)
      decodedStatus ("{\"state\":\"stopped\"" <> owing [1079, 12] <> "}")
        `shouldBe` Right (DrainerStatus DrainerOff "off · 2 PRs owe cleanup" DrainerServiceStopped Nothing)
      decodedStatus ("{\"state\":\"running\"" <> owing [1079, 12, 3] <> "}")
        `shouldBe` Right (DrainerStatus DrainerOn "on · 3 PRs owe cleanup" DrainerServiceRunning Nothing)

    it "carries the clause on every state that can owe, not only a stopped one" $ do
      -- A stop is when nothing discharges the debt, but every other state can
      -- carry it too, and none of them may hide it.
      decodedStatus ("{\"state\":\"starting\"" <> owing [12] <> "}")
        `shouldBe` Right (DrainerStatus DrainerStarting "starting… · 1 PR owes cleanup" DrainerServiceStarting Nothing)
      decodedStatus ("{\"state\":\"external\"" <> owing [12] <> "}")
        `shouldBe` Right (DrainerStatus DrainerWarning "on outside launchd · 1 PR owes cleanup" (DrainerServiceExternal "launchd") Nothing)
      decodedStatus ("{\"state\":\"mid_operation\",\"operation\":\"rebase\"" <> owing [12] <> "}")
        `shouldBe` Right (DrainerStatus DrainerError "rebase in progress; finish or abort it · 1 PR owes cleanup" DrainerServiceBlocked Nothing)

    it "follows an open incident's summary without displacing it" $
      decodedStatus ("{\"state\":\"stopped\",\"open_incident\":" <> conflict <> owing [42] <> "}")
        `shouldBe` Right
          ( DrainerStatus
              DrainerError
              "stopped · unresolved incident · PR #42 has a merge conflict in README. · 1 PR owes cleanup"
              DrainerServiceStopped
              (Just "PR #42 has a merge conflict in README.")
          )

    it "says nothing for a verified-empty projection, an unknown one, or none at all" $ do
      let settled = Right (DrainerStatus DrainerOff "off" DrainerServiceStopped Nothing)
      decodedStatus "{\"state\":\"stopped\",\"cleanup_obligations\":[]}" `shouldBe` settled
      -- Unknown: the controller could not read the drainer's queue state.
      decodedStatus "{\"state\":\"stopped\",\"cleanup_obligations\":null}" `shouldBe` settled
      -- And a controller predating the projection looks exactly as it does today.
      decodedStatus "{\"state\":\"stopped\"}" `shouldBe` settled

    it "fails the whole observation on a member that names no pull request" $
      -- The same fail-closed rule the incident set follows: a projection this
      -- side cannot read is reported as unreadable, never counted as debt.
      decodeDrainerStatus "{\"state\":\"stopped\",\"cleanup_obligations\":[{\"steps\":[]}]}"
        `shouldSatisfy` either (Data.Text.isPrefixOf "could not decode PR drainer status") (const False)

  DirectMerge.examples
  where
    -- The sidebar projection every test above this file's incident group
    -- asserts on, taken out of the whole observation.
    decodedStatus :: LazyByteString.ByteString -> Either Text DrainerStatus
    decodedStatus = fmap (.observedStatus) . decodeDrainerStatus

    statusFromExit :: ExitCode -> String -> String -> Either Text DrainerStatus
    statusFromExit exitCode output errors =
      (.observedStatus) <$> statusFromControllerExit exitCode output errors

    runDrainerStatus :: Int -> DrainerController -> String -> IO (Either Text DrainerStatus)
    runDrainerStatus seconds controller command =
      fmap (fmap (.observedStatus)) (runDrainerCommand seconds controller command)
