-- | The embedded issue-review client: connection startup and shutdown, the
-- reader threads, and the dispatch of everything a provider sends back —
-- including routing a tool call to "Kanban.Review.Tools" and answering it.
--
-- A client holds a /pool/ of connections rather than one process
-- ("Kanban.Review.Connection"). Codex's backend shares one connection across
-- every review thread; Claude's gives each thread its own process, and both
-- route through the same code by acquiring a connection per review or
-- reusing the one they hold.
--
-- Two things about a backend the shared code cannot be written without, and
-- both are read off the backend record rather than off the provider it
-- belongs to. 'ReviewProcessShape' says how many processes a client's
-- threads occupy, and so whether one connection ending is the whole client
-- ending. 'ReviewProtocol' says whether starting a connection completes a
-- handshake, and how one line of its output is read: 'AppServerProtocol' is
-- the JSON-RPC exchange the rest of this module speaks, and
-- 'StreamJsonProtocol' is the CLI channel "Kanban.Review.Stream" decodes.
--
-- Also the compatibility facade for the whole @Kanban.Review.*@ group: this
-- module's export list is what "Kanban.UI", "Kanban.Preflight", and the
-- test suite import, so the focused modules behind it can be rearranged
-- without touching a consumer.
module Kanban.Review
  ( CanonicalIssueReviewResult (..),
    CommandBounds (..),
    ConnectionId (..),
    EmbeddedReviewBackend (..),
    GitHubIssueOperation (..),
    GitHubIssueToolRequest (..),
    IssueReviewerRecord (..),
    IssueReviewerSource (..),
    ReviewAnswer (..),
    ReviewApproval (..),
    ReviewChoice (..),
    ReviewClient,
    ReviewConnection (..),
    ReviewEvent (..),
    ReviewLaunch (..),
    ReviewOutputKind (..),
    ReviewProcessShape (..),
    ReviewProtocol (..),
    ReviewQuestion (..),
    ReviewQuestionKind (..),
    ReviewRequestId (..),
    ReviewResult (..),
    ReviewStage (..),
    ReviewThreadId (..),
    ReviewTurnOutcome (..),
    ReviewWireMessage (..),
    StreamRecord (..),
    StreamTurnResult (..),
    ToolRegistry,
    addRecordingReviewConnectionForTesting,
    answerReviewQuestion,
    approveReviewAction,
    attachToolProcess,
    beginIssueReview,
    canonicalCommandBounds,
    canonicalIssueReviewArguments,
    canonicalIssueReviewerPath,
    claudeCommandBounds,
    claudeReviewArguments,
    claudeStartedEvent,
    claudeTool,
    decodeCanonicalIssueReviewResult,
    decodeClaudeToolPrompt,
    decodeGitHubIssueToolRequest,
    decodeReviewQuestion,
    decodeReviewResult,
    decodeReviewWireMessage,
    decodeStreamRecord,
    drainToolRegistry,
    embeddedReviewProvider,
    finalOutputSchema,
    githubCommandBounds,
    githubIssueCommentArguments,
    githubIssueEditArguments,
    authenticatedClaudeArguments,
    githubIssueViewArguments,
    githubLabelCreateArguments,
    handleWireMessage,
    interruptReview,
    issueReviewerNotFoundMessage,
    issueReviewerRecordFromBytes,
    issueReviewerRecordPath,
    issueReviseDisplay,
    killConnectionToolProcesses,
    killReviewTools,
    killThreadToolProcesses,
    missingEmbeddedReviewMessage,
    newRecordingReviewClientForTesting,
    newReviewClientForTesting,
    reviewConnectionsForTesting,
    reviewDeveloperInstructions,
    newToolRegistry,
    outcomeUnknownDiagnostic,
    releaseToolSlot,
    renderCanonicalIssueReviewResult,
    reserveToolSlot,
    resolveCanonicalIssueReviewer,
    resolveCanonicalIssueReviewerAt,
    reviewStageForLabels,
    streamUserMessage,
    unsupportedReviewOperationMessage,
    issueReviseAssignment,
    runAuthenticatedClaude,
    runCanonicalCommand,
    runCanonicalIssueReview,
    runGitHubIssueTool,
    selectCanonicalIssueReviewer,
    selectCanonicalIssueReviewerAt,
    sendReviewMessage,
    startReviewClient,
    startResolvedReviewClient,
    stopReviewClient,
    renderReviewResult,
    withReservedToolSlot,
  )
where

import Control.Concurrent (forkIO, modifyMVar, modifyMVar_, newMVar, putMVar, takeMVar, withMVar)
import Control.Concurrent.MVar (readMVar)
import Control.Exception (IOException, try)
import Control.Monad (forever, void, when)
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
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Kanban.CommandCapture (CommandBounds (..))
import Kanban.Domain (Repository (..), WorkflowConfig, defaultWorkflowConfig)
import Kanban.Models
  ( Assignment (..),
    ModelRoster,
    ProviderName (..),
    RoleName (..),
    assignmentFor,
    assignmentUnavailableMessage,
  )
import Kanban.Process (killManagedProcess, managedProcess)
import Kanban.ProviderAdapter
  ( EmbeddedReviewBackend (..),
    ProviderAdapter (..),
    ReviewLaunch (..),
    ReviewProcessShape (..),
    ReviewProtocol (..),
    adapterFor,
    claudeReviewArguments,
  )
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
    emitProtocolWarning,
    killConnectionToolProcesses,
    killConnectionToolProcesses,
    killReviewTools,
    killThreadToolProcesses,
    newToolRegistry,
    releaseToolSlot,
    reserveToolSlot,
    withReservedToolSlot,
  )
import Kanban.Review.Connection
  ( ConnectionAcquisition (..),
    ConnectionId (..),
    PendingRequest (..),
    ReviewConnection (..),
    ReviewThreadId (..),
    attachConnection,
    attachedConnections,
    awaitConnectionReaders,
    drainConnectionPool,
    lookupConnection,
    markConnectionReadersStarted,
    newConnectionPool,
    newReviewConnection,
    releaseConnectionSlot,
    reserveConnectionSlot,
    takeConnection,
    takePendingThreadStarts,
  )
import Kanban.Review.Diagnostics
  ( exceptionText,
    missingEmbeddedReviewMessage,
    outcomeUnknownDiagnostic,
    reviewSessionDiagnostic,
    sentenceCase,
    unsupportedReviewOperationMessage,
  )
import Kanban.Review.Prompts
  ( claudeTool,
    claudeToolName,
    finalOutputSchema,
    githubToolName,
    questionToolName,
    reviewDeveloperInstructions,
    reviewPrompt,
  )
import Kanban.Review.Stream
  ( StreamRecord (..),
    StreamTurnResult (..),
    decodeStreamRecord,
    streamUserMessage,
  )
import Kanban.Review.Tools
  ( authenticatedClaudeArguments,
    claudeCommandBounds,
    githubActionSummary,
    githubCommandBounds,
    githubIssueCommentArguments,
    githubIssueEditArguments,
    githubIssueViewArguments,
    githubLabelCreateArguments,
    issueReviseAssignment,
    issueReviseDisplay,
    runAuthenticatedClaude,
    runGitHubIssueTool,
  )
import Kanban.Review.Types
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

