module Main (main) where

import Control.Exception (bracket)
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text
import Data.Time (UTCTime (..), fromGregorian, minutesToTimeZone, secondsToDiffTime)
import Kanban.Cache
  ( CacheLoad (..),
    UsageCacheLoad (..),
    loadRepositoryCache,
    loadUsageCache,
    repositoryCachePath,
    writeRepositoryCache,
    writeUsageCache,
  )
import Kanban.Claude (decodeClaudeUsageText)
import Kanban.Codex (decodeCodexUsageResponse)
import Kanban.Domain
import Kanban.GitHub (decodeGitHubItems)
import Kanban.Layout (responsiveColumnWidths, responsiveOpenColumnWidths)
import Kanban.Repository (parseRepositoryName)
import Kanban.Text (excerpt, sanitizeText)
import Kanban.Tracker (implementationSortKey, parseTrackerChildren)
import Kanban.Workflow (CardStatus (..), deriveBoard, entryItem, pullRequestStatus)
import System.Directory (createDirectory, getTemporaryDirectory, removeFile, removePathForcibly)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.IO (hClose, openTempFile)
import Test.Hspec

main :: IO ()
main = hspec $ do
  describe "repository identity parsing" $ do
    it "parses an HTTPS GitHub remote" $
      parseRepositoryName "https://github.com/coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
    it "parses an SSH GitHub remote" $
      parseRepositoryName "git@github.com:coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
    it "parses explicit OWNER/NAME syntax" $
      parseRepositoryName "coghex/kanban" `shouldBe` Right ("coghex", "kanban")

  describe "external text sanitization" $ do
    it "strips ANSI, control, and bidi sequences" $
      sanitizeText "safe\ESC[31m red\ESC[0m\NUL\x202Etext" `shouldBe` "safe redtext"
    it "selects and normalizes the first meaningful paragraph" $
      excerpt "\n\n  First\tparagraph\nwraps.  \n\nSecond paragraph." `shouldBe` "First paragraph wraps."

  describe "workflow classification" $ do
    it "classifies assigned issues as Active and removes linked issue cards" $ do
      let snapshot = RepoSnapshot [baseIssue 1 [], baseIssue 2 [Assignee "agent"]] [basePullRequest 10 [1] False []] epoch
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` []
      map (itemNumber . entryItem) (Map.findWithDefault [] Active columns) `shouldBe` [2]
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing columns) `shouldBe` [10]

    it "keeps draft approved pull requests in Reviewing" $ do
      let pullRequest = basePullRequest 10 [] True [Label "reviewed:approve" "00ff00"]
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [] [pullRequest] epoch)
      Map.size columns `shouldBe` 4
      length (Map.findWithDefault [] Reviewing columns) `shouldBe` 1
      Map.findWithDefault [] Done columns `shouldBe` []

    it "classifies non-draft approved pull requests as Done" $ do
      let pullRequest = basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [] [pullRequest] epoch)
      length (Map.findWithDefault [] Done columns) `shouldBe` 1

    it "keeps tracker issues visible as standalone cards before hierarchy is applied" $ do
      let tracker = (baseIssue 12 []) {issueLabels = [Label "epic" "5319e7"]}
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [tracker] [] epoch)
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [12]

    it "groups tracker children in natural implementation order" $ do
      let tracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #2 — A10: Later\n- [ ] #1 — A2: Earlier"
              }
          snapshot = RepoSnapshot [tracker, baseIssue 1 [], baseIssue 2 []] [] epoch
          Board columns = deriveBoard defaultWorkflowConfig snapshot
          entries = Map.findWithDefault [] Issues columns
      map (itemNumber . entryItem) entries `shouldBe` [1, 2]
      map entryImplementationKey entries `shouldBe` [Just "A2", Just "A10"]

    it "inherits tracker membership through a PR's linked child issue" $ do
      let tracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Phase plan\n- [ ] #1 — B1: Child"
              }
          snapshot = RepoSnapshot [tracker, baseIssue 1 []] [basePullRequest 10 [1] False []] epoch
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      case Map.findWithDefault [] Reviewing columns of
        [Tracked trackingContext item] -> do
          itemNumber item `shouldBe` 10
          trackingContext.trackingPrimary.membershipChild.trackerChildImplementationKey `shouldBe` Just "B1"
        values -> expectationFailure ("unexpected reviewing entries: " <> show values)

    it "chooses the earliest implementation key for multi-tracked PRs" $ do
      let laterTracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #1 — B1: Child"
              }
          earlierTracker =
            (baseIssue 200 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #1 — A2: Child"
              }
          snapshot = RepoSnapshot [laterTracker, earlierTracker, baseIssue 1 []] [basePullRequest 10 [1] False []] epoch
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      case Map.findWithDefault [] Reviewing columns of
        [Tracked trackingContext _] -> do
          trackingContext.trackingPrimary.membershipTracker.trackerIssue.issueNumber `shouldBe` 200
          map (.membershipTracker.trackerIssue.issueNumber) trackingContext.trackingAdditional `shouldBe` [100]
        values -> expectationFailure ("unexpected multi-tracked entries: " <> show values)

  describe "tracker checklist parsing" $ do
    it "parses supported checkboxes, progress, and natural keys only in tracker sections" $ do
      let body =
            "## Related\n- [ ] #99 — A1: Ignore\n"
              <> "## Children\n### Phase A\n- [ ] #2 — **A10:** Later\n- [x] **#1 — A2: Earlier**\n"
              <> "External prerequisite:\n- [ ] #77 — A3: Ignore\n"
          children = parseTrackerChildren body
      map (.trackerChildIssueNumber) children `shouldBe` [2, 1]
      map (.trackerChildComplete) children `shouldBe` [False, True]
      map (.trackerChildImplementationKey) (sortOn implementationSortKey children) `shouldBe` [Just "A2", Just "A10"]

  describe "GitHub GraphQL decoding" $ do
    it "decodes issue and pull-request fields used by the workflow" $ do
      case decodeGitHubItems (LazyByteString.pack githubResponse) of
        Left message -> expectationFailure message
        Right ([issue], [pullRequest]) -> do
          issue.issueNumber `shouldBe` 41
          issue.issueAssignees `shouldBe` [Assignee "worker"]
          issue.issueLabels `shouldBe` [Label "blocked" "d73a4a"]
          pullRequest.pullRequestLinkedIssues `shouldBe` [41]
          pullRequest.pullRequestReviewDecision `shouldBe` ReviewApproved
          pullRequest.pullRequestMergeState `shouldBe` MergeConflicting
          pullRequest.pullRequestChecks `shouldBe` ChecksFailed 0 3
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    it "rejects GraphQL error responses" $
      decodeGitHubItems "{\"errors\":[{\"message\":\"boom\"}],\"data\":{}}"
        `shouldSatisfy` isLeft

  describe "Codex app-server decoding" $ do
    it "maps returned windows by duration and computes percentage left" $ do
      case decodeCodexUsageResponse epoch codexRateLimitResponse of
        Left providerError -> expectationFailure (show providerError)
        Right snapshot -> do
          map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["5 hour", "week"]
          map (.usagePercentLeft) snapshot.usageWindows `shouldBe` [78, 59]
          snapshot.usageFetchedAt `shouldBe` epoch

    it "accepts an account that currently exposes only a weekly window" $ do
      case decodeCodexUsageResponse epoch codexWeeklyOnlyResponse of
        Left providerError -> expectationFailure (show providerError)
        Right snapshot -> map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["week"]

  describe "Claude /usage decoding" $ do
    it "selects the last complete screen-reader update" $ do
      case decodeClaudeUsageText (minutesToTimeZone (-420)) epoch claudeUsageOutput of
        Left providerError -> expectationFailure (show providerError)
        Right snapshot -> do
          map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["5 hour", "week"]
          map (.usagePercentLeft) snapshot.usageWindows `shouldBe` [79, 86]

    it "fails closed when the interactive usage request fails" $
      decodeClaudeUsageText (minutesToTimeZone (-420)) epoch "Current session\nFailed to load usage data"
        `shouldSatisfy` isLeft

  describe "repository snapshot cache" $ do
    it "round-trips a versioned snapshot and ignores corrupt JSON" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
              snapshot = RepoSnapshot [baseIssue 7 []] [] epoch
          writeRepositoryCache repository snapshot `shouldReturn` Right ()
          loadRepositoryCache repository `shouldReturn` CacheLoaded snapshot
          cachePath <- repositoryCachePath repository
          LazyByteString.writeFile cachePath "not JSON"
          invalid <- loadRepositoryCache repository
          invalid `shouldSatisfy` isInvalidCache

    it "round-trips global usage snapshots" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let codexUsage = UsageSnapshot [UsageWindow "week" 77 epoch] epoch
              claudeUsage = UsageSnapshot [UsageWindow "5 hour" 65 epoch] epoch
              snapshots = Map.fromList [(Codex, codexUsage), (Claude, claudeUsage)]
          writeUsageCache snapshots `shouldReturn` Right ()
          loadUsageCache `shouldReturn` UsageCacheLoaded snapshots

  describe "pull request status" $ do
    it "makes conflicts red even when approved and CI passed" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeConflicting, pullRequestChecks = ChecksPassed 4}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusProblem "merge conflict"
    it "makes clean approved pull requests green when CI passed" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeClean, pullRequestChecks = ChecksPassed 4}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusReady

  describe "responsive board layout" $ do
    it "shares a wide board across all four columns" $
      responsiveColumnWidths 167 `shouldBe` [41, 41, 40, 40]
    it "keeps readable columns and relies on scrolling below the threshold" $
      responsiveColumnWidths 100 `shouldBe` [32, 32, 32, 32]
    it "accounts for two-cell gutters in the open layout" $
      responsiveOpenColumnWidths 170 `shouldBe` [41, 41, 41, 41]

baseIssue :: Int -> [Assignee] -> Issue
baseIssue number assignees =
  Issue number ("Issue " <> showText number) "Body" "https://example.test" [] assignees epoch epoch

basePullRequest :: Int -> [Int] -> Bool -> [Label] -> PullRequest
basePullRequest number linked draft labels =
  PullRequest
    number
    ("PR " <> showText number)
    "Body"
    "https://example.test"
    labels
    "agent"
    draft
    "master"
    "branch"
    linked
    ReviewRequired
    MergeUnknown
    ChecksUnknown
    epoch
    epoch

itemNumber :: BoardItem -> Int
itemNumber (IssueItem issue) = issue.issueNumber
itemNumber (PullRequestItem pullRequest) = pullRequest.pullRequestNumber

entryImplementationKey :: ColumnEntry -> Maybe Text
entryImplementationKey (Tracked trackingContext _) = trackingContext.trackingPrimary.membershipChild.trackerChildImplementationKey
entryImplementationKey (Standalone _) = Nothing

showText :: Show value => value -> Text
showText = Data.Text.pack . show

epoch :: UTCTime
epoch = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)

isLeft :: Either left right -> Bool
isLeft (Left _) = True
isLeft (Right _) = False

isInvalidCache :: CacheLoad -> Bool
isInvalidCache (CacheInvalid _) = True
isInvalidCache _ = False

withTemporaryCacheRoot :: (FilePath -> IO result) -> IO result
withTemporaryCacheRoot = bracket createTemporaryDirectory removePathForcibly

createTemporaryDirectory :: IO FilePath
createTemporaryDirectory = do
  temporaryRoot <- getTemporaryDirectory
  (path, handle) <- openTempFile temporaryRoot "kanban-cache-test"
  hClose handle
  removeFile path
  createDirectory path
  pure path

withEnvironmentValue :: String -> String -> IO result -> IO result
withEnvironmentValue name value action =
  bracket
    (do previous <- lookupEnv name; setEnv name value; pure previous)
    (maybe (unsetEnv name) (setEnv name))
    (const action)

githubResponse :: String
githubResponse =
  unlines
    [ "{",
      "  \"data\": {",
      "    \"repository\": {",
      "      \"issues\": {",
      "        \"nodes\": [{",
      "          \"number\": 41, \"title\": \"Blocked issue\", \"body\": \"Details\",",
      "          \"url\": \"https://example.test/issues/41\",",
      "          \"labels\": {\"nodes\": [{\"name\": \"blocked\", \"color\": \"d73a4a\"}]},",
      "          \"assignees\": {\"nodes\": [{\"login\": \"worker\"}]},",
      "          \"createdAt\": \"2026-01-01T00:00:00Z\", \"updatedAt\": \"2026-01-02T00:00:00Z\"",
      "        }],",
      "        \"pageInfo\": {\"hasNextPage\": false, \"endCursor\": null}",
      "      },",
      "      \"pullRequests\": {",
      "        \"nodes\": [{",
      "          \"number\": 9, \"title\": \"Fix it\", \"body\": \"PR details\",",
      "          \"url\": \"https://example.test/pull/9\", \"labels\": {\"nodes\": []},",
      "          \"author\": {\"login\": \"author\"}, \"isDraft\": false,",
      "          \"baseRefName\": \"master\", \"headRefName\": \"fix\",",
      "          \"closingIssuesReferences\": {\"nodes\": [{\"number\": 41}]},",
      "          \"reviewDecision\": \"APPROVED\", \"mergeable\": \"CONFLICTING\",",
      "          \"mergeStateStatus\": \"DIRTY\",",
      "          \"statusCheckRollup\": {\"state\": \"FAILURE\", \"contexts\": {\"totalCount\": 3}},",
      "          \"createdAt\": \"2026-01-03T00:00:00Z\", \"updatedAt\": \"2026-01-04T00:00:00Z\"",
      "        }],",
      "        \"pageInfo\": {\"hasNextPage\": false, \"endCursor\": null}",
      "      }",
      "    }",
      "  }",
      "}"
    ]

codexRateLimitResponse :: LazyByteString.ByteString
codexRateLimitResponse =
  "{\"id\":1,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":99,\"windowDurationMins\":10080,\"resetsAt\":1784810495},\"secondary\":null},\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"usedPercent\":22,\"windowDurationMins\":300,\"resetsAt\":1784010000},\"secondary\":{\"usedPercent\":41,\"windowDurationMins\":10080,\"resetsAt\":1784810495}}}}}"

codexWeeklyOnlyResponse :: LazyByteString.ByteString
codexWeeklyOnlyResponse =
  "{\"id\":1,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":23,\"windowDurationMins\":10080,\"resetsAt\":1784810495},\"secondary\":null},\"rateLimitsByLimitId\":null}}"

claudeUsageOutput :: Text
claudeUsageOutput =
  Data.Text.unlines
    [ "Current session",
      "20% 20% used",
      "Resets 8:40pm (America/Los_Angeles)",
      "Current week (all models)",
      "13% 13% used",
      "Resets Jul 22 at 11pm (America/Los_Angeles)",
      "Refreshing…",
      "21% 21% used",
      "Resets 8:39pm (America/Los_Angeles)",
      "Current week (all models)",
      "14% 14% used",
      "Resets Jul 22 at 10:59pm (America/Los_Angeles)",
      "Usage credits",
      "78% 78% used",
      "$156.37 / $200.00 spent · Resets Aug 1 (America/Los_Angeles)"
    ]
