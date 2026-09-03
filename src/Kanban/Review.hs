-- | The embedded issue-review client: connection startup and shutdown, the
-- reader threads, and the dispatch of everything a provider sends back —
-- including routing a tool call to "Kanban.Review.Tools" and answering it,
-- whether it arrived as an app-server request on the provider's own wire or
-- as a frame forwarded by the stdio MCP re-entry a stream-json backend's
-- tools go over ('serveConnectionToolCalls', D-15).
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
    InterruptAcknowledgement (..),
    InterruptSettlement (..),
    InterruptTarget (..),
    IssueReviewerRecord (..),
    IssueReviewerSource (..),
    PendingInterrupt (..),
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
    ReviewToolServerLaunch (..),
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
    canonicalLaunchOutcome,
    claudeCommandBounds,
    claudeReviewArguments,
    claudeStartedEvent,
    claudeTool,
    claudeToolName,
    decodeCanonicalIssueReviewResult,
    decodeClaudeToolPrompt,
    decodeGitHubIssueToolRequest,
    decodeReviewQuestion,
    decodeReviewResult,
    decodeReviewWireMessage,
    decodeStreamRecord,
    drainToolRegistry,
    embeddedReviewProvider,
    embeddedReviewCell,
    embeddedReviewProviderFor,
    finalOutputSchema,
    finishReviewThread,
    githubCommandBounds,
    githubIssueCommentArguments,
    githubIssueEditArguments,
    authenticatedClaudeArguments,
    githubIssueViewArguments,
    githubToolName,
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
    reviewClientLogPath,
    reviewConnectionProcesses,
    reviewThreadOwnProcesses,
    reviewConnectionsForTesting,
    reviewDeveloperInstructions,
    newToolRegistry,
    outcomeUnknownDiagnostic,
    pendingInterrupt,
    questionToolName,
    releaseToolSlot,
    renderCanonicalIssueReviewResult,
    reserveToolSlot,
    resolveCanonicalIssueReviewer,
    resolveCanonicalIssueReviewerAt,
    reviewStageForLabels,
    reviewTurnResumable,
    settleInterrupt,
    streamInterruptRequest,
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

