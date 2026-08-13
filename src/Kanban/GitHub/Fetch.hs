-- | The board's GraphQL snapshot fetch: the argument vector and query one
-- page is requested with, the page-by-page loop that runs them, and the fold
-- that turns decoded pages into a 'RepoSnapshot'.
--
-- This is the composition point for everything else in the provider. It
-- reclaims and guards through 'Kanban.GitHub.Guard', spawns through
-- 'Kanban.GitHub.Run', decodes through 'Kanban.GitHub.Decode', and reports
-- through 'Kanban.GitHub.Message' and 'Kanban.GitHub.Warnings'.
module Kanban.GitHub.Fetch
  ( FetchState (..),
    GitHubResult (..),
    RateObserver,
    advanceState,
    decodeGitHubItems,
    fetchGitHubSnapshot,
    graphqlArguments,
    paginationDecision,
  )
where

import Control.Exception (try)
import Data.Aeson (eitherDecode)
import Data.Bifunctor (first)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Time (getCurrentTime)
import Kanban.Config (LimitsConfig (..))
import Kanban.Domain
import Kanban.GitHub.Decode (Connection (..), GitHubPage (..), PageInfo (..))
import Kanban.GitHub.Guard (GhFetchGuard, reclaimRecordedGhGroups, uninterruptiblyBounded)
import Kanban.GitHub.Message (classifyFailure, compactError, decodeGhOutput, partialResponseWarning, primaryRateLimited, withGraphQLErrors)
import Kanban.GitHub.Rate (RateSample (..), rateSampleFromResponse)
import Kanban.GitHub.Run (GhFetchAborted (..), GhProcessFailed (..), ghFailureKind, runGh)
import Kanban.GitHub.Warnings (snapshotWarnings)
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import System.Exit (ExitCode (..))

data GitHubResult = GitHubResult
  { githubSnapshot :: RepoSnapshot,
    githubWarnings :: [Text]
  }
  deriving stock (Eq, Show)

data FetchState = FetchState
  { fetchedIssues :: [Issue],
    fetchedPullRequests :: [PullRequest],
    issueCursor :: Maybe Text,
    pullRequestCursor :: Maybe Text,
    fetchMoreIssues :: Bool,
    fetchMorePullRequests :: Bool,
    issuesTruncated :: Bool,
    pullRequestsTruncated :: Bool,
    -- | Whether this refresh is still asking for native sub-issue
    -- relationships. A deployment whose GraphQL schema has no such fields
    -- rejects the whole query at validation time, which would fail every
    -- refresh for every repository; the fetch drops the selection once and
    -- carries on with checklist-only membership instead.
    fetchSubIssues :: Bool,
    -- | One warning per page that arrived with GraphQL errors. A refresh spans
    -- several pages and only the last one builds the result, so a page's
    -- errors have to be carried here or they are lost with the state that
    -- decoded them.
    fetchWarnings :: [Text]
  }

pageLimit :: Int
pageLimit = 100

-- | Told what each page reported about the budget, in the order the pages
-- were fetched.
--
-- Every page reports, whether or not it succeeded and whether or not GitHub
-- said anything usable: 'Nothing' is the honest answer for a response that
-- omitted or malformed its rate report, and the fetch carries on exactly as it
-- would have without one (§13). Only the scheduler above acts on these; the
-- fetch itself never changes course over a budget.
type RateObserver = Maybe RateSample -> IO ()

