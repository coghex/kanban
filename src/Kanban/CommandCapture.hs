-- | Running one short-lived subprocess under two *independent* bounds: how
-- long it may take to exit, and how much longer than that its output
-- capture may lag. Keeping them separate is what stops an already-observed
-- exit from being reported as a timeout when a descendant that inherited
-- the pipe still holds its write end open (issue #15).
--
-- This machinery started inside "Kanban.Review", where only two of its
-- three command runners were converted to it and the third kept a private
-- @hGetContents@-plus-@takeMVar@ capture that had exactly the bug the
-- conversion existed to remove (issue #154). It lives here so the shared
-- path is the only path: a new subprocess runner reaches for
-- 'startCapture' and 'awaitCommandOutcome' rather than rebuilding capture
-- and re-introducing the omission.
--
-- Unbounded runs share this module too, through 'readProcessBytes': the
-- short status-only commands that have no deadline of their own still need
-- capture that reads *bytes*, for the reason 'readProcessBytes' documents.
--
-- Nothing here knows anything about reviews, GitHub, or any particular
-- executable. Callers own the diagnostics: this module reports what was
-- observed ('CommandOutcome'), and they decide what that means.
module Kanban.CommandCapture
  ( CommandBounds (..),
    CommandOutcome (..),
    StreamCapture,
    StreamCaptureResult (..),
    awaitCommandOutcome,
    captureGraceMicros,
    capturedBytes,
    commandRanToCompletion,
    decodeCommandText,
    readProcessBytes,
    releaseCapture,
    renderWindow,
    startCapture,
  )
where

import Control.Concurrent (ThreadId, forkIO, killThread, newEmptyMVar, putMVar)
import Control.Concurrent.MVar (MVar, readMVar, tryReadMVar)
import Control.Exception (IOException, bracket, throwIO, try)
import Control.Monad (void)
import qualified Data.ByteString.Char8 as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (CreatePipe), waitForProcess, withCreateProcess)
import System.Timeout (timeout)

-- | The two independent bounds every short-lived command subprocess runs
-- under: how long it may take to *exit*, and how much longer than that its
-- output capture may lag before the call gives up on a stream something
-- still holds open. Keeping them separate is what stops an already-observed
-- exit from being reported as a timeout (issue #15). Production values are
-- chosen per runner by its caller; tests inject short values so the
-- deadline and grace paths are reachable without waiting out the real
-- deadlines.
--
-- Long-lived processes are deliberately outside this vocabulary: a backend
-- that is supposed to outlive any single call — the Codex app-server behind
-- 'Kanban.Review.startReviewClient' — has no exit deadline to bound.
data CommandBounds = CommandBounds
  { commandDeadlineMicros :: Int,
    commandCaptureGraceMicros :: Int
  }
  deriving stock (Eq, Show)

-- | The result of running one command subprocess under 'CommandBounds':
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

-- | 'System.Process.readCreateProcessWithExitCode' with its decoding step
-- removed: the same empty stdin, concurrently drained streams and wait for
-- the child's exit, but each stream comes back as the bytes the child
-- actually wrote.
--
-- The decoding step is what had to go. It ran a child's output through
-- whatever encoding the environment happened to name, so a single byte the
-- active locale cannot decode — routine under the C\/POSIX locales of SSH,
-- tmux, cron and launchd sessions — raised an 'IOException' out of a child
-- that had run perfectly well, before its caller's own handling of the exit
-- status ever ran (issues #42, #172). Callers decode what they captured
-- themselves: 'decodeCommandText' for text, and the filesystem encoding for
-- a path that has to survive being handed back to another process.
readProcessBytes :: CreateProcess -> IO (ExitCode, ByteString.ByteString, ByteString.ByteString)
readProcessBytes spec =
  withCreateProcess piped $ \input output errors processHandle ->
    withDrain output $ \awaitOutput ->
      withDrain errors $ \awaitErrors -> do
        -- Empty stdin, closed rather than left open, so a child that reads
        -- sees EOF instead of waiting on a prompt that will never come.
        mapM_ (\handle -> void (try (hClose handle) :: IO (Either IOException ()))) input
        capturedOutput <- awaitOutput
        capturedErrors <- awaitErrors
        exitCode <- waitForProcess processHandle
        pure (exitCode, capturedOutput, capturedErrors)
  where
    piped = spec {std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}

-- | One stream's reader thread, alive for exactly as long as the body needs
-- it. A body that leaves early — an enclosing 'System.Timeout.timeout'
-- firing on a hung child, say — kills the reader before the process cleanup
-- closes its handle, for the reason 'releaseCapture' gives: a blocked
-- reader holds that handle's lock, and a close attempted first would block
-- right behind it.
withDrain :: Maybe Handle -> (IO ByteString.ByteString -> IO result) -> IO result
withDrain Nothing body = body (pure ByteString.empty)
withDrain (Just handle) body =
  bracket startReader (killThread . fst) $ \(_, captured) ->
    body (readMVar captured >>= either throwIO pure)
  where
    startReader = do
      captured <- newEmptyMVar
      reader <- forkIO (try @IOException (ByteString.hGetContents handle) >>= putMVar captured)
      pure (reader, captured)

-- | The one decoding a captured stream's text goes through. Lenient UTF-8
-- rather than the locale's encoding: what a child writes is bytes, so a
-- corrupted or truncated one leaves a replacement character in a readable
-- diagnostic instead of an exception raised from inside the decoder.
decodeCommandText :: ByteString.ByteString -> Text
decodeCommandText = TextEncoding.decodeUtf8With lenientDecode

-- | Renders a bound for a diagnostic. Sub-second bounds only ever come from
-- tests, but they are rendered honestly rather than rounded to \"0 seconds\".
renderWindow :: Int -> Text
renderWindow micros
  | micros >= 1000000 && micros `mod` 1000000 == 0 = Text.pack (show (micros `div` 1000000)) <> unit (micros `div` 1000000) " second"
  | otherwise = Text.pack (show (micros `div` 1000)) <> " ms"
  where
    unit 1 singular = singular
    unit _ singular = singular <> "s"

-- | How much longer than the process itself its output capture may take.
-- Long enough that an ordinary pipe drain always finishes inside it, short
-- enough that a descendant holding the pipe open cannot stall the caller.
captureGraceMicros :: Int
captureGraceMicros = 2 * 1000 * 1000

captureChunkBytes :: Int
captureChunkBytes = 65536
