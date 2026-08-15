-- | Verbatim GitHub, provider and cache payloads the decoding groups parse.
module Spec.Support.Json
  ( githubResponse,
    githubRerunResponse,
    githubMixedChecksResponse,
    githubCappedChecksResponse,
    githubChecksResponse,
    githubPageWith,
    githubPageWithErrors,
    graphqlErrorsOnly,
    issueNodeJson,
    issueNodeJsonInState,
    pullRequestNodeJson,
    pullRequestNodeJsonInState,
    completedPageJson,
    emptyLabelsJson,
    emptyAssigneesJson,
    emptyClosingIssuesJson,
    emptySubIssuesJson,
    subIssuesJson,
    subIssueConnectionJson,
    subIssueSummaryJson,
    subIssueNodeJson,
    fixtureRepositoryIdentity,
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
    versionFourCacheFile,
    versionFiveCacheFile,
    emptySnapshotCacheFile,
    malformedCompletedCacheFile,
    undecodableCacheFile,
    githubIndependentPage,
    graphqlPageWithRateLimit,
    rateLimitedGraphqlResponse,
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

-- | GitHub's own @owner\/name@ for the repository every page fixture here is
-- fetched from. Native sub-issue membership is decided against this, so a
-- child node carrying it is local and one carrying anything else is foreign.
fixtureRepositoryIdentity :: String
fixtureRepositoryIdentity = "coghex/kanban"

-- | The smallest GraphQL response the board fetch accepts: both requested
-- connections present, both empty, neither paginated.
emptyGraphqlPage :: ByteString.ByteString
emptyGraphqlPage =
  ByteString.pack
    ( "{\"data\":{\"repository\":{\"nameWithOwner\":\""
        <> fixtureRepositoryIdentity
        <> "\",\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}},\"pullRequests\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}"
    )

-- | The same smallest accepted page with GitHub's rate report beside it. The
-- argument is the @rateLimit@ field's own body verbatim, so one fixture
-- covers a complete report, a partial one, an implausible one, and @null@.
graphqlPageWithRateLimit :: String -> ByteString.ByteString
graphqlPageWithRateLimit rateLimit =
  ByteString.pack
    ( "{\"data\":{\"rateLimit\":"
        <> rateLimit
        <> ",\"repository\":{\"nameWithOwner\":\""
        <> fixtureRepositoryIdentity
        <> "\",\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}},\"pullRequests\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}"
    )

-- | How GitHub answers a request against an exhausted primary budget: an
-- otherwise ordinary response carrying no data and a @RATE_LIMITED@ error.
rateLimitedGraphqlResponse :: ByteString.ByteString
rateLimitedGraphqlResponse =
  "{\"data\":null,\"errors\":[{\"type\":\"RATE_LIMITED\",\"message\":\"API rate limit exceeded for user ID 4242.\"}]}"

githubResponse :: String
githubResponse =
  unlines
    [ "{",
      "  \"data\": {",
      "    \"repository\": {",
      "      \"nameWithOwner\": \"" <> fixtureRepositoryIdentity <> "\",",
      "      \"issues\": {",
      "        \"nodes\": [{",
      "          \"number\": 41, \"title\": \"Blocked issue\", \"body\": \"Details\",",
      "          \"url\": \"https://example.test/issues/41\", \"state\": \"OPEN\",",
      "          \"labels\": {\"totalCount\": 3, \"nodes\": [{\"name\": \"blocked\", \"color\": \"d73a4a\"}]},",
      "          \"assignees\": {\"totalCount\": 2, \"nodes\": [{\"login\": \"worker\"}]},",
      "          " <> emptySubIssuesJson <> ",",
      "          \"createdAt\": \"2026-01-01T00:00:00Z\", \"updatedAt\": \"2026-01-02T00:00:00Z\"",
      "        }],",
      "        \"pageInfo\": {\"hasNextPage\": false, \"endCursor\": null}",
      "      },",
      "      \"pullRequests\": {",
      "        \"nodes\": [{",
      "          \"number\": 9, \"title\": \"Fix it\", \"body\": \"PR details\",",
      "          \"url\": \"https://example.test/pull/9\", \"state\": \"OPEN\", \"labels\": {\"totalCount\": 0, \"nodes\": []},",
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
    [ "{\"data\":{\"repository\":{\"nameWithOwner\":\"" <> fixtureRepositoryIdentity <> "\",",
      "\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}},",
      "\"pullRequests\":{\"nodes\":[{",
      "\"number\":858,\"title\":\"Ready after rerun\",\"body\":\"Closes #844\",\"url\":\"https://example.test/pull/858\",\"state\":\"OPEN\",",
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
    [ "{\"data\":{\"repository\":{\"nameWithOwner\":\"" <> fixtureRepositoryIdentity <> "\",",
      "\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}},",
      "\"pullRequests\":{\"nodes\":[{",
      "\"number\":860,\"title\":\"Mixed checks\",\"body\":\"Closes #36\",\"url\":\"https://example.test/pull/860\",\"state\":\"OPEN\",",
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
-- | A page whose two open connections are paginated independently: each is
-- either absent — which is what @\@include(if: false)@ produces once that
-- connection has reached its final page — or present with its own nodes and
-- its own next cursor.
--
-- The other page builders here move both connections together, which cannot
-- express the ordinary shape of an uncapped traversal: issues and pull
-- requests run out at different pages, and every page after the shorter one
-- finishes asks for the longer one alone.
githubIndependentPage :: Maybe ([String], Maybe String) -> Maybe ([String], Maybe String) -> String
githubIndependentPage issues pullRequests =
  "{\"data\":{\"repository\":{\"nameWithOwner\":\""
    <> fixtureRepositoryIdentity
    <> "\""
    <> maybe "" (connectionJson "issues") issues
    <> maybe "" (connectionJson "pullRequests") pullRequests
    <> "}}}"
  where
    connectionJson name (nodes, nextCursor) =
      ",\"" <> name <> "\":{\"nodes\":[" <> intercalate "," nodes <> "]," <> pageInfoJson nextCursor <> "}"
    pageInfoJson Nothing = "\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}"
    pageInfoJson (Just cursor) = "\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"" <> cursor <> "\"}"

-- | A page of the completed traversal.
--
-- Each connection is either absent -- which is what @\@include(if: false)@
-- produces once that connection has reached its final page -- or present with
-- GitHub's own @totalCount@, its nodes, and its own next cursor. The total is
-- the part no open page ever carries, and is the whole of §15's progress
-- denominator.
completedPageJson :: Maybe (Int, [String], Maybe String) -> Maybe (Int, [String], Maybe String) -> String
completedPageJson issues pullRequests =
  "{\"data\":{\"repository\":{\"nameWithOwner\":\""
    <> fixtureRepositoryIdentity
    <> "\""
    <> maybe "" (connectionJson "issues") issues
    <> maybe "" (connectionJson "pullRequests") pullRequests
    <> "}}}"
  where
    connectionJson name (total, nodes, nextCursor) =
      ",\""
        <> name
        <> "\":{\"totalCount\":"
        <> show total
        <> ",\"nodes\":["
        <> intercalate "," nodes
        <> "],"
        <> pageInfoJson nextCursor
        <> "}"
    pageInfoJson Nothing = "\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}"
    pageInfoJson (Just cursor) = "\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"" <> cursor <> "\"}"

githubPageWith :: [String] -> [String] -> String
githubPageWith issueNodes pullRequestNodes =
  unlines
    [ "{\"data\":{\"repository\":{\"nameWithOwner\":\"" <> fixtureRepositoryIdentity <> "\",",
      "\"issues\":{\"nodes\":[" <> intercalate "," issueNodes <> "],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}},",
      "\"pullRequests\":{\"nodes\":[" <> intercalate "," pullRequestNodes <> "],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}",
      "}}}"
    ]

-- | The partial response GraphQL sends for a query it could only partly
-- resolve: both requested connections present and complete, and an @errors@
-- array naming what it could not deliver. The cursor is the one GitHub
-- returns when another page follows, so a test can chain two of these the way
-- the fetch loop does. Messages are inserted verbatim, so a caller wanting a
-- JSON escape writes it itself.
githubPageWithErrors :: [String] -> Maybe String -> [String] -> [String] -> String
githubPageWithErrors messages nextCursor issueNodes pullRequestNodes =
  unlines
    [ "{\"errors\":[" <> intercalate "," (map errorObjectJson messages) <> "],",
      "\"data\":{\"repository\":{\"nameWithOwner\":\"" <> fixtureRepositoryIdentity <> "\",",
      "\"issues\":{\"nodes\":[" <> intercalate "," issueNodes <> "]," <> pageInfoJson <> "},",
      "\"pullRequests\":{\"nodes\":[" <> intercalate "," pullRequestNodes <> "]," <> pageInfoJson <> "}",
      "}}}"
    ]
  where
    pageInfoJson = case nextCursor of
      Nothing -> "\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}"
      Just cursor -> "\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"" <> cursor <> "\"}"

-- | The fatal shape: errors and a null @data@, which is what GitHub answers
-- when the whole query failed rather than part of it.
graphqlErrorsOnly :: [String] -> String
graphqlErrorsOnly messages =
  "{\"errors\":[" <> intercalate "," (map errorObjectJson messages) <> "],\"data\":null}"

-- | A GraphQL error object with the siblings @message@ really arrives beside,
-- so a decoder that stringified the whole entry rather than reading the one
-- field would be visible.
errorObjectJson :: String -> String
errorObjectJson message =
  "{\"path\":[\"repository\"],\"message\":\"" <> message <> "\",\"locations\":[{\"line\":1,\"column\":1}]}"

-- | One issue node whose nested connections are supplied verbatim, so a test
-- can null one out or leave it off the node entirely.
issueNodeJson :: Int -> [String] -> String
issueNodeJson = issueNodeJsonInState "OPEN" Nothing

-- | The same node in a named lifecycle state, and optionally with a title of
-- its own so two runs over the same number can differ by an edit.
issueNodeJsonInState :: String -> Maybe String -> Int -> [String] -> String
issueNodeJsonInState state title number connections =
  "{"
    <> intercalate
      ","
      ( [ "\"number\":" <> show number,
          "\"title\":\"" <> maybe ("Issue " <> show number) id title <> "\"",
          "\"body\":\"B\"",
          "\"url\":\"https://example.test/issues/" <> show number <> "\"",
          "\"state\":\"" <> state <> "\""
        ]
          <> connections
          <> ["\"createdAt\":\"2026-01-01T00:00:00Z\"", "\"updatedAt\":\"2026-01-02T00:00:00Z\""]
      )
    <> "}"

-- | The pull-request counterpart: every scalar the decoder requires, with the
-- connections and rollup left to the caller.
pullRequestNodeJson :: Int -> [String] -> String
pullRequestNodeJson = pullRequestNodeJsonInState "OPEN" Nothing

pullRequestNodeJsonInState :: String -> Maybe String -> Int -> [String] -> String
pullRequestNodeJsonInState state title number extras =
  "{"
    <> intercalate
      ","
      ( [ "\"number\":" <> show number,
          "\"title\":\"" <> maybe ("PR " <> show number) id title <> "\"",
          "\"body\":\"B\"",
          "\"url\":\"https://example.test/pull/" <> show number <> "\"",
          "\"state\":\"" <> state <> "\"",
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

-- | The sub-issue relationship fields GitHub answers for an issue that has
-- none: a positively empty connection and a zeroed summary.
emptySubIssuesJson :: String
emptySubIssuesJson = subIssuesJson 0 [] 0 0

-- | Both sub-issue fields for a parent with children, which is how GitHub
-- delivers them together.
subIssuesJson :: Int -> [String] -> Int -> Int -> String
subIssuesJson omitted children completed total =
  subIssueConnectionJson omitted children <> "," <> subIssueSummaryJson completed total

-- | The relationship connection alone. @omitted@ is what GitHub says exists
-- beyond the delivered nodes, which is the incomplete-answer shape §12
-- refuses to read as a verified empty set.
subIssueConnectionJson :: Int -> [String] -> String
subIssueConnectionJson omitted children =
  "\"subIssues\":{\"totalCount\":"
    <> show (length children + omitted)
    <> ",\"nodes\":["
    <> intercalate "," children
    <> "]}"

-- | The completion summary alone, so a test can null or truncate one half of
-- GitHub's answer without repeating the other.
subIssueSummaryJson :: Int -> Int -> String
subIssueSummaryJson completed total =
  "\"subIssuesSummary\":{\"total\":" <> show total <> ",\"completed\":" <> show completed <> "}"

-- | One native sub-issue node, with the owning repository GitHub reports
-- beside its number.
subIssueNodeJson :: Int -> String -> Bool -> String
subIssueNodeJson number repository closed =
  "{\"number\":"
    <> show number
    <> ",\"state\":\""
    <> (if closed then "CLOSED" else "OPEN")
    <> "\",\"repository\":{\"nameWithOwner\":\""
    <> repository
    <> "\"}}"

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

-- | A cache file exactly as version 4 wrote one: the current envelope,
-- check-summary and gap shape, but with an issue that carries no native
-- sub-issue answer. Everything else is the current encoder's own output, so
-- the only thing that cannot decode under the current schema is the part
-- version 5 actually added.
versionFourCacheFile :: Int -> ByteString.ByteString
versionFourCacheFile version =
  ByteString.pack
    ( "{\"schemaVersion\":"
        <> show version
        <> ",\"repositoryKey\":\"coghex/kanban\",\"snapshot\":{"
        <> "\"snapshotFetchedAt\":\"2026-01-01T00:00:00Z\",\"snapshotPullRequests\":[],"
        <> "\"snapshotIssuesTruncated\":false,\"snapshotPullRequestsTruncated\":false,"
        <> "\"snapshotIssues\":[{"
        <> "\"issueAssigneeOverflow\":0,\"issueAssignees\":[],\"issueBody\":\"B\","
        <> "\"issueCreatedAt\":\"2026-01-01T00:00:00Z\",\"issueDataGaps\":[],"
        <> "\"issueLabelOverflow\":0,\"issueLabels\":[],\"issueNumber\":36,"
        <> "\"issueTitle\":\"T\",\"issueUpdatedAt\":\"2026-01-01T00:00:00Z\","
        <> "\"issueUrl\":\"u\"}]}}"
    )

-- | A cache file exactly as version 5 wrote one: the last shape anything ever
-- persisted, complete with the top-level truncation flags version 6 dropped.
-- This is what an earlier release leaves in the cache root, and what the
-- current version gate has to turn away without reading.
versionFiveCacheFile :: Int -> ByteString.ByteString
versionFiveCacheFile version =
  ByteString.pack
    ( "{\"schemaVersion\":"
        <> show version
        <> ",\"repositoryKey\":\"coghex/kanban\",\"snapshot\":{"
        <> "\"snapshotFetchedAt\":\"2026-01-01T00:00:00Z\",\"snapshotPullRequests\":[],"
        <> "\"snapshotIssuesTruncated\":true,\"snapshotPullRequestsTruncated\":true,"
        <> "\"snapshotIssues\":[{"
        <> "\"issueAssigneeOverflow\":0,\"issueAssignees\":[],\"issueBody\":\"B\","
        <> "\"issueCreatedAt\":\"2026-01-01T00:00:00Z\",\"issueDataGaps\":[],"
        <> "\"issueLabelOverflow\":0,\"issueLabels\":[],\"issueNumber\":36,"
        <> "\"issueSubIssues\":{\"tag\":\"SubIssuesNotRequested\"},"
        <> "\"issueTitle\":\"T\",\"issueUpdatedAt\":\"2026-01-01T00:00:00Z\","
        <> "\"issueUrl\":\"u\"}]}}"
    )

-- | The current envelope around an empty snapshot.
--
-- It exists so a test about the envelope's own fields cannot be answered by an
-- item decode: every other snapshot fixture here is deliberately shaped like
-- some earlier release's items, and would fail under the current schema before
-- the repository key was ever compared.
emptySnapshotCacheFile :: Int -> ByteString.ByteString
emptySnapshotCacheFile version =
  ByteString.pack
    ( "{\"schemaVersion\":"
        <> show version
        <> ",\"repositoryKey\":\"coghex/kanban\",\"snapshot\":{"
        <> "\"snapshotFetchedAt\":\"2026-01-01T00:00:00Z\","
        <> "\"snapshotIssues\":[],\"snapshotPullRequests\":[]}}"
    )

-- | A completed-history cache file whose envelope is current and whose payload
-- is one an earlier lifecycle-less build would have written: an issue with no
-- @issueState@. It stands for a malformed payload under a version this build
-- does claim to understand, which §16 keeps warning about rather than
-- silencing as version skew.
malformedCompletedCacheFile :: Int -> ByteString.ByteString
malformedCompletedCacheFile version =
  ByteString.pack
    ( "{\"schemaVersion\":"
        <> show version
        <> ",\"repositoryKey\":\"coghex/kanban\",\"history\":{"
        <> "\"historyFetchedAt\":\"2026-01-01T00:00:00Z\",\"historyPullRequests\":[],"
        <> "\"historyIssues\":[{"
        <> "\"issueAssigneeOverflow\":0,\"issueAssignees\":[],\"issueBody\":\"B\","
        <> "\"issueCreatedAt\":\"2026-01-01T00:00:00Z\",\"issueDataGaps\":[],"
        <> "\"issueLabelOverflow\":0,\"issueLabels\":[],\"issueNumber\":36,"
        <> "\"issueSubIssues\":{\"tag\":\"SubIssuesNotRequested\"},"
        <> "\"issueTitle\":\"T\",\"issueUpdatedAt\":\"2026-01-01T00:00:00Z\","
        <> "\"issueUrl\":\"u\"}]}}"
    )

-- | A cache file carrying a recognised envelope around a payload that cannot
-- be a snapshot at all. Loading it under the current version is what shows
-- the gate answered before the decoder did: turned away by the version, it is
-- absent; relabelled as current, the same bytes are corruption.
undecodableCacheFile :: Int -> ByteString.ByteString
undecodableCacheFile version =
  ByteString.pack
    ( "{\"schemaVersion\":"
        <> show version
        <> ",\"repositoryKey\":\"coghex/kanban\",\"snapshot\":\"not a snapshot at all\"}"
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
