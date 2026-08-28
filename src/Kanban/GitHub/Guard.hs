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
    GhRecordLock,
    abandonGh,
    clearCleanupFailure,
    dropGhGroup,
    ghFetchCleanupFailure,
    ghGroupIsRecorded,
    holdBackUnrecordedGroup,
    newGhFetchGuard,
    newGhRecordLock,
    newGhRecordLockOwnedBy,
    reclaimRecordedGhGroups,
    recordGhGroup,
    registerSpawnedGh,
    setCleanupFailure,
    uninterruptibleCleanup,
    uninterruptiblyBounded,
  )
where

import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, putMVar, takeMVar, tryPutMVar, withMVar)
import Control.Exception (IOException, finally, try, uninterruptibleMask_)
import Control.Monad (unless, void, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, isJust)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Cache (GhGroupRecordLoad (..), loadGhGroupRecord, removeGhGroupRecord, writeGhGroupRecord)
import Kanban.Domain
import Kanban.GitHub.Group (forceKillGhGroup, freezeThenKillOwnedGroup, groupCleanupPasses, groupConfirmedEmpty, groupMembers, ignoreIOException, killGhGroup)
import Kanban.Process (OwnedProcessGroup (..), ProcessIdentity (..), defaultProcessSnapshot, matchingIdentities, membersStillInGroup)
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
data GhFetchGuard = GhFetchGuard
  { ghGuardCleanupFailure :: IORef (Maybe GhCleanupFailure),
    ghGuardRecordLock :: GhRecordLock
  }

-- | The repository's durable @gh@ group record, held as something that can
-- only be updated by one writer at a time — and beside it, the one thing about
-- that record which is not durable at all.
--
-- Every update to the record is a read-modify-write of the whole list of
-- groups: an entry is added or removed by rewriting the others beside it. Two
-- of those interleaving lose whichever entry the later write had not read,
-- and a lost entry is a possibly-live @gh@ that no later fetch -- and no later
-- run of the dashboard -- knows to reclaim. The lock is what the coordinator
-- owns on behalf of the repository, so every job it schedules writes the
-- record through the same one (§15).
data GhRecordLock = GhRecordLock
  { ghRecordMutex :: MVar (),
    -- | Set once a job ended holding back a group nothing durable accounts
    -- for, and never cleared.
    --
    -- It is repository-scoped rather than per job because that is the only
    -- scope at which it means anything. 'GuardInMemoryOnly' says this
    -- process's own refusal to start another @gh@ is all that stands between
    -- a possibly-live group and an overlapping one — and a refusal recorded
    -- only on the guard of the job that ended dies with that job, leaving the
    -- next one to spawn freely. Every job the coordinator schedules shares
    -- this lock, so a refusal recorded here outlives the guard that earned it
    -- and reaches every later fetch, whatever kind of job makes it.
    ghRecordHeldBack :: IORef (Maybe Text),
    -- | The dashboard process this record's new entries belong to, when it
    -- could be identified.
    --
    -- Written into every entry this board records and read by nothing that
    -- decides anything. It is not a liveness test, not part of
    -- @provablyOurs@, and never a signalling target: the census and the
    -- recorded member identities remain the whole of that. What it buys is a
    -- message that can say which board left a group behind.
    ghRecordOwner :: Maybe ProcessIdentity,
    -- | The groups this record still holds that this process inherited, by
    -- pgid.
    --
    -- The one signal that separates an entry this board wrote from one it
    -- inherited, and deliberately not owner presence: this board's own entries
    -- carry an owner too, so owner presence answers a different question.
    -- Under the repository lease no other current board can have been writing
    -- this record, so whatever was in it at the first reclaim was written by a
    -- process that is no longer running — and anything appearing after that,
    -- in this process, is this board's own.
    --
    -- Settled at that first reclaim and emptied when the record carrying those
    -- entries is durably gone, never in between. A pgid is not a stable
    -- identity: once an inherited entry has been confirmed gone and removed
    -- from the record, the operating system may reissue its pgid to a @gh@
    -- this board starts, and a set still holding the number would describe
    -- that new entry as a predecessor's. Retiring the claim with the record is
    -- what keeps this about /which board wrote an entry/ rather than about
    -- which integer it happens to carry.
    --
    -- 'Nothing' until that first reclaim, which is why it is an 'IORef' and
    -- not a field settled at construction: the record is not read until then.
    -- An empty set is a settled answer rather than that state — it says
    -- nothing inherited is outstanding — so a later read must not take it as
    -- licence to freeze the set again over entries this board has since
    -- written.
    ghRecordInherited :: IORef (Maybe (Set Int))
  }

newGhRecordLock :: IO GhRecordLock
newGhRecordLock = newGhRecordLockOwnedBy Nothing

