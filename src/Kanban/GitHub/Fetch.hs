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
    HistoryFetchState (..),
    RateObserver,
    advanceHistoryState,
    advanceState,
    decodeGitHubItems,
    fetchGitHubSnapshot,
    fetchHistoryPage,
    graphqlArguments,
    historyFetchProgress,
    historyGraphqlArguments,
    historyTraversalComplete,
    initialHistoryFetchState,
    paginationDecision,
  )
where

import Control.Applicative ((<|>))
import Control.Exception (try)
import Data.Aeson (eitherDecode)
import Data.Bifunctor (first)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Time (getCurrentTime)
import Kanban.Domain
import Kanban.GitHub.Decode (Connection (..), GitHubPage (..), PageInfo (..))
import Kanban.GitHub.Guard (GhFetchGuard, reclaimRecordedGhGroups, uninterruptiblyBounded)
import Kanban.GitHub.Message (classifyFailure, compactError, decodeGhOutput, partialResponseWarning, primaryRateLimited, withGraphQLErrors)
import Kanban.GitHub.Rate (RateSample (..), rateSampleFromResponse)
import Kanban.GitHub.Run (GhFetchAborted (..), GhProcessFailed (..), ghFailureKind, runGh)
import Kanban.GitHub.Warnings (snapshotWarnings)
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import System.Exit (ExitCode (..))
import System.Timeout (timeout)

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

-- | The completed traversal's own page state.
--
-- It is a type of its own rather than a flag on 'FetchState' because the two
-- traversals are answered on different schedules: an open generation runs its
-- pages back to back inside one call, while a completed generation is one page
-- per coordinator job and has to survive between them. What it adds is the
-- pair of totals §15's progress is reported as; what it drops is the warning
-- list, since the only warning a page can raise is the sub-issue fallback the
-- open generation already reports for the same repository in the same process.
data HistoryFetchState = HistoryFetchState
  { historyFetchedIssues :: [Issue],
    historyFetchedPullRequests :: [PullRequest],
    historyIssueCursor :: Maybe Text,
    historyPullRequestCursor :: Maybe Text,
    historyMoreIssues :: Bool,
    historyMorePullRequests :: Bool,
    -- | GitHub's own count for each completed connection, once a page has
    -- reported one. It survives the connection running out, because the query
    -- stops asking for an exhausted connection at all and a total already
    -- known is not unlearned by the page that omits it.
    historyIssueTotal :: Maybe Int,
    historyPullRequestTotal :: Maybe Int,
    -- | See 'fetchSubIssues': the same one-time fallback, because a completed
    -- tracker's native children are as much a part of requirement 7's
    -- old-item update detection as its title is.
    historyFetchSubIssues :: Bool
  }
  deriving stock (Eq, Show)

initialHistoryFetchState :: HistoryFetchState
initialHistoryFetchState = HistoryFetchState [] [] Nothing Nothing True True Nothing Nothing True

-- | Whether both completed connections have reached their final page, which is
-- the only condition under which a completed generation is whole.
historyTraversalComplete :: HistoryFetchState -> Bool
historyTraversalComplete state = not state.historyMoreIssues && not state.historyMorePullRequests

historyFetchProgress :: HistoryFetchState -> CompletedProgress
historyFetchProgress state =
  CompletedProgress
    { completedIssuesLoaded = length state.historyFetchedIssues,
      completedIssuesTotal = state.historyIssueTotal,
      completedPullRequestsLoaded = length state.historyFetchedPullRequests,
      completedPullRequestsTotal = state.historyPullRequestTotal
    }

-- | GitHub's own maximum for a connection page, and therefore the size every
-- page asks for: with no configured cap to stop short of, the traversal wants
-- the fewest requests it can make.
pageLimit :: Int
pageLimit = 100

