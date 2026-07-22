{-# LANGUAGE DeriveGeneric #-}

module Kanban.Review
  ( CanonicalIssueReviewResult (..),
    GitHubIssueOperation (..),
    GitHubIssueToolRequest (..),
    ReviewAnswer (..),
    ReviewApproval (..),
    ReviewChoice (..),
    ReviewClient,
    ReviewEvent (..),
    ReviewOutputKind (..),
    ReviewQuestion (..),
    ReviewQuestionKind (..),
    ReviewRequestId (..),
    ReviewResult (..),
    ReviewStage (..),
    ReviewTurnOutcome (..),
    ReviewWireMessage (..),
    answerReviewQuestion,
    approveReviewAction,
    beginIssueReview,
    canonicalIssueReviewArguments,
    canonicalIssueReviewerPath,
    decodeCanonicalIssueReviewResult,
    decodeClaudeToolPrompt,
    decodeGitHubIssueToolRequest,
    decodeReviewQuestion,
    decodeReviewResult,
    decodeReviewWireMessage,
    githubIssueCommentArguments,
    githubIssueEditArguments,
    githubIssueViewArguments,
    githubLabelCreateArguments,
    interruptReview,
    killReviewTools,
    renderCanonicalIssueReviewResult,
    resolveCanonicalIssueReviewer,
    reviewStageForLabels,
    runCanonicalIssueReview,
    sendReviewMessage,
    startReviewClient,
    stopReviewClient,
    renderReviewResult,
  )
where

import Control.Concurrent (MVar, forkIO, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, takeMVar, withMVar)
import Control.Exception (Exception, IOException, displayException, try)
import Control.Monad (forever, void)
import Data.Aeson
  ( FromJSON (..),
    Result (..),
    Value (..),
    eitherDecode,
    encode,
    fromJSON,
    object,
    withObject,
    (.:),
    (.:?),
    (.!=),
    (.=),
  )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import GHC.Generics (Generic)
import Kanban.Domain (Repository (..), WorkflowConfig (..))
import Kanban.Process (ManagedProcess, killManagedProcess, managedProcess)
import Kanban.Transcript (SessionLog, closeSessionLog, logMessage, logRawLine, openSessionLog)
import System.Directory (doesFileExist, findExecutable, getHomeDirectory)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (BufferMode (..), Handle, hClose, hFlush, hIsEOF, hSetBuffering)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (..),
    createProcess,
    getPid,
    getProcessExitCode,
    proc,
    terminateProcess,
    waitForProcess,
  )
import System.Posix.Signals (sigKILL, sigTERM, signalProcessGroup)
import System.Timeout (timeout)

newtype ReviewRequestId = ReviewRequestId Value
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
  = ReviewThreadCreated Int Text
  | ReviewTurnStarted Text Text
  | ReviewOutput Text ReviewOutputKind Text
  | ReviewQuestionRequested Text ReviewRequestId ReviewQuestion
  | ReviewApprovalRequested Text ReviewRequestId ReviewApproval
  | ReviewClaudeStarted Text
  | ReviewClaudeFinished Text (Either Text ())
  | ReviewGitHubStarted Text Text
  | ReviewGitHubFinished Text (Either Text Text)
  | ReviewTurnCompleted Text ReviewTurnOutcome (Maybe Text) (Maybe (Text, ReviewResult))
  | ReviewStartFailed Int Text
  | ReviewClientStopped Text
  | ReviewProtocolWarning Text
  deriving stock (Eq, Show)

data ReviewWireMessage
  = WireResponse Value (Either Value Value)
  | WireNotification Text Value
  | WireRequest Value Text Value
  deriving stock (Eq, Show)

data PendingRequest
  = PendingThreadStart Int
  | PendingTurnStart Text
  | PendingOther
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

data ReviewClient = ReviewClient
  { reviewInput :: Handle,
    reviewProcess :: ProcessHandle,
    reviewWriteLock :: MVar (),
    reviewNextRequestId :: IORef Int,
    reviewPendingRequests :: MVar (Map Int PendingRequest),
    reviewThreadIssues :: MVar (Map Text Int),
    reviewToolProcesses :: MVar (Map Text ManagedProcess),
    reviewEventSink :: ReviewEvent -> IO (),
    reviewRepositoryRoot :: FilePath,
    -- | The dashboard's resolved OWNER/NAME (which may come from an
    -- explicit --repo override, e.g. reviewing upstream from a fork
    -- checkout). Passed explicitly to every GitHub tool call below so it
    -- never re-derives identity from the checkout's own remote.
    reviewRepositorySlug :: Text,
    reviewWorkflowConfig :: WorkflowConfig,
    reviewSessionLog :: Maybe SessionLog,
    reviewOutputDone :: MVar (),
    reviewErrorDone :: MVar ()
  }

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

renderCanonicalIssueReviewResult :: ReviewStage -> CanonicalIssueReviewResult -> Text
renderCanonicalIssueReviewResult stage result =
  Text.unlines
    ( [ reviewResultHeading stage,
        "  Outcome: " <> if result.canonicalReviewApproved then "APPROVED" else "CHANGES REQUESTED",
        "  Origin: " <> result.canonicalReviewOrigin,
        "  Reviewer route: " <> fromMaybe "not reported" result.canonicalReviewRequiredReviewers,
        "  Models: " <> fromMaybe "not reported" result.canonicalReviewRequiredModels
      ]
        <> renderReasons result.canonicalReviewReasons
    )
  where
    renderReasons [] = ["  Blocking reasons: none"]
    renderReasons reasons = "  Blocking reasons:" : map ("    • " <>) reasons

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

-- | The Kanban-managed install location for the vendored canonical
-- issue-review backend (@tools\/approve_issues.py@), independent of which
-- repository is under review — the same stable directory
-- @tools\/install_issue_review.py@ populates in the same manner as the PR
-- drainer installer. Overridable with @KANBAN_ISSUE_REVIEW_INSTALL_DIR@ for
-- an alternate install or a test fixture.
canonicalIssueReviewerPath :: IO FilePath
canonicalIssueReviewerPath = do
  override <- lookupEnv "KANBAN_ISSUE_REVIEW_INSTALL_DIR"
  case override of
    Just installDir | not (null installDir) -> pure (installDir <> "/approve_issues.py")
    _ -> do
      home <- getHomeDirectory
      pure (home <> "/Library/Application Support/kanban/issue-review/approve_issues.py")

-- | Resolve the bundled canonical issue reviewer, failing with a
-- remediation-oriented diagnostic when it has not been installed yet.
resolveCanonicalIssueReviewer :: IO (Either Text FilePath)
resolveCanonicalIssueReviewer = do
  scriptPath <- canonicalIssueReviewerPath
  scriptExists <- doesFileExist scriptPath
  pure $
    if scriptExists
      then Right scriptPath
      else
        Left
          ( "Canonical issue reviewer was not found at "
              <> Text.pack scriptPath
              <> ". Run `python3 tools/install_issue_review.py` from the Kanban checkout to install it."
          )

