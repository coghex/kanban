-- | Decoding one GraphQL response into domain values: the envelope and its
-- @errors@ array, the issue and pull-request connections, and the status
-- check rollup.
--
-- The page shape lives here with its 'FromJSON' instances rather than beside
-- the fetch that folds it, so the decoders and the types they answer for
-- cannot drift apart. Nothing here runs a process or knows about pagination.
module Kanban.GitHub.Decode
  ( Connection (..),
    GitHubPage (..),
    PageInfo (..),
  )
where

import Control.Applicative ((<|>))
import Data.Aeson
  ( FromJSON (parseJSON),
    Object,
    Value,
    withObject,
    (.:),
    (.:?),
    (.!=),
  )
import Data.Aeson.Key (Key)
import Data.Aeson.Types (Parser, Result (..), parse, parseEither)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Domain
import Kanban.GitHub.Message (normalizeSpacing, withGraphQLErrors)

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
  { -- | GitHub's own @owner\/name@ for the repository the page was fetched
    -- from. Native sub-issue membership is decided against this rather than
    -- against the locally configured owner and name, so a repository reached
    -- through a rename redirect still recognizes its own children.
    pageRepository :: Maybe Text,
    pageIssues :: Maybe (Connection Issue),
    pagePullRequests :: Maybe (Connection PullRequest),
    -- | The messages from the response's GraphQL @errors@ array, in the order
    -- GitHub reported them. GraphQL answers a partly-resolvable query with
    -- both @data@ and @errors@, so these accompany a decoded page rather than
    -- replacing it: 'Kanban.GitHub.advanceState' turns them into a refresh
    -- warning when the page is structurally complete and folds them into the
    -- failure when it is not.
    pageGraphQLErrors :: [Text]
  }
  deriving stock (Eq, Show)

-- | One decoded rollup context. 'checkContextKey' is the deduplication
-- identity (app/name, or status creator/context), which is deliberately not
-- the name shown to the user: 'checkContextName' keeps the plain name GitHub
-- reported so the details overlay can list it.
data CheckContext = CheckContext
  { checkContextKey :: Text,
    checkContextName :: Text,
    checkContextRecency :: CheckRecency,
    checkContextState :: CheckState
  }
  deriving stock (Eq, Show)

-- | Where a rollup context ranks among the others sharing its dedup key, from
-- oldest to newest. A missing timestamp gets a rank of its own rather than the
-- empty string it used to be defaulted to, because the two context kinds mean
-- opposite things by one: a check run with neither @startedAt@ nor
-- @completedAt@ is a rerun GitHub has only just been asked for, which is
-- exactly the entry the dedup exists to prefer over the failure it supersedes,
-- while a status context with no @createdAt@ told us nothing about its age and
-- must not displace one that did. The @check:@ and @status:@ prefixes
-- 'parseCheckContext' builds keys from keep the kinds in separate dedup keys,
-- so the two rules never compete with each other.
data CheckRecency
  = -- | A status context that arrived without a @createdAt@.
    RecencyUndated
  | -- | The context's own timestamp. GitHub reports fixed-format UTC ISO-8601,
    -- so comparing the text lexicographically orders them chronologically.
    RecencyAt Text
  | -- | A check run that has neither started nor completed.
    RecencyUnstarted
  deriving stock (Eq, Ord, Show)

-- | One entry of a GraphQL response's @errors@ array. The specification makes
-- @message@ mandatory, so the fallback covers only a malformed entry -- but a
-- response already reporting errors is the worst moment to fail decoding over
-- one of them and surface nothing at all.
newtype GraphQLError = GraphQLError {graphQLErrorMessage :: Text}

instance FromJSON GraphQLError where
  parseJSON value = GraphQLError <$> (messageOf value <|> pure "(GitHub reported an error with no message)")
    where
      messageOf = withObject "GraphQL error" (fmap normalizeSpacing . (.: "message"))

