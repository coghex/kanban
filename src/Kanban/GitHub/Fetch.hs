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
import Kanban.GitHub.Message (classifyFailure, compactError, decodeGhOutput, partialResponseWarning, withGraphQLErrors)
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
    -- | One warning per page that arrived with GraphQL errors. A refresh spans
    -- several pages and only the last one builds the result, so a page's
    -- errors have to be carried here or they are lost with the state that
    -- decoded them.
    fetchWarnings :: [Text]
  }

pageLimit :: Int
pageLimit = 100

fetchGitHubSnapshot :: GhFetchGuard -> LimitsConfig -> WorkflowConfig -> Repository -> IO (Either ProviderError GitHubResult)
fetchGitHubSnapshot guard limits workflowConfig repository = do
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

    initialState = FetchState [] [] Nothing Nothing True True False False []

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
          pageResult <- fetchPage guard limits repository state
          case pageResult of
            Left providerError -> pure (Left providerError)
            Right page -> case advanceState limits state page of
              Left providerError -> pure (Left providerError)
              Right nextState -> fetchPages nextState

decodeGitHubItems :: LazyByteString.ByteString -> Either String ([Issue], [PullRequest])
decodeGitHubItems input = do
  page <- (eitherDecode input :: Either String GitHubPage)
  pure
    ( maybe [] (.connectionNodes) page.pageIssues,
      maybe [] (.connectionNodes) page.pagePullRequests
    )

fetchPage :: GhFetchGuard -> LimitsConfig -> Repository -> FetchState -> IO (Either ProviderError GitHubPage)
fetchPage guard limits repository state = do
  -- The unwritable-guard failure is deliberately not folded in with the
  -- IOExceptions below: those mean gh could not be run, while this means gh
  -- ran and was then stopped again because nothing durable could account for
  -- it. Reporting it as a missing executable would send the user looking in
  -- entirely the wrong place.
  guarded <- try @GhFetchAborted (try @GhProcessFailed (runGh guard repository (graphqlArguments limits repository state)))
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
        Left message ->
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
  let newIssues = maybe [] (.connectionNodes) issueConnection
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
    <> ["-f", "query=" <> Text.unpack graphqlQuery]
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

graphqlQuery :: Text
graphqlQuery =
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
      "  repository(owner: $owner, name: $name) {",
      "    issues(first: $issuePageSize, after: $issueCursor, states: OPEN) @include(if: $fetchIssues) {",
      "      nodes {",
      "        number title body url createdAt updatedAt",
      "        labels(first: 20) { totalCount nodes { name color } }",
      "        assignees(first: 10) { totalCount nodes { login } }",
      "      }",
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
