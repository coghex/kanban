-- | The review session's runtime state: the 'ReviewClient' record, the pool
-- of provider connections it holds, and the 'ToolRegistry' it owns.
--
-- Held below both "Kanban.Review.Tools" and "Kanban.Review" because the two
-- share this state in opposite directions — the client record carries the
-- registry and the bounds, while the tool runners take the client. Keeping
-- the record here is what makes that acyclic without moving the registry
-- off the client or changing any runner's signature.
module Kanban.Review.Client
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
where

import Control.Concurrent (MVar, ThreadId, killThread, modifyMVar, modifyMVar_, newMVar)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Kanban.CommandCapture (CommandBounds)
import Kanban.Domain (WorkflowConfig)
import Kanban.Models (ModelRoster)
import Kanban.Process (ManagedProcess, killManagedProcess)
import Kanban.ProviderAdapter (EmbeddedReviewBackend (..))
import Kanban.Review.Connection (ConnectionId, ConnectionPool, ReviewThreadId (..))
import Kanban.Review.Types (ReviewEvent (..))
import Kanban.ReviewToolServer (ReviewToolEndpoint, teardownReviewToolEndpoint)
import Kanban.Transcript (SessionLog)

data ReviewClient = ReviewClient
  { -- | The backend every one of this client's connections is spawned from,
    -- retained rather than consulted once at startup because a backend that
    -- gives each review thread its own process spawns again on every start.
    -- It is also what says whether one connection ending is the whole client
    -- ending.
    reviewBackend :: EmbeddedReviewBackend,
    -- | Every provider connection this client currently holds. One for the
    -- whole of a shared-process backend's life; one per review thread for a
    -- backend that gives each thread its own.
    reviewConnections :: ConnectionPool,
    -- | The turn currently running on each thread, maintained from the
    -- @turn/started@ and @turn/completed@ notifications. The UI keeps its own
    -- copy for display, but a rejected steer has to be classified against
    -- what the wire has actually delivered *at that point in the stream*, and
    -- a connection's notifications and responses are handled in order by that
    -- connection's single 'Kanban.Review.readServerOutput' thread — so this
    -- map, not the UI's asynchronously updated session state, decides whether
    -- a rejected steer can be resent (issue #17).
    --
    -- Keyed by 'ReviewThreadId' rather than the provider's own thread id:
    -- two connections both naming a thread @thread-1@ would otherwise share
    -- one entry and answer each other's steers.
    reviewActiveTurns :: MVar (Map ReviewThreadId Text),
    -- | The interrupt in flight on each thread, for a backend whose channel
    -- has no operation that redirects a running turn and cancels one instead
    -- (D-16). At most one per thread: a second guidance or cancellation
    -- arriving while one is unresolved is refused rather than queued, so the
    -- acknowledgement that comes back can only belong to one operation and
    -- one waiting message.
    --
    -- Keyed by thread rather than held on the connection even though the only
    -- backend that fills it gives each thread a process of its own, because
    -- what is serialized here is a thread's operations. A connection is where
    -- the request id is unique; a thread is what owns the turn being ended
    -- and the guidance waiting on it.
    reviewInterrupts :: MVar (Map ReviewThreadId PendingInterrupt),
    reviewThreadIssues :: MVar (Map ReviewThreadId Int),
    reviewToolRegistry :: ToolRegistry,
    -- | The tool re-entry serving each connection whose provider's tools go
    -- over MCP rather than inline (D-15): the FIFO endpoint the connection's
    -- launch named and the parent loop answering it. Keyed by connection
    -- because that is what the endpoint is bound to — a caller cannot select
    -- another thread's proxy any more than another thread's issue — and
    -- taken (never merely read) by teardown, so a connection's terminal
    -- cleanup and full client shutdown cannot both destroy one.
    reviewToolProxies :: MVar (Map ConnectionId ReviewToolProxy),
    reviewEventSink :: ReviewEvent -> IO (),
    -- | Called with every provider process this client creates, at the
    -- instant it is created.
    --
    -- The repository review host passes its supervisor's own registration
    -- here (SAG-10), so a connection is recorded, identified, and censused
    -- before anything else happens to it. Registering after the spawn
    -- returned, or at the owner's next poll, leaves a window in which a host
    -- killed uncleanly loses the only durable record of a process it started
    -- — and an orphaned provider with nothing naming it is exactly what the
    -- census exists to prevent.
    --
    -- A no-op for every other owner, which is what tests and the
    -- placeholder client pass.
    reviewProcessRegistered :: ManagedProcess -> IO (),
    reviewRepositoryRoot :: FilePath,
    -- | The dashboard's resolved OWNER/NAME (which may come from an
    -- explicit --repo override, e.g. reviewing upstream from a fork
    -- checkout). Passed explicitly to every GitHub tool call below so it
    -- never re-derives identity from the checkout's own remote.
    reviewRepositorySlug :: Text,
    reviewWorkflowConfig :: WorkflowConfig,
    -- | The roster snapshot this backend was started against, resolved once
    -- at startup and retained rather than reread. Two cells are consulted
    -- through it, each at its own spawn boundary and each with its own
    -- refusal: @issue_review.codex@ for the review thread's own model and
    -- effort ('Kanban.Review.beginIssueReview',
    -- 'Kanban.Review.sendTurnStart'), and @issue_revise.claude@ for the
    -- @kanban_run_claude@ tool ('Kanban.Review.Tools.runAuthenticatedClaude').
    -- A roster that loads only one brand leaves the other's tool refusing,
    -- which is why the whole roster travels here rather than one resolved
    -- assignment.
    reviewModelRoster :: ModelRoster,
    -- | The one transcript every connection's raw traffic is written to.
    -- Client-wide rather than per-connection because it records the review
    -- backend's session, not one process's share of it, so it is closed when
    -- the /client/ is finished: with a shared process that is the moment its
    -- one connection ends, and with a process per thread it is shutdown,
    -- because such a client outlives its connections.
    reviewSessionLog :: Maybe SessionLog,
    -- | The bounds every @gh@ subprocess behind @kanban_github_issue@ runs
    -- under. Carried on the client rather than passed down, so the
    -- mutation-specific wrappers above 'Kanban.Review.Tools.runGitHubCommand'
    -- -- which is where the verify-before-retry guidance is chosen -- are all
    -- reachable from a test that injects short bounds.
    reviewCommandBounds :: CommandBounds,
    -- | The bounds the @claude@ subprocess behind @kanban_run_claude@ runs
    -- under, carried here for the same reason:
    -- 'Kanban.Review.Tools.runAuthenticatedClaude' is only reachable through
    -- the client, so its deadline and capture-grace paths would otherwise
    -- cost ten real minutes to reach from a test.
    reviewClaudeBounds :: CommandBounds
  }