-- | Decodes the GraphQL envelope. Errors no longer condemn the response on
-- their own: GraphQL reports a partly-resolvable query as @data@ /and/
-- @errors@, so what decides the outcome is whether there is a repository page
-- behind them. When there is not, the messages are the failure's explanation,
-- which is the whole of what GitHub said about it.
instance FromJSON GitHubPage where
  parseJSON = withObject "GraphQL response" $ \root -> do
    errors <- map graphQLErrorMessage <$> (root .:? "errors" .!= [])
    -- Everything past the errors is run for its result rather than being left
    -- to abort the parse on its own. A failure anywhere below -- an absent
    -- @data@, a connection that is not an object, an item missing a scalar --
    -- is a response GitHub has already said something about, and letting
    -- Aeson's text propagate alone would drop that explanation on the floor:
    -- the exact loss this decoder exists to end. 'parse' rather than
    -- 'parseEither' because only it leaves the reason unformatted, and the
    -- caller's own decode adds the one @Error in $@ this should carry.
    case parse (parseRepositoryPage errors) root of
      Error reason -> fail (Text.unpack (withGraphQLErrors errors (Text.pack reason)))
      Success page -> pure page
    where
      parseRepositoryPage errors root = do
        dataValue <- root .:? "data"
        dataObject <- maybe (fail "GitHub GraphQL response contained no data") pure dataValue
        repositoryValue <- dataObject .:? "repository"
        repositoryObject <- maybe (fail "GitHub repository was not found") pure repositoryValue
        flip (withObject "repository") repositoryObject $ \repository -> do
          identity <- repository .:? "nameWithOwner"
          GitHubPage identity
            <$> parseOptionalConnection (parseIssue identity) repository "issues"
            <*> parseOptionalConnection parsePullRequest repository "pullRequests"
            <*> pure errors

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

parseIssue :: Maybe Text -> Value -> Parser Issue
parseIssue repositoryIdentity = withObject "issue" $ \object -> do
  (labels, labelOverflow, labelGaps) <- parseNodes parseLabel object "labels" LabelsUnavailable
  (assignees, assigneeOverflow, assigneeGaps) <- parseNodes parseAssignee object "assignees" AssigneesUnavailable
  (subIssues, subIssueGaps) <- parseSubIssues repositoryIdentity object
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
    <*> pure subIssues
    <*> pure (labelGaps <> assigneeGaps <> subIssueGaps)

parsePullRequest :: Value -> Parser PullRequest
parsePullRequest = withObject "pull request" $ \object -> do
  mergeable <- object .: "mergeable"
  mergeStateStatus <- object .: "mergeStateStatus"
  (labels, labelOverflow, labelGaps) <- parseNodes parseLabel object "labels" LabelsUnavailable
  (linkedIssues, linkedIssueOverflow, linkedIssueGaps) <- parseNodes parseIssueNumber object "closingIssuesReferences" LinkedIssuesUnavailable
  (checks, checkGaps) <- parseChecks object
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
      <*> pure checks
      <*> object .: "createdAt"
      <*> object .: "updatedAt"
      <*> pure labelOverflow
      <*> pure linkedIssueOverflow
      <*> pure (labelGaps <> linkedIssueGaps <> checkGaps)

-- | A nested connection, plus the 'DataGap' to record if GitHub did not supply
-- it. @labels@, @assignees@, and @closingIssuesReferences@ are all nullable in
-- GitHub's schema, and a partial-error response nulls out exactly the fields
-- that errored, so an absent or null connection is one item's missing data
-- rather than a broken page: it decodes as no nodes and a gap on that item.
--
-- A connection that /is/ present stays strict. Malformed nodes, a missing or
-- non-numeric @totalCount@, and a @totalCount@ below the node list all still
-- fail the decode -- those describe a response this build cannot reason about
-- at all, not a field GitHub declined to deliver.
parseNodes :: (Value -> Parser item) -> Object -> Key -> DataGap -> Parser ([item], Int, [DataGap])
parseNodes itemParser object fieldName gap = do
  connection <- object .:? fieldName
  case connection of
    Nothing -> pure ([], 0, [gap])
    Just value -> withObject "nested connection" parseNested value
  where
    parseNested nested = do
      nodeValues <- nested .:? "nodes" .!= []
      totalCount <- nested .: "totalCount"
      nodes <- traverse itemParser nodeValues
      if totalCount < length nodes
        then fail "nested connection totalCount was smaller than its node list"
        else pure (nodes, totalCount - length nodes, [])