fetchGitHubSnapshot :: GhFetchGuard -> RateObserver -> LimitsConfig -> WorkflowConfig -> Repository -> IO (Either ProviderError GitHubResult)
fetchGitHubSnapshot guard observeRate limits workflowConfig repository = do
  -- Reclaim signals process groups and then confirms what it did, so it is
  -- held to the same rule as cleanup: the refresh timer may not land between
  -- those halves. Without that, a timeout arriving mid-freeze would leave the
  -- record on disk, the guard unset, and the board publishing an ordinary
  -- timeout over a group nothing had established anything about.
  -- Reclaim publishes its own outcome from inside the shield rather than
  -- having it read off afterwards. A refresh timeout pending while this waits
  -- is delivered the instant the mask lifts -- before any code out here could
  -- run -- so anything decided in between would be lost and the refresh would
  -- report an ordinary timeout over a record it had just failed to clear.
  reclaimed <- uninterruptiblyBounded reclaimInterrupted (reclaimRecordedGhGroups guard repository)
  case reclaimed of
    Left message -> pure (Left (ProviderError RequestFailed message))
    Right () -> fetchPages initialState
  where
    reclaimInterrupted = Left "reclaiming a gh process group left by an earlier GitHub refresh did not run to completion"

    initialState = FetchState [] [] Nothing Nothing True True False False True []

    fetchPages state
      | not state.fetchMoreIssues && not state.fetchMorePullRequests = do
          fetchedAt <- getCurrentTime
          let repoSnapshot =
                RepoSnapshot
                  state.fetchedIssues
                  state.fetchedPullRequests
                  fetchedAt
                  state.issuesTruncated
                  state.pullRequestsTruncated
          pure (Right (GitHubResult repoSnapshot (snapshotWarnings limits workflowConfig repoSnapshot <> state.fetchWarnings)))
      | otherwise = do
          pageResult <- fetchPage guard observeRate limits repository state
          case pageResult of
            Left providerError
              | state.fetchSubIssues && subIssueSchemaUnsupported providerError.providerErrorMessage ->
                  fetchPages
                    state
                      { fetchSubIssues = False,
                        fetchWarnings = state.fetchWarnings <> [subIssuesUnsupportedWarning]
                      }
              | otherwise -> pure (Left providerError)
            Right page -> case advanceState limits state page of
              Left providerError -> pure (Left providerError)
              Right nextState -> fetchPages nextState

-- | Whether a failed page is GitHub rejecting the sub-issue selection itself
-- rather than failing the request for some other reason.
--
-- A field the schema does not have is a validation error, so GitHub answers
-- with no @data@ at all and the refresh has no page to degrade: §12's
-- second membership source has to be dropped from the query, not from the
-- response. The match needs both halves -- one of the field names /and/ the
-- vocabulary GraphQL validation uses for an unknown field -- so an ordinary
-- server error that happens to quote the query cannot silently disable
-- native membership for the rest of the refresh.
subIssueSchemaUnsupported :: Text -> Bool
subIssueSchemaUnsupported message =
  any (`Text.isInfixOf` folded) ["subissues", "subissuessummary"]
    && any (`Text.isInfixOf` folded) ["doesn't exist", "does not exist", "cannot query field", "unknown field", "undefined field"]
  where
    folded = Text.toCaseFold message

subIssuesUnsupportedWarning :: Text
subIssuesUnsupportedWarning =
  "GitHub did not recognize native sub-issue fields; tracker membership uses checklists only"

decodeGitHubItems :: LazyByteString.ByteString -> Either String ([Issue], [PullRequest])
decodeGitHubItems input = do
  page <- (eitherDecode input :: Either String GitHubPage)
  pure
    ( maybe [] (.connectionNodes) page.pageIssues,
      maybe [] (.connectionNodes) page.pagePullRequests
    )

