{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | A single bounded-retry line reader shared by every stdout/stderr
-- streaming loop in "Kanban.Solve" and "Kanban.PullRequestFlow", so the two
-- modules no longer diverge on read-failure behavior: one abandons a
-- provider's pipe silently while the provider keeps writing (hanging
-- 'System.Process.waitForProcess' until a much later watchdog), another
-- busy-loops on a persistent error, and a third can let an exception from
-- its EOF probe skip its own completion signal entirely, deadlocking a
-- parent's 'Control.Concurrent.MVar.takeMVar'. This module fixes all three
-- shapes in one place: EOF always ends the loop normally; a read exception
-- is retried a small, fixed number of times before the reader gives up;
-- and giving up terminates the still-live provider and reports why, rather
-- than leaving the pipe to fill or the loop to spin.
module Kanban.StreamReader
  ( StreamOutcome (..),
    maxConsecutiveReadFailures,
    handleReadLine,
    runStreamReader,
    runStreamReaderWith,
    onStreamAbandoned,
  )
where

import Control.Applicative ((<|>))
import Control.Exception (IOException, try)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.IORef (IORef, atomicModifyIORef')
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Process (ManagedProcess, killManagedProcess)
import System.IO (Handle, hIsEOF)

-- | Whether a bounded stream reader consumed its handle to a normal EOF, or
-- gave up after a run of consecutive read failures exhausted its bound.
data StreamOutcome = StreamCompleted | StreamAbandoned
  deriving stock (Eq, Show)

-- | The consecutive-failure budget shared by every stdout/stderr reader:
-- small enough that a persistent read error surfaces within seconds rather
-- than at a watchdog deadline, large enough to absorb one transient failure
-- (e.g. an interrupted system call) without tearing down a healthy
-- provider. The count resets to this value after every successful read, so
-- only a *run* of consecutive failures can exhaust it.
maxConsecutiveReadFailures :: Int
maxConsecutiveReadFailures = 5

-- | Probes for EOF and, if there is more to read, reads one line — the two
-- operations every current reader site performs, and the two operations
-- whose 'IOException' must not escape uncaught: an exception from either
-- one counts as a single read failure.
handleReadLine :: Handle -> IO (Either IOException (Maybe ByteString.ByteString))
handleReadLine handle = do
  eofResult <- try (hIsEOF handle)
  case eofResult of
    Left exception -> pure (Left exception)
    Right True -> pure (Right Nothing)
    Right False -> fmap Just <$> try (ByteStringChar8.hGetLine handle)

-- | Reads newline-delimited lines from a live provider's 'Handle', forwarding
-- each to 'onLine', until EOF or until 'maxConsecutiveReadFailures'
-- consecutive read failures give up. See 'runStreamReaderWith' for the
-- retry/abandonment contract.
runStreamReader :: Handle -> Text -> (ByteString.ByteString -> IO ()) -> (Text -> IO ()) -> IO StreamOutcome
runStreamReader handle = runStreamReaderWith (handleReadLine handle)

-- | As 'runStreamReader', but reads via an injected action instead of a real
-- 'Handle' — the seam tests use to deterministically exercise a read
-- exception (as opposed to ordinary EOF, which every reader already treats
-- as a normal return and must keep doing). On EOF ('Right Nothing'),
-- returns 'StreamCompleted'. A read failure ('Left') is retried; the
-- remaining budget resets to 'maxConsecutiveReadFailures' after every
-- successful read, so only a run of consecutive failures can exhaust it.
-- Once exhausted, 'onAbandon' is called with a diagnostic reason (naming
-- the failure count and the last exception) and 'StreamAbandoned' is
-- returned, instead of either looping forever on the error or returning
-- silently as if nothing had gone wrong.
runStreamReaderWith :: IO (Either IOException (Maybe ByteString.ByteString)) -> Text -> (ByteString.ByteString -> IO ()) -> (Text -> IO ()) -> IO StreamOutcome
runStreamReaderWith readLine streamTag onLine onAbandon = go maxConsecutiveReadFailures Nothing
  where
    go remaining lastFailure
      | remaining <= 0 = do
          onAbandon
            ( streamTag
                <> " stream reader gave up after "
                <> Text.pack (show maxConsecutiveReadFailures)
                <> " consecutive read failures"
                <> maybe "" ((": " <>) . Text.pack . show) lastFailure
            )
          pure StreamAbandoned
      | otherwise = do
          result <- readLine
          case result of
            Left exception -> go (remaining - 1) (Just exception)
            Right Nothing -> pure StreamCompleted
            Right (Just line) -> onLine line >> go maxConsecutiveReadFailures Nothing

-- | The abandonment response shared by every reader call site: surface the
-- diagnostic, remember the first reason so the invocation's terminal
-- outcome can be forced to a failure even if the provider's own exit code
-- races to success, and terminate the still-live provider so a caller's
-- 'System.Process.waitForProcess' can never block behind a pipe nobody is
-- reading anymore.
onStreamAbandoned :: (Text -> IO ()) -> ManagedProcess -> IORef (Maybe Text) -> Text -> IO ()
onStreamAbandoned emitDiagnostic managed abandonReasonRef reason = do
  emitDiagnostic reason
  atomicModifyIORef' abandonReasonRef (\existing -> (existing <|> Just reason, ()))
  killManagedProcess managed