-- | An issue's native sub-issue relationships, plus the 'DataGap' to record
-- when GitHub's answer cannot be trusted as complete.
--
-- Membership can only be decided against the repository the page belongs to,
-- so a response that did not carry that identity fails closed to
-- 'SubIssuesUnreported' rather than guessing which children are local. So
-- does an absent or null @subIssues@ or @subIssuesSummary@ -- the shape a
-- partial-error response nulls a field into -- and so does a connection whose
-- @totalCount@ exceeds the children it delivered: each of those is an
-- unverified absence, never a tracker GitHub said has no children.
--
-- A connection that is present stays strict in the same places
-- 'parseNodes' is: a missing @totalCount@, a malformed child, and a
-- @totalCount@ below the node list all still fail the decode. The summary is
-- held to the same standard, because a tracker's progress is rendered
-- verbatim from it: a negative count, more completed than exist, or a total
-- below the relationships GitHub itself listed are all responses this build
-- cannot reason about, and would otherwise reach a header as @3/2 complete@
-- or as @0/0 complete@ above two visible children.
--
-- A total /above/ the connection's own count is the one direction that is
-- merely incomplete rather than impossible -- a sub-issue in a repository
-- this token cannot see is counted by GitHub and absent from the node list --
-- so it is kept, and counted among the children that did not arrive.
parseSubIssues :: Maybe Text -> Object -> Parser (NativeSubIssues, [DataGap])
parseSubIssues repositoryIdentity object = do
  connection <- object .:? "subIssues"
  summary <- object .:? "subIssuesSummary"
  case (repositoryIdentity, connection, summary) of
    (Just identity, Just connectionValue, Just summaryValue) -> do
      (children, connectionCount) <- withObject "sub-issue connection" parseChildren connectionValue
      (completed, total) <- withObject "sub-issue summary" (parseSummary connectionCount) summaryValue
      let omitted = max connectionCount total - length children
      pure
        ( SubIssuesReported (SubIssueRelationships identity children omitted completed total),
          [SubIssuesUnavailable | omitted > 0]
        )
    _ -> pure (SubIssuesUnreported, [SubIssuesUnavailable])
  where
    parseChildren connection = do
      nodeValues <- connection .:? "nodes" .!= []
      totalCount <- connection .: "totalCount"
      children <- traverse parseSubIssueLink nodeValues
      if totalCount < length children
        then fail "sub-issue connection totalCount was smaller than its node list"
        else pure (children, totalCount)
    parseSummary connectionCount summary = do
      completed <- summary .: "completed"
      total <- summary .: "total"
      maybe (pure (completed, total)) fail (summaryFault connectionCount completed total)

-- | Why a sub-issue summary cannot be believed, if it cannot. Each of these
-- describes a pair of counts no consistent response can produce, as opposed
-- to one that merely did not deliver everything.
summaryFault :: Int -> Int -> Int -> Maybe String
summaryFault connectionCount completed total
  | completed < 0 || total < 0 = Just "sub-issue summary reported a negative count"
  | completed > total = Just "sub-issue summary reported more completed sub-issues than it has"
  | total < connectionCount = Just "sub-issue summary total was smaller than its relationship connection"
  | otherwise = Nothing

parseSubIssueLink :: Value -> Parser SubIssueLink
parseSubIssueLink = withObject "sub-issue" $ \child -> do
  number <- child .: "number"
  state <- child .: "state"
  repository <- withObject "sub-issue repository" (.: "nameWithOwner") =<< child .: "repository"
  pure (SubIssueLink number repository ((state :: Text) == "CLOSED"))

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
parseMergeState "MERGEABLE" "BLOCKED" = MergeProtected
parseMergeState _ "BLOCKED" = MergeBlocked
parseMergeState _ "UNSTABLE" = MergeUnstable
parseMergeState _ _ = MergeUnknown

-- | The rollup summary, plus 'ChecksUndecodable' when a context in it could
-- not be read. The rollup's own structure stays strict -- a missing
-- @contexts@ object or @totalCount@ is a malformed response, not a degraded
-- item -- but an individual context this build does not understand fails
-- closed the way §13 already fails a rollup past the context cap: the whole
-- summary becomes 'ChecksUnknown' rather than aborting the page it arrived on.
--
-- The cap is checked before any context is decoded, so a capped rollup keeps
-- its existing meaning exactly and never picks up a gap: its summary is
-- unknown because GitHub reported more contexts than were requested, which is
-- the documented cap behavior and not an anomaly to warn about.
parseChecks :: Object -> Parser (CheckSummary, [DataGap])
parseChecks object = do
  rollup <- object .:? "statusCheckRollup"
  case rollup of
    Nothing -> pure (ChecksNone, [])
    Just value -> withObject "status check rollup" parseRollup value
  where
    parseRollup rollup = do
      contexts <- rollup .: "contexts"
      withObject "check contexts" parseContexts contexts
    parseContexts contexts = do
      totalCount <- contexts .: "totalCount"
      values <- contexts .:? "nodes" .!= []
      if totalCount > length values
        then pure (ChecksUnknown, [])
        else case traverse (parseEither parseCheckContext) values of
          Left _ -> pure (ChecksUnknown, [ChecksUndecodable])
          Right parsed -> pure (summarizeChecks parsed, [])

