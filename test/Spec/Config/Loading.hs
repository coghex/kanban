-- | Loading configuration and resolving the remote it names.
module Spec.Config.Loading (spec) where

import Control.Monad (forM_)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text
import qualified Data.Text.IO
import Kanban.Config
import Kanban.Domain
import Kanban.Repository
  ( RepositoryRoster (..),
    RosterEntry (..),
    resolveRepository,
    resolveRepositoryRoster,
    rosterDegradationNotices,
  )
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Expect (errorContains, isLeftText, isRight, rejectsWithGuidance, unsafeConfig)
import Spec.Support.Fixtures (fullFixtureToml)
import System.Directory (canonicalizePath, createDirectory, doesFileExist)
import System.FilePath (isAbsolute, (</>))
import System.Process (readProcessWithExitCode)
import Test.Hspec

spec :: Spec
spec = do
  scriptOwnedKeysSpec
  describe "configuration loading" $ do
    it "yields the stable defaults when no configuration file exists" $
      withTemporaryCacheRoot $ \configRoot ->
        withEnvironmentValue "XDG_CONFIG_HOME" configRoot $ do
          path <- defaultConfigPath
          doesFileExist path `shouldReturn` False
          loadRawConfig Nothing `shouldReturn` Right (defaultRawConfig, [])
          defaultRawConfig.rawCache `shouldBe` True
          defaultRawConfig.rawRemoteName `shouldBe` "origin"
          defaultRawConfig.rawWorkflow `shouldBe` defaultWorkflowConfig
          defaultRawConfig.rawLimits `shouldBe` LimitsConfig 3
          defaultRawConfig.rawTimeouts `shouldBe` TimeoutsConfig 30 10 45

    it "honors an explicit --config path pointing at a fixture" $
      withTemporaryCacheRoot $ \configRoot -> do
        let fixturePath = configRoot </> "fixture.toml"
        writeFile fixturePath "remote_name = \"upstream\"\n"
        loaded <- loadRawConfig (Just fixturePath)
        let (config, warnings) = unsafeConfig loaded
        warnings `shouldBe` []
        config.rawRemoteName `shouldBe` "upstream"

    it "resolves an explicit --config path to an absolute path so a worker spawned from a different directory still finds it" $ do
      resolveConfigPathOption Nothing `shouldReturn` Nothing
      absolutePath <- resolveConfigPathOption (Just "/already/absolute/config.toml")
      absolutePath `shouldBe` Just "/already/absolute/config.toml"
      relativeResult <- resolveConfigPathOption (Just "relative-config.toml")
      case relativeResult of
        Just resolved -> isAbsolute resolved `shouldBe` True
        Nothing -> expectationFailure "expected a resolved path"

    it "decodes a full-file fixture covering every documented key and warns on an unknown top-level key" $ do
      let (config, warnings) = unsafeConfig (decodeConfigText fullFixtureToml)
      config.rawCache `shouldBe` False
      config.rawRemoteName `shouldBe` "upstream"
      config.rawWorkflow
        `shouldBe` WorkflowConfig
          { approvalLabel = "lgtm",
            changesRequestedLabel = "needs-work",
            blockedLabels = Set.fromList ["blocked", "urgent"],
            trackerLabels = Set.fromList ["epic", "tracker"],
            additionalTrackerSectionHeadings = ["Milestones"],
            approvalMode = ApprovalByEither,
            blockingSeverity = SeverityAmber,
            problemStyleLabels = Set.fromList ["defect"],
            uiStyleLabels = Set.fromList ["interface", "input"]
          }
      config.rawLimits `shouldBe` LimitsConfig 5
      config.rawTimeouts `shouldBe` TimeoutsConfig 60 20 90
      config.rawUsage
        `shouldBe` UsageConfig
          { usageCodexCommand = Just (UsageCommandConfig ["/usr/local/bin/my-codex-usage", "--json"]),
            usageCodexEstimatedPercentPerSolveRound = Just 8,
            usageClaudeCommand = Just (UsageCommandConfig ["/usr/local/bin/my-claude-usage", "--json"]),
            usageClaudeEstimatedPercentPerSolveRound = Just 12
          }
      Map.member "coghex/kanban" config.rawRepositories `shouldBe` True
      Map.member "other/repo" config.rawRepositories `shouldBe` True
      Data.Text.concat warnings `shouldSatisfy` Data.Text.isInfixOf "unknown_top_level_key"

    it "merges a matching repository override onto the global table, leaving unset fields inherited" $ do
      let (config, _) = unsafeConfig (decodeConfigText fullFixtureToml)
          resolved = resolveConfig "coghex/kanban" config
      resolved.resolvedWorkflow.approvalLabel `shouldBe` "ship-it"
      resolved.resolvedWorkflow.changesRequestedLabel `shouldBe` "needs-work"
      resolved.resolvedLimits `shouldBe` LimitsConfig 7
      resolved.resolvedTimeouts `shouldBe` TimeoutsConfig 15 20 90
      resolved.resolvedCache `shouldBe` False
      resolved.resolvedRemoteName `shouldBe` "upstream"

    it "selects the canonical repository table whatever case the resolved identity carries" $ do
      let (config, _) = unsafeConfig (decodeConfigText fullFixtureToml)
          -- A remote such as git@github.com:Coghex/Kanban.git resolves with
          -- the clone's casing; the override key stays canonical lowercase.
          selected identity = resolveConfig identity config
      (selected "Coghex/Kanban").resolvedWorkflow.approvalLabel `shouldBe` "ship-it"
      (selected "COGHEX/KANBAN").resolvedWorkflow.approvalLabel `shouldBe` "ship-it"
      (selected "cOgHeX/kAnBaN").resolvedWorkflow.approvalLabel `shouldBe` "ship-it"
      -- Merge and precedence survive the normalized lookup unchanged.
      (selected "Coghex/Kanban").resolvedWorkflow.changesRequestedLabel `shouldBe` "needs-work"
      (selected "Coghex/Kanban").resolvedLimits `shouldBe` LimitsConfig 7
      (selected "Coghex/Kanban").resolvedTimeouts `shouldBe` TimeoutsConfig 15 20 90

    it "folds the resolved identity ASCII-only, the way tools/kanban_config.py does" $ do
      -- A Unicode fold (Data.Text.toLower here, str.lower() there) maps the
      -- KELVIN SIGN onto 'k' and would match; the two languages' full
      -- Unicode tables need not agree, so both sides fold ASCII only. A
      -- non-ASCII identity then matches no canonical key, and does not fail.
      let toml =
            "[workflow]\n"
              <> "approval_label = \"global\"\n"
              <> "[repositories.\"acme/kanban\".workflow]\n"
              <> "approval_label = \"override\"\n"
          (config, _) = unsafeConfig (decodeConfigText toml)
      (resolveConfig "acme/Kanban" config).resolvedWorkflow.approvalLabel `shouldBe` "override"
      (resolveConfig "acme/\x212Aanban" config).resolvedWorkflow.approvalLabel `shouldBe` "global"

    it "rejects a repository key that is not canonical lowercase owner/name, naming the key" $ do
      let rejects key =
            decodeConfigText ("[repositories.\"" <> key <> "\".workflow]\napproval_label = \"x\"\n")
              `shouldSatisfy` errorContains ["repositories", "\"" <> key <> "\""]
      rejects "Coghex/Kanban"
      rejects "kanban"
      rejects "/kanban"
      rejects "coghex/"
      rejects "coghex//kanban"
      rejects "coghex/kanban/extra"
      rejects "coghex/kanban.git"
      rejects "https://github.com/coghex/kanban"
      rejects "git@github.com:coghex/kanban.git"
      rejects " coghex/kanban"
      rejects "coghex/kanban "
      rejects "coghex/kan ban"
      rejects "coghex/kanban!"

    it "accepts every character the canonical repository-key grammar allows" $ do
      decodeConfigText "[repositories.\"a-c.o_1/k-n.b_2\".workflow]\napproval_label = \"x\"\n"
        `shouldSatisfy` isRight

    it "leaves an unrelated repository table without effect on a different repository's resolution" $ do
      let (config, _) = unsafeConfig (decodeConfigText fullFixtureToml)
          resolved = resolveConfig "coghex/kanban" config
      resolved.resolvedWorkflow.approvalLabel `shouldNotBe` "should-not-apply"

    it "replaces rather than extends a global array when a repository override sets it" $ do
      let toml =
            "[workflow]\n"
              <> "blocked_labels = [\"blocked\", \"urgent\"]\n"
              <> "[repositories.\"acme/widgets\".workflow]\n"
              <> "blocked_labels = [\"custom-block\"]\n"
          (config, _) = unsafeConfig (decodeConfigText toml)
          resolved = resolveConfig "acme/widgets" config
      resolved.resolvedWorkflow.blockedLabels `shouldBe` Set.fromList ["custom-block"]

    it "defaults both label-styling collections to empty, so an absent key styles nothing" $ do
      let (config, warnings) = unsafeConfig (decodeConfigText "[workflow]\napproval_label = \"lgtm\"\n")
          resolved = resolveConfig "acme/widgets" config
      warnings `shouldBe` []
      resolved.resolvedWorkflow.problemStyleLabels `shouldBe` Set.empty
      resolved.resolvedWorkflow.uiStyleLabels `shouldBe` Set.empty

    it "applies the usual override semantics to the label-styling collections" $ do
      let toml =
            "[workflow]\n"
              <> "problem_style_labels = [\"defect\"]\n"
              <> "ui_style_labels = [\"interface\"]\n"
              <> "[repositories.\"acme/widgets\".workflow]\n"
              <> "ui_style_labels = [\"widget-ui\"]\n"
          (config, _) = unsafeConfig (decodeConfigText toml)
          resolved = resolveConfig "acme/widgets" config
      -- The omitted array inherits the global value; the specified one
      -- replaces it in full rather than extending it.
      resolved.resolvedWorkflow.problemStyleLabels `shouldBe` Set.fromList ["defect"]
      resolved.resolvedWorkflow.uiStyleLabels `shouldBe` Set.fromList ["widget-ui"]

    it "rejects an empty label-styling entry the same way every other label list does" $ do
      decodeConfigText "[workflow]\nproblem_style_labels = [\"\"]\n"
        `shouldSatisfy` errorContains ["workflow", "problem_style_labels"]
      decodeConfigText "[workflow]\nui_style_labels = \"interface\"\n"
        `shouldSatisfy` errorContains ["workflow", "ui_style_labels"]

    it "fails on syntactically malformed TOML" $
      decodeConfigText "this is not [valid toml" `shouldSatisfy` isLeftText

    it "rejects each semantically invalid known value, naming the full key path" $ do
      decodeConfigText "[workflow]\napproval_label = \"\"\n" `shouldSatisfy` errorContains ["workflow", "approval_label"]
      decodeConfigText "remote_name = \"\"\n" `shouldSatisfy` errorContains ["remote_name"]
      decodeConfigText "[workflow]\napproval_mode = \"bogus\"\n" `shouldSatisfy` errorContains ["approval_mode"]
      decodeConfigText "[workflow]\nblocking_severity = \"purple\"\n" `shouldSatisfy` errorContains ["blocking_severity"]
      decodeConfigText "[limits]\nexcerpt_lines = -1\n" `shouldSatisfy` errorContains ["excerpt_lines"]
      decodeConfigText "[timeouts]\ngithub_seconds = 0\n" `shouldSatisfy` errorContains ["github_seconds"]
      decodeConfigText "[usage.codex]\ncommand = []\n" `shouldSatisfy` errorContains ["command"]
      decodeConfigText "[usage.codex]\ncommand = [\"\"]\n" `shouldSatisfy` errorContains ["command"]

    -- The estimate divides the remaining percentage, so zero has to be an
    -- error rather than a value the renderer defends against; the upper bound
    -- is what makes it a percentage of a window rather than an arbitrary
    -- number. Every rejection names the whole path, because the two providers
    -- configure the key independently and the message is the only thing that
    -- says which one was wrong.
    it "holds both providers' solve-round estimate to a 1-100 whole percentage, naming the full key path" $ do
      let rejects provider value =
            decodeConfigText
              ("[usage." <> provider <> "]\nestimated_percent_per_solve_round = " <> value <> "\n")
              `shouldSatisfy` errorContains ["usage", provider, "estimated_percent_per_solve_round"]
      mapM_
        (\provider -> mapM_ (rejects provider) ["0", "-1", "101", "7.5", "true", "\"8\""])
        ["codex", "claude"]
      decodeConfigText "[usage.codex]\nestimated_percent_per_solve_round = 1\n" `shouldSatisfy` isRight
      decodeConfigText "[usage.claude]\nestimated_percent_per_solve_round = 100\n" `shouldSatisfy` isRight

    -- The two keys are siblings rather than one nested in the other, so a
    -- provider table may carry either alone. An estimate without a command
    -- describes the built-in probe's windows.
    it "accepts each usage provider key without the other, and warns about neither" $ do
      let (estimateOnly, estimateWarnings) =
            unsafeConfig (decodeConfigText "[usage.codex]\nestimated_percent_per_solve_round = 8\n")
          (commandOnly, commandWarnings) =
            unsafeConfig (decodeConfigText "[usage.claude]\ncommand = [\"my-claude-usage\"]\n")
      estimateOnly.rawUsage.usageCodexCommand `shouldBe` Nothing
      estimateOnly.rawUsage.usageCodexEstimatedPercentPerSolveRound `shouldBe` Just 8
      commandOnly.rawUsage.usageClaudeCommand `shouldBe` Just (UsageCommandConfig ["my-claude-usage"])
      commandOnly.rawUsage.usageClaudeEstimatedPercentPerSolveRound `shouldBe` Nothing
      (estimateWarnings, commandWarnings) `shouldBe` ([], [])

    it "rejects a timeout large enough to overflow when converted to microseconds, but accepts the boundary" $ do
      let overflowingSeconds = (maxBound :: Int) `div` 1000000 + 1
          largestSafeSeconds = (maxBound :: Int) `div` 1000000
      decodeConfigText ("[timeouts]\ngithub_seconds = " <> Data.Text.pack (show overflowingSeconds) <> "\n")
        `shouldSatisfy` errorContains ["github_seconds"]
      (decodeConfigText ("[timeouts]\ngithub_seconds = " <> Data.Text.pack (show largestSafeSeconds) <> "\n"))
        `shouldSatisfy` isRight

    it "rejects the global-only keys cache, remote_name, and usage inside a repository override" $ do
      decodeConfigText "[repositories.\"a/b\"]\ncache = true\n" `shouldSatisfy` errorContains ["cache"]
      decodeConfigText "[repositories.\"a/b\"]\nremote_name = \"origin\"\n" `shouldSatisfy` errorContains ["remote_name"]
      decodeConfigText "[repositories.\"a/b\"]\n[repositories.\"a/b\".usage]\n" `shouldSatisfy` errorContains ["usage"]
    it "warns, rather than fails, on an unrecognized key while still loading" $ do
      let (_, warnings) = unsafeConfig (decodeConfigText "[workflow]\nunexpected_field = 1\n")
      Data.Text.concat warnings `shouldSatisfy` Data.Text.isInfixOf "unexpected_field"
      Data.Text.concat warnings `shouldSatisfy` Data.Text.isInfixOf "workflow"

    it "warns on a misspelled script-owned key rather than accepting it" $ do
      let (_, warnings) = unsafeConfig (decodeConfigText "[workflow]\ndirect_publication_path = [\"docs/status.md\"]\n")
      Data.Text.concat warnings `shouldSatisfy` Data.Text.isInfixOf "direct_publication_path"
      Data.Text.concat warnings `shouldSatisfy` Data.Text.isInfixOf "workflow"

    -- The open-connection caps are gone from the schema, so a file that still
    -- sets them is a file with two unknown keys in it -- warned about like any
    -- other, at either scope, and with no effect whatsoever on what the board
    -- fetches.
    it "treats the removed open-connection caps as ordinary unknown keys at both scopes" $ do
      let toml =
            "[limits]\n"
              <> "max_open_issues = 500\n"
              <> "max_open_pull_requests = 200\n"
              <> "[repositories.\"coghex/kanban\".limits]\n"
              <> "max_open_issues = 999\n"
              <> "max_open_pull_requests = 400\n"
          (config, warnings) = unsafeConfig (decodeConfigText toml)
          reported = Data.Text.concat warnings
      mapM_ (\key -> reported `shouldSatisfy` Data.Text.isInfixOf key) ["max_open_issues", "max_open_pull_requests"]
      reported `shouldSatisfy` Data.Text.isInfixOf "limits"
      reported `shouldSatisfy` Data.Text.isInfixOf "coghex/kanban"
      -- Both scopes warned and neither changed anything: the excerpt height is
      -- all that is left in the table, and it is still the default.
      config.rawLimits `shouldBe` defaultLimitsConfig
      (resolveConfig "coghex/kanban" config).resolvedLimits `shouldBe` defaultLimitsConfig

    it "rejects a global approval_label and changes_requested_label that resolve to the same label" $
      decodeConfigText "[workflow]\napproval_label = \"lgtm\"\nchanges_requested_label = \"LGTM\"\n"
        `shouldSatisfy` errorContains ["workflow.approval_label", "workflow.changes_requested_label"]

    it "rejects a configured label that collides with the reserved reviewed:revised protocol label" $ do
      decodeConfigText "[workflow]\napproval_label = \"reviewed:revised\"\n"
        `shouldSatisfy` errorContains ["approval_label", "reviewed:revised"]
      decodeConfigText "[workflow]\nchanges_requested_label = \"Reviewed:Revised\"\n"
        `shouldSatisfy` errorContains ["changes_requested_label", "reviewed:revised"]

    it "rejects a repository override whose merged labels collide, even though neither table alone does" $ do
      let toml =
            "[workflow]\n"
              <> "approval_label = \"lgtm\"\n"
              <> "changes_requested_label = \"needs-work\"\n"
              <> "[repositories.\"acme/widgets\".workflow]\n"
              <> "changes_requested_label = \"lgtm\"\n"
      decodeConfigText toml `shouldSatisfy` errorContains ["repositories.\"acme/widgets\".workflow"]

  describe "global remote resolution" $ do
    it "resolves the repository through a configured non-origin remote" $
      withTemporaryCacheRoot $ \projectRoot -> do
        _ <- readProcessWithExitCode "git" ["-C", projectRoot, "init", "--quiet"] ""
        _ <- readProcessWithExitCode "git" ["-C", projectRoot, "remote", "add", "upstream", "https://github.com/coghex/kanban.git"] ""
        result <- resolveRepository "upstream" projectRoot Nothing
        case result of
          Left message -> expectationFailure (Data.Text.unpack message)
          Right repository -> do
            repository.repositoryOwner `shouldBe` "coghex"
            repository.repositoryName `shouldBe` "kanban"

    it "fails startup rather than querying GitHub for a bare mirror's owner" $
      withTemporaryCacheRoot $ \projectRoot -> do
        _ <- readProcessWithExitCode "git" ["-C", projectRoot, "init", "--quiet"] ""
        _ <- readProcessWithExitCode "git" ["-C", projectRoot, "remote", "add", "origin", "/srv/git/team/myrepo.git"] ""
        result <- resolveRepository "origin" projectRoot Nothing
        result `shouldSatisfy` rejectsWithGuidance "/srv/git/team/myrepo.git"

    it "honors an explicit --repo value when the remote cannot be used" $
      withTemporaryCacheRoot $ \projectRoot -> do
        _ <- readProcessWithExitCode "git" ["-C", projectRoot, "init", "--quiet"] ""
        result <- resolveRepository "origin" projectRoot (Just "coghex/kanban")
        case result of
          Left message -> expectationFailure (Data.Text.unpack message)
          Right repository -> do
            repository.repositoryOwner `shouldBe` "coghex"
            repository.repositoryName `shouldBe` "kanban"

  describe "repository roster" $ do
    -- Requirement 1 and the schema-parity assertion in one place: the fixture
    -- is a tracked file rather than a literal, because the same bytes have to
    -- decode through `tools/kanban_config.py` with an empty warning list too
    -- (`tools/test_kanban_config.py`). A `path` known to one parser only would
    -- make the other warn about a documented key.
    it "decodes the shared path fixture with no warnings and carries every declared checkout" $ do
      fixture <- Data.Text.IO.readFile rosterFixturePath
      let (config, warnings) = unsafeConfig (decodeConfigText fixture)
      warnings `shouldBe` []
      configuredRepositoryPaths config
        `shouldBe` [ ("acme/widgets", "/srv/checkouts/widgets"),
                     ("other/repo", "/srv/checkouts/other")
                   ]
      -- `path` sits beside the override tables rather than replacing them.
      (resolveConfig "acme/widgets" config).resolvedWorkflow.approvalLabel `shouldBe` "ship-it"

    -- Requirement 2, and the review's clarification that the string is judged
    -- as written: nothing here expands `~`, so `~/work/repo` is a non-absolute
    -- value rather than a home-relative one.
    it "rejects a non-absolute path at load time, naming the full key path" $ do
      let rejects value =
            decodeConfigText ("[repositories.\"acme/widgets\"]\npath = " <> value <> "\n")
              `shouldSatisfy` errorContains ["repositories.\"acme/widgets\".path"]
      mapM_ rejects ["\"work/repo\"", "\"./work/repo\"", "\"../repo\"", "\"~/work/repo\"", "\"\""]
      decodeConfigText "[repositories.\"acme/widgets\"]\npath = \"/srv/checkouts/widgets\"\n"
        `shouldSatisfy` isRight

    -- Requirement 3's second half: a table that sets no `path` keeps its
    -- present meaning as an override for whichever repository the session
    -- opens, so no existing configuration gains a roster entry on upgrade.
    -- `fullFixtureToml` is exactly such a file.
    it "gives a table without a path no roster entry" $ do
      let (config, _) = unsafeConfig (decodeConfigText fullFixtureToml)
      configuredRepositoryPaths config `shouldBe` []
      Map.keys config.rawRepositories `shouldBe` ["coghex/kanban", "other/repo"]

    -- Requirement 3's first half, with the review's clarification that a valid
    -- entry is exercised against a remote differing from its key by ASCII case
    -- alone: that is one repository, so the checkout stays usable and the
    -- config key stays the identity.
    it "resolves a configured entry whose remote differs from its key only by case" $
      withTemporaryCacheRoot $ \root -> do
        checkout <- gitCheckout root "widgets" "https://github.com/Acme/Widgets.git"
        roster <- resolveRepositoryRoster "origin" [("acme/widgets", checkout)] (launchRepository root)
        canonicalCheckout <- canonicalizePath checkout
        map rosterEntryIdentity roster.rosterEntries `shouldBe` ["coghex/kanban", "acme/widgets"]
        map rosterEntryCheckout roster.rosterEntries
          `shouldBe` [Just (launchRepository root).repositoryRoot, Just canonicalCheckout]
        rosterDegradationNotices roster `shouldBe` []

    -- Requirement 5, with the review's correction that "absent" means the
    -- declared target is missing rather than the key being omitted. Requirement
    -- 6's "startup never refuses to launch" is the `Just` roster itself: this
    -- returns a roster rather than an error.
    it "keeps an entry whose path resolves to nothing, with no usable checkout" $
      withTemporaryCacheRoot $ \root -> do
        let absent = root </> "not-a-directory"
        roster <- resolveRepositoryRoster "origin" [("acme/widgets", absent)] (launchRepository root)
        map rosterEntryIdentity roster.rosterEntries `shouldBe` ["coghex/kanban", "acme/widgets"]
        map rosterEntryCheckout roster.rosterEntries
          `shouldBe` [Just (launchRepository root).repositoryRoot, Nothing]
        case rosterDegradationNotices roster of
          [notice] -> do
            notice `shouldSatisfy` Data.Text.isInfixOf "repositories.\"acme/widgets\""
            notice `shouldSatisfy` Data.Text.isInfixOf (Data.Text.pack absent)
          notices -> expectationFailure ("expected one notice, got " <> show notices)

    -- Requirement 4: the key wins. A mistyped key must not silently produce a
    -- roster member for a repository the configuration never named.
    it "keeps an entry whose checkout disagrees with its key, keyed by the key" $
      withTemporaryCacheRoot $ \root -> do
        checkout <- gitCheckout root "widgets" "https://github.com/other/repo.git"
        roster <- resolveRepositoryRoster "origin" [("acme/widgets", checkout)] (launchRepository root)
        map rosterEntryIdentity roster.rosterEntries `shouldBe` ["coghex/kanban", "acme/widgets"]
        map rosterEntryCheckout roster.rosterEntries
          `shouldBe` [Just (launchRepository root).repositoryRoot, Nothing]
        case rosterDegradationNotices roster of
          [notice] -> do
            notice `shouldSatisfy` Data.Text.isInfixOf "repositories.\"acme/widgets\""
            notice `shouldSatisfy` Data.Text.isInfixOf "other/repo"
          notices -> expectationFailure ("expected one notice, got " <> show notices)

    -- The review's clarification that the notice carries a diagnostic for
    -- every degraded identity, not merely the first one found.
    it "reports one notice fragment per degraded entry" $
      withTemporaryCacheRoot $ \root -> do
        mismatched <- gitCheckout root "widgets" "https://github.com/other/repo.git"
        let absent = root </> "not-a-directory"
        roster <-
          resolveRepositoryRoster
            "origin"
            [("acme/widgets", mismatched), ("zed/tools", absent)]
            (launchRepository root)
        map rosterEntryIdentity roster.rosterEntries
          `shouldBe` ["coghex/kanban", "acme/widgets", "zed/tools"]
        let notices = rosterDegradationNotices roster
        length notices `shouldBe` 2
        zip notices ["acme/widgets", "zed/tools"]
          `shouldSatisfy` all (\(notice, key) -> Data.Text.isInfixOf key notice)

    -- Requirement 3's "always a member" and requirement 8's unchanged session:
    -- with nothing configured the roster is exactly the launch repository.
    it "resolves to the launch repository alone when nothing is configured" $
      withTemporaryCacheRoot $ \root -> do
        configuredRepositoryPaths defaultRawConfig `shouldBe` []
        roster <- resolveRepositoryRoster "origin" [] (launchRepository root)
        roster.rosterEntries
          `shouldBe` [ RosterEntry
                         { rosterEntryIdentity = "coghex/kanban",
                           rosterEntryCheckout = Just (launchRepository root).repositoryRoot,
                           rosterEntryDiagnostic = Nothing
                         }
                     ]
        rosterDegradationNotices roster `shouldBe` []

    -- Requirement 7: the launch checkout wins, silently, and membership folds
    -- ASCII case -- a `Coghex/Kanban` clone and a `coghex/kanban` entry are one
    -- entry. The configured path is a real checkout of a different repository,
    -- so an entry resolved from it would be visible either as a second member
    -- or as a degradation notice; neither appears.
    it "gives the launch checkout the collision with its own configured entry" $
      withTemporaryCacheRoot $ \root -> do
        elsewhere <- gitCheckout root "elsewhere" "https://github.com/other/repo.git"
        let launch = (launchRepository root) {repositoryOwner = "Coghex", repositoryName = "Kanban"}
        roster <- resolveRepositoryRoster "origin" [("coghex/kanban", elsewhere)] launch
        roster.rosterEntries
          `shouldBe` [ RosterEntry
                         { rosterEntryIdentity = "Coghex/Kanban",
                           rosterEntryCheckout = Just launch.repositoryRoot,
                           rosterEntryDiagnostic = Nothing
                         }
                     ]
        rosterDegradationNotices roster `shouldBe` []