-- | One interrupt this client has written and not yet settled, and whatever
-- is waiting on it.
--
-- Two independent facts have to arrive before guidance may follow an
-- interrupt, and the channel orders neither against the other: the CLI's
-- acknowledgement of the control request, and the end of the turn the
-- request targeted. Holding both here is what lets them arrive in either
-- order and still settle once.
data PendingInterrupt = PendingInterrupt
  { -- | The @request_id@ the control request was written under, so the
    -- acknowledgement that comes back can be told from one belonging to an
    -- operation this thread has already finished with.
    interruptRequest :: Text,
    -- | The turn this interrupt was aimed at, which is the only turn whose
    -- ending settles it.
    interruptTurn :: Text,
    -- | The message to send as the next turn once it settles, or 'Nothing'
    -- for an explicit cancellation, which is asking for the turn to end and
    -- nothing more.
    interruptGuidance :: Maybe Text,
    interruptAcknowledgement :: InterruptAcknowledgement,
    interruptTarget :: InterruptTarget
  }
  deriving stock (Eq, Show)

-- | What the CLI has said about the control request so far.
data InterruptAcknowledgement
  = AcknowledgementPending
  | InterruptAccepted
  | -- | The CLI answered, and the answer was not agreement. Carries what it
    -- said, because an interrupt that was refused is the whole account of why
    -- the guidance riding on it was never sent.
    InterruptRefused Text
  deriving stock (Eq, Show)

