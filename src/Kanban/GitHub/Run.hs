-- | Running one page's @gh@: resolving it on @PATH@, starting it behind a
-- pre-spawn barrier as the leader of its own process group, draining its
-- pipes, and settling the group before the handle is reaped.
--
-- This is the only module that starts an external process. It is also where
-- every 'IOException' the run can raise picks up the phase it escaped from,
-- because that — not the exception's own text — decides whether the user is
-- told @gh@ is missing.
module Kanban.GitHub.Run
  ( GhFailurePhase (..),
    GhFetchAborted (..),
    GhProcessFailed (..),
    ghBehindBarrier,
    ghFailureKind,
    runGh,
  )
where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (Exception, IOException, bracketOnError, throwIO, try)
import Control.Monad (void)
import Data.Bifunctor (first)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Domain
import Kanban.GitHub.Group (confirmsOwnGroupLeadership, groupMembers, ignoreIOException)
import Kanban.GitHub.Guard (GhCleanupFailure (..), GhCleanupGuard (..), GhFetchGuard, abandonGh, dropGhGroup, ghGroupIsRecorded, recordGhGroup, registerSpawnedGh, setCleanupFailure, uninterruptibleCleanup)
import Kanban.Process (OwnedProcessGroup (..), defaultProcessSnapshot, identityForPid)
import Kanban.Provider (ProviderErrorKind (..))
import System.Directory (findExecutable)
import System.Exit (ExitCode)
import System.IO (hClose, hFlush, hPutStrLn)
import System.IO.Error (doesNotExistErrorType, isDoesNotExistError, isPermissionError, mkIOError)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process
  ( CreateProcess (..),
    StdStream (CreatePipe),
    createProcess,
    proc,
    waitForProcess,
  )