-- | The tracked fixture both configuration parsers decode, relative to the
-- repository root the suite runs from -- the same way
-- @Spec.Agent.Capture@ reaches its own fixture.
rosterFixturePath :: FilePath
rosterFixturePath = "test" </> "fixtures" </> "repository-roster.toml"

-- | A stand-in for the checkout the session was launched from. Roster
-- resolution never runs git against it: it is already resolved by the time
-- the roster is built, which is what requirement 7's collision rule rests on.
launchRepository :: FilePath -> Repository
launchRepository root =
  Repository
    { repositoryRoot = root </> "launch",
      repositoryOwner = "coghex",
      repositoryName = "kanban"
    }

-- | A temporary checkout with one @origin@ naming the given remote.
gitCheckout :: FilePath -> FilePath -> String -> IO FilePath
gitCheckout root name remote = do
  let checkout = root </> name
  createDirectory checkout
  _ <- readProcessWithExitCode "git" ["-C", checkout, "init", "--quiet"] ""
  _ <- readProcessWithExitCode "git" ["-C", checkout, "remote", "add", "origin", remote] ""
  pure checkout

-- | The keys @tools\/kanban_config.py@ owns and the application neither reads
-- nor judges, in every position they were documented.
--
-- Each case is a document carrying the key together with the same document
-- with the key taken out, so "unchanged" is a comparison rather than a claim:
-- the board keys beside the ignored one (@github_seconds@, @approval_label@)
-- are what would move if the key were mistaken for something the app reads.
-- A value is whatever the file wrote, including the ones the scripts refuse.
scriptOwnedKeysSpec :: Spec
scriptOwnedKeysSpec = describe "the keys the scripts own" $ do
  forM_ scriptOwnedCases $ \(family, ignored, kept) ->
    it ("loads quietly and unchanged with " <> family) $ do
      let (withKeys, warnings) = unsafeConfig (decodeConfigText ignored)
          (withoutKeys, _) = unsafeConfig (decodeConfigText kept)
      warnings `shouldBe` []
      withKeys `shouldBe` withoutKeys
      resolveConfig "o/n" withKeys `shouldBe` resolveConfig "o/n" withoutKeys

  -- The negative control for the examples above. "No warnings" only proves
  -- something if the same position does warn about a key the schema lacks,
  -- so each family is paired with a near miss that must be reported: an
  -- example that stopped reading warnings, or a key that began to be
  -- claimed more widely than its name, fails here.
  forM_ nearMissCases $ \(family, document, reported) ->
    it ("still warns about a near miss beside " <> family) $ do
      let (_, warnings) = unsafeConfig (decodeConfigText document)
      Data.Text.concat warnings `shouldSatisfy` Data.Text.isInfixOf reported

  it "still refuses a board key with an invalid value beside the ignored ones" $ do
    decodeConfigText "[timeouts]\ngithub_seconds = 0\nping_codex_seconds = 0\n" `shouldSatisfy` errorContains ["github_seconds"]
    decodeConfigText "[repositories.\"o/n\".timeouts]\nclaude_seconds = 0\nworker_deadline_seconds = 0\n"
      `shouldSatisfy` errorContains ["claude_seconds"]
    decodeConfigText "[workflow]\napproval_label = \"\"\ncoordination_paths = [\"\"]\n" `shouldSatisfy` errorContains ["approval_label"]

  it "still refuses the global-only keys the app does read inside a repository override" $ do
    decodeConfigText "[repositories.\"o/n\"]\ncache = false\nmissions = 1\n" `shouldSatisfy` errorContains ["cache"]

  it "still refuses malformed TOML whatever the ignored keys hold" $
    decodeConfigText "[missions]\nagent_ceiling = \n" `shouldSatisfy` isLeftText

