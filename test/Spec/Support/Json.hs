-- | Verbatim GitHub, provider and cache payloads the decoding groups parse.
module Spec.Support.Json
  ( githubResponse,
    githubRerunResponse,
    githubMixedChecksResponse,
    githubCappedChecksResponse,
    githubChecksResponse,
    githubPageWith,
    issueNodeJson,
    pullRequestNodeJson,
    emptyLabelsJson,
    emptyAssigneesJson,
    emptyClosingIssuesJson,
    rollupJson,
    futureCheckContextJson,
    namelessCheckRunJson,
    queuedCheckRunJson,
    completedOnlyCheckRunJson,
    undatedCheckRunJson,
    statusContextJson,
    runningCheckRunJson,
    versionTwoCacheFile,
    versionThreeCacheFile,
    checkRunJson,
    codexRateLimitResponse,
    codexWeeklyOnlyResponse,
    claudeUsageOutput,
    emptyGraphqlPage
  )
where

import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.List (intercalate)
import Data.Text (Text)
import qualified Data.Text

-- | The smallest GraphQL response the board fetch accepts: both requested
-- connections present, both empty, neither paginated.
emptyGraphqlPage :: ByteString.ByteString
emptyGraphqlPage =
  "{\"data\":{\"repository\":{\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}},\"pullRequests\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}"

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
      "          \"labels\": {\"totalCount\": 3, \"nodes\": [{\"name\": \"blocked\", \"color\": \"d73a4a\"}]},",
      "          \"assignees\": {\"totalCount\": 2, \"nodes\": [{\"login\": \"worker\"}]},",
      "          \"createdAt\": \"2026-01-01T00:00:00Z\", \"updatedAt\": \"2026-01-02T00:00:00Z\"",
      "        }],",
      "        \"pageInfo\": {\"hasNextPage\": false, \"endCursor\": null}",
      "      },",
      "      \"pullRequests\": {",
      "        \"nodes\": [{",
      "          \"number\": 9, \"title\": \"Fix it\", \"body\": \"PR details\",",
      "          \"url\": \"https://example.test/pull/9\", \"labels\": {\"totalCount\": 0, \"nodes\": []},",
      "          \"author\": {\"login\": \"author\"}, \"isDraft\": false,",
      "          \"baseRefName\": \"master\", \"headRefName\": \"fix\",",
      "          \"closingIssuesReferences\": {\"totalCount\": 4, \"nodes\": [{\"number\": 41}]},",
      "          \"reviewDecision\": \"APPROVED\", \"mergeable\": \"CONFLICTING\",",
      "          \"mergeStateStatus\": \"DIRTY\",",
      "          \"statusCheckRollup\": {\"contexts\": {\"totalCount\": 3, \"nodes\": [",
      "            {\"__typename\": \"CheckRun\", \"name\": \"build-test\", \"status\": \"COMPLETED\", \"conclusion\": \"SUCCESS\", \"startedAt\": \"2026-01-03T00:00:00Z\", \"completedAt\": \"2026-01-03T00:01:00Z\", \"checkSuite\": {\"app\": {\"slug\": \"github-actions\"}}},",
      "            {\"__typename\": \"CheckRun\", \"name\": \"review-approved\", \"status\": \"COMPLETED\", \"conclusion\": \"SUCCESS\", \"startedAt\": \"2026-01-03T00:00:00Z\", \"completedAt\": \"2026-01-03T00:01:00Z\", \"checkSuite\": {\"app\": {\"slug\": \"github-actions\"}}},",
      "            {\"__typename\": \"CheckRun\", \"name\": \"review-approved\", \"status\": \"COMPLETED\", \"conclusion\": \"FAILURE\", \"startedAt\": \"2026-01-03T00:02:00Z\", \"completedAt\": \"2026-01-03T00:03:00Z\", \"checkSuite\": {\"app\": {\"slug\": \"github-actions\"}}}",
      "          ]}},",
      "          \"createdAt\": \"2026-01-03T00:00:00Z\", \"updatedAt\": \"2026-01-04T00:00:00Z\"",
      "        }],",
      "        \"pageInfo\": {\"hasNextPage\": false, \"endCursor\": null}",
      "      }",
      "    }",
      "  }",
      "}"
    ]