-- | Which lifecycle a page is asking about.
--
-- The two scopes differ only in the @states:@ filters and in whether the
-- connection's @totalCount@ is requested, so they share one query text and one
-- argument vector rather than two that could drift on any of the two dozen
-- fields a card is built from.
data ItemScope = OpenItems | CompletedItems
  deriving stock (Eq, Show)

-- | Everything one page request varies by: which lifecycle it asks about,
-- which connections are still being followed, and where each of them resumed.
data PageRequest = PageRequest
  { requestScope :: ItemScope,
    requestIssues :: Bool,
    requestPullRequests :: Bool,
    requestIssueCursor :: Maybe Text,
    requestPullRequestCursor :: Maybe Text,
    requestSubIssues :: Bool
  }
  deriving stock (Eq, Show)

openRequest :: FetchState -> PageRequest
openRequest state =
  PageRequest
    { requestScope = OpenItems,
      requestIssues = state.fetchMoreIssues,
      requestPullRequests = state.fetchMorePullRequests,
      requestIssueCursor = state.issueCursor,
      requestPullRequestCursor = state.pullRequestCursor,
      requestSubIssues = state.fetchSubIssues
    }

historyRequest :: HistoryFetchState -> PageRequest
historyRequest state =
  PageRequest
    { requestScope = CompletedItems,
      requestIssues = state.historyMoreIssues,
      requestPullRequests = state.historyMorePullRequests,
      requestIssueCursor = state.historyIssueCursor,
      requestPullRequestCursor = state.historyPullRequestCursor,
      requestSubIssues = state.historyFetchSubIssues
    }

-- | Told what each page reported about the budget, in the order the pages
-- were fetched.
--
-- Every page reports, whether or not it succeeded and whether or not GitHub
-- said anything usable: 'Nothing' is the honest answer for a response that
-- omitted or malformed its rate report, and the fetch carries on exactly as it
-- would have without one (§13). Only the scheduler above acts on these; the
-- fetch itself never changes course over a budget.
type RateObserver = Maybe RateSample -> IO ()

-- | Fetches one complete open generation: both connections followed to their
-- final page, published only once neither has more to give (§13).
--
-- @pageSeconds@ bounds one page request rather than the traversal. A
-- repository large enough to need twenty pages is not a repository whose
-- refresh should fail on page nineteen because the first eighteen were
-- healthy but slow; what the deadline is there to catch is a single @gh@ that
-- has stopped answering. Interrupting the page unwinds it through
-- 'Kanban.GitHub.Run.runGh'\'s own verified cleanup, exactly as the whole
-- refresh's deadline used to, so the abandoned group is dealt with before the
-- failure is reported.
fetchGitHubSnapshot :: GhFetchGuard -> RateObserver -> Int -> WorkflowConfig -> Repository -> IO (Either ProviderError GitHubResult)
fetchGitHubSnapshot guard observeRate pageSeconds workflowConfig repository = do
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
    reclaimInterrupted = Left "reclaiming a recorded gh process group did not run to completion"

    initialState = FetchState [] [] Nothing Nothing True True True []

    fetchPages state
      | not state.fetchMoreIssues && not state.fetchMorePullRequests = do
          fetchedAt <- getCurrentTime
          let repoSnapshot =
                RepoSnapshot
                  state.fetchedIssues
                  state.fetchedPullRequests
                  fetchedAt
          pure (Right (GitHubResult repoSnapshot (snapshotWarnings workflowConfig repoSnapshot <> state.fetchWarnings)))
      | otherwise = do
          timedPage <- timeout (pageSeconds * 1000000) (fetchPage guard observeRate repository (openRequest state))
          case timedPage of
            Nothing -> pure (Left (pageTimedOut pageSeconds))
            Just (Left providerError)
              | state.fetchSubIssues && subIssueSchemaUnsupported providerError.providerErrorMessage ->
                  fetchPages
                    state
                      { fetchSubIssues = False,
                        fetchWarnings = state.fetchWarnings <> [subIssuesUnsupportedWarning]
                      }
              | otherwise -> pure (Left providerError)
            Just (Right page) -> case advanceState state page of
              Left providerError -> pure (Left providerError)
              Right nextState -> fetchPages nextState

