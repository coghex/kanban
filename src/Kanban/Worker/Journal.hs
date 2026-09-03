-- | The worker event journal: how a supervisor appends an envelope to its
-- @.events.jsonl@ and how a monitor reads that file back without ever
-- replaying or dropping a line.
--
-- Both directions live here on purpose. The append side's single-'hPut'
-- write and the read side's byte-offset consumption are two halves of one
-- guarantee (see issue #8) — a concurrent reader only ever observes a whole
-- line — and separating them would leave each half's comments explaining an
-- invariant the other one enforces.
--
-- Knows nothing of leases or termination: "Kanban.Worker.Monitor" is where
-- the journal's replay is combined with the recovery those require.
--
-- This module is internal — "Kanban.Worker" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Worker.Journal
  ( EventJournalLock,
    newEventJournalLock,
    appendWorkerEvent,
    consumeJournalLines,
    readJournalSince,
    readWorkerJournal,
    decodeJournalLine,
    isTerminalEnvelope,
    emitEnvelope,
    drainJournalBeforeExit,
  )
where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (IOException, onException, try)
import Data.Aeson (eitherDecodeStrict', encode)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Maybe (mapMaybe)
import Data.Time (getCurrentTime)
import Kanban.Worker.Types
  ( WorkerDescriptor (..),
    WorkerEnvelope (..),
    WorkerEvent (..),
    WorkerId (..),
    WorkerSpec (..),
  )
import System.IO (BufferMode (LineBuffering), Handle, hClose, hSetBinaryMode, hSetBuffering)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (setFdMode)
import System.Posix.IO (OpenFileFlags (append, creat), OpenMode (WriteOnly), closeFd, defaultFileFlags, fdToHandle, openFd)

-- | Serializes this supervisor's own appends to the worker event journal.
-- Wrapped rather than left a bare 'MVar ()' because 'appendWorkerEvent' is
-- also reached from outside the supervisor (see 'recordPendingTermination')
-- and so cannot take 'SupervisorCells' itself: without the wrapper it would
-- accept either of the two deadline handshake vars that share that type,
-- which coordinate the deadline race rather than guarding a file.
newtype EventJournalLock = EventJournalLock (MVar ())

newEventJournalLock :: IO EventJournalLock
newEventJournalLock = EventJournalLock <$> newMVar ()

appendWorkerEvent :: WorkerDescriptor -> EventJournalLock -> WorkerEvent -> IO ()
appendWorkerEvent descriptor (EventJournalLock lock) event = withMVar lock $ \() -> do
  now <- getCurrentTime
  handle <- openPrivateAppendHandle descriptor.workerDescriptorEventPath
  hSetBuffering handle LineBuffering
  -- A single write of the complete envelope-plus-newline, so a concurrent
  -- reader of this file only ever observes a complete line or nothing of it
  -- (see issue #8) rather than a partial record split across two hPuts.
  LazyByteString.hPut handle (encode (WorkerEnvelope now event) <> "\n")
  -- The handle is intentionally short-lived so a TUI restart always sees a
  -- fully flushed record and the worker never retains a deleted log inode.
  hClose handle

-- | Opens a worker's event journal for appending under §16's user-only file
-- mode, whatever the ambient umask and whichever release created the file.
--
-- 'openBinaryFile' creates a missing journal at @0666@ minus the umask, so a
-- default umask left issue bodies and full agent transcripts — from private
-- repositories as readily as public ones — group- and world-readable, while
-- every other file in the worker directory goes through 'writePrivateJson'
-- and lands at @0600@. @O_CREAT@ with an explicit mode closes that for a new
-- journal without depending on the umask, and the mode is then reapplied so
-- a journal an earlier release already created permissively is tightened
-- /before/ this call appends more private bytes to it, rather than only
-- whenever some future rewrite that never comes happens along.
--
-- 'setFdMode' acts on the descriptor just opened rather than re-resolving
-- the path, so the mode always lands on the file being appended to.
openPrivateAppendHandle :: FilePath -> IO Handle
openPrivateAppendHandle path = do
  journalFd <- openFd path WriteOnly defaultFileFlags {append = True, creat = Just 0o600}
  handle <- onException (setFdMode journalFd 0o600 >> fdToHandle journalFd) (closeFd journalFd)
  hSetBinaryMode handle True
  pure handle

-- | Splits the unconsumed suffix of a journal's full current contents into
-- complete (newline-terminated) lines and the new consumed-byte offset. An
-- unterminated trailing fragment — a write observed mid-append — is left
-- unconsumed so a later call sees it whole once the append completes,
-- fixing the permanently-dropped-event defect in issue #8. Tracking
-- consumption by byte offset rather than line count also means a caller
-- that keeps the offset unchanged across a failed read neither replays nor
-- skips a line: for any way of splitting a journal's growth into chunks,
-- repeated calls threading the offset through yield exactly its complete
-- lines, once each, in order.
consumeJournalLines :: Int -> ByteString.ByteString -> ([ByteString.ByteString], Int)
consumeJournalLines consumedBytes content = case ByteString.elemIndexEnd newline unseen of
  Nothing -> ([], consumedBytes)
  Just lastNewlineIndex ->
    let consumedThisRound = lastNewlineIndex + 1
        completeLines = ByteString.split newline (ByteString.take consumedThisRound unseen)
     in (filter (not . ByteString.null) completeLines, consumedBytes + consumedThisRound)
  where
    unseen = ByteString.drop consumedBytes content
    newline = 10

-- | Reads the journal's full current contents and applies
-- 'consumeJournalLines' from the given offset. A read failure caused by the
-- journal not existing yet (no event has ever been appended) is reported as
-- an empty read rather than a failure, since that is the normal state
-- before a worker's first write; any other 'IOException' is surfaced so the
-- caller can retry without moving the consumption position.
readJournalSince :: WorkerDescriptor -> Int -> IO (Either IOException ([ByteString.ByteString], Int))
readJournalSince descriptor consumedBytes = do
  contentResult <- try @IOException (ByteString.readFile descriptor.workerDescriptorEventPath)
  pure $ case contentResult of
    Left err
      | isDoesNotExistError err -> Right ([], consumedBytes)
      | otherwise -> Left err
    Right content -> Right (consumeJournalLines consumedBytes content)

-- | Every complete envelope a worker has journaled so far, oldest first.
--
-- The whole journal rather than a suffix: this is what a caller asks when it
-- needs the /evidence/ a worker recorded rather than the events it has not
-- seen yet — an issue action's published verdict, a reattaching dashboard's
-- replay. An unterminated trailing fragment is left out for the same reason
-- 'consumeJournalLines' leaves it: it is an append still in flight.
--
-- A journal that cannot be read at all reads as empty. That is only ever a
-- worker that has written nothing yet or a file that has been collected, and
-- both are honestly "no evidence here"; every caller treats an absence of
-- evidence as a non-result rather than as a result.
readWorkerJournal :: WorkerDescriptor -> IO [WorkerEnvelope]
readWorkerJournal descriptor = do
  readResult <- readJournalSince descriptor 0
  pure $ case readResult of
    Left _ -> []
    Right (journalLines, _) -> mapMaybe decodeJournalLine journalLines

decodeJournalLine :: ByteString.ByteString -> Maybe WorkerEnvelope
decodeJournalLine line = case eitherDecodeStrict' line :: Either String WorkerEnvelope of
  Left _ -> Nothing
  Right envelope -> Just envelope

isTerminalEnvelope :: WorkerEnvelope -> Bool
isTerminalEnvelope envelope = case envelope.workerEnvelopeEvent of
  WorkerFinished _ -> True
  _ -> False

emitEnvelope :: WorkerDescriptor -> (WorkerId -> WorkerSpec -> WorkerEvent -> IO ()) -> WorkerEnvelope -> IO ()
emitEnvelope descriptor eventSink envelope = eventSink spec.workerId spec envelope.workerEnvelopeEvent
  where
    spec = descriptor.workerDescriptorSpec

-- | Delivers any journal lines appended since the monitor loop's last read,
-- for a recovery pass that is about to finalize and have 'monitorWorker'
-- exit. Without this, events written in the crash window between the
-- monitor's last poll and this state check — final output, diagnostics, the
-- real terminal envelope — are never delivered (see issue #8). A read
-- failure here must not finalize: the caller aborts this recovery attempt
-- (by returning 'Nothing') and lets the monitor retry on its next poll
-- rather than guessing the drain was empty; 'Just sawFinished' reports
-- whether a real 'WorkerFinished' was among the drained events, so the
-- caller can skip emitting a duplicate synthetic one.
drainJournalBeforeExit :: WorkerDescriptor -> (WorkerId -> WorkerSpec -> WorkerEvent -> IO ()) -> Int -> IO (Maybe Bool)
drainJournalBeforeExit descriptor eventSink consumedBytes = do
  readResult <- readJournalSince descriptor consumedBytes
  case readResult of
    Left _ -> pure Nothing
    Right (unseen, _) -> do
      let envelopes = mapMaybe decodeJournalLine unseen
      mapM_ (emitEnvelope descriptor eventSink) envelopes
      pure (Just (any isTerminalEnvelope envelopes))