-- | The record lock a board takes for a repository it holds, carrying the
-- identity its entries are stamped with.
--
-- Separate from 'newGhRecordLock' rather than replacing it because an absent
-- owner is a supported state — a process snapshot that could not be taken
-- leaves the board with no identity and no less authority — and because most
-- callers have nothing to say about ownership at all.
newGhRecordLockOwnedBy :: Maybe ProcessIdentity -> IO GhRecordLock
newGhRecordLockOwnedBy owner = GhRecordLock <$> newMVar () <*> newIORef Nothing <*> pure owner <*> newIORef Nothing

-- | Serializes one read-modify-write of the durable record.
withRecordLock :: GhFetchGuard -> IO result -> IO result
withRecordLock guard action = withMVar guard.ghGuardRecordLock.ghRecordMutex (const action)

-- | Records a finished job's verdict against the repository, when that verdict
-- is one only this process is holding back.
--
-- Called once per job, after its body has fully unwound and its verdict is
-- final. A recorded group needs nothing from this — the durable record already
-- makes every later fetch re-verify it — and a group confirmed gone is holding
-- nothing back at all, so only 'GuardInMemoryOnly' latches.
holdBackUnrecordedGroup :: GhFetchGuard -> IO ()
holdBackUnrecordedGroup guard = do
  verdict <- ghFetchCleanupFailure guard
  case verdict of
    Just failure
      | failure.ghCleanupGuard == GuardInMemoryOnly ->
          writeIORef guard.ghGuardRecordLock.ghRecordHeldBack (Just failure.ghCleanupMessage)
    _ -> pure ()

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

-- | A guard for one job, sharing the repository's record lock with every
-- other job the coordinator schedules. The cleanup verdict is per job -- it is
-- what that job's own outcome is built from -- while the lock is the
-- repository's, which is exactly the split requirement 1 asks for.
newGhFetchGuard :: GhRecordLock -> IO GhFetchGuard
newGhFetchGuard recordLock = do
  cleanupFailure <- newIORef Nothing
  pure (GhFetchGuard cleanupFailure recordLock)

ghFetchCleanupFailure :: GhFetchGuard -> IO (Maybe GhCleanupFailure)
ghFetchCleanupFailure guard = readIORef guard.ghGuardCleanupFailure

setCleanupFailure :: GhFetchGuard -> GhCleanupFailure -> IO ()
setCleanupFailure guard = writeIORef guard.ghGuardCleanupFailure . Just

clearCleanupFailure :: GhFetchGuard -> IO ()
clearCleanupFailure guard = writeIORef guard.ghGuardCleanupFailure Nothing

-- | Cleans up the @gh@ an abandoned fetch walked away from: TERM, then KILL,
-- the whole process group it leads, confirmed against a fresh process
-- snapshot rather than assumed from the act of signalling. A group that
-- could not be terminated or could not be confirmed gone is both recorded on
-- the guard — a possibly-live @gh@ is not a clean timeout and must not be
-- reported as one — and written to the durable record, so the very next
-- fetch re-verifies it before spawning anything, even if the dashboard is
-- restarted in between.
abandonGh :: GhFetchGuard -> Repository -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> IO ()
abandonGh guard repository (input, _, _, processHandle) = do
  let cleanupFailure = guard.ghGuardCleanupFailure
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
      mapM_ (dropGhGroup guard repository) spawnedPid
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
      void (recordGhGroup guard repository unconfirmed)
      ghGroupIsRecorded guard repository unconfirmed.ownedProcessGroupPid

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

-- | Whether the durable record still names this group, asked under the record
-- lock so the answer cannot be taken from a list another writer is midway
-- through replacing.
ghGroupIsRecorded :: GhFetchGuard -> Repository -> Int -> IO Bool
ghGroupIsRecorded guard repository groupPid =
  withRecordLock guard (any ((== groupPid) . ownedProcessGroupPid) <$> recordedGhGroups repository)

-- | Writes the guard for a @gh@ that has just been spawned, before it is
-- used for anything. The entry names only the process group, because that is
-- all that is known this early and all a later run needs: an uncensused
-- entry is watched until its pgid is unoccupied, which is exactly the
-- question "did that gh outlive us?".
registerSpawnedGh :: GhFetchGuard -> Repository -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> IO (Either Text Int)
registerSpawnedGh guard repository (_, _, _, processHandle) = do
  spawnedPid <- getPid processHandle
  case spawnedPid of
    Nothing -> pure (Left "gh reported no process id, so no guard could be written for it")
    Just pid -> do
      let groupPid = fromIntegral pid
      written <- recordGhGroup guard repository (OwnedProcessGroup groupPid [] False Nothing)
      pure (groupPid <$ written)

