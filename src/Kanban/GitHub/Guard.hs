-- | The guard that accounts for every @gh@ a board fetch starts: the
-- in-memory cleanup verdict the refresh reads, the durable record on disk
-- that outlives the dashboard, and the reclamation a later fetch performs
-- before it is allowed to spawn anything.
--
-- This is where a possibly-live @gh@ is turned into something the board can
-- refuse to refresh over. It asks 'Kanban.GitHub.Group' what became of a
-- process group and writes the answer down; it does not run @gh@ itself,
-- which is what keeps it below 'Kanban.GitHub.Run'.
module Kanban.GitHub.Guard
  ( GhCleanupFailure (..),
    GhCleanupGuard (..),
    GhFetchGuard,
    abandonGh,
    clearCleanupFailure,
    dropGhGroup,
    ghFetchCleanupFailure,
    ghGroupIsRecorded,
    newGhFetchGuard,
    reclaimRecordedGhGroups,
    recordGhGroup,
    registerSpawnedGh,
    setCleanupFailure,
    uninterruptibleCleanup,
    uninterruptiblyBounded,
  )
where

import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Exception (IOException, finally, try, uninterruptibleMask_)
import Control.Monad (unless, void, when)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Cache (GhGroupRecordLoad (..), loadGhGroupRecord, removeGhGroupRecord, writeGhGroupRecord)
import Kanban.Domain
import Kanban.GitHub.Group (forceKillGhGroup, freezeThenKillOwnedGroup, groupCleanupPasses, groupConfirmedEmpty, groupMembers, ignoreIOException, killGhGroup)
import Kanban.Process (OwnedProcessGroup (..), defaultProcessSnapshot, matchingIdentities, membersStillInGroup)
import System.IO (Handle, hClose)
import System.Process (ProcessHandle, getPid, waitForProcess)
import System.Timeout (timeout)

-- | Records whether the @gh@ process group an abandoned board fetch left
-- running could actually be confirmed dead.
--
-- 'Kanban.GitHub.fetchGitHubSnapshot' is meant to be run under
-- 'System.Timeout.timeout', so it is abandoned by an asynchronous exception
-- rather than by returning a value: the unwinding is where the still-running
-- @gh@ gets cleaned up, and this is the only channel through which the
-- outcome of that cleanup can reach the caller. 'Just' means the group may
-- still be live, so the caller must not report an ordinary clean timeout.
newtype GhFetchGuard = GhFetchGuard (IORef (Maybe GhCleanupFailure))

-- | A cleanup that could not confirm its @gh@ group is gone.
data GhCleanupFailure = GhCleanupFailure
  { ghCleanupMessage :: Text,
    ghCleanupGuard :: GhCleanupGuard
  }
  deriving stock (Eq, Show)

-- | What is keeping a possibly-live @gh@ from being overlapped, now that its
-- death could not be confirmed.
--
-- There is deliberately no third state for "killed but unproven". Whether a
-- signal was sent is not evidence; only a fresh snapshot showing the group
-- gone is, and a cleanup that has that does not report a failure at all. So
-- the only question left here is whether the guard outlives this dashboard.
data GhCleanupGuard
  = -- | The group is on disk. Any later fetch re-checks it before spawning
    -- anything, in this dashboard or one started long afterwards.
    GuardRecorded
  | -- | Nothing could be recorded. This dashboard's refusal to refresh is all
    -- that remains, and it is worth nothing once the dashboard exits — so
    -- this is the one case that must never suggest a restart.
    GuardInMemoryOnly
  deriving stock (Eq, Show)

newGhFetchGuard :: IO GhFetchGuard
newGhFetchGuard = GhFetchGuard <$> newIORef Nothing

ghFetchCleanupFailure :: GhFetchGuard -> IO (Maybe GhCleanupFailure)
ghFetchCleanupFailure (GhFetchGuard cleanupFailure) = readIORef cleanupFailure

setCleanupFailure :: GhFetchGuard -> GhCleanupFailure -> IO ()
setCleanupFailure (GhFetchGuard cleanupFailure) = writeIORef cleanupFailure . Just

clearCleanupFailure :: GhFetchGuard -> IO ()
clearCleanupFailure (GhFetchGuard cleanupFailure) = writeIORef cleanupFailure Nothing