-- | Fetches exactly one page of the completed traversal and folds it in.
--
-- One page rather than the whole of it, because the coordinator gives the
-- owner back at every page boundary (§15) and the accumulator between calls is
-- the caller's to hold. Everything else is the open traversal's: the same
-- reclaim before anything is spawned, the same per-page deadline, the same
-- verified @gh@ cleanup on the way out, and the same one-time retreat from a
-- deployment whose schema has no sub-issue fields.
fetchHistoryPage :: GhFetchGuard -> RateObserver -> Int -> Repository -> HistoryFetchState -> IO (Either ProviderError HistoryFetchState)
fetchHistoryPage guard observeRate pageSeconds repository initial = do
  -- The record is the only thing that carries "a gh of ours may still be
  -- running" across a job, and a history page spawns gh exactly as a foreground
  -- one does, so it is held to the same refusal rather than starting beside a
  -- group nothing has confirmed gone.
  reclaimed <- uninterruptiblyBounded reclaimInterrupted (reclaimRecordedGhGroups guard repository)
  case reclaimed of
    Left message -> pure (Left (ProviderError RequestFailed message))
    Right () -> fetchOnce initial
  where
    reclaimInterrupted = Left "reclaiming a recorded gh process group did not run to completion"

    fetchOnce state = do
      timedPage <- timeout (pageSeconds * 1000000) (fetchPage guard observeRate repository (historyRequest state))
      case timedPage of
        Nothing -> pure (Left (pageTimedOut pageSeconds))
        Just (Left providerError)
          | state.historyFetchSubIssues && subIssueSchemaUnsupported providerError.providerErrorMessage ->
              fetchOnce state {historyFetchSubIssues = False}
          | otherwise -> pure (Left providerError)
        Just (Right page) -> pure (advanceHistoryState state page)

-- | What a page that outran the configured GitHub timeout reports. The
-- wording is the one §17 already renders for a refresh that timed out, since
-- from the board's side a page that never answered /is/ the refresh timing
-- out.
pageTimedOut :: Int -> ProviderError
pageTimedOut pageSeconds =
  ProviderError
    RequestTimedOut
    ("GitHub refresh timed out after " <> Text.pack (show pageSeconds) <> " seconds")

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

fetchPage :: GhFetchGuard -> RateObserver -> Repository -> PageRequest -> IO (Either ProviderError GitHubPage)
fetchPage guard observeRate repository request = do
  -- The unwritable-guard failure is deliberately not folded in with the
  -- IOExceptions below: those mean gh could not be run, while this means gh
  -- ran and was then stopped again because nothing durable could account for
  -- it. Reporting it as a missing executable would send the user looking in
  -- entirely the wrong place.
  guarded <- try @GhFetchAborted (try @GhProcessFailed (runGh guard repository (pageArguments repository request)))
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
advanceState :: FetchState -> GitHubPage -> Either ProviderError FetchState
advanceState previous page = first explainStructuralFailure $ do
  issueConnection <- requireConnection "issues" previous.fetchMoreIssues page.pageIssues
  pullRequestConnection <- requireConnection "pull requests" previous.fetchMorePullRequests page.pagePullRequests
  let newIssues = map (forgetSubIssueRequest previous.fetchSubIssues) (maybe [] (.connectionNodes) issueConnection)
      newPullRequests = maybe [] (.connectionNodes) pullRequestConnection
  (moreIssues, nextIssueCursor) <- advanceConnection previous.fetchMoreIssues issueConnection
  (morePullRequests, nextPullRequestCursor) <- advanceConnection previous.fetchMorePullRequests pullRequestConnection
  pure
    FetchState
      { fetchedIssues = previous.fetchedIssues <> newIssues,
        fetchedPullRequests = previous.fetchedPullRequests <> newPullRequests,
        issueCursor = nextIssueCursor,
        pullRequestCursor = nextPullRequestCursor,
        fetchMoreIssues = moreIssues,
        fetchMorePullRequests = morePullRequests,
        fetchSubIssues = previous.fetchSubIssues,
        fetchWarnings = previous.fetchWarnings <> pageWarnings
      }
  where
    pageWarnings = [partialResponseWarning page.pageGraphQLErrors | not (null page.pageGraphQLErrors)]
    explainStructuralFailure providerError =
      providerError
        { providerErrorMessage = withGraphQLErrors page.pageGraphQLErrors providerError.providerErrorMessage
        }

