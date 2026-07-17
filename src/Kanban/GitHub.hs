module Kanban.GitHub
  ( GitHubResult (..),
    decodeGitHubItems,
    fetchGitHubSnapshot,
    paginationDecision,
    snapshotWarnings,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.Aeson
  ( FromJSON (parseJSON),
    Object,
    Value,
    eitherDecode,
    withObject,
    (.:),
    (.:?),
    (.!=),
  )
import Data.Aeson.Key (Key)
import Data.Aeson.Types (Parser)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Lazy as LazyText
import qualified Data.Text.Lazy.Encoding as LazyTextEncoding
import Data.Time (getCurrentTime)
import Kanban.Domain
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.Tracker (trackerDiagnosticsForIssue)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data GitHubResult = GitHubResult
  { githubSnapshot :: RepoSnapshot,
    githubWarnings :: [Text]
  }
  deriving stock (Eq, Show)

data PageInfo = PageInfo
  { pageHasNext :: Bool,
    pageEndCursor :: Maybe Text
  }
  deriving stock (Eq, Show)

data Connection item = Connection
  { connectionNodes :: [item],
    connectionPageInfo :: PageInfo
  }
  deriving stock (Eq, Show)

data GitHubPage = GitHubPage
  { pageIssues :: Maybe (Connection Issue),
    pagePullRequests :: Maybe (Connection PullRequest)
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
    pullRequestsTruncated :: Bool
  }

issueLimit, pullRequestLimit, pageLimit :: Int
issueLimit = 250
pullRequestLimit = 100
pageLimit = 100

fetchGitHubSnapshot :: Repository -> IO (Either ProviderError GitHubResult)
fetchGitHubSnapshot repository = fetchPages initialState
  where
    initialState = FetchState [] [] Nothing Nothing True True False False

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
          pure (Right (GitHubResult repoSnapshot (snapshotWarnings repoSnapshot)))
      | otherwise = do
          pageResult <- fetchPage repository state
          case pageResult of
            Left providerError -> pure (Left providerError)
            Right page -> case advanceState state page of
              Left providerError -> pure (Left providerError)
              Right nextState -> fetchPages nextState

decodeGitHubItems :: LazyByteString.ByteString -> Either String ([Issue], [PullRequest])
decodeGitHubItems input = do
  page <- (eitherDecode input :: Either String GitHubPage)
  pure
    ( maybe [] (.connectionNodes) page.pageIssues,
      maybe [] (.connectionNodes) page.pagePullRequests
    )

fetchPage :: Repository -> FetchState -> IO (Either ProviderError GitHubPage)
fetchPage repository state = do
  processResult <-
    try @IOException
      ( readProcessWithExitCode
          "gh"
          (graphqlArguments repository state)
          ""
      )
  pure $ case processResult of
    Left exception ->
      Left
        ProviderError
          { providerErrorKind = ExecutableMissing,
            providerErrorMessage = Text.pack (show exception)
          }
    Right (ExitFailure _, _, stderrText) ->
      Left
        ProviderError
          { providerErrorKind = classifyFailure (Text.pack stderrText),
            providerErrorMessage = compactError stderrText
          }
    Right (ExitSuccess, stdoutText, _) ->
      case eitherDecode (LazyTextEncoding.encodeUtf8 (LazyText.pack stdoutText)) of
        Left message ->
          Left
            ProviderError
              { providerErrorKind = InvalidResponse,
                providerErrorMessage = "GitHub returned invalid JSON: " <> Text.pack message
              }
        Right page -> Right page

advanceState :: FetchState -> GitHubPage -> Either ProviderError FetchState
advanceState previous page = do
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
        pullRequestsTruncated = previous.pullRequestsTruncated || truncatedPullRequests
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

graphqlArguments :: Repository -> FetchState -> [String]
graphqlArguments repository state =
  [ "api",
    "graphql",
    "-F",
    "owner=" <> Text.unpack repository.repositoryOwner,
    "-F",
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
    issuePageSize = max 1 (min pageLimit (issueLimit - length state.fetchedIssues))
    pullRequestPageSize = max 1 (min pageLimit (pullRequestLimit - length state.fetchedPullRequests))

cursorArgument :: String -> Maybe Text -> [String]
cursorArgument _ Nothing = []
cursorArgument name (Just cursor) = ["-F", name <> "=" <> Text.unpack cursor]

boolText :: Bool -> String
boolText True = "true"
boolText False = "false"

classifyFailure :: Text -> ProviderErrorKind
classifyFailure message
  | any (`Text.isInfixOf` Text.toCaseFold message) ["authentication", "not logged", "oauth", "token"] = AuthenticationRequired
  | otherwise = RequestFailed

compactError :: String -> Text
compactError rawMessage =
  let message = Text.unwords (Text.words (Text.pack rawMessage))
   in if Text.null message then "GitHub request failed" else Text.take 500 message

instance FromJSON GitHubPage where
  parseJSON = withObject "GraphQL response" $ \root -> do
    errors <- root .:? "errors" .!= ([] :: [Value])
    unless (null errors) (fail "GitHub GraphQL response contained errors")
    dataObject <- root .: "data"
    repositoryValue <- dataObject .:? "repository"
    repositoryObject <- maybe (fail "GitHub repository was not found") pure repositoryValue
    withObject "repository" parseRepositoryPage repositoryObject
    where
      parseRepositoryPage repositoryObject =
        GitHubPage
          <$> parseOptionalConnection parseIssue repositoryObject "issues"
          <*> parseOptionalConnection parsePullRequest repositoryObject "pullRequests"

instance FromJSON PageInfo where
  parseJSON = withObject "pageInfo" $ \object ->
    PageInfo
      <$> object .: "hasNextPage"
      <*> object .:? "endCursor"

parseOptionalConnection :: (Value -> Parser item) -> Object -> Key -> Parser (Maybe (Connection item))
parseOptionalConnection itemParser object fieldName = do
  value <- object .:? fieldName
  traverse (parseConnection itemParser) value

parseConnection :: (Value -> Parser item) -> Value -> Parser (Connection item)
parseConnection itemParser = withObject "connection" $ \object -> do
  nodes <- object .:? "nodes" .!= []
  Connection
    <$> traverse itemParser nodes
    <*> object .: "pageInfo"

parseLabel :: Value -> Parser Label
parseLabel = withObject "label" $ \object ->
  Label
    <$> object .: "name"
    <*> object .: "color"

parseAssignee :: Value -> Parser Assignee
parseAssignee = withObject "assignee" $ \object -> Assignee <$> object .: "login"

parseIssue :: Value -> Parser Issue
parseIssue = withObject "issue" $ \object -> do
  (labels, labelOverflow) <- parseNodes parseLabel object "labels"
  (assignees, assigneeOverflow) <- parseNodes parseAssignee object "assignees"
  Issue
    <$> object .: "number"
    <*> object .: "title"
    <*> object .:? "body" .!= ""
    <*> object .: "url"
    <*> pure labels
    <*> pure assignees
    <*> object .: "createdAt"
    <*> object .: "updatedAt"
    <*> pure labelOverflow
    <*> pure assigneeOverflow

parsePullRequest :: Value -> Parser PullRequest
parsePullRequest = withObject "pull request" $ \object -> do
  mergeable <- object .: "mergeable"
  mergeStateStatus <- object .: "mergeStateStatus"
  (labels, labelOverflow) <- parseNodes parseLabel object "labels"
  (linkedIssues, linkedIssueOverflow) <- parseNodes parseIssueNumber object "closingIssuesReferences"
  PullRequest
      <$> object .: "number"
      <*> object .: "title"
      <*> object .:? "body" .!= ""
      <*> object .: "url"
      <*> pure labels
      <*> parseAuthor object
      <*> object .: "isDraft"
      <*> object .: "baseRefName"
      <*> object .: "headRefName"
      <*> pure linkedIssues
      <*> (parseReviewDecision <$> object .:? "reviewDecision")
      <*> pure (parseMergeState mergeable mergeStateStatus)
      <*> parseChecks object
      <*> object .: "createdAt"
      <*> object .: "updatedAt"
      <*> pure labelOverflow
      <*> pure linkedIssueOverflow

parseNodes :: (Value -> Parser item) -> Object -> Key -> Parser ([item], Int)
parseNodes itemParser object fieldName = do
  connection <- object .: fieldName
  withObject "nested connection" parseNested connection
  where
    parseNested nested = do
      nodeValues <- nested .:? "nodes" .!= []
      totalCount <- nested .: "totalCount"
      nodes <- traverse itemParser nodeValues
      if totalCount < length nodes
        then fail "nested connection totalCount was smaller than its node list"
        else pure (nodes, totalCount - length nodes)

parseIssueNumber :: Value -> Parser Int
parseIssueNumber = withObject "issue reference" (.: "number")

parseAuthor :: Object -> Parser Text
parseAuthor object = do
  author <- object .:? "author"
  case author of
    Nothing -> pure "ghost"
    Just value -> withObject "author" (\actor -> actor .: "login") value

parseReviewDecision :: Maybe Text -> ReviewDecision
parseReviewDecision (Just "APPROVED") = ReviewApproved
parseReviewDecision (Just "CHANGES_REQUESTED") = ReviewChangesRequested
parseReviewDecision (Just "REVIEW_REQUIRED") = ReviewRequired
parseReviewDecision _ = ReviewUnknown

parseMergeState :: Text -> Text -> MergeState
parseMergeState "CONFLICTING" _ = MergeConflicting
parseMergeState _ "DIRTY" = MergeConflicting
parseMergeState _ "CLEAN" = MergeClean
parseMergeState _ "BEHIND" = MergeBehind
parseMergeState _ "BLOCKED" = MergeBlocked
parseMergeState _ "UNSTABLE" = MergeUnstable
parseMergeState _ _ = MergeUnknown

parseChecks :: Object -> Parser CheckSummary
parseChecks object = do
  rollup <- object .:? "statusCheckRollup"
  case rollup of
    Nothing -> pure ChecksNone
    Just value -> withObject "status check rollup" parseRollup value
  where
    parseRollup rollup = do
      state <- rollup .: "state"
      contexts <- rollup .: "contexts"
      total <- withObject "check contexts" (.: "totalCount") contexts
      pure $ case (state :: Text) of
        "SUCCESS" -> ChecksPassed total
        "FAILURE" -> ChecksFailed 0 total
        "ERROR" -> ChecksFailed 0 total
        "PENDING" -> ChecksPending 0 total
        "EXPECTED" -> ChecksPending 0 total
        _ -> ChecksUnknown

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
      "        statusCheckRollup { state contexts(first: 1) { totalCount } }",
      "      }",
      "      pageInfo { hasNextPage endCursor }",
      "    }",
      "  }",
      "}"
    ]

snapshotWarnings :: RepoSnapshot -> [Text]
snapshotWarnings snapshot =
  [showText issueLimit <> "+ open issues; board is truncated" | snapshot.snapshotIssuesTruncated]
    <> [showText pullRequestLimit <> "+ open pull requests; board is truncated" | snapshot.snapshotPullRequestsTruncated]
    <> [ nestedCountText nestedOverflowItems
           <> " contain truncated labels, assignees, or linked issues; +N markers show omitted values"
       | nestedOverflowItems > 0
       ]
    <> [ trackerCountText malformedTrackers
           <> " have malformed or missing child checklists; amber diagnostics show the cause"
       | malformedTrackers > 0
       ]
  where
    nestedOverflowItems =
      length (filter issueHasOverflow snapshot.snapshotIssues)
        + length (filter pullRequestHasOverflow snapshot.snapshotPullRequests)
    issueHasOverflow issue = issue.issueLabelOverflow > 0 || issue.issueAssigneeOverflow > 0
    pullRequestHasOverflow pullRequest = pullRequest.pullRequestLabelOverflow > 0 || pullRequest.pullRequestLinkedIssueOverflow > 0
    malformedTrackers =
      length
        ( filter
            (not . null . trackerDiagnosticsForIssue defaultWorkflowConfig)
            snapshot.snapshotIssues
        )
    nestedCountText 1 = "1 card"
    nestedCountText count = showText count <> " cards"
    trackerCountText 1 = "1 tracker"
    trackerCountText count = showText count <> " trackers"

showText :: Show value => value -> Text
showText = Text.pack . show
