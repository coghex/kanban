-- | The repository snapshot cache, its private directory permissions, pull
-- request status, cache precedence, and configured values reaching their
-- runtime consumers.
module Spec.Data.Cache (spec) where

import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import qualified Data.Map.Strict as Map
import qualified Data.Text
import Data.Time (addUTCTime)
import Kanban.CLI (Options (..))
import Kanban.Cache
  ( CacheLoad (..),
    UsageCacheLoad (..),
    loadRepositoryCache,
    loadUsageCache,
    repositoryCachePath,
    repositoryCacheSchemaVersion,
    usageCachePath,
    writeRepositoryCache,
    writeUsageCache
  )
import Kanban.Config
import Kanban.Domain
import Kanban.Settings (ChatVerbosity (..), Settings (..), saveSettings, settingsPath)
import Kanban.Transcript (closeSessionLog, openSessionLog, transcriptRoot)
import Kanban.UI
  ( approvedAttr,
    approvedInteriorAttr,
    cacheEnabled,
    cardExcerptLimit,
    cardInteriorAttribute,
    claudeRefreshTimeoutMicros,
    codexRefreshTimeoutMicros,
    githubRefreshTimeoutMicros,
    neutralAttr,
    pendingAttr,
    problemAttr,
    pullRequestCardAttribute,
    readyAttr
  )
import Kanban.Workflow (CardStatus (..), deriveBoard, entryItem, isProblem, pullRequestStatus)
import Spec.Support.Env
  ( permissionsOf,
    withEnvironmentValue,
    withFileCreationMask,
    withTemporaryCacheRoot
  )
import Spec.Support.Expect (isInvalidCache, isInvalidUsageCache)
import Spec.Support.Fixtures
  ( baseIssue,
    basePullRequest,
    epoch,
    itemNumber,
    testOptions,
    testResolvedConfig
  )