-- | Folds one decoded completed page into the traversal.
--
-- It answers the same structural questions 'advanceState' does, and defers to
-- the same helpers for them, so the two traversals cannot disagree about what
-- an omitted connection or a next page without a cursor means. The GraphQL
-- @errors@ array is deliberately not carried: a completed page that is
-- structurally intact and partly errored degrades its own items exactly as an
-- open one does, and the banner that would report it belongs to the open
-- generation this slice does not touch.
advanceHistoryState :: HistoryFetchState -> GitHubPage -> Either ProviderError HistoryFetchState
advanceHistoryState previous page = first explainStructuralFailure $ do
  issueConnection <- requireConnection "issues" previous.historyMoreIssues page.pageIssues
  pullRequestConnection <- requireConnection "pull requests" previous.historyMorePullRequests page.pagePullRequests
  let newIssues = map (forgetSubIssueRequest previous.historyFetchSubIssues) (maybe [] (.connectionNodes) issueConnection)
      newPullRequests = maybe [] (.connectionNodes) pullRequestConnection
  (moreIssues, nextIssueCursor) <- advanceConnection previous.historyMoreIssues issueConnection
  (morePullRequests, nextPullRequestCursor) <- advanceConnection previous.historyMorePullRequests pullRequestConnection
  pure
    HistoryFetchState
      { historyFetchedIssues = previous.historyFetchedIssues <> newIssues,
        historyFetchedPullRequests = previous.historyFetchedPullRequests <> newPullRequests,
        historyIssueCursor = nextIssueCursor,
        historyPullRequestCursor = nextPullRequestCursor,
        historyMoreIssues = moreIssues,
        historyMorePullRequests = morePullRequests,
        historyIssueTotal = (issueConnection >>= (.connectionTotalCount)) <|> previous.historyIssueTotal,
        historyPullRequestTotal = (pullRequestConnection >>= (.connectionTotalCount)) <|> previous.historyPullRequestTotal,
        historyFetchSubIssues = previous.historyFetchSubIssues
      }
  where
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

advanceConnection :: Bool -> Maybe (Connection item) -> Either ProviderError (Bool, Maybe Text)
advanceConnection False _ = Right (False, Nothing)
advanceConnection True (Just connection) =
  paginationDecision pageInfo.pageHasNext pageInfo.pageEndCursor
  where
    pageInfo = connection.connectionPageInfo
advanceConnection True Nothing =
  Left (ProviderError InvalidResponse "GitHub response omitted a requested connection")

-- | Whether this connection has another page, and the cursor to ask for it
-- with. @hasNextPage@ is the only thing that ends a traversal: there is no
-- cap left for a connection to reach, so a repository with a thousand open
-- issues is followed to its thousandth (§13).
paginationDecision :: Bool -> Maybe Text -> Either ProviderError (Bool, Maybe Text)
paginationDecision False _ = Right (False, Nothing)
paginationDecision True Nothing =
  Left
    ProviderError
      { providerErrorKind = InvalidResponse,
        providerErrorMessage = "GitHub pagination indicated another page without a cursor"
      }
paginationDecision True (Just cursor) = Right (True, Just cursor)