runCanonicalIssueReview :: Maybe FilePath -> Repository -> Int -> ReviewStage -> (ManagedProcess -> IO ()) -> IO (Either Text CanonicalIssueReviewResult)
runCanonicalIssueReview configPath repository issueNumber stage processStarted
  | stage == IssueRevision = pure (Left "Canonical issue review cannot perform specification revision")
  | otherwise = do
      resolved <- resolveCanonicalIssueReviewer
      case resolved of
        Left message -> pure (Left message)
        Right scriptPath -> do
          python <- findExecutable "python3"
          case python of
            Nothing -> pure (Left "python3 was not found on PATH")
            Just pythonPath -> do
              output <-
                runCanonicalCommand
                  repository
                  issueNumber
                  pythonPath
                  (canonicalIssueReviewArguments scriptPath repository issueNumber stage configPath)
                  processStarted
              pure (output >>= decodeCanonicalIssueReviewResult)

-- | Explicit --repo, so the canonical reviewer always gates and mutates the
-- same repository Kanban resolved (including any --repo override), rather
-- than independently re-deriving identity from the configured remote —
-- which could diverge in a fork checkout.
canonicalIssueReviewArguments :: FilePath -> Repository -> Int -> ReviewStage -> Maybe FilePath -> [String]
canonicalIssueReviewArguments scriptPath repository issueNumber stage configPath =
  [ scriptPath,
    "--path",
    repository.repositoryRoot,
    "--repo",
    Text.unpack (repository.repositoryOwner <> "/" <> repository.repositoryName),
    stageFlag,
    show issueNumber,
    "--legacy-policy",
    "dual",
    "--json"
  ]
    <> maybe [] (\path -> ["--config", path]) configPath
  where
    stageFlag = case stage of
      InitialReview -> "--review"
      IssueRereview -> "--rereview"
      IssueRevision -> "--review"

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

startReviewClient :: WorkflowConfig -> Repository -> (ReviewEvent -> IO ()) -> IO (Either Text ReviewClient)
startReviewClient workflowConfig repository eventSink = do
  logResult <- openSessionLog repository "issue-revision-appserver" 0 Nothing
  sessionLog <- case logResult of
    Left message -> eventSink (ReviewProtocolWarning message) >> pure Nothing
    Right value -> logMessage value "backend-started" "codex app-server" >> pure (Just value)
  started <- try (createProcess processSpec) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
  case started of
    Left exception -> closeReviewLog sessionLog >> pure (Left ("Could not start codex app-server: " <> exceptionText exception))
    Right (Just inputHandle, Just outputHandle, Just errorHandle, processHandle) -> do
      hSetBuffering inputHandle LineBuffering
      hSetBuffering outputHandle LineBuffering
      writeLock <- newMVar ()
      requestCounter <- newIORef 2
      pendingRequests <- newMVar Map.empty
      threadIssues <- newMVar Map.empty
      toolProcesses <- newMVar Map.empty
      outputDone <- newEmptyMVar
      errorDone <- newEmptyMVar
      let client =
            ReviewClient
              { reviewInput = inputHandle,
                reviewProcess = processHandle,
                reviewWriteLock = writeLock,
                reviewNextRequestId = requestCounter,
                reviewPendingRequests = pendingRequests,
                reviewThreadIssues = threadIssues,
                reviewToolProcesses = toolProcesses,
                reviewEventSink = eventSink,
                reviewRepositoryRoot = repositoryRoot,
                reviewRepositorySlug = repository.repositoryOwner <> "/" <> repository.repositoryName,
                reviewWorkflowConfig = workflowConfig,
                reviewSessionLog = sessionLog,
                reviewOutputDone = outputDone,
                reviewErrorDone = errorDone
              }
      initialized <- timeout initializationTimeoutMicros (initializeClient client outputHandle)
      case initialized of
        Nothing -> do
          stopReviewClient client
          closeReviewLog sessionLog
          pure (Left "Codex app-server initialization timed out")
        Just (Left message) -> do
          stopReviewClient client
          closeReviewLog sessionLog
          pure (Left message)
        Just (Right ()) -> do
          void (forkIO (readServerOutput client outputHandle >> putMVar outputDone ()))
          void (forkIO (readServerErrors client errorHandle >> putMVar errorDone ()))
          void (forkIO (watchServerProcess client))
          pure (Right client)
    Right _ -> closeReviewLog sessionLog >> pure (Left "Codex app-server did not provide all three standard streams")
  where
    repositoryRoot = repository.repositoryRoot
    processSpec =
      (proc "codex" ["app-server", "--listen", "stdio://"])
        { cwd = Just repositoryRoot,
          std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }

initializeClient :: ReviewClient -> Handle -> IO (Either Text ())
initializeClient client outputHandle = do
  sent <- sendValue client initializeRequest
  case sent of
    Left message -> pure (Left message)
    Right () -> awaitInitialize
  where
    awaitInitialize = do
      eof <- hIsEOF outputHandle
      if eof
        then pure (Left "Codex app-server exited during initialization")
        else do
          line <- LazyByteString.fromStrict <$> ByteString.hGetLine outputHandle
          mapM_ (\sessionLog -> logRawLine sessionLog "stdout" (LazyByteString.toStrict line)) client.reviewSessionLog
          case decodeReviewWireMessage line of
            Right (WireResponse requestId (Right _))
              | requestIdInt requestId == Just 1 -> do
                  sendValue client (object ["method" .= ("initialized" :: Text), "params" .= object []])
            Right (WireResponse requestId (Left err))
              | requestIdInt requestId == Just 1 -> pure (Left ("Codex app-server rejected initialization: " <> compactValue err))
            Right _ -> awaitInitialize
            Left message -> pure (Left ("Invalid Codex initialization response: " <> message))
    initializeRequest =
      object
        [ "method" .= ("initialize" :: Text),
          "id" .= (1 :: Int),
          "params"
            .= object
              [ "clientInfo"
                  .= object
                    [ "name" .= ("kanban" :: Text),
                      "title" .= ("Kanban" :: Text),
                      "version" .= ("0.1.0" :: Text)
                    ],
                "capabilities" .= object ["experimentalApi" .= True]
              ]
        ]

beginIssueReview :: ReviewClient -> Int -> IO (Either Text ())
beginIssueReview client issueNumber =
  sendRequest client (PendingThreadStart issueNumber) "thread/start" threadParams
  where
    threadParams =
      object
        [ "cwd" .= client.reviewRepositoryRoot,
          "model" .= ("gpt-5.4" :: Text),
          "approvalPolicy" .= ("on-request" :: Text),
          "sandbox" .= ("read-only" :: Text),
          "ephemeral" .= False,
          "developerInstructions" .= reviewDeveloperInstructions client.reviewWorkflowConfig,
          "dynamicTools" .= [questionTool, claudeTool, githubTool client.reviewWorkflowConfig]
        ]

sendReviewMessage :: ReviewClient -> Text -> Maybe Text -> Text -> IO (Either Text ())
sendReviewMessage client threadId activeTurnId message = case activeTurnId of
  Just turnId -> sendRequest client PendingOther "turn/steer" (steerParams turnId)
  Nothing -> sendTurnStart client threadId message
  where
    steerParams turnId =
      object
        [ "threadId" .= threadId,
          "expectedTurnId" .= turnId,
          "input" .= [textInput message]
        ]