-- | Replaces whatever is recorded for a group with `group`, keeping every
-- other repository entry.
--
-- The read and the write are one critical section. Splitting them is what
-- loses an entry: the list this rewrites is the list it just read, so a write
-- that landed in between is discarded wholesale.
recordGhGroup :: GhFetchGuard -> Repository -> OwnedProcessGroup -> IO (Either Text ())
recordGhGroup guard repository group = withRecordLock guard $ do
  existing <- recordedGhGroups repository
  -- Stamped here rather than by each caller, because this is the one way a
  -- new entry reaches the record and the callers that build one are describing
  -- a process group, not deciding whose board it belongs to. Every entry this
  -- process writes therefore carries its identity, and no entry it inherited
  -- is ever rewritten to claim it.
  let owned = group {ownedProcessGroupOwner = guard.ghGuardRecordLock.ghRecordOwner}
  writeGhGroupRecord repository (owned : withoutGroup group.ownedProcessGroupPid existing)

dropGhGroup :: GhFetchGuard -> Repository -> Int -> IO ()
dropGhGroup guard repository groupPid = withRecordLock guard $ do
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
  -- Asked before the record, and answered without consulting it, because this
  -- is exactly the group the record does not have. A job that ended holding one
  -- back leaves nothing on disk to re-verify, so every later fetch would find
  -- an absent record and spawn straight past it; the refusal has to come from
  -- the one place that outlived that job.
  heldBack <- readIORef guard.ghGuardRecordLock.ghRecordHeldBack
  case heldBack of
    Just message -> refuseUnrecorded message
    Nothing -> reclaimRecorded
  where
    refuseUnrecorded message = do
      -- 'GuardInMemoryOnly' rather than 'GuardRecorded': this job is refusing
      -- over a group that is still on nothing but this process's word, and the
      -- notice §17 renders for the two differs precisely because a restart
      -- cannot know to hold back over this one.
      setCleanupFailure guard (GhCleanupFailure (refusalText message) GuardInMemoryOnly)
      pure (Left (refusalText message))

    reclaimRecorded = do
      recordLoad <- loadGhGroupRecord repository
      case recordLoad of
        -- Settled on the first record this process /reads/, not on the first
        -- one that turns out to hold something. Every fetch reclaims before it
        -- spawns anything, so the first read happens before this board has
        -- written a single entry -- and an absent record therefore establishes
        -- that this board inherited nothing. Deferring the answer to the first
        -- non-empty read would settle it after this board's own first entry
        -- was already in the file, and classify that entry as a predecessor's.
        GhGroupRecordAbsent -> do
          _ <- rememberInherited guard []
          pure (Right ())
        -- Deliberately not remembered. Nothing can be said about a record that
        -- will not decode, and nothing needs to be: this refuses the fetch, so
        -- no gh is spawned and no entry is written, and the first read that
        -- does succeed still sees exactly what the predecessor left.
        GhGroupRecordUnusable message -> refuse message
        GhGroupRecordLoaded groups -> do
          inherited <- rememberInherited guard groups
          reclaimGroups inherited groups

    reclaimGroups inherited groups = do
      -- A record exists from here on, so every exit other than clearing it
      -- has to leave the guard set. It is set now, pessimistically, because
      -- the exits that matter most are the ones that never reach a `case`:
      -- the budget expiring, or this whole reclaim being abandoned.
      setCleanupFailure guard (GhCleanupFailure (refusalText interrupted) GuardRecorded)
      outcomes <- traverse (reclaimGhGroup inherited) groups
      case [message | Left message <- outcomes] of
        [] -> do
          -- Under the record lock like every other rewrite, even though the
          -- coordinator only ever reclaims with the owner held: clearing the
          -- record is the one update that discards entries it never read.
          cleared <- withRecordLock guard (removeGhGroupRecord repository)
          case cleared of
            Left message -> refuse message
            Right () -> do
              -- Only here, and only once the removal reported success. An
              -- entry a failed removal left on disk is still an inherited
              -- entry the next reclaim reads, and giving up the claim over it
              -- would hand a predecessor's leftover this board's name.
              retireInherited guard
              clearCleanupFailure guard
              pure (Right ())
        message : _ -> refuse message

    refuse message = do
      setCleanupFailure guard (GhCleanupFailure (refusalText message) GuardRecorded)
      pure (Left (refusalText message))

    interrupted = "reclaiming it did not run to completion"

    -- Says what happened and refuses; it says nothing about whose gh it was.
    -- It wraps both kinds of refusal — a group this process is holding back on
    -- nothing but its own word, and a recorded one it inherited — and a
    -- wrapper that named a predecessor would be claiming one for the first
    -- kind, which never has one. Which board a leftover belongs to is said by
    -- the per-entry message inside the parentheses, which is the only text
    -- that knows.
    refusalText message = "a gh process could not be confirmed stopped (" <> message <> "); refusing to start another until it is"