-- | Builds the @gh api graphql@ argument vector.  GraphQL @String!@
-- variables go through @-f@, gh's always-raw flag, because @-F@ coerces
-- all-digit values to Int and @true@/@false@ to Boolean: an owner or
-- repository named @12345@ would otherwise be sent as an Int and rejected
-- for every page of every refresh.  Only the genuinely typed variables --
-- the @Int!@ page sizes and @Boolean!@ fetch controls -- keep @-F@.
graphqlArguments :: Repository -> FetchState -> [String]
graphqlArguments repository = pageArguments repository . openRequest

-- | The completed traversal's argument vector, built by the same rules from
-- the same builder — only the scope differs.
historyGraphqlArguments :: Repository -> HistoryFetchState -> [String]
historyGraphqlArguments repository = pageArguments repository . historyRequest

pageArguments :: Repository -> PageRequest -> [String]
pageArguments repository request =
  [ "api",
    "graphql",
    "-f",
    "owner=" <> Text.unpack repository.repositoryOwner,
    "-f",
    "name=" <> Text.unpack repository.repositoryName,
    "-F",
    "issuePageSize=" <> show pageLimit,
    "-F",
    "pullRequestPageSize=" <> show pageLimit,
    "-F",
    "fetchIssues=" <> boolText request.requestIssues,
    "-F",
    "fetchPullRequests=" <> boolText request.requestPullRequests
  ]
    <> cursorArgument "issueCursor" request.requestIssueCursor
    <> cursorArgument "pullRequestCursor" request.requestPullRequestCursor
    <> ["-f", "query=" <> Text.unpack (graphqlQuery request.requestScope request.requestSubIssues)]

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

-- | The page query, for one lifecycle scope, with or without §12's native
-- sub-issue selection.
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
--
-- The two scopes select the same fields from the same connections and differ
-- only in the @states:@ filters and in the completed scope's @totalCount@.
-- Sharing one text is what keeps requirement 7 true without a second list to
-- maintain: a field a card is built from is asked for in both scopes or in
-- neither, so an edit to a long-closed item is picked up by the same
-- selection that would have picked it up while the item was open.
graphqlQuery :: ItemScope -> Bool -> Text
graphqlQuery scope withSubIssues =
  queryLines
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
      "    issues(first: $issuePageSize, after: $issueCursor, states: " <> issueStates <> ") @include(if: $fetchIssues) {",
      connectionTotal,
      "      nodes {",
      "        number title body url state createdAt updatedAt",
      "        labels(first: 20) { totalCount nodes { name color } }",
      "        assignees(first: 10) { totalCount nodes { login } }"
    ]
    <> subIssueSelection
    <> queryLines
      [ "      }",
        "      pageInfo { hasNextPage endCursor }",
        "    }",
        "    pullRequests(first: $pullRequestPageSize, after: $pullRequestCursor, states: " <> pullRequestStates <> ") @include(if: $fetchPullRequests) {",
        connectionTotal,
        "      nodes {",
        "        number title body url state createdAt updatedAt isDraft",
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
    (issueStates, pullRequestStates) = case scope of
      OpenItems -> ("OPEN", "OPEN")
      CompletedItems -> ("[CLOSED]", "[CLOSED, MERGED]")
    -- Only the completed scope pays for it, and only because §15's progress is
    -- a loaded/total pair: the open generation publishes atomically and has
    -- nothing to report a denominator for.
    connectionTotal = case scope of
      OpenItems -> ""
      CompletedItems -> "      totalCount"
    -- A selection the scope does not want is an empty entry rather than an
    -- absent one, and a blank line in the middle of a query is noise in every
    -- log that ever prints it.
    queryLines = Text.unlines . filter (not . Text.null)
    subIssueSelection
      | withSubIssues =
          Text.unlines
            [ "        subIssues(first: 100) { totalCount nodes { number state repository { nameWithOwner } } }",
              "        subIssuesSummary { total completed }"
            ]
      | otherwise = ""