-- | Cleans up the @gh@ an abandoned fetch walked away from: TERM, then KILL,
-- the whole process group it leads, confirmed against a fresh process
-- snapshot rather than assumed from the act of signalling. A group that
-- could not be terminated or could not be confirmed gone is both recorded on
-- the guard — a possibly-live @gh@ is not a clean timeout and must not be
-- reported as one — and written to the durable record, so the very next
-- fetch re-verifies it before spawning anything, even if the dashboard is
-- restarted in between.
abandonGh :: GhFetchGuard -> Repository -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> IO ()
abandonGh (GhFetchGuard cleanupFailure) repository (input, _, _, processHandle) = do
  -- Captured before anything reaps the handle, since 'getPid' goes 'Nothing'
  -- the moment it is reaped and the guard entry is keyed by this PID.
  spawnedPid <- fmap fromIntegral <$> getPid processHandle
  -- A finding already on the guard was established by the fetch itself, which
  -- knew things this cleanup no longer can -- above all when the leader has
  -- already been reaped and there is nothing left here to census. It is never
  -- overwritten and never cleared; this cleanup only ever adds one.
  alreadyReported <- isJust <$> readIORef cleanupFailure
  -- Written before any of the work below, all of which can be cut short by
  -- the cleanup budget running out. Whatever happens after this point, the
  -- fetch cannot end up reporting an ordinary clean timeout for a gh whose
  -- death was never actually established.
  unless alreadyReported (writeIORef cleanupFailure (Just (GhCleanupFailure "gh cleanup did not run to completion" GuardInMemoryOnly)))
  outcome <- killGhGroup processHandle
  resolved <- case outcome of
    Right proven -> pure (Right proven)
    Left (message, unconfirmed) -> do
      -- Upgrading the spawn-time guard to the full census is what lets a
      -- later run re-kill the group rather than only watch it, so it is
      -- worth attempting -- but nothing depends on it succeeding, because
      -- the entry written at spawn time already covers this pgid.
      recorded <- recordAndConfirm unconfirmed
      if recorded
        then pure (Left (GhCleanupFailure message GuardRecorded))
        else do
          -- Nothing on disk and nothing verified, so a restart would find no
          -- reason to hold back. Force is all that is left that depends on
          -- neither facility -- but it settles nothing by itself: only a
          -- snapshot showing the group actually empty does, and if it does,
          -- this was not a failed cleanup at all.
          forceKillGhGroup processHandle spawnedPid
          emptied <- groupConfirmedEmpty unconfirmed.ownedProcessGroupPid
          if emptied
            then pure (Right True)
            else do
              retried <- recordAndConfirm unconfirmed
              pure (Left (GhCleanupFailure message (if retried then GuardRecorded else GuardInMemoryOnly)))
  case resolved of
    Left failure -> unless alreadyReported (writeIORef cleanupFailure (Just failure))
    -- Reaping cannot block here: the group has been confirmed empty, so gh
    -- is at most an unreaped zombie. It is skipped entirely when that
    -- confirmation failed, since waiting on a gh that is still running would
    -- block this thread and the refresh would never report anything at all.
    Right proven -> do
      void (try @IOException (waitForProcess processHandle))
      mapM_ (dropGhGroup repository) spawnedPid
      -- A finding this cleanup did not make is retracted only by evidence
      -- this cleanup did make: proving the group empty. Otherwise the fetch's
      -- own finding stands, since it saw things no longer observable here.
      --
      -- Retracting on `proven` matters as much as keeping it otherwise. A
      -- cleanup that has just emptied the group and dropped its record has
      -- left nothing to hold off for, and a board held off for nothing would
      -- never refresh again.
      when (proven || not alreadyReported) (writeIORef cleanupFailure Nothing)
  mapM_ (ignoreIOException . hClose) input
  where
    recordAndConfirm unconfirmed = do
      void (recordGhGroup repository unconfirmed)
      ghGroupIsRecorded repository unconfirmed.ownedProcessGroupPid

-- | Runs a cleanup that must not be cut short by the refresh timer.
--
-- 'Control.Exception.bracketOnError' masks its handler, but 'mask' still
-- admits an exception at every interruptible point, and this cleanup is
-- little else: two grace windows and several subprocess waits. A refresh
-- timeout landing in one of them would abandon the work half-done —
-- signalled but never confirmed, nothing recorded — and the fetch would go on
-- to report an ordinary timeout for a process that is still running.
--
-- So the work happens on a thread of its own, where the timer's exception
-- cannot reach it, and this thread waits for it without accepting exceptions
-- either. That wait cannot outlast the worker, and the worker holds itself
-- to a budget, so refusing interruption here does not mean waiting forever.
uninterruptibleCleanup :: IO () -> IO ()
uninterruptibleCleanup = uninterruptiblyBounded ()