-- | Records which of a repository's entries this process inherited, the first
-- time it reads the record, and answers that question afterwards.
--
-- Settled once and never derived a second time: a later read of the same
-- record can contain entries this board wrote, and taking the answer again
-- would reclassify its own leftovers as a predecessor's.
-- 'atomicModifyIORef'' keeps the first writer's set even though every caller
-- already holds the record lock, because what it must be is decided once, not
-- decided under whichever lock happens to be held. 'retireInherited' is the
-- only thing that moves it afterwards, and all it can do is empty it.
rememberInherited :: GhFetchGuard -> [OwnedProcessGroup] -> IO (Set Int)
rememberInherited guard groups =
  atomicModifyIORef' guard.ghGuardRecordLock.ghRecordInherited $ \remembered ->
    case remembered of
      Just already -> (Just already, already)
      Nothing ->
        let first = Set.fromList (map ownedProcessGroupPid groups)
         in (Just first, first)

-- | Gives up the inherited claim, because the record that carried it is gone.
--
-- Reached only on the one path that clears the record, and only once the
-- removal reported success. Every inherited entry was in that file, so with
-- the file gone this process holds no outstanding leftover of a predecessor's
-- and every entry a later read finds is one it wrote itself — whatever pgid
-- the operating system reissued in the meantime, and whether or not the entry
-- carries members, a census, or an owner to tell it apart by. That is the
-- reason the claim is retired rather than the entries remembered: an entry
-- 'registerSpawnedGh' has just written can be indistinguishable from the one
-- that vacated its pgid, both being @OwnedProcessGroup pgid [] False owner@
-- for the same @owner@, so only /when/ it appeared can separate them.
--
-- Emptied rather than reset to 'Nothing', which would let the next read freeze
-- the set again over this board's own entries. That is the question
-- 'rememberInherited' settles once, so this answers it rather than reopening
-- it.
retireInherited :: GhFetchGuard -> IO ()
retireInherited guard =
  atomicModifyIORef' guard.ghGuardRecordLock.ghRecordInherited (const (Just Set.empty, ()))

-- | How a message should describe one entry's provenance.
--
-- Three spellings for three genuinely different facts, and the missing-owner
-- one is not a degraded version of the second: it is what an entry written
-- before owner metadata existed truthfully supports, and inventing a board for
-- it would be worse than saying less.
--
-- The pgid tested below is only ever asked about against a set that still
-- holds outstanding inherited entries: 'retireInherited' drops the numbers as
-- the record carrying them is cleared, so a reissued pgid is not a member and
-- the first branch answers for it. That set alone decides provenance;
-- 'ownedProcessGroupOwner' is read beneath it, once an entry is already known
-- to be a predecessor's, and never to establish that it is one.
entryOrigin :: Set Int -> OwnedProcessGroup -> Text
entryOrigin inherited group
  | not (Set.member group.ownedProcessGroupPid inherited) = "a gh this board started"
  | Just owner <- group.ownedProcessGroupOwner =
      "a gh left by a previous Kanban board (pid " <> Text.pack (show owner.processIdentityPid) <> ")"
  | otherwise = "a gh left by a previous Kanban board"

-- | One recorded group's second chance.
--
-- A censused group is identity-pinned and this dashboard's to signal, so it
-- gets the same verified TERM-then-KILL escalation again. An uncensused one
-- never can be, so it is only ever observed: whatever still matches it
-- refuses the fetch instead of being signalled blind, and — crucially — an
-- uncensused entry is never handed to the group check, whose empty
-- membership would read as vacuously absent and clear a live survivor.
--
-- @inherited@ reaches only the two messages. Nothing about which board wrote
-- an entry changes what is done to it: the reclaim below is identical either
-- way, which is what keeps owner metadata informational.
reclaimGhGroup :: Set Int -> OwnedProcessGroup -> IO (Either Text ())
reclaimGhGroup inherited group = go group.ownedProcessGroupMembers groupCleanupPasses
  where
    groupPid = group.ownedProcessGroupPid

    origin = entryOrigin inherited group

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
      origin
        <> " (pgid "
        <> Text.pack (show groupPid)
        <> ") still accounts for "
        <> Text.pack (show surviving)
        <> " running process(es) that cannot be identified as this repository's, so they cannot be signalled from here"

    exhausted =
      origin
        <> " (pgid "
        <> Text.pack (show groupPid)
        <> ") kept gaining members faster than they could be terminated"