scriptOwnedCases :: [(String, Text, Text)]
scriptOwnedCases =
  [ ( "a missions table the scripts would refuse",
      "remote_name = \"upstream\"\n[missions]\nagent_ceiling = 0\n[missions.notifications]\nenabled = true\n",
      "remote_name = \"upstream\"\n"
    ),
    ( "missions of the wrong type, and a negative and a fractional ceiling",
      "missions = 3\n",
      ""
    ),
    ( "a notification command of the wrong type",
      "[missions]\nagent_ceiling = -1\n[missions.notifications]\ncommand = 7\nenabled = \"yes\"\n",
      ""
    ),
    ( "valid ping and worker-deadline timeouts beside board timeouts",
      "[timeouts]\ngithub_seconds = 60\nping_codex_seconds = 130\nping_claude_seconds = 140\nworker_deadline_seconds = 7200\n",
      "[timeouts]\ngithub_seconds = 60\n"
    ),
    ( "out-of-range ping and worker-deadline timeouts",
      "[timeouts]\ngithub_seconds = 60\nping_codex_seconds = 0\nping_claude_seconds = -1\nworker_deadline_seconds = 604801\n",
      "[timeouts]\ngithub_seconds = 60\n"
    ),
    ( "ping and worker-deadline timeouts of the wrong type",
      "[timeouts]\ngithub_seconds = 60\nping_codex_seconds = \"soon\"\nping_claude_seconds = [1]\nworker_deadline_seconds = 1.5\n",
      "[timeouts]\ngithub_seconds = 60\n"
    ),
    ( "an overflowing ping timeout",
      "[timeouts]\nping_codex_seconds = 9223372036854775807\n",
      ""
    ),
    ( "valid coordination and direct-publication paths",
      "[workflow]\napproval_label = \"lgtm\"\ncoordination_paths = [\"docs/status.md\", \"ROADMAP.md\"]\ndirect_publication_paths = [\"docs/published.md\"]\n",
      "[workflow]\napproval_label = \"lgtm\"\n"
    ),
    ( "coordination and direct-publication paths of the wrong shape",
      "[workflow]\napproval_label = \"lgtm\"\ncoordination_paths = [\"\"]\ndirect_publication_paths = \"docs/status.md\"\n",
      "[workflow]\napproval_label = \"lgtm\"\n"
    ),
    ( "coordination and direct-publication paths holding numbers",
      "[workflow]\ncoordination_paths = [1]\ndirect_publication_paths = [true]\n",
      ""
    ),
    ( "ping and worker-deadline timeouts in a repository table",
      "[repositories.\"o/n\".timeouts]\ngithub_seconds = 15\nping_claude_seconds = 0\nworker_deadline_seconds = \"never\"\nping_codex_seconds = 150\n",
      "[repositories.\"o/n\".timeouts]\ngithub_seconds = 15\n"
    ),
    ( "coordination and direct-publication paths in a repository table",
      "[repositories.\"o/n\".workflow]\napproval_label = \"ship-it\"\ncoordination_paths = [\"\"]\ndirect_publication_paths = [\"docs/o.md\"]\n",
      "[repositories.\"o/n\".workflow]\napproval_label = \"ship-it\"\n"
    ),
    ( "a missions table inside a repository table",
      "[repositories.\"o/n\"]\npath = \"/tmp/o-n\"\n[repositories.\"o/n\".missions]\nagent_ceiling = 0\n[repositories.\"o/n\".missions.notifications]\nenabled = true\n",
      "[repositories.\"o/n\"]\npath = \"/tmp/o-n\"\n"
    ),
    ( "a scalar missions key inside a repository table",
      "[repositories.\"o/n\"]\nmissions = false\n",
      "[repositories.\"o/n\"]\n"
    )
  ]

nearMissCases :: [(String, Text, Text)]
nearMissCases =
  [ ("missions", "missionz = 1\n", "missionz"),
    ("the ping timeouts", "[timeouts]\nping_codex_second = 1\n", "ping_codex_second"),
    ("the worker deadline", "[timeouts]\nworker_deadline = 1\n", "worker_deadline"),
    ("the coordination paths", "[workflow]\ncoordination_path = []\n", "coordination_path"),
    ("the direct-publication paths", "[workflow]\ndirect_publication_path = []\n", "direct_publication_path"),
    ("a repository table's timeouts", "[repositories.\"o/n\".timeouts]\nping_claude_second = 1\n", "ping_claude_second"),
    ("a repository table's workflow", "[repositories.\"o/n\".workflow]\ncoordination_path = []\n", "coordination_path")
  ]