-- | The event announcing a @kanban_run_claude@ call, carrying the display of
-- the cell /this/ client resolves it from.
--
-- Resolved here, at emission, and never again. The client keeps the roster
-- snapshot it was started on for its whole life while the dashboard's own
-- moves with the settings overlay, so the two diverge the moment a cell is
-- edited; and because the call runs in a fork, a consumer can handle a
-- backend stop or restart before this event and would then read a
-- replacement client's roster, or no client at all. Binding the value to the
-- client that is actually running the call closes both.
claudeStartedEvent :: ReviewClient -> ReviewThreadId -> ReviewEvent
claudeStartedEvent client threadId =
  ReviewClaudeStarted threadId (issueReviseDisplay client.reviewModelRoster)

-- | The provider Kanban's embedded issue review runs on, and so the adapter
-- whose backend it starts and whose dynamic tools it registers.
--
-- Codex, unchanged: MODEL-12 makes the backend a field a provider may lack
-- rather than a construction only Codex can be, but it routes nothing new.
-- MODEL-13 is what fills Claude's, and MODEL-10 is what makes this a value
-- the operator's mode can move.
embeddedReviewProvider :: ProviderName
embeddedReviewProvider = CodexProvider

-- | The cell an embedded issue review runs on: @issue_review@ for the
-- provider whose backend is serving it.
--
-- One spelling, taking the provider, because two things resolve it and they
-- must not be able to disagree. 'startReviewClient' asks before it has a
-- client, for the provider its routing selected; everything inside a running
-- client asks through 'backendAssignment' below, for the provider whose
-- backend actually started. Those are the same cell for the backend an
-- install routes to, and a second backend is exactly what would make two
-- separate lookups drift apart.
issueReviewAssignment :: ProviderName -> ModelRoster -> Either Text Assignment
issueReviewAssignment provider roster =
  either (Left . assignmentUnavailableMessage) Right (assignmentFor roster IssueReviewRole provider)

-- | The cell a running client's own backend resolves.
--
-- Read through the backend rather than through 'embeddedReviewProvider'
-- because everything downstream of it belongs to the provider that started:
-- Codex's model and effort travel in @thread\/start@ and @turn\/start@,
-- Claude's are argv (D-15), and the refusal a roster that cannot supply the
-- cell produces has to name the provider whose backend is being refused.
backendAssignment :: ReviewClient -> Either Text Assignment
backendAssignment client =
  issueReviewAssignment client.reviewBackend.backendProvider client.reviewModelRoster

startReviewClient :: ModelRoster -> WorkflowConfig -> Repository -> (ReviewEvent -> IO ()) -> IO (Either Text ReviewClient)
startReviewClient roster workflowConfig repository eventSink = case issueReviewAssignment embeddedReviewProvider roster of
  -- Resolved before the app-server is spawned, not after: a roster that
  -- loads no Codex provider must start no process at all, and the backend's
  -- own failure surface already carries the reason to the UI. The cell is
  -- consulted first and the backend second, in that order, because that is
  -- the order the refusals were already reached in: today's Codex-only
  -- routing always finds a backend, so the second arm answers nothing an
  -- install can currently ask.
  Left message -> pure (Left message)
  Right _ -> case (adapterFor embeddedReviewProvider).adapterEmbeddedReview of
    Nothing -> pure (Left (missingEmbeddedReviewMessage embeddedReviewProvider))
    Just backend -> startResolvedReviewClient backend roster workflowConfig repository eventSink

-- | Start a client against a chosen backend, rather than the one
-- 'embeddedReviewProvider' resolves. Exported so a test can drive either
-- process shape without a provider shipping it: nothing in production calls
-- this except 'startReviewClient' above.
startResolvedReviewClient :: EmbeddedReviewBackend -> ModelRoster -> WorkflowConfig -> Repository -> (ReviewEvent -> IO ()) -> IO (Either Text ReviewClient)
startResolvedReviewClient backend roster workflowConfig repository eventSink = do
  logResult <- openSessionLog repository "issue-revision-appserver" 0 Nothing
  sessionLog <- case logResult of
    Left message -> eventSink (ReviewProtocolWarning backend.backendProvider message) >> pure Nothing
    Right value -> logMessage value "backend-started" backend.backendLabel >> pure (Just value)
  connections <- newConnectionPool
  activeTurns <- newMVar Map.empty
  threadIssues <- newMVar Map.empty
  toolRegistry <- newToolRegistry
  let client =
        ReviewClient
          { reviewBackend = backend,
            reviewConnections = connections,
            reviewActiveTurns = activeTurns,
            reviewThreadIssues = threadIssues,
            reviewToolRegistry = toolRegistry,
            reviewEventSink = eventSink,
            reviewRepositoryRoot = repository.repositoryRoot,
            reviewRepositorySlug = repository.repositoryOwner <> "/" <> repository.repositoryName,
            reviewWorkflowConfig = workflowConfig,
            reviewModelRoster = roster,
            reviewSessionLog = sessionLog,
            reviewCommandBounds = githubCommandBounds,
            reviewClaudeBounds = claudeCommandBounds
          }
  -- A shared-process backend's one connection is spawned and handshaken here
  -- rather than at the first review, so a backend that cannot start is
  -- reported by 'startReviewClient' itself, exactly as it was before the
  -- client held a pool. A per-thread backend has nothing to start yet: its
  -- first connection belongs to the first review thread.
  case backend.backendProcessShape of
    ProcessPerThread -> pure (Right client)
    SharedProcess -> do
      started <- startReviewConnection client
      case started of
        Left message -> closeReviewLog sessionLog >> pure (Left message)
        Right _ -> pure (Right client)

-- | The connection that serves a new review thread: the one this client
-- already holds when its backend shares a process across every thread, or a
-- freshly spawned one when the backend gives each thread its own.
acquireReviewConnection :: ReviewClient -> IO (Either Text ReviewConnection)
acquireReviewConnection client = case client.reviewBackend.backendProcessShape of
  -- A shared-process backend's one connection is created when the client
  -- starts and is never replaced. Spawning a replacement here would be a
  -- second app-server for a client the UI has already been told is finished,
  -- and the threads the first was serving would go on being reported against
  -- a client that looks healthy.
  SharedProcess -> do
    held <- attachedConnections client.reviewConnections
    case held of
      connection : _ -> pure (Right connection)
      [] -> pure (Left (connectionGoneMessage client))
  ProcessPerThread -> startReviewConnection client

-- | Reserve a slot and spawn a connection into it.
startReviewConnection :: ReviewClient -> IO (Either Text ReviewConnection)
startReviewConnection client = do
  reserved <- reserveConnectionSlot client.reviewConnections
  case reserved of
    ConnectionPoolClosed -> pure (Left (clientShuttingDownMessage client))
    ReservedConnection identifier -> spawnReviewConnection client identifier