answerReviewQuestion :: ReviewClient -> ReviewRequestId -> ReviewAnswer -> IO (Either Text ())
answerReviewQuestion client (ReviewRequestId requestId) answer =
  sendValue client
    . object
    $ [ "id" .= requestId,
        "result"
          .= object
            [ "success" .= True,
              "contentItems"
                .= [ object
                       [ "type" .= ("inputText" :: Text),
                         "text" .= TextEncoding.decodeUtf8 (LazyByteString.toStrict (encode answerValue))
                       ]
                   ]
            ]
      ]
  where
    answerValue =
      object
        [ "selected" .= answer.reviewAnswerSelections,
          "other" .= answer.reviewAnswerOther
        ]

approveReviewAction :: ReviewClient -> ReviewRequestId -> Bool -> Bool -> IO (Either Text ())
approveReviewAction client (ReviewRequestId requestId) accepted forSession =
  sendValue client
    . object
    $ [ "id" .= requestId,
        "result" .= object ["decision" .= decision]
      ]
  where
    decision :: Text
    decision
      | not accepted = "decline"
      | forSession = "acceptForSession"
      | otherwise = "accept"

interruptReview :: ReviewClient -> Text -> Text -> IO (Either Text ())
interruptReview client threadId turnId =
  sendRequest
    client
    PendingOther
    "turn/interrupt"
    (object ["threadId" .= threadId, "turnId" .= turnId])

killReviewTools :: ReviewClient -> Text -> IO ()
killReviewTools client threadId = do
  owned <- modifyMVar client.reviewToolProcesses $ \processes -> pure (Map.delete threadId processes, Map.lookup threadId processes)
  maybe (pure ()) killManagedProcess owned

stopReviewClient :: ReviewClient -> IO ()
stopReviewClient client = do
  toolProcesses <- modifyMVar client.reviewToolProcesses (\processes -> pure (Map.empty, Map.elems processes))
  mapM_ killManagedProcess toolProcesses
  exitCode <- getProcessExitCode client.reviewProcess
  case exitCode of
    Just _ -> pure ()
    Nothing -> do
      processId <- getPid client.reviewProcess
      case processId of
        Just pid -> ignoreIOException (signalProcessGroup sigTERM pid)
        Nothing -> terminateProcess client.reviewProcess
      stopped <- timeout shutdownTimeoutMicros (waitForProcess client.reviewProcess)
      case (stopped, processId) of
        (Nothing, Just pid) -> ignoreIOException (signalProcessGroup sigKILL pid)
        (Nothing, Nothing) -> terminateProcess client.reviewProcess
        _ -> pure ()
  ignoreIOException (hClose client.reviewInput)

closeReviewLog :: Maybe SessionLog -> IO ()
closeReviewLog = mapM_ closeSessionLog

sendRequest :: ReviewClient -> PendingRequest -> Text -> Value -> IO (Either Text ())
sendRequest client pending method params = do
  requestId <- nextRequestId client
  modifyMVar_ client.reviewPendingRequests (pure . Map.insert requestId pending)
  result <- sendValue client (object ["method" .= method, "id" .= requestId, "params" .= params])
  case result of
    Right () -> pure (Right ())
    Left message -> do
      modifyMVar_ client.reviewPendingRequests (pure . Map.delete requestId)
      pure (Left message)

sendTurnStart :: ReviewClient -> Text -> Text -> IO (Either Text ())
sendTurnStart client threadId prompt =
  sendRequest client (PendingTurnStart threadId) "turn/start" params
  where
    params =
      object
        [ "threadId" .= threadId,
          "effort" .= ("high" :: Text),
          "input" .= [textInput prompt],
          "outputSchema" .= finalOutputSchema
        ]
textInput :: Text -> Value
textInput value = object ["type" .= ("text" :: Text), "text" .= value]

nextRequestId :: ReviewClient -> IO Int
nextRequestId client = atomicModifyIORef' client.reviewNextRequestId (\current -> (current + 1, current))

sendValue :: ReviewClient -> Value -> IO (Either Text ())
sendValue client value = do
  mapM_ (\sessionLog -> logRawLine sessionLog "stdin" (LazyByteString.toStrict (encode value))) client.reviewSessionLog
  result <-
    try
      ( withMVar client.reviewWriteLock $ \() -> do
          LazyByteString.hPutStr client.reviewInput (encode value)
          LazyByteString.hPutStr client.reviewInput "\n"
          hFlush client.reviewInput
      ) :: IO (Either IOException ())
  pure $ case result of
    Left exception -> Left ("Codex app-server write failed: " <> exceptionText exception)
    Right () -> Right ()

readServerOutput :: ReviewClient -> Handle -> IO ()
readServerOutput client outputHandle = do
  result <- try (forever readOne) :: IO (Either IOException ())
  case result of
    Left exception -> client.reviewEventSink (ReviewClientStopped ("Codex app-server output closed: " <> exceptionText exception))
    Right () -> pure ()
  where
    readOne = do
      strictLine <- ByteString.hGetLine outputHandle
      mapM_ (\sessionLog -> logRawLine sessionLog "stdout" strictLine) client.reviewSessionLog
      let line = LazyByteString.fromStrict strictLine
      case decodeReviewWireMessage line of
        Left message -> client.reviewEventSink (ReviewProtocolWarning message)
        Right wireMessage -> handleWireMessage client wireMessage

readServerErrors :: ReviewClient -> Handle -> IO ()
readServerErrors client errorHandle = do
  result <- try (forever readOne) :: IO (Either IOException ())
  case result of
    Left _ -> pure ()
    Right () -> pure ()
  where
    readOne = do
      strictLine <- ByteString.hGetLine errorHandle
      mapM_ (\sessionLog -> logRawLine sessionLog "stderr" strictLine) client.reviewSessionLog
      let line = LazyByteString.fromStrict strictLine
      client.reviewEventSink (ReviewOutput "" DiagnosticOutput (decodeLine line))

watchServerProcess :: ReviewClient -> IO ()
watchServerProcess client = do
  exitCode <- waitForProcess client.reviewProcess
  takeMVar client.reviewOutputDone
  takeMVar client.reviewErrorDone
  mapM_ (\sessionLog -> logMessage sessionLog "backend-finished" (renderExitCode exitCode)) client.reviewSessionLog
  closeReviewLog client.reviewSessionLog
  client.reviewEventSink (ReviewClientStopped (renderExitCode exitCode))

handleWireMessage :: ReviewClient -> ReviewWireMessage -> IO ()
handleWireMessage client wireMessage = case wireMessage of
  WireResponse requestId result -> handleResponse client requestId result
  WireNotification method params -> handleNotification client method params
  WireRequest requestId method params -> handleServerRequest client requestId method params

