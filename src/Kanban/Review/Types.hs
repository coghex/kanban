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
    reviewTurnResumable,
    reviewWorkflowLabels,
  )
where

import Data.Aeson
  ( FromJSON (..),
    Result (..),
    ToJSON (..),
    Value (..),
    eitherDecode,
    fromJSON,
    object,
    withObject,
    withText,
    (.!=),
    (.:),
    (.:?),
    (.=),
  )
import Data.Aeson.Types (Parser)
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import GHC.Generics (Generic)
import Kanban.Domain (WorkflowConfig (..))
import Kanban.Models (ProviderName, parseProviderKey, providerKey)
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

data ReviewOutputKind
  = AgentOutput
  | ReasoningOutput
  | CommandOutput
  | -- | A line the provider wrote to its stderr, naming the provider that
    -- wrote it.
    --
    -- The only output kind that identifies a program rather than a part of a
    -- conversation, and so the only one that carries who. Its rendering is a
    -- bracketed tag beside text the operator is meant to read as coming from
    -- somewhere; a tag compiled in here would name the wrong somewhere as
    -- soon as a second backend existed.
    DiagnosticOutput ProviderName
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
  | -- | An interrupt-and-send that could not be completed, carrying the
    -- thread, what went wrong, and the guidance that was waiting on it — so a
    -- session can put a message it has already shown as sent back where the
    -- user can resend it deliberately.
    --
    -- The Claude path's counterpart to 'ReviewSteerUndelivered' and
    -- deliberately not that event (D-16). There is no steer to reject on this
    -- channel; what can fail instead is the interrupt a typed message has to
    -- land before it may be sent, and the two are different enough that one
    -- event describing both would have to lie about one of them. It carries
    -- no turn id for the same reason: the turn this names is the one the
    -- interrupt failed to end, which the session has already been told about.
    --
    -- 'Nothing' is an explicit cancellation, which had no message riding on
    -- it — the failure is still reported, because a cancellation that only
    -- reached the provider's stdin has cancelled nothing.
    ReviewInterruptFailed ReviewThreadId Text (Maybe Text)
  | -- | Something the client could not make sense of, naming the provider
    -- whose backend produced it.
    --
    -- The provider travels with the event because the code that raises one
    -- has none of its own: the reader loops, the response dispatch, and the
    -- tool runners are shared by every backend, and a consumer that rendered
    -- them all under a compiled-in brand would name the wrong program as
    -- soon as a second backend existed.
    ReviewProtocolWarning ProviderName Text
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

-- ---------------------------------------------------------------------------
-- The durable encoding
-- ---------------------------------------------------------------------------

-- A review thread outlives the dashboard that opened it (SAG-10): its host
-- journals every 'ReviewEvent' it produces, and a later dashboard replays that
-- journal through the very same handler a live event reaches. These instances
-- are that journal's schema.
--
-- The four payloads that already decode from the provider's wire get a
-- 'ToJSON' that emits exactly the shape their existing 'FromJSON' reads,
-- rather than a second parallel encoding. One decoder then serves both
-- directions, so a durable record cannot drift from the wire shape it was
-- built out of — the round trip is asserted, and the alternative (a private
-- durable spelling beside the wire one) is two schemas that have to be kept
-- equal by hand.

instance ToJSON ReviewChoice where
  toJSON choice =
    object
      [ "id" .= choice.reviewChoiceId,
        "label" .= choice.reviewChoiceLabel,
        "description" .= choice.reviewChoiceDescription
      ]

instance ToJSON ReviewQuestion where
  toJSON question =
    object
      [ "id" .= question.reviewQuestionId,
        "header" .= question.reviewQuestionHeader,
        "question" .= question.reviewQuestionText,
        "kind" .= questionKindText question.reviewQuestionKind,
        "options" .= question.reviewQuestionChoices,
        "allowOther" .= question.reviewQuestionAllowOther,
        "multiple" .= question.reviewQuestionMultiple
      ]