githubRerunResponse :: String
githubRerunResponse =
  unlines
    [ "{\"data\":{\"repository\":{",
      "\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}},",
      "\"pullRequests\":{\"nodes\":[{",
      "\"number\":858,\"title\":\"Ready after rerun\",\"body\":\"Closes #844\",\"url\":\"https://example.test/pull/858\",",
      "\"labels\":{\"totalCount\":1,\"nodes\":[{\"name\":\"reviewed:approve\",\"color\":\"0e8a16\"}]},",
      "\"author\":{\"login\":\"author\"},\"isDraft\":false,\"baseRefName\":\"master\",\"headRefName\":\"fix\",",
      "\"closingIssuesReferences\":{\"totalCount\":1,\"nodes\":[{\"number\":844}]},",
      "\"reviewDecision\":null,\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"BLOCKED\",",
      "\"statusCheckRollup\":{\"contexts\":{\"totalCount\":5,\"nodes\":[",
      checkRunJson "review-approved" "FAILURE" "2026-07-17T14:43:13Z",
      ",",
      checkRunJson "review-approved" "SUCCESS" "2026-07-17T14:48:53Z",
      ",",
      checkRunJson "build-test" "SUCCESS" "2026-07-17T14:43:35Z",
      ",",
      checkRunJson "dismiss-stale-approval" "SKIPPED" "2026-07-17T14:48:50Z",
      ",",
      checkRunJson "dismiss-stale-approval" "SKIPPED" "2026-07-17T14:43:16Z",
      "]}},",
      "\"createdAt\":\"2026-07-17T13:21:31Z\",\"updatedAt\":\"2026-07-17T14:48:47Z\"",
      "}],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}",
      "}}}"
    ]

-- | A rollup holding a superseded failure (now green), a current failure, and
-- a rerun that is still running, so the aggregate counts and the retained
-- detail both have something to select from.
githubMixedChecksResponse :: String
githubMixedChecksResponse =
  githubChecksResponse
    5
    [ checkRunJson "build-test" "SUCCESS" "2026-07-17T14:43:00Z",
      checkRunJson "integration-suite" "SUCCESS" "2026-07-17T14:40:00Z",
      checkRunJson "integration-suite" "FAILURE" "2026-07-17T14:50:00Z",
      checkRunJson "smoke" "FAILURE" "2026-07-17T14:30:00Z",
      runningCheckRunJson "smoke" "2026-07-17T14:55:00Z"
    ]

-- | A rollup GitHub reports as larger than the 100 contexts §13 requests.
githubCappedChecksResponse :: String
githubCappedChecksResponse =
  githubChecksResponse 150 [checkRunJson "build-test" "SUCCESS" "2026-07-17T14:43:00Z"]

-- | One open pull request whose only interesting field is its check rollup.
githubChecksResponse :: Int -> [String] -> String
githubChecksResponse totalCount nodes =
  unlines
    [ "{\"data\":{\"repository\":{",
      "\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}},",
      "\"pullRequests\":{\"nodes\":[{",
      "\"number\":860,\"title\":\"Mixed checks\",\"body\":\"Closes #36\",\"url\":\"https://example.test/pull/860\",",
      "\"labels\":{\"totalCount\":0,\"nodes\":[]},",
      "\"author\":{\"login\":\"author\"},\"isDraft\":false,\"baseRefName\":\"master\",\"headRefName\":\"fix\",",
      "\"closingIssuesReferences\":{\"totalCount\":1,\"nodes\":[{\"number\":36}]},",
      "\"reviewDecision\":null,\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"UNSTABLE\",",
      "\"statusCheckRollup\":{\"contexts\":{\"totalCount\":" <> show totalCount <> ",\"nodes\":[",
      intercalate "," nodes,
      "]}},",
      "\"createdAt\":\"2026-07-17T13:21:31Z\",\"updatedAt\":\"2026-07-17T14:48:47Z\"",
      "}],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}",
      "}}}"
    ]

-- | A page holding the given raw issue and pull-request nodes, so a test can
-- stand one anomalous item beside an intact one and check that only the
-- anomalous item is degraded.
githubPageWith :: [String] -> [String] -> String
githubPageWith issueNodes pullRequestNodes =
  unlines
    [ "{\"data\":{\"repository\":{",
      "\"issues\":{\"nodes\":[" <> intercalate "," issueNodes <> "],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}},",
      "\"pullRequests\":{\"nodes\":[" <> intercalate "," pullRequestNodes <> "],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}",
      "}}}"
    ]

-- | One issue node whose nested connections are supplied verbatim, so a test
-- can null one out or leave it off the node entirely.
issueNodeJson :: Int -> [String] -> String
issueNodeJson number connections =
  "{"
    <> intercalate
      ","
      ( [ "\"number\":" <> show number,
          "\"title\":\"Issue " <> show number <> "\"",
          "\"body\":\"B\"",
          "\"url\":\"https://example.test/issues/" <> show number <> "\""
        ]
          <> connections
          <> ["\"createdAt\":\"2026-01-01T00:00:00Z\"", "\"updatedAt\":\"2026-01-02T00:00:00Z\""]
      )
    <> "}"