-- | Runs an action where the refresh timer cannot reach it, and waits for it
-- without accepting exceptions either.
--
-- Anything that signals a process group and then has to confirm what it did
-- belongs in here. Interrupted between those two halves it leaves the worst
-- of both: processes signalled, nothing established, and -- since the caller
-- never hears about it -- an ordinary timeout published over whatever
-- survived. The work is bounded by its own budget, so refusing interruption
-- does not mean waiting forever; if that budget runs out the caller is told
-- so through `whenInterrupted` rather than by silence.
uninterruptiblyBounded :: a -> IO a -> IO a
uninterruptiblyBounded whenInterrupted action = do
  finished <- newEmptyMVar
  void
    ( forkIOWithUnmask
        ( \unmask ->
            (timeout cleanupBudgetMicros (unmask action) >>= putMVar finished . fromMaybe whenInterrupted)
              `finally` void (tryPutMVar finished whenInterrupted)
        )
    )
  uninterruptibleMask_ (takeMVar finished)

-- | Comfortably longer than a cleanup that is behaving: three escalation
-- rounds of grace windows and snapshots, plus the forced fallback's own
-- bounded reap. It exists only so that a cleanup wedged on something
-- unexpected cannot hold the refresh thread indefinitely.
cleanupBudgetMicros :: Int
cleanupBudgetMicros = 30 * 1000 * 1000

ghGroupIsRecorded :: Repository -> Int -> IO Bool
ghGroupIsRecorded repository groupPid =
  any ((== groupPid) . ownedProcessGroupPid) <$> recordedGhGroups repository

-- | Writes the guard for a @gh@ that has just been spawned, before it is
-- used for anything. The entry names only the process group, because that is
-- all that is known this early and all a later run needs: an uncensused
-- entry is watched until its pgid is unoccupied, which is exactly the
-- question "did that gh outlive us?".
registerSpawnedGh :: Repository -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> IO (Either Text Int)
registerSpawnedGh repository (_, _, _, processHandle) = do
  spawnedPid <- getPid processHandle
  case spawnedPid of
    Nothing -> pure (Left "gh reported no process id, so no guard could be written for it")
    Just pid -> do
      let groupPid = fromIntegral pid
      written <- recordGhGroup repository (OwnedProcessGroup groupPid [] False)
      pure (groupPid <$ written)

-- | Replaces whatever is recorded for a group with `group`, keeping every
-- other repository entry.
recordGhGroup :: Repository -> OwnedProcessGroup -> IO (Either Text ())
recordGhGroup repository group = do
  existing <- recordedGhGroups repository
  writeGhGroupRecord repository (group : withoutGroup group.ownedProcessGroupPid existing)

dropGhGroup :: Repository -> Int -> IO ()
dropGhGroup repository groupPid = do
  existing <- recordedGhGroups repository
  case withoutGroup groupPid existing of
    [] -> void (removeGhGroupRecord repository)
    remaining -> void (writeGhGroupRecord repository remaining)

withoutGroup :: Int -> [OwnedProcessGroup] -> [OwnedProcessGroup]
withoutGroup groupPid = filter ((/= groupPid) . ownedProcessGroupPid)

recordedGhGroups :: Repository -> IO [OwnedProcessGroup]
recordedGhGroups repository = do
  existing <- loadGhGroupRecord repository
  pure $ case existing of
    GhGroupRecordLoaded groups -> groups
    _ -> []