fetchPage :: GhFetchGuard -> RateObserver -> LimitsConfig -> Repository -> FetchState -> IO (Either ProviderError GitHubPage)
fetchPage guard observeRate limits repository state = do
  -- The unwritable-guard failure is deliberately not folded in with the
  -- IOExceptions below: those mean gh could not be run, while this means gh
  -- ran and was then stopped again because nothing durable could account for
  -- it. Reporting it as a missing executable would send the user looking in
  -- entirely the wrong place.
  guarded <- try @GhFetchAborted (try @GhProcessFailed (runGh guard repository (graphqlArguments limits repository state)))
  -- Reported off the response body rather than off a decoded page, and for a
  -- failed request as readily as a successful one: gh prints what GitHub
  -- answered whatever the status was, and a rejected page's own report is the
  -- one that says when the budget returns. A run that produced no body at all
  -- reports an unknown budget, which is what every other unusable answer
  -- reports too.
  observeRate $ case guarded of
    Right (Right (_, standardOutput, _)) -> rateSampleFromResponse standardOutput
    _ -> Nothing
  pure $ case guarded of
    Left (GhGuardUnwritable message) ->
      Left
        ProviderError
          { providerErrorKind = RequestFailed,
            providerErrorMessage = "GitHub refresh could not record the gh process it started (" <> message <> "), so it was stopped again"
          }
    Left (GhGroupUnresolved message) ->
      Left
        ProviderError
          { providerErrorKind = RequestFailed,
            providerErrorMessage = "GitHub refresh left a gh process group it could not confirm stopped (" <> message <> ")"
          }
    Right (Left (GhProcessFailed phase exception)) ->
      Left
        ProviderError
          { providerErrorKind = ghFailureKind phase exception,
            providerErrorMessage = Text.pack (show exception)
          }
    Right (Right (ExitFailure _, _, standardError)) ->
      let stderrText = decodeGhOutput standardError
       in Left
            ProviderError
              { providerErrorKind = classifyFailure stderrText,
                providerErrorMessage = compactError stderrText
              }
    Right (Right (ExitSuccess, standardOutput, _)) ->
      case eitherDecode (LazyByteString.fromStrict (TextEncoding.encodeUtf8 (decodeGhOutput standardOutput))) of
        -- GitHub answers an exhausted budget at the GraphQL layer rather than
        -- the HTTP one: a 200 carrying no @data@ and a rate-limit error. That
        -- reaches here as a decode failure whose text is GitHub's own
        -- explanation (see the 'GitHubPage' decoder), so it is sorted by what
        -- GitHub said rather than reported as malformed JSON -- which would
        -- send the user looking at a response that is perfectly well-formed
        -- and hide the one failure the scheduler can wait out.
        Left message
          | primaryRateLimited (Text.pack message) ->
              Left
                ProviderError
                  { providerErrorKind = RateLimited,
                    providerErrorMessage = compactError (Text.pack message)
                  }
          | otherwise ->
              Left
                ProviderError
                  { providerErrorKind = InvalidResponse,
                    providerErrorMessage = "GitHub returned invalid JSON: " <> Text.pack message
                  }
        Right page -> Right page

-- | Folds one decoded page into the fetch, deciding what a response GitHub
-- answered with errors is worth.
--
-- The structural checks below are what separates a partial response worth
-- rendering from a broken one. A page that passes them holds every connection
-- this request asked for, so the errors describe fields that are missing from
-- within items rather than the page itself: the board shows the data and says
-- what GitHub could not resolve. A page that fails them has a hole the
-- decoder cannot reason about, and the same messages become the explanation
-- for the failure instead of a warning beside data nobody should trust.
advanceState :: LimitsConfig -> FetchState -> GitHubPage -> Either ProviderError FetchState
advanceState limits previous page = first explainStructuralFailure $ do
  issueConnection <- requireConnection "issues" previous.fetchMoreIssues page.pageIssues
  pullRequestConnection <- requireConnection "pull requests" previous.fetchMorePullRequests page.pagePullRequests
  let newIssues = map (forgetSubIssueRequest previous.fetchSubIssues) (maybe [] (.connectionNodes) issueConnection)
      newPullRequests = maybe [] (.connectionNodes) pullRequestConnection
      allIssues = take issueLimit (previous.fetchedIssues <> newIssues)
      allPullRequests = take pullRequestLimit (previous.fetchedPullRequests <> newPullRequests)
  (moreIssues, nextIssueCursor, truncatedIssues) <-
    advanceConnection issueLimit (length allIssues) previous.fetchMoreIssues issueConnection
  (morePullRequests, nextPullRequestCursor, truncatedPullRequests) <-
    advanceConnection pullRequestLimit (length allPullRequests) previous.fetchMorePullRequests pullRequestConnection
  pure
    FetchState
      { fetchedIssues = allIssues,
        fetchedPullRequests = allPullRequests,
        issueCursor = nextIssueCursor,
        pullRequestCursor = nextPullRequestCursor,
        fetchMoreIssues = moreIssues,
        fetchMorePullRequests = morePullRequests,
        issuesTruncated = previous.issuesTruncated || truncatedIssues,
        pullRequestsTruncated = previous.pullRequestsTruncated || truncatedPullRequests,
        fetchSubIssues = previous.fetchSubIssues,
        fetchWarnings = previous.fetchWarnings <> pageWarnings
      }
  where
    issueLimit = limits.limitsMaxOpenIssues
    pullRequestLimit = limits.limitsMaxOpenPullRequests
    pageWarnings = [partialResponseWarning page.pageGraphQLErrors | not (null page.pageGraphQLErrors)]
    explainStructuralFailure providerError =
      providerError
        { providerErrorMessage = withGraphQLErrors page.pageGraphQLErrors providerError.providerErrorMessage
        }