-- | What has become of the turn the interrupt was aimed at.
data InterruptTarget
  = TargetRunning
  | -- | It ended cut short, which is what an interrupt that landed does to it.
    TargetAborted
  | -- | It ended on its own, so nothing was interrupted however the control
    -- request was answered.
    TargetSettled
  deriving stock (Eq, Show)

-- | What a pending interrupt has become.
data InterruptSettlement
  = -- | Both halves are in and agree: the turn was cut short and the CLI
    -- accepted the request, so guidance riding on it may now be written.
    InterruptDelivered
  | -- | It cannot be completed, and this is why. Anything riding on it has to
    -- go back to the user rather than be sent.
    InterruptAbandoned Text
  deriving stock (Eq, Show)

-- | A fresh interrupt, waiting on both of its halves.
pendingInterrupt :: Text -> Text -> Maybe Text -> PendingInterrupt
pendingInterrupt request turnId guidance =
  PendingInterrupt request turnId guidance AcknowledgementPending TargetRunning

-- | Whether an interrupt is settled, and how. 'Nothing' is an interrupt still
-- waiting on one of its halves.
--
-- The one place this is decided, so the rule that releases a user's message
-- into a provider's stdin has a single spelling. Refusal is read first
-- because a refused request performed nothing whatever the turn went on to
-- do; a target that ended on its own is read next, because an interrupt is
-- still acknowledged as a success when it arrives a moment after the turn it
-- names has finished — so the acknowledgement alone never establishes that a
-- turn was cut short, and guidance released on it would open a turn on a
-- review that has already reached its verdict.
settleInterrupt :: PendingInterrupt -> Maybe InterruptSettlement
settleInterrupt pending = case (pending.interruptAcknowledgement, pending.interruptTarget) of
  (InterruptRefused detail, _) -> Just (InterruptAbandoned ("the backend " <> detail))
  (_, TargetSettled) -> Just (InterruptAbandoned "the turn had already finished when the interrupt reached it")
  (InterruptAccepted, TargetAborted) -> Just InterruptDelivered
  (AcknowledgementPending, _) -> Nothing
  (InterruptAccepted, TargetRunning) -> Nothing

-- | Report something this client could not make sense of, under the brand of
-- the backend it is actually running.
--
-- The one place a protocol warning is raised, because it is the one place
-- that knows: the reader loops, the response dispatch, and the tool runners
-- that reach it are shared by every backend and carry no provider of their
-- own, so a warning built anywhere else would have to name a brand it had
-- guessed.
emitProtocolWarning :: ReviewClient -> Text -> IO ()
emitProtocolWarning client message =
  client.reviewEventSink (ReviewProtocolWarning client.reviewBackend.backendProvider message)

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
  { toolEntryThread :: ReviewThreadId,
    toolEntryProcess :: Maybe ManagedProcess
  }

newToolRegistry :: IO ToolRegistry
newToolRegistry = ToolRegistry <$> newIORef 0 <*> newMVar (ToolRegistryState False Map.empty)

-- | Reserve a slot for an about-to-be-spawned tool process. 'Nothing' means
-- the registry is already closed (client shutdown has begun) — the caller
-- must not spawn at all.
reserveToolSlot :: ToolRegistry -> ReviewThreadId -> IO (Maybe Int)
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
killThreadToolProcesses :: ToolRegistry -> ReviewThreadId -> IO ()
killThreadToolProcesses registry threadId = killMatchingToolProcesses registry (\entry -> entry.toolEntryThread == threadId)