questionKindText :: ReviewQuestionKind -> Text
questionKindText QuestionChoice = "choice"
questionKindText QuestionText = "text"

instance ToJSON ReviewResult where
  toJSON result =
    object
      [ "issue" .= result.reviewResultIssue,
        "stage" .= reviewStageText result.reviewResultStage,
        "approved" .= result.reviewResultApproved,
        "reviewerRoute" .= result.reviewResultReviewerRoute,
        "models" .= result.reviewResultModels,
        "commentUrl" .= result.reviewResultCommentUrl,
        "blockingReasons" .= result.reviewResultBlockingReasons
      ]

instance ToJSON CanonicalIssueReviewResult where
  toJSON result =
    object
      [ "approved" .= result.canonicalReviewApproved,
        "issue" .= result.canonicalReviewIssue,
        "origin" .= result.canonicalReviewOrigin,
        "required_reviewers" .= result.canonicalReviewRequiredReviewers,
        "required_models" .= result.canonicalReviewRequiredModels,
        "reasons" .= result.canonicalReviewReasons
      ]

-- | The wire spelling 'FromJSON' 'ReviewResult' already accepts, kept here as
-- the one place the three stage names are written down for a durable record.
reviewStageText :: ReviewStage -> Text
reviewStageText InitialReview = "review"
reviewStageText IssueRevision = "revision"
reviewStageText IssueRereview = "rereview"

parseReviewStageText :: Text -> Maybe ReviewStage
parseReviewStageText "review" = Just InitialReview
parseReviewStageText "revision" = Just IssueRevision
parseReviewStageText "rereview" = Just IssueRereview
parseReviewStageText _ = Nothing

instance ToJSON ReviewStage where
  toJSON = toJSON . reviewStageText

instance FromJSON ReviewStage where
  parseJSON = withText "ReviewStage" $ \value ->
    maybe (fail "stage must be review, revision, or rereview") pure (parseReviewStageText value)

-- | The wire id travels verbatim, as the 'Value' it arrived as. A request the
-- provider named with a string and one it named with a number are different
-- requests, and an answer written under a re-typed id reaches neither.
instance ToJSON ReviewRequestId where
  toJSON requestId =
    object
      [ "connection" .= requestId.reviewRequestConnection,
        "wireId" .= requestId.reviewRequestWireId
      ]

instance FromJSON ReviewRequestId where
  parseJSON = withObject "ReviewRequestId" $ \value ->
    ReviewRequestId <$> value .: "connection" <*> value .: "wireId"

instance ToJSON ReviewAnswer where
  toJSON answer =
    object
      [ "selections" .= answer.reviewAnswerSelections,
        "other" .= answer.reviewAnswerOther
      ]

instance FromJSON ReviewAnswer where
  parseJSON = withObject "ReviewAnswer" $ \value ->
    ReviewAnswer <$> value .:? "selections" .!= [] <*> value .:? "other"

instance ToJSON ReviewApproval where
  toJSON approval =
    object
      [ "command" .= approval.reviewApprovalCommand,
        "reason" .= approval.reviewApprovalReason,
        "fileChange" .= approval.reviewApprovalFileChange
      ]

instance FromJSON ReviewApproval where
  parseJSON = withObject "ReviewApproval" $ \value ->
    ReviewApproval <$> value .:? "command" <*> value .:? "reason" <*> value .:? "fileChange" .!= False

instance ToJSON ReviewOutputKind where
  toJSON AgentOutput = object ["kind" .= ("agent" :: Text)]
  toJSON ReasoningOutput = object ["kind" .= ("reasoning" :: Text)]
  toJSON CommandOutput = object ["kind" .= ("command" :: Text)]
  toJSON (DiagnosticOutput provider) =
    object ["kind" .= ("diagnostic" :: Text), "provider" .= providerKey provider]