-- | Runs one page's @gh@ as the leader of its own process group, so a fetch
-- that gets abandoned can be cleaned up as a group rather than as a lone
-- child. 'readProcessWithExitCode', which this replaces, terminates only the
-- direct child and never confirms it exited: a @gh@ wedged on network I\/O
-- and ignoring TERM, or one that has spawned a credential helper, could
-- outlive the timeout that reported it dead and still be running when the
-- next refresh starts another one.
--
-- Every 'IOException' the run can raise leaves here tagged with the half it
-- came out of, because that — not the exception's own text — is what decides
-- whether the user is told @gh@ is missing. Resolution and spawning are the
-- only places where a failure can still mean "there is no @gh@ to run"; once
-- the child exists, @gh@ demonstrably launched, and an exception is about
-- this run rather than about the installation.
runGh :: GhFetchGuard -> Repository -> [String] -> IO (ExitCode, ByteString.ByteString, ByteString.ByteString)
runGh guard repository arguments = afterLaunch $ do
  resolved <- duringLaunch (findExecutable "gh")
  case resolved of
    Nothing -> duringLaunch (ioError (mkIOError doesNotExistErrorType "gh" Nothing (Just "gh")))
    Just ghPath -> bracketOnError (duringLaunch (createProcess (ghProcess ghPath))) cleanUp run
  where
    -- 'GhProcessFailed' is not an 'IOException', so a launch failure tagged
    -- here passes straight back out through 'afterLaunch' rather than being
    -- caught and retagged as one. That is what keeps the outer tag total —
    -- covering the cleanup handler too — without it ever overwriting a phase
    -- already established.
    duringLaunch = taggedAs GhLaunching
    afterLaunch = taggedAs GhRunning

    taggedAs phase action = try @IOException action >>= either (throwIO . GhProcessFailed phase) pure

    cleanUp spawned = uninterruptibleCleanup (abandonGh guard repository spawned)

    ghProcess ghPath =
      (uncurry proc (ghBehindBarrier ghPath arguments))
        { std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }

    -- The child exists but has not run @gh@ yet, and cannot until this
    -- releases it. So the durable guard is not merely written early -- there
    -- is no instant at which a @gh@ is running that the record does not
    -- already cover. Losing the dashboard anywhere in here closes the pipe,
    -- the barrier reads EOF, and the child exits without ever having
    -- executed anything.
    run spawned@(input, _, _, _) = do
      registered <- registerSpawnedGh guard repository spawned
      case registered of
        Left message -> throwIO (GhGuardUnwritable message)
        -- The PID comes from the registration, captured while the child was
        -- still unreaped: 'collect' waits on the handle, and 'getPid' goes
        -- 'Nothing' the moment it does, which would leave the entry behind.
        Right groupPid -> do
          -- Asked while the child is alive and still parked on the barrier,
          -- which is the one moment it is guaranteed observable and has done
          -- nothing yet. Everything downstream reasons about the pgid as if
          -- it named this fetch's group; that is only true if the child
          -- actually leads it, and this is where that becomes a fact rather
          -- than an assumption.
          --
          -- Refusing here costs nothing, because gh has not run: there are no
          -- descendants to account for and nothing to clean up but the parked
          -- shell itself, which is killed by PID -- the one identity that is
          -- meaningful when the group is not ours.
          leads <- confirmsOwnGroupLeadership groupPid
          case leads of
            Left message -> do
              ignoreIOException (signalProcess sigKILL (fromIntegral groupPid))
              void (try @IOException (waitForProcess processHandleOf))
              throwIO (GhGroupUnresolved message)
            Right () -> do
              released <- releaseBarrier input
              case released of
                Left message -> throwIO (GhGuardUnwritable message)
                Right () -> collect groupPid spawned
      where
        (_, _, _, processHandleOf) = spawned

    -- Writing the go-ahead is also what hands gh its (immediately closed)
    -- standard input, so the barrier costs the child nothing it would
    -- otherwise have had.
    releaseBarrier Nothing = pure (Left "gh was started without a standard input to release it through")
    releaseBarrier (Just input) = do
      written <- try @IOException (hPutStrLn input "" >> hFlush input)
      pure (first (Text.pack . show) written)

    collect groupPid (input, output, errors, processHandle) = do
      mapM_ (ignoreIOException . hClose) input
      standardOutput <- drain output
      standardError <- drain errors
      -- Both pipes are drained to EOF before the exit status is collected,
      -- exactly as 'readProcessWithExitCode' did, so a response larger than
      -- the pipe buffer cannot deadlock gh against a reader that has not run
      -- yet.
      capturedOutput <- takeMVar standardOutput >>= either throwIO pure
      capturedError <- takeMVar standardError >>= either throwIO pure
      settled <- settleGroup groupPid
      case settled of
        -- gh has exited and nothing it led is left, so the guard covering it
        -- has nothing left to cover.
        Right () -> do
          exitCode <- waitForProcess processHandle
          dropGhGroup guard repository groupPid
          pure (exitCode, capturedOutput, capturedError)
        -- A member outlived the process that led it -- closing the pipes is
        -- not exiting, and a descendant can do the first without the second.
        -- The record stays, naming what is left, so the next fetch reclaims
        -- it with the full ownership machinery instead of starting a gh
        -- beside it.
        --
        -- The finding is published to the guard before the handle is reaped,
        -- and that order is deliberate: reaping is exactly what makes this
        -- group unfindable from the cleanup path, where 'getPid' turns
        -- 'Nothing' and there is no longer anything to census. A refresh
        -- timeout arriving from here on would otherwise find nothing amiss
        -- and report an ordinary timeout over a descendant this already knew
        -- about.
        Left (message, survivors) -> do
          setCleanupFailure guard (GhCleanupFailure message GuardInMemoryOnly)
          void (recordGhGroup guard repository (OwnedProcessGroup groupPid survivors True))
          recorded <- ghGroupIsRecorded guard repository groupPid
          setCleanupFailure guard (GhCleanupFailure message (if recorded then GuardRecorded else GuardInMemoryOnly))
          -- Deliberately not reaped. Reaping is what frees the PID and with
          -- it the pgid, and the cleanup this throw is about to trigger needs
          -- both: with them it can escalate against the survivors and prove
          -- what became of them, and only a cleanup that proves the group
          -- empty is allowed to take this finding back off the guard.
          throwIO (GhGroupUnresolved message)

    -- Establishes what became of the group, entirely before the handle is
    -- reaped. That ordering is the whole argument: until the leader is waited
    -- on, its PID stays allocated, so the pgid cannot be reissued and
    -- everything the census finds in it is genuinely this fetch's.
    --
    -- Waiting for the leader to leave the live process table first matters
    -- just as much as the census that follows. A leader that is still running
    -- can still fork, so a census taken while it lives says nothing about a
    -- descendant appearing a moment later; one taken after it has exited --
    -- but before it is reaped -- cannot be overtaken that way. A zombie is
    -- excluded from the table yet still holds its PID, which is exactly the
    -- window this needs.
    settleGroup groupPid = do
      departed <- awaitLeaderDeparture groupPid leaderDeparturePolls
      case departed of
        Left message -> pure (Left (message, []))
        Right () -> do
          snapshot <- defaultProcessSnapshot
          pure $ case snapshot of
            -- No census is not an empty group. Refusing here costs a refresh;
            -- assuming would cost the guarantee.
            Left message -> Left ("could not confirm gh's process group was empty: " <> message, [])
            Right processes -> case groupMembers groupPid processes of
              [] -> Right ()
              survivors ->
                Left
                  ( "gh exited but "
                      <> Text.pack (show (length survivors))
                      <> " process(es) it led (pgid "
                      <> Text.pack (show groupPid)
                      <> ") are still running",
                    survivors
                  )

    awaitLeaderDeparture groupPid pollsLeft = do
      snapshot <- defaultProcessSnapshot
      case snapshot of
        Left message -> pure (Left ("could not watch for gh's exit: " <> message))
        Right processes
          | identityForPid groupPid processes == Nothing -> pure (Right ())
          | pollsLeft <= (0 :: Int) -> pure (Left "gh closed its output but was still running when its process group had to be settled")
          | otherwise -> threadDelay leaderDeparturePollMicros >> awaitLeaderDeparture groupPid (pollsLeft - 1)

    -- Each reader owns its handle for the handle's whole life, including
    -- closing it. Closing from here instead would mean closing a handle a
    -- reader thread may still be blocked on, which takes the handle's lock
    -- and would hang the very cleanup that has to finish promptly.
    --
    -- Bytes, not locale-decoded text. 'hGetContents'' would have run @gh@'s
    -- output through whatever encoding the environment happened to name, so
    -- a non-ASCII issue title under a C or POSIX locale — the everyday case
    -- over SSH, cron and launchd — threw an invalid-byte 'IOException' out
    -- of a perfectly healthy fetch. Reading raw and decoding once, leniently,
    -- as UTF-8 keeps both the success and the failure paths independent of
    -- the environment.
    drain Nothing = newEmptyMVar >>= \captured -> putMVar captured (Right ByteString.empty) >> pure captured
    drain (Just handle) = do
      captured <- newEmptyMVar
      void . forkIO $ do
        bytes <- try @IOException (ByteString.hGetContents handle)
        ignoreIOException (hClose handle)
        putMVar captured bytes
      pure captured