-- | The pull-request counterpart: every scalar the decoder requires, with the
-- connections and rollup left to the caller.
pullRequestNodeJson :: Int -> [String] -> String
pullRequestNodeJson number extras =
  "{"
    <> intercalate
      ","
      ( [ "\"number\":" <> show number,
          "\"title\":\"PR " <> show number <> "\"",
          "\"body\":\"B\"",
          "\"url\":\"https://example.test/pull/" <> show number <> "\"",
          "\"author\":{\"login\":\"author\"}",
          "\"isDraft\":false",
          "\"baseRefName\":\"master\"",
          "\"headRefName\":\"fix\"",
          "\"reviewDecision\":null",
          "\"mergeable\":\"MERGEABLE\"",
          "\"mergeStateStatus\":\"CLEAN\""
        ]
          <> extras
          <> ["\"createdAt\":\"2026-01-03T00:00:00Z\"", "\"updatedAt\":\"2026-01-04T00:00:00Z\""]
      )
    <> "}"

emptyLabelsJson, emptyAssigneesJson, emptyClosingIssuesJson :: String
emptyLabelsJson = "\"labels\":{\"totalCount\":0,\"nodes\":[]}"
emptyAssigneesJson = "\"assignees\":{\"totalCount\":0,\"nodes\":[]}"
emptyClosingIssuesJson = "\"closingIssuesReferences\":{\"totalCount\":0,\"nodes\":[]}"

rollupJson :: Int -> [String] -> String
rollupJson totalCount nodes =
  "\"statusCheckRollup\":{\"contexts\":{\"totalCount\":"
    <> show totalCount
    <> ",\"nodes\":["
    <> intercalate "," nodes
    <> "]}}"

-- | A rollup context whose @__typename@ this build has never seen, as GitHub
-- adding a rollup kind would deliver it.
futureCheckContextJson :: String
futureCheckContextJson = "{\"__typename\":\"SomeFutureType\",\"name\":\"future\"}"

-- | A context of a type this build /does/ know, missing a field that type's
-- decode requires.
namelessCheckRunJson :: String
namelessCheckRunJson =
  "{\"__typename\":\"CheckRun\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\",\"startedAt\":\"2026-01-03T00:00:00Z\"}"

-- | A rerun GitHub has accepted but not started: @QUEUED@, with the null
-- conclusion and null @startedAt@/@completedAt@ that state actually reports.
queuedCheckRunJson :: String -> String
queuedCheckRunJson name =
  "{\"__typename\":\"CheckRun\",\"name\":\""
    <> name
    <> "\",\"status\":\"QUEUED\",\"conclusion\":null,\"startedAt\":null,\"completedAt\":null"
    <> ",\"checkSuite\":{\"app\":{\"slug\":\"github-actions\"}}}"

-- | A finished run reporting only @completedAt@, which is the case the
-- effective-timestamp fallback exists for.
completedOnlyCheckRunJson :: String -> String -> String -> String
completedOnlyCheckRunJson name conclusion completedAt =
  "{\"__typename\":\"CheckRun\",\"name\":\""
    <> name
    <> "\",\"status\":\"COMPLETED\",\"conclusion\":\""
    <> conclusion
    <> "\",\"startedAt\":null,\"completedAt\":\""
    <> completedAt
    <> "\",\"checkSuite\":{\"app\":{\"slug\":\"github-actions\"}}}"

-- | A finished run carrying no timestamps. GitHub does not report one, but it
-- is the only way to give two untimestamped runs of a key different states and
-- so observe which of them the tie-break keeps.
undatedCheckRunJson :: String -> String -> String
undatedCheckRunJson name conclusion =
  "{\"__typename\":\"CheckRun\",\"name\":\""
    <> name
    <> "\",\"status\":\"COMPLETED\",\"conclusion\":\""
    <> conclusion
    <> "\",\"startedAt\":null,\"completedAt\":null"
    <> ",\"checkSuite\":{\"app\":{\"slug\":\"github-actions\"}}}"

-- | A commit status context, the rollup's other kind. Its @createdAt@ is
-- optional because the query always asks for it and GitHub answers null when
-- it has none.
statusContextJson :: String -> String -> Maybe String -> String
statusContextJson name state createdAt =
  "{\"__typename\":\"StatusContext\",\"context\":\""
    <> name
    <> "\",\"state\":\""
    <> state
    <> "\",\"createdAt\":"
    <> maybe "null" (\stamp -> "\"" <> stamp <> "\"") createdAt
    <> ",\"creator\":{\"login\":\"ci\"}}"