handleResponse :: ReviewClient -> Value -> Either Value Value -> IO ()
handleResponse client requestId result = case requestIdInt requestId of
  Nothing -> client.reviewEventSink (ReviewProtocolWarning "Codex returned a non-numeric response id")
  Just integerId -> do
    pending <- modifyMVar client.reviewPendingRequests $ \requests ->
      pure (Map.delete integerId requests, Map.lookup integerId requests)
    case (pending, result) of
      (Just (PendingThreadStart issueNumber), Right value) -> case resultThreadId value of
        Nothing -> client.reviewEventSink (ReviewStartFailed issueNumber "Codex thread/start response did not contain a thread id")
        Just threadId -> do
          modifyMVar_ client.reviewThreadIssues (pure . Map.insert threadId issueNumber)
          client.reviewEventSink (ReviewThreadCreated issueNumber threadId)
          started <- sendTurnStart client threadId (reviewPrompt issueNumber)
          case started of
            Left message -> client.reviewEventSink (ReviewStartFailed issueNumber message)
            Right () -> pure ()
      (Just (PendingThreadStart issueNumber), Left err) ->
        client.reviewEventSink (ReviewStartFailed issueNumber ("Codex could not create the review thread: " <> compactValue err))
      (Just (PendingTurnStart threadId), Left err) ->
        client.reviewEventSink (ReviewTurnCompleted threadId TurnFailed (Just (compactValue err)) Nothing)
      (_, Left err) -> client.reviewEventSink (ReviewProtocolWarning ("Codex request failed: " <> compactValue err))
      _ -> pure ()

handleNotification :: ReviewClient -> Text -> Value -> IO ()
handleNotification client method params = case method of
  "turn/started" -> case (fieldText "threadId" params, nestedText ["turn", "id"] params) of
    (Just threadId, Just turnId) -> client.reviewEventSink (ReviewTurnStarted threadId turnId)
    _ -> client.reviewEventSink (ReviewProtocolWarning "turn/started omitted its thread or turn id")
  "item/agentMessage/delta" -> emitDelta AgentOutput
  "item/commandExecution/outputDelta" -> emitDelta CommandOutput
  "item/reasoning/summaryTextDelta" -> emitDelta ReasoningOutput
  "turn/completed" -> case fieldText "threadId" params of
    Nothing -> client.reviewEventSink (ReviewProtocolWarning "turn/completed omitted its thread id")
    Just threadId ->
      client.reviewEventSink
        (ReviewTurnCompleted threadId (turnOutcome params) (nestedText ["turn", "error", "message"] params) (turnResult params))
  _ -> pure ()
  where
    emitDelta outputKind = case (fieldText "threadId" params, fieldText "delta" params) of
      (Just threadId, Just delta) -> client.reviewEventSink (ReviewOutput threadId outputKind delta)
      _ -> pure ()

handleServerRequest :: ReviewClient -> Value -> Text -> Value -> IO ()
handleServerRequest client requestId method params = case method of
  "item/tool/call"
    | fieldText "tool" params == Just questionToolName -> case (fieldText "threadId" params, objectField "arguments" params) of
        (Just threadId, Just arguments) -> case parseQuestionValue arguments of
          Right question -> client.reviewEventSink (ReviewQuestionRequested threadId wrappedId question)
          Left message -> do
            void (sendDynamicToolFailure client wrappedId message)
            client.reviewEventSink (ReviewProtocolWarning message)
        _ -> void (sendDynamicToolFailure client wrappedId "Question tool call omitted its thread id or arguments")
    | fieldText "tool" params == Just claudeToolName -> case (fieldText "threadId" params, objectField "arguments" params) of
        (Just threadId, Just arguments) -> case parseClaudeToolRequest arguments of
          Left message -> do
            void (sendDynamicToolFailure client wrappedId message)
            client.reviewEventSink (ReviewProtocolWarning message)
          Right claudeRequest ->
            void
              . forkIO
              $ runClaudeToolCall client threadId wrappedId claudeRequest
        _ -> void (sendDynamicToolFailure client wrappedId "Claude tool call omitted its thread id or arguments")
    | fieldText "tool" params == Just githubToolName -> case (fieldText "threadId" params, objectField "arguments" params) of
        (Just threadId, Just arguments) -> case decodeGitHubIssueToolRequest client.reviewWorkflowConfig arguments of
          Left message -> do
            void (sendDynamicToolFailure client wrappedId message)
            client.reviewEventSink (ReviewProtocolWarning message)
          Right githubRequest -> do
            authorized <- githubRequestMatchesThread client threadId githubRequest
            if authorized
              then
                void
                  . forkIO
                  $ runGitHubToolCall client threadId wrappedId githubRequest
              else do
                let message = "kanban_github_issue may only access the issue owned by this review thread"
                void (sendDynamicToolFailure client wrappedId message)
                client.reviewEventSink (ReviewProtocolWarning message)
        _ -> void (sendDynamicToolFailure client wrappedId "GitHub issue tool call omitted its thread id or arguments")
    | otherwise -> void (sendDynamicToolFailure client wrappedId "Kanban does not implement that dynamic tool")
  "item/commandExecution/requestApproval" -> emitApproval False
  "item/fileChange/requestApproval" -> emitApproval True
  _ -> do
    void (sendErrorResponse client requestId (-32601) ("Unsupported app-server request: " <> method))
    client.reviewEventSink (ReviewProtocolWarning ("Unsupported app-server request: " <> method))
  where
    wrappedId = ReviewRequestId requestId
    emitApproval fileChange = case fieldText "threadId" params of
      Nothing -> void (sendErrorResponse client requestId (-32602) "Approval request omitted its thread id")
      Just threadId ->
        client.reviewEventSink
          ( ReviewApprovalRequested
              threadId
              wrappedId
              ReviewApproval
                { reviewApprovalCommand = fieldText "command" params,
                  reviewApprovalReason = fieldText "reason" params,
                  reviewApprovalFileChange = fileChange
                }
          )

sendDynamicToolFailure :: ReviewClient -> ReviewRequestId -> Text -> IO (Either Text ())
sendDynamicToolFailure client (ReviewRequestId requestId) message =
  sendValue client
    ( object
        [ "id" .= requestId,
          "result"
            .= object
              [ "success" .= False,
                "contentItems" .= [object ["type" .= ("inputText" :: Text), "text" .= message]]
              ]
        ]
    )

sendDynamicToolSuccess :: ReviewClient -> ReviewRequestId -> Text -> IO (Either Text ())
sendDynamicToolSuccess client (ReviewRequestId requestId) output =
  sendValue client
    ( object
        [ "id" .= requestId,
          "result"
            .= object
              [ "success" .= True,
                "contentItems" .= [object ["type" .= ("inputText" :: Text), "text" .= output]]
              ]
        ]
    )

runClaudeToolCall :: ReviewClient -> Text -> ReviewRequestId -> ClaudeToolRequest -> IO ()
runClaudeToolCall client threadId requestId request = do
  client.reviewEventSink (ReviewClaudeStarted threadId)
  result <- runAuthenticatedClaude client threadId request.claudeToolPrompt
  sent <- case result of
    Left message -> sendDynamicToolFailure client requestId message
    Right output -> sendDynamicToolSuccess client requestId output
  let completion = case (result, sent) of
        (Left message, _) -> Left message
        (_, Left message) -> Left message
        (Right _, Right ()) -> Right ()
  client.reviewEventSink (ReviewClaudeFinished threadId completion)