import Spec.Support.Json (versionThreeCacheFile, versionTwoCacheFile)
import System.Directory (createDirectory, createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.Posix.Files (setFileMode)
import Test.Hspec

spec :: Spec
spec = do
  describe "repository snapshot cache" $ do
    it "round-trips a versioned snapshot and ignores corrupt JSON" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
              snapshot = RepoSnapshot [baseIssue 7 []] [] epoch False False
          writeRepositoryCache repository snapshot `shouldReturn` Right ()
          loadRepositoryCache repository `shouldReturn` CacheLoaded snapshot
          cachePath <- repositoryCachePath repository
          LazyByteString.writeFile cachePath "not JSON"
          invalid <- loadRepositoryCache repository
          invalid `shouldSatisfy` isInvalidCache

    it "round-trips the retained per-check detail" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
              pullRequest =
                (basePullRequest 823 [36] False [])
                  { pullRequestChecks =
                      ChecksFailed 9 12 [CheckDetail "integration-suite" CheckFailed, CheckDetail "docs-lint" CheckPending]
                  }
              snapshot = RepoSnapshot [] [pullRequest] epoch False False
          writeRepositoryCache repository snapshot `shouldReturn` Right ()
          loadRepositoryCache repository `shouldReturn` CacheLoaded snapshot

    -- A card restored from cache has to keep saying what it does not know.
    -- Reloading one with its gaps dropped would put back the amber marker's
    -- absence and the definite "unassigned" the live decode refused.
    it "round-trips the per-item data gaps" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
              issue = (baseIssue 41 []) {issueDataGaps = [AssigneesUnavailable]}
              pullRequest =
                (basePullRequest 823 [] False [])
                  {pullRequestDataGaps = [LabelsUnavailable, ChecksUndecodable]}
              snapshot = RepoSnapshot [issue] [pullRequest] epoch False False
          writeRepositoryCache repository snapshot `shouldReturn` Right ()
          loadRepositoryCache repository `shouldReturn` CacheLoaded snapshot

    -- §16: an unknown version is absent, not corruption. Meeting a file
    -- written by another version of the binary is the expected outcome of an
    -- upgrade or a downgrade, so it must start up exactly as it would with no
    -- cache at all -- no warning, nothing for the user to act on.
    it "treats a future schema version as absent rather than as corruption" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
          writeRepositoryCache repository (RepoSnapshot [] [] epoch False False) `shouldReturn` Right ()
          cachePath <- repositoryCachePath repository
          ByteString.writeFile cachePath (versionThreeCacheFile 999)
          loadRepositoryCache repository `shouldReturn` CacheAbsent

    -- Version 3 knew nothing of those gaps, so reusing one of its entries
    -- would restore a card as though every field had arrived.
    it "treats a genuine version 3 file as absent rather than as malformed" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
          writeRepositoryCache repository (RepoSnapshot [] [] epoch False False) `shouldReturn` Right ()
          cachePath <- repositoryCachePath repository
          ByteString.writeFile cachePath (versionThreeCacheFile 3)
          loadRepositoryCache repository `shouldReturn` CacheAbsent
          -- The version gate, not the decoder, is what turned it away:
          -- relabelled as current, the same file fails on its missing gap
          -- fields and keeps the warning a real corruption earns.
          ByteString.writeFile cachePath (versionThreeCacheFile repositoryCacheSchemaVersion)
          relabeled <- loadRepositoryCache repository
          relabeled `shouldSatisfy` isInvalidCache

    -- A real version 2 file wrote its check summaries as two aggregate counts,
    -- so its snapshot cannot decode under the current schema at all. The
    -- version has to be read before the snapshot, or the user is told the file
    -- is malformed JSON when the truthful answer is that it is simply old.
    it "treats a genuine version 2 file as absent rather than as malformed" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
          -- Write a current cache first, so the old file lands where the
          -- loader looks for it.
          writeRepositoryCache repository (RepoSnapshot [] [] epoch False False) `shouldReturn` Right ()
          cachePath <- repositoryCachePath repository
          ByteString.writeFile cachePath (versionTwoCacheFile 2)
          loadRepositoryCache repository `shouldReturn` CacheAbsent
          -- Proof the version gate is what turned it away: relabel that same
          -- old-shaped file as current, and the snapshot decode fails instead.
          ByteString.writeFile cachePath (versionTwoCacheFile repositoryCacheSchemaVersion)
          relabeled <- loadRepositoryCache repository
          relabeled `shouldSatisfy` isInvalidCache

    -- Only a version is silent. A file with no integer version to read is not
    -- "from another release", it is unreadable, and still warns.
    it "keeps warning for a file with no usable schema version" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
          writeRepositoryCache repository (RepoSnapshot [] [] epoch False False) `shouldReturn` Right ()
          cachePath <- repositoryCachePath repository
          ByteString.writeFile cachePath "{\"repositoryKey\":\"coghex/kanban\",\"snapshot\":{}}"
          missing <- loadRepositoryCache repository
          missing `shouldSatisfy` isInvalidCache
          ByteString.writeFile cachePath "{\"schemaVersion\":\"four\",\"repositoryKey\":\"coghex/kanban\"}"
          notAnInteger <- loadRepositoryCache repository
          notAnInteger `shouldSatisfy` isInvalidCache

    -- A recognised version that names someone else's repository is a real
    -- mix-up rather than a version skew, so it keeps the warning.
    it "still reports a recognised-version file belonging to another repository as invalid" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let mine = Repository "/tmp/project" "coghex" "kanban"
              theirs = Repository "/tmp/other" "coghex" "other"
          writeRepositoryCache mine (RepoSnapshot [] [] epoch False False) `shouldReturn` Right ()
          minePath <- repositoryCachePath mine
          theirsPath <- repositoryCachePath theirs
          ByteString.readFile minePath >>= ByteString.writeFile theirsPath
          loadRepositoryCache theirs `shouldReturn` CacheInvalid "cache ignored: repository identity mismatch"

    it "round-trips global usage snapshots" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let codexUsage = UsageSnapshot [UsageWindow "week" 77 epoch] epoch
              claudeUsage = UsageSnapshot [UsageWindow "5 hour" 65 epoch] epoch
              snapshots = Map.fromList [(Codex, codexUsage), (Claude, claudeUsage)]
          writeUsageCache snapshots `shouldReturn` Right ()
          loadUsageCache `shouldReturn` UsageCacheLoaded snapshots

    -- The usage cache follows the same policy, and needs the same
    -- version-before-payload order to do so: its snapshots are decoded from a
    -- shape that a future version is free to change.
    it "treats an unknown usage schema version as absent, whatever its payload looks like" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          writeUsageCache (Map.fromList [(Codex, UsageSnapshot [UsageWindow "week" 77 epoch] epoch)]) `shouldReturn` Right ()
          path <- usageCachePath
          ByteString.writeFile path "{\"schemaVersion\":999,\"snapshots\":\"whatever this came to mean\"}"
          loadUsageCache `shouldReturn` UsageCacheAbsent
          -- Relabelled as current, that same payload is a genuine decode
          -- failure -- so the version, not the decoder, produced the silence.
          ByteString.writeFile path "{\"schemaVersion\":1,\"snapshots\":\"whatever this came to mean\"}"
          relabeled <- loadUsageCache
          relabeled `shouldSatisfy` isInvalidUsageCache

    it "keeps warning for a corrupt or version-less usage cache" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          writeUsageCache Map.empty `shouldReturn` Right ()
          path <- usageCachePath
          ByteString.writeFile path "not JSON"
          corrupt <- loadUsageCache
          corrupt `shouldSatisfy` isInvalidUsageCache
          ByteString.writeFile path "{\"snapshots\":{}}"
          missing <- loadUsageCache
          missing `shouldSatisfy` isInvalidUsageCache

  -- 'createDirectoryIfMissing' gives a parent it creates the process umask,
  -- so chmodding only the leaf left ~/.cache/kanban at whatever mode the
  -- writer that happened to run first was given -- and the cache holds issue
  -- and pull request bodies from private repositories.
  describe "private state directory permissions" $ do
    it "creates every cache level it owns as 0700 under a permissive umask, and leaves the XDG root alone" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let xdgRoot = temporaryRoot </> "cache"
            repository = Repository "/tmp/project" "coghex" "kanban"
        createDirectory xdgRoot
        setFileMode xdgRoot 0o755
        withEnvironmentValue "XDG_CACHE_HOME" xdgRoot $
          withFileCreationMask 0o000 $ do
            writeRepositoryCache repository (RepoSnapshot [] [] epoch False False) `shouldReturn` Right ()
            cachePath <- repositoryCachePath repository
            permissionsOf (xdgRoot </> "kanban") `shouldReturn` 0o700
            permissionsOf (takeDirectory cachePath) `shouldReturn` 0o700
            permissionsOf cachePath `shouldReturn` 0o600
            permissionsOf xdgRoot `shouldReturn` 0o755

    -- The transcript root is three levels deep, so the intermediate "logs"
    -- directory is one no writer ever chmodded; here both it and a kanban
    -- directory an earlier version left loose are tightened.
    it "tightens intermediate levels an earlier writer left loose" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let xdgRoot = temporaryRoot </> "cache"
            repository = Repository "/tmp/project" "coghex" "kanban"
        createDirectory xdgRoot
        setFileMode xdgRoot 0o755
        createDirectoryIfMissing True (xdgRoot </> "kanban" </> "logs")
        setFileMode (xdgRoot </> "kanban") 0o755
        setFileMode (xdgRoot </> "kanban" </> "logs") 0o755
        withEnvironmentValue "XDG_CACHE_HOME" xdgRoot $
          withFileCreationMask 0o000 $ do
            opened <- openSessionLog repository "solve-claude" 45 Nothing
            case opened of
              Left message -> expectationFailure (Data.Text.unpack message)
              Right sessionLog -> closeSessionLog sessionLog
            logsRoot <- transcriptRoot repository
            permissionsOf (xdgRoot </> "kanban") `shouldReturn` 0o700
            permissionsOf (xdgRoot </> "kanban" </> "logs") `shouldReturn` 0o700
            permissionsOf logsRoot `shouldReturn` 0o700
            permissionsOf xdgRoot `shouldReturn` 0o755

    it "creates the config level it owns as 0700 under a permissive umask" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let xdgRoot = temporaryRoot </> "config"
        createDirectory xdgRoot
        setFileMode xdgRoot 0o755
        withEnvironmentValue "XDG_CONFIG_HOME" xdgRoot $
          withFileCreationMask 0o000 $ do
            saveSettings (Settings FullChat) `shouldReturn` Right ()
            path <- settingsPath
            permissionsOf (xdgRoot </> "kanban") `shouldReturn` 0o700
            permissionsOf path `shouldReturn` 0o600
            permissionsOf xdgRoot `shouldReturn` 0o755

  describe "pull request status" $ do
    it "makes conflicts red even when approved and CI passed" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeConflicting, pullRequestChecks = ChecksPassed 4}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusProblem "merge conflict"
    it "makes clean approved pull requests green when CI passed" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeClean, pullRequestChecks = ChecksPassed 4}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusReady

    -- issue #48: approved + BEHIND must report checks-pending before
    -- merge-pending whenever checks are not yet ready, since a still-running
    -- check is more actionable information than a stale branch.
    it "reports checks-pending before merge-pending when approved, behind, and checks are still pending" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeBehind, pullRequestChecks = ChecksPending 1 2 [CheckDetail "build" CheckPending]}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusPending "checks pending"
    it "reports merge-pending once approved, behind, and checks have already passed" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeBehind, pullRequestChecks = ChecksPassed 4}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusPending "merge pending"

    it "defaults blocking severity to red, preserving the existing problem presentation" $ do
      let pullRequest = basePullRequest 10 [] False [Label "reviewed:changes" "ff0000"]
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusProblem "blocked"
      isProblem defaultWorkflowConfig (PullRequestItem pullRequest) `shouldBe` True
    it "renders and sorts a configured amber blocking severity as pending rather than a problem" $ do
      let config = defaultWorkflowConfig {blockingSeverity = SeverityAmber}
          pullRequest = basePullRequest 10 [] False [Label "reviewed:changes" "ff0000"]
      pullRequestStatus config pullRequest `shouldBe` StatusPending "blocked"
      isProblem config (PullRequestItem pullRequest) `shouldBe` False

    it "reorders standalone board entries when amber blocking severity drops a blocked PR out of the problem bucket" $ do
      let blocked = (basePullRequest 10 [] False [Label "reviewed:changes" "ff0000"]) {pullRequestCreatedAt = addUTCTime 3600 epoch}
          neutral = basePullRequest 11 [] False []
          snapshot = RepoSnapshot [] [blocked, neutral] epoch False False
          Board redColumns = deriveBoard defaultWorkflowConfig snapshot
          amberConfig = defaultWorkflowConfig {blockingSeverity = SeverityAmber}
          Board amberColumns = deriveBoard amberConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing redColumns) `shouldBe` [10, 11]
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing amberColumns) `shouldBe` [11, 10]

    it "reorders tracker groups when amber blocking severity drops a blocked child PR out of the problem bucket" $ do
      let blockedTracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #1 — A1: Child",
                issueCreatedAt = addUTCTime 3600 epoch
              }
          neutralTracker =
            (baseIssue 200 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #2 — A1: Child",
                issueCreatedAt = epoch
              }
          blockedPr = basePullRequest 10 [1] False [Label "reviewed:changes" "ff0000"]
          neutralPr = basePullRequest 11 [2] False []
          snapshot = RepoSnapshot [blockedTracker, neutralTracker, baseIssue 1 [], baseIssue 2 []] [blockedPr, neutralPr] epoch False False
          Board redColumns = deriveBoard defaultWorkflowConfig snapshot
          amberConfig = defaultWorkflowConfig {blockingSeverity = SeverityAmber}
          Board amberColumns = deriveBoard amberConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing redColumns) `shouldBe` [10, 11]
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing amberColumns) `shouldBe` [11, 10]

    it "leaves an unapproved PR with pending checks neutral rather than showing checks-pending" $ do
      let pullRequest = (basePullRequest 10 [] False []) {pullRequestChecks = ChecksPending 1 2 [CheckDetail "build" CheckPending]}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusNeutral

    it "renders an approved, amber-blocked PR's card as pending rather than approved" $ do
      let amberConfig = defaultWorkflowConfig {blockingSeverity = SeverityAmber}
          pullRequest = basePullRequest 10 [] False [Label "reviewed:approve" "00ff00", Label "reviewed:changes" "ff0000"]
      pullRequestCardAttribute amberConfig pullRequest `shouldBe` pendingAttr
      pullRequestCardAttribute amberConfig pullRequest `shouldNotBe` approvedAttr
      cardInteriorAttribute (pullRequestCardAttribute amberConfig pullRequest) `shouldBe` neutralAttr

    it "renders a fully ready, approved PR's card as ready with an approved interior wash" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeClean, pullRequestChecks = ChecksPassed 4}
      pullRequestCardAttribute defaultWorkflowConfig pullRequest `shouldBe` readyAttr
      cardInteriorAttribute (pullRequestCardAttribute defaultWorkflowConfig pullRequest) `shouldBe` approvedInteriorAttr

    it "keeps a red-severity blocked PR's card as a problem, with a neutral interior" $ do
      let pullRequest = basePullRequest 10 [] False [Label "reviewed:approve" "00ff00", Label "reviewed:changes" "ff0000"]
      pullRequestCardAttribute defaultWorkflowConfig pullRequest `shouldBe` problemAttr
      cardInteriorAttribute (pullRequestCardAttribute defaultWorkflowConfig pullRequest) `shouldBe` neutralAttr

    it "confines configurable blocking severity to pull requests, leaving blocked-issue treatment unchanged" $ do
      let issue = (baseIssue 10 []) {issueLabels = [Label "blocked" "d73a4a"]}
      isProblem defaultWorkflowConfig (IssueItem issue) `shouldBe` True
      isProblem (defaultWorkflowConfig {blockingSeverity = SeverityAmber}) (IssueItem issue) `shouldBe` True

    it "reports merge-pending, not checks-pending, when checks are unknown rather than a known pending state" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeBehind, pullRequestChecks = ChecksUnknown}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusPending "merge pending"

    it "lets a configured approval label change Done-column membership" $ do
      let config = defaultWorkflowConfig {approvalLabel = "lgtm"}
          pullRequest = basePullRequest 10 [] False [Label "lgtm" "00ff00"]
          snapshot = RepoSnapshot [] [pullRequest] epoch False False
          Board customColumns = deriveBoard config snapshot
          Board defaultColumns = deriveBoard defaultWorkflowConfig snapshot
      map itemNumber (map entryItem (Map.findWithDefault [] Done customColumns)) `shouldBe` [10]
      map itemNumber (map entryItem (Map.findWithDefault [] Done defaultColumns)) `shouldBe` []

  describe "cache precedence" $ do
    it "lets --no-cache disable the cache even when configuration enables it" $
      cacheEnabled (testOptions {optionNoCache = True}) (testResolvedConfig {resolvedCache = True}) `shouldBe` False
    it "lets configuration disable the cache without --no-cache" $
      cacheEnabled (testOptions {optionNoCache = False}) (testResolvedConfig {resolvedCache = False}) `shouldBe` False
    it "enables the cache only when neither --no-cache nor configuration disables it" $
      cacheEnabled (testOptions {optionNoCache = False}) (testResolvedConfig {resolvedCache = True}) `shouldBe` True

  describe "configured provider timeouts and excerpt height reaching their runtime consumers" $ do
    it "converts the configured GitHub timeout from seconds to the microseconds System.Timeout.timeout takes" $
      githubRefreshTimeoutMicros (testResolvedConfig {resolvedTimeouts = TimeoutsConfig 5 7 9}) `shouldBe` 5000000
    it "converts the configured Codex timeout from seconds to microseconds" $
      codexRefreshTimeoutMicros (testResolvedConfig {resolvedTimeouts = TimeoutsConfig 5 7 9}) `shouldBe` 7000000
    it "converts the configured Claude timeout from seconds to microseconds" $
      claudeRefreshTimeoutMicros (testResolvedConfig {resolvedTimeouts = TimeoutsConfig 5 7 9}) `shouldBe` 9000000
    it "passes the configured excerpt line count through to the card-rendering limit" $ do
      cardExcerptLimit (testResolvedConfig {resolvedLimits = LimitsConfig 250 100 3}) `shouldBe` 3
      cardExcerptLimit (testResolvedConfig {resolvedLimits = LimitsConfig 250 100 9}) `shouldBe` 9
