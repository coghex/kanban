-- | The review session's runtime state: the 'ReviewClient' record and the
-- 'ToolRegistry' it owns.
--
-- Held below both "Kanban.Review.Tools" and "Kanban.Review" because the two
-- share this state in opposite directions — the client record carries the
-- registry and the bounds, while the tool runners take the client. Keeping
-- the record here is what makes that acyclic without moving the registry
-- off the client or changing any runner's signature.
module Kanban.Review.Client
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
where

import Control.Concurrent (MVar, modifyMVar, modifyMVar_, newMVar)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Kanban.CommandCapture (CommandBounds)
import Kanban.Domain (WorkflowConfig)
import Kanban.Process (ManagedProcess, killManagedProcess)
import Kanban.Review.Types (PendingRequest, ReviewEvent)
import Kanban.Transcript (SessionLog)
import System.IO (Handle)
import System.Process (ProcessHandle)

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
    -- 'Kanban.Review.readServerOutput' thread — so this map, not the UI's
    -- asynchronously updated session state, decides whether a rejected steer
    -- can be resent (issue #17).
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

killReviewTools :: ReviewClient -> Text -> IO ()
killReviewTools client threadId = killThreadToolProcesses client.reviewToolRegistry threadId

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