-- | Start one provider process, complete its handshake, and register it.
--
-- The readers are forked before the connection is attached, so anything that
-- later finds it in the pool — shutdown above all — may wait on its
-- completion signal unconditionally. A failure before that point is cleaned
-- up here and releases the reservation, because nothing else has ever seen
-- it.
spawnReviewConnection :: ReviewClient -> ConnectionId -> IO (Either Text ReviewConnection)
spawnReviewConnection client identifier = case backendAssignment client of
  -- Resolved before the process, not after: a backend whose argv carries the
  -- roster's model and effort cannot be launched without them, and one that
  -- carries them on the wire would only reach the same refusal a moment
  -- later with a provider process already running.
  Left message -> abandonSlot message
  Right assignment -> do
    let processSpec = client.reviewBackend.backendProcess (ReviewLaunch client.reviewRepositoryRoot assignment)
    started <- try (createProcess processSpec) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
    case started of
      Left exception -> abandonSlot ("Could not start " <> label <> ": " <> exceptionText exception)
      Right (Just inputHandle, Just outputHandle, Just errorHandle, processHandle) -> do
        hSetBuffering inputHandle LineBuffering
        hSetBuffering outputHandle LineBuffering
        (processManaged, groupLeaderProblem) <- managedProcess processHandle
        mapM_ (\value -> mapM_ (logMessage value "group-leadership-unverified") groupLeaderProblem) client.reviewSessionLog
        connection <- newReviewConnection identifier inputHandle processHandle processManaged
        -- The thread this connection's stream is on, once its provider has
        -- named it. Held beside the connection rather than on it because it
        -- is the reader loops' own state: both of them attribute what they
        -- read to it, and only they ever write it.
        streamThread <- newIORef Nothing
        initialized <- completeHandshake client connection outputHandle
        case initialized of
          Nothing -> abandonConnection connection (sentenceLabel <> " initialization timed out")
          Just (Left message) -> abandonConnection connection message
          Just (Right ()) -> do
            markConnectionReadersStarted connection
            void (forkIO (readProviderOutput client connection streamThread outputHandle >> putMVar connection.connectionOutputDone ()))
            void (forkIO (readProviderErrors client connection streamThread errorHandle >> putMVar connection.connectionErrorDone ()))
            void (forkIO (watchServerProcess client connection))
            attached <- attachConnection client.reviewConnections connection
            if attached
              then pure (Right connection)
              else do
                -- Shutdown drained the pool while this was starting, so no
                -- drain will ever see this connection: it is stopped here, by
                -- the only code that still holds it.
                stopReviewConnection connection
                awaitConnectionReaders connection
                pure (Left (clientShuttingDownMessage client))
      Right _ -> abandonSlot (sentenceLabel <> " did not provide all three standard streams")
  where
    label = client.reviewBackend.backendLabel
    sentenceLabel = sentenceCase label
    abandonSlot message = do
      releaseConnectionSlot client.reviewConnections identifier
      pure (Left message)
    abandonConnection connection message = do
      stopReviewConnection connection
      abandonSlot message

-- | Complete whatever a backend requires before anything may be sent, which
-- for one of the two protocols is nothing at all.
--
-- The app-server answers an @initialize@ request and is not usable until it
-- has, so the exchange is performed and bounded. The CLI streams as soon as
-- it starts: there is no exchange to complete, nothing to wait for, and so
-- nothing to time out on. The 'Maybe' is the timeout's, so the two arms
-- agree on one shape.
completeHandshake :: ReviewClient -> ReviewConnection -> Handle -> IO (Maybe (Either Text ()))
completeHandshake client connection outputHandle = case client.reviewBackend.backendProtocol of
  AppServerProtocol -> timeout initializationTimeoutMicros (initializeConnection client connection outputHandle)
  StreamJsonProtocol -> pure (Just (Right ()))

-- | Kill one connection's process group and close the handle its requests
-- are written to. Never waits: the caller decides whether it also has to
-- wait for that connection's loops to finish.
stopReviewConnection :: ReviewConnection -> IO ()
stopReviewConnection connection = do
  killManagedProcess connection.connectionManaged
  ignoreIOException (hClose connection.connectionInput)

clientShuttingDownMessage :: ReviewClient -> Text
clientShuttingDownMessage client = backendSentence client <> " client is shutting down"

connectionGoneMessage :: ReviewClient -> Text
connectionGoneMessage client = backendSentence client <> " connection for this review has ended"

-- | Builds a 'ReviewClient' holding one 'placeholderReviewBackend'
-- connection, without the handshake and reader loops 'startReviewClient'
-- gives a real one, so tests can exercise the tool-invocation and registry
-- machinery (@kanban_run_claude@, @kanban_github_issue@, 'killReviewTools',
-- 'stopReviewClient') directly.
--
-- The injected bounds stand in for *both* production sets, so a fake
-- @claude@ reaches the deadline and capture-grace paths as cheaply as a
-- fake @gh@ does. No test needs the two to differ; one that did could
-- override 'reviewClaudeBounds' on the result.
--
-- The roster is injected for the same reason: it is what the two consulted
-- cells are resolved from, so a test proving a non-default roster reaches
-- @kanban_run_claude@'s argv passes one in here.
newReviewClientForTesting :: ModelRoster -> CommandBounds -> FilePath -> Text -> (ReviewEvent -> IO ()) -> IO ReviewClient
newReviewClientForTesting roster bounds repositoryRoot repositorySlug eventSink = do
  connections <- newConnectionPool
  activeTurns <- newMVar Map.empty
  threadIssues <- newMVar Map.empty
  toolRegistry <- newToolRegistry
  let client =
        ReviewClient
          { reviewBackend = placeholderReviewBackend,
            reviewConnections = connections,
            reviewActiveTurns = activeTurns,
            reviewThreadIssues = threadIssues,
            reviewToolRegistry = toolRegistry,
            reviewEventSink = eventSink,
            reviewRepositoryRoot = repositoryRoot,
            reviewRepositorySlug = repositorySlug,
            reviewWorkflowConfig = defaultWorkflowConfig,
            reviewModelRoster = roster,
            reviewSessionLog = Nothing,
            reviewCommandBounds = bounds,
            reviewClaudeBounds = bounds
          }
  _ <- addTestingReviewConnection client False
  pure client

-- | The cell the placeholder backend is launched under. It ignores its
-- launch entirely — @git --version@ takes no model — but a launch is what
-- every backend is handed, and inventing one here keeps the fixture from
-- depending on whatever roster a test happened to pass.
placeholderAssignment :: Assignment
placeholderAssignment = Assignment "placeholder" "none" "placeholder none"

