-- | One managed-service controller invocation: run as the leader of its own
-- process group, bounded by a timeout, and cleaned up as a group when that
-- timeout expires.
--
-- Extracted from "Kanban.Drainer", which is still one caller, so that
-- "Kanban.ApprovalService" gets the same process discipline rather than a
-- second copy of it that could drift. Nothing here knows which service it is
-- running: the only thing a caller supplies beyond the command is the
-- 'subject' its ownership diagnostics name, so each service's messages stay
-- its own.
module Kanban.ServiceProcess
  ( InvocationFailure (..),
    diagnosticMessage,
    invocationFailureMessage,
    runGroupedProcess,
    serviceTransitionCommand,
  )
where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, try)
import Control.Monad (void)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Process
  ( ProcessIdentity (..),
    defaultProcessSnapshot,
    killVerifiedGroup,
  )
import System.Exit (ExitCode (..))
import System.IO (hClose, hGetContents')
import System.Posix.Process (getProcessGroupIDOf, setProcessGroupIDOf)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (..),
    createProcess,
    getPid,
    proc,
    waitForProcess,
  )
import System.Timeout (timeout)

-- | Why a controller invocation produced no exit status at all. Rendering is
-- left to the caller because what a timeout means depends on the operation:
-- a killed @status@ query changed nothing, whereas a @start@ or @stop@ cut
-- short mid-transition leaves the service manager in a state only the next
-- poll can establish.
data InvocationFailure
  = -- | The controller could not be run, or died taking the invocation with it.
    InvocationFailed Text
  | -- | Timed out, then terminated and confirmed gone.
    InvocationTimedOut
  | -- | Timed out, and termination could not be confirmed — so unlike
    -- 'InvocationTimedOut' the controller may still be running, and the
    -- caller must not report this as a settled timeout.
    InvocationNotTerminated Text

-- | Which controller subcommands have a state consequence the next status
-- poll settles. Shared by both services because both spell the two
-- transitions the same way, and because a service that classified them
-- differently would render a timed-out transition as though nothing had
-- happened.
serviceTransitionCommand :: String -> Bool
serviceTransitionCommand command = command == "start" || command == "stop"

diagnosticMessage :: String -> String -> Text
diagnosticMessage output errors = Text.strip . Text.pack $ if null errors then output else errors

-- | Renders an invocation that never produced an exit status. @reconciles@
-- says the operation has a state consequence the ten-second status poll will
-- settle, which is true of @start@ and @stop@ and of nothing else here: a
-- transition killed part-way through leaves launchd in a state this process
-- genuinely does not know, and saying only "timed out" would read as
-- "nothing happened". A cleanup that could not confirm termination never
-- gets that reconciliation promise, because a controller that may still be
-- running can still change the state the poll is about to read.
invocationFailureMessage :: Int -> Text -> Bool -> InvocationFailure -> Text
invocationFailureMessage seconds label reconciles failure = case failure of
  InvocationFailed message -> message
  InvocationTimedOut
    | reconciles -> timedOut <> "; the outcome is unknown and the next status poll will reconcile it"
    | otherwise -> timedOut
  InvocationNotTerminated message -> timedOut <> "; " <> message
  where
    timedOut = label <> " timed out after " <> Text.pack (show seconds) <> " seconds"

