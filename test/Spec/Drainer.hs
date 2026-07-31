-- | The launchd-managed pull request drainer: discovering its LaunchAgent,
-- decoding its status, and deciding what a toggle does.
module Spec.Drainer (spec) where

import qualified Data.ByteString.Char8 as ByteString
import qualified Data.Text
import Kanban.Domain
import Kanban.Drainer
  ( DrainerController (..),
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
    normalizedRepositoryIdentity,
    resolveDrainerPlist,
    runDrainerCommand,
    statusFromControllerExit,
    unreadablePlist
  )
import Kanban.Process (identityForPid, readProcessSnapshot)
import Spec.Support.Env (withTemporaryCacheRoot)
import Spec.Support.Expect (isLeft, requireLeft, requireRight, shouldMention, shouldNotMention)
import Spec.Support.Process (fakeController, readRecordedPid)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = do
  describe "PR drainer LaunchAgent discovery" $ do
    let entryFor label plist =
          "{\"launchd_label\":\""
            <> label
            <> "\",\"plist_path\":\""
            <> plist
            <> "\",\"repository\":\"/tmp/example-project\"}"
        recordFor identity label plist =
          ByteString.pack
            ( "{\"ntfy_url\":\"https://notify.example.test/topic\",\"repositories\":{\""
                <> identity
                <> "\":"
                <> entryFor label plist
                <> "}}"
            )
        recordDocument = recordFor "example/project"
        failureFor = either id (\plist -> "unexpectedly resolved " <> Data.Text.pack plist)

    it "reads the label, plist path, and repository the installer recorded" $
      drainerRecordFromBytes
        "example/project"
        (recordDocument "com.example.drain" "/Users/example/Library/LaunchAgents/com.example.drain.plist")
        `shouldBe` Right
          ( Just
              ( DrainerRecord
                  "com.example.drain"
                  "/Users/example/Library/LaunchAgents/com.example.drain.plist"
                  "/tmp/example-project"
              )
          )

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
      fmap (fmap (.drainerRecordLabel)) (drainerRecordFromBytes "example/project" document)
        `shouldBe` Right (Just "com.example.drain.example.project")
      fmap (fmap (.drainerRecordPlist)) (drainerRecordFromBytes "other/thing" document)
        `shouldBe` Right (Just "/tmp/b.plist")
      -- A repository with no entry is uninstalled, not malformed: it is the
      -- one failure whose repair is installing rather than reinstalling.
      drainerRecordFromBytes "third/repo" document `shouldBe` Right Nothing

    it "rejects a record that cannot name the installed job" $ do
      -- Each of these parses as JSON, or as an object, without identifying a
      -- launchd job — so each has to be an unreadable record rather than a
      -- lookup that proceeds on a value it cannot use.
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

    it "selects the record by a case-folded identity, so one repository has one drainer" $ do
      -- GitHub owner and repository names are case-insensitive, and the
      -- controller case-folds the identity it derives its label from. A
      -- dashboard that looked up the raw spelling would report a repository
      -- spelled `Example/Project` as having no drainer at all.
      let repository = Repository "/tmp/current-project" "Example" "Project"
      normalizedRepositoryIdentity repository `shouldBe` "example/project"

    it "looks for that record where the installer fixes it, not where --install-dir moved" $ do
      recordPath <- drainerRecordPath
      Data.Text.pack recordPath
        `shouldMention` "/Library/Application Support/kanban/pr-drainer/config.json"

    it "names macOS rather than a missing /usr/bin/plutil on another host" $ do
      outcome <-
        resolveDrainerPlist "linux" "example/project" "/nonexistent/pr-drainer/config.json"
      failureFor outcome `shouldMention` "macOS"

    it "says the drainer is not installed when no record was written" $
      withTemporaryCacheRoot $ \root -> do
        outcome <- resolveDrainerPlist "darwin" "example/project" (root </> "config.json")
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
        outcome <- resolveDrainerPlist "darwin" "example/project" recordPath
        failureFor outcome `shouldMention` "not installed for example/project"
        failureFor outcome `shouldMention` "tools/install_drainer.py"

    it "distinguishes an unreadable record from an absent one" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
        ByteString.writeFile recordPath (recordDocument "" "/tmp/x.plist")
        outcome <- resolveDrainerPlist "darwin" "example/project" recordPath
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
        outcome <- resolveDrainerPlist "darwin" "example/project" recordPath
        failureFor outcome `shouldMention` "not installed for example/project"
        failureFor outcome `shouldMention` "tools/install_drainer.py"
        failureFor outcome `shouldNotMention` "Error in $"

    it "reports a malformed entry without Aeson's JSONPath" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
        ByteString.writeFile
          recordPath
          (ByteString.pack "{\"repositories\":{\"example/project\":{\"plist_path\":\"/tmp/x.plist\"}}}")
        outcome <- resolveDrainerPlist "darwin" "example/project" recordPath
        failureFor outcome `shouldMention` "unreadable"
        failureFor outcome `shouldMention` "launchd_label"
        failureFor outcome `shouldNotMention` "Error in $"

    it "reports a stale install when the recorded plist is gone" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
            plist = root </> "com.example.drain.plist"
        ByteString.writeFile recordPath (recordDocument "com.example.drain" plist)
        outcome <- resolveDrainerPlist "darwin" "example/project" recordPath
        failureFor outcome `shouldMention` "LaunchAgent is missing"
        failureFor outcome `shouldMention` "tools/install_drainer.py"

    it "keeps a plist that will not parse distinct, and still names the repair" $ do
      -- The one failure the record cannot diagnose: it located the plist
      -- correctly and the file is there. plutil's own complaint is carried
      -- through, but re-running the installer rewrites the plist, so this
      -- branch is no less actionable than the others.
      let message =
            unreadablePlist
              "/Users/example/Library/LaunchAgents/com.example.drain.plist"
              "Property List error: Unexpected character b at line 1"
      message `shouldMention` "com.example.drain.plist"
      message `shouldMention` "Unexpected character"
      message `shouldMention` "tools/install_drainer.py"
      message `shouldNotMention` "install record"

    it "resolves the plist the record names, wherever the installer put it" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
            plist = root </> "com.example.drain.plist"
        ByteString.writeFile plist "<plist/>"
        ByteString.writeFile recordPath (recordDocument "com.example.drain" plist)
        resolveDrainerPlist "darwin" "example/project" recordPath `shouldReturn` Right plist

  describe "PR drainer status decoding" $ do
    it "replaces the LaunchAgent's managed repository with the current one" $ do
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
              )
      controllerFromProgramArguments
        repository
        ["/usr/bin/python3", "/tmp/drain_prs_service.py", "run"]
        `shouldBe` expected
      controllerFromProgramArguments
        repository
        ["/usr/bin/python3", "/tmp/drain_prs_service.py", "--path", "/tmp/previous-project", "run"]
        `shouldBe` expected
      -- Both bound arguments are re-supplied from this dashboard, so a plist
      -- that already carries one cannot make the command name two checkouts
      -- or two repositories.
      controllerFromProgramArguments
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
            repository
            ["/usr/bin/python3", "/tmp/drain_prs_service.py", "run"]
        )
        `shouldBe` Right
          ["/tmp/drain_prs_service.py", "--path", "/tmp/current-project", "--repo", "other/thing"]

    it "maps a running managed drainer to green/on" $ do
      let result = decodeDrainerStatus "{\"state\":\"running\",\"open_incident\":null}"
      result `shouldBe` Right (DrainerStatus DrainerOn "on")
      result `shouldSatisfy` either (const False) drainerIsRunning

    it "makes a running drainer with an unresolved incident a warning" $ do
      let result = decodeDrainerStatus "{\"state\":\"running\",\"open_incident\":{\"summary\":\"prior crash\"}}"
      result `shouldBe` Right (DrainerStatus DrainerWarning "on · unresolved incident · prior crash")
      result `shouldSatisfy` either (const False) drainerIsRunning

    it "surfaces a per-pull-request merge-conflict incident on the board" $ do
      let result =
            decodeDrainerStatus
              "{\"state\":\"running\",\"open_incident\":{\"summary\":\"PR #42 has a merge conflict in README; the drainer left it unmerged.\",\"pull_request\":42,\"kind\":\"merge-conflict\"}}"
      result
        `shouldBe` Right
          ( DrainerStatus
              DrainerWarning
              "on · unresolved incident · PR #42 has a merge conflict in README; the drainer left it unmerged."
          )
      result `shouldSatisfy` either (const False) drainerIsRunning

    it "makes a stopped drainer with an unresolved incident an error" $
      decodeDrainerStatus "{\"state\":\"stopped\",\"open_incident\":{\"summary\":\"model failed\"}}"
        `shouldBe` Right (DrainerStatus DrainerError "stopped · unresolved incident · model failed")

    it "names the git operation a checkout stopped mid-operation has to finish" $ do
      let render operation =
            decodeDrainerStatus
              ( "{\"state\":\"mid_operation\",\"operation\":\""
                  <> operation
                  <> "\",\"open_incident\":null}"
              )
      render "merge" `shouldBe` Right (DrainerStatus DrainerError "merge in progress; finish or abort it")
      render "rebase" `shouldBe` Right (DrainerStatus DrainerError "rebase in progress; finish or abort it")
      render "cherry-pick" `shouldBe` Right (DrainerStatus DrainerError "cherry-pick in progress; finish or abort it")
      render "bisect" `shouldBe` Right (DrainerStatus DrainerError "bisect in progress; finish or abort it")

    it "still says something actionable when the controller names no operation" $ do
      decodeDrainerStatus "{\"state\":\"mid_operation\",\"operation\":null,\"open_incident\":null}"
        `shouldBe` Right (DrainerStatus DrainerError "unfinished git operation; finish or abort it")
      decodeDrainerStatus "{\"state\":\"mid_operation\",\"open_incident\":null}"
        `shouldBe` Right (DrainerStatus DrainerError "unfinished git operation; finish or abort it")

    it "no longer recognises the uncommitted-changes state the removed gate produced" $
      -- Ordinary uncommitted work is carried across the post-merge
      -- fast-forward by the drainer's own autostash, so a controller still
      -- reporting `dirty` is one that has had the blanket gate put back. The
      -- board must not have a rendering waiting for it.
      decodeDrainerStatus "{\"state\":\"dirty\",\"open_incident\":null}"
        `shouldBe` Right (DrainerStatus DrainerError "unknown state: dirty")

    it "no longer recognises the cross-repository state the singleton produced" $
      -- Every repository now has its own job, status file, and logs, so
      -- another repository's running drainer is invisible here rather than a
      -- warning — and a controller still reporting `foreign` is one that has
      -- had the singleton put back. The board must not have a rendering
      -- waiting for it.
      decodeDrainerStatus "{\"state\":\"foreign\",\"open_incident\":null}"
        `shouldBe` Right (DrainerStatus DrainerError "unknown state: foreign")

    it "renders a state the controller reports but this version does not know as an error" $
      decodeDrainerStatus "{\"state\":\"paused\"}"
        `shouldBe` Right (DrainerStatus DrainerError "unknown state: paused")

    it "keeps a status document the controller printed while exiting nonzero" $ do
      -- Exiting nonzero while reporting "stopped with an unresolved incident"
      -- is the natural convention for that state, and the state machine
      -- already renders it in red with the incident attached. Collapsing it
      -- to an opaque error blob would discard exactly the detail the nonzero
      -- exit is flagging.
      statusFromControllerExit (ExitFailure 3) "{\"state\":\"stopped\",\"open_incident\":{\"summary\":\"model failed\"}}" ""
        `shouldBe` Right (DrainerStatus DrainerError "stopped · unresolved incident · model failed")

    it "prefers a decodable status over diagnostics the same failing run wrote to stderr" $
      statusFromControllerExit
        (ExitFailure 1)
        "{\"state\":\"running\",\"open_incident\":{\"summary\":\"prior crash\"}}"
        "launchctl: warning\n"
        `shouldBe` Right (DrainerStatus DrainerWarning "on · unresolved incident · prior crash")

    it "falls back to stderr when a failing run's output does not decode" $
      statusFromControllerExit (ExitFailure 2) "not json at all\n" "  controller exploded\n"
        `shouldBe` Left "controller exploded"

    it "falls back to stdout when a failing run wrote no diagnostics" $
      statusFromControllerExit (ExitFailure 2) "  not json at all\n" ""
        `shouldBe` Left "not json at all"

    it "still reports undecodable output from a successful run as a decode failure" $
      statusFromControllerExit ExitSuccess "not json at all\n" ""
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
        runDrainerCommand 5 controller "status"
          `shouldReturn` Right (DrainerStatus DrainerError "stopped · unresolved incident · model failed")

    it "reports a failing controller's diagnostics when it printed nothing decodable" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        controller <- fakeController temporaryRoot ["echo 'launchd job is not loaded' >&2", "exit 1"]
        runDrainerCommand 5 controller "status" `shouldReturn` Left "launchd job is not loaded"

    it "leaves no survivor from a wedged controller's process group, and says the transition's outcome is unknown" $
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
        outcome <- runDrainerCommand 1 controller "start"
        -- Taken the instant the invocation returns, so this proves the group
        -- was already empty when the timeout was reported -- not merely that
        -- it emptied by the time an assertion got around to looking.
        snapshot <- readProcessSnapshot >>= requireRight "process snapshot after the drainer timeout"
        leaderPid <- readRecordedPid leaderFile
        descendantPid <- readRecordedPid descendantFile
        descendantPid `shouldNotBe` leaderPid
        identityForPid leaderPid snapshot `shouldBe` Nothing
        identityForPid descendantPid snapshot `shouldBe` Nothing
        message <- requireLeft "a wedged controller reported success" outcome
        message `shouldMention` "drainer start timed out after 1 seconds"
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
        outcome <- runDrainerCommand 1 controller "status"
        snapshot <- readProcessSnapshot >>= requireRight "process snapshot after the orphaned-descendant timeout"
        descendantPid <- readRecordedPid descendantFile
        identityForPid descendantPid snapshot `shouldBe` Nothing
        message <- requireLeft "an orphaned descendant reported success" outcome
        message `shouldMention` "drainer status timed out after 1 seconds"
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
        outcome <- runDrainerCommand 1 controller "status"
        snapshot <- readProcessSnapshot >>= requireRight "process snapshot after the forking-handler timeout"
        leaderPid <- readRecordedPid leaderFile
        forkedPid <- readRecordedPid forkedFile
        forkedPid `shouldNotBe` leaderPid
        identityForPid leaderPid snapshot `shouldBe` Nothing
        identityForPid forkedPid snapshot `shouldBe` Nothing
        message <- requireLeft "a forking TERM handler reported success" outcome
        message `shouldMention` "drainer status timed out after 1 seconds"
        message `shouldNotMention` "still running"

    it "keeps the outcome-unknown wording generic for a timed-out status query" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- A killed status query changed nothing, so there is no transition
        -- for the poll to reconcile and nothing unknown to promise about.
        controller <- fakeController temporaryRoot ["while :; do sleep 1; done"]
        outcome <- runDrainerCommand 1 controller "status"
        message <- requireLeft "a wedged status query reported success" outcome
        message `shouldMention` "drainer status timed out after 1 seconds"
        message `shouldNotMention` "reconcile"

  describe "PR drainer toggle decisions" $ do
    it "issues no second start while a reported start is still in flight" $
      -- The status poll can report `starting` for a transition this
      -- dashboard never began, and `drainerIsRunning` calls that "not
      -- running" -- which is precisely how the toggle used to answer a start
      -- already under way with another one.
      case drainerToggle False (DrainerStatus DrainerStarting "starting…") of
        DrainerToggleBusy notice -> notice `shouldBe` "PR drainer is already starting"
        decision -> expectationFailure ("a reported starting drainer produced " <> show decision)

    it "issues nothing while this dashboard's own toggle is still in flight" $
      case drainerToggle True (DrainerStatus DrainerOff "off") of
        DrainerToggleBusy notice -> notice `shouldBe` "PR drainer is already starting or stopping"
        decision -> expectationFailure ("a busy toggle produced " <> show decision)

    it "starts a settled off drainer and stops a settled running one" $ do
      drainerToggle False (DrainerStatus DrainerOff "off") `shouldBe` StartDrainer
      drainerToggle False (DrainerStatus DrainerOn "on") `shouldBe` StopDrainer
      drainerToggle False (DrainerStatus DrainerWarning "on · unresolved incident") `shouldBe` StopDrainer
      drainerToggle False (DrainerStatus DrainerError "merge in progress; finish or abort it") `shouldBe` StartDrainer
