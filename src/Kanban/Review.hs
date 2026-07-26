{-# LANGUAGE DeriveGeneric #-}

module Kanban.Review
  ( CanonicalIssueReviewResult (..),
    CommandBounds (..),
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
    ToolRegistry,
    answerReviewQuestion,
    approveReviewAction,
    attachToolProcess,
    beginIssueReview,
    canonicalCommandBounds,
    canonicalIssueReviewArguments,
    canonicalIssueReviewerPath,
    decodeCanonicalIssueReviewResult,
    decodeClaudeToolPrompt,
    decodeGitHubIssueToolRequest,
    decodeReviewQuestion,
    decodeReviewResult,
    decodeReviewWireMessage,
    drainToolRegistry,
    githubCommandBounds,
    githubIssueCommentArguments,
    githubIssueEditArguments,
    githubIssueViewArguments,
    githubLabelCreateArguments,
    handleWireMessage,
    interruptReview,
    killReviewTools,
    killThreadToolProcesses,
    newRecordingReviewClientForTesting,
    newReviewClientForTesting,
    newToolRegistry,
    outcomeUnknownDiagnostic,
    releaseToolSlot,
    renderCanonicalIssueReviewResult,
    reserveToolSlot,
    resolveCanonicalIssueReviewer,
    reviewStageForLabels,
    runCanonicalCommand,
    runCanonicalIssueReview,
    runGitHubIssueTool,
    sendReviewMessage,
    startReviewClient,
    stopReviewClient,
    renderReviewResult,
    withReservedToolSlot,
  )
where

import Control.Concurrent (MVar, ThreadId, forkIO, killThread, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, takeMVar, withMVar)
import Control.Concurrent.MVar (readMVar, tryReadMVar)
import Control.Exception (Exception, IOException, displayException, try)
import Control.Monad (forever, unless, void)
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
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import GHC.Generics (Generic)
import Kanban.Domain (Repository (..), WorkflowConfig (..), defaultWorkflowConfig)
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
    createPipe,
    createProcess,
    proc,
    waitForProcess,
  )
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
  -- | A @turn/steer@ the app-server rejected whose text could not be resent
  -- automatically, carrying the thread, the turn the steer targeted, and the
  -- user's original message so the session can offer it back for a deliberate
  -- resend (issue #17). Emitted only when a turn is still active on the
  -- thread: with no active turn the message is resent as a new @turn/start@
  -- instead, and nothing is reported.
  | ReviewSteerUndelivered Text Text Text
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
  -- | An in-flight @turn/steer@, retaining its thread, the @expectedTurnId@
  -- it targeted, and the user's message. Without that context a rejection
  -- could only be reported as a generic protocol warning, silently dropping
  -- the typed feedback (issue #17). Interrupts and approval responses stay
  -- 'PendingOther'.
  | PendingSteer Text Text Text
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

-- | The two independent bounds every review subprocess runs under: how long
-- it may take to *exit*, and how much longer than that its output capture
-- may lag before the call gives up on a stream something still holds open.
-- Keeping them separate is what stops an already-observed exit from being
-- reported as a timeout (issue #15). Production uses 'githubCommandBounds'
-- and 'canonicalCommandBounds'; tests inject sub-second values so the
-- deadline and grace paths are reachable without waiting out the real 30 s
-- and one-hour deadlines.
data CommandBounds = CommandBounds
  { commandDeadlineMicros :: Int,
    commandCaptureGraceMicros :: Int
  }
  deriving stock (Eq, Show)

data ReviewClient = ReviewClient
  { reviewInput :: Handle,
    reviewProcess :: ProcessHandle,
    -- | The app-server's own pgid, captured at spawn time so shutdown can
    -- still signal it after 'reviewProcess' has been reaped (see
    -- 'ToolRegistry' and issue #16).
    reviewProcessManaged :: ManagedProcess,
    reviewWriteLock :: MVar (),
    reviewNextRequestId :: IORef Int,
    reviewPendingRequests :: MVar (Map Int PendingRequest),
    -- | The turn currently running on each thread, maintained from the
    -- @turn/started@ and @turn/completed@ notifications. The UI keeps its own
    -- copy for display, but a rejected steer has to be classified against
    -- what the wire has actually delivered *at that point in the stream*, and
    -- notifications and responses are handled in order by the single
    -- 'readServerOutput' thread — so this map, not the UI's asynchronously
    -- updated session state, decides whether a rejected steer can be resent
    -- (issue #17).
    reviewActiveTurns :: MVar (Map Text Text),
    reviewThreadIssues :: MVar (Map Text Int),
    reviewToolRegistry :: ToolRegistry,
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
    reviewErrorDone :: MVar (),
    -- | The bounds every @gh@ subprocess behind @kanban_github_issue@ runs
    -- under. Carried on the client rather than passed down, so the
    -- mutation-specific wrappers above 'runGitHubCommand' -- which is where
    -- the verify-before-retry guidance is chosen -- are all reachable from a
    -- test that injects short bounds.
    reviewCommandBounds :: CommandBounds
  }

-- | Tracks every externally spawned review-tool child process (each
-- @kanban_run_claude@ invocation, each @gh@ subprocess behind
-- @kanban_github_issue@) for the full window between spawn and termination
-- handoff, keyed by a unique invocation id rather than by thread id — two
-- overlapping invocations on the same review thread never collide, and
-- 'killReviewTools' kills every invocation owned by a thread without
-- disturbing another thread's entries.
--
-- Registration happens in two steps around the actual process spawn so a
-- cancellation or full shutdown racing that spawn can never leave an
-- unregistered child running: 'reserveToolSlot' records *intent* before the
-- process exists, and 'attachToolProcess' fills in the spawned
-- 'ManagedProcess' immediately after. If the reservation was already
-- drained (by 'killThreadToolProcesses' or 'drainToolRegistry') in that
-- narrow window, 'attachToolProcess' reports failure and the caller kills
-- the process it just spawned itself, so nothing it started can outlive a
-- cancellation or shutdown that had already committed to draining it.
data ToolRegistry = ToolRegistry
  { toolRegistryCounter :: IORef Int,
    toolRegistryState :: MVar ToolRegistryState
  }

data ToolRegistryState = ToolRegistryState
  { toolRegistryClosed :: Bool,
    toolRegistryEntries :: Map Int ToolEntry
  }

data ToolEntry = ToolEntry
  { toolEntryThread :: Text,
    toolEntryProcess :: Maybe ManagedProcess
  }

newToolRegistry :: IO ToolRegistry
newToolRegistry = ToolRegistry <$> newIORef 0 <*> newMVar (ToolRegistryState False Map.empty)

-- | Reserve a slot for an about-to-be-spawned tool process. 'Nothing' means
-- the registry is already closed (client shutdown has begun) — the caller
-- must not spawn at all.
reserveToolSlot :: ToolRegistry -> Text -> IO (Maybe Int)
reserveToolSlot registry threadId = do
  key <- atomicModifyIORef' registry.toolRegistryCounter (\next -> (next + 1, next))
  modifyMVar registry.toolRegistryState $ \state ->
    pure $
      if state.toolRegistryClosed
        then (state, Nothing)
        else (state {toolRegistryEntries = Map.insert key (ToolEntry threadId Nothing) state.toolRegistryEntries}, Just key)

-- | Attach the now-spawned process to its reservation. 'False' means the
-- reservation is already gone — drained by a same-thread cancel or a full
-- shutdown while the process was spawning — so the caller now owns killing
-- the process it just spawned, since no drain will ever see it.
attachToolProcess :: ToolRegistry -> Int -> ManagedProcess -> IO Bool
attachToolProcess registry key managed =
  modifyMVar registry.toolRegistryState $ \state ->
    case Map.lookup key state.toolRegistryEntries of
      Nothing -> pure (state, False)
      Just entry -> pure (state {toolRegistryEntries = Map.insert key (entry {toolEntryProcess = Just managed}) state.toolRegistryEntries}, True)

-- | Release a completed invocation's slot, whether or not it ever attached
-- a process.
releaseToolSlot :: ToolRegistry -> Int -> IO ()
releaseToolSlot registry key =
  modifyMVar_ registry.toolRegistryState $ \state ->
    pure state {toolRegistryEntries = Map.delete key state.toolRegistryEntries}

-- | Kill and drop every entry owned by `threadId`. A still-pending
-- reservation (no process yet) is simply dropped — its spawn discovers this
-- via 'attachToolProcess' and kills the process itself.
killThreadToolProcesses :: ToolRegistry -> Text -> IO ()
killThreadToolProcesses registry threadId = do
  dropped <- modifyMVar registry.toolRegistryState $ \state ->
    let (mine, rest) = Map.partition (\entry -> entry.toolEntryThread == threadId) state.toolRegistryEntries
     in pure (state {toolRegistryEntries = rest}, Map.elems mine)
  mapM_ killToolEntry dropped

-- | Close the registry — no further reservation succeeds — and hand back
-- every process that was already running, for the caller to kill. Used by
-- full client shutdown, where nothing may be left running or registered
-- afterward.
drainToolRegistry :: ToolRegistry -> IO [ManagedProcess]
drainToolRegistry registry = do
  entries <- modifyMVar registry.toolRegistryState $ \state ->
    pure (ToolRegistryState True Map.empty, Map.elems state.toolRegistryEntries)
  pure [managed | ToolEntry _ (Just managed) <- entries]

killToolEntry :: ToolEntry -> IO ()
killToolEntry entry = mapM_ killManagedProcess entry.toolEntryProcess

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
                  canonicalCommandBounds
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
      (processManaged, groupLeaderProblem) <- managedProcess processHandle
      mapM_ (\value -> mapM_ (logMessage value "group-leadership-unverified") groupLeaderProblem) sessionLog
      writeLock <- newMVar ()
      requestCounter <- newIORef 2
      pendingRequests <- newMVar Map.empty
      activeTurns <- newMVar Map.empty
      threadIssues <- newMVar Map.empty
      toolRegistry <- newToolRegistry
      outputDone <- newEmptyMVar
      errorDone <- newEmptyMVar
      let client =
            ReviewClient
              { reviewInput = inputHandle,
                reviewProcess = processHandle,
                reviewProcessManaged = processManaged,
                reviewWriteLock = writeLock,
                reviewNextRequestId = requestCounter,
                reviewPendingRequests = pendingRequests,
                reviewActiveTurns = activeTurns,
                reviewThreadIssues = threadIssues,
                reviewToolRegistry = toolRegistry,
                reviewEventSink = eventSink,
                reviewRepositoryRoot = repositoryRoot,
                reviewRepositorySlug = repository.repositoryOwner <> "/" <> repository.repositoryName,
                reviewWorkflowConfig = workflowConfig,
                reviewSessionLog = sessionLog,
                reviewOutputDone = outputDone,
                reviewErrorDone = errorDone,
                reviewCommandBounds = githubCommandBounds
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

-- | Builds a 'ReviewClient' without the app-server handshake 'startReviewClient'
-- performs, so tests can exercise the tool-invocation and registry machinery
-- (@kanban_run_claude@, @kanban_github_issue@, 'killReviewTools',
-- 'stopReviewClient') directly. The client's own "app-server" is a harmless
-- placeholder process (@git --version@, already an audited invocation of
-- this codebase's own workflow) so shutdown still has a real, killable
-- process to operate on.
newReviewClientForTesting :: CommandBounds -> FilePath -> Text -> (ReviewEvent -> IO ()) -> IO ReviewClient
newReviewClientForTesting bounds repositoryRoot repositorySlug eventSink = do
  (Just inputHandle, Just _outputHandle, Just _errorHandle, processHandle) <-
    createProcess
      (proc "git" ["--version"])
        { std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }
  (processManaged, _) <- managedProcess processHandle
  writeLock <- newMVar ()
  requestCounter <- newIORef 2
  pendingRequests <- newMVar Map.empty
  activeTurns <- newMVar Map.empty
  threadIssues <- newMVar Map.empty
  toolRegistry <- newToolRegistry
  outputDone <- newEmptyMVar
  errorDone <- newEmptyMVar
  pure
    ReviewClient
      { reviewInput = inputHandle,
        reviewProcess = processHandle,
        reviewProcessManaged = processManaged,
        reviewWriteLock = writeLock,
        reviewNextRequestId = requestCounter,
        reviewPendingRequests = pendingRequests,
        reviewActiveTurns = activeTurns,
        reviewThreadIssues = threadIssues,
        reviewToolRegistry = toolRegistry,
        reviewEventSink = eventSink,
        reviewRepositoryRoot = repositoryRoot,
        reviewRepositorySlug = repositorySlug,
        reviewWorkflowConfig = defaultWorkflowConfig,
        reviewSessionLog = Nothing,
        reviewOutputDone = outputDone,
        reviewErrorDone = errorDone,
        reviewCommandBounds = bounds
      }

-- | A 'newReviewClientForTesting' whose "app-server" stdin is a pipe the
-- caller reads, so a test can drive responses in through 'handleWireMessage'
-- and assert on the exact wire traffic they provoke — the seam the steer
-- recovery path needs, since the suite previously only decoded app-server
-- messages rather than letting a handler answer one (issue #17).
newRecordingReviewClientForTesting :: (ReviewEvent -> IO ()) -> IO (ReviewClient, Handle)
newRecordingReviewClientForTesting eventSink = do
  client <- newReviewClientForTesting githubCommandBounds "." "coghex/kanban" eventSink
  (readEnd, writeEnd) <- createPipe
  hSetBuffering writeEnd LineBuffering
  -- The placeholder process's own stdin is of no further use, and leaving it
  -- open would outlive 'stopReviewClient', which closes 'reviewInput' only.
  ignoreIOException (hClose client.reviewInput)
  pure (client {reviewInput = writeEnd}, readEnd)

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
  Just turnId -> sendRequest client (PendingSteer threadId turnId message) "turn/steer" (steerParams turnId)
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
killReviewTools client threadId = killThreadToolProcesses client.reviewToolRegistry threadId

-- | Drains every registered tool process and signals the app-server's own
-- recorded process group, using the exact same best-effort primitive
-- ('killManagedProcess') regardless of whether the app-server's leader
-- handle has already been reaped — shared by the user-initiated shutdown
-- path ('stopReviewClient') and every natural-crash terminal path
-- ('watchServerProcess', 'readServerOutput'), so a client that is about to
-- be discarded (see @ReviewClientStopped@ handling in "Kanban.UI") never
-- leaves an in-flight tool call or a surviving app-server group member
-- unsignalled.
terminalReviewClientCleanup :: ReviewClient -> IO ()
terminalReviewClientCleanup client = do
  toolProcesses <- drainToolRegistry client.reviewToolRegistry
  mapM_ killManagedProcess toolProcesses
  killManagedProcess client.reviewProcessManaged

stopReviewClient :: ReviewClient -> IO ()
stopReviewClient client = do
  terminalReviewClientCleanup client
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
    Left exception -> do
      terminalReviewClientCleanup client
      client.reviewEventSink (ReviewClientStopped ("Codex app-server output closed: " <> exceptionText exception))
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
  terminalReviewClientCleanup client
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
      -- A rejected steer still holds the user's typed guidance, so it is
      -- recovered rather than reported and dropped (issue #17). The natural
      -- rejection is the targeted turn ending in the instant before the
      -- request landed: with the thread now idle the message becomes the
      -- 'turn/start' the user would have sent a moment later. While any turn
      -- is running -- a newer one, or the targeted one the server rejected
      -- the steer against anyway -- applying the message would silently
      -- redirect it, so the session takes it back for a deliberate resend.
      (Just (PendingSteer threadId targetTurnId message), Left _) -> do
        activeTurn <- Map.lookup threadId <$> readMVar client.reviewActiveTurns
        case activeTurn of
          Nothing -> do
            resent <- sendTurnStart client threadId message
            case resent of
              Right () -> pure ()
              Left _ -> client.reviewEventSink (ReviewSteerUndelivered threadId targetTurnId message)
          Just _ -> client.reviewEventSink (ReviewSteerUndelivered threadId targetTurnId message)
      (_, Left err) -> client.reviewEventSink (ReviewProtocolWarning ("Codex request failed: " <> compactValue err))
      _ -> pure ()

handleNotification :: ReviewClient -> Text -> Value -> IO ()
handleNotification client method params = case method of
  "turn/started" -> case (fieldText "threadId" params, nestedText ["turn", "id"] params) of
    (Just threadId, Just turnId) -> do
      modifyMVar_ client.reviewActiveTurns (pure . Map.insert threadId turnId)
      client.reviewEventSink (ReviewTurnStarted threadId turnId)
    _ -> client.reviewEventSink (ReviewProtocolWarning "turn/started omitted its thread or turn id")
  "item/agentMessage/delta" -> emitDelta AgentOutput
  "item/commandExecution/outputDelta" -> emitDelta CommandOutput
  "item/reasoning/summaryTextDelta" -> emitDelta ReasoningOutput
  "turn/completed" -> case fieldText "threadId" params of
    Nothing -> client.reviewEventSink (ReviewProtocolWarning "turn/completed omitted its thread id")
    Just threadId -> do
      modifyMVar_ client.reviewActiveTurns (pure . Map.delete threadId)
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
  result <- withReservedToolSlot client threadId (\key -> runAuthenticatedClaude client key request.claudeToolPrompt)
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
  result <- withReservedToolSlot client threadId (\key -> runGitHubIssueTool client key request)
  sent <- case result of
    Left message -> sendDynamicToolFailure client requestId message
    Right output -> sendDynamicToolSuccess client requestId output
  let completion = case (result, sent) of
        (Left message, _) -> Left message
        (_, Left message) -> Left message
        (Right output, Right ()) -> Right output
  client.reviewEventSink (ReviewGitHubFinished threadId completion)

-- | Reserves a registry slot for the *whole* dispatched tool call before
-- doing any work (including the @findExecutable@ lookup and any
-- multi-subprocess sequence within it), and releases it only once the call
-- is completely finished. Reserving here, at the very top of the dispatched
-- call, rather than around each individual subprocess spawn, is what lets a
-- same-thread cancellation land in the gap before the first spawn — or
-- between the sequential subprocesses of one GitHub update — and still find
-- and drain this same reservation, so a later subprocess of an
-- already-cancelled call cannot spawn as if nothing happened.
withReservedToolSlot :: ReviewClient -> Text -> (Int -> IO (Either Text a)) -> IO (Either Text a)
withReservedToolSlot client threadId action = do
  reserved <- reserveToolSlot client.reviewToolRegistry threadId
  case reserved of
    Nothing -> pure (Left "Review client is shutting down")
    Just key -> do
      result <- action key
      releaseToolSlot client.reviewToolRegistry key
      pure result

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

runGitHubIssueTool :: ReviewClient -> Int -> GitHubIssueToolRequest -> IO (Either Text Text)
runGitHubIssueTool client key request = do
  executable <- findExecutable "gh"
  case executable of
    Nothing -> pure (Left "GitHub CLI was not found on PATH")
    Just ghPath -> case request.githubToolOperation of
      GitHubIssueRead -> fmap readOutcome (runGitHubCommand client key ghPath (githubIssueViewArguments client.reviewRepositorySlug request.githubToolIssue) "")
      GitHubIssueUpdate -> runGitHubIssueUpdate client key ghPath request
  where
    -- A read has no side effect to reconcile, so an unobserved read is an
    -- ordinary failure the model may simply reissue -- it must not carry the
    -- verify-current-state-before-retry instruction the mutations below
    -- need, which would only tell the model to redo the read it just failed.
    readOutcome (GitHubCommandSucceeded output) = Right output
    readOutcome (GitHubCommandFailed message) = Left message
    readOutcome (GitHubCommandUnobserved observation) =
      Left (observation <> " while reading issue #" <> Text.pack (show request.githubToolIssue) <> ".")

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

-- | Why one step of a multi-step GitHub update did not complete. The
-- distinction is the whole point of issue #15: a definite failure did not
-- mutate anything, whereas an unobserved step may well have landed, so it
-- must never be described as failed and must always tell the model to check
-- current state before it retries.
data MutationFailure
  = MutationFailed Text
  | MutationUnobserved Text

runGitHubIssueUpdate :: ReviewClient -> Int -> FilePath -> GitHubIssueToolRequest -> IO (Either Text Text)
runGitHubIssueUpdate client key ghPath request = do
  commentResult <- case request.githubToolComment of
    Nothing -> pure (Right Nothing)
    Just comment -> do
      outcome <- runGitHubCommand client key ghPath (githubIssueCommentArguments client.reviewRepositorySlug request.githubToolIssue) comment
      pure $ case mutationOutcome outcome of
        Right commentUrl -> Right (Just (Text.strip commentUrl))
        Left failure -> Left (renderMutationFailure Nothing "posting the issue comment" failure)
  case commentResult of
    Left message -> pure (Left message)
    Right commentUrl -> do
      labelResult <- ensureRevisedLabel client key ghPath request.githubToolAddLabels
      case labelResult of
        Left failure -> pure (Left (renderMutationFailure commentUrl "creating the reviewed:revised label" failure))
        Right () -> do
          edited <- applyReviewLabels client key ghPath request
          pure $ case edited of
            Left failure -> Left (renderMutationFailure commentUrl "updating the issue labels" failure)
            Right _ -> Right (githubUpdateResult commentUrl request)

ensureRevisedLabel :: ReviewClient -> Int -> FilePath -> [Text] -> IO (Either MutationFailure ())
ensureRevisedLabel client key ghPath labels
  | "reviewed:revised" `notElem` labels = pure (Right ())
  | otherwise = fmap (fmap (const ()) . mutationOutcome) (runGitHubCommand client key ghPath (githubLabelCreateArguments client.reviewRepositorySlug) "")

applyReviewLabels :: ReviewClient -> Int -> FilePath -> GitHubIssueToolRequest -> IO (Either MutationFailure Text)
applyReviewLabels client key ghPath request
  | null request.githubToolAddLabels && null request.githubToolRemoveLabels = pure (Right "")
  | otherwise = fmap mutationOutcome (runGitHubCommand client key ghPath (githubIssueEditArguments client.reviewRepositorySlug request) "")

mutationOutcome :: GitHubCommandOutcome -> Either MutationFailure Text
mutationOutcome (GitHubCommandSucceeded output) = Right output
mutationOutcome (GitHubCommandFailed message) = Left (MutationFailed message)
mutationOutcome (GitHubCommandUnobserved observation) = Left (MutationUnobserved observation)

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

-- | The model-facing message for a GitHub update that did not run to
-- completion, keeping whatever is already *known* to have landed (the
-- comment URL) attached so a retry cannot silently repost it.
--
-- A definite failure keeps the existing "…, but <step> failed" wording. An
-- unobserved step deliberately does not: saying it failed would contradict
-- the very thing the message goes on to state, that the mutation may
-- already have completed. Those carry 'githubVerificationRemedy' instead,
-- so the model re-reads the issue through this same tool before deciding
-- whether there is anything left to retry.
renderMutationFailure :: Maybe Text -> Text -> MutationFailure -> Text
renderMutationFailure commentUrl step failure = case (commentUrl, failure) of
  (Nothing, MutationFailed message) -> message
  (Nothing, MutationUnobserved observation) -> unobservedDetail observation
  (Just url, MutationFailed message) ->
    "The issue comment was posted at " <> url <> ", but " <> step <> " failed: " <> message
  (Just url, MutationUnobserved observation) ->
    "The issue comment was posted at " <> url <> ". " <> unobservedDetail observation
  where
    unobservedDetail observation = outcomeUnknownMessage (observation <> " while " <> step) githubVerificationRemedy

-- | The shape shared by every "this side effect may already have landed"
-- diagnostic: what was actually observed, the 'outcomeUnknownMarker' that
-- makes such a result recognisable as distinct from a definite failure, and
-- the instruction for confirming real state before anything is retried.
outcomeUnknownMessage :: Text -> Text -> Text
outcomeUnknownMessage observation remedy = observation <> outcomeUnknownMarker <> " " <> remedy

outcomeUnknownMarker :: Text
outcomeUnknownMarker = ", so its outcome is unknown and it may already have completed."

-- | Whether a review diagnostic describes an unobserved outcome rather than
-- a definite failure, so a caller rendering it (the TUI's canonical-review
-- projection) never tells the operator that something failed when all that
-- actually failed was observing it.
outcomeUnknownDiagnostic :: Text -> Bool
outcomeUnknownDiagnostic = Text.isInfixOf outcomeUnknownMarker

-- | Remedy for the @kanban_github_issue@ paths, whose diagnostics are read
-- by the revision agent through the tool protocol: it holds the very tool
-- that can settle the question, so it is told to use it before retrying.
githubVerificationRemedy :: Text
githubVerificationRemedy =
  "Re-read the issue and its labels with this tool to confirm the current state before retrying anything."

-- | Remedy for the canonical gate, whose results are rendered to the TUI
-- rather than returned to any tool-calling model. It must not mention
-- rereading "with this tool": there is no model on that path to do so.
canonicalVerificationRemedy :: Text
canonicalVerificationRemedy =
  "Check the issue's current comments and labels before running the review again."

-- | Spawns one @gh@ invocation and attaches it to the invocation-wide
-- reservation `key` (see 'withReservedToolSlot'). Regardless of how this
-- process finishes -- naturally (success or its own failure), a broken
-- input pipe, or a timeout -- it is always swept with 'killManagedProcess'
-- before returning: a leader that already exited on its own can still have
-- left a same-group child behind, and this is the one point where every
-- exit path funnels through the same recorded-pgid termination, whether or
-- not this is the last subprocess of a multi-step update.
runGitHubCommand :: ReviewClient -> Int -> FilePath -> [String] -> Text -> IO GitHubCommandOutcome
runGitHubCommand client key ghPath arguments input = do
  started <- try (createProcess processSpec) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
  case started of
    Left exception -> pure (GitHubCommandFailed ("Could not start GitHub CLI: " <> exceptionText exception))
    Right (Just inputHandle, Just outputHandle, Just errorHandle, processHandle) -> do
      (managed, groupLeaderProblem) <- managedProcess processHandle
      mapM_ (\problem -> client.reviewEventSink (ReviewProtocolWarning ("process group leadership: " <> problem))) groupLeaderProblem
      attached <- attachToolProcess client.reviewToolRegistry key managed
      if not attached
        then killManagedProcess managed >> pure (GitHubCommandFailed "Review client is shutting down")
        else do
          outputCapture <- startCapture outputHandle
          errorCapture <- startCapture errorHandle
          written <- try (ByteString.hPutStr inputHandle (TextEncoding.encodeUtf8 input) >> hClose inputHandle) :: IO (Either IOException ())
          result <- case written of
            Left exception -> pure (GitHubCommandFailed ("Could not send input to GitHub CLI: " <> exceptionText exception))
            Right () -> renderGitHubCommandResult bounds <$> awaitCommandOutcome bounds processHandle outputCapture errorCapture
          releaseCapture outputCapture
          releaseCapture errorCapture
          killManagedProcess managed
          pure result
    Right _ -> pure (GitHubCommandFailed "GitHub CLI did not provide all three standard streams")
  where
    bounds = client.reviewCommandBounds
    processSpec =
      (proc ghPath arguments)
        { cwd = Just client.reviewRepositoryRoot,
          std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }

runCanonicalCommand :: CommandBounds -> Repository -> Int -> FilePath -> [String] -> (ManagedProcess -> IO ()) -> IO (Either Text Text)
runCanonicalCommand bounds repository issueNumber executable arguments processStarted = do
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
      outputCapture <- startCapture outputHandle
      errorCapture <- startCapture errorHandle
      completed <- awaitCommandOutcome bounds processHandle outputCapture errorCapture
      releaseCapture outputCapture
      releaseCapture errorCapture
      -- Sweeping the recorded process group is what makes the two giving-up
      -- paths actually bounded: a still-running reviewer, or a descendant
      -- that outlived it still holding a capture pipe, would otherwise be
      -- left behind once this call returns.
      unless (commandRanToCompletion completed) (killManagedProcess managed)
      result <- case completed of
        CommandUnfinished ->
          pure
            ( Left
                ( outcomeUnknownMessage
                    ("The canonical issue review did not exit within " <> renderWindow bounds.commandDeadlineMicros)
                    canonicalVerificationRemedy
                )
            )
        CommandExited exitCode output errors -> case (exitCode, output, errors) of
          (_, StreamUnreadable exception, _) -> pure (Left ("Could not read canonical issue review output: " <> exceptionText exception))
          -- A canonical run that exited cleanly with fully captured output
          -- has always been reported as a success even when its diagnostics
          -- could not be read; only a *failing* exit needs them.
          (ExitSuccess, StreamComplete outputBytes, _) -> do
            logCaptured sessionLog outputBytes (capturedBytes errors)
            pure (Right (decodeClaudeBytes outputBytes))
          -- Exited zero, but a surviving pipe holder kept stdout from ever
          -- reaching EOF: the prefix may look like complete JSON and still
          -- be a truncated verdict, so this is outcome-unknown rather than a
          -- success -- and, crucially, never a timeout.
          (ExitSuccess, StreamTruncated outputBytes, _) -> do
            logCaptured sessionLog outputBytes (capturedBytes errors)
            pure
              ( Left
                  ( outcomeUnknownMessage
                      ("The canonical issue review exited but its output was still incomplete after " <> renderWindow bounds.commandCaptureGraceMicros)
                      canonicalVerificationRemedy
                  )
              )
          (_, _, StreamUnreadable exception) -> pure (Left ("Could not read canonical issue review diagnostics: " <> exceptionText exception))
          (ExitFailure code, _, _) -> do
            logCaptured sessionLog (capturedBytes output) (capturedBytes errors)
            pure (Left ("Canonical issue reviewer exited with status " <> Text.pack (show code) <> renderClaudeFailureDetails (capturedBytes output) (capturedBytes errors)))
      finishLog sessionLog
      pure result
    Right _ -> finishLog sessionLog >> pure (Left "Canonical issue reviewer did not provide stdout and stderr pipes")
  where
    repositoryRoot = repository.repositoryRoot
    finishLog sessionLog = mapM_ (\value -> logMessage value "command-finished" "canonical issue review" >> closeSessionLog value) sessionLog
    logCaptured sessionLog output errors = do
      mapM_ (\value -> mapM_ (logRawLine value "stdout") (ByteString.split '\n' output)) sessionLog
      mapM_ (\value -> mapM_ (logRawLine value "stderr") (ByteString.split '\n' errors)) sessionLog
    processSpec =
      (proc executable arguments)
        { cwd = Just repositoryRoot,
          std_in = NoStream,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }

-- | How one @gh@ invocation actually ended. 'GitHubCommandUnobserved'
-- carries only the neutral *observation* -- what the runner saw -- because
-- the runner alone cannot tell a harmless read from a mutation; the
-- verify-before-retry remedy is chosen by the callers above it.
data GitHubCommandOutcome
  = GitHubCommandSucceeded Text
  | GitHubCommandFailed Text
  | GitHubCommandUnobserved Text

renderGitHubCommandResult :: CommandBounds -> CommandOutcome -> GitHubCommandOutcome
renderGitHubCommandResult bounds outcome = case outcome of
  CommandUnfinished ->
    GitHubCommandUnobserved ("The GitHub CLI did not exit within " <> renderWindow bounds.commandDeadlineMicros)
  CommandExited exitCode output errors -> case (exitCode, output, errors) of
    (_, StreamUnreadable exception, _) -> GitHubCommandFailed ("Could not read GitHub CLI output: " <> exceptionText exception)
    (_, _, StreamUnreadable exception) -> GitHubCommandFailed ("Could not read GitHub CLI diagnostics: " <> exceptionText exception)
    -- An *observed* nonzero exit stays a nonzero-exit failure whatever the
    -- capture did: the command definitely did not do what was asked, so
    -- there is nothing unknown about its outcome.
    (ExitFailure code, _, _) ->
      GitHubCommandFailed
        ( "GitHub CLI exited with status "
            <> Text.pack (show code)
            <> renderClaudeFailureDetails (capturedBytes output) (capturedBytes errors)
        )
    -- Incomplete stdout is unknown even when the captured prefix happens to
    -- parse -- callers read it as a comment URL or a JSON verdict, and a
    -- truncated one of either is worse than no answer. Incomplete *stderr*
    -- alone never invalidates a clean exit with complete stdout.
    (ExitSuccess, StreamTruncated _, _) ->
      GitHubCommandUnobserved ("The GitHub CLI exited but its output was still incomplete after " <> renderWindow bounds.commandCaptureGraceMicros)
    (ExitSuccess, StreamComplete outputBytes, _) -> GitHubCommandSucceeded (decodeClaudeBytes outputBytes)

-- | The result of running one review subprocess under 'CommandBounds':
-- either it exited (with each stream's capture flagged complete, truncated
-- or unreadable *independently*) or it outlived its deadline entirely.
data CommandOutcome
  = CommandExited ExitCode StreamCaptureResult StreamCaptureResult
  | CommandUnfinished

commandRanToCompletion :: CommandOutcome -> Bool
commandRanToCompletion (CommandExited _ StreamComplete {} StreamComplete {}) = True
commandRanToCompletion _ = False

data StreamCaptureResult
  = StreamComplete ByteString.ByteString
  | StreamTruncated ByteString.ByteString
  | StreamUnreadable IOException

capturedBytes :: StreamCaptureResult -> ByteString.ByteString
capturedBytes (StreamComplete bytes) = bytes
capturedBytes (StreamTruncated bytes) = bytes
capturedBytes (StreamUnreadable _) = ByteString.empty

-- | Bounds process exit and output capture *separately*. Once the process
-- has exited within its deadline its status is a fact, so a capture that
-- cannot finish only downgrades that call's *output* -- after a short
-- grace, whatever arrived is returned flagged truncated. This is the whole
-- fix for issue #15: a mutation that demonstrably ran can no longer be
-- reported as having timed out just because a descendant it spawned still
-- holds the pipe open.
--
-- Both graces are awaited under one 'timeout', and with 'readMVar' rather
-- than 'takeMVar', so a stream that did finish is still recognised as
-- complete when the other one is what ran out the clock.
awaitCommandOutcome :: CommandBounds -> ProcessHandle -> StreamCapture -> StreamCapture -> IO CommandOutcome
awaitCommandOutcome bounds processHandle outputCapture errorCapture = do
  exited <- timeout bounds.commandDeadlineMicros (waitForProcess processHandle)
  case exited of
    Nothing -> pure CommandUnfinished
    Just exitCode -> do
      void . timeout bounds.commandCaptureGraceMicros $ do
        void (readMVar outputCapture.streamCaptureDone)
        void (readMVar errorCapture.streamCaptureDone)
      CommandExited exitCode <$> streamCaptureResult outputCapture <*> streamCaptureResult errorCapture

-- | One subprocess stream's capture worker, plus everything needed to give
-- up on it. The bytes accumulate into an 'IORef' that stays readable while
-- the worker is still blocked, and completion is signalled separately --
-- 'ByteString.hGetContents' publishes only at EOF, which never arrives
-- while a descendant that inherited the pipe holds its write end, so a
-- grace period that had to @takeMVar@ the worker's result would hang
-- exactly where it is supposed to give up.
data StreamCapture = StreamCapture
  { streamCaptureChunks :: IORef [ByteString.ByteString],
    streamCaptureDone :: MVar (Either IOException ()),
    streamCaptureThread :: ThreadId,
    streamCaptureHandle :: Handle
  }

startCapture :: Handle -> IO StreamCapture
startCapture handle = do
  chunks <- newIORef []
  done <- newEmptyMVar
  threadId <- forkIO $ do
    outcome <- try (readChunks chunks)
    putMVar done outcome
  pure
    StreamCapture
      { streamCaptureChunks = chunks,
        streamCaptureDone = done,
        streamCaptureThread = threadId,
        streamCaptureHandle = handle
      }
  where
    readChunks chunks = do
      chunk <- ByteString.hGetSome handle captureChunkBytes
      if ByteString.null chunk
        then pure ()
        else atomicModifyIORef' chunks (\previous -> (chunk : previous, ())) >> readChunks chunks

streamCaptureResult :: StreamCapture -> IO StreamCaptureResult
streamCaptureResult capture = do
  finished <- tryReadMVar capture.streamCaptureDone
  captured <- ByteString.concat . reverse <$> readIORef capture.streamCaptureChunks
  pure $ case finished of
    Nothing -> StreamTruncated captured
    Just (Left exception) -> StreamUnreadable exception
    Just (Right ()) -> StreamComplete captured

-- | Retires a capture worker: a finished one only needs its pipe closed,
-- and a still-blocked one is killed first, since nothing else will ever
-- unblock a read on a pipe another process is holding open. Killing before
-- closing matters -- a blocked reader holds the handle's lock, so a close
-- attempted first would block right behind it.
releaseCapture :: StreamCapture -> IO ()
releaseCapture capture = do
  finished <- tryReadMVar capture.streamCaptureDone
  case finished of
    Just _ -> pure ()
    Nothing -> killThread capture.streamCaptureThread
  void (try (hClose capture.streamCaptureHandle) :: IO (Either IOException ()))

-- | Renders a bound for a diagnostic. Sub-second bounds only ever come from
-- tests, but they are rendered honestly rather than rounded to \"0 seconds\".
renderWindow :: Int -> Text
renderWindow micros
  | micros >= 1000000 && micros `mod` 1000000 == 0 = Text.pack (show (micros `div` 1000000)) <> unit (micros `div` 1000000) " second"
  | otherwise = Text.pack (show (micros `div` 1000)) <> " ms"
  where
    unit 1 singular = singular
    unit _ singular = singular <> "s"

-- | Spawns the authenticated Claude CLI and attaches it to the
-- invocation-wide reservation `key` (see 'withReservedToolSlot'). As in
-- 'runGitHubCommand', every exit path -- natural completion, a broken input
-- pipe, or a timeout -- is swept with 'killManagedProcess' before
-- returning, so a leader that already exited on its own can't leave a
-- same-group child unsignalled.
runAuthenticatedClaude :: ReviewClient -> Int -> Text -> IO (Either Text Text)
runAuthenticatedClaude client key prompt = do
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
          attached <- attachToolProcess client.reviewToolRegistry key managed
          if not attached
            then killManagedProcess managed >> pure (Left "Review client is shutting down")
            else do
              outputResult <- newEmptyMVar
              errorResult <- newEmptyMVar
              void . forkIO $ captureHandle outputHandle outputResult
              void . forkIO $ captureHandle errorHandle errorResult
              written <- try (ByteString.hPutStr inputHandle (TextEncoding.encodeUtf8 prompt) >> hClose inputHandle) :: IO (Either IOException ())
              result <- case written of
                Left exception -> pure (Left ("Could not send the reviewer prompt to Claude: " <> exceptionText exception))
                Right () -> do
                  completed <-
                    timeout claudeReviewerTimeoutMicros $ do
                      exitCode <- waitForProcess processHandle
                      output <- takeMVar outputResult
                      errors <- takeMVar errorResult
                      pure (exitCode, output, errors)
                  pure $ case completed of
                    Nothing -> Left "Claude Sonnet 5 revision agent timed out after ten minutes"
                    Just captured -> renderClaudeResult captured
              killManagedProcess managed
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

claudeReviewerTimeoutMicros :: Int
claudeReviewerTimeoutMicros = 10 * 60 * 1000 * 1000

-- | Production bounds for the canonical gate: the same one-hour process
-- deadline as before, now with capture bounded separately behind it.
canonicalCommandBounds :: CommandBounds
canonicalCommandBounds =
  CommandBounds
    { commandDeadlineMicros = 60 * 60 * 1000 * 1000,
      commandCaptureGraceMicros = captureGraceMicros
    }

-- | How much longer than the process itself its output capture may take.
-- Long enough that an ordinary pipe drain always finishes inside it, short
-- enough that a descendant holding the pipe open cannot stall the caller.
captureGraceMicros :: Int
captureGraceMicros = 2 * 1000 * 1000

captureChunkBytes :: Int
captureChunkBytes = 65536

claudePromptLimit :: Int
claudePromptLimit = 100000

claudeDiagnosticLimit :: Int
claudeDiagnosticLimit = 4000

-- | Production bounds for every @gh@ invocation: the same 30-second process
-- deadline as before, with capture bounded separately behind it.
githubCommandBounds :: CommandBounds
githubCommandBounds =
  CommandBounds
    { commandDeadlineMicros = 30 * 1000 * 1000,
      commandCaptureGraceMicros = captureGraceMicros
    }

githubCommentLimit :: Int
githubCommentLimit = 100000