-- | Runs one controller invocation as the leader of its own process group,
-- so a wedged one can be cleaned up as a group rather than as a lone child.
-- 'System.Process.readProcessWithExitCode', which this replaces, terminates
-- only the direct child on abandonment and never confirms it exited: a
-- controller ignoring TERM, or one that has left a @launchctl@ behind, could
-- outlive the timeout that reported it dead and still be running when the
-- next ten-second poll starts another one.
--
-- @subject@ names the controller in the ownership diagnostics below, so each
-- service reports its own rather than the other's.
--
-- 'Nothing' seconds runs the invocation to completion however long it takes.
-- Exactly one caller wants that — the drainer's single-pull-request merge,
-- whose work is irreversible partway through, so abandoning it on a deadline
-- would be worse than waiting. Every other invocation is a status read or a
-- service transition, which has a budget precisely because nothing is lost by
-- cutting it short.
runGroupedProcess :: Text -> Maybe Int -> FilePath -> [String] -> IO (Either InvocationFailure (ExitCode, String, String))
runGroupedProcess subject seconds executable arguments = do
  spawned <- try @IOException (createProcess groupedProcess)
  case spawned of
    Left exception -> pure (Left (InvocationFailed (Text.pack (show exception))))
    Right handles -> do
      -- Taken before the invocation can finish, so it is still answerable.
      owned <- confirmOwnedGroup subject (processHandleOf handles)
      completed <- try @IOException (withBudget (collect handles))
      case completed of
        Left exception -> do
          void (abandonController subject owned)
          pure (Left (InvocationFailed (Text.pack (show exception))))
        Right (Just outcome) -> pure (Right outcome)
        Right Nothing -> do
          terminated <- abandonController subject owned
          case terminated of
            Left message -> pure (Left (InvocationNotTerminated message))
            -- Confirmed gone, so the handle is at most an unreaped zombie and
            -- waiting on it cannot block. Skipped entirely when termination
            -- was not confirmed, where it could block forever.
            Right () -> do
              void (try @IOException (waitForProcess (processHandleOf handles)))
              pure (Left InvocationTimedOut)
  where
    -- An unbounded run cannot time out, so 'collect' is simply awaited and
    -- the abandonment branches below stay unreachable for it.
    withBudget action = case seconds of
      Nothing -> Just <$> action
      Just budget -> timeout (budget * 1000 * 1000) action

    groupedProcess =
      (proc executable arguments)
        { std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }

    processHandleOf (_, _, _, processHandle) = processHandle

    -- Both pipes are drained concurrently and to EOF before the exit status
    -- is collected, exactly as 'readProcessWithExitCode' did, so output
    -- larger than a pipe buffer cannot deadlock the controller against a
    -- reader that has not run yet.
    collect (input, output, errors, processHandle) = do
      mapM_ (ignoreIOException . hClose) input
      standardOutput <- drain output
      standardError <- drain errors
      capturedOutput <- takeMVar standardOutput
      capturedError <- takeMVar standardError
      exitCode <- waitForProcess processHandle
      pure (exitCode, capturedOutput, capturedError)

    -- Each reader owns its handle for the handle's whole life, including
    -- closing it. Closing from here instead would take a lock a reader
    -- thread may still be blocked on, and would hang the cleanup that has to
    -- finish promptly. A read that fails contributes nothing rather than
    -- killing the invocation: the exit status and the other stream still say
    -- something worth reporting.
    drain Nothing = newEmptyMVar >>= \captured -> putMVar captured "" >> pure captured
    drain (Just handle) = do
      captured <- newEmptyMVar
      void . forkIO $ do
        text <- try @IOException (hGetContents' handle)
        ignoreIOException (hClose handle)
        putMVar captured (either (const "") id text)
      pure captured

-- | Establishes that the controller leads the process group named by its own
-- PID, while it is still known alive and before anything depends on the
-- answer. Taking ownership here rather than at cleanup time is what lets a
-- timeout terminate the group even after the controller itself has exited:
-- a leader that exits into a zombie is gone from every process snapshot, yet
-- a descendant holding the inherited pipes open is exactly what kept the
-- read blocked long enough to time out. Asked only at cleanup, that case is
-- indistinguishable from a pgid this process never owned, and refusing it
-- would leave the descendant running for the next poll to overlap.
--
-- The recorded pgid stays valid for the rest of the invocation because the
-- handle is not reaped until after cleanup: the leader keeps its PID, and a
-- zombie remains a member of its own group, so neither the PID nor the group
-- id it names can be recycled underneath this.
confirmOwnedGroup :: Text -> ProcessHandle -> IO (Either Text Int)
confirmOwnedGroup subject processHandle = do
  spawnedPid <- getPid processHandle
  case spawnedPid of
    Nothing -> pure (Left (subject <> " reported no PID to take ownership of"))
    Just pid -> do
      -- @create_group@ has the child call @setpgid(0, 0)@ itself, but that
      -- happens after the fork, so a read taken right now could still see
      -- the old group and wrongly conclude the child leads nothing. POSIX
      -- allows the parent to set the same group for a child that has not
      -- exec'd, which closes precisely that window. The attempt is not
      -- itself the verdict — failing with EACCES only means the child got
      -- there first — so the read below is the sole authority either way.
      void (try @IOException (setProcessGroupIDOf pid pid))
      actual <- try @IOException (getProcessGroupIDOf pid)
      pure $ case actual of
        Left exception -> Left ("could not read " <> subject <> "'s process group: " <> Text.pack (show exception))
        Right groupId
          | groupId == pid -> Right (fromIntegral pid)
          | otherwise -> Left (subject <> " did not lead its own process group, so what it starts cannot be terminated with it")

-- | Terminates a timed-out controller and everything it left running,
-- re-censusing and re-killing until a fresh snapshot shows the group empty
-- or the pass budget runs out. An ownership failure carried in from
-- 'confirmOwnedGroup' fails closed here, because the caller's alternative —
-- reporting a settled timeout — would be a claim about a process this never
-- actually accounted for.
--
-- One pass is not enough, and not merely as a race technicality.
-- 'killVerifiedGroup' stops as soon as the members it censused before
-- signalling are gone, which means a TERM handler that forks a fresh
-- same-group child and then lets the censused members exit satisfies that
-- pass without SIGKILL ever being sent — leaving the group occupied by a
-- process no signal has yet reached. Each pass therefore begins with a new
-- census, and only a snapshot showing the group actually empty ends the
-- loop: a snapshot that could not be taken is not an empty group, and
-- neither is one this stopped looking at.
abandonController :: Text -> Either Text Int -> IO (Either Text ())
abandonController _ (Left ownership) = pure (Left ownership)
abandonController subject (Right groupPid) = terminatePass terminationPasses
  where
    terminatePass passesLeft = do
      snapshot <- defaultProcessSnapshot
      case snapshot of
        Left message -> pure (Left ("could not take a process snapshot to terminate it: " <> message))
        -- An empty census is the confirmation, not a precondition: the
        -- leader may already be a zombie, which every snapshot here
        -- excludes, so this never requires it to be present.
        Right processes -> case groupMembers groupPid processes of
          [] -> pure (Right ())
          members
            | passesLeft <= (0 :: Int) -> pure (Left (survivorMessage members))
            | otherwise -> do
                killed <- killVerifiedGroup groupPid members
                either (pure . Left) (const (terminatePass (passesLeft - 1))) killed

    survivorMessage members =
      Text.pack (show (length members))
        <> " process(es) " <> subject <> " led were still running after "
        <> Text.pack (show terminationPasses)
        <> " termination passes"

groupMembers :: Int -> [ProcessIdentity] -> [ProcessIdentity]
groupMembers groupPid = filter ((== groupPid) . processIdentityGroupPid)

ignoreIOException :: IO () -> IO ()
ignoreIOException action = void (try @IOException action)

-- | How many escalation passes a timed-out invocation gets before it reports
-- survivors; a final census after the last one decides the verdict. Two is
-- the minimum that can settle a TERM handler which forks a replacement and
-- exits — the first pass ends on the censused members' departure without
-- ever reaching SIGKILL, and the second finds and kills what it left behind
-- — so three leaves one pass of margin without letting a controller that
-- forks on every signal hold the cleanup open indefinitely.
terminationPasses :: Int
terminationPasses = 3