runGitHubToolCall :: ReviewClient -> Text -> ReviewRequestId -> GitHubIssueToolRequest -> IO ()
runGitHubToolCall client threadId requestId request = do
  client.reviewEventSink (ReviewGitHubStarted threadId (githubActionSummary request))
  result <- runGitHubIssueTool client.reviewRepositoryRoot client.reviewRepositorySlug request
  sent <- case result of
    Left message -> sendDynamicToolFailure client requestId message
    Right output -> sendDynamicToolSuccess client requestId output
  let completion = case (result, sent) of
        (Left message, _) -> Left message
        (_, Left message) -> Left message
        (Right output, Right ()) -> Right output
  client.reviewEventSink (ReviewGitHubFinished threadId completion)

githubActionSummary :: GitHubIssueToolRequest -> Text
githubActionSummary request = case request.githubToolOperation of
  GitHubIssueRead -> "Reading issue #" <> Text.pack (show request.githubToolIssue) <> " and its comments…"
  GitHubIssueUpdate ->
    "Updating issue #"
      <> Text.pack (show request.githubToolIssue)
      <> mutationSummary
  where
    mutationSummary
      | request.githubToolComment /= Nothing = " comment and review labels…"
      | otherwise = " review labels…"

runGitHubIssueTool :: FilePath -> Text -> GitHubIssueToolRequest -> IO (Either Text Text)
runGitHubIssueTool repositoryRoot repo request = do
  executable <- findExecutable "gh"
  case executable of
    Nothing -> pure (Left "GitHub CLI was not found on PATH")
    Just ghPath -> case request.githubToolOperation of
      GitHubIssueRead -> runGitHubCommand repositoryRoot ghPath (githubIssueViewArguments repo request.githubToolIssue) ""
      GitHubIssueUpdate -> runGitHubIssueUpdate repositoryRoot repo ghPath request

-- | Explicit --repo on every GitHub CLI invocation below, so the dashboard's
-- resolved repository identity (which may come from an explicit --repo
-- override, e.g. reviewing upstream from a fork checkout) is never silently
-- re-derived by `gh` from the checkout's own remote.
githubIssueViewArguments :: Text -> Int -> [String]
githubIssueViewArguments repo issueNumber =
  [ "issue",
    "view",
    show issueNumber,
    "--repo",
    Text.unpack repo,
    "--json",
    "number,title,body,url,state,labels,comments"
  ]

githubIssueCommentArguments :: Text -> Int -> [String]
githubIssueCommentArguments repo issueNumber =
  ["issue", "comment", show issueNumber, "--repo", Text.unpack repo, "--body-file", "-"]

githubLabelCreateArguments :: Text -> [String]
githubLabelCreateArguments repo =
  [ "label",
    "create",
    "reviewed:revised",
    "--repo",
    Text.unpack repo,
    "--color",
    "8250DF",
    "--description",
    "Specification amended and awaiting opposite-brand rereview",
    "--force"
  ]

githubIssueEditArguments :: Text -> GitHubIssueToolRequest -> [String]
githubIssueEditArguments repo request = baseArguments <> addArguments <> removeArguments
  where
    baseArguments = ["issue", "edit", show request.githubToolIssue, "--repo", Text.unpack repo]
    addArguments
      | null request.githubToolAddLabels = []
      | otherwise = ["--add-label", Text.unpack (Text.intercalate "," request.githubToolAddLabels)]
    removeArguments
      | null request.githubToolRemoveLabels = []
      | otherwise = ["--remove-label", Text.unpack (Text.intercalate "," request.githubToolRemoveLabels)]

runGitHubIssueUpdate :: FilePath -> Text -> FilePath -> GitHubIssueToolRequest -> IO (Either Text Text)
runGitHubIssueUpdate repositoryRoot repo ghPath request = do
  commentResult <- case request.githubToolComment of
    Nothing -> pure (Right Nothing)
    Just comment ->
      fmap (fmap (Just . Text.strip))
        (runGitHubCommand repositoryRoot ghPath (githubIssueCommentArguments repo request.githubToolIssue) comment)
  case commentResult of
    Left message -> pure (Left message)
    Right commentUrl -> do
      labelResult <- ensureRevisedLabel repositoryRoot repo ghPath request.githubToolAddLabels
      case labelResult of
        Left message -> pure (Left (partialUpdateMessage commentUrl message))
        Right () -> do
          edited <- applyReviewLabels repositoryRoot repo ghPath request
          pure $ case edited of
            Left message -> Left (partialUpdateMessage commentUrl message)
            Right _ -> Right (githubUpdateResult commentUrl request)

ensureRevisedLabel :: FilePath -> Text -> FilePath -> [Text] -> IO (Either Text ())
ensureRevisedLabel repositoryRoot repo ghPath labels
  | "reviewed:revised" `notElem` labels = pure (Right ())
  | otherwise = fmap (fmap (const ())) (runGitHubCommand repositoryRoot ghPath (githubLabelCreateArguments repo) "")

applyReviewLabels :: FilePath -> Text -> FilePath -> GitHubIssueToolRequest -> IO (Either Text Text)
applyReviewLabels repositoryRoot repo ghPath request
  | null request.githubToolAddLabels && null request.githubToolRemoveLabels = pure (Right "")
  | otherwise = runGitHubCommand repositoryRoot ghPath (githubIssueEditArguments repo request) ""

githubUpdateResult :: Maybe Text -> GitHubIssueToolRequest -> Text
githubUpdateResult commentUrl request =
  TextEncoding.decodeUtf8
    . LazyByteString.toStrict
    . encode
    $ object
      [ "issue" .= request.githubToolIssue,
        "commentUrl" .= commentUrl,
        "addedLabels" .= request.githubToolAddLabels,
        "removedLabels" .= request.githubToolRemoveLabels
      ]

partialUpdateMessage :: Maybe Text -> Text -> Text
partialUpdateMessage Nothing message = message
partialUpdateMessage (Just commentUrl) message =
  "The issue comment was posted at " <> commentUrl <> ", but the label update failed: " <> message

runGitHubCommand :: FilePath -> FilePath -> [String] -> Text -> IO (Either Text Text)
runGitHubCommand repositoryRoot ghPath arguments input = do
  started <- try (createProcess processSpec) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
  case started of
    Left exception -> pure (Left ("Could not start GitHub CLI: " <> exceptionText exception))
    Right (Just inputHandle, Just outputHandle, Just errorHandle, processHandle) -> do
      outputResult <- newEmptyMVar
      errorResult <- newEmptyMVar
      void . forkIO $ captureHandle outputHandle outputResult
      void . forkIO $ captureHandle errorHandle errorResult
      written <- try (ByteString.hPutStr inputHandle (TextEncoding.encodeUtf8 input) >> hClose inputHandle) :: IO (Either IOException ())
      case written of
        Left exception -> do
          stopOwnedProcess processHandle
          pure (Left ("Could not send input to GitHub CLI: " <> exceptionText exception))
        Right () -> do
          completed <-
            timeout githubCommandTimeoutMicros $ do
              exitCode <- waitForProcess processHandle
              output <- takeMVar outputResult
              errors <- takeMVar errorResult
              pure (exitCode, output, errors)
          case completed of
            Nothing -> do
              stopOwnedProcess processHandle
              pure (Left "GitHub operation timed out after 30 seconds")
            Just captured -> pure (renderGitHubCommandResult captured)
    Right _ -> pure (Left "GitHub CLI did not provide all three standard streams")
  where
    processSpec =
      (proc ghPath arguments)
        { cwd = Just repositoryRoot,
          std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }

runCanonicalCommand :: Repository -> Int -> FilePath -> [String] -> (ManagedProcess -> IO ()) -> IO (Either Text Text)
runCanonicalCommand repository issueNumber executable arguments processStarted = do
  logResult <- openSessionLog repository "issue-canonical-review" issueNumber Nothing
  sessionLog <- case logResult of
    Left _ -> pure Nothing
    Right value -> logMessage value "command-started" (Text.pack executable) >> pure (Just value)
  started <- try (createProcess processSpec) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
  case started of
    Left exception -> finishLog sessionLog >> pure (Left ("Could not start canonical issue reviewer: " <> exceptionText exception))
    Right (Nothing, Just outputHandle, Just errorHandle, processHandle) -> do
      (managed, groupLeaderProblem) <- managedProcess processHandle
      mapM_ (\value -> mapM_ (logMessage value "group-leadership-unverified") groupLeaderProblem) sessionLog
      processStarted managed
      outputResult <- newEmptyMVar
      errorResult <- newEmptyMVar
      void . forkIO $ captureHandle outputHandle outputResult
      void . forkIO $ captureHandle errorHandle errorResult
      completed <- timeout canonicalReviewTimeoutMicros $ do
        exitCode <- waitForProcess processHandle
        output <- takeMVar outputResult
        errors <- takeMVar errorResult
        pure (exitCode, output, errors)
      case completed of
        Nothing -> stopOwnedProcess processHandle >> finishLog sessionLog >> pure (Left "Canonical issue review timed out after one hour")
        Just (ExitSuccess, Right output, errors) -> do
          logCaptured sessionLog output errors
          finishLog sessionLog
          pure (Right (decodeClaudeBytes output))
        Just (ExitFailure code, Right output, Right errors) ->
          logCaptured sessionLog output (Right errors) >> finishLog sessionLog >> pure (Left ("Canonical issue reviewer exited with status " <> Text.pack (show code) <> renderClaudeFailureDetails output errors))
        Just (_, Left exception, _) -> finishLog sessionLog >> pure (Left ("Could not read canonical issue review output: " <> exceptionText exception))
        Just (_, _, Left exception) -> finishLog sessionLog >> pure (Left ("Could not read canonical issue review diagnostics: " <> exceptionText exception))
    Right _ -> finishLog sessionLog >> pure (Left "Canonical issue reviewer did not provide stdout and stderr pipes")
  where
    repositoryRoot = repository.repositoryRoot
    finishLog sessionLog = mapM_ (\value -> logMessage value "command-finished" "canonical issue review" >> closeSessionLog value) sessionLog
    logCaptured sessionLog output errors = do
      mapM_ (\value -> mapM_ (logRawLine value "stdout") (ByteString.split '\n' output)) sessionLog
      case errors of
        Right errorBytes -> mapM_ (\value -> mapM_ (logRawLine value "stderr") (ByteString.split '\n' errorBytes)) sessionLog
        Left _ -> pure ()
    processSpec =
      (proc executable arguments)
        { cwd = Just repositoryRoot,
          std_in = NoStream,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }

renderGitHubCommandResult :: (ExitCode, Either IOException ByteString.ByteString, Either IOException ByteString.ByteString) -> Either Text Text
renderGitHubCommandResult (exitCode, outputResult, errorResult) = case (exitCode, outputResult, errorResult) of
  (_, Left exception, _) -> Left ("Could not read GitHub CLI output: " <> exceptionText exception)
  (_, _, Left exception) -> Left ("Could not read GitHub CLI diagnostics: " <> exceptionText exception)
  (ExitSuccess, Right output, Right _) -> Right (decodeClaudeBytes output)
  (ExitFailure code, Right output, Right errors) ->
    Left
      ( "GitHub CLI exited with status "
          <> Text.pack (show code)
          <> renderClaudeFailureDetails output errors
      )

runAuthenticatedClaude :: ReviewClient -> Text -> Text -> IO (Either Text Text)
runAuthenticatedClaude client threadId prompt = do
  executable <- findExecutable "claude"
  case executable of
    Nothing -> pure (Left "Claude CLI was not found on PATH")
    Just claudePath -> do
      started <- try (createProcess (claudeProcess claudePath)) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
      case started of
        Left exception -> pure (Left ("Could not start authenticated Claude CLI: " <> exceptionText exception))
        Right (Just inputHandle, Just outputHandle, Just errorHandle, processHandle) -> do
          (managed, groupLeaderProblem) <- managedProcess processHandle
          mapM_ (\problem -> client.reviewEventSink (ReviewProtocolWarning ("process group leadership: " <> problem))) groupLeaderProblem
          modifyMVar_ client.reviewToolProcesses (pure . Map.insert threadId managed)
          outputResult <- newEmptyMVar
          errorResult <- newEmptyMVar
          void . forkIO $ captureHandle outputHandle outputResult
          void . forkIO $ captureHandle errorHandle errorResult
          written <- try (ByteString.hPutStr inputHandle (TextEncoding.encodeUtf8 prompt) >> hClose inputHandle) :: IO (Either IOException ())
          result <- case written of
            Left exception -> do
              stopOwnedProcess processHandle
              pure (Left ("Could not send the reviewer prompt to Claude: " <> exceptionText exception))
            Right () -> do
              completed <-
                timeout claudeReviewerTimeoutMicros $ do
                  exitCode <- waitForProcess processHandle
                  output <- takeMVar outputResult
                  errors <- takeMVar errorResult
                  pure (exitCode, output, errors)
              case completed of
                Nothing -> do
                  stopOwnedProcess processHandle
                  pure (Left "Claude Sonnet 5 revision agent timed out after ten minutes")
                Just captured -> pure (renderClaudeResult captured)
          modifyMVar_ client.reviewToolProcesses (pure . Map.delete threadId)
          pure result
        Right _ -> pure (Left "Claude CLI did not provide all three standard streams")
  where
    claudeProcess claudePath =
      ( proc
          claudePath
          [ "--print",
            "--model",
            "claude-sonnet-5",
            "--effort",
            "high",
            "--permission-mode",
            "plan",
            "--safe-mode",
            "--no-session-persistence"
          ]
      )
        { cwd = Just client.reviewRepositoryRoot,
          std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }

captureHandle :: Handle -> MVar (Either IOException ByteString.ByteString) -> IO ()
captureHandle handle result = do
  captured <- try (ByteString.hGetContents handle)
  putMVar result captured

renderClaudeResult :: (ExitCode, Either IOException ByteString.ByteString, Either IOException ByteString.ByteString) -> Either Text Text
renderClaudeResult (exitCode, outputResult, errorResult) = case (exitCode, outputResult, errorResult) of
  (_, Left exception, _) -> Left ("Could not read Claude reviewer output: " <> exceptionText exception)
  (_, _, Left exception) -> Left ("Could not read Claude reviewer diagnostics: " <> exceptionText exception)
  (ExitSuccess, Right output, Right _)
    | Text.null renderedOutput -> Left "Claude returned no reviewer output"
    | otherwise -> Right renderedOutput
    where
      renderedOutput = decodeClaudeBytes output
  (ExitFailure code, Right output, Right errors) ->
    Left
      ( "Claude Sonnet 5 exited with status "
          <> Text.pack (show code)
          <> renderClaudeFailureDetails output errors
      )

renderClaudeFailureDetails :: ByteString.ByteString -> ByteString.ByteString -> Text
renderClaudeFailureDetails output errors =
  case filter (not . Text.null) [decodeClaudeBytes errors, decodeClaudeBytes output] of
    [] -> ""
    messages -> ": " <> Text.take claudeDiagnosticLimit (Text.intercalate "\n" messages)

decodeClaudeBytes :: ByteString.ByteString -> Text
decodeClaudeBytes = Text.strip . TextEncoding.decodeUtf8With lenientDecode

stopOwnedProcess :: ProcessHandle -> IO ()
stopOwnedProcess processHandle = do
  processId <- getPid processHandle
  case processId of
    Just pid -> ignoreIOException (signalProcessGroup sigTERM pid)
    Nothing -> terminateProcess processHandle
  stopped <- timeout shutdownTimeoutMicros (waitForProcess processHandle)
  case (stopped, processId) of
    (Nothing, Just pid) -> ignoreIOException (signalProcessGroup sigKILL pid)
    (Nothing, Nothing) -> terminateProcess processHandle
    _ -> pure ()

sendErrorResponse :: ReviewClient -> Value -> Int -> Text -> IO (Either Text ())
sendErrorResponse client requestId code message =
  sendValue client (object ["id" .= requestId, "error" .= object ["code" .= code, "message" .= message]])

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

githubRequestMatchesThread :: ReviewClient -> Text -> GitHubIssueToolRequest -> IO Bool
githubRequestMatchesThread client threadId request =
  withMVar client.reviewThreadIssues $ \threadIssues ->
    pure (Map.lookup threadId threadIssues == Just request.githubToolIssue)

requestIdInt :: Value -> Maybe Int
requestIdInt value = case fromJSON value of
  Success integer -> Just integer
  Error _ -> Nothing

resultThreadId :: Value -> Maybe Text
resultThreadId = nestedText ["thread", "id"]

fieldText :: Text -> Value -> Maybe Text
fieldText key = nestedText [key]

objectField :: Text -> Value -> Maybe Value
objectField key (Object value) = KeyMap.lookup (Key.fromText key) value
objectField _ _ = Nothing

nestedText :: [Text] -> Value -> Maybe Text
nestedText [] (String value) = Just value
nestedText (key : keys) value = objectField key value >>= nestedText keys
nestedText _ _ = Nothing

turnOutcome :: Value -> ReviewTurnOutcome
turnOutcome params = case nestedText ["turn", "status"] params of
  Just "completed" -> TurnSucceeded
  Just "interrupted" -> TurnInterrupted
  Just "cancelled" -> TurnInterrupted
  _ -> TurnFailed

turnResult :: Value -> Maybe (Text, ReviewResult)
turnResult params = do
  turn <- objectField "turn" params
  itemsValue <- objectField "items" turn
  items <- case fromJSON itemsValue of
    Success values -> Just (values :: [Value])
    Error _ -> Nothing
  message <- safeLastValue [item | item <- items, fieldText "type" item == Just "agentMessage"]
  text <- fieldText "text" message
  result <- either (const Nothing) Just (decodeReviewResult text)
  pure (text, result)

safeLastValue :: [value] -> Maybe value
safeLastValue [] = Nothing
safeLastValue values = Just (last values)

compactValue :: Value -> Text
compactValue = Text.take 1000 . TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode

decodeLine :: LazyByteString.ByteString -> Text
decodeLine = Text.stripEnd . TextEncoding.decodeUtf8With lenientDecode . LazyByteString.toStrict

exceptionText :: Exception exception => exception -> Text
exceptionText = Text.pack . displayException

renderExitCode :: ExitCode -> Text
renderExitCode ExitSuccess = "Codex app-server exited"
renderExitCode (ExitFailure code) = "Codex app-server exited with status " <> Text.pack (show code)

ignoreIOException :: IO () -> IO ()
ignoreIOException action = do
  _ <- try action :: IO (Either IOException ())
  pure ()

questionToolName :: Text
questionToolName = "kanban_prompt_user"

claudeToolName :: Text
claudeToolName = "kanban_run_claude"

githubToolName :: Text
githubToolName = "kanban_github_issue"

questionTool :: Value
questionTool =
  object
    [ "type" .= ("function" :: Text),
      "name" .= questionToolName,
      "description" .= ("Ask the user a structured question through the Kanban review panel and wait for the returned answer." :: Text),
      "inputSchema"
        .= object
          [ "type" .= ("object" :: Text),
            "additionalProperties" .= False,
            "required" .= (["id", "question", "kind"] :: [Text]),
            "properties"
              .= object
                [ "id" .= stringSchema,
                  "header" .= stringSchema,
                  "question" .= stringSchema,
                  "kind" .= object ["type" .= ("string" :: Text), "enum" .= (["choice", "text"] :: [Text])],
                  "options"
                    .= object
                      [ "type" .= ("array" :: Text),
                        "items"
                          .= object
                            [ "type" .= ("object" :: Text),
                              "additionalProperties" .= False,
                              "required" .= (["id", "label"] :: [Text]),
                              "properties"
                                .= object
                                  [ "id" .= stringSchema,
                                    "label" .= stringSchema,
                                    "description" .= stringSchema
                                  ]
                            ]
                      ],
                  "allowOther" .= booleanSchema,
                  "multiple" .= booleanSchema
                ]
          ]
    ]
  where
    stringSchema = object ["type" .= ("string" :: Text)]
    booleanSchema = object ["type" .= ("boolean" :: Text)]

claudeTool :: Value
claudeTool =
  object
    [ "type" .= ("function" :: Text),
      "name" .= claudeToolName,
      "description"
        .= ( "Run the authenticated Claude Sonnet 5 high specification-revision agent through Kanban outside the Codex command sandbox. Provide a standalone prompt containing the issue, effective specification, repository evidence, blockers, and exact requested amendment output."
               :: Text
           ),
      "inputSchema"
        .= object
          [ "type" .= ("object" :: Text),
            "additionalProperties" .= False,
            "required" .= (["prompt"] :: [Text]),
            "properties" .= object ["prompt" .= object ["type" .= ("string" :: Text)]]
          ]
    ]

