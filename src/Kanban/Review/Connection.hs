-- | One provider connection, and the pool of them a review client holds.
--
-- A review client used to /be/ one connection: a single stdin, a single
-- process, a single request counter, a single pending-request set. That is
-- the shape @codex app-server@ has, where every review thread is
-- multiplexed onto one process. It is not the shape every provider has —
-- a @claude@ CLI process is a single conversation, so a backend built on it
-- needs one process per review thread (D-15) — and a record that can hold
-- only one connection cannot express the second.
--
-- So the per-connection state lives here, in 'ReviewConnection', and
-- "Kanban.Review.Client" keeps a 'ConnectionPool' of them. A backend that
-- shares one process routes every thread to the same connection; a backend
-- that gives each thread its own routes each thread to its own. Neither
-- shape is expressible in terms of the other, which is why the client holds
-- a pool rather than a connection.
--
-- 'ReviewThreadId' is what makes that safe. A provider names its threads,
-- and two providers' processes number theirs from the same start, so a bare
-- provider thread id is unique only /within/ one connection. Every map a
-- client keys by thread — active turns, issue authorization, the tool
-- registry, the UI's own session lookup — is keyed by this pair instead, so
-- two connections that both call their thread @thread-1@ never resolve each
-- other's entries. The same reasoning gives 'PendingRequest' a home here
-- rather than beside the wire payloads: JSON-RPC ids are scoped to one
-- connection, so the pending set they index is connection-local state.
module Kanban.Review.Connection
  ( ConnectionAcquisition (..),
    ConnectionId (..),
    ConnectionPool,
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
    takePendingThreadStarts,
    takeConnection,
  )
where

import Control.Concurrent (MVar, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, readMVar)
import Control.Monad (when)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Kanban.Process (ManagedProcess)
import System.IO (Handle)
import System.Process (ProcessHandle)

-- | Which of a client's connections something belongs to. Allocated by the
-- pool and never reused within one client's life, so an id that outlives
-- the connection it named — on a request the user has not answered yet, say
-- — resolves to nothing rather than to a later connection.
newtype ConnectionId = ConnectionId Int
  deriving stock (Eq, Ord, Show)

-- | A review thread as Kanban knows it: the connection serving it, plus the
-- thread id the provider on that connection chose.
--
-- Only the pair is unique. The provider half alone is what the wire carries
-- and what a message must be addressed with, so it is kept verbatim rather
-- than folded into a rendered composite — a composite would have to be
-- taken apart again at every send, and it would move what the UI displays
-- for a session.
data ReviewThreadId = ReviewThreadId
  { reviewThreadConnection :: ConnectionId,
    reviewThreadProvider :: Text
  }
  deriving stock (Eq, Ord, Show)