-- | Re-verifies, and where it is safe to do so re-kills, every @gh@ group a
-- previous fetch failed to confirm dead — including ones recorded by an
-- earlier run of the dashboard, which is the whole reason the record is on
-- disk. The record is cleared only once every entry is provably accounted
-- for; anything else refuses the fetch outright, so a new @gh@ is never
-- spawned alongside one that may still be running.
reclaimRecordedGhGroups :: GhFetchGuard -> Repository -> IO (Either Text ())
reclaimRecordedGhGroups guard repository = do
  recordLoad <- loadGhGroupRecord repository
  case recordLoad of
    GhGroupRecordAbsent -> pure (Right ())
    GhGroupRecordUnusable message -> refuse message
    GhGroupRecordLoaded groups -> do
      -- A record exists from here on, so every exit other than clearing it
      -- has to leave the guard set. It is set now, pessimistically, because
      -- the exits that matter most are the ones that never reach a `case`:
      -- the budget expiring, or this whole reclaim being abandoned.
      setCleanupFailure guard (GhCleanupFailure (refusalText interrupted) GuardRecorded)
      outcomes <- traverse reclaimGhGroup groups
      case [message | Left message <- outcomes] of
        [] -> do
          cleared <- removeGhGroupRecord repository
          case cleared of
            Left message -> refuse message
            Right () -> do
              clearCleanupFailure guard
              pure (Right ())
        message : _ -> refuse message
  where
    refuse message = do
      setCleanupFailure guard (GhCleanupFailure (refusalText message) GuardRecorded)
      pure (Left (refusalText message))

    interrupted = "reclaiming it did not run to completion"

    refusalText message = "a gh process from an earlier GitHub refresh could not be confirmed stopped (" <> message <> "); refusing to start another until it is"

-- | One recorded group's second chance.
--
-- A censused group is identity-pinned and this dashboard's to signal, so it
-- gets the same verified TERM-then-KILL escalation again. An uncensused one
-- never can be, so it is only ever observed: whatever still matches it
-- refuses the fetch instead of being signalled blind, and — crucially — an
-- uncensused entry is never handed to the group check, whose empty
-- membership would read as vacuously absent and clear a live survivor.
reclaimGhGroup :: OwnedProcessGroup -> IO (Either Text ())
reclaimGhGroup group = go group.ownedProcessGroupMembers groupCleanupPasses
  where
    groupPid = group.ownedProcessGroupPid

    -- `known` grows as the reclaim proceeds, and it is what every signal is
    -- justified by. A flag saying "ownership was proven earlier" would not
    -- do: between two rounds the group can empty and its pgid be reissued, so
    -- an earlier proof says nothing about who is in it now. Identities do
    -- survive that, because a reused PID never matches a recorded start time.
    --
    -- Members are adopted into `known` only from a census taken while
    -- ownership was proven; at that instant everything in the group is
    -- descended from what this repository started, so a descendant forked
    -- from a member's TERM handler becomes provably ours and stays killable
    -- after its parent exits.
    go known passesLeft = do
      snapshot <- defaultProcessSnapshot
      case snapshot of
        Left message -> pure (Left message)
        Right processes -> do
          let occupants = groupMembers groupPid processes
              -- Saved identities are asked about by identity, never by
              -- group. The record written when gh turned out not to lead its
              -- own group names a pgid that was never this repository's, so
              -- looking only at that pgid finds nothing and would call the
              -- record spent while the gh it names is still running.
              savedAlive = matchingIdentities processes known
          case occupants <> savedAlive of
            -- Nothing in the group and nothing the record names: the only
            -- ending that clears it, and the reason this is asked of a fresh
            -- census rather than inferred from the recorded members going
            -- away.
            [] -> pure (Right ())
            survivors
              | not (provablyOurs processes known) -> pure (Left (unprovable (length survivors)))
              | passesLeft <= 0 -> pure (Left exhausted)
              | otherwise -> do
                  result <- freezeThenKillOwnedGroup groupPid known
                  case result of
                    Left message -> pure (Left message)
                    Right adopted -> go (known <> adopted) (passesLeft - 1)

    -- An uncensused record never pins anything, so its group can only ever
    -- be watched; a censused one is ours to signal exactly while one of the
    -- identities known to be ours is still holding its PID, start time, and
    -- group.
    provablyOurs processes known =
      group.ownedProcessGroupCensused
        && not (null (membersStillInGroup groupPid processes known))

    unprovable surviving =
      "a gh from an earlier GitHub refresh (pgid "
        <> Text.pack (show groupPid)
        <> ") still accounts for "
        <> Text.pack (show surviving)
        <> " running process(es) that cannot be identified as this repository's, so they cannot be signalled from here"

    exhausted =
      "a gh process group from an earlier GitHub refresh (pgid "
        <> Text.pack (show groupPid)
        <> ") kept gaining members faster than they could be terminated"