githubTool :: WorkflowConfig -> Value
githubTool workflowConfig =
  object
    [ "type" .= ("function" :: Text),
      "name" .= githubToolName,
      "description"
        .= ( "Read the live GitHub issue and comments, or perform the review workflow's bounded comment/label update. This is the only permitted GitHub interface for the embedded workflow."
               :: Text
           ),
      "inputSchema"
        .= object
          [ "type" .= ("object" :: Text),
            "additionalProperties" .= False,
            "required" .= (["operation", "issue"] :: [Text]),
            "properties"
              .= object
                [ "operation" .= object ["type" .= ("string" :: Text), "enum" .= (["read", "update"] :: [Text])],
                  "issue" .= object ["type" .= ("integer" :: Text), "minimum" .= (1 :: Int)],
                  "comment" .= object ["type" .= (["string", "null"] :: [Text])],
                  "addLabels" .= reviewLabelArraySchema,
                  "removeLabels" .= reviewLabelArraySchema
                ]
          ]
    ]
  where
    reviewLabelArraySchema =
      object
        [ "type" .= ("array" :: Text),
          "items" .= object ["type" .= ("string" :: Text), "enum" .= reviewWorkflowLabels workflowConfig],
          "uniqueItems" .= True
        ]

reviewDeveloperInstructions :: WorkflowConfig -> Text
reviewDeveloperInstructions workflowConfig =
  Text.unlines
    [ "You are the interactive issue-review and specification-revision coordinator embedded inside the Kanban terminal dashboard.",
      "Never run ~/work/approve-issues.py, the installed tools/approve_issues.py backend from any path, or any background approval daemon.",
      "Advance exactly ONE workflow stage per invocation. Do not edit repository files, edit the issue body, or implement the issue.",
      "All questions requiring user input MUST use the kanban_prompt_user tool. Never ask a question in ordinary assistant prose.",
      "Use kind=choice with 2-5 concrete options when possible. Set multiple=false and ask one decision per tool call. Use kind=text only for genuinely free-form context.",
      "Read the live GitHub issue, all of its comments in chronological order, and its labels. The effective specification is the issue body plus canonical issue-comment amendments, with explicit later amendments superseding earlier conflicting text.",
      "Find the hidden <!-- issue-origin:claude --> or <!-- issue-origin:codex --> marker in the issue body.",
      "You MUST use kanban_github_issue for every GitHub issue read, comment, or review-label mutation. Never invoke gh, curl, or a GitHub API through a shell or command tool. The Kanban tool is already authenticated and its update operation is restricted to one issue comment and the three review workflow labels.",
      "Whenever revision requires Claude Sonnet 5 high, you MUST call kanban_run_claude. Never invoke claude, claude-code, or another Claude executable through a shell or command tool. The Kanban tool owns authenticated execution and returns Sonnet's text.",
      "The kanban_run_claude prompt must be standalone: include the issue body, relevant chronological comments/effective specification, repository evidence, blockers, and request exact amendment content. Sonnet runs in plan mode and must not be asked to edit files, post comments, or change labels.",
      "Choose the one stage from live labels: reviewed:revised means REREVIEW; otherwise "
        <> workflowConfig.changesRequestedLabel
        <> " means REVISION; otherwise INITIAL REVIEW.",
      "INITIAL REVIEW and REREVIEW are owned by the canonical approve-issues.py v2 backend and must never be performed in this app-server thread. This thread performs REVISION only.",
      "REVISION switches back to the issue author's brand: Codex-origin amendment content is authored by you as GPT-5.4 high; Claude-origin amendment content is authored by Claude Sonnet 5 high; unmarked issues default to you as GPT-5.4 high.",
      "During REVISION, classify every latest review blocker. Resolve mechanical, repository-verifiable, or clearly implied omissions without asking. If two or more reasonable answers would change behavior, compatibility, scope, policy, migration semantics, or user-visible outcomes, ask the user through kanban_prompt_user before proceeding.",
      "After resolving every blocker during REVISION, post exactly one canonical issue comment headed '## Specification amendment'. State that it supplements the issue body, list the normative clarifications and acceptance/test changes, and end with <!-- kanban-spec-amendment -->.",
      "After posting the amendment, ensure the repository has a reviewed:revised label (create it with purple color 8250DF if missing), add it to the issue, and remove "
        <> workflowConfig.changesRequestedLabel
        <> " and "
        <> workflowConfig.approvalLabel
        <> ". Do NOT rereview or approve in the same invocation.",
      "If REVISION cannot resolve every blocker, do not post a partial amendment and leave "
        <> workflowConfig.changesRequestedLabel
        <> " in place.",
      "Never close the issue. Finish with the requested structured result. Set stage to review, revision, or rereview. For revision set approved=false; commentUrl is the amendment comment and blockingReasons contains only unresolved blockers."
    ]

reviewPrompt :: Int -> Text
reviewPrompt issueNumber =
  "Perform exactly the specification REVISION stage for GitHub issue #"
    <> Text.pack (show issueNumber)
    <> " in this repository now. It has canonical CHANGES_REQUESTED state from approve-issues.py. Follow the embedded revision policy, post one authoritative amendment, and leave it ready for canonical v2 rereview."

finalOutputSchema :: Value
finalOutputSchema =
  object
    [ "type" .= ("object" :: Text),
      "additionalProperties" .= False,
      "required" .= (["issue", "stage", "approved", "reviewerRoute", "models", "commentUrl", "blockingReasons"] :: [Text]),
      "properties"
        .= object
          [ "issue" .= object ["type" .= ("integer" :: Text)],
            "stage" .= object ["type" .= ("string" :: Text), "enum" .= (["review", "revision", "rereview"] :: [Text])],
            "approved" .= object ["type" .= ("boolean" :: Text)],
            "reviewerRoute" .= object ["type" .= ("string" :: Text)],
            "models" .= object ["type" .= ("array" :: Text), "items" .= object ["type" .= ("string" :: Text)]],
            "commentUrl" .= object ["type" .= (["string", "null"] :: [Text])],
            "blockingReasons" .= object ["type" .= ("array" :: Text), "items" .= object ["type" .= ("string" :: Text)]]
          ]
    ]

initializationTimeoutMicros :: Int
initializationTimeoutMicros = 10 * 1000 * 1000

shutdownTimeoutMicros :: Int
shutdownTimeoutMicros = 2 * 1000 * 1000

claudeReviewerTimeoutMicros :: Int
claudeReviewerTimeoutMicros = 10 * 60 * 1000 * 1000

canonicalReviewTimeoutMicros :: Int
canonicalReviewTimeoutMicros = 60 * 60 * 1000 * 1000

claudePromptLimit :: Int
claudePromptLimit = 100000

claudeDiagnosticLimit :: Int
claudeDiagnosticLimit = 4000

githubCommandTimeoutMicros :: Int
githubCommandTimeoutMicros = 30 * 1000 * 1000

githubCommentLimit :: Int
githubCommentLimit = 100000
