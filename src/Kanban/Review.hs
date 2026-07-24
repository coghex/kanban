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
    confirmToolProcessTerminatedOrKeepTryingWith,
    killManagedProcessVerifiedOrKeepTryingWith,
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
    killReviewToolsWith,
    newReviewClientForTesting,
    renderCanonicalIssueReviewResult,
    resolveCanonicalIssueReviewer,
    reviewStageForLabels,
    runAuthenticatedClaude,
    runAuthenticatedClaudeWith,
    runCanonicalIssueReview,
    runCanonicalCommandWith,
    runGitHubIssueTool,
    runGitHubIssueUpdateWith,
    sendReviewMessage,
    startReviewClient,
    stopReviewClient,
    renderReviewResult,
  )
where

import Control.Concurrent (MVar, forkIO, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar, threadDelay, withMVar)
import Control.Exception (Exception, IOException, bracket_, displayException, finally, try)
import Control.Monad (forever, unless, void, when)
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
import Kanban.Process (ManagedProcess, ProcessIdentity, forceCensusTick, killCensusVerified, killManagedProcessVerified, managedProcess, watchManagedProcessCensus)
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

-- | A single registered tool process: its owning thread, the process
-- itself, and whether a drain (see 'drainMatchingToolProcesses') has
-- already claimed responsibility for removing it. Once claimed, the
-- invocation's own natural completion must leave the entry in place for
-- the drain to remove -- otherwise a self-deregistration racing a
-- concurrent drain could make the registry look empty before that drain's
-- own kill-and-verify sequence for this same entry has actually finished.
--
-- 'toolEntryProcess' is 'Nothing' from the moment an invocation is
-- reserved (see 'reserveToolInvocation') until the process it will run has
-- actually been spawned and attached (see 'attachToolProcess') -- so a
-- concurrent drain can see and claim the *reservation* itself, before
-- 'createProcess' or 'managedProcess's own @ps@-based check (both of which
-- take real, measurable time) have even run, closing the window where a
-- cancelled thread could otherwise still spawn and run a fresh tool. Once
-- attached, the paired actions are 'watchManagedProcessCensus's peek and
-- stop-and-collect actions for that process: whichever caller ends up
-- killing this entry re-peeks on every retry (see
-- 'confirmToolProcessTerminated') and runs stop-and-collect exactly once,
-- only once actually confirmed terminated, to release the background
-- census watcher.
data ToolEntry = ToolEntry
  { toolEntryThread :: Text,
    toolEntryProcess :: Maybe (ManagedProcess, IO [ProcessIdentity], IO [ProcessIdentity]),
    toolEntryDraining :: Bool
  }

-- | Every review-owned tool process (@kanban_run_claude@, @kanban_github_issue@'s
-- @gh@, and any future dynamic tool) registered under a key unique per
-- invocation rather than per thread, so overlapping invocations on one
-- thread never collide -- retaining the owning thread id alongside each
-- entry lets 'killReviewTools' still terminate every invocation for a
-- thread without touching another thread's entries. Closing the registry
-- (see 'drainToolProcesses') is what makes full-client shutdown atomic with
-- respect to a concurrently spawning invocation: once closed, a
-- registration attempt is rejected and its caller must terminate the
-- process it just spawned itself, rather than let it run on unregistered
-- and outlive the drain. 'toolRegistryCancellingThreads' is the same
-- fencing idea scoped to a single thread's cancellation
-- ('killReviewTools') rather than the whole client's shutdown: while a
-- thread id is a member, a fresh invocation on that thread is refused the
-- same way, so a @kanban_run_claude@/@kanban_github_issue@ call the
-- app-server issues for a thread at the exact moment its turn is cancelled
-- cannot slip through unregistered and outlive the cancel. Unlike the
-- permanent close, membership is temporary -- cleared once that specific
-- 'killReviewTools' call finishes -- so the thread can register normally
-- again for its next turn. Ref-counted, not a bare 'Set' membership flag:
-- two overlapping 'killReviewTools' calls for the same thread (e.g. a
-- steered turn cancelling one still-draining cancellation) can each fence
-- it independently, and the thread must stay fenced until *every* such
-- call has finished draining, not merely the first one to complete --
-- otherwise a fresh invocation could reserve and attach in the gap after
-- the first call clears the fence while the second is still actively
-- cancelling.
data ToolRegistry = ToolRegistry
  { toolRegistryEntries :: Map Int ToolEntry,
    toolRegistryClosed :: Bool,
    toolRegistryCancellingThreads :: Map Text Int
  }

emptyToolRegistry :: ToolRegistry
emptyToolRegistry = ToolRegistry Map.empty False Map.empty