runningCheckRunJson :: String -> String -> String
runningCheckRunJson name startedAt =
  "{\"__typename\":\"CheckRun\",\"name\":\""
    <> name
    <> "\",\"status\":\"IN_PROGRESS\",\"conclusion\":null,\"startedAt\":\""
    <> startedAt
    <> "\",\"checkSuite\":{\"app\":{\"slug\":\"github-actions\"}}}"

-- | A cache file exactly as version 2 wrote one: the current envelope shape,
-- but with a check summary carrying only its two aggregate counts. Everything
-- else is the current encoder's own output, so the only thing that cannot
-- decode under the current schema is the part version 3 actually changed.
versionTwoCacheFile :: Int -> ByteString.ByteString
versionTwoCacheFile version =
  ByteString.pack
    ( "{\"schemaVersion\":"
        <> show version
        <> ",\"repositoryKey\":\"coghex/kanban\",\"snapshot\":{"
        <> "\"snapshotFetchedAt\":\"2026-01-01T00:00:00Z\",\"snapshotIssues\":[],"
        <> "\"snapshotIssuesTruncated\":false,\"snapshotPullRequestsTruncated\":false,"
        <> "\"snapshotPullRequests\":[{"
        <> "\"pullRequestAuthor\":\"agent\",\"pullRequestBase\":\"master\",\"pullRequestBody\":\"B\","
        <> "\"pullRequestChecks\":{\"contents\":[1,2],\"tag\":\"ChecksFailed\"},"
        <> "\"pullRequestCreatedAt\":\"2026-01-01T00:00:00Z\",\"pullRequestDraft\":false,"
        <> "\"pullRequestHead\":\"branch\",\"pullRequestLabelOverflow\":0,\"pullRequestLabels\":[],"
        <> "\"pullRequestLinkedIssueOverflow\":0,\"pullRequestLinkedIssues\":[36],"
        <> "\"pullRequestMergeState\":\"MergeUnknown\",\"pullRequestNumber\":823,"
        <> "\"pullRequestReviewDecision\":\"ReviewRequired\",\"pullRequestTitle\":\"T\","
        <> "\"pullRequestUpdatedAt\":\"2026-01-01T00:00:00Z\",\"pullRequestUrl\":\"u\"}]}}"
    )

-- | A cache file exactly as version 3 wrote one: the current envelope and
-- check-summary shape, but with no per-item data gaps. Everything else is the
-- current encoder's own output, so the only thing that cannot decode under the
-- current schema is the part version 4 actually added.
versionThreeCacheFile :: Int -> ByteString.ByteString
versionThreeCacheFile version =
  ByteString.pack
    ( "{\"schemaVersion\":"
        <> show version
        <> ",\"repositoryKey\":\"coghex/kanban\",\"snapshot\":{"
        <> "\"snapshotFetchedAt\":\"2026-01-01T00:00:00Z\",\"snapshotIssues\":[],"
        <> "\"snapshotIssuesTruncated\":false,\"snapshotPullRequestsTruncated\":false,"
        <> "\"snapshotPullRequests\":[{"
        <> "\"pullRequestAuthor\":\"agent\",\"pullRequestBase\":\"master\",\"pullRequestBody\":\"B\","
        <> "\"pullRequestChecks\":{\"contents\":[9,12,[]],\"tag\":\"ChecksFailed\"},"
        <> "\"pullRequestCreatedAt\":\"2026-01-01T00:00:00Z\",\"pullRequestDraft\":false,"
        <> "\"pullRequestHead\":\"branch\",\"pullRequestLabelOverflow\":0,\"pullRequestLabels\":[],"
        <> "\"pullRequestLinkedIssueOverflow\":0,\"pullRequestLinkedIssues\":[36],"
        <> "\"pullRequestMergeState\":\"MergeUnknown\",\"pullRequestNumber\":823,"
        <> "\"pullRequestReviewDecision\":\"ReviewRequired\",\"pullRequestTitle\":\"T\","
        <> "\"pullRequestUpdatedAt\":\"2026-01-01T00:00:00Z\",\"pullRequestUrl\":\"u\"}]}}"
    )

checkRunJson :: String -> String -> String -> String
checkRunJson name conclusion startedAt =
  "{\"__typename\":\"CheckRun\",\"name\":\""
    <> name
    <> "\",\"status\":\"COMPLETED\",\"conclusion\":\""
    <> conclusion
    <> "\",\"startedAt\":\""
    <> startedAt
    <> "\",\"completedAt\":\""
    <> startedAt
    <> "\",\"checkSuite\":{\"app\":{\"slug\":\"github-actions\"}}}"

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
