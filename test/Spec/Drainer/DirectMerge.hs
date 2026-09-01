-- | Merging one Done card directly: which install the drainer is resolved
-- from, what @m@ decides for a given drainer state and selection, and how the
-- one result document that run writes is reported.
--
-- Every example here is pure or a temporary directory: no install, no
-- terminal, no network, no GitHub account. The install-record path is a
-- parameter precisely so the real one is never read or written.
module Spec.Drainer.DirectMerge (examples) where

import Data.Text (Text)
import qualified Data.Text
import Kanban.Domain
  ( BoardItem (..),
    Freshness (..),
    Label (..),
    Repository (..),
    defaultWorkflowConfig,
  )
import Kanban.Drainer
  ( DirectMergeDecision (..),
    DirectMergeEffect (..),
    DrainerActivity (..),
    DrainerBackend (..),
    DrainerController (..),
    DrainerScriptSource (..),
    DrainerState (..),
    DrainerStatus (..),
    decodeDirectMergeResult,
    directMergeArguments,
    directMergeDecision,
    directMergeEffect,
    drainerIsRunning,
    resolveSinglePullRequestDrainerAt,
    selectSinglePullRequestDrainer,
    singlePullRequestDrainerPath,
  )
import Kanban.UI.Refresh
  ( BoardRefreshDispatch (..),
    releaseQueuedBoardRefresh,
    boardRefreshDispatch,
  )
import Kanban.UI.Types (DirectMergeReport (..))
import Kanban.UI.Util
  ( directMergeNoticeFor,
    directMergeReportAfterRefresh,
    outstandingDirectMergeReport,
  )
import Spec.Support.Env (withTemporaryCacheRoot)
import Spec.Support.Expect (shouldMention, shouldNotMention)
import Spec.Support.Fixtures (baseIssue, basePullRequest)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec

examples :: Spec
examples = do
  describe "resolving the installed single-PR drainer" $ do
    let installDrainerAt directory = do
          createDirectoryIfMissing True directory
          writeFile (singlePullRequestDrainerPath directory) "#!/usr/bin/env python3\n"
          pure (singlePullRequestDrainerPath directory)
        controllerIn = controllerFor DrainerLaunchd
        controllerFor backend directory =
          DrainerController
            "/usr/bin/python3"
            [directory </> "drain_prs_service.py", "--path", "/tmp/project", "--repo", "example/project"]
            backend
        failureFor = either id (\path -> "unexpectedly resolved " <> Data.Text.pack path)

    it "prefers KANBAN_DRAINER_INSTALL_DIR over the controller's own directory" $
      withTemporaryCacheRoot $ \root -> do
        selected <- installDrainerAt (root </> "selected")
        _ <- installDrainerAt (root </> "installed")
        resolveSinglePullRequestDrainerAt
          (Just (root </> "selected"))
          (Just (controllerIn (root </> "installed")))
          (root </> "config.json")
          `shouldReturn` Right selected

    -- A blank override is how an unset variable often reaches a process
    -- through a wrapper script; treating it as a selection would resolve
    -- "/drain_prs.py".
    it "ignores a blank override rather than selecting the filesystem root" $
      withTemporaryCacheRoot $ \root -> do
        installed <- installDrainerAt (root </> "installed")
        resolveSinglePullRequestDrainerAt
          (Just "   ")
          (Just (controllerIn (root </> "installed")))
          (root </> "config.json")
          `shouldReturn` Right installed

    -- The case the environment override cannot serve: the installer supplies
    -- KANBAN_DRAINER_INSTALL_DIR to the controller it runs and to the
    -- LaunchAgent it writes, and a separately launched dashboard inherits
    -- neither. The plist still names the installed controller, so the drainer
    -- beside it is the one that job would run.
    it "derives a custom --install-dir install from the discovered controller" $
      withTemporaryCacheRoot $ \root -> do
        installed <- installDrainerAt (root </> "custom-install-dir")
        resolveSinglePullRequestDrainerAt
          Nothing
          (Just (controllerIn (root </> "custom-install-dir")))
          (root </> "config.json")
          `shouldReturn` Right installed

    it "falls back to the record's own directory when no controller was discovered" $
      withTemporaryCacheRoot $ \root -> do
        installed <- installDrainerAt root
        resolveSinglePullRequestDrainerAt Nothing Nothing (root </> "config.json")
          `shouldReturn` Right installed

    -- Each of these names a source that is present but locates no directory.
    -- Falling through to the next source would resolve a *different*
    -- installation than the one configured, and then merge with it silently,
    -- so each fails closed instead. A working install sits at the fallback
    -- location in both cases, so a resolver that fell through would pass here
    -- rather than fail.
    it "refuses a discovered controller that names no absolute installation" $
      withTemporaryCacheRoot $ \root -> do
        _ <- installDrainerAt root
        let relative =
              DrainerController "/usr/bin/python3" ["drain_prs_service.py", "--path", "/tmp/p"] DrainerLaunchd
        outcome <- resolveSinglePullRequestDrainerAt Nothing (Just relative) (root </> "config.json")
        failureFor outcome `shouldMention` "cannot be located"
        failureFor outcome `shouldMention` "tools/install_drainer.py"

    it "refuses a relative override rather than resolving it against the working directory" $
      withTemporaryCacheRoot $ \root -> do
        _ <- installDrainerAt root
        outcome <-
          resolveSinglePullRequestDrainerAt (Just "relative-install") Nothing (root </> "config.json")
        failureFor outcome `shouldMention` "not an absolute path"
        failureFor outcome `shouldMention` "KANBAN_DRAINER_INSTALL_DIR"

    it "names the source that selected a directory nothing is installed in" $
      withTemporaryCacheRoot $ \root -> do
        selection <-
          resolveSinglePullRequestDrainerAt
            (Just (root </> "empty"))
            Nothing
            (root </> "config.json")
        failureFor selection `shouldMention` "KANBAN_DRAINER_INSTALL_DIR"
        failureFor selection `shouldMention` "tools/install_drainer.py --install-dir"

    it "reports an incomplete install beside a discovered controller" $
      withTemporaryCacheRoot $ \root -> do
        selection <-
          resolveSinglePullRequestDrainerAt
            Nothing
            (Just (controllerIn (root </> "half-installed")))
            (root </> "config.json")
        failureFor selection `shouldMention` "tools/install_drainer.py"
        failureFor selection `shouldMention` "half-installed"

    it "sends an uninstalled default to the drainer installer" $
      withTemporaryCacheRoot $ \root -> do
        selection <- resolveSinglePullRequestDrainerAt Nothing Nothing (root </> "config.json")
        failureFor selection `shouldMention` "python3 tools/install_drainer.py"
        -- The remediation must not recommend the option the user did not use.
        failureFor selection `shouldNotMention` "--install-dir"

    it "records which source it selected, before asking whether anything is there" $
      withTemporaryCacheRoot $ \root -> do
        let sourceOf environment discovered path =
              fst <$> selectSinglePullRequestDrainer environment discovered path
        sourceOf (Just "/opt/kanban") Nothing (root </> "config.json")
          `shouldBe` Right (DrainerScriptFromEnvironment "/opt/kanban")
        sourceOf Nothing (Just (controllerIn "/opt/installed")) (root </> "config.json")
          `shouldBe` Right (DrainerScriptFromController DrainerLaunchd "/opt/installed")
        sourceOf Nothing Nothing (root </> "config.json")
          `shouldBe` Right (DrainerScriptFromDefault root)

  describe "what m decides for a drainer state and a selected card" $ do
    let approved = PullRequestItem (basePullRequest 42 [7] False [Label "reviewed:approve" "0E8A16"])
        unapproved = PullRequestItem (basePullRequest 43 [8] False [])
        approvedDraft = PullRequestItem (basePullRequest 44 [9] True [Label "reviewed:approve" "0E8A16"])
        issueCard = IssueItem (baseIssue 45 [])
        decide = directMergeDecision defaultWorkflowConfig
        idle = reportedStatus DrainerOff DrainerServiceStopped "off" Nothing

    it "runs the drainer's single-PR path for an approved pull request in Done" $
      decide Nothing idle (Just approved) `shouldBe` RunDirectMerge 42

    it "refuses every card that is not an approved pull request" $ do
      refusal (decide Nothing idle Nothing) `shouldMention` "no card is selected"
      refusal (decide Nothing idle (Just issueCard)) `shouldMention` "#45 is an issue"
      refusal (decide Nothing idle (Just unapproved)) `shouldMention` "PR #43 is not in Done"
      -- An approved draft is still Reviewing, exactly as the board draws it.
      refusal (decide Nothing idle (Just approvedDraft)) `shouldMention` "PR #44 is not in Done"

    -- Eligibility is answered before the service is, because what is wrong is
    -- the card: reporting the drainer's state for an issue would be a true
    -- statement about the wrong thing.
    it "answers an ineligible selection before it looks at the drainer at all" $ do
      let running = reportedStatus DrainerOn DrainerServiceRunning "on" (Just "conflict on PR #9")
      refusal (decide (Just 42) running (Just issueCard)) `shouldMention` "#45 is an issue"

    it "refuses a second m while a merge this dashboard started is running" $ do
      refusal (decide (Just 42) idle (Just approved)) `shouldMention` "PR #42 is already being merged"
      -- Another card is refused for the same reason, and names the run that
      -- is actually in flight rather than the card just pressed.
      refusal (decide (Just 42) idle (Just approved)) `shouldNotMention` "not in Done"

    it "lets an unresolved incident outrank every service state" $ do
      let incidentWhileStopped =
            reportedStatus DrainerError DrainerServiceStopped "stopped · unresolved incident · conflict" (Just "conflict on PR #9")
          incidentWhileRunning =
            reportedStatus DrainerWarning DrainerServiceRunning "on · unresolved incident · conflict" (Just "conflict on PR #9")
      refusal (decide Nothing incidentWhileStopped (Just approved)) `shouldMention` "conflict on PR #9"
      refusal (decide Nothing incidentWhileRunning (Just approved)) `shouldMention` "conflict on PR #9"

    it "still refuses an incident that carried no summary" $ do
      let summaryless = reportedStatus DrainerError DrainerServiceStopped "stopped · unresolved incident" (Just "")
      refusal (decide Nothing summaryless (Just approved)) `shouldMention` "unresolved incident"

    it "refuses every state that is not a settled stop" $ do
      let refusalFor activity detail =
            refusal (decide Nothing (reportedStatus DrainerWarning activity detail Nothing) (Just approved))
      refusalFor DrainerServiceRunning "on" `shouldMention` "running"
      refusalFor DrainerServiceStarting "starting…" `shouldMention` "starting"
      refusalFor DrainerServiceStopping "stopping…" `shouldMention` "stopping"
      refusalFor (DrainerServiceExternal "launchd") "on outside launchd" `shouldMention` "outside launchd"
      refusalFor (DrainerServiceExternal "systemd") "on outside systemd" `shouldMention` "outside systemd"
      refusalFor DrainerServiceBlocked "rebase in progress; finish or abort it" `shouldMention` "rebase in progress"

    -- The fail-closed case that matters most: a controller that could not be
    -- discovered, run, or decoded leaves the service's state unknown, and
    -- "unknown" must never be read as "off".
    it "refuses safely when no usable status was ever obtained" $ do
      let unknown = reportedStatus DrainerError DrainerServiceUnknown "unknown state: wedged" Nothing
      refusal (decide Nothing unknown (Just approved)) `shouldMention` "could not be established"
      refusal (decide Nothing unknown (Just approved)) `shouldMention` "unknown state: wedged"

  describe "the drainer status a decision reads" $ do
    it "carries the incident and the service state apart from the rendered detail" $ do
      let running = reportedStatus DrainerOn DrainerServiceRunning "on" Nothing
          external = reportedStatus DrainerWarning (DrainerServiceExternal "launchd") "on outside launchd" Nothing
          stopped = reportedStatus DrainerOff DrainerServiceStopped "off" Nothing
      -- Both readings of "a drainer is draining this repository", without the
      -- detail text having to begin with the word "on" for either to hold.
      drainerIsRunning running `shouldBe` True
      drainerIsRunning external `shouldBe` True
      drainerIsRunning stopped `shouldBe` False

  describe "invoking the single-PR path" $ do
    let repository = Repository "/Users/example/work/project" "Example" "Project"

    it "names the resolved checkout, identity and pull request" $
      directMergeArguments "/opt/kanban/drain_prs.py" repository Nothing 42
        `shouldBe` [ "/opt/kanban/drain_prs.py",
                     "--path",
                     "/Users/example/work/project",
                     "--repo",
                     "example/project",
                     "--pr",
                     "42"
                   ]

    it "forwards the active configuration when one is set" $
      directMergeArguments "/opt/kanban/drain_prs.py" repository (Just "/Users/example/kanban.toml") 42
        `shouldMentionArgument` "/Users/example/kanban.toml"

  describe "reporting what one single-PR run did" $ do
    let documentWith schema version number dryRun outcome merged reason message =
          "{\"schema\":\""
            <> schema
            <> "\",\"version\":"
            <> show version
            <> ",\"pull_request\":"
            <> show (number :: Int)
            <> ",\"outcome\":\""
            <> outcome
            <> "\",\"merged\":"
            <> jsonBool merged
            <> ",\"would_merge\":false,\"reason\":\""
            <> reason
            <> "\",\"message\":\""
            <> message
            <> "\",\"dry_run\":"
            <> jsonBool dryRun
            <> "}"
        jsonBool value = if value then "true" else "false"
        resultDocument = documentWith "drain-prs-single-pr" (1 :: Int) 42 False
        effectFor exitCode document =
          directMergeEffect 42 (decodeDirectMergeResult 42 exitCode document "")

    it "refreshes the board and says so when the pull request merged" $ do
      let effect = effectFor ExitSuccess (resultDocument "merged" True "merged" "PR #42 merged.")
      effect.directMergeRefreshesBoard `shouldBe` True
      effect.directMergeNotice `shouldMention` "PR #42 merged"

    -- The distinction the merge being irreversible forces: cleanup runs after
    -- it, so a cleanup failure must not be reported as "nothing happened",
    -- and the board is stale either way.
    it "reports a merge whose run then failed as merged and not as clean" $ do
      let effect =
            effectFor
              (ExitFailure 1)
              ( resultDocument
                  "error"
                  True
                  "post_merge_cleanup_failed"
                  "PR #42 merged; the linked issue is still open."
              )
      effect.directMergeRefreshesBoard `shouldBe` True
      effect.directMergeNotice `shouldMention` "merged, but the run did not finish cleanly"
      effect.directMergeNotice `shouldMention` "post_merge_cleanup_failed"
      effect.directMergeNotice `shouldMention` "the linked issue is still open"

    it "carries a declined run's own reason through instead of a generic one" $ do
      let effect =
            effectFor
              (ExitFailure 2)
              ( resultDocument
                  "no_action"
                  False
                  "checks_pending"
                  "PR #42 is waiting on its required checks (build-test=pending)."
              )
      effect.directMergeRefreshesBoard `shouldBe` False
      effect.directMergeNotice `shouldMention` "build-test=pending"
      effect.directMergeNotice `shouldMention` "checks_pending"

    -- A single-PR run owns stdout for its one document, so empty stdout is a
    -- start-up failure the caller must not read as "no merge happened".
    it "treats empty output as a start-up failure and quotes what the run last said" $ do
      let effect =
            directMergeEffect
              42
              (decodeDirectMergeResult 42 (ExitFailure 2) "" "starting up\ndrain_prs.py error: unrecognized arguments\n")
      effect.directMergeRefreshesBoard `shouldBe` False
      effect.directMergeNotice `shouldMention` "wrote no result"
      effect.directMergeNotice `shouldMention` "unrecognized arguments"

    it "reports output that is not the promised document without believing it" $ do
      let effect = effectFor ExitSuccess "{\"outcome\":\"merged\"}"
      effect.directMergeRefreshesBoard `shouldBe` False
      effect.directMergeNotice `shouldMention` "could not be read"

    -- The resolver runs whatever is installed at the selected path, so an
    -- answer from something that is not this contract's drainer is reachable
    -- rather than hypothetical. Every one of these carries the four outcome
    -- fields and would have been believed — and each claims a merge, which is
    -- reported to the user and refetches the board — so each has to be
    -- refused rather than partially trusted.
    it "refuses a merge reported by a document that is not the promised one" $ do
      let refused document = do
            let effect = effectFor ExitSuccess document
            effect.directMergeRefreshesBoard `shouldBe` False
            effect.directMergeNotice `shouldMention` "not the one this action asked for"
            effect.directMergeNotice `shouldMention` "tools/install_drainer.py"
            pure effect.directMergeNotice

      -- Another tool's document that happens to carry the same field names.
      wrongSchema <- refused (documentWith "some-other-tool" (1 :: Int) 42 False "merged" True "merged" "done.")
      wrongSchema `shouldMention` "some-other-tool"

      -- Both directions: an older installed drainer, and a newer one whose
      -- fields this side has never seen defined.
      old <- refused (documentWith "drain-prs-single-pr" (0 :: Int) 42 False "merged" True "merged" "done.")
      old `shouldMention` "schema version 0"
      new <- refused (documentWith "drain-prs-single-pr" (2 :: Int) 42 False "merged" True "merged" "done.")
      new `shouldMention` "schema version 2"

      -- A result for a different pull request entirely, which would otherwise
      -- report PR #42 as merged on the strength of PR #43's answer.
      other <- refused (documentWith "drain-prs-single-pr" (1 :: Int) 43 False "merged" True "merged" "done.")
      other `shouldMention` "PR #43"

      -- An outcome whose meaning this side does not know.
      unknown <- refused (documentWith "drain-prs-single-pr" (1 :: Int) 42 False "partially_merged" True "merged" "done.")
      unknown `shouldMention` "partially_merged"

      -- Self-contradictory documents, each of which resolves to a confident
      -- claim about a merge in one direction or the other.
      _ <- refused (documentWith "drain-prs-single-pr" (1 :: Int) 42 False "merged" False "merged" "done.")
      _ <- refused (documentWith "drain-prs-single-pr" (1 :: Int) 42 False "no_action" True "checks_pending" "waiting.")
      -- A dry run mutates nothing, so one cannot have merged anything.
      _ <- refused (documentWith "drain-prs-single-pr" (1 :: Int) 42 True "merged" True "merged" "done.")
      pure ()

    -- The identity fields are what the check is made of, so a document that
    -- omits one has not answered this action's question at all — and each of
    -- these still claims a merge through the fields it does carry.
    it "refuses a document that omits a field the check is made of" $
      mapM_
        ( \document -> do
            let effect = effectFor ExitSuccess document
            effect.directMergeRefreshesBoard `shouldBe` False
            effect.directMergeNotice `shouldMention` "could not be read"
        )
        [ "{\"version\":1,\"pull_request\":42,\"outcome\":\"merged\",\"merged\":true,\"reason\":\"merged\",\"message\":\"done.\",\"dry_run\":false}",
          "{\"schema\":\"drain-prs-single-pr\",\"pull_request\":42,\"outcome\":\"merged\",\"merged\":true,\"reason\":\"merged\",\"message\":\"done.\",\"dry_run\":false}",
          "{\"schema\":\"drain-prs-single-pr\",\"version\":1,\"outcome\":\"merged\",\"merged\":true,\"reason\":\"merged\",\"message\":\"done.\",\"dry_run\":false}",
          "{\"schema\":\"drain-prs-single-pr\",\"version\":1,\"pull_request\":42,\"outcome\":\"merged\",\"reason\":\"merged\",\"message\":\"done.\",\"dry_run\":false}",
          "{\"schema\":\"drain-prs-single-pr\",\"version\":1,\"pull_request\":42,\"outcome\":\"merged\",\"merged\":true,\"reason\":\"merged\",\"message\":\"done.\"}"
        ]

    it "reports a run that could not be started at all" $ do
      let effect = directMergeEffect 42 (Left "python3 was not found on PATH")
      effect.directMergeRefreshesBoard `shouldBe` False
      effect.directMergeNotice `shouldMention` "python3 was not found on PATH"

    -- The drainer's message is external text on its way to a Brick widget, so
    -- it is sanitized on exactly this boundary (docs/design.md section 11).
    it "strips terminal control sequences out of the message it presents" $ do
      let effect =
            effectFor
              (ExitFailure 2)
              (resultDocument "no_action" False "not_approved" "PR \\u001b[31m#42\\u001b[0m is not approved.")
      effect.directMergeNotice `shouldMention` "#42"
      effect.directMergeNotice `shouldNotMention` "\ESC"
      effect.directMergeNotice `shouldNotMention` "[31m"

  describe "the board refresh a completed merge requires" $ do
    -- A fetch already in flight may have read GitHub before the merge landed,
    -- so it does not satisfy a refresh the merge requires; the request is
    -- queued rather than dropped, which is what 'startBoardRefresh' alone
    -- would do.
    it "queues behind a fetch that is already running" $ do
      boardRefreshDispatch Loading False `shouldBe` QueueRefreshUntilIdle
      boardRefreshDispatch NotLoaded False `shouldBe` StartRefreshNow
      boardRefreshDispatch (Unavailable "offline") False `shouldBe` StartRefreshNow

    it "releases the queued refresh once that fetch has published" $ do
      releaseQueuedBoardRefresh True (Unavailable "offline") `shouldBe` True
      releaseQueuedBoardRefresh False (Unavailable "offline") `shouldBe` False
      -- A board still loading after a refresh published is one that failed in
      -- a way that leaves it unable to fetch at all, so the request waits
      -- rather than being spent on a call that would only be turned away.
      releaseQueuedBoardRefresh True Loading `shouldBe` False

    -- The merge is irreversible and its result is the only report of it, so
    -- the refresh that same result requires must not be what removes it from
    -- the screen. This is the whole reason a merged-and-unfinished outcome is
    -- ever readable.
    it "keeps a landed merge's result in front of the refresh it required" $ do
      let landed = "PR #42 merged, but the run did not finish cleanly (post_merge_cleanup_failed): the linked issue is still open."
          report = DirectMergeReport landed 7
          (shown, carried) = directMergeNoticeFor (Just report) "Refreshing GitHub…"
      shown `shouldMention` "post_merge_cleanup_failed"
      shown `shouldMention` "Refreshing GitHub"
      -- What it carries forward is the result itself; the instance the
      -- composed text is displayed under is stamped by whoever shows it
      -- ('Kanban.UI.Util.recordDirectMergeShown'), which is the next
      -- question's exact comparison.
      carried `shouldBe` Just report
      -- Two hops: the refresh starting, then publishing. The result stays in
      -- front of both rather than being consumed by the first.
      let (afterPublish, _) = directMergeNoticeFor carried "board updated"
      afterPublish `shouldMention` "post_merge_cleanup_failed"
      afterPublish `shouldMention` "board updated"
      -- Nothing outstanding leaves every other notice exactly as it was.
      fst (directMergeNoticeFor Nothing "Refreshing GitHub…") `shouldBe` "Refreshing GitHub…"

    -- Two dozen places clear or replace the notice — both Esc handlers, every
    -- overlay that opens, every selection move — and each means the user has
    -- stopped looking at this result. None of them names the result, so the
    -- question asked is "is what I wrote still on screen", which no future
    -- site has to know about either.
    it "stops carrying a result whose notice is gone, however it went" $ do
      let report = DirectMergeReport "PR #42 merged." 7
      -- The instance it was shown under is still displayed, so still
      -- outstanding.
      outstandingDirectMergeReport (Just 7) (Just report) `shouldBe` Just report
      -- Dismissed with Esc, from the board or from the details overlay `m`
      -- was pressed in, cleared by opening an overlay or moving the card, or
      -- expired by the ten-second lifetime: no instance is displayed at all.
      outstandingDirectMergeReport Nothing (Just report) `shouldBe` Nothing
      -- Replaced by some other action's notice instance -- including one
      -- whose text happens to repeat the report word for word, which is a
      -- different instance and must not adopt it.
      outstandingDirectMergeReport (Just 8) (Just report) `shouldBe` Nothing

    it "drops that result only once the refresh it required has run" $ do
      let carried = Just (DirectMergeReport "PR #42 merged." 7)
      -- The fetch that merely happened to be in flight publishes first; the
      -- refresh the merge required has not started, so the result survives it.
      directMergeReportAfterRefresh True carried `shouldBe` carried
      directMergeReportAfterRefresh False carried `shouldBe` Nothing

-- | A status shaped as the controller's decoder builds one, so an example
-- never has to restate the field order.
reportedStatus :: DrainerState -> DrainerActivity -> Text -> Maybe Text -> DrainerStatus
reportedStatus state activity detail incident = DrainerStatus state detail activity incident

refusal :: DirectMergeDecision -> Text
refusal (RefuseDirectMerge message) = message
refusal (RunDirectMerge number) = "unexpectedly ran a direct merge for #" <> Data.Text.pack (show number)

shouldMentionArgument :: [String] -> String -> Expectation
shouldMentionArgument arguments needle = (needle `elem` arguments) `shouldBe` True