-- | What a request this client sent is waiting for, so its response can be
-- classified by more than its id.
data PendingRequest
  = PendingThreadStart Int
  | PendingTurnStart ReviewThreadId
  | -- | An in-flight @turn/steer@, retaining its thread, the @expectedTurnId@
    -- it targeted, and the user's message. Without that context a rejection
    -- could only be reported as a generic protocol warning, silently dropping
    -- the typed feedback (issue #17). Interrupts and approval responses stay
    -- 'PendingOther'.
    PendingSteer ReviewThreadId Text Text
  | PendingOther
  deriving stock (Eq, Show)

-- | Everything that belongs to exactly one provider process.
data ReviewConnection = ReviewConnection
  { connectionId :: ConnectionId,
    connectionInput :: Handle,
    connectionProcess :: ProcessHandle,
    -- | This connection's own pgid, captured at spawn time so shutdown can
    -- still signal it after 'connectionProcess' has been reaped (see
    -- 'Kanban.Review.Client.ToolRegistry' and issue #16).
    connectionManaged :: ManagedProcess,
    connectionWriteLock :: MVar (),
    connectionNextRequestId :: IORef Int,
    connectionPendingRequests :: MVar (Map Int PendingRequest),
    -- | Whether this connection's reader, error, and watcher loops were ever
    -- forked. Written before the connection is attached to a pool, so
    -- anything that finds it there may wait on 'connectionWatchDone'; a
    -- connection abandoned mid-handshake, or a fixture that starts no loops,
    -- is never waited on for a signal nothing will fill.
    connectionReadersStarted :: IORef Bool,
    connectionOutputDone :: MVar (),
    connectionErrorDone :: MVar (),
    -- | Filled once the watcher has reaped the process /and/ taken both
    -- reader signals, so one wait covers all three.
    connectionWatchDone :: MVar ()
  }

newReviewConnection :: ConnectionId -> Handle -> ProcessHandle -> ManagedProcess -> IO ReviewConnection
newReviewConnection identifier inputHandle processHandle managed =
  ReviewConnection identifier inputHandle processHandle managed
    <$> newMVar ()
    <*> newIORef 2
    <*> newMVar Map.empty
    <*> newIORef False
    <*> newEmptyMVar
    <*> newEmptyMVar
    <*> newEmptyMVar

-- | Take the issue numbers whose review is still waiting for its thread on
-- this connection, removing them from the pending set.
--
-- A review with no thread yet has no thread id, and so no identity anything
-- connection-scoped can match it by; its issue number is the only thing
-- naming it. Both ends of that wait read it here. A connection dying takes
-- these to report the reviews that will now never start, and taking rather
-- than reading is what keeps its two terminal paths — the output reader
-- hitting EOF and the watcher reaping the process — from both reporting the
-- same abandoned review. A provider naming its thread takes them for the
-- opposite reason: the review has arrived, and leaving the entry behind
-- would let a later death report a review that is already running.
takePendingThreadStarts :: ReviewConnection -> IO [Int]
takePendingThreadStarts connection =
  modifyMVar connection.connectionPendingRequests $ \requests ->
    pure
      ( Map.filter (not . isThreadStart) requests,
        [issueNumber | PendingThreadStart issueNumber <- Map.elems requests]
      )
  where
    isThreadStart PendingThreadStart {} = True
    isThreadStart _ = False

markConnectionReadersStarted :: ReviewConnection -> IO ()
markConnectionReadersStarted connection = writeIORef connection.connectionReadersStarted True

-- | Block until this connection's loops have all finished, or return at once
-- if it never started any.
awaitConnectionReaders :: ReviewConnection -> IO ()
awaitConnectionReaders connection = do
  started <- readIORef connection.connectionReadersStarted
  when started (readMVar connection.connectionWatchDone)

-- | Every connection a client currently holds, plus whether shutdown has
-- already committed to draining them.
--
-- Registration happens in two steps around the spawn, exactly as
-- 'Kanban.Review.Client.ToolRegistry' does it around a tool subprocess and
-- for the same reason: a shutdown racing a spawn must not be able to leave
-- an unregistered provider process running. 'acquireConnectionSlot' records
-- /intent/ before the process exists, and 'attachConnection' fills in the
-- spawned connection. If the reservation was already drained in that window,
-- 'attachConnection' reports failure and the spawner stops what it started
-- itself, because no drain will ever see it.
newtype ConnectionPool = ConnectionPool
  { poolState :: MVar PoolState
  }

data PoolState = PoolState
  { poolClosed :: Bool,
    poolNextId :: Int,
    poolEntries :: Map ConnectionId (Maybe ReviewConnection)
  }

-- | What one reservation attempt decided.
data ConnectionAcquisition
  = -- | A reserved slot to spawn into. The caller owes the pool either an
    -- 'attachConnection' or a 'releaseConnectionSlot'.
    ReservedConnection ConnectionId
  | -- | Shutdown has committed. Nothing further may be spawned.
    ConnectionPoolClosed

newConnectionPool :: IO ConnectionPool
newConnectionPool = ConnectionPool <$> newMVar (PoolState False 0 Map.empty)

-- | Claim a slot to spawn a connection into, refusing once shutdown has
-- committed. Allocating the id under the pool's own lock, in the same step
-- that records the intent, is what makes 'drainConnectionPool' a point every
-- spawn is on one side of.
reserveConnectionSlot :: ConnectionPool -> IO ConnectionAcquisition
reserveConnectionSlot pool =
  modifyMVar pool.poolState $ \state ->
    if state.poolClosed
      then pure (state, ConnectionPoolClosed)
      else
        let identifier = ConnectionId state.poolNextId
         in pure
              ( state
                  { poolNextId = state.poolNextId + 1,
                    poolEntries = Map.insert identifier Nothing state.poolEntries
                  },
                ReservedConnection identifier
              )

-- | Fill in a reservation with the connection that was spawned into it.
-- 'False' means the reservation is already gone — drained by a shutdown that
-- committed while the process was starting — so the caller now owns stopping
-- what it spawned, since no drain will ever see it.
attachConnection :: ConnectionPool -> ReviewConnection -> IO Bool
attachConnection pool connection =
  modifyMVar pool.poolState $ \state ->
    if Map.member connection.connectionId state.poolEntries
      then pure (state {poolEntries = Map.insert connection.connectionId (Just connection) state.poolEntries}, True)
      else pure (state, False)

-- | Drop a reservation whose spawn never produced a connection.
releaseConnectionSlot :: ConnectionPool -> ConnectionId -> IO ()
releaseConnectionSlot pool identifier =
  modifyMVar_ pool.poolState $ \state ->
    pure state {poolEntries = Map.delete identifier state.poolEntries}

lookupConnection :: ConnectionPool -> ConnectionId -> IO (Maybe ReviewConnection)
lookupConnection pool identifier = do
  state <- readMVar pool.poolState
  pure (Map.lookup identifier state.poolEntries >>= id)

attachedConnections :: ConnectionPool -> IO [ReviewConnection]
attachedConnections pool = do
  state <- readMVar pool.poolState
  pure [connection | Just connection <- Map.elems state.poolEntries]

-- | Remove one connection that has ended on its own, leaving the pool open
-- for the connections it still holds and for any it has yet to spawn.
takeConnection :: ConnectionPool -> ConnectionId -> IO ()
takeConnection pool identifier =
  modifyMVar_ pool.poolState $ \state ->
    pure state {poolEntries = Map.delete identifier state.poolEntries}

-- | Close the pool — no further acquisition succeeds — and hand back every
-- connection that was already attached, for the caller to stop. Used by full
-- client shutdown, where nothing may be left running or registered
-- afterward.
drainConnectionPool :: ConnectionPool -> IO [ReviewConnection]
drainConnectionPool pool =
  modifyMVar pool.poolState $ \state ->
    pure
      ( state {poolClosed = True, poolEntries = Map.empty},
        [connection | Just connection <- Map.elems state.poolEntries]
      )