instance FromJSON ReviewOutputKind where
  parseJSON = withObject "ReviewOutputKind" $ \value -> do
    kind <- value .: "kind"
    case kind :: Text of
      "agent" -> pure AgentOutput
      "reasoning" -> pure ReasoningOutput
      "command" -> pure CommandOutput
      "diagnostic" -> DiagnosticOutput <$> (value .: "provider" >>= parseProvider)
      other -> fail ("unknown review output kind " <> Text.unpack other)
    where
      parseProvider key =
        maybe (fail ("unknown provider " <> Text.unpack key)) pure (parseProviderKey key)

instance ToJSON ReviewTurnOutcome where
  toJSON TurnSucceeded = toJSON ("succeeded" :: Text)
  toJSON TurnFailed = toJSON ("failed" :: Text)
  toJSON TurnInterrupted = toJSON ("interrupted" :: Text)

instance FromJSON ReviewTurnOutcome where
  parseJSON = withText "ReviewTurnOutcome" $ \value -> case value of
    "succeeded" -> pure TurnSucceeded
    "failed" -> pure TurnFailed
    "interrupted" -> pure TurnInterrupted
    other -> fail ("unknown review turn outcome " <> Text.unpack other)

-- | A tool result, whose failure half is a message and whose success half may
-- carry nothing at all. Encoded as an object rather than a bare string so the
-- two halves are told apart by shape rather than by content: a tool that
-- succeeded with the text @"error"@ is not a tool that failed.
encodeToolResult :: ToJSON success => Either Text success -> Value
encodeToolResult (Left message) = object ["error" .= message]
encodeToolResult (Right value) = object ["ok" .= value]

parseToolResult :: FromJSON success => Value -> Parser (Either Text success)
parseToolResult = withObject "tool result" $ \value -> do
  failure <- value .:? "error"
  case failure of
    Just message -> pure (Left message)
    Nothing -> Right <$> value .: "ok"

instance ToJSON ReviewEvent where
  toJSON reviewEvent = case reviewEvent of
    ReviewThreadCreated issueNumber threadId ->
      tagged "thread_created" ["issue" .= issueNumber, "thread" .= threadId]
    ReviewTurnStarted threadId turnId ->
      tagged "turn_started" ["thread" .= threadId, "turn" .= turnId]
    ReviewOutput threadId outputKind text ->
      tagged "output" ["thread" .= threadId, "outputKind" .= outputKind, "text" .= text]
    ReviewQuestionRequested threadId requestId question ->
      tagged "question_requested" ["thread" .= threadId, "request" .= requestId, "question" .= question]
    ReviewApprovalRequested threadId requestId approval ->
      tagged "approval_requested" ["thread" .= threadId, "request" .= requestId, "approval" .= approval]
    ReviewClaudeStarted threadId display ->
      tagged "claude_started" ["thread" .= threadId, "display" .= display]
    ReviewClaudeFinished threadId result ->
      tagged "claude_finished" ["thread" .= threadId, "result" .= encodeToolResult result]
    ReviewGitHubStarted threadId summary ->
      tagged "github_started" ["thread" .= threadId, "summary" .= summary]
    ReviewGitHubFinished threadId result ->
      tagged "github_finished" ["thread" .= threadId, "result" .= encodeToolResult result]
    ReviewTurnCompleted threadId outcome message result ->
      tagged
        "turn_completed"
        [ "thread" .= threadId,
          "outcome" .= outcome,
          "message" .= message,
          "result" .= fmap encodeCompletedResult result
        ]
    ReviewStartFailed issueNumber message ->
      tagged "start_failed" ["issue" .= issueNumber, "message" .= message]
    ReviewClientStopped message -> tagged "client_stopped" ["message" .= message]
    ReviewConnectionStopped connectionId message ->
      tagged "connection_stopped" ["connection" .= connectionId, "message" .= message]
    ReviewSteerUndelivered threadId turnId message ->
      tagged "steer_undelivered" ["thread" .= threadId, "turn" .= turnId, "message" .= message]
    ReviewInterruptFailed threadId cause message ->
      tagged "interrupt_failed" ["thread" .= threadId, "cause" .= cause, "message" .= message]
    ReviewProtocolWarning provider message ->
      tagged "protocol_warning" ["provider" .= providerKey provider, "message" .= message]
    where
      tagged name fields = object (("event" .= (name :: Text)) : fields)
      encodeCompletedResult (raw, result) = object ["raw" .= raw, "result" .= result]