import Control.Concurrent (MVar, forkIO, modifyMVar, modifyMVar_, newMVar, putMVar, takeMVar, threadDelay, withMVar)
import Control.Concurrent.MVar (readMVar)
import Control.Exception (IOException, try)
import Control.Monad (forM_, forever, void, when)
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
import Data.IORef (atomicModifyIORef')
import qualified Data.Map.Strict as Map
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
import Kanban.Process (ManagedProcess, killManagedProcess, managedProcess)
import Kanban.ProviderAdapter
  ( EmbeddedReviewBackend (..),
    ProviderAdapter (..),
    ReviewLaunch (..),
    ReviewProcessShape (..),
    ReviewProtocol (..),
    ReviewToolServerLaunch (..),
    adapterFor,
    claudeReviewArguments,
    embeddedReviewProvider,
    embeddedReviewProviderFor,
  )
import Kanban.Review.Canonical
  ( IssueReviewerRecord (..),
    IssueReviewerSource (..),
    canonicalCommandBounds,
    canonicalIssueReviewArguments,
    canonicalIssueReviewerPath,
    canonicalLaunchOutcome,
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
  ( InterruptAcknowledgement (..),
    InterruptSettlement (..),
    InterruptTarget (..),
    PendingInterrupt (..),
    ReviewClient (..),
    ReviewToolProxy (..),
    ToolRegistry,
    attachToolProcess,
    destroyReviewToolProxy,
    drainReviewToolProxies,
    drainToolRegistry,
    emitProtocolWarning,
    killConnectionToolProcesses,
    killConnectionToolProcesses,
    killReviewTools,
    killThreadToolProcesses,
    newToolRegistry,
    pendingInterrupt,
    registerReviewToolProxy,
    releaseToolSlot,
    reserveToolSlot,
    settleInterrupt,
    takeReviewToolProxy,
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
    reviewOpeningMessage,
    reviewPrompt,
  )
import Kanban.ReviewToolServer
  ( ReviewToolEndpoint (..),
    createReviewToolEndpoint,
    decodeEndpointCall,
    mcpToolDescriptor,
    mcpToolResult,
    proxyError,
    proxyResult,
    readEndpointCall,
    teardownReviewToolEndpoint,
    writeEndpointReply,
  )
import Kanban.Review.Stream
  ( StreamRecord (..),
    StreamTurnResult (..),
    decodeStreamRecord,
    streamInterruptRequest,
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
  ( reviewTurnResumable, CanonicalIssueReviewResult (..),
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
import Kanban.Transcript (SessionLog, closeSessionLog, logMessage, logRawLine, openSessionLog, sessionLogPath)
import System.Environment (getExecutablePath)
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
-- | The cell the embedded review backend will actually start on.
--
-- One expression, named, because three places have to agree about it and two
-- of them are not the spawn: 'startReviewClient' refuses on it before any
-- process exists, the processes overlay labels the repository review host and
-- its children with it, and a test pins it. Resolving it separately anywhere
-- is how a boundary comes to refuse a roster the spawn would have accepted,
-- or to name a provider the host would never have started.
--
-- The provider half is 'embeddedReviewProviderFor', which is the adapter's
-- routing and not a brand chosen here (requirement 8).
embeddedReviewCell :: ModelRoster -> Either Text Assignment
embeddedReviewCell roster = issueReviewAssignment (embeddedReviewProviderFor roster) roster

issueReviewAssignment :: ProviderName -> ModelRoster -> Either Text Assignment
issueReviewAssignment provider roster =
  either (Left . assignmentUnavailableMessage) Right (assignmentFor roster IssueReviewRole provider)

-- | The cell a running client's own backend resolves.
--
-- Read through the backend rather than through
-- 'Kanban.ProviderAdapter.embeddedReviewProvider' because everything
-- downstream of it belongs to the provider that started:
-- Codex's model and effort travel in @thread\/start@ and @turn\/start@,
-- Claude's are argv (D-15), and the refusal a roster that cannot supply the
-- cell produces has to name the provider whose backend is being refused.
backendAssignment :: ReviewClient -> Either Text Assignment
backendAssignment client =
  issueReviewAssignment client.reviewBackend.backendProvider client.reviewModelRoster

-- | Start the embedded review on the provider this install routes it to.
--
-- The provider comes off the roster the cell is looked up in, the same way
-- 'Kanban.PullRequestFlow.pullRequestAssignment' takes its mode, so the
-- backend that starts and the @issue_review@ cell it runs on cannot be
-- resolved against two different rosters — and through the same
-- 'embeddedReviewProviderFor' the dashboard's own launch boundary refuses on,
-- so a roster it allowed cannot be one this refuses.
startReviewClient :: ModelRoster -> WorkflowConfig -> Repository -> (ManagedProcess -> IO ()) -> (ReviewEvent -> IO ()) -> IO (Either Text ReviewClient)
startReviewClient roster workflowConfig repository processRegistered eventSink = case embeddedReviewCell roster of
  -- Resolved before the backend is spawned, not after: a roster that loads
  -- no cell for the routed provider must start no process at all, and the
  -- backend's own failure surface already carries the reason to the UI. The
  -- cell is consulted first and the backend second, in that order, because
  -- that is the order the refusals were already reached in.
  Left message -> pure (Left message)
  Right _ -> case (adapterFor provider).adapterEmbeddedReview of
    Nothing -> pure (Left (missingEmbeddedReviewMessage provider))
    Just backend -> startResolvedReviewClient backend roster workflowConfig repository processRegistered eventSink
  where
    provider = embeddedReviewProviderFor roster

-- | Start a client against a chosen backend, rather than the one
-- 'Kanban.ProviderAdapter.embeddedReviewProvider' resolves. Exported so a
-- test can drive either process shape without a provider shipping it:
-- nothing in production calls this except 'startReviewClient' above.
startResolvedReviewClient :: EmbeddedReviewBackend -> ModelRoster -> WorkflowConfig -> Repository -> (ManagedProcess -> IO ()) -> (ReviewEvent -> IO ()) -> IO (Either Text ReviewClient)
startResolvedReviewClient backend roster workflowConfig repository processRegistered eventSink = do
  logResult <- openSessionLog repository "issue-revision-appserver" 0 Nothing
  sessionLog <- case logResult of
    Left message -> eventSink (ReviewProtocolWarning backend.backendProvider message) >> pure Nothing
    Right value -> logMessage value "backend-started" backend.backendLabel >> pure (Just value)
  connections <- newConnectionPool
  activeTurns <- newMVar Map.empty
  interrupts <- newMVar Map.empty
  threadIssues <- newMVar Map.empty
  toolRegistry <- newToolRegistry
  toolProxies <- newMVar Map.empty
  let client =
        ReviewClient
          { reviewBackend = backend,
            reviewProcessRegistered = processRegistered,
            reviewConnections = connections,
            reviewActiveTurns = activeTurns,
            reviewInterrupts = interrupts,
            reviewThreadIssues = threadIssues,
            reviewToolRegistry = toolRegistry,
            reviewToolProxies = toolProxies,
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
      started <- startReviewConnection client Nothing
      case started of
        Left message -> closeReviewLog sessionLog >> pure (Left message)
        Right _ -> pure (Right client)

-- | The connection that serves a new review thread: the one this client
-- already holds when its backend shares a process across every thread, or a
-- freshly spawned one when the backend gives each thread its own.
--
-- The issue travels into a per-thread spawn because that spawn may create
-- this thread's tool endpoint, and the endpoint is bound to the one issue
-- its review owns rather than to anything a caller could later claim.
acquireReviewConnection :: ReviewClient -> Int -> IO (Either Text ReviewConnection)
acquireReviewConnection client issueNumber = case client.reviewBackend.backendProcessShape of
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
  ProcessPerThread -> startReviewConnection client (Just issueNumber)

-- | Reserve a slot and spawn a connection into it. @reviewIssue@ is the one
-- issue the connection will serve where the backend gives each review its
-- own process, and 'Nothing' for a shared-process backend's startup spawn,
-- which serves no review yet.
startReviewConnection :: ReviewClient -> Maybe Int -> IO (Either Text ReviewConnection)
startReviewConnection client reviewIssue = do
  reserved <- reserveConnectionSlot client.reviewConnections
  case reserved of
    ConnectionPoolClosed -> pure (Left (clientShuttingDownMessage client))
    ReservedConnection identifier -> spawnReviewConnection client identifier reviewIssue

-- | Start one provider process, complete its handshake, and register it.
--
-- The readers are forked before the connection is attached, so anything that
-- later finds it in the pool — shutdown above all — may wait on its
-- completion signal unconditionally. A failure before that point is cleaned
-- up here and releases the reservation, because nothing else has ever seen
-- it — including the tool endpoint a stream-json spawn creates ahead of its
-- process, which every failure path below unlinks before reporting.
spawnReviewConnection :: ReviewClient -> ConnectionId -> Maybe Int -> IO (Either Text ReviewConnection)
spawnReviewConnection client identifier reviewIssue = case backendAssignment client of
  -- Resolved before the process, not after: a backend whose argv carries the
  -- roster's model and effort cannot be launched without them, and one that
  -- carries them on the wire would only reach the same refusal a moment
  -- later with a provider process already running.
  Left message -> abandonSlot message
  Right assignment -> do
    prepared <- prepareToolServer client
    case prepared of
      Left message -> abandonSlot message
      Right toolServer -> do
        let processSpec = client.reviewBackend.backendProcess (ReviewLaunch client.reviewRepositoryRoot assignment (snd <$> toolServer))
        started <- try (createProcess processSpec) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
        case started of
          Left exception -> abandonEndpoint toolServer >> abandonSlot ("Could not start " <> label <> ": " <> exceptionText exception)
          Right (Just inputHandle, Just outputHandle, Just errorHandle, processHandle) -> do
            hSetBuffering inputHandle LineBuffering
            hSetBuffering outputHandle LineBuffering
            (processManaged, groupLeaderProblem) <- managedProcess processHandle
            -- Registered with whoever owns this client before the connection
            -- is even built, so no window exists in which this process is
            -- running and nothing durable names it.
            client.reviewProcessRegistered processManaged
            mapM_ (\value -> mapM_ (logMessage value "group-leadership-unverified") groupLeaderProblem) client.reviewSessionLog
            connection <- newReviewConnection identifier inputHandle processHandle processManaged
            -- What this connection's two readers share. Held beside the
            -- connection rather than on it because it is the reader loops' own
            -- state, and in one place because they use it together: see
            -- 'StreamAttribution'.
            attribution <- newMVar (StreamAttribution Nothing [])
            initialized <- completeHandshake client connection outputHandle
            case initialized of
              Nothing -> abandonEndpoint toolServer >> abandonConnection connection (sentenceLabel <> " initialization timed out")
              Just (Left message) -> abandonEndpoint toolServer >> abandonConnection connection message
              Just (Right ()) -> do
                -- Registered before the watcher is forked, so from here on
                -- the connection's own terminal cleanup owns the proxy —
                -- including the refused-attachment path below, whose
                -- 'stopReviewConnection' the watcher answers.
                mapM_
                  ( \(endpoint, _) -> do
                      server <- forkIO (serveConnectionToolCalls client connection attribution reviewIssue endpoint)
                      registerReviewToolProxy client identifier (ReviewToolProxy endpoint server)
                  )
                  toolServer
                markConnectionReadersStarted connection
                void (forkIO (readProviderOutput client connection attribution outputHandle >> putMVar connection.connectionOutputDone ()))
                void (forkIO (readProviderErrors client connection attribution errorHandle >> putMVar connection.connectionErrorDone ()))
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
          Right _ -> abandonEndpoint toolServer >> abandonSlot (sentenceLabel <> " did not provide all three standard streams")
  where
    label = client.reviewBackend.backendLabel
    sentenceLabel = sentenceCase label
    abandonSlot message = do
      releaseConnectionSlot client.reviewConnections identifier
      pure (Left message)
    abandonConnection connection message = do
      stopReviewConnection connection
      abandonSlot message
    abandonEndpoint = mapM_ (teardownReviewToolEndpoint . fst)

-- | What a spawn needs when its backend's tools go over the MCP re-entry
-- rather than inline: a fresh endpoint, and the launch record naming the
-- exact currently running executable against it.
--
-- Keyed on the protocol because the protocol is what decides the question:
-- the app-server takes its tools in @thread\/start@, and the stream-json
-- channel has no tool declaration at all, so a backend speaking it can only
-- be served this way (D-15).
prepareToolServer :: ReviewClient -> IO (Either Text (Maybe (ReviewToolEndpoint, ReviewToolServerLaunch)))
prepareToolServer client = case client.reviewBackend.backendProtocol of
  AppServerProtocol -> pure (Right Nothing)
  StreamJsonProtocol -> do
    created <- createReviewToolEndpoint
    case created of
      Left message -> pure (Left ("Could not create the review tool endpoint: " <> message))
      Right endpoint -> do
        executable <- getExecutablePath
        pure (Right (Just (endpoint, ReviewToolServerLaunch executable endpoint.endpointDirectory)))

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

-- | Settle one review thread and nothing else (SAG-10, requirement 11).
--
-- Which is the whole difficulty: what "one thread" owns depends on the
-- backend's process shape, and the two shapes have no common answer.
--
-- Under 'ProcessPerThread' the thread /is/ a process, so ending it means
-- taking its connection out of the pool and stopping it — the provider
-- process, its input handle, its tool subprocesses, and the tool re-entry
-- endpoint serving it. Under 'SharedProcess' every other live thread is
-- multiplexed onto that same connection, so stopping it would end them too;
-- there the thread owns only its tool subprocesses, and the connection is
-- deliberately left running.
--
-- The tool kill is common to both and runs first either way, because a
-- @kanban_run_claude@ CLI or a @gh@ call started by this thread is this
-- thread's descendant under either shape.
--
-- Never the client. A child action ending must not end the host or a sibling
-- (requirement 11), so this is the only teardown an action's termination is
-- allowed to reach; 'stopReviewClient' belongs to the host's own shutdown.
finishReviewThread :: ReviewClient -> ReviewThreadId -> IO ()
finishReviewThread client threadId = do
  -- The remote turn first, and only under a shared process.
  --
  -- Killing tool subprocesses and dropping bookkeeping stops nothing the
  -- provider is doing: under 'ProcessPerThread' that is fine, because the
  -- thread's whole process is torn down below, but under 'SharedProcess' the
  -- connection stays up by design and the turn simply keeps running. The
  -- action would be marked terminal while its provider went on working —
  -- spending quota, and reaching @kanban_github_issue@ — with no session left
  -- that could stop it.
  --
  -- Interrupting is the only operation that ends one thread's turn without
  -- touching the connection every sibling shares, which is why it is the one
  -- used here. Best-effort: a turn that has already ended refuses the
  -- interrupt, and that refusal is the outcome this wanted anyway.
  when (client.reviewBackend.backendProcessShape == SharedProcess) $ do
    running <- Map.lookup threadId <$> readMVar client.reviewActiveTurns
    forM_ running (void . interruptReview client threadId)
  killReviewTools client threadId
  modifyMVar_ client.reviewActiveTurns (pure . Map.delete threadId)
  modifyMVar_ client.reviewInterrupts (pure . Map.delete threadId)
  modifyMVar_ client.reviewThreadIssues (pure . Map.delete threadId)
  when (client.reviewBackend.backendProcessShape == ProcessPerThread) $ do
    let identifier = threadId.reviewThreadConnection
    found <- lookupConnection client.reviewConnections identifier
    takeConnection client.reviewConnections identifier
    mapM_ stopReviewConnection found
    proxy <- takeReviewToolProxy client identifier
    mapM_ destroyReviewToolProxy proxy

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
  interrupts <- newMVar Map.empty
  threadIssues <- newMVar Map.empty
  toolRegistry <- newToolRegistry
  toolProxies <- newMVar Map.empty
  let client =
        ReviewClient
          { reviewBackend = placeholderReviewBackend,
            reviewProcessRegistered = const (pure ()),
            reviewConnections = connections,
            reviewActiveTurns = activeTurns,
            reviewInterrupts = interrupts,
            reviewThreadIssues = threadIssues,
            reviewToolRegistry = toolRegistry,
            reviewToolProxies = toolProxies,
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
    createProcess (client.reviewBackend.backendProcess (ReviewLaunch client.reviewRepositoryRoot placeholderAssignment Nothing))
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

-- | Every provider process this client currently holds.
--
-- One for a shared-process backend, one per live review thread for a
-- process-per-thread one. The repository review host registers these with its
-- own supervisor so they are recorded, verifiable, and reachable by the
-- ordinary recovery path: a host that dies uncleanly otherwise leaves them
-- orphaned with nothing durable naming them.
reviewConnectionProcesses :: ReviewClient -> IO [ManagedProcess]
reviewConnectionProcesses client = map (.connectionManaged) <$> attachedConnections client.reviewConnections

-- | The process serving one thread, when that process is the thread's alone.
--
-- Under 'ProcessPerThread' a thread /is/ a process, so the action that owns
-- the thread owns the process too, and it is recorded on that action's own
-- durable state. That is what lets a termination or a stale-worker recovery
-- reach it with no host left to ask: a host registers these with its own
-- supervisor, and a supervisor that has died takes that record's usefulness
-- with it.
--
-- Under 'SharedProcess' this is deliberately empty. The one process serves
-- every thread, so recording it against a child would let that child's
-- termination kill every sibling — the opposite of requirement 11 — and
-- ending a thread there is 'finishReviewThread'\'s interrupt instead.
reviewThreadOwnProcesses :: ReviewClient -> ReviewThreadId -> IO [ManagedProcess]
reviewThreadOwnProcesses client threadId = case client.reviewBackend.backendProcessShape of
  SharedProcess -> pure []
  ProcessPerThread -> do
    connection <- lookupConnection client.reviewConnections threadId.reviewThreadConnection
    pure (maybe [] ((: []) . (.connectionManaged)) connection)

-- | Where this client writes the raw traffic that belongs to no one review
-- thread — the handshake, the diagnostics, a line it could not parse.
--
-- The repository review host records this as its /own/ log, because it is the
-- host's session rather than any child's. Each child keeps a raw log of the
-- traffic routed to it, which is what a shared-process backend's one
-- interleaved transcript cannot give any of them.
reviewClientLogPath :: ReviewClient -> Maybe FilePath
reviewClientLogPath client = sessionLogPath <$> client.reviewSessionLog

-- | A 'newReviewClientForTesting' whose one connection records what the
-- client writes to it.
newRecordingReviewClientForTesting :: ModelRoster -> (ReviewEvent -> IO ()) -> IO (ReviewClient, Handle)
newRecordingReviewClientForTesting roster eventSink = do
  connections <- newConnectionPool
  activeTurns <- newMVar Map.empty
  interrupts <- newMVar Map.empty
  threadIssues <- newMVar Map.empty
  toolRegistry <- newToolRegistry
  toolProxies <- newMVar Map.empty
  let client =
        ReviewClient
          { reviewBackend = placeholderReviewBackend,
            reviewProcessRegistered = const (pure ()),
            reviewConnections = connections,
            reviewActiveTurns = activeTurns,
            reviewInterrupts = interrupts,
            reviewThreadIssues = threadIssues,
            reviewToolRegistry = toolRegistry,
            reviewToolProxies = toolProxies,
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
    acquired <- acquireReviewConnection client issueNumber
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
          -- Named for the backend that is actually serving this thread, for
          -- the reason 'backendAssignment' gives: a thread must not be told
          -- it is a coordinator it is not.
          "developerInstructions" .= reviewDeveloperInstructions client.reviewWorkflowConfig client.reviewModelRoster client.reviewBackend.backendProvider,
          -- The running backend's own provider, for the reason
          -- 'backendAssignment' gives: the tools this thread registers belong
          -- to the process that is serving it, not to whatever the routing
          -- would select again now.
          "dynamicTools" .= (adapterFor client.reviewBackend.backendProvider).adapterReviewTools client.reviewModelRoster client.reviewWorkflowConfig
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
  -- The instructions travel with the prompt because this channel has no
  -- field of its own to carry them; see 'reviewOpeningMessage'.
  sent <-
    sendValue
      client
      connection
      ( streamUserMessage
          ( reviewOpeningMessage
              client.reviewWorkflowConfig
              client.reviewModelRoster
              client.reviewBackend.backendProvider
              issueNumber
          )
      )
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

-- | Send the user's typed message to a review thread, whether or not a turn
-- is already running on it.
--
-- One entry point, two mechanisms, because the two channels differ in what
-- they can do to a turn in flight. The app-server redirects it: @turn\/steer@
-- carries the @expectedTurnId@ the message was aimed at, and a rejection is
-- recovered rather than dropped (issue #17). The CLI's channel has no
-- operation that redirects one at all (D-16), so the message ends the turn
-- and becomes the next one — which the probe behind that decision found to
-- be a near-equivalent, because an interrupted turn's partial output stays in
-- the conversation the follow-up reads.
--
-- With no turn running both are the same thing: the message opens a turn.
sendReviewMessage :: ReviewClient -> ReviewThreadId -> Maybe Text -> Text -> IO (Either Text ())
sendReviewMessage client threadId activeTurnId = case activeTurnId of
  Just turnId -> \message -> case client.reviewBackend.backendProtocol of
    StreamJsonProtocol -> requestInterrupt client threadId turnId (Just message)
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

-- | Write one @control_request@ ending the turn running on a thread, and
-- record what is waiting on it.
--
-- 'Right' means the request was written, and nothing more. What the CLI does
-- with it arrives later on that connection's reader, so this is where an
-- interrupt-and-send stops being synchronous: a caller that took 'Right' has
-- not yet had its message delivered, and learns it never will through
-- 'ReviewInterruptFailed'.
--
-- Refused outright, before anything is written, in the two cases a caller can
-- still do something about. A thread already interrupting must not start a
-- second handshake: the acknowledgement coming back names one request, and
-- two pending operations would race for it while one of the two messages went
-- nowhere. And a turn that is no longer the thread's own is a turn nothing
-- can end — the terminal record for it is already past, so no ending would
-- ever settle this. Both leave the caller holding its message, which is what
-- lets a session keep the user's draft rather than restore it later.
--
-- The two maps are taken in this order here and everywhere else that holds
-- both, so the reader thread settling a turn cannot deadlock against a
-- message being typed on it.
requestInterrupt :: ReviewClient -> ReviewThreadId -> Text -> Maybe Text -> IO (Either Text ())
requestInterrupt client threadId turnId guidance =
  withThreadConnection client threadId $ \connection -> do
    requestId <- interruptRequestId <$> nextRequestId connection
    claimed <- modifyMVar client.reviewActiveTurns $ \turns ->
      if Map.lookup threadId turns /= Just turnId
        then pure (turns, Left (staleTurnMessage client))
        else do
          taken <- modifyMVar client.reviewInterrupts $ \pending -> case Map.lookup threadId pending of
            Just _ -> pure (pending, Left (interruptInFlightMessage client))
            Nothing -> pure (Map.insert threadId (pendingInterrupt requestId turnId guidance) pending, Right ())
          pure (turns, taken)
    case claimed of
      Left message -> pure (Left message)
      Right () -> do
        sent <- sendValue client connection (streamInterruptRequest requestId)
        case sent of
          Right () -> pure (Right ())
          Left message -> do
            -- The caller is told and keeps its message, so nothing is left
            -- waiting on an acknowledgement that cannot arrive.
            modifyMVar_ client.reviewInterrupts (pure . Map.delete threadId)
            pure (Left message)

-- | The @request_id@ one interrupt is written under. Prefixed so a reader of
-- a session transcript can tell Kanban's own control traffic from the CLI's,
-- and drawn from the connection's request counter so no two of this
-- connection's requests share an id.
interruptRequestId :: Int -> Text
interruptRequestId = ("kanban-interrupt-" <>) . Text.pack . show

interruptInFlightMessage :: ReviewClient -> Text
interruptInFlightMessage client =
  backendSentence client <> " is already interrupting this turn; wait for it to stop before sending again"

staleTurnMessage :: ReviewClient -> Text
staleTurnMessage client =
  backendSentence client <> " has already finished that turn; send again to start a new one"

-- | Fold one new fact into the interrupt pending on a thread, and act on
-- whatever that makes of it.
--
-- The single place a pending interrupt is settled, so the guidance riding on
-- one is written on exactly one path and abandoned on exactly one other. Both
-- of the facts it folds in — the acknowledgement and the end of the targeted
-- turn — reach it from the same connection reader, so the entry is taken
-- under the lock that read it and a settlement cannot happen twice.
--
-- The write itself is deliberately outside that lock. Sending is what opens
-- the next turn, and holding the interrupt map across it would make a message
-- typed on another thread wait on this thread's provider accepting a line.
advanceInterrupt :: ReviewClient -> ReviewConnection -> ReviewThreadId -> (PendingInterrupt -> PendingInterrupt) -> IO ()
advanceInterrupt client connection threadId step = do
  settled <- modifyMVar client.reviewInterrupts $ \pending -> case Map.lookup threadId pending of
    Nothing -> pure (pending, Nothing)
    Just current ->
      let stepped = step current
       in case settleInterrupt stepped of
            Nothing -> pure (Map.insert threadId stepped pending, Nothing)
            Just settlement -> pure (Map.delete threadId pending, Just (stepped.interruptGuidance, settlement))
  case settled of
    Nothing -> pure ()
    -- An explicit cancellation asked for the turn to end and nothing more, so
    -- its delivery is the turn's own completion event and there is nothing
    -- left to write.
    Just (Nothing, InterruptDelivered) -> pure ()
    Just (Just message, InterruptDelivered) -> do
      sent <- sendTurnStartOn client connection threadId message
      case sent of
        Right () -> pure ()
        Left detail -> client.reviewEventSink (ReviewInterruptFailed threadId detail (Just message))
    Just (guidance, InterruptAbandoned cause) ->
      client.reviewEventSink (ReviewInterruptFailed threadId cause guidance)

-- | Report every interrupt pending on a connection that has ended, taking
-- them so only one of a dying connection's terminal paths can.
--
-- An acknowledgement that never arrived before the process died is the
-- failure this covers: nothing else would ever settle these, and the guidance
-- waiting on one would be lost silently — having already been shown to the
-- user as sent.
reportAbandonedInterrupts :: ReviewClient -> ReviewConnection -> Text -> IO ()
reportAbandonedInterrupts client connection message = do
  abandoned <- modifyMVar client.reviewInterrupts $ \pending ->
    let (mine, rest) = Map.partitionWithKey (\threadId _ -> threadId.reviewThreadConnection == connection.connectionId) pending
     in pure (rest, Map.toList mine)
  mapM_
    (\(threadId, interrupt) -> client.reviewEventSink (ReviewInterruptFailed threadId message interrupt.interruptGuidance))
    abandoned

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

-- | Deliver the user's answer to the request that asked for it, the way
-- that request arrived. An app-server question is a server request on the
-- connection's own wire and is answered there; a stream-json backend's
-- question came through the MCP re-entry, whose caller is still blocked on
-- the forwarded call, so the answer is the reply frame that resolves it —
-- written to that connection's endpoint and never to the provider's stdin,
-- which on this channel reads only user messages. Both carry the same
-- encoded answer document, so the model reads one shape on either backend.
answerReviewQuestion :: ReviewClient -> ReviewRequestId -> ReviewAnswer -> IO (Either Text ())
answerReviewQuestion client requestIdentity answer =
  withConnection client requestIdentity.reviewRequestConnection $ \connection ->
    case client.reviewBackend.backendProtocol of
      AppServerProtocol ->
        sendValue client connection
          . object
          $ [ "id" .= requestIdentity.reviewRequestWireId,
            "result"
              .= object
                [ "success" .= True,
                  "contentItems"
                    .= [ object
                           [ "type" .= ("inputText" :: Text),
                             "text" .= renderedAnswer
                           ]
                       ]
                  ]
            ]
      StreamJsonProtocol -> do
        proxies <- readMVar client.reviewToolProxies
        case Map.lookup connection.connectionId proxies of
          Nothing -> pure (Left (connectionGoneMessage client))
          Just proxy ->
            writeEndpointReply
              proxy.proxyEndpoint
              (proxyResult requestIdentity.reviewRequestWireId (mcpToolResult False renderedAnswer))
  where
    renderedAnswer = TextEncoding.decodeUtf8 (LazyByteString.toStrict (encode answerValue))
    answerValue =
      object
        [ "selected" .= answer.reviewAnswerSelections,
          "other" .= answer.reviewAnswerOther
        ]

-- | Answer a command or file-change approval request, which only the
-- app-server ever raises. Refused rather than written on the CLI's channel:
-- no approval request can arrive there, so an identity that reaches this
-- arm is stale, and the app-server response it would produce is a line the
-- CLI process on the other end would read as ordinary input.
approveReviewAction :: ReviewClient -> ReviewRequestId -> Bool -> Bool -> IO (Either Text ())
approveReviewAction client requestIdentity accepted forSession = case client.reviewBackend.backendProtocol of
  StreamJsonProtocol -> pure (Left (unsupportedOperation client "answer an approval request"))
  AppServerProtocol ->
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

-- | Cancel a running turn.
--
-- Both channels have an operation for it, and neither answers synchronously:
-- 'Right' says the request reached the provider, not that the turn stopped.
-- The app-server reports the stop as that turn's own completion, and so does
-- the CLI's channel -- but the CLI also answers the control request itself
-- (D-16), so a cancellation it refuses is reported as
-- 'ReviewInterruptFailed' rather than leaving a session waiting on a turn
-- that is still running.
interruptReview :: ReviewClient -> ReviewThreadId -> Text -> IO (Either Text ())
interruptReview client threadId turnId = case client.reviewBackend.backendProtocol of
  StreamJsonProtocol -> requestInterrupt client threadId turnId Nothing
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
  -- The tool re-entry first, so nothing goes on answering the endpoint of a
  -- connection that is over: unlinking it is also what makes a still-running
  -- re-entered server fail its pending calls and exit. Taken, so the two
  -- terminal paths that both reach here cannot tear one proxy down twice.
  taken <- takeReviewToolProxy client connection.connectionId
  mapM_ destroyReviewToolProxy taken
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
  -- Every attached connection's proxy was destroyed by its own watcher
  -- inside the waits above; what this drain reaps is a spawn that
  -- registered its proxy and was then refused attachment in the shutdown
  -- race, whose own cleanup may still be running. Take-semantics make the
  -- overlap harmless, and after this no endpoint of this client's remains
  -- on disk.
  leftover <- drainReviewToolProxies client
  mapM_ destroyReviewToolProxy leftover
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
readProviderOutput :: ReviewClient -> ReviewConnection -> MVar StreamAttribution -> Handle -> IO ()
readProviderOutput client connection attribution outputHandle = do
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
        Left detail -> reportUnreadableLine client connection attribution detail
        Right record -> handleStreamRecord client connection attribution record
    readOne = do
      strictLine <- ByteString.hGetLine outputHandle
      mapM_ (\sessionLog -> logRawLine sessionLog "stdout" strictLine) client.reviewSessionLog
      interpret (LazyByteString.fromStrict strictLine)

-- | A line on a stream-json connection this backend could not read at all.
--
-- Warned about, as any unreadable line is, and then treated as the answer
-- that may have been lost inside it. A line that does not parse carries no
-- record type, so there is no telling whether it was the acknowledgement an
-- interrupt is waiting on — and waiting on an answer that has already gone
-- past unreadably is exactly the hang this backend must not have. So it
-- settles the one interrupt the thread can have pending, and the user's
-- message comes back.
--
-- The trade is the one every other unconfirming answer makes: a garbled line
-- that was /not/ the acknowledgement costs a deliberate resend, while
-- leaving the interrupt to wait costs the message and every send after it.
-- A thread with nothing pending is unaffected, which is every thread in a
-- session that is merely reading a stream it does not fully understand.
reportUnreadableLine :: ReviewClient -> ReviewConnection -> MVar StreamAttribution -> Text -> IO ()
reportUnreadableLine client connection attribution detail = do
  emitProtocolWarning client (streamDiagnostic client detail)
  named <- attributedThread <$> readMVar attribution
  mapM_ (\threadId -> advanceInterrupt client connection threadId (interruptUnconfirmed detail)) named

-- | Mark a pending interrupt as answered by something that did not confirm
-- it, quoting what was said or what could not be read.
--
-- One spelling for every such answer -- an explicit refusal, an answer that
-- named no request, one that named a different request, and a line that
-- could not be read at all -- because they differ only in what they say, and
-- what they mean for the message riding on the interrupt is identical.
interruptUnconfirmed :: Text -> PendingInterrupt -> PendingInterrupt
interruptUnconfirmed detail pending = pending {interruptAcknowledgement = InterruptRefused detail}

-- | Read one connection's stderr to its end, reporting each line against
-- the thread it belongs to and releasing whatever is still waiting for a
-- thread when the stream ends.
readProviderErrors :: ReviewClient -> ReviewConnection -> MVar StreamAttribution -> Handle -> IO ()
readProviderErrors client connection attribution errorHandle = do
  _ <- try (forever readOne) :: IO (Either IOException ())
  releaseHeldDiagnostics client connection attribution
  where
    readOne = do
      strictLine <- ByteString.hGetLine errorHandle
      mapM_ (\sessionLog -> logRawLine sessionLog "stderr" strictLine) client.reviewSessionLog
      reportDiagnostic client connection attribution (decodeLine (LazyByteString.fromStrict strictLine))

-- | What this connection's two readers share: the thread its provider has
-- named, and the diagnostics that arrived before it did.
--
-- One 'MVar' rather than two references because the two are decided
-- together. A stderr line either goes to the thread or waits for it, and
-- naming the thread both fixes the identity and releases what waited; two
-- readers deciding those separately is how a line comes to be both held and
-- emitted, or neither.
data StreamAttribution = StreamAttribution
  { attributedThread :: Maybe ReviewThreadId,
    -- | Oldest first, as the provider wrote them.
    heldDiagnostics :: [Text]
  }

-- | Report one line of a connection's stderr against the thread it belongs
-- to.
--
-- A process that multiplexes every thread writes its diagnostics for the
-- process rather than for one of them, so there is no thread to name and
-- none to wait for: the empty provider id no session claims reaches the
-- transcript of nothing, which is what this did before a connection had an
-- identity at all.
--
-- A stream that names its own session is the opposite case — the connection
-- serves one review thread, and everything it writes to stderr belongs to
-- that thread — but its two readers run concurrently, so stderr routinely
-- arrives before the stdout record that names it. Reporting those early
-- lines unattributed would show the most interesting ones, the complaints a
-- provider makes on the way up, as notices belonging to no review. They wait
-- instead.
--
-- Keyed on the protocol rather than the process shape, because the protocol
-- is what decides whether a thread will ever be named /in the stream/. An
-- app-server names its threads in its responses, so nothing here would ever
-- be released by a record arriving, and holding its stderr would only delay
-- it to the end of the connection.
reportDiagnostic :: ReviewClient -> ReviewConnection -> MVar StreamAttribution -> Text -> IO ()
reportDiagnostic client connection attribution line = case client.reviewBackend.backendProtocol of
  AppServerProtocol -> emitDiagnostic client (unattributedThread connection) line
  StreamJsonProtocol -> do
    named <- modifyMVar attribution $ \state -> case state.attributedThread of
      Just threadId -> pure (state, Just threadId)
      Nothing -> pure (state {heldDiagnostics = state.heldDiagnostics <> [line]}, Nothing)
    mapM_ (\threadId -> emitDiagnostic client threadId line) named

-- | Release the diagnostics still waiting for a thread that will now never
-- be named, against no thread at all.
--
-- They were written before the provider said anything about itself, which is
-- usually why it never did, so they are the one account of what went wrong.
-- Unattributed is where every shared-process diagnostic goes and is strictly
-- better than dropping them; a thread that /is/ named takes them instead,
-- and finds nothing left here.
releaseHeldDiagnostics :: ReviewClient -> ReviewConnection -> MVar StreamAttribution -> IO ()
releaseHeldDiagnostics client connection attribution = do
  held <- modifyMVar attribution (\state -> pure (state {heldDiagnostics = []}, state.heldDiagnostics))
  mapM_ (emitDiagnostic client (unattributedThread connection)) held

emitDiagnostic :: ReviewClient -> ReviewThreadId -> Text -> IO ()
emitDiagnostic client threadId line =
  client.reviewEventSink (ReviewOutput threadId (DiagnosticOutput client.reviewBackend.backendProvider) line)

-- | The thread an unattributable diagnostic is reported against: none of
-- them. No session claims the empty provider id.
unattributedThread :: ReviewConnection -> ReviewThreadId
unattributedThread connection = ReviewThreadId connection.connectionId ""

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
handleStreamRecord :: ReviewClient -> ReviewConnection -> MVar StreamAttribution -> StreamRecord -> IO ()
handleStreamRecord client connection attribution record = case record of
  StreamIgnored -> pure ()
  StreamTurnOpened providerThreadId turnId -> do
    (threadId, drifted, released) <- attributeTurn providerThreadId
    -- A connection serves one review for its whole life, so the session the
    -- provider names must be the one it named first. A later record naming a
    -- different one is reported and disregarded rather than followed: the
    -- review's thread identity is what every map and every session is keyed
    -- by, and adopting a new one would carry this turn, its transcript, and
    -- its verdict away from the review that is waiting for them, with no
    -- pending start left to announce the new thread to anybody.
    when drifted $
      emitProtocolWarning
        client
        (streamDiagnostic client ("opened a turn on session " <> providerThreadId <> ", not the one this review is running on"))
    -- Taken rather than read: the review has arrived, and an entry left
    -- behind would let this connection's death report a review that is
    -- already running as one that never started.
    opening <- takePendingThreadStarts connection
    mapM_ (announceThread threadId) opening
    -- After the session exists and before its first turn: these were written
    -- on the way up, and they belong to this review's transcript rather than
    -- to a notice about nothing.
    mapM_ (emitDiagnostic client threadId) released
    modifyMVar_ client.reviewActiveTurns (pure . Map.insert threadId turnId)
    client.reviewEventSink (ReviewTurnStarted threadId turnId)
  StreamDelta outputKind text ->
    onNamedThread "streamed output" (\threadId -> client.reviewEventSink (ReviewOutput threadId outputKind text))
  StreamControlAnswered requestId answer ->
    onNamedThread "an answer to a control request" $ \threadId ->
      advanceInterrupt client connection threadId (acknowledge requestId answer)
  -- Warned about like any line this backend could not read, and then acted
  -- on, because an operation is waiting on it.
  StreamControlUnreadable detail -> onNamedThread "an answer to a control request" $ \threadId -> do
    emitProtocolWarning client (streamDiagnostic client detail)
    advanceInterrupt client connection threadId (interruptUnconfirmed detail)
  StreamTurnClosed outcome -> onNamedThread "a turn result" $ \threadId -> do
    ended <- modifyMVar client.reviewActiveTurns (\turns -> pure (Map.delete threadId turns, Map.lookup threadId turns))
    client.reviewEventSink $ case outcome of
      StreamVerdict text result -> ReviewTurnCompleted threadId TurnSucceeded Nothing (Just (text, result))
      StreamTurnAborted -> ReviewTurnCompleted threadId TurnInterrupted Nothing Nothing
      StreamTurnFailure detail -> ReviewTurnCompleted threadId TurnFailed (Just (streamDiagnostic client detail)) Nothing
    -- Reported before the interrupt is settled, so a session is told its turn
    -- has stopped before the guidance that ended it opens the next one. The
    -- two are written by this one reader in that order, and the next turn's
    -- own opening record is behind both.
    mapM_ (\turnId -> advanceInterrupt client connection threadId (targetEnded turnId outcome)) ended
  where
    -- The thread this turn runs on, whether the session drifted, and the
    -- diagnostics that were waiting for a thread to belong to. Decided in one
    -- step under the connection's own lock, so the stderr reader cannot slip
    -- a line into a list this has already taken.
    attributeTurn sessionId = modifyMVar attribution $ \state -> case state.attributedThread of
      Just held -> pure (state, (held, held.reviewThreadProvider /= sessionId, []))
      Nothing ->
        let named = ReviewThreadId connection.connectionId sessionId
         in pure (StreamAttribution (Just named) [], (named, False, state.heldDiagnostics))
    announceThread threadId issueNumber = do
      modifyMVar_ client.reviewThreadIssues (pure . Map.insert threadId issueNumber)
      client.reviewEventSink (ReviewThreadCreated issueNumber threadId)
    -- Every answer to a control request settles the one interrupt a thread
    -- can have pending, and only an answer that both names it and agrees
    -- settles it as performed.
    --
    -- One rule for all of them, because on this channel there is nothing for
    -- a second reading to be about: a thread has at most one interrupt in
    -- flight, this backend writes no other kind of control request, and the
    -- CLI answers each one once. So an answer naming a different request, or
    -- naming none at all, is not somebody else's -- it is this exchange
    -- turning out not to be what this client thinks it is, and it is the
    -- last thing that will be said about the request. Left to wait, it
    -- costs the user's message and every send after it; taken as a refusal,
    -- it costs a deliberate resend. The bound is what matters, so it fails
    -- closed.
    acknowledge requestId answer pending
      | pending.interruptRequest /= requestId =
          interruptUnconfirmed ("answered " <> requestId <> ", which is not the interrupt this review is waiting on") pending
      | otherwise = either interruptUnconfirmed (const accepted) answer pending
    accepted pending = pending {interruptAcknowledgement = InterruptAccepted}
    -- What the turn's own ending makes of the interrupt aimed at it, and the
    -- same bound from the other side.
    --
    -- Its own account of how it ended is what says whether the interrupt is
    -- what ended it. A /different/ turn ending settles it too, and as
    -- unconfirmed: a thread runs one turn at a time, so a turn ending that
    -- is not the target's is proof the target is no longer running, and
    -- nothing about it says an interrupt is what stopped it.
    targetEnded turnId outcome pending
      | pending.interruptTurn /= turnId = pending {interruptTarget = TargetSettled}
      | otherwise = pending {interruptTarget = endedAs outcome}
    endedAs StreamTurnAborted = TargetAborted
    endedAs _ = TargetSettled
    -- Everything but the opening record belongs to a thread the stream has
    -- already named. One that arrives before it is a protocol warning rather
    -- than an event attributed to a guess.
    onNamedThread what action = do
      named <- attributedThread <$> readMVar attribution
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
reportConnectionStopped client connection message = do
  case client.reviewBackend.backendProcessShape of
    SharedProcess -> client.reviewEventSink (ReviewClientStopped message)
    ProcessPerThread -> do
      abandoned <- takePendingThreadStarts connection
      mapM_ (\issueNumber -> client.reviewEventSink (ReviewStartFailed issueNumber message)) abandoned
      interrupted <- takeConnectionTurns client connection
      mapM_ (\threadId -> client.reviewEventSink (ReviewTurnCompleted threadId TurnFailed (Just message) Nothing)) interrupted
      client.reviewEventSink (ReviewConnectionStopped connection.connectionId message)
  -- Last, and deliberately after the events that end this connection's
  -- sessions. A message handed back is put where the session it belongs to
  -- can still act on it, and which places those are depends on the phase
  -- those events leave it in -- so reporting this first would offer a
  -- resend from a session that is about to stop accepting one.
  reportAbandonedInterrupts client connection message

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
                void (sendDynamicToolFailure client connection wrappedId crossIssueRefusal)
                emitProtocolWarning client crossIssueRefusal
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

crossIssueRefusal :: Text
crossIssueRefusal = "kanban_github_issue may only access the issue owned by this review thread"

-- | Answer one connection's tool re-entry: the parent's half of the MCP
-- proxy a stream-json backend's tools go over (D-15).
--
-- The dispatch mirrors 'handleServerRequest''s @item\/tool\/call@ arms by
-- outcome: a valid question emits 'ReviewQuestionRequested' and leaves the
-- forwarded call blocked until the user's answer resolves it; an authorized
-- GitHub call emits 'ReviewGitHubStarted' and 'ReviewGitHubFinished' around
-- the same runner the Codex path forks; and an invalid or cross-issue call
-- is answered as a tool-level failure beside the same protocol warning,
-- with no start or finish event, exactly as the app-server path refuses it.
--
-- Authorization is the endpoint's: this connection was spawned for exactly
-- one review, the endpoint was bound to that review's issue before the
-- provider existed, and no field of the call can name another thread. That
-- is the same one-issue boundary 'githubRequestMatchesThread' holds on the
-- multiplexed backend, held by construction instead of by lookup — and a
-- connection spawned for no review at all ('Nothing') authorizes nothing.
--
-- The loop ends when the endpoint's read fails, which teardown causes by
-- closing it; 'destroyReviewToolProxy' also kills the loop directly, so a
-- teardown cannot wait on a read that never returns.
serveConnectionToolCalls :: ReviewClient -> ReviewConnection -> MVar StreamAttribution -> Maybe Int -> ReviewToolEndpoint -> IO ()
serveConnectionToolCalls client connection attribution reviewIssue endpoint = do
  _ <- try (forever serveOne) :: IO (Either IOException ())
  pure ()
  where
    serveOne = do
      line <- readEndpointCall endpoint
      case decodeEndpointCall line of
        Left message -> emitProtocolWarning client (streamDiagnostic client ("tool endpoint " <> message))
        Right (wireId, method, params) -> case method of
          "tools/list" ->
            void (writeEndpointReply endpoint (proxyResult wireId (object ["tools" .= servedToolDescriptors])))
          "tools/call" -> serveToolCall wireId params
          _ -> do
            void (writeEndpointReply endpoint (proxyError wireId (-32601) ("Kanban's review tool server does not serve " <> method)))
            emitProtocolWarning client (streamDiagnostic client ("tool endpoint forwarded an unservable method: " <> method))
    -- The same declarations the Codex thread registers inline, translated —
    -- never restated — so the served schemas carry whatever the adapter's
    -- declarations carry, the workflow label vocabulary included.
    servedToolDescriptors =
      map
        mcpToolDescriptor
        ((adapterFor client.reviewBackend.backendProvider).adapterReviewTools client.reviewModelRoster client.reviewWorkflowConfig)
    serveToolCall wireId params = do
      let wrappedId = ReviewRequestId connection.connectionId wireId
          arguments = maybe (Object mempty) id (objectField "arguments" params)
          refuse message = do
            void (writeEndpointReply endpoint (proxyResult wireId (mcpToolResult True message)))
            emitProtocolWarning client message
      named <- awaitAttributedThread attribution
      case named of
        -- The CLI names its session at the head of the very first turn,
        -- before the model can call anything, so a call with no session
        -- after the wait is a protocol violation rather than a race.
        Nothing -> refuse (streamDiagnostic client "called a Kanban tool before naming its session")
        Just threadId -> case objectField "name" params >>= textValue of
          Just name
            | name == questionToolName -> case parseQuestionValue arguments of
                Left message -> refuse message
                Right question -> client.reviewEventSink (ReviewQuestionRequested threadId wrappedId question)
            | name == githubToolName -> case decodeGitHubIssueToolRequest client.reviewWorkflowConfig arguments of
                Left message -> refuse message
                Right githubRequest
                  | Just githubRequest.githubToolIssue == reviewIssue ->
                      void (forkIO (runProxiedGitHubCall client endpoint threadId wireId githubRequest))
                  | otherwise -> refuse crossIssueRefusal
          _ ->
            -- The Codex arm answers an unregistered tool without a warning,
            -- and so does this one.
            void (writeEndpointReply endpoint (proxyResult wireId (mcpToolResult True "Kanban does not implement that dynamic tool")))

-- | 'runGitHubToolCall' for a call that arrived over the re-entry: the same
-- events around the same runner, with the answer written as the reply frame
-- resolving the forwarded call.
runProxiedGitHubCall :: ReviewClient -> ReviewToolEndpoint -> ReviewThreadId -> Value -> GitHubIssueToolRequest -> IO ()
runProxiedGitHubCall client endpoint threadId wireId request = do
  client.reviewEventSink (ReviewGitHubStarted threadId (githubActionSummary request))
  result <- withReservedToolSlot client threadId (\key -> runGitHubIssueTool client key request)
  sent <- writeEndpointReply endpoint . proxyResult wireId $ case result of
    Left message -> mcpToolResult True message
    Right output -> mcpToolResult False output
  let completion = case (result, sent) of
        (Left message, _) -> Left message
        (_, Left message) -> Left message
        (Right output, Right ()) -> Right output
  client.reviewEventSink (ReviewGitHubFinished threadId completion)

-- | The thread this connection's stream has named, waiting briefly for the
-- readers to have processed the record that names it: the endpoint and the
-- stdout stream are separate channels, so a call the provider makes right
-- after announcing itself can reach the parent first. Bounded, so a
-- provider that truly never names a session cannot park a call forever.
awaitAttributedThread :: MVar StreamAttribution -> IO (Maybe ReviewThreadId)
awaitAttributedThread attribution = go attributionAttempts
  where
    go :: Int -> IO (Maybe ReviewThreadId)
    go remaining = do
      named <- attributedThread <$> readMVar attribution
      case named of
        Just threadId -> pure (Just threadId)
        Nothing
          | remaining <= 0 -> pure Nothing
          | otherwise -> threadDelay 25000 >> go (remaining - 1)
    attributionAttempts = 200 :: Int

textValue :: Value -> Maybe Text
textValue (String value) = Just value
textValue _ = Nothing

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
