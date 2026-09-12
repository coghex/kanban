{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | An independent process running one notification command, so that stopping
-- it can be observed from outside (issue #666, requirement 11).
--
-- The hazard this exists for cannot be staged in-process. A notification
-- command is started in a process group of its own, which is what lets the
-- ordinary sweep end it and everything it spawned; but it also means the
-- supervisor above the scheduler — which signals the /scheduler's/ group —
-- cannot reach it. So the scheduler has to sweep it itself on the way out, and
-- \"on the way out\" here means a signal handler running in a process that is
-- being killed. A test that called the handler directly would prove the sweep
-- works, which is already known, rather than that a stop reaches it.
--
-- The shape is "Spec.Support.MissionProbes"'s: a marker in the child's
-- environment diverts this suite's own binary out of hspec and into
-- 'runNotifyProbe', and answers come back through files. What is different is
-- only what the probe is asked to do — run one stubborn notifier and wait to
-- be killed — and that the parent's instrument is a signal rather than a gate.
module Spec.Support.NotifyProbe
  ( notifyProbeVariable,
    runNotifyProbe,
    withStubbornNotifier,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, try)
import Control.Monad (void)
import qualified Data.Text as Text
import Kanban.Mission (missionNotificationTimeoutMicros, runMissionNotificationCommand)
import System.Directory (removePathForcibly)
import System.Environment (getExecutablePath)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (signalProcess, sigTERM)
import System.Process
  ( CreateProcess (..),
    StdStream (CreatePipe),
    createProcess,
    proc,
    terminateProcess,
    waitForProcess,
  )
import Test.Hspec (expectationFailure)

notifyProbeVariable :: String
notifyProbeVariable = "KANBAN_NOTIFY_PROBE"

-- | The probe half, reached from @main@ when 'notifyProbeVariable' is set.
--
-- Runs one notification command that ignores @SIGTERM@ and sleeps, under a
-- bound long enough that the parent's signal always arrives first. The call
-- never returns: the parent ends this process, and what the example is about
-- is what that leaves behind.
runNotifyProbe :: FilePath -> IO ()
runNotifyProbe directory = do
  let command = directory </> "stubborn-notifier"
      marker = directory </> "notifier.pid"
  writeFile
    command
    ( unlines
        [ "#!/bin/sh",
          "trap '' TERM INT",
          "echo $$ > " <> show marker,
          "sleep 120"
        ]
    )
  setFileMode command 0o700
  processId <- getProcessID
  writeFile (directory </> "probe.pid") (show processId)
  void (runMissionNotificationCommand missionNotificationTimeoutMicros [Text.pack command])
  -- Unreachable in the ordinary case; if the parent's signal never lands, this
  -- stops the probe outliving the example rather than hanging the suite.
  threadDelay (30 * 1000 * 1000)

-- | Runs a probe, waits until its notifier is up, stops the probe, and hands
-- back the notifier's process identifier.
--
-- Every exit reaps the probe, so an example that fails cannot leave one
-- behind.
withStubbornNotifier :: forall result. FilePath -> (Int -> IO result) -> IO result
withStubbornNotifier directory body = do
  executable <- getExecutablePath
  bracket (start executable) reap $ \handle -> do
    notifier <- awaitPid (directory </> "notifier.pid")
    stop handle
    body notifier
  where
    start executable = do
      created <-
        createProcess
          (proc executable [])
            { env = Just [(notifyProbeVariable, directory), ("PATH", "/usr/bin:/bin")],
              std_out = CreatePipe,
              std_err = CreatePipe
            }
      case created of
        (_, _, _, processHandle) -> pure processHandle

    -- Signalled by identifier rather than by group: the probe is the
    -- scheduler's stand-in, and what is being tested is that *it* cleans up
    -- the group it started, not that a group signal reached both.
    stop processHandle = do
      probe <- awaitPid (directory </> "probe.pid")
      void (try @IOException (signalProcess sigTERM (fromIntegral probe)))
      void (waitForProcess processHandle)

    reap processHandle = do
      void (try @IOException (terminateProcess processHandle))
      void (try @IOException (waitForProcess processHandle))
      void (try @IOException (removePathForcibly (directory </> "notifier.pid")))

    awaitPid :: FilePath -> IO Int
    awaitPid path = go (1500 :: Int)
      where
        go 0 = do
          expectationFailure ("no process identifier was recorded at " <> path)
          pure 0
        go remaining = do
          contents <- try @IOException (readFile path)
          case contents of
            Right recorded
              | (digits@(_ : _), _) <- span (`elem` ("0123456789" :: String)) recorded ->
                  pure (read digits)
            _ -> threadDelay 20000 >> go (remaining - 1)