data ReviewClient = ReviewClient
  { reviewInput :: Handle,
    reviewProcess :: ProcessHandle,
    -- | The app-server's own identity, captured at spawn time (see
    -- 'managedProcess') so its process group can still be signalled after
    -- the leader itself has exited and been reaped -- e.g. an unexpected
    -- app-server crash that leaves a spawned child alive.
    reviewProcessManaged :: ManagedProcess,
    -- | 'watchManagedProcessCensus's peek and stop-and-collect actions for
    -- the app-server, consulted (and, once terminated is confirmed,
    -- stopped) at shutdown so 'confirmToolProcessTerminated' has a
    -- provenance-backed witness for the app-server's own descendants too,
    -- not just its own pgid.
    reviewProcessCensusPeek :: IO [ProcessIdentity],
    reviewProcessCensusStop :: IO [ProcessIdentity],
    reviewWriteLock :: MVar (),
    reviewNextRequestId :: IORef Int,
    reviewNextToolInvocationId :: IORef Int,
    reviewPendingRequests :: MVar (Map Int PendingRequest),
    reviewThreadIssues :: MVar (Map Text Int),
    reviewToolProcesses :: MVar ToolRegistry,
    -- | Counts tool invocations currently between a successful
    -- 'reserveToolInvocation' and their own final cleanup (deregister or
    -- 'registerOrphanedToolProcess'), keyed by owning thread, so
    -- 'drainToolProcesses' can wait for every in-flight straggler
    -- client-wide before a whole-client shutdown returns (see
    -- 'awaitNoInFlightInvocations'), and 'killReviewTools' can wait for
    -- just its own thread's stragglers (see
    -- 'awaitNoInFlightInvocationsFor') without blocking on unrelated
    -- threads' work.
    reviewInFlightInvocations :: MVar (Map Text Int),
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
      (processManaged, groupLeaderProblem) <- managedProcess processHandle
      mapM_ (\problem -> eventSink (ReviewProtocolWarning ("app-server process group leadership: " <> problem))) groupLeaderProblem
      (processCensusPeek, _, processCensusStop) <- watchManagedProcessCensus processManaged
      writeLock <- newMVar ()
      requestCounter <- newIORef 2
      toolInvocationCounter <- newIORef 1
      pendingRequests <- newMVar Map.empty
      threadIssues <- newMVar Map.empty
      toolProcesses <- newMVar emptyToolRegistry
      inFlightInvocations <- newMVar Map.empty
      outputDone <- newEmptyMVar
      errorDone <- newEmptyMVar
      let client =
            ReviewClient
              { reviewInput = inputHandle,
                reviewProcess = processHandle,
                reviewProcessManaged = processManaged,
                reviewProcessCensusPeek = processCensusPeek,
                reviewProcessCensusStop = processCensusStop,
                reviewWriteLock = writeLock,
                reviewNextRequestId = requestCounter,
                reviewNextToolInvocationId = toolInvocationCounter,
                reviewPendingRequests = pendingRequests,
                reviewThreadIssues = threadIssues,
                reviewToolProcesses = toolProcesses,
                reviewInFlightInvocations = inFlightInvocations,
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

-- | Builds a 'ReviewClient' for tests, exercising the same tool-process
-- registry, spawn, and shutdown machinery as production without needing a
-- live @codex app-server@ handshake -- which is exercised separately by the
-- Codex app-server protocol tests. The app-server slot itself is filled by a
-- trivial, real, group-leading placeholder process so 'stopReviewClient'
-- and 'reviewProcessManaged' have a genuine process to operate on.
newReviewClientForTesting :: WorkflowConfig -> FilePath -> (ReviewEvent -> IO ()) -> IO ReviewClient
newReviewClientForTesting workflowConfig repositoryRoot eventSink = do
  (Just inputHandle, Just outputHandle, Just errorHandle, processHandle) <-
    createProcess placeholderSpec
  hSetBuffering inputHandle LineBuffering
  void (forkIO (drainHandle outputHandle))
  void (forkIO (drainHandle errorHandle))
  (processManaged, _) <- managedProcess processHandle
  (processCensusPeek, _, processCensusStop) <- watchManagedProcessCensus processManaged
  writeLock <- newMVar ()
  requestCounter <- newIORef 2
  toolInvocationCounter <- newIORef 1
  pendingRequests <- newMVar Map.empty
  threadIssues <- newMVar Map.empty
  toolProcesses <- newMVar emptyToolRegistry
  inFlightInvocations <- newMVar Map.empty
  outputDone <- newEmptyMVar
  errorDone <- newEmptyMVar
  pure
    ReviewClient
      { reviewInput = inputHandle,
        reviewProcess = processHandle,
        reviewProcessManaged = processManaged,
        reviewProcessCensusPeek = processCensusPeek,
        reviewProcessCensusStop = processCensusStop,
        reviewWriteLock = writeLock,
        reviewNextRequestId = requestCounter,
        reviewNextToolInvocationId = toolInvocationCounter,
        reviewPendingRequests = pendingRequests,
        reviewThreadIssues = threadIssues,
        reviewToolProcesses = toolProcesses,
        reviewInFlightInvocations = inFlightInvocations,
        reviewEventSink = eventSink,
        reviewRepositoryRoot = repositoryRoot,
        reviewRepositorySlug = "test/test",
        reviewWorkflowConfig = workflowConfig,
        reviewSessionLog = Nothing,
        reviewOutputDone = outputDone,
        reviewErrorDone = errorDone
      }
  where
    placeholderSpec =
      (proc "sh" ["-c", "trap '' TERM; while :; do sleep 1; done"])
        { cwd = Just repositoryRoot,
          std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }
    drainHandle handle = do
      result <- try (ByteString.hGetContents handle) :: IO (Either IOException ByteString.ByteString)
      either (const (pure ())) (const (pure ())) result

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

-- | Marks an invocation 'reserveToolInvocation' has already counted as
-- in-flight for `threadId` (see there for why the count is incremented
-- atomically with the reservation itself, not here) as finished once
-- `action` completes, however it completes -- covering every exit path
-- (deregister, 'registerOrphanedToolProcess', or an early-return failure)
-- with one wrapper around the whole invocation body.
releaseInFlightInvocation :: ReviewClient -> Text -> IO a -> IO a
releaseInFlightInvocation client threadId action =
  action `finally` modifyMVar_ client.reviewInFlightInvocations (pure . Map.update releaseCount threadId)
  where
    releaseCount count
      | count <= 1 = Nothing
      | otherwise = Just (count - 1)

-- | Blocks, with no attempt limit, until every invocation
-- 'reserveToolInvocation' counted as in-flight -- for *any* thread -- has
-- finished its own cleanup (see 'releaseInFlightInvocation'). Shutdown
-- must retain ownership of a straggler until it is genuinely done, not
-- merely until some fixed budget elapses: giving up early and returning
-- would let 'stopReviewClient' report itself finished while a spawned
-- process (and its census watcher) is still only reachable through that
-- straggler's own in-progress best-effort cleanup, with no other drain
-- ever coming back for it. This is safe to block on unboundedly because
-- every code path that increments a thread's count is paired, via
-- 'releaseInFlightInvocation's 'finally', with exactly one decrement --
-- every count is therefore guaranteed to reach zero once every
-- already-bounded cleanup path (createProcess, the tool's own capped
-- timeout, 'killManagedProcessVerified's bounded retries,
-- 'Kanban.Review.confirmToolProcessTerminated's bounded retries)
-- finishes, however long that takes. Must only be called once new
-- registrations are already refused client-wide (i.e. after the registry
-- has been closed), so no count can ever be replenished by a fresh
-- invocation racing in underneath.
awaitNoInFlightInvocations :: ReviewClient -> IO ()
awaitNoInFlightInvocations client = go
  where
    go = do
      counts <- readMVar client.reviewInFlightInvocations
      when (not (Map.null counts)) (threadDelay inFlightPollMicros >> go)

-- | As 'awaitNoInFlightInvocations', but scoped to a single thread's own
-- in-flight count -- used by 'killReviewTools' so cancelling one thread's
-- turn does not block on unrelated threads' entirely unrelated in-flight
-- work. Must only be called while `threadId` is already fenced against new
-- registrations (see 'toolRegistryCancellingThreads'), so its count can
-- only ever count down to zero for the duration of this wait, never be
-- replenished underneath it.
awaitNoInFlightInvocationsFor :: ReviewClient -> Text -> IO ()
awaitNoInFlightInvocationsFor client threadId = go
  where
    go = do
      counts <- readMVar client.reviewInFlightInvocations
      when (Map.member threadId counts) (threadDelay inFlightPollMicros >> go)

-- | Holds `threadId`'s in-flight count up for the duration of `action`,
-- without touching the tool registry at all -- unlike
-- 'reserveToolInvocation'/'releaseInFlightInvocation', which are paired
-- around a single spawned process. Exists for a caller whose own single
-- logical operation spans multiple, sequential 'runGitHubCommand'
-- invocations (see 'runGitHubIssueUpdate'): wrapping the whole operation
-- keeps this thread's in-flight count above zero for its *entire*
-- duration, including the gaps between each individual sub-invocation
-- where no process is registered at all. Without this, a cancellation
-- landing in one of those gaps would see this thread's count already at
-- zero, finish immediately, and release its thread fence (see
-- 'withThreadFenced') before the next sub-invocation ever reserves --
-- letting that next @gh@ spawn escape cancellation entirely, even though
-- the overall tool call it belongs to was never actually cancelled. The
-- ref-counted map composes correctly with the per-sub-invocation holds
-- 'reserveToolInvocation'/'releaseInFlightInvocation' already take: this
-- is simply one more concurrent holder of the same count, never
-- confused with the others.
withThreadInFlightHeld :: ReviewClient -> Text -> IO a -> IO a
withThreadInFlightHeld client threadId =
  bracket_
    (modifyMVar_ client.reviewInFlightInvocations (pure . Map.insertWith (+) threadId 1))
    (modifyMVar_ client.reviewInFlightInvocations (pure . Map.update releaseCount threadId))
  where
    releaseCount count
      | count <= 1 = Nothing
      | otherwise = Just (count - 1)

-- | Reserves a slot for a tool invocation about to be spawned, *before* any
-- process exists -- so a concurrent drain (below) can see and cancel it
-- even before 'createProcess' or 'managedProcess's own @ps@-based check
-- (both of which take real, measurable time) have run. Returns 'Nothing'
-- once the registry has been closed by 'drainToolProcesses' (full-client
-- shutdown already underway) or while this thread is being cancelled by
-- 'killReviewTools' (its cancellation is still in flight): the caller must
-- not spawn a process at all in that case.
--
-- An accepted reservation increments 'reviewInFlightInvocations' in the
-- very same 'reviewToolProcesses' transaction that inserts it into the
-- registry, not as a separate step afterward: a gap between "reservation
-- visible in the registry" and "counted as in-flight" would let a
-- concurrent 'drainToolProcesses' claim and drop the reservation (correctly
-- finding nothing to kill yet) and then observe an in-flight count of zero
-- and return, before this invocation ever got a chance to increment it
-- itself -- leaving a straggler that later registers an unresolved orphan
-- with no shutdown drain left to ever reach it. Since both this and every
-- concurrent drain's own close-and-claim step contend for the same
-- 'reviewToolProcesses' lock, nesting the increment inside this
-- transaction guarantees it is visible before any drain that could
-- possibly claim this same reservation ever runs.
reserveToolInvocation :: ReviewClient -> Text -> IO (Maybe Int)
reserveToolInvocation client threadId = do
  invocationId <- atomicModifyIORef' client.reviewNextToolInvocationId (\current -> (current + 1, current))
  accepted <- modifyMVar client.reviewToolProcesses $ \registry ->
    if registry.toolRegistryClosed || Map.member threadId registry.toolRegistryCancellingThreads
      then pure (registry, False)
      else do
        modifyMVar_ client.reviewInFlightInvocations (pure . Map.insertWith (+) threadId 1)
        pure (registry {toolRegistryEntries = Map.insert invocationId (ToolEntry threadId Nothing False) registry.toolRegistryEntries}, True)
  pure (if accepted then Just invocationId else Nothing)

-- | Attaches a now-spawned process (and its census watcher's peek and
-- stop-and-collect actions -- see 'watchManagedProcessCensus') to a
-- reservation made by 'reserveToolInvocation'. Returns 'False' if that
-- reservation is gone or already claimed by a concurrent drain (cancelled
-- while still unspawned): the caller must then stop the census watcher and
-- terminate the process it just spawned itself, since the registry no
-- longer -- or does not yet safely -- own that slot.
attachToolProcess :: ReviewClient -> Int -> ManagedProcess -> IO [ProcessIdentity] -> IO [ProcessIdentity] -> IO Bool
attachToolProcess client invocationId managed peekCensus stopCensus =
  modifyMVar client.reviewToolProcesses $ \registry ->
    case Map.lookup invocationId registry.toolRegistryEntries of
      Just entry | not entry.toolEntryDraining ->
        pure (registry {toolRegistryEntries = Map.insert invocationId (entry {toolEntryProcess = Just (managed, peekCensus, stopCensus)}) registry.toolRegistryEntries}, True)
      _ -> pure (registry, False)

-- | Registers an already-running process directly as a claimed (draining)
-- entry, bypassing the normal reserve/attach handshake -- used when
-- 'attachToolProcess' above fails (the reservation was already claimed by
-- a concurrent drain, which -- correctly, at the time -- found nothing yet
-- to kill for it and dropped it as trivially confirmed) *and* this
-- caller's own best-effort 'confirmToolProcessTerminated' attempt could
-- not confirm the process it just spawned is gone. Without this, that
-- process (and its census watcher) would have no registry entry left
-- anywhere: the concurrent drain that would otherwise have owned it has
-- already finished, so nothing would ever retry killing it. Registering it
-- here, still marked draining, leaves it for the next whole-registry drain
-- (see 'drainToolProcesses', run at client shutdown) to retry and confirm.
registerOrphanedToolProcess :: ReviewClient -> Text -> ManagedProcess -> IO [ProcessIdentity] -> IO [ProcessIdentity] -> IO ()
registerOrphanedToolProcess client threadId managed peekCensus stopCensus = do
  invocationId <- atomicModifyIORef' client.reviewNextToolInvocationId (\current -> (current + 1, current))
  modifyMVar_ client.reviewToolProcesses $ \registry ->
    pure
      registry
        { toolRegistryEntries =
            Map.insert invocationId (ToolEntry threadId (Just (managed, peekCensus, stopCensus)) True) registry.toolRegistryEntries
        }

-- | Removes exactly the entry a single invocation created, once that
-- invocation has confirmed its own process terminated (see
-- 'confirmToolProcessTerminated'), or once it releases a reservation that
-- never made it as far as spawning a process (the executable could not be
-- found, or 'createProcess' itself failed). If a concurrent drain has
-- already claimed this entry (marked it draining -- see
-- 'drainMatchingToolProcesses'), this leaves it in place instead: only the
-- owning drain may remove an entry it has claimed, once its own
-- kill-and-verify sequence for that entry has finished, so the registry
-- never looks empty while a drain's termination of it is still in flight.
deregisterToolProcess :: ReviewClient -> Int -> IO ()
deregisterToolProcess client invocationId =
  modifyMVar_ client.reviewToolProcesses $ \registry ->
    pure registry {toolRegistryEntries = Map.update dropUnlessDraining invocationId registry.toolRegistryEntries}
  where
    dropUnlessDraining entry
      | entry.toolEntryDraining = Just entry
      | otherwise = Nothing

-- | Cancels every currently registered invocation for `threadId` -- e.g. the
-- user interrupting a review turn, or a steered turn superseding a running
-- one. Fences that thread for the duration of this call (see
-- 'toolRegistryCancellingThreads'), so a @kanban_run_claude@/
-- @kanban_github_issue@ call the app-server issues for this exact thread at
-- essentially the same instant is refused and self-killed by
-- 'reserveToolInvocation' rather than slipping through unregistered and
-- outliving the cancel. The fence is cleared once this call finishes,
-- whether or not anything actually needed killing, so the thread accepts
-- registrations normally again for its next turn.
killReviewTools :: ReviewClient -> Text -> IO ()
killReviewTools = killReviewToolsWith (pure ())

-- | Fences `threadId` against new registrations (see
-- 'toolRegistryCancellingThreads') for the duration of `action`, releasing
-- the fence again once `action` returns or throws -- regardless of which.
-- 'killReviewToolsWith' holds this for its *entire* body, not just its
-- first claim step, so the fence stays active across the wait for that
-- thread's own in-flight stragglers and the second drain that reaches any
-- orphan entry they left behind (see 'drainToolProcesses' for the same
-- two-phase shape at whole-client shutdown). Nested/overlapping fences of
-- the same thread compose correctly: the ref-counted map only drops the
-- entry once every holder has released it.
withThreadFenced :: ReviewClient -> Text -> IO a -> IO a
withThreadFenced client threadId =
  bracket_
    (modifyMVar_ client.reviewToolProcesses (\registry -> pure registry {toolRegistryCancellingThreads = Map.insertWith (+) threadId 1 registry.toolRegistryCancellingThreads}))
    (modifyMVar_ client.reviewToolProcesses (\registry -> pure registry {toolRegistryCancellingThreads = Map.update releaseFence threadId registry.toolRegistryCancellingThreads}))
  where
    releaseFence count
      | count <= 1 = Nothing
      | otherwise = Just (count - 1)

-- | As 'killReviewTools', but runs `afterClaim` right after this call's own
-- first claim step (see 'drainMatchingToolProcessesWith') and just before
-- it starts confirming anything -- exposed so tests can pause one of two
-- overlapping cancellations for the same thread right at that point, to
-- deterministically prove the fence stays active until *every* concurrent
-- fencer has released it (see 'ToolRegistry'), not just the first to
-- finish. Production code always calls this with @pure ()@.
--
-- Two-phase, mirroring 'drainToolProcesses': the first drain only ever
-- sees invocations that had already reached 'attachToolProcess' (or a
-- reservation that never got that far) by the time this call's fence took
-- effect. A straggler still between 'reserveToolInvocation' and its own
-- spawn completing is invisible to it -- its reservation is claimed and
-- dropped as (at the time) trivially confirmed, since 'toolEntryProcess'
-- is still 'Nothing' -- and only surfaces, if its own best-effort
-- 'confirmToolProcessTerminated' attempt fails, via
-- 'registerOrphanedToolProcess' sometime *after* this first drain has
-- already returned. Waiting for just `threadId`'s own in-flight stragglers
-- (see 'awaitNoInFlightInvocationsFor', called only once the fence is
-- already active so its count can only fall) and draining a second time is
-- what actually reaches any orphan-registered entry those stragglers left
-- behind, rather than leaving a cancelled tool unowned and live until some
-- unrelated later cancellation or client shutdown happens to sweep it up.
-- The fence itself is held by 'withThreadFenced' across both drains and
-- the wait between them, so neither inner drain needs to fence again.
killReviewToolsWith :: IO () -> ReviewClient -> Text -> IO ()
killReviewToolsWith afterClaim client threadId =
  withThreadFenced client threadId $ do
    drainMatchingToolProcessesWith afterClaim client (DrainOptions {drainCloseRegistry = False, drainFenceThread = Nothing}) matchesThread
    awaitNoInFlightInvocationsFor client threadId
    drainMatchingToolProcessesWith (pure ()) client (DrainOptions {drainCloseRegistry = False, drainFenceThread = Nothing}) matchesThread
  where
    matchesThread = (== threadId) . toolEntryThread

data DrainOptions = DrainOptions
  { drainCloseRegistry :: Bool,
    drainFenceThread :: Maybe Text
  }

-- | Kills every currently registered process matching `matches`, claiming
-- each matched entry (marking it draining, so a concurrent
-- 'deregisterToolProcess' from the invocation's own natural completion
-- leaves it for this drain to remove) in the same atomic step that reads
-- it -- and, in that exact same step, closes the registry
-- ('drainCloseRegistry') and/or fences a specific thread
-- ('drainFenceThread') against new registrations, so a 'reserveToolInvocation'
-- racing this call either lands its entry here (and gets killed below, or
-- trivially confirmed if still unspawned -- see below) or is rejected
-- outright: no spawn can escape unregistered and unkilled in the gap
-- between reading and fencing/closing. Each claimed entry is retained
-- until 'confirmToolProcessTerminated' actually confirms it terminated --
-- an entry it cannot confirm is left registered (still draining) rather
-- than dropped, so a later drain still owns and retries it, instead of a
-- concurrent shutdown or probe ever observing the registry as empty while
-- a described OS process remains unconfirmed. A still-unspawned
-- (reserved) entry has nothing to kill yet: it is trivially treated as
-- confirmed and removed here, so 'attachToolProcess' later finds it gone
-- and self-kills whatever it just spawned instead. A fenced thread's
-- reference count is always released again before returning, regardless
-- of outcome, so a per-thread cancel never permanently blocks that
-- thread's future turns -- but only once *every* concurrent fencer of
-- that thread has done the same (see 'ToolRegistry'), not merely this
-- call.
drainMatchingToolProcesses :: ReviewClient -> DrainOptions -> (ToolEntry -> Bool) -> IO ()
drainMatchingToolProcesses = drainMatchingToolProcessesWith (pure ())

-- | As 'drainMatchingToolProcesses', but runs `afterClaim` right after the
-- claim-and-fence step, before confirming anything -- see 'killReviewToolsWith'.
drainMatchingToolProcessesWith :: IO () -> ReviewClient -> DrainOptions -> (ToolEntry -> Bool) -> IO ()
drainMatchingToolProcessesWith afterClaim client options matches = do
  owned <- modifyMVar client.reviewToolProcesses $ \registry ->
    let matching = Map.filter matches registry.toolRegistryEntries
        claimed = Map.map (\entry -> entry {toolEntryDraining = True}) matching
        cancelling = maybe registry.toolRegistryCancellingThreads (\t -> Map.insertWith (+) t 1 registry.toolRegistryCancellingThreads) options.drainFenceThread
     in pure
          ( registry
              { toolRegistryEntries = Map.union claimed registry.toolRegistryEntries,
                toolRegistryClosed = registry.toolRegistryClosed || options.drainCloseRegistry,
                toolRegistryCancellingThreads = cancelling
              },
            matching
          )
  afterClaim
  confirmed <- mapM (confirmEntry client . toolEntryProcess) owned
  modifyMVar_ client.reviewToolProcesses $ \registry ->
    pure
      registry
        { toolRegistryEntries = Map.difference registry.toolRegistryEntries (Map.filter id confirmed),
          toolRegistryCancellingThreads = maybe registry.toolRegistryCancellingThreads (\t -> Map.update releaseFence t registry.toolRegistryCancellingThreads) options.drainFenceThread
        }
  where
    releaseFence count
      | count <= 1 = Nothing
      | otherwise = Just (count - 1)
    confirmEntry _ Nothing = pure True
    confirmEntry theClient (Just (managed, peekCensus, stopCensus)) =
      confirmToolProcessTerminated theClient managed peekCensus stopCensus

-- | Atomically closes the registry to new registrations and drains every
-- currently registered process (see 'drainMatchingToolProcesses'). Safe to
-- call more than once (e.g. once from 'stopReviewClient' and again from
-- 'watchServerProcess'): closing an already-closed, already-empty registry
-- is a no-op.
--
-- Two-phase: the first drain only ever sees invocations that had already
-- reached 'attachToolProcess' (or a reservation that never got that far).
-- A straggler still between 'reserveToolInvocation' and its own spawn
-- completing is invisible to it -- its reservation is claimed and dropped
-- here as (at the time) trivially confirmed, since 'toolEntryProcess' is
-- still 'Nothing' -- and only surfaces, if its own best-effort
-- 'confirmToolProcessTerminated' attempt fails, via
-- 'registerOrphanedToolProcess' sometime *after* this first drain has
-- already returned. Waiting for every such straggler to finish (see
-- 'awaitNoInFlightInvocations', called only once the registry is already
-- closed so the in-flight count can only fall) and draining a second time
-- is what actually reaches any orphan-registered entry those stragglers
-- left behind, rather than leaving it, and the process and census watcher
-- it names, unowned once this returns.
--
-- Both drain passes are still bounded (each entry's own
-- 'confirmToolProcessTerminated' attempt is capped at
-- 'confirmAttempts'), and can therefore return with entries still
-- registered (marked draining, never removed -- see
-- 'drainMatchingToolProcessesWith'): a leader whose census could never
-- establish continuity (the documented residual gap in
-- 'Kanban.Process.startEmbeddedCensusWith') stays genuinely unconfirmable
-- no matter how many *bounded* attempts run. Rather than returning with
-- those entries permanently unowned once this function's own two passes
-- are spent, a detached background thread keeps retrying the exact same
-- drain, unboundedly, until the registry is finally empty -- an active
-- cleanup owner for as long as anything remains, not a one-shot best
-- effort. This does not block the caller (a quitting client should not
-- hang indefinitely on a single unconfirmable straggler), but it does
-- mean the process and its census watcher are never simply abandoned:
-- either the background retries eventually succeed (the watcher's own
-- ongoing ticks can still catch a survivor a bounded attempt missed), or
-- they keep trying for as long as this client -- and the Haskell RTS
-- backing it -- is alive at all.
drainToolProcesses :: ReviewClient -> IO ()
drainToolProcesses = drainToolProcessesWith (threadDelay backgroundCleanupRetryDelayMicros)

-- | As 'drainToolProcesses', but with the background cleanup owner's own
-- retry-to-retry wait injectable -- e.g. to deterministically prove it
-- eventually reaches an entry a bounded attempt could not, without a test
-- actually waiting out 'backgroundCleanupRetryDelayMicros'.
drainToolProcessesWith :: IO () -> ReviewClient -> IO ()
drainToolProcessesWith backgroundRetryDelay client = do
  close
  awaitNoInFlightInvocations client
  close
  stillOwned <- registryNonEmpty
  when stillOwned (void (forkIO keepDraining))
  where
    close = drainMatchingToolProcesses client (DrainOptions {drainCloseRegistry = True, drainFenceThread = Nothing}) (const True)
    registryNonEmpty = not . Map.null . toolRegistryEntries <$> readMVar client.reviewToolProcesses
    keepDraining = do
      backgroundRetryDelay
      close
      stillOwned <- registryNonEmpty
      when stillOwned keepDraining

-- | Kills `managed` and confirms, via 'killCensusVerified', that its
-- recorded process group is now empty -- retrying the kill escalation a
-- bounded number of times if a fresh check still shows survivors, no
-- continuity can yet be established, or a snapshot itself fails.
-- `peekCensus` (see 'watchManagedProcessCensus') is re-read on every
-- attempt, not collected once up front: the watcher keeps ticking between
-- retries, so a survivor it had not yet witnessed on the first attempt can
-- still be picked up and trusted by a later one, rather than this being
-- permanently stuck with whatever the census happened to contain at the
-- very first call. A retry pauses for 'confirmRetryDelayMicros' first --
-- long enough for at least one more watcher tick to land -- since without
-- that pause every attempt would just re-peek the exact same
-- not-yet-updated census and never actually gain anything from retrying at
-- all.
--
-- Reports the outcome rather than discarding it: callers must not
-- deregister/remove an invocation whose termination could not be
-- confirmed, since that would drop registry ownership of a group that may
-- still hold a live member. `stopCensus` is only ever run once termination
-- is actually confirmed, releasing the background watcher at that point;
-- on give-up, the watcher is deliberately left running so a later retry of
-- the very same entry still has live, continuously-recorded evidence to
-- consult rather than a frozen, stale reading. A problem serious enough to
-- exhaust every retry is also surfaced as a protocol warning, so it is at
-- least visible rather than silently swallowed.
confirmToolProcessTerminated :: ReviewClient -> ManagedProcess -> IO [ProcessIdentity] -> IO [ProcessIdentity] -> IO Bool
confirmToolProcessTerminated client managed peekCensus stopCensus = go confirmAttempts
  where
    confirmAttempts = 3 :: Int
    go attemptsLeft
      | attemptsLeft <= 0 = do
          client.reviewEventSink (ReviewProtocolWarning "could not confirm a review tool process group fully terminated after repeated attempts")
          pure False
      | otherwise = do
          confirmed <- killCensusVerified managed peekCensus
          if confirmed
            then void stopCensus >> pure True
            else do
              threadDelay confirmRetryDelayMicros
              go (attemptsLeft - 1)

-- | As 'confirmToolProcessTerminated', but a bounded failure to confirm
-- does not end this function's own ownership of `managed`: it is surfaced
-- immediately (this function's caller still gets the same 'Bool' result,
-- promptly, so it is never blocked on an unconfirmable straggler), and a
-- detached background thread then keeps retrying, unboundedly, until
-- termination is finally confirmed -- the same active-cleanup-owner
-- pattern 'drainToolProcesses' uses for the tool registry, applied here to
-- a single directly-managed process (namely the app-server itself).
confirmToolProcessTerminatedOrKeepTrying :: ReviewClient -> ManagedProcess -> IO [ProcessIdentity] -> IO [ProcessIdentity] -> IO Bool
confirmToolProcessTerminatedOrKeepTrying = confirmToolProcessTerminatedOrKeepTryingWith (threadDelay backgroundCleanupRetryDelayMicros)

-- | As 'confirmToolProcessTerminatedOrKeepTrying', but with the background
-- cleanup owner's own retry-to-retry wait injectable -- e.g. to
-- deterministically prove it eventually confirms termination once
-- whatever blocked a bounded attempt is resolved, without a test actually
-- waiting out 'backgroundCleanupRetryDelayMicros'.
confirmToolProcessTerminatedOrKeepTryingWith :: IO () -> ReviewClient -> ManagedProcess -> IO [ProcessIdentity] -> IO [ProcessIdentity] -> IO Bool
confirmToolProcessTerminatedOrKeepTryingWith backgroundRetryDelay client managed peekCensus stopCensus = do
  confirmed <- confirmToolProcessTerminated client managed peekCensus stopCensus
  unless confirmed (void (forkIO keepTrying))
  pure confirmed
  where
    keepTrying = do
      backgroundRetryDelay
      confirmed <- confirmToolProcessTerminated client managed peekCensus stopCensus
      unless confirmed keepTrying

-- | Quitting terminates the owned app-server process (DESIGN.md §7): drains
-- every registered tool process first, then the app-server itself, both via
-- 'confirmToolProcessTerminatedOrKeepTrying' so a leader already exited and
-- reaped still has its recorded process group signalled and confirmed
-- rather than silently skipped.
--
-- Neither this call's own confirmation nor 'drainToolProcesses's registry
-- drain is ever allowed to simply abandon a process it cannot immediately
-- confirm gone (see both for why a bounded attempt genuinely can fail: a
-- confirmed leader whose entire census seed vanished before any tick
-- could ever witness it -- see 'Kanban.Process.startEmbeddedCensusWith'
-- -- can leave termination truly, if rarely, unconfirmable within any
-- fixed number of attempts). A bounded failure here is still surfaced
-- immediately, as its own distinctly worded protocol warning (in addition
-- to 'confirmToolProcessTerminated's own generic one) and recorded in the
-- session log, so a quit that could not *immediately* confirm cleanup is
-- discoverable right away rather than looking identical to a clean one --
-- but this function itself still returns promptly either way, since a
-- quitting client must not hang indefinitely on a single unconfirmed
-- straggler. What changes from a purely bounded attempt is that nothing
-- is ever left permanently unowned once this function returns: a
-- background thread keeps retrying every unconfirmed piece until it
-- finally succeeds, for as long as this client is alive at all.
--
-- Confirming the app-server's process *group* empty (via
-- 'confirmToolProcessTerminatedOrKeepTrying', which only ever signals and
-- re-checks via @ps@) is not the same as this program having reaped
-- 'reviewProcess' itself: a process that has genuinely exited but never
-- been collected via a successful @waitpid@ is already invisible to
-- every @ps@-based check in this codebase (see
-- 'Kanban.Process.isZombieStat'), so the group can read confirmed-empty
-- while 'reviewProcess' still sits as an unreaped zombie in the OS
-- process table. Nothing else is guaranteed to ever reap it on this
-- specific path: 'watchServerProcess' is the only thing that otherwise
-- calls @waitForProcess@ on this exact handle, and it is only ever
-- started once app-server initialization has already *succeeded@ -- a
-- 'stopReviewClient' called on an initialization timeout or failure (see
-- 'startReviewClient'), or on a test-only client from
-- 'newReviewClientForTesting', runs with no such watcher ever having
-- started at all. A detached background thread blocking on
-- 'waitForProcess' here guarantees this program eventually reaps
-- 'reviewProcess' regardless -- safe to run alongside a concurrently
-- already-running 'watchServerProcess' on the normal quit path, since the
-- @process@ library documents @waitForProcess@ as safe to call for the
-- same process from multiple threads at once.
--
-- 'forceCensusTick' runs immediately before that reaper thread's own
-- 'waitForProcess' call, for exactly the same reason it runs before every
-- other real reap of a managed leader's handle in this module (see
-- 'watchServerProcess', 'runGitHubCommand', 'runCanonicalCommandWith',
-- 'runAuthenticatedClaudeWith'): without it, a same-group child forked
-- after the census's last observation, with the leader then reaped by
-- *this exact reaper thread* before the background watcher's next
-- scheduled tick, would never be witnessed while
-- 'Kanban.Process.managedProcessHandleStillOpen' could still vouch for
-- it -- permanently losing the not-yet-reaped proof for it, with no
-- amount of background retrying in 'confirmToolProcessTerminatedOrKeepTrying'
-- ever able to recover a child that was never recorded in the first
-- place.
stopReviewClient :: ReviewClient -> IO ()
stopReviewClient client = do
  void (forkIO (forceCensusTick client.reviewProcessManaged >> void (waitForProcess client.reviewProcess)))
  drainToolProcesses client
  confirmed <- confirmToolProcessTerminatedOrKeepTrying client client.reviewProcessManaged client.reviewProcessCensusPeek client.reviewProcessCensusStop
  unless confirmed $ do
    client.reviewEventSink (ReviewProtocolWarning "review client stopped without confirming the app-server's own process group fully terminated")
    mapM_ (\sessionLog -> logMessage sessionLog "stop-unconfirmed" "app-server process group termination could not be confirmed") client.reviewSessionLog
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