-- | Kill and drop every entry owned by any thread on @connectionId@, leaving
-- the registry open. What one connection ending has to reach: its own
-- threads' in-flight tool calls, and nothing another connection is still
-- serving. Full shutdown uses 'drainToolRegistry' instead, which also closes
-- the registry.
killConnectionToolProcesses :: ToolRegistry -> ConnectionId -> IO ()
killConnectionToolProcesses registry connectionId =
  killMatchingToolProcesses registry (\entry -> entry.toolEntryThread.reviewThreadConnection == connectionId)

killMatchingToolProcesses :: ToolRegistry -> (ToolEntry -> Bool) -> IO ()
killMatchingToolProcesses registry owned = do
  dropped <- modifyMVar registry.toolRegistryState $ \state ->
    let (mine, rest) = Map.partition owned state.toolRegistryEntries
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

killReviewTools :: ReviewClient -> ReviewThreadId -> IO ()
killReviewTools client threadId = killThreadToolProcesses client.reviewToolRegistry threadId

-- | One connection's tool re-entry, as the parent holds it: the endpoint
-- the spawned server proxies over, and the serving loop answering it.
data ReviewToolProxy = ReviewToolProxy
  { proxyEndpoint :: ReviewToolEndpoint,
    proxyServer :: ThreadId
  }

registerReviewToolProxy :: ReviewClient -> ConnectionId -> ReviewToolProxy -> IO ()
registerReviewToolProxy client connectionId proxy =
  modifyMVar_ client.reviewToolProxies (pure . Map.insert connectionId proxy)

-- | Take one connection's proxy, if it still holds one. Taking rather than
-- reading is what makes destruction single-owner: whichever terminal path
-- gets here first is the one that tears it down.
takeReviewToolProxy :: ReviewClient -> ConnectionId -> IO (Maybe ReviewToolProxy)
takeReviewToolProxy client connectionId =
  modifyMVar client.reviewToolProxies $ \proxies ->
    pure (Map.delete connectionId proxies, Map.lookup connectionId proxies)

-- | Take every proxy still registered, for full shutdown to destroy. The
-- connections' own watchers have normally emptied this already; what is
-- left is a spawn that registered and was then refused attachment in the
-- shutdown race, and nothing else will ever look for it.
drainReviewToolProxies :: ReviewClient -> IO [ReviewToolProxy]
drainReviewToolProxies client =
  modifyMVar client.reviewToolProxies (\proxies -> pure (Map.empty, Map.elems proxies))

-- | Stop one proxy completely: the serving loop first, so nothing answers a
-- frame mid-teardown, then the endpoint — whose unlinking is what tells the
-- re-entered server to fail its pending calls and exit.
destroyReviewToolProxy :: ReviewToolProxy -> IO ()
destroyReviewToolProxy proxy = do
  killThread proxy.proxyServer
  teardownReviewToolEndpoint proxy.proxyEndpoint

-- | Reserves a registry slot for the *whole* dispatched tool call before
-- doing any work (including the @findExecutable@ lookup and any
-- multi-subprocess sequence within it), and releases it only once the call
-- is completely finished. Reserving here, at the very top of the dispatched
-- call, rather than around each individual subprocess spawn, is what lets a
-- same-thread cancellation land in the gap before the first spawn — or
-- between the sequential subprocesses of one GitHub update — and still find
-- and drain this same reservation, so a later subprocess of an
-- already-cancelled call cannot spawn as if nothing happened.
withReservedToolSlot :: ReviewClient -> ReviewThreadId -> (Int -> IO (Either Text a)) -> IO (Either Text a)
withReservedToolSlot client threadId action = do
  reserved <- reserveToolSlot client.reviewToolRegistry threadId
  case reserved of
    Nothing -> pure (Left "Review client is shutting down")
    Just key -> do
      result <- action key
      releaseToolSlot client.reviewToolRegistry key
      pure result