instance FromJSON ReviewEvent where
  parseJSON = withObject "ReviewEvent" $ \value -> do
    name <- value .: "event"
    case name :: Text of
      "thread_created" -> ReviewThreadCreated <$> value .: "issue" <*> value .: "thread"
      "turn_started" -> ReviewTurnStarted <$> value .: "thread" <*> value .: "turn"
      "output" -> ReviewOutput <$> value .: "thread" <*> value .: "outputKind" <*> value .: "text"
      "question_requested" ->
        ReviewQuestionRequested <$> value .: "thread" <*> value .: "request" <*> value .: "question"
      "approval_requested" ->
        ReviewApprovalRequested <$> value .: "thread" <*> value .: "request" <*> value .: "approval"
      "claude_started" -> ReviewClaudeStarted <$> value .: "thread" <*> value .: "display"
      "claude_finished" ->
        ReviewClaudeFinished <$> value .: "thread" <*> (value .: "result" >>= parseToolResult)
      "github_started" -> ReviewGitHubStarted <$> value .: "thread" <*> value .: "summary"
      "github_finished" ->
        ReviewGitHubFinished <$> value .: "thread" <*> (value .: "result" >>= parseToolResult)
      "turn_completed" ->
        ReviewTurnCompleted
          <$> value .: "thread"
          <*> value .: "outcome"
          <*> value .:? "message"
          <*> (value .:? "result" >>= traverse parseCompletedResult)
      "start_failed" -> ReviewStartFailed <$> value .: "issue" <*> value .: "message"
      "client_stopped" -> ReviewClientStopped <$> value .: "message"
      "connection_stopped" -> ReviewConnectionStopped <$> value .: "connection" <*> value .: "message"
      "steer_undelivered" ->
        ReviewSteerUndelivered <$> value .: "thread" <*> value .: "turn" <*> value .: "message"
      "interrupt_failed" ->
        ReviewInterruptFailed <$> value .: "thread" <*> value .: "cause" <*> value .:? "message"
      "protocol_warning" ->
        ReviewProtocolWarning <$> (value .: "provider" >>= parseProvider) <*> value .: "message"
      other -> fail ("unknown review event " <> Text.unpack other)
    where
      parseCompletedResult = withObject "completed result" $ \value ->
        (,) <$> value .: "raw" <*> value .: "result"
      parseProvider key =
        maybe (fail ("unknown provider " <> Text.unpack key)) pure (parseProviderKey key)

-- | Whether a completed turn leaves its review still able to take input.
--
-- The one spelling of that rule (SAG-10). Two very different consumers depend
-- on it agreeing with itself: the overlay decides from it whether to keep
-- offering an input line, and the repository review host decides from it
-- whether the durable child action behind that line is still there to receive
-- what is typed. An overlay that offered a line to a settled child, or a
-- child kept alive for a line the overlay had already withdrawn, is what two
-- copies of this rule produce the first time one of them is edited.
--
-- Only an interrupted revision is resumable. A canonical stage does not
-- resume at all — it is a subprocess that ran the gate, and a fresh stage is
-- a fresh run — and a revision whose turn actually completed has published
-- its verdict.
reviewTurnResumable :: ReviewStage -> ReviewTurnOutcome -> Bool
reviewTurnResumable IssueRevision TurnInterrupted = True
reviewTurnResumable _ _ = False