-- | The app-server exiting, however it happened, is the same "no longer
-- owned" event as a deliberate quit: 'drainToolProcesses' and
-- 'confirmToolProcessTerminatedOrKeepTrying' here guarantee every
-- review-owned tool process (and the app-server's own surviving group
-- members, if the leader itself crashed and was reaped before this ran)
-- are cleaned up as soon as the
-- process is confirmed gone -- not only when 'stopReviewClient' later runs,
-- which an unexpected crash means may never happen (the UI drops its
-- 'ReviewClient' reference once it observes 'ReviewClientStopped'). This
-- must run *before* awaiting the output/error readers: a surviving group
-- member normally inherits the app-server's stdout/stderr pipes, so the
-- readers only see EOF once every holder of those pipes -- including that
-- survivor -- is gone. Waiting on the readers first would deadlock exactly
-- the crash this cleanup exists to catch.
--
-- 'confirmToolProcessTerminatedOrKeepTrying' can still, despite that
-- ordering, fail to *immediately* confirm every survivor gone (its own
-- bounded attempt's retries are limited -- see 'stopReviewClient' for why
-- raising that bound is not always safe -- though a background thread
-- keeps retrying afterward). A survivor that outlives the bounded attempt
-- keeps holding the app-server's stdout/stderr pipes open, so waiting on
-- the readers is bounded by 'pipeReaderShutdownTimeoutMicros' rather than
-- unboundedly: this function runs on its own thread and its completion is
-- what the rest of the app (the UI's 'ReviewClientStopped' handler, this
-- session's log) is waiting on, so hanging here would hang the entire
-- client shutdown, not merely leave one already-known survivor
-- unconfirmed. A timeout is reported as its own distinct protocol warning
-- rather than silently proceeding as if the readers cleanly reached EOF.
--
-- 'forceCensusTick' runs immediately before 'waitForProcess' reaps the
-- app-server's own leader handle: the census's own background watcher
-- only ticks every 'Kanban.Process.censusIntervalMicros' in steady state,
-- and a child forked (with the leader then reaped by *this exact call*)
-- entirely within that gap would otherwise never be witnessed while
-- 'Kanban.Process.managedProcessHandleStillOpen' could still vouch for
-- it -- permanently losing the not-yet-reaped proof for it, with no
-- background retry ever able to recover what was never recorded in the
-- first place. Forcing one last, synchronous observation right before
-- the reap closes that gap down to the same back-to-back-syscalls window
-- the embedded census's own initial synchronous tick already achieves.
watchServerProcess :: ReviewClient -> IO ()
watchServerProcess client = do
  forceCensusTick client.reviewProcessManaged
  exitCode <- waitForProcess client.reviewProcess
  drainToolProcesses client
  confirmed <- confirmToolProcessTerminatedOrKeepTrying client client.reviewProcessManaged client.reviewProcessCensusPeek client.reviewProcessCensusStop
  unless confirmed $
    client.reviewEventSink (ReviewProtocolWarning "app-server process group termination could not be confirmed after it exited")
  readersDone <- timeout pipeReaderShutdownTimeoutMicros (takeMVar client.reviewOutputDone >> takeMVar client.reviewErrorDone)
  case readersDone of
    Just () -> pure ()
    Nothing -> do
      client.reviewEventSink (ReviewProtocolWarning "gave up waiting for the app-server's output/error readers to reach EOF -- a surviving process may still hold its pipes open")
      mapM_ (\sessionLog -> logMessage sessionLog "stop-unconfirmed" "output/error readers never reached EOF") client.reviewSessionLog
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
  result <- runGitHubIssueTool client threadId request
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

runGitHubIssueTool :: ReviewClient -> Text -> GitHubIssueToolRequest -> IO (Either Text Text)
runGitHubIssueTool client threadId request = do
  executable <- findExecutable "gh"
  case executable of
    Nothing -> pure (Left "GitHub CLI was not found on PATH")
    Just ghPath -> case request.githubToolOperation of
      GitHubIssueRead -> runGitHubCommand client threadId ghPath (githubIssueViewArguments client.reviewRepositorySlug request.githubToolIssue) ""
      GitHubIssueUpdate -> runGitHubIssueUpdate client threadId ghPath request

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

-- | As 'runGitHubIssueUpdate', but runs `afterComment` right after the
-- comment sub-invocation (if any) completes and just before the label
-- sub-invocations begin -- exposed so a test can pause deterministically
-- in exactly the gap a same-thread cancellation landing there must not
-- let escape (see 'withThreadInFlightHeld'), rather than racing real
-- process/scheduler timing to land it. Production code always calls this
-- with @pure ()@.
runGitHubIssueUpdate :: ReviewClient -> Text -> FilePath -> GitHubIssueToolRequest -> IO (Either Text Text)
runGitHubIssueUpdate = runGitHubIssueUpdateWith (pure ())

-- | Posts a comment (if requested) and then applies label changes, as up
-- to three entirely separate, sequential @gh@ invocations
-- ('runGitHubCommand', 'ensureRevisedLabel', 'applyReviewLabels') -- each
-- independently reserved and released around its own single process, with
-- nothing registered in between them at all. 'withThreadInFlightHeld'
-- wraps this whole sequence so a cancellation ('killReviewTools') that
-- lands in one of those gaps still waits for -- and stays fenced against
-- new registrations for -- the *entire* multi-step update, not just
-- whichever single @gh@ call happens to be running (or between calls)
-- when it starts; see there for why a per-sub-invocation-only accounting
-- would let a later step spawn after cancellation had already finished.
runGitHubIssueUpdateWith :: IO () -> ReviewClient -> Text -> FilePath -> GitHubIssueToolRequest -> IO (Either Text Text)
runGitHubIssueUpdateWith afterComment client threadId ghPath request = withThreadInFlightHeld client threadId $ do
  commentResult <- case request.githubToolComment of
    Nothing -> pure (Right Nothing)
    Just comment ->
      fmap (fmap (Just . Text.strip))
        (runGitHubCommand client threadId ghPath (githubIssueCommentArguments client.reviewRepositorySlug request.githubToolIssue) comment)
  afterComment
  case commentResult of
    Left message -> pure (Left message)
    Right commentUrl -> do
      labelResult <- ensureRevisedLabel client threadId ghPath request.githubToolAddLabels
      case labelResult of
        Left message -> pure (Left (partialUpdateMessage commentUrl message))
        Right () -> do
          edited <- applyReviewLabels client threadId ghPath request
          pure $ case edited of
            Left message -> Left (partialUpdateMessage commentUrl message)
            Right _ -> Right (githubUpdateResult commentUrl request)

ensureRevisedLabel :: ReviewClient -> Text -> FilePath -> [Text] -> IO (Either Text ())
ensureRevisedLabel client threadId ghPath labels
  | "reviewed:revised" `notElem` labels = pure (Right ())
  | otherwise = fmap (fmap (const ())) (runGitHubCommand client threadId ghPath (githubLabelCreateArguments client.reviewRepositorySlug) "")

applyReviewLabels :: ReviewClient -> Text -> FilePath -> GitHubIssueToolRequest -> IO (Either Text Text)
applyReviewLabels client threadId ghPath request
  | null request.githubToolAddLabels && null request.githubToolRemoveLabels = pure (Right "")
  | otherwise = runGitHubCommand client threadId ghPath (githubIssueEditArguments client.reviewRepositorySlug request) ""

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

runGitHubCommand :: ReviewClient -> Text -> FilePath -> [String] -> Text -> IO (Either Text Text)
runGitHubCommand client threadId ghPath arguments input = do
  reserved <- reserveToolInvocation client threadId
  case reserved of
    Nothing -> pure (Left "Kanban refused the GitHub CLI invocation: this thread is not currently accepting new tool processes")
    Just invocationId -> releaseInFlightInvocation client threadId $ do
      started <- try (createProcess processSpec) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
      case started of
        Left exception -> do
          deregisterToolProcess client invocationId
          pure (Left ("Could not start GitHub CLI: " <> exceptionText exception))
        Right (Just inputHandle, Just outputHandle, Just errorHandle, processHandle) -> do
          (managed, groupLeaderProblem) <- managedProcess processHandle
          mapM_ (\problem -> client.reviewEventSink (ReviewProtocolWarning ("process group leadership: " <> problem))) groupLeaderProblem
          (peekCensus, _, stopCensus) <- watchManagedProcessCensus managed
          attached <- attachToolProcess client invocationId managed peekCensus stopCensus
          if not attached
            then do
              confirmed <- confirmToolProcessTerminated client managed peekCensus stopCensus
              unless confirmed (registerOrphanedToolProcess client threadId managed peekCensus stopCensus)
              pure (Left "Kanban refused the GitHub CLI invocation: this thread is not currently accepting new tool processes")
            else do
              outputResult <- newEmptyMVar
              errorResult <- newEmptyMVar
              void . forkIO $ captureHandle outputHandle outputResult
              void . forkIO $ captureHandle errorHandle errorResult
              written <- try (ByteString.hPutStr inputHandle (TextEncoding.encodeUtf8 input) >> hClose inputHandle) :: IO (Either IOException ())
              result <- case written of
                Left exception -> pure (Left ("Could not send input to GitHub CLI: " <> exceptionText exception))
                Right () -> do
                  completed <-
                    timeout githubCommandTimeoutMicros $ do
                      forceCensusTick managed
                      exitCode <- waitForProcess processHandle
                      output <- takeMVar outputResult
                      errors <- takeMVar errorResult
                      pure (exitCode, output, errors)
                  case completed of
                    Nothing -> pure (Left "GitHub operation timed out after 30 seconds")
                    Just captured -> pure (renderGitHubCommandResult captured)
              -- Confirmed here regardless of outcome, not only on failure/timeout:
              -- `gh` itself could fork a same-group child, close its inherited
              -- stdio, and exit successfully, leaving a survivor this invocation
              -- is the only registry entry ever pointing at. Deregistering only
              -- once confirmed leaves an unconfirmed entry registered for a
              -- later drain to retry, rather than dropping ownership of it here.
              confirmed <- confirmToolProcessTerminated client managed peekCensus stopCensus
              when confirmed (deregisterToolProcess client invocationId)
              pure result
        Right _ -> do
          deregisterToolProcess client invocationId
          pure (Left "GitHub CLI did not provide all three standard streams")
  where
    processSpec =
      (proc ghPath arguments)
        { cwd = Just client.reviewRepositoryRoot,
          std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }

runCanonicalCommand :: Repository -> Int -> FilePath -> [String] -> (ManagedProcess -> IO ()) -> IO (Either Text Text)
runCanonicalCommand = runCanonicalCommandWith canonicalReviewTimeoutMicros

-- | As 'killManagedProcessVerified', but a bounded failure to confirm does
-- not end this call's own ownership of `managed`: a detached background
-- thread keeps retrying, unboundedly, until termination is finally
-- confirmed -- the same active-cleanup-owner pattern
-- 'confirmToolProcessTerminatedOrKeepTrying' uses for the tool registry
-- and app-server, applied here to a standalone managed process (namely
-- 'runCanonicalCommandWith's own leader) that has no 'ReviewClient' of
-- its own to route per-retry warnings through.
killManagedProcessVerifiedOrKeepTrying :: ManagedProcess -> IO Bool
killManagedProcessVerifiedOrKeepTrying = killManagedProcessVerifiedOrKeepTryingWith (threadDelay backgroundCleanupRetryDelayMicros)

-- | As 'killManagedProcessVerifiedOrKeepTrying', but with the background
-- cleanup owner's own retry-to-retry wait injectable -- e.g. to
-- deterministically prove it eventually confirms termination once
-- whatever blocked a bounded attempt is resolved, without a test actually
-- waiting out 'backgroundCleanupRetryDelayMicros'.
killManagedProcessVerifiedOrKeepTryingWith :: IO () -> ManagedProcess -> IO Bool
killManagedProcessVerifiedOrKeepTryingWith backgroundRetryDelay managed = do
  confirmed <- killManagedProcessVerified managed
  unless confirmed (void (forkIO keepTrying))
  pure confirmed
  where
    keepTrying = do
      backgroundRetryDelay
      confirmed <- killManagedProcessVerified managed
      unless confirmed keepTrying

-- | As 'runCanonicalCommand', but with the overall timeout injectable --
-- e.g. to deterministically exercise the timeout path in a test without
-- waiting out the real one-hour budget.
runCanonicalCommandWith :: Int -> Repository -> Int -> FilePath -> [String] -> (ManagedProcess -> IO ()) -> IO (Either Text Text)
runCanonicalCommandWith timeoutMicros repository issueNumber executable arguments processStarted = do
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
      completed <- timeout timeoutMicros $ do
        forceCensusTick managed
        exitCode <- waitForProcess processHandle
        output <- takeMVar outputResult
        errors <- takeMVar errorResult
        pure (exitCode, output, errors)
      case completed of
        -- Uses the already-captured `managed` value, not a fresh
        -- 'getPid'-based query against `processHandle`: if the leader has
        -- already exited and been reaped by the time this timeout fires
        -- (e.g. a same-group child forked earlier is still holding
        -- inherited stdout/stderr pipes open), a live handle query would
        -- return 'Nothing' and leave that survivor completely unreachable
        -- and unowned once this returns.
        --
        -- 'killManagedProcessVerifiedOrKeepTrying's own bounded attempt
        -- can still fail to *immediately* confirm the group empty (a
        -- transient snapshot failure, or the documented residual gap in
        -- 'Kanban.Process.startEmbeddedCensusWith' where a census tick
        -- was never able to witness a fast-forked child at all) -- a
        -- background thread keeps retrying afterward, so this function
        -- never simply returns having discarded ownership of a group it
        -- could not immediately confirm empty.
        Nothing -> do
          confirmed <- killManagedProcessVerifiedOrKeepTrying managed
          unless confirmed $
            mapM_ (\value -> logMessage value "group-unconfirmed" "canonical issue reviewer's process group could not be confirmed terminated after timing out") sessionLog
          finishLog sessionLog
          pure (Left "Canonical issue review timed out after one hour")
        Just (exitCode, output, errors) -> do
          -- A *normal* completion -- the leader exiting on its own,
          -- however that went -- is not the same as this spawn's process
          -- group actually being empty: the leader could have forked a
          -- same-group child and closed its own inherited stdout/stderr
          -- before exiting, letting waitForProcess and both capture
          -- threads all complete normally while that child keeps running,
          -- entirely untracked once this function returns (the caller
          -- only ever sees a plain 'Either', with no further handle on
          -- this managed process at all). killManagedProcessVerifiedOrKeepTrying
          -- is always safe to call unconditionally here: if the recorded
          -- group is already genuinely empty (the ordinary case), its own
          -- first fresh check confirms that and returns without ever
          -- sending a signal; it only actually terminates anything if a
          -- survivor is found, and keeps retrying in the background
          -- rather than ever giving up on one it could not immediately
          -- confirm.
          survivorConfirmed <- killManagedProcessVerifiedOrKeepTrying managed
          unless survivorConfirmed $
            mapM_ (\value -> logMessage value "group-unconfirmed" "canonical issue reviewer's process group could not be confirmed terminated after it exited") sessionLog
          case (exitCode, output, errors) of
            (ExitSuccess, Right outputBytes, _) -> do
              logCaptured sessionLog outputBytes errors
              finishLog sessionLog
              pure (Right (decodeClaudeBytes outputBytes))
            (ExitFailure code, Right outputBytes, Right errorBytes) ->
              logCaptured sessionLog outputBytes (Right errorBytes) >> finishLog sessionLog >> pure (Left ("Canonical issue reviewer exited with status " <> Text.pack (show code) <> renderClaudeFailureDetails outputBytes errorBytes))
            (_, Left exception, _) -> finishLog sessionLog >> pure (Left ("Could not read canonical issue review output: " <> exceptionText exception))
            (_, _, Left exception) -> finishLog sessionLog >> pure (Left ("Could not read canonical issue review diagnostics: " <> exceptionText exception))
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
runAuthenticatedClaude = runAuthenticatedClaudeWith (pure ())

-- | As 'runAuthenticatedClaude', but runs `beforeSpawn` right after the
-- invocation is reserved and just before it spawns a process -- exposed so
-- tests can pause an invocation at exactly that point (see
-- 'checkGroupMembershipWith' for the same "...With" dependency-injection
-- pattern used elsewhere in this codebase) to deterministically hold it
-- open across a concurrent 'stopReviewClient'/'killReviewTools', rather
-- than relying on scheduler timing to land the race. Production code
-- always calls this with @pure ()@.
runAuthenticatedClaudeWith :: IO () -> ReviewClient -> Text -> Text -> IO (Either Text Text)
runAuthenticatedClaudeWith beforeSpawn client threadId prompt = do
  reserved <- reserveToolInvocation client threadId
  case reserved of
    Nothing -> pure (Left "Kanban refused the Claude invocation: this thread is not currently accepting new tool processes")
    Just invocationId -> releaseInFlightInvocation client threadId $ do
      beforeSpawn
      executable <- findExecutable "claude"
      case executable of
        Nothing -> do
          deregisterToolProcess client invocationId
          pure (Left "Claude CLI was not found on PATH")
        Just claudePath -> do
          started <- try (createProcess (claudeProcess claudePath)) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
          case started of
            Left exception -> do
              deregisterToolProcess client invocationId
              pure (Left ("Could not start authenticated Claude CLI: " <> exceptionText exception))
            Right (Just inputHandle, Just outputHandle, Just errorHandle, processHandle) -> do
              (managed, groupLeaderProblem) <- managedProcess processHandle
              mapM_ (\problem -> client.reviewEventSink (ReviewProtocolWarning ("process group leadership: " <> problem))) groupLeaderProblem
              (peekCensus, _, stopCensus) <- watchManagedProcessCensus managed
              attached <- attachToolProcess client invocationId managed peekCensus stopCensus
              if not attached
                then do
                  confirmed <- confirmToolProcessTerminated client managed peekCensus stopCensus
                  unless confirmed (registerOrphanedToolProcess client threadId managed peekCensus stopCensus)
                  pure (Left "Kanban refused the Claude invocation: this thread is not currently accepting new tool processes")
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
                          forceCensusTick managed
                          exitCode <- waitForProcess processHandle
                          output <- takeMVar outputResult
                          errors <- takeMVar errorResult
                          pure (exitCode, output, errors)
                      case completed of
                        Nothing -> pure (Left "Claude Sonnet 5 revision agent timed out after ten minutes")
                        Just captured -> pure (renderClaudeResult captured)
                  -- Confirmed here regardless of outcome, not only on
                  -- failure/timeout: Claude itself could fork a same-group
                  -- child, close its inherited stdio, and exit successfully,
                  -- leaving a survivor this invocation is the only registry
                  -- entry ever pointing at. Deregistering only once confirmed
                  -- leaves an unconfirmed entry registered for a later drain to
                  -- retry, rather than dropping ownership of it here.
                  confirmed <- confirmToolProcessTerminated client managed peekCensus stopCensus
                  when confirmed (deregisterToolProcess client invocationId)
                  pure result
            Right _ -> do
              deregisterToolProcess client invocationId
              pure (Left "Claude CLI did not provide all three standard streams")
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

-- | Bounds 'watchServerProcess's wait for the output/error readers to reach
-- EOF, comfortably longer than 'confirmToolProcessTerminated's own worst
-- case (its three attempts, 'confirmRetryDelayMicros' apart, which runs
-- immediately beforehand) so a normal confirm-then-EOF sequence never trips
-- it, while still bounding the case where a survivor 'confirmToolProcessTerminated'
-- could not confirm gone keeps holding the pipes open indefinitely.
pipeReaderShutdownTimeoutMicros :: Int
pipeReaderShutdownTimeoutMicros = 5 * 1000 * 1000

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

-- | Paced to comfortably exceed the census watcher's own tick interval (see
-- 'watchManagedProcessCensus' in "Kanban.Process"), so a retry in
-- 'confirmToolProcessTerminated' genuinely gives the still-running watcher
-- a chance to record an intervening tick -- not an immediate, still-stale
-- re-peek of exactly the same reading that just failed to establish
-- continuity.
confirmRetryDelayMicros :: Int
confirmRetryDelayMicros = 600 * 1000

-- | How often 'awaitNoInFlightInvocations' re-checks the in-flight count.
inFlightPollMicros :: Int
inFlightPollMicros = 200 * 1000

-- | How long the background cleanup owner ('drainToolProcesses',
-- 'confirmToolProcessTerminatedOrKeepTrying') waits between retries once a
-- bounded attempt has already failed and handed ownership off to it. Much
-- longer than 'confirmRetryDelayMicros': this is no longer racing to catch
-- an imminent census tick on a client someone is actively waiting on, just
-- periodically checking in on a straggler in the background for as long
-- as it takes.
backgroundCleanupRetryDelayMicros :: Int
backgroundCleanupRetryDelayMicros = 30 * 1000 * 1000

githubCommentLimit :: Int
githubCommentLimit = 100000