-- | Separates \"GitHub was asked and did not answer\" from \"nobody asked\".
--
-- The decoder cannot tell the two apart: a page fetched without the sub-issue
-- selection looks exactly like one whose fields GitHub nulled out. Only the
-- fetch knows which query it sent, so it is the fetch that downgrades an
-- unreported answer to an unrequested one -- and drops the gap with it, since
-- a board that never asked has nothing missing to mark every card amber over.
forgetSubIssueRequest :: Bool -> Issue -> Issue
forgetSubIssueRequest True issue = issue
forgetSubIssueRequest False issue =
  issue
    { issueSubIssues = SubIssuesNotRequested,
      issueDataGaps = filter (/= SubIssuesUnavailable) issue.issueDataGaps
    }

requireConnection :: Text -> Bool -> Maybe (Connection item) -> Either ProviderError (Maybe (Connection item))
requireConnection _ False connection = Right connection
requireConnection connectionName True Nothing =
  Left
    ProviderError
      { providerErrorKind = InvalidResponse,
        providerErrorMessage = "GitHub response omitted the " <> connectionName <> " connection"
      }
requireConnection _ True connection = Right connection

advanceConnection :: Int -> Int -> Bool -> Maybe (Connection item) -> Either ProviderError (Bool, Maybe Text, Bool)
advanceConnection _ _ False _ = Right (False, Nothing, False)
advanceConnection limit currentCount True (Just connection) =
  paginationDecision limit currentCount pageInfo.pageHasNext pageInfo.pageEndCursor
  where
    pageInfo = connection.connectionPageInfo
advanceConnection _ _ True Nothing =
  Left (ProviderError InvalidResponse "GitHub response omitted a requested connection")

paginationDecision :: Int -> Int -> Bool -> Maybe Text -> Either ProviderError (Bool, Maybe Text, Bool)
paginationDecision _ _ False _ = Right (False, Nothing, False)
paginationDecision limit currentCount True _
  | currentCount >= limit = Right (False, Nothing, True)
paginationDecision _ _ True Nothing =
  Left
    ProviderError
      { providerErrorKind = InvalidResponse,
        providerErrorMessage = "GitHub pagination indicated another page without a cursor"
      }
paginationDecision _ _ True (Just cursor) = Right (True, Just cursor, False)

-- | Builds the @gh api graphql@ argument vector.  GraphQL @String!@
-- variables go through @-f@, gh's always-raw flag, because @-F@ coerces
-- all-digit values to Int and @true@/@false@ to Boolean: an owner or
-- repository named @12345@ would otherwise be sent as an Int and rejected
-- for every page of every refresh.  Only the genuinely typed variables --
-- the @Int!@ page sizes and @Boolean!@ fetch controls -- keep @-F@.
graphqlArguments :: LimitsConfig -> Repository -> FetchState -> [String]
graphqlArguments limits repository state =
  [ "api",
    "graphql",
    "-f",
    "owner=" <> Text.unpack repository.repositoryOwner,
    "-f",
    "name=" <> Text.unpack repository.repositoryName,
    "-F",
    "issuePageSize=" <> show issuePageSize,
    "-F",
    "pullRequestPageSize=" <> show pullRequestPageSize,
    "-F",
    "fetchIssues=" <> boolText state.fetchMoreIssues,
    "-F",
    "fetchPullRequests=" <> boolText state.fetchMorePullRequests
  ]
    <> cursorArgument "issueCursor" state.issueCursor
    <> cursorArgument "pullRequestCursor" state.pullRequestCursor
    <> ["-f", "query=" <> Text.unpack (graphqlQuery state.fetchSubIssues)]
  where
    issuePageSize = max 1 (min pageLimit (limits.limitsMaxOpenIssues - length state.fetchedIssues))
    pullRequestPageSize = max 1 (min pageLimit (limits.limitsMaxOpenPullRequests - length state.fetchedPullRequests))