-- | How long a gh that has closed its output gets to actually exit before its
-- group is called unsettled. Draining to EOF normally means it is already
-- gone, so this is a margin rather than a wait.
leaderDeparturePolls :: Int
leaderDeparturePolls = 20

leaderDeparturePollMicros :: Int
leaderDeparturePollMicros = 50 * 1000

-- | The argv that starts @gh@ behind a barrier: a shell that waits for a
-- line on standard input and only then replaces itself with @gh@.
--
-- This is what makes the durable guard genuinely a /pre/-spawn guard. Writing
-- the record straight after 'createProcess' would still leave a window —
-- short, but real — in which @gh@ is running and nothing on disk names it, so
-- losing the dashboard there would strand it unguarded. Here the child cannot
-- reach @gh@ until the record is committed, and because the wait ends on EOF
-- as well as on input, a parent that dies in that window closes the pipe and
-- the child exits without ever executing anything.
--
-- @exec@ matters: the shell is replaced rather than forked, so the PID and
-- process group the record names are exactly the ones @gh@ ends up running
-- under.
-- The executable is resolved by the parent rather than left to the shell's
-- @exec@, so a missing or non-executable @gh@ is still reported as
-- 'ExecutableMissing' from the spawn site instead of arriving later as an
-- indistinguishable nonzero exit from inside the barrier.
ghBehindBarrier :: FilePath -> [String] -> (FilePath, [String])
ghBehindBarrier ghPath arguments = ("sh", ["-c", "read -r _release_ || exit 0; exec \"$0\" \"$@\"", ghPath] <> arguments)

-- | Raised when the durable guard covering a freshly spawned @gh@ cannot be
-- written. It is raised rather than returned so the spawn unwinds through
-- 'Kanban.GitHub.Guard.abandonGh' and that @gh@ is terminated: a process this
-- fetch started must never outlive the record that would have accounted for
-- it.
data GhFetchAborted
  = -- | The durable guard covering a freshly spawned @gh@ could not be
    -- written, so that @gh@ was stopped rather than left running unguarded.
    GhGuardUnwritable Text
  | -- | @gh@ finished, but something it led did not, and the group could not
    -- be confirmed empty. The record is left in place for a later fetch to
    -- reclaim rather than this one carrying on beside it.
    GhGroupUnresolved Text
  deriving stock (Show)

instance Exception GhFetchAborted

-- | An 'IOException' raised somewhere in the @gh@ path, carrying the phase it
-- escaped from. The phase travels with it because the exception alone cannot
-- answer the only question the board asks of it: whether the user should be
-- sent to install @gh@.
data GhProcessFailed = GhProcessFailed GhFailurePhase IOException
  deriving stock (Show)

instance Exception GhProcessFailed

-- | Which half of a @gh@ run a failure came out of.
data GhFailurePhase
  = -- | No child exists yet: @gh@ is still being resolved on @PATH@ or
    -- spawned. This is the only phase in which "there is no runnable @gh@"
    -- is still a possible explanation.
    GhLaunching
  | -- | The child was created, so @gh@ launched. Anything that goes wrong
    -- from here — a read that fails mid-response, a pipe that breaks, a
    -- descriptor limit — is about this request, not about the installation.
    GhRunning
  deriving stock (Eq, Show)

-- | Maps one @gh@ failure onto the vocabulary §17 renders. 'ExecutableMissing'
-- becomes @NOT INSTALLED@, which is only ever the truth for a launch that
-- failed because there was nothing to launch: no such file, or a file that
-- cannot be executed. Every other launch error — a descriptor limit, a fork
-- failure — and every post-launch error is 'RequestFailed', so a working,
-- authenticated @gh@ is never reported as absent.
ghFailureKind :: GhFailurePhase -> IOException -> ProviderErrorKind
ghFailureKind GhLaunching exception
  | isDoesNotExistError exception = ExecutableMissing
  | isPermissionError exception = ExecutableMissing
  | otherwise = RequestFailed
ghFailureKind GhRunning _ = RequestFailed