-- | The stand-in backend the testing constructors spawn: a harmless
-- placeholder process (@git --version@, already an audited invocation of
-- this codebase's own workflow) so shutdown still has a real, killable
-- process to operate on.
--
-- Shared-process shaped and app-server spoken, so a fixture built on it
-- behaves as the backend an install routes to does. A test about the pool
-- adds its second connection explicitly rather than by starting a second
-- review, which is what keeps 'beginIssueReview' on these fixtures reaching
-- the one connection it always did.
placeholderReviewBackend :: EmbeddedReviewBackend
placeholderReviewBackend =
  EmbeddedReviewBackend
    { backendLabel = "codex app-server",
      backendProvider = CodexProvider,
      backendProcessShape = SharedProcess,
      backendProtocol = AppServerProtocol,
      backendProcess = \_ ->
        (proc "git" ["--version"])
          { std_in = CreatePipe,
            std_out = CreatePipe,
            std_err = CreatePipe,
            create_group = True
          }
    }

-- | Attach one more placeholder connection to a testing client, without the
-- handshake or the reader loops a real one gets. Registered exactly as a
-- spawned connection is, so the pool, the routing, and shutdown see no
-- difference. @recording@ replaces the placeholder process's own stdin with
-- a pipe the caller reads.
addTestingReviewConnection :: ReviewClient -> Bool -> IO (ReviewConnection, Maybe Handle)
addTestingReviewConnection client recording = do
  reserved <- reserveConnectionSlot client.reviewConnections
  identifier <- case reserved of
    ReservedConnection value -> pure value
    _ -> fail "the testing review client's connection pool refused a reservation"
  (Just processInput, Just _outputHandle, Just _errorHandle, processHandle) <-
    createProcess (client.reviewBackend.backendProcess (ReviewLaunch client.reviewRepositoryRoot placeholderAssignment))
  (processManaged, _) <- managedProcess processHandle
  (inputHandle, readEnd) <-
    if not recording
      then pure (processInput, Nothing)
      else do
        (readEnd, writeEnd) <- createPipe
        hSetBuffering writeEnd LineBuffering
        -- The placeholder process's own stdin is of no further use, and
        -- leaving it open would outlive the shutdown that closes only what
        -- the connection record names.
        ignoreIOException (hClose processInput)
        pure (writeEnd, Just readEnd)
  connection <- newReviewConnection identifier inputHandle processHandle processManaged
  _ <- attachConnection client.reviewConnections connection
  pure (connection, readEnd)

-- | A testing connection whose provider stdin is a pipe the caller reads, so
-- a test can drive responses in through 'handleWireMessage' and assert on
-- the exact wire traffic they provoke — the seam the steer recovery path
-- needs, since the suite previously only decoded app-server messages rather
-- than letting a handler answer one (issue #17).
--
-- Adding a second one is what makes connection isolation observable: the
-- same provider thread id, or the same request id, arriving on two
-- connections must reach two separate sets of state.
addRecordingReviewConnectionForTesting :: ReviewClient -> IO (ReviewConnection, Handle)
addRecordingReviewConnectionForTesting client = do
  (connection, readEnd) <- addTestingReviewConnection client True
  case readEnd of
    Just wire -> pure (connection, wire)
    Nothing -> fail "the recording testing connection was built without its wire"

-- | Every connection a client currently holds, so a test can address one of
-- them or assert on what shutdown reaped.
reviewConnectionsForTesting :: ReviewClient -> IO [ReviewConnection]
reviewConnectionsForTesting client = attachedConnections client.reviewConnections

-- | A 'newReviewClientForTesting' whose one connection records what the
-- client writes to it.
newRecordingReviewClientForTesting :: ModelRoster -> (ReviewEvent -> IO ()) -> IO (ReviewClient, Handle)
newRecordingReviewClientForTesting roster eventSink = do
  connections <- newConnectionPool
  activeTurns <- newMVar Map.empty
  threadIssues <- newMVar Map.empty
  toolRegistry <- newToolRegistry
  let client =
        ReviewClient
          { reviewBackend = placeholderReviewBackend,
            reviewConnections = connections,
            reviewActiveTurns = activeTurns,
            reviewThreadIssues = threadIssues,
            reviewToolRegistry = toolRegistry,
            reviewEventSink = eventSink,
            reviewRepositoryRoot = ".",
            reviewRepositorySlug = "coghex/kanban",
            reviewWorkflowConfig = defaultWorkflowConfig,
            reviewModelRoster = roster,
            reviewSessionLog = Nothing,
            reviewCommandBounds = githubCommandBounds,
            reviewClaudeBounds = githubCommandBounds
          }
  (_, wire) <- addRecordingReviewConnectionForTesting client
  pure (client, wire)

initializeConnection :: ReviewClient -> ReviewConnection -> Handle -> IO (Either Text ())
initializeConnection client connection outputHandle = do
  sent <- sendValue client connection initializeRequest
  case sent of
    Left message -> pure (Left message)
    Right () -> awaitInitialize
  where
    label = sentenceCase client.reviewBackend.backendLabel
    awaitInitialize = do
      eof <- hIsEOF outputHandle
      if eof
        then pure (Left (label <> " exited during initialization"))
        else do
          line <- LazyByteString.fromStrict <$> ByteString.hGetLine outputHandle
          mapM_ (\sessionLog -> logRawLine sessionLog "stdout" (LazyByteString.toStrict line)) client.reviewSessionLog
          case decodeReviewWireMessage line of
            Right (WireResponse requestId (Right _))
              | requestIdInt requestId == Just 1 -> do
                  sendValue client connection (object ["method" .= ("initialized" :: Text), "params" .= object []])
            Right (WireResponse requestId (Left err))
              | requestIdInt requestId == Just 1 -> pure (Left (label <> " rejected initialization: " <> compactValue err))
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
beginIssueReview client issueNumber = case backendAssignment client of
  -- Consulted before a connection is acquired, so a roster that cannot
  -- supply this backend's cell refuses with a visible reason and starts no
  -- process at all. For a backend that gives each thread its own, acquiring
  -- the connection *is* the spawn.
  Left message -> pure (Left message)
  Right assignment -> do
    -- The one place a review's connection is decided. A shared-process
    -- backend hands back the connection it already holds, so every thread
    -- lands on one process; a per-thread backend spawns here, so this
    -- review's thread is the only one its process will ever serve.
    acquired <- acquireReviewConnection client
    case acquired of
      Left message -> pure (Left message)
      Right connection -> case client.reviewBackend.backendProtocol of
        AppServerProtocol -> sendRequest client connection (PendingThreadStart issueNumber) "thread/start" (threadParams assignment)
        StreamJsonProtocol -> openStreamedReview client connection issueNumber
  where
    threadParams assignment =
      object
        [ "cwd" .= client.reviewRepositoryRoot,
          "model" .= assignment.assignmentModel,
          "approvalPolicy" .= ("on-request" :: Text),
          "sandbox" .= ("read-only" :: Text),
          "ephemeral" .= False,
          "developerInstructions" .= reviewDeveloperInstructions client.reviewWorkflowConfig client.reviewModelRoster,
          "dynamicTools" .= (adapterFor embeddedReviewProvider).adapterReviewTools client.reviewModelRoster client.reviewWorkflowConfig
        ]

-- | Open a review on a backend whose process /is/ the thread.
--
-- There is nothing to create: the connection was spawned for this review
-- alone, and the review begins by writing its first user message. The
-- session id the provider announces on the way back is what finally names
-- the thread, which is why the issue is recorded as a pending start exactly
-- as a @thread\/start@ request records it — under an id nothing ever writes
-- to the wire, because it is not a request. That record is what a connection
-- dying before the announcement reports the review by, and what the
-- announcement itself takes when it arrives.
openStreamedReview :: ReviewClient -> ReviewConnection -> Int -> IO (Either Text ())
openStreamedReview client connection issueNumber = do
  pendingId <- nextRequestId connection
  modifyMVar_ connection.connectionPendingRequests (pure . Map.insert pendingId (PendingThreadStart issueNumber))
  sent <- sendValue client connection (streamUserMessage (reviewPrompt issueNumber))
  case sent of
    Right () -> pure (Right ())
    Left message -> do
      -- The caller is told, so nothing is left to report this review by.
      modifyMVar_ connection.connectionPendingRequests (pure . Map.delete pendingId)
      -- A per-thread connection was spawned for this review and will now
      -- never serve a thread, so nothing else would ever stop it. A shared
      -- one is left alone for the same reason the app-server path leaves
      -- it: every other review is on it.
      when (client.reviewBackend.backendProcessShape == ProcessPerThread) (stopReviewConnection connection)
      pure (Left message)

sendReviewMessage :: ReviewClient -> ReviewThreadId -> Maybe Text -> Text -> IO (Either Text ())
sendReviewMessage client threadId activeTurnId = case activeTurnId of
  -- Redirecting a turn already in flight. The app-server has an operation
  -- for it; the CLI's channel has none at all (D-16), and what replaces it
  -- is MODEL-16's, so until then a message typed mid-turn is refused rather
  -- than written as a request the process on the other end cannot read.
  Just turnId -> \message -> case client.reviewBackend.backendProtocol of
    StreamJsonProtocol -> pure (Left (unsupportedOperation client "steer a running turn"))
    AppServerProtocol ->
      withThreadConnection client threadId $ \connection ->
        sendRequest client connection (PendingSteer threadId turnId message) "turn/steer" (steerParams turnId message)
  Nothing -> sendTurnStart client threadId
  where
    steerParams turnId message =
      object
        [ "threadId" .= threadId.reviewThreadProvider,
          "expectedTurnId" .= turnId,
          "input" .= [textInput message]
        ]

-- | Run an action against the connection a thread lives on. A thread that
-- names a connection this client no longer holds is a connection that has
-- ended, which is a refusal rather than a write to somebody else's process.
withThreadConnection :: ReviewClient -> ReviewThreadId -> (ReviewConnection -> IO (Either Text a)) -> IO (Either Text a)
withThreadConnection client threadId = withConnection client threadId.reviewThreadConnection

withConnection :: ReviewClient -> ConnectionId -> (ReviewConnection -> IO (Either Text a)) -> IO (Either Text a)
withConnection client identifier action = do
  found <- lookupConnection client.reviewConnections identifier
  case found of
    Nothing -> pure (Left (connectionGoneMessage client))
    Just connection -> action connection

answerReviewQuestion :: ReviewClient -> ReviewRequestId -> ReviewAnswer -> IO (Either Text ())
answerReviewQuestion client requestIdentity answer =
  withConnection client requestIdentity.reviewRequestConnection $ \connection ->
    sendValue client connection
      . object
      $ [ "id" .= requestIdentity.reviewRequestWireId,
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
approveReviewAction client requestIdentity accepted forSession =
  withConnection client requestIdentity.reviewRequestConnection $ \connection ->
    sendValue client connection
      . object
      $ [ "id" .= requestIdentity.reviewRequestWireId,
          "result" .= object ["decision" .= decision]
        ]
  where
    decision :: Text
    decision
      | not accepted = "decline"
      | forSession = "acceptForSession"
      | otherwise = "accept"

-- | Cancel a running turn. The CLI does have an operation for this -- a
-- @control_request@ (D-16) -- but driving it is MODEL-16's, so until then
-- this refuses rather than writing the app-server's request into a process
-- that would read it as ordinary input.
interruptReview :: ReviewClient -> ReviewThreadId -> Text -> IO (Either Text ())
interruptReview client threadId turnId = case client.reviewBackend.backendProtocol of
  StreamJsonProtocol -> pure (Left (unsupportedOperation client "interrupt a turn"))
  AppServerProtocol ->
    withThreadConnection client threadId $ \connection ->
      sendRequest
        client
        connection
        PendingOther
        "turn/interrupt"
        (object ["threadId" .= threadId.reviewThreadProvider, "turnId" .= turnId])

unsupportedOperation :: ReviewClient -> Text -> Text
unsupportedOperation client = unsupportedReviewOperationMessage client.reviewBackend.backendLabel

-- | What one connection's end has to reach: the tool calls its own threads
-- started, and its own recorded process group — using the same best-effort
-- primitive ('killManagedProcess') regardless of whether the leader handle
-- has already been reaped. Shared by every natural-crash terminal path
-- ('watchServerProcess', 'readServerOutput'), so a connection that is about
-- to be discarded (see @ReviewClientStopped@ handling in "Kanban.UI") never
-- leaves an in-flight tool call or a surviving group member unsignalled.
--
-- A shared-process backend's connection ending is the whole client ending,
-- so it closes the tool registry outright and nothing may reserve against it
-- again. One of several per-thread connections ending is not: the registry
-- stays open for the threads still running on other connections, and only
-- this connection's entries are killed.
terminalConnectionCleanup :: ReviewClient -> ReviewConnection -> IO ()
terminalConnectionCleanup client connection = do
  case client.reviewBackend.backendProcessShape of
    SharedProcess -> do
      toolProcesses <- drainToolRegistry client.reviewToolRegistry
      mapM_ killManagedProcess toolProcesses
    ProcessPerThread -> killConnectionToolProcesses client.reviewToolRegistry connection.connectionId
  killManagedProcess connection.connectionManaged

-- | Stop the whole client: every connection it holds, every tool process any
-- of them started, and every loop any of them forked.
--
-- The pool is closed in the same step that empties it, so a review starting
-- concurrently either reserved its slot before that close — and then owns
-- stopping what it spawned, because 'attachConnection' refuses it (see
-- 'spawnReviewConnection') — or is refused outright and spawns nothing.
-- Killing every connection before waiting on any keeps the waits concurrent
-- rather than serialized behind each kill.
stopReviewClient :: ReviewClient -> IO ()
stopReviewClient client = do
  toolProcesses <- drainToolRegistry client.reviewToolRegistry
  mapM_ killManagedProcess toolProcesses
  connections <- drainConnectionPool client.reviewConnections
  mapM_ stopReviewConnection connections
  mapM_ awaitConnectionReaders connections
  -- A shared-process client's transcript was closed by the watcher above,
  -- which is the only path a crashed client ever reaches; a per-thread
  -- client's is still open, and this is where that client ends.
  when (client.reviewBackend.backendProcessShape == ProcessPerThread) (closeReviewLog client.reviewSessionLog)

closeReviewLog :: Maybe SessionLog -> IO ()
closeReviewLog = mapM_ closeSessionLog

sendRequest :: ReviewClient -> ReviewConnection -> PendingRequest -> Text -> Value -> IO (Either Text ())
sendRequest client connection pending method params = do
  requestId <- nextRequestId connection
  modifyMVar_ connection.connectionPendingRequests (pure . Map.insert requestId pending)
  result <- sendValue client connection (object ["method" .= method, "id" .= requestId, "params" .= params])
  case result of
    Right () -> pure (Right ())
    Left message -> do
      modifyMVar_ connection.connectionPendingRequests (pure . Map.delete requestId)
      pure (Left message)

sendTurnStart :: ReviewClient -> ReviewThreadId -> Text -> IO (Either Text ())
sendTurnStart client threadId prompt =
  withThreadConnection client threadId (\connection -> sendTurnStartOn client connection threadId prompt)

-- | 'sendTurnStart' for a caller that already holds the thread's connection:
-- the response handler, which is running on it.
--
-- A turn is opened the way its channel opens one. The app-server takes a
-- request carrying this turn's effort and output schema; the CLI took both
-- as launch flags and holds them for the process's whole life (D-15), so
-- there is nothing to send but the message itself, and the @init@ record it
-- answers with is what announces the turn.
sendTurnStartOn :: ReviewClient -> ReviewConnection -> ReviewThreadId -> Text -> IO (Either Text ())
sendTurnStartOn client connection threadId prompt = case backendAssignment client of
  Left message -> pure (Left message)
  Right assignment -> case client.reviewBackend.backendProtocol of
    AppServerProtocol -> sendRequest client connection (PendingTurnStart threadId) "turn/start" (params assignment)
    StreamJsonProtocol -> sendValue client connection (streamUserMessage prompt)
  where
    params assignment =
      object
        [ "threadId" .= threadId.reviewThreadProvider,
          "effort" .= assignment.assignmentEffort,
          "input" .= [textInput prompt],
          "outputSchema" .= finalOutputSchema
        ]

textInput :: Text -> Value
textInput value = object ["type" .= ("text" :: Text), "text" .= value]

-- | The next JSON-RPC id on one connection. Per-connection because the ids
-- are: two connections numbering from the same start off one counter would
-- resolve each other's pending entries.
nextRequestId :: ReviewConnection -> IO Int
nextRequestId connection = atomicModifyIORef' connection.connectionNextRequestId (\current -> (current + 1, current))

sendValue :: ReviewClient -> ReviewConnection -> Value -> IO (Either Text ())
sendValue client connection value = do
  mapM_ (\sessionLog -> logRawLine sessionLog "stdin" (LazyByteString.toStrict (encode value))) client.reviewSessionLog
  result <-
    try
      ( withMVar connection.connectionWriteLock $ \() -> do
          LazyByteString.hPutStr connection.connectionInput (encode value)
          LazyByteString.hPutStr connection.connectionInput "\n"
          hFlush connection.connectionInput
      ) :: IO (Either IOException ())
  pure $ case result of
    Left exception -> Left (backendSentence client <> " write failed: " <> exceptionText exception)
    Right () -> Right ()

-- | Read one connection's output to its end, interpreting each line the way
-- its backend's protocol says to.
--
-- The protocol is read once, here, rather than per line: which decoder a
-- connection uses is fixed when it is spawned, and a dispatch inside the
-- loop would suggest it could change mid-stream.
readProviderOutput :: ReviewClient -> ReviewConnection -> IORef (Maybe ReviewThreadId) -> Handle -> IO ()
readProviderOutput client connection streamThread outputHandle = do
  result <- try (forever readOne) :: IO (Either IOException ())
  case result of
    Left exception -> do
      terminalConnectionCleanup client connection
      reportConnectionStopped client connection (backendSentence client <> " output closed: " <> exceptionText exception)
    Right () -> pure ()
  where
    interpret = case client.reviewBackend.backendProtocol of
      AppServerProtocol -> \line -> case decodeReviewWireMessage line of
        Left message -> emitProtocolWarning client message
        Right wireMessage -> handleWireMessage client connection wireMessage
      StreamJsonProtocol -> \line -> case decodeStreamRecord line of
        Left detail -> emitProtocolWarning client (streamDiagnostic client detail)
        Right record -> handleStreamRecord client connection streamThread record
    readOne = do
      strictLine <- ByteString.hGetLine outputHandle
      mapM_ (\sessionLog -> logRawLine sessionLog "stdout" strictLine) client.reviewSessionLog
      interpret (LazyByteString.fromStrict strictLine)

readProviderErrors :: ReviewClient -> ReviewConnection -> IORef (Maybe ReviewThreadId) -> Handle -> IO ()
readProviderErrors client connection streamThread errorHandle = do
  result <- try (forever readOne) :: IO (Either IOException ())
  case result of
    Left _ -> pure ()
    Right () -> pure ()
  where
    readOne = do
      strictLine <- ByteString.hGetLine errorHandle
      mapM_ (\sessionLog -> logRawLine sessionLog "stderr" strictLine) client.reviewSessionLog
      let line = LazyByteString.fromStrict strictLine
      threadId <- diagnosticThread connection streamThread
      client.reviewEventSink (ReviewOutput threadId DiagnosticOutput (decodeLine line))

-- | The thread a connection's stderr is reported against.
--
-- A process that multiplexes every thread writes its diagnostics for the
-- whole process rather than for one of them, so there is no thread to name:
-- the empty provider id no session claims reaches the transcript of nothing,
-- which is what this did before a connection had an identity at all. A
-- process serving one review thread is the opposite case — everything it
-- writes to stderr belongs to that thread — so once its stream has named the
-- thread, that is where its diagnostics go.
diagnosticThread :: ReviewConnection -> IORef (Maybe ReviewThreadId) -> IO ReviewThreadId
diagnosticThread connection streamThread =
  fromMaybe (ReviewThreadId connection.connectionId "") <$> readIORef streamThread

-- | Turn one decoded stream-json record into what it means for this
-- connection's review.
--
-- The thread, turn, transcript and completion the app-server's own
-- notifications carry, out of a stream that has none of their names: the CLI
-- re-emits its @init@ record at the head of every turn, so the first one is
-- where a review's thread becomes nameable and each later one opens a turn
-- on the thread already named. The two events a review can also end in —
-- a start that never produced a thread, and a connection that stopped — are
-- 'reportConnectionStopped''s, because they are things a stream stopping
-- means rather than things it says.
handleStreamRecord :: ReviewClient -> ReviewConnection -> IORef (Maybe ReviewThreadId) -> StreamRecord -> IO ()
handleStreamRecord client connection streamThread record = case record of
  StreamIgnored -> pure ()
  StreamTurnOpened providerThreadId turnId -> do
    let threadId = ReviewThreadId connection.connectionId providerThreadId
    writeIORef streamThread (Just threadId)
    -- Taken rather than read: the review has arrived, and an entry left
    -- behind would let this connection's death report a review that is
    -- already running as one that never started.
    opening <- takePendingThreadStarts connection
    mapM_ (announceThread threadId) opening
    modifyMVar_ client.reviewActiveTurns (pure . Map.insert threadId turnId)
    client.reviewEventSink (ReviewTurnStarted threadId turnId)
  StreamDelta outputKind text ->
    onNamedThread "streamed output" (\threadId -> client.reviewEventSink (ReviewOutput threadId outputKind text))
  StreamTurnClosed outcome -> onNamedThread "a turn result" $ \threadId -> do
    modifyMVar_ client.reviewActiveTurns (pure . Map.delete threadId)
    client.reviewEventSink $ case outcome of
      StreamVerdict text result -> ReviewTurnCompleted threadId TurnSucceeded Nothing (Just (text, result))
      StreamTurnFailure detail -> ReviewTurnCompleted threadId TurnFailed (Just (streamDiagnostic client detail)) Nothing
  where
    announceThread threadId issueNumber = do
      modifyMVar_ client.reviewThreadIssues (pure . Map.insert threadId issueNumber)
      client.reviewEventSink (ReviewThreadCreated issueNumber threadId)
    -- Everything but the opening record belongs to a thread the stream has
    -- already named. One that arrives before it is a protocol warning rather
    -- than an event attributed to a guess.
    onNamedThread what action = do
      named <- readIORef streamThread
      case named of
        Just threadId -> action threadId
        Nothing -> emitProtocolWarning client (streamDiagnostic client ("sent " <> what <> " before naming its session"))

-- | Report the end of one connection.
--
-- A shared-process backend multiplexes every thread onto its one connection,
-- so that connection ending /is/ the client ending and the client-wide event
-- is the accurate one. It reaches every live session, including one still
-- waiting for its first thread, so nothing needs naming separately.
--
-- A per-thread backend's client outlives its connections: only the threads
-- this one served are finished, and a new review may still be started, so the
-- connection is named and the client is left alone. That event can only reach
-- a session through the thread it is running on — which is exactly what a
-- review whose @thread\/start@ was still in flight never got. Such a review
-- would otherwise sit at "starting" for good, with no connection behind it,
-- so it is reported first and by issue number, the same way every other
-- never-started review is.
reportConnectionStopped :: ReviewClient -> ReviewConnection -> Text -> IO ()
reportConnectionStopped client connection message = case client.reviewBackend.backendProcessShape of
  SharedProcess -> client.reviewEventSink (ReviewClientStopped message)
  ProcessPerThread -> do
    abandoned <- takePendingThreadStarts connection
    mapM_ (\issueNumber -> client.reviewEventSink (ReviewStartFailed issueNumber message)) abandoned
    interrupted <- takeConnectionTurns client connection
    mapM_ (\threadId -> client.reviewEventSink (ReviewTurnCompleted threadId TurnFailed (Just message) Nothing)) interrupted
    client.reviewEventSink (ReviewConnectionStopped connection.connectionId message)

-- | Take the threads on this connection that had a turn running, removing
-- them from the active set.
--
-- A turn whose process died produced no verdict and never will, and a
-- session left holding a running turn would wait for a completion that
-- cannot arrive. Reported as that thread's own failed turn rather than as
-- anything client-wide: a per-thread backend's other connections are
-- untouched, and the threads on them are still running.
--
-- Taking, for the same reason the pending starts above are taken: a dying
-- connection reaches two terminal paths, and only one of them may report.
takeConnectionTurns :: ReviewClient -> ReviewConnection -> IO [ReviewThreadId]
takeConnectionTurns client connection =
  modifyMVar client.reviewActiveTurns $ \turns ->
    let (mine, rest) = Map.partitionWithKey (\threadId _ -> threadId.reviewThreadConnection == connection.connectionId) turns
     in pure (rest, Map.keys mine)

watchServerProcess :: ReviewClient -> ReviewConnection -> IO ()
watchServerProcess client connection = do
  exitCode <- waitForProcess connection.connectionProcess
  terminalConnectionCleanup client connection
  takeMVar connection.connectionOutputDone
  takeMVar connection.connectionErrorDone
  takeConnection client.reviewConnections connection.connectionId
  mapM_ (\sessionLog -> logMessage sessionLog "backend-finished" (renderExitCode client exitCode)) client.reviewSessionLog
  -- The transcript records the client's whole session rather than one
  -- process's share of it, so it is closed when the client is finished. A
  -- shared-process client is finished exactly here, when the connection every
  -- thread was on has ended -- including the crash path, which reaches no
  -- shutdown. A per-thread client outlives its connections and keeps the
  -- transcript open for the reviews still to come, so 'stopReviewClient'
  -- closes that one.
  when (client.reviewBackend.backendProcessShape == SharedProcess) (closeReviewLog client.reviewSessionLog)
  reportConnectionStopped client connection (renderExitCode client exitCode)
  -- Last, and after both reader signals above: this is the one signal
  -- 'stopReviewClient' waits on, so it must not be filled while any of this
  -- connection's loops could still run.
  putMVar connection.connectionWatchDone ()


-- | Dispatch one message, against the connection it arrived on. Every piece
-- of state it reaches — the pending requests the response resolves, the
-- identity the thread in a notification gets, the connection an answer to a
-- server request will be written back to — belongs to that connection and to
-- no other.
handleWireMessage :: ReviewClient -> ReviewConnection -> ReviewWireMessage -> IO ()
handleWireMessage client connection wireMessage = case wireMessage of
  WireResponse requestId result -> handleResponse client connection requestId result
  WireNotification method params -> handleNotification client connection method params
  WireRequest requestId method params -> handleServerRequest client connection requestId method params

handleResponse :: ReviewClient -> ReviewConnection -> Value -> Either Value Value -> IO ()
handleResponse client connection requestId result = case requestIdInt requestId of
  Nothing -> emitProtocolWarning client "Codex returned a non-numeric response id"
  Just integerId -> do
    pending <- modifyMVar connection.connectionPendingRequests $ \requests ->
      pure (Map.delete integerId requests, Map.lookup integerId requests)
    case (pending, result) of
      (Just (PendingThreadStart issueNumber), Right value) -> case resultThreadId value of
        Nothing -> client.reviewEventSink (ReviewStartFailed issueNumber "Codex thread/start response did not contain a thread id")
        Just providerThreadId -> do
          let threadId = ReviewThreadId connection.connectionId providerThreadId
          modifyMVar_ client.reviewThreadIssues (pure . Map.insert threadId issueNumber)
          client.reviewEventSink (ReviewThreadCreated issueNumber threadId)
          started <- sendTurnStartOn client connection threadId (reviewPrompt issueNumber)
          case started of
            Left message -> client.reviewEventSink (ReviewStartFailed issueNumber message)
            Right () -> pure ()
      (Just (PendingThreadStart issueNumber), Left err) -> do
        client.reviewEventSink (ReviewStartFailed issueNumber ("Codex could not create the review thread: " <> compactValue err))
        -- A per-thread connection was spawned for this review and no thread
        -- will ever be created on it, so nothing else would ever stop it.
        -- A shared connection is left alone: every other review is on it.
        when (client.reviewBackend.backendProcessShape == ProcessPerThread) (stopReviewConnection connection)
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
            resent <- sendTurnStartOn client connection threadId message
            case resent of
              Right () -> pure ()
              Left _ -> client.reviewEventSink (ReviewSteerUndelivered threadId targetTurnId message)
          Just _ -> client.reviewEventSink (ReviewSteerUndelivered threadId targetTurnId message)
      (_, Left err) -> emitProtocolWarning client ("Codex request failed: " <> compactValue err)
      _ -> pure ()

handleNotification :: ReviewClient -> ReviewConnection -> Text -> Value -> IO ()
handleNotification client connection method params = case method of
  "turn/started" -> case (notifiedThread params, nestedText ["turn", "id"] params) of
    (Just threadId, Just turnId) -> do
      modifyMVar_ client.reviewActiveTurns (pure . Map.insert threadId turnId)
      client.reviewEventSink (ReviewTurnStarted threadId turnId)
    _ -> emitProtocolWarning client "turn/started omitted its thread or turn id"
  "item/agentMessage/delta" -> emitDelta AgentOutput
  "item/commandExecution/outputDelta" -> emitDelta CommandOutput
  "item/reasoning/summaryTextDelta" -> emitDelta ReasoningOutput
  "turn/completed" -> case notifiedThread params of
    Nothing -> emitProtocolWarning client "turn/completed omitted its thread id"
    Just threadId -> do
      modifyMVar_ client.reviewActiveTurns (pure . Map.delete threadId)
      client.reviewEventSink
        (ReviewTurnCompleted threadId (turnOutcome params) (nestedText ["turn", "error", "message"] params) (turnResult params))
  _ -> pure ()
  where
    -- The wire names a thread by the provider's own id, which is unique only
    -- within this connection; what the rest of Kanban keys by is the pair.
    notifiedThread value = ReviewThreadId connection.connectionId <$> fieldText "threadId" value
    emitDelta outputKind = case (notifiedThread params, fieldText "delta" params) of
      (Just threadId, Just delta) -> client.reviewEventSink (ReviewOutput threadId outputKind delta)
      _ -> pure ()

handleServerRequest :: ReviewClient -> ReviewConnection -> Value -> Text -> Value -> IO ()
handleServerRequest client connection requestId method params = case method of
  "item/tool/call"
    | fieldText "tool" params == Just questionToolName -> case (requestingThread params, objectField "arguments" params) of
        (Just threadId, Just arguments) -> case parseQuestionValue arguments of
          Right question -> client.reviewEventSink (ReviewQuestionRequested threadId wrappedId question)
          Left message -> do
            void (sendDynamicToolFailure client connection wrappedId message)
            emitProtocolWarning client message
        _ -> void (sendDynamicToolFailure client connection wrappedId "Question tool call omitted its thread id or arguments")
    | fieldText "tool" params == Just claudeToolName -> case (requestingThread params, objectField "arguments" params) of
        (Just threadId, Just arguments) -> case parseClaudeToolRequest arguments of
          Left message -> do
            void (sendDynamicToolFailure client connection wrappedId message)
            emitProtocolWarning client message
          Right claudeRequest ->
            void
              . forkIO
              $ runClaudeToolCall client connection threadId wrappedId claudeRequest
        _ -> void (sendDynamicToolFailure client connection wrappedId "Claude tool call omitted its thread id or arguments")
    | fieldText "tool" params == Just githubToolName -> case (requestingThread params, objectField "arguments" params) of
        (Just threadId, Just arguments) -> case decodeGitHubIssueToolRequest client.reviewWorkflowConfig arguments of
          Left message -> do
            void (sendDynamicToolFailure client connection wrappedId message)
            emitProtocolWarning client message
          Right githubRequest -> do
            authorized <- githubRequestMatchesThread client threadId githubRequest
            if authorized
              then
                void
                  . forkIO
                  $ runGitHubToolCall client connection threadId wrappedId githubRequest
              else do
                let message = "kanban_github_issue may only access the issue owned by this review thread"
                void (sendDynamicToolFailure client connection wrappedId message)
                emitProtocolWarning client message
        _ -> void (sendDynamicToolFailure client connection wrappedId "GitHub issue tool call omitted its thread id or arguments")
    | otherwise -> void (sendDynamicToolFailure client connection wrappedId "Kanban does not implement that dynamic tool")
  "item/commandExecution/requestApproval" -> emitApproval False
  "item/fileChange/requestApproval" -> emitApproval True
  _ -> do
    void (sendErrorResponse client connection requestId (-32601) ("Unsupported app-server request: " <> method))
    emitProtocolWarning client ("Unsupported app-server request: " <> method)
  where
    -- The connection travels with the wire id because the user may answer
    -- minutes later, by which time another connection may have issued a
    -- server request numbered the same.
    wrappedId = ReviewRequestId connection.connectionId requestId
    requestingThread value = ReviewThreadId connection.connectionId <$> fieldText "threadId" value
    emitApproval fileChange = case requestingThread params of
      Nothing -> void (sendErrorResponse client connection requestId (-32602) "Approval request omitted its thread id")
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

sendDynamicToolFailure :: ReviewClient -> ReviewConnection -> ReviewRequestId -> Text -> IO (Either Text ())
sendDynamicToolFailure client connection requestIdentity message =
  sendValue client connection
    ( object
        [ "id" .= requestIdentity.reviewRequestWireId,
          "result"
            .= object
              [ "success" .= False,
                "contentItems" .= [object ["type" .= ("inputText" :: Text), "text" .= message]]
              ]
        ]
    )

sendDynamicToolSuccess :: ReviewClient -> ReviewConnection -> ReviewRequestId -> Text -> IO (Either Text ())
sendDynamicToolSuccess client connection requestIdentity output =
  sendValue client connection
    ( object
        [ "id" .= requestIdentity.reviewRequestWireId,
          "result"
            .= object
              [ "success" .= True,
                "contentItems" .= [object ["type" .= ("inputText" :: Text), "text" .= output]]
              ]
        ]
    )

runClaudeToolCall :: ReviewClient -> ReviewConnection -> ReviewThreadId -> ReviewRequestId -> ClaudeToolRequest -> IO ()
runClaudeToolCall client connection threadId requestId request = do
  client.reviewEventSink (claudeStartedEvent client threadId)
  result <- withReservedToolSlot client threadId (\key -> runAuthenticatedClaude client key request.claudeToolPrompt)
  sent <- case result of
    Left message -> sendDynamicToolFailure client connection requestId message
    Right output -> sendDynamicToolSuccess client connection requestId output
  let completion = case (result, sent) of
        (Left message, _) -> Left message
        (_, Left message) -> Left message
        (Right _, Right ()) -> Right ()
  client.reviewEventSink (ReviewClaudeFinished threadId completion)

runGitHubToolCall :: ReviewClient -> ReviewConnection -> ReviewThreadId -> ReviewRequestId -> GitHubIssueToolRequest -> IO ()
runGitHubToolCall client connection threadId requestId request = do
  client.reviewEventSink (ReviewGitHubStarted threadId (githubActionSummary request))
  result <- withReservedToolSlot client threadId (\key -> runGitHubIssueTool client key request)
  sent <- case result of
    Left message -> sendDynamicToolFailure client connection requestId message
    Right output -> sendDynamicToolSuccess client connection requestId output
  let completion = case (result, sent) of
        (Left message, _) -> Left message
        (_, Left message) -> Left message
        (Right output, Right ()) -> Right output
  client.reviewEventSink (ReviewGitHubFinished threadId completion)

sendErrorResponse :: ReviewClient -> ReviewConnection -> Value -> Int -> Text -> IO (Either Text ())
sendErrorResponse client connection requestId code message =
  sendValue client connection (object ["id" .= requestId, "error" .= object ["code" .= code, "message" .= message]])

githubRequestMatchesThread :: ReviewClient -> ReviewThreadId -> GitHubIssueToolRequest -> IO Bool
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

renderExitCode :: ReviewClient -> ExitCode -> Text
renderExitCode client ExitSuccess = backendSentence client <> " exited"
renderExitCode client (ExitFailure code) = backendSentence client <> " exited with status " <> Text.pack (show code)

-- | The backend's label at the start of a sentence.
backendSentence :: ReviewClient -> Text
backendSentence client = sentenceCase client.reviewBackend.backendLabel

-- | A diagnostic "Kanban.Review.Stream" produced, completed by the backend
-- that is speaking the channel it decoded. The decoder knows the protocol
-- and this knows who is running it; neither knows both, which is what stops
-- either from naming a provider it guessed.
streamDiagnostic :: ReviewClient -> Text -> Text
streamDiagnostic client = reviewSessionDiagnostic client.reviewBackend.backendLabel

ignoreIOException :: IO () -> IO ()
ignoreIOException action = do
  _ <- try action :: IO (Either IOException ())
  pure ()

initializationTimeoutMicros :: Int
initializationTimeoutMicros = 10 * 1000 * 1000