-- | Cursors are declared @String@ and are opaque to us, so they are passed
-- raw as well; an all-digit cursor would otherwise corrupt pagination the
-- same way.  An absent cursor stays omitted, which is what makes a request
-- the first page.
cursorArgument :: String -> Maybe Text -> [String]
cursorArgument _ Nothing = []
cursorArgument name (Just cursor) = ["-f", name <> "=" <> Text.unpack cursor]

boolText :: Bool -> String
boolText True = "true"
boolText False = "false"

-- | The page query, with or without §12's native sub-issue selection.
--
-- The selection is a plain part of the issue node rather than an
-- @\@include@-guarded one, because a GraphQL directive still leaves the field
-- to be validated against the schema: a deployment that does not have it
-- rejects the query whatever the flag says. Two texts is what makes the
-- fallback in 'fetchPages' possible at all.
--
-- Sub-issue relationships are requested for every issue on the page rather
-- than only for trackers, since tracker recognition happens after decoding;
-- only the tracker ones are ever consumed. @first: 100@ is GitHub's own
-- per-parent sub-issue limit, so one page holds every immediate child.
graphqlQuery :: Bool -> Text
graphqlQuery withSubIssues =
  Text.unlines
    [ "query(",
      "  $owner: String!,",
      "  $name: String!,",
      "  $issueCursor: String,",
      "  $pullRequestCursor: String,",
      "  $issuePageSize: Int!,",
      "  $pullRequestPageSize: Int!,",
      "  $fetchIssues: Boolean!,",
      "  $fetchPullRequests: Boolean!",
      ") {",
      -- What the page cost, what is left, and when it returns. Requested on
      -- every page because the budget is what the scheduler above reserves
      -- foreground work out of, and a report is only worth anything while it
      -- is the newest one. The field is free: GitHub does not score it.
      "  rateLimit { cost remaining resetAt }",
      "  repository(owner: $owner, name: $name) {",
      "    nameWithOwner",
      "    issues(first: $issuePageSize, after: $issueCursor, states: OPEN) @include(if: $fetchIssues) {",
      "      nodes {",
      "        number title body url createdAt updatedAt",
      "        labels(first: 20) { totalCount nodes { name color } }",
      "        assignees(first: 10) { totalCount nodes { login } }"
    ]
    <> subIssueSelection
    <> Text.unlines
      [ "      }",
        "      pageInfo { hasNextPage endCursor }",
        "    }",
        "    pullRequests(first: $pullRequestPageSize, after: $pullRequestCursor, states: OPEN) @include(if: $fetchPullRequests) {",
        "      nodes {",
        "        number title body url createdAt updatedAt isDraft",
        "        baseRefName headRefName author { login }",
        "        labels(first: 20) { totalCount nodes { name color } }",
        "        closingIssuesReferences(first: 20) { totalCount nodes { number } }",
        "        reviewDecision mergeable mergeStateStatus",
        "        statusCheckRollup {",
        "          contexts(first: 100) {",
        "            totalCount",
        "            nodes {",
        "              __typename",
        "              ... on CheckRun { name status conclusion startedAt completedAt checkSuite { app { slug } } }",
        "              ... on StatusContext { context state createdAt creator { login } }",
        "            }",
        "          }",
        "        }",
        "      }",
        "      pageInfo { hasNextPage endCursor }",
        "    }",
        "  }",
        "}"
      ]
  where
    subIssueSelection
      | withSubIssues =
          Text.unlines
            [ "        subIssues(first: 100) { totalCount nodes { number state repository { nameWithOwner } } }",
              "        subIssuesSummary { total completed }"
            ]
      | otherwise = ""