parseCheckContext :: Value -> Parser CheckContext
parseCheckContext = withObject "status check context" $ \context -> do
  contextType <- context .: "__typename"
  case (contextType :: Text) of
    "CheckRun" -> do
      name <- context .: "name"
      status <- context .: "status"
      conclusion <- context .:? "conclusion"
      startedAt <- optionalTimestamp <$> context .:? "startedAt"
      completedAt <- optionalTimestamp <$> context .:? "completedAt"
      app <- parseCheckRunApp context
      pure
        CheckContext
          { checkContextKey = "check:" <> app <> ":" <> name,
            checkContextName = name,
            -- A run reporting only @completedAt@ has still run, so that
            -- timestamp stays its effective one; only a run with neither is
            -- the just-requested rerun 'RecencyUnstarted' means.
            checkContextRecency = maybe RecencyUnstarted RecencyAt (startedAt <|> completedAt),
            checkContextState = classifyCheckRun status conclusion
          }
    "StatusContext" -> do
      name <- context .: "context"
      state <- context .: "state"
      createdAt <- optionalTimestamp <$> context .:? "createdAt"
      creator <- parseStatusCreator context
      pure
        CheckContext
          { checkContextKey = "status:" <> creator <> ":" <> name,
            checkContextName = name,
            checkContextRecency = maybe RecencyUndated RecencyAt createdAt,
            checkContextState = classifyStatusContext state
          }
    other -> fail ("unsupported status check context type: " <> Text.unpack other)

-- | GitHub reports a timestamp it has no value for as JSON null, and can leave
-- the field off entirely; treat an empty string the same way so \"not stamped
-- yet\" reaches 'CheckRecency' as one representation rather than three.
optionalTimestamp :: Maybe Text -> Maybe Text
optionalTimestamp (Just timestamp) | not (Text.null timestamp) = Just timestamp
optionalTimestamp _ = Nothing

parseCheckRunApp :: Object -> Parser Text
parseCheckRunApp context = do
  suite <- context .:? "checkSuite"
  case suite of
    Nothing -> pure "unknown"
    Just value -> withObject "check suite" parseSuite value
  where
    parseSuite suite = do
      app <- suite .:? "app"
      case app of
        Nothing -> pure "unknown"
        Just value -> withObject "check app" (\object -> object .:? "slug" .!= "unknown") value

parseStatusCreator :: Object -> Parser Text
parseStatusCreator context = do
  creator <- context .:? "creator"
  case creator of
    Nothing -> pure "unknown"
    Just value -> withObject "status creator" (\object -> object .:? "login" .!= "unknown") value

classifyCheckRun :: Text -> Maybe Text -> CheckState
classifyCheckRun "COMPLETED" (Just conclusion)
  | conclusion `elem` ["SUCCESS", "NEUTRAL", "SKIPPED"] = CheckPassed
  | otherwise = CheckFailed
classifyCheckRun _ _ = CheckPending

classifyStatusContext :: Text -> CheckState
classifyStatusContext "SUCCESS" = CheckPassed
classifyStatusContext "PENDING" = CheckPending
classifyStatusContext "EXPECTED" = CheckPending
classifyStatusContext _ = CheckFailed

-- | Fold the rollup into the aggregate counts the board colors read, keeping
-- the deduplicated checks that did not pass so the details overlay can name
-- them. Detail comes from exactly the same @latest@ selection as the counts,
-- so a superseded failure can never be listed beside a passing aggregate.
summarizeChecks :: [CheckContext] -> CheckSummary
summarizeChecks [] = ChecksNone
summarizeChecks contexts
  | any ((== CheckFailed) . (.checkContextState)) latest = ChecksFailed passed total outstanding
  | any ((== CheckPending) . (.checkContextState)) latest = ChecksPending passed total outstanding
  | otherwise = ChecksPassed total
  where
    latest = Map.elems (Map.fromListWith latestContext [(context.checkContextKey, context) | context <- contexts])
    total = length latest
    passed = length (filter ((== CheckPassed) . (.checkContextState)) latest)
    outstanding =
      [ CheckDetail context.checkContextName context.checkContextState
        | context <- latest,
          context.checkContextState /= CheckPassed
      ]
    -- The authoritative dedup comparator. 'CheckRecency' carries the rule for
    -- a context with no timestamp -- newest for a check run, oldest for a
    -- status context -- so all this decides is the tie: equal recencies keep
    -- @left@, which 'Map.fromListWith' hands the entry appearing later in the
    -- decoded @contexts.nodes@ order.
    latestContext left right
      | left.checkContextRecency >= right.checkContextRecency = left
      | otherwise = right
