-- | The Codex app-server client that drives an interactive review session:
-- process startup and shutdown, the JSON-RPC handshake, the reader threads,
-- and the dispatch of every wire message — including routing a tool call to
-- "Kanban.Review.Tools" and answering it.
--
-- Also the compatibility facade for the whole @Kanban.Review.*@ group: this
-- module's export list is what "Kanban.UI", "Kanban.Preflight", and the
-- test suite import, so the focused modules behind it can be rearranged
-- without touching a consumer.
module Kanban.Review
  ( CanonicalIssueReviewResult (..),
    CommandBounds (..),
    GitHubIssueOperation (..),
    GitHubIssueToolRequest (..),
    IssueReviewerRecord (..),
    IssueReviewerSource (..),
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
    claudeCommandBounds,
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
    issueReviewerNotFoundMessage,
    issueReviewerRecordFromBytes,
    issueReviewerRecordPath,
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
    resolveCanonicalIssueReviewerAt,
    reviewStageForLabels,
    runAuthenticatedClaude,
    runCanonicalCommand,
    runCanonicalIssueReview,
    runGitHubIssueTool,
    selectCanonicalIssueReviewer,
    selectCanonicalIssueReviewerAt,
    sendReviewMessage,
    startReviewClient,
    stopReviewClient,
    renderReviewResult,
    withReservedToolSlot,
  )
where

import Control.Concurrent (forkIO, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, takeMVar, withMVar)
import Control.Concurrent.MVar (readMVar)
import Control.Exception (IOException, try)
import Control.Monad (forever, void)
import Data.Aeson
  ( Result (..),
    Value (..),
    encode,
    fromJSON,
    object,
    (.=),
  )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (atomicModifyIORef', newIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Kanban.CommandCapture (CommandBounds (..))
import Kanban.Domain (Repository (..), WorkflowConfig, defaultWorkflowConfig)
import Kanban.Process (killManagedProcess, managedProcess)
import Kanban.Review.Canonical
  ( IssueReviewerRecord (..),
    IssueReviewerSource (..),
    canonicalCommandBounds,
    canonicalIssueReviewArguments,
    canonicalIssueReviewerPath,
    issueReviewerNotFoundMessage,
    issueReviewerRecordFromBytes,
    issueReviewerRecordPath,
    renderCanonicalIssueReviewResult,
    resolveCanonicalIssueReviewer,
    resolveCanonicalIssueReviewerAt,
    runCanonicalCommand,
    runCanonicalIssueReview,
    selectCanonicalIssueReviewer,
    selectCanonicalIssueReviewerAt,
  )
import Kanban.Review.Client
  ( ReviewClient (..),
    ToolRegistry,
    attachToolProcess,
    drainToolRegistry,
    killReviewTools,
    killThreadToolProcesses,
    newToolRegistry,
    releaseToolSlot,
    reserveToolSlot,
    withReservedToolSlot,
  )
import Kanban.Review.Diagnostics (exceptionText, outcomeUnknownDiagnostic)
import Kanban.Review.Prompts
  ( claudeTool,
    claudeToolName,
    finalOutputSchema,
    githubTool,
    githubToolName,
    questionTool,
    questionToolName,
    reviewDeveloperInstructions,
    reviewPrompt,
  )
import Kanban.Review.Tools
  ( claudeCommandBounds,
    githubActionSummary,
    githubCommandBounds,
    githubIssueCommentArguments,
    githubIssueEditArguments,
    githubIssueViewArguments,
    githubLabelCreateArguments,
    runAuthenticatedClaude,
    runGitHubIssueTool,
  )
import Kanban.Review.Types
  ( CanonicalIssueReviewResult (..),
    ClaudeToolRequest (..),
    GitHubIssueOperation (..),
    GitHubIssueToolRequest (..),
    PendingRequest (..),
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
    reviewStageForLabels,
  )
import Kanban.Transcript (SessionLog, closeSessionLog, logMessage, logRawLine, openSessionLog)
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
                reviewCommandBounds = githubCommandBounds,
                reviewClaudeBounds = claudeCommandBounds
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
--
-- The injected bounds stand in for *both* production sets, so a fake
-- @claude@ reaches the deadline and capture-grace paths as cheaply as a
-- fake @gh@ does. No test needs the two to differ; one that did could
-- override 'reviewClaudeBounds' on the result.
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
        reviewCommandBounds = bounds,
        reviewClaudeBounds = bounds
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

sendErrorResponse :: ReviewClient -> Value -> Int -> Text -> IO (Either Text ())
sendErrorResponse client requestId code message =
  sendValue client (object ["id" .= requestId, "error" .= object ["code" .= code, "message" .= message]])

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

renderExitCode :: ExitCode -> Text
renderExitCode ExitSuccess = "Codex app-server exited"
renderExitCode (ExitFailure code) = "Codex app-server exited with status " <> Text.pack (show code)

ignoreIOException :: IO () -> IO ()
ignoreIOException action = do
  _ <- try action :: IO (Either IOException ())
  pure ()

initializationTimeoutMicros :: Int
initializationTimeoutMicros = 10 * 1000 * 1000
