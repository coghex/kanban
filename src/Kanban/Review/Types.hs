{-# LANGUAGE DeriveGeneric #-}

-- | The review workflow's wire and result payloads: the app-server message
-- shapes, the dynamic tools' request shapes, the canonical gate's verdict,
-- and the decoders and renderers that belong to them.
--
-- Deliberately free of handles, processes, and client state, so it sits
-- below every other @Kanban.Review.*@ module and all of them can agree on
-- one set of payload types without a cycle. The one thing it does sit above
-- is "Kanban.Review.Connection": a review event names the thread it happened
-- on, and a thread is only identified by its connection and the provider's
-- own id together.
module Kanban.Review.Types
  ( CanonicalIssueReviewResult (..),
    ClaudeToolRequest (..),
    GitHubIssueOperation (..),
    GitHubIssueToolRequest (..),
    ReviewAnswer (..),
    ReviewApproval (..),
    ReviewChoice (..),
    ReviewEvent (..),
    ReviewOutputKind (..),
    ReviewQuestion (..),
    ReviewQuestionKind (..),
    ReviewRequestId (..),
    ReviewResult (..),
    ReviewStage (..),
    ReviewTurnOutcome (..),
    ReviewWireMessage (..),
    decodeCanonicalIssueReviewResult,
    decodeClaudeToolPrompt,
    decodeGitHubIssueToolRequest,
    decodeReviewQuestion,
    decodeReviewResult,
    decodeReviewWireMessage,
    parseClaudeToolRequest,
    parseQuestionValue,
    renderReviewResult,
    reviewResultHeading,
    reviewStageForLabels,
    reviewWorkflowLabels,
  )
where

import Data.Aeson
  ( FromJSON (..),
    Result (..),
    Value (..),
    eitherDecode,
    fromJSON,
    withObject,
    (.:),
    (.:?),
    (.!=),
  )
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import GHC.Generics (Generic)
import Kanban.Domain (WorkflowConfig (..))
import Kanban.Review.Connection (ConnectionId, ReviewThreadId)

-- | A request the provider sent /this/ client, which the user answers later
-- through 'Kanban.Review.answerReviewQuestion' or
-- 'Kanban.Review.approveReviewAction'.
--
-- The connection travels with the wire id because the answer may be minutes
-- behind the question, and two connections numbering their own server
-- requests will reuse each other's ids. Only the pair says where the answer
-- has to be written.
data ReviewRequestId = ReviewRequestId
  { reviewRequestConnection :: ConnectionId,
    reviewRequestWireId :: Value
  }
  deriving stock (Eq, Show)

data ReviewQuestionKind = QuestionChoice | QuestionText
  deriving stock (Eq, Show)

data ReviewChoice = ReviewChoice
  { reviewChoiceId :: Text,
    reviewChoiceLabel :: Text,
    reviewChoiceDescription :: Text
  }
  deriving stock (Eq, Show, Generic)

data ReviewQuestion = ReviewQuestion
  { reviewQuestionId :: Text,
    reviewQuestionHeader :: Text,
    reviewQuestionText :: Text,
    reviewQuestionKind :: ReviewQuestionKind,
    reviewQuestionChoices :: [ReviewChoice],
    reviewQuestionAllowOther :: Bool,
    reviewQuestionMultiple :: Bool
  }
  deriving stock (Eq, Show, Generic)

data ReviewAnswer = ReviewAnswer
  { reviewAnswerSelections :: [Text],
    reviewAnswerOther :: Maybe Text
  }
  deriving stock (Eq, Show)

data ReviewApproval =
  ReviewApproval
    { reviewApprovalCommand :: Maybe Text,
      reviewApprovalReason :: Maybe Text,
      reviewApprovalFileChange :: Bool
    }
  deriving stock (Eq, Show)

data ReviewOutputKind = AgentOutput | ReasoningOutput | CommandOutput | DiagnosticOutput
  deriving stock (Eq, Show)

data ReviewTurnOutcome = TurnSucceeded | TurnFailed | TurnInterrupted
  deriving stock (Eq, Show)

data ReviewStage = InitialReview | IssueRevision | IssueRereview
  deriving stock (Eq, Show)

data ReviewResult = ReviewResult
  { reviewResultIssue :: Int,
    reviewResultStage :: ReviewStage,
    reviewResultApproved :: Bool,
    reviewResultReviewerRoute :: Text,
    reviewResultModels :: [Text],
    reviewResultCommentUrl :: Maybe Text,
    reviewResultBlockingReasons :: [Text]
  }
  deriving stock (Eq, Show, Generic)

data CanonicalIssueReviewResult = CanonicalIssueReviewResult
  { canonicalReviewApproved :: Bool,
    canonicalReviewIssue :: Int,
    canonicalReviewOrigin :: Text,
    canonicalReviewRequiredReviewers :: Maybe Text,
    canonicalReviewRequiredModels :: Maybe Text,
    canonicalReviewReasons :: [Text]
  }
  deriving stock (Eq, Show, Generic)

data ReviewEvent
  = ReviewThreadCreated Int ReviewThreadId
  | ReviewTurnStarted ReviewThreadId Text
  | ReviewOutput ReviewThreadId ReviewOutputKind Text
  | ReviewQuestionRequested ReviewThreadId ReviewRequestId ReviewQuestion
  | ReviewApprovalRequested ReviewThreadId ReviewRequestId ReviewApproval
  | -- | A @kanban_run_claude@ call has started, carrying the thread and the
    -- @display@ of the @issue_revise.claude@ cell it resolved.
    --
    -- The display travels /with/ the event rather than being looked up when
    -- it is handled. The tool runs in a fork, so a backend teardown or
    -- restart can be handled first: a consumer that resolved the cell at
    -- handling time would name a replacement client's assignment, or none at
    -- all, for a call that is running on the roster this one captured.
    ReviewClaudeStarted ReviewThreadId Text
  | ReviewClaudeFinished ReviewThreadId (Either Text ())
  | ReviewGitHubStarted ReviewThreadId Text
  | ReviewGitHubFinished ReviewThreadId (Either Text Text)
  | ReviewTurnCompleted ReviewThreadId ReviewTurnOutcome (Maybe Text) (Maybe (Text, ReviewResult))
  | ReviewStartFailed Int Text
  | -- | The client is finished: the one connection every thread was
    -- multiplexed onto has ended, so nothing it was serving can continue.
    -- Emitted only by a backend that shares one process across every review
    -- thread, which is the only shape in which one connection ending is the
    -- whole client ending.
    ReviewClientStopped Text
  | -- | One of several connections has ended while the client remains
    -- usable. Only the threads this connection served are finished; a thread
    -- on another connection is untouched, and a new review may still be
    -- started. Emitted by a backend that gives each review thread its own
    -- process.
    ReviewConnectionStopped ConnectionId Text
  -- | A @turn/steer@ the app-server rejected whose text could not be resent
  -- automatically, carrying the thread, the turn the steer targeted, and the
  -- user's original message so the session can offer it back for a deliberate
  -- resend (issue #17). Emitted only when a turn is still active on the
  -- thread: with no active turn the message is resent as a new @turn/start@
  -- instead, and nothing is reported.
  | ReviewSteerUndelivered ReviewThreadId Text Text
  | ReviewProtocolWarning Text
  deriving stock (Eq, Show)

data ReviewWireMessage
  = WireResponse Value (Either Value Value)
  | WireNotification Text Value
  | WireRequest Value Text Value
  deriving stock (Eq, Show)

newtype ClaudeToolRequest = ClaudeToolRequest
  { claudeToolPrompt :: Text
  }
  deriving stock (Eq, Show)

data GitHubIssueOperation = GitHubIssueRead | GitHubIssueUpdate
  deriving stock (Eq, Show)

data GitHubIssueToolRequest = GitHubIssueToolRequest
  { githubToolOperation :: GitHubIssueOperation,
    githubToolIssue :: Int,
    githubToolComment :: Maybe Text,
    githubToolAddLabels :: [Text],
    githubToolRemoveLabels :: [Text]
  }
  deriving stock (Eq, Show)

instance FromJSON ReviewChoice where
  parseJSON = withObject "ReviewChoice" $ \value ->
    ReviewChoice
      <$> value .: "id"
      <*> value .: "label"
      <*> value .:? "description" .!= ""

instance FromJSON ReviewQuestion where
  parseJSON = withObject "ReviewQuestion" $ \value -> do
    kindText <- value .:? "kind" .!= ("choice" :: Text)
    kind <- case Text.toCaseFold kindText of
      "choice" -> pure QuestionChoice
      "text" -> pure QuestionText
      _ -> fail "question kind must be choice or text"
    ReviewQuestion
      <$> value .: "id"
      <*> value .:? "header" .!= "INPUT REQUIRED"
      <*> value .: "question"
      <*> pure kind
      <*> value .:? "options" .!= []
      <*> value .:? "allowOther" .!= False
      <*> value .:? "multiple" .!= False

instance FromJSON ReviewResult where
  parseJSON = withObject "ReviewResult" $ \value -> do
    stageText <- value .: "stage"
    stage <- case (stageText :: Text) of
      "review" -> pure InitialReview
      "revision" -> pure IssueRevision
      "rereview" -> pure IssueRereview
      _ -> fail "stage must be review, revision, or rereview"
    ReviewResult
      <$> value .: "issue"
      <*> pure stage
      <*> value .: "approved"
      <*> value .: "reviewerRoute"
      <*> value .: "models"
      <*> value .:? "commentUrl"
      <*> value .: "blockingReasons"

instance FromJSON CanonicalIssueReviewResult where
  parseJSON = withObject "CanonicalIssueReviewResult" $ \value ->
    CanonicalIssueReviewResult
      <$> value .: "approved"
      <*> value .: "issue"
      <*> value .: "origin"
      <*> value .:? "required_reviewers"
      <*> value .:? "required_models"
      <*> value .:? "reasons" .!= []

instance FromJSON ClaudeToolRequest where
  parseJSON = withObject "ClaudeToolRequest" $ \value -> ClaudeToolRequest <$> value .: "prompt"

instance FromJSON GitHubIssueToolRequest where
  parseJSON = withObject "GitHubIssueToolRequest" $ \value -> do
    operationText <- value .: "operation"
    operation <- case (operationText :: Text) of
      "read" -> pure GitHubIssueRead
      "update" -> pure GitHubIssueUpdate
      _ -> fail "operation must be read or update"
    GitHubIssueToolRequest
      <$> pure operation
      <*> value .: "issue"
      <*> value .:? "comment"
      <*> value .:? "addLabels" .!= []
      <*> value .:? "removeLabels" .!= []

decodeReviewWireMessage :: LazyByteString.ByteString -> Either Text ReviewWireMessage
decodeReviewWireMessage bytes = case eitherDecode bytes of
  Left message -> Left (Text.pack message)
  Right value -> parseWireValue value

decodeReviewQuestion :: LazyByteString.ByteString -> Either Text ReviewQuestion
decodeReviewQuestion bytes = case eitherDecode bytes of
  Left message -> Left (Text.pack message)
  Right question
    | question.reviewQuestionKind == QuestionChoice && length question.reviewQuestionChoices < 2 ->
        Left "Choice questions must provide at least two options"
    | otherwise -> Right question

decodeReviewResult :: Text -> Either Text ReviewResult
decodeReviewResult value = case eitherDecode (LazyByteString.fromStrict (TextEncoding.encodeUtf8 value)) of
  Left message -> Left (Text.pack message)
  Right result -> Right result

decodeCanonicalIssueReviewResult :: Text -> Either Text CanonicalIssueReviewResult
decodeCanonicalIssueReviewResult value = case eitherDecode (LazyByteString.fromStrict (TextEncoding.encodeUtf8 value)) of
  Left message -> Left ("Canonical issue reviewer returned invalid JSON: " <> Text.pack message)
  Right result -> Right result

renderReviewResult :: ReviewResult -> Text
renderReviewResult result =
  Text.unlines
    ( [ reviewResultHeading result.reviewResultStage,
        "  Outcome: " <> reviewResultOutcome result,
        "  Reviewer route: " <> result.reviewResultReviewerRoute,
        "  Models: " <> renderModels,
        "  Comment: " <> fromMaybe "not posted" result.reviewResultCommentUrl
      ]
        <> renderBlockingReasons result.reviewResultBlockingReasons
    )
  where
    renderModels = case result.reviewResultModels of
      [] -> "not reported"
      models -> Text.intercalate ", " models
    renderBlockingReasons [] = ["  Blocking reasons: none"]
    renderBlockingReasons reasons = "  Blocking reasons:" : map ("    • " <>) reasons

reviewResultHeading :: ReviewStage -> Text
reviewResultHeading InitialReview = "Review result"
reviewResultHeading IssueRevision = "Specification revision"
reviewResultHeading IssueRereview = "Rereview result"

reviewResultOutcome :: ReviewResult -> Text
reviewResultOutcome result = case result.reviewResultStage of
  IssueRevision
    | null result.reviewResultBlockingReasons -> "AMENDMENT POSTED"
    | otherwise -> "REVISION BLOCKED"
  _
    | result.reviewResultApproved -> "APPROVED"
    | otherwise -> "CHANGES REQUESTED"

reviewStageForLabels :: WorkflowConfig -> [Text] -> ReviewStage
reviewStageForLabels config labels
  | hasLabel "reviewed:revised" = IssueRereview
  | hasLabel config.changesRequestedLabel = IssueRevision
  | otherwise = InitialReview
  where
    foldedLabels = map Text.toCaseFold labels
    hasLabel name = Text.toCaseFold name `elem` foldedLabels

parseWireValue :: Value -> Either Text ReviewWireMessage
parseWireValue (Object value) = case (KeyMap.lookup "id" value, KeyMap.lookup "method" value) of
  (Just requestId, Just (String method)) ->
    Right (WireRequest requestId method (fromMaybe (Object mempty) (KeyMap.lookup "params" value)))
  (Nothing, Just (String method)) ->
    Right (WireNotification method (fromMaybe (Object mempty) (KeyMap.lookup "params" value)))
  (Just requestId, Nothing) -> case (KeyMap.lookup "result" value, KeyMap.lookup "error" value) of
    (Just result, _) -> Right (WireResponse requestId (Right result))
    (_, Just err) -> Right (WireResponse requestId (Left err))
    _ -> Left "app-server response has neither result nor error"
  _ -> Left "app-server message has neither method nor id"
parseWireValue _ = Left "app-server message must be a JSON object"

parseQuestionValue :: Value -> Either Text ReviewQuestion
parseQuestionValue value = case fromJSON value of
  Error message -> Left ("Invalid kanban_prompt_user arguments: " <> Text.pack message)
  Success question
    | question.reviewQuestionKind == QuestionChoice && length question.reviewQuestionChoices < 2 ->
        Left "Choice questions must provide at least two options"
    | otherwise -> Right question

parseClaudeToolRequest :: Value -> Either Text ClaudeToolRequest
parseClaudeToolRequest value = case fromJSON value of
  Error message -> Left ("Invalid kanban_run_claude arguments: " <> Text.pack message)
  Success request
    | Text.null (Text.strip request.claudeToolPrompt) -> Left "kanban_run_claude requires a non-empty prompt"
    | Text.length request.claudeToolPrompt > claudePromptLimit -> Left "kanban_run_claude prompt exceeds the 100,000-character limit"
    | otherwise -> Right request

decodeClaudeToolPrompt :: Value -> Either Text Text
decodeClaudeToolPrompt value = (.claudeToolPrompt) <$> parseClaudeToolRequest value

parseGitHubIssueToolRequest :: WorkflowConfig -> Value -> Either Text GitHubIssueToolRequest
parseGitHubIssueToolRequest config value = case fromJSON value of
  Error message -> Left ("Invalid kanban_github_issue arguments: " <> Text.pack message)
  Success request
    | request.githubToolIssue <= 0 -> Left "kanban_github_issue requires a positive issue number"
    | any (`notElem` reviewWorkflowLabels config) allLabels ->
        Left
          ( "kanban_github_issue may only change "
              <> config.approvalLabel
              <> ", "
              <> config.changesRequestedLabel
              <> ", and reviewed:revised"
          )
    | any (`elem` request.githubToolRemoveLabels) request.githubToolAddLabels -> Left "kanban_github_issue cannot add and remove the same label"
    | maybe False ((> githubCommentLimit) . Text.length) request.githubToolComment -> Left "kanban_github_issue comment exceeds the 100,000-character limit"
    | request.githubToolOperation == GitHubIssueRead && hasMutation -> Left "kanban_github_issue read requests cannot contain mutations"
    | request.githubToolOperation == GitHubIssueUpdate && not hasMutation -> Left "kanban_github_issue update requests must post a comment or change a label"
    | otherwise -> Right request
    where
      allLabels = request.githubToolAddLabels <> request.githubToolRemoveLabels
      hasMutation = maybe False (not . Text.null . Text.strip) request.githubToolComment || not (null allLabels)

decodeGitHubIssueToolRequest :: WorkflowConfig -> Value -> Either Text GitHubIssueToolRequest
decodeGitHubIssueToolRequest = parseGitHubIssueToolRequest

reviewWorkflowLabels :: WorkflowConfig -> [Text]
reviewWorkflowLabels config = [config.approvalLabel, config.changesRequestedLabel, "reviewed:revised"]

claudePromptLimit :: Int
claudePromptLimit = 100000

githubCommentLimit :: Int
githubCommentLimit = 100000
