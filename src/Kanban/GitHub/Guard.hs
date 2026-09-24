-- | The guard that accounts for every @gh@ a fetch starts — a dashboard's, a
-- mission runner's, or a worker's precondition read: the in-memory cleanup
-- verdict the refresh reads, the durable record on disk that every one of
-- those readers shares and that outlives each of them, and the reclamation a
-- later fetch performs before it is allowed to spawn anything.
--
-- This is where a possibly-live @gh@ is turned into something the board can
-- refuse to refresh over. It asks 'Kanban.GitHub.Group' what became of a
-- process group and writes the answer down; it does not run @gh@ itself,
-- which is what keeps it below 'Kanban.GitHub.Run'.
module Kanban.GitHub.Guard
  ( GhCleanupFailure (..),
    GhCleanupGuard (..),
    GhEntryClass (..),
    GhEntryWriter (..),
    GhFetchGuard,
    GhRecordLock,
    GhSpawnRegistration (..),
    GhSpawnState,
    abandonGh,
    abandonSpawn,
    classifyGhEntry,
    clearCleanupFailure,
    describeGhEntry,
    dropGhGroup,
    ghFetchCleanupFailure,
    ghGroupIsPending,
    ghGroupIsRecorded,
    holdBackUnrecordedGroup,
    markGhGroupPending,
    newGhFetchGuard,
    newGhRecordLock,
    newGhSpawnState,
    reclaimRecordedGhGroups,
    recordGhGroup,
    registerSpawnedGh,
    releaseSpawnClaim,
    setCleanupFailure,
    spawnRegistrationGroup,
    uninterruptibleCleanup,
    uninterruptiblyBounded,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, putMVar, takeMVar, tryPutMVar, withMVar)
import Control.Exception (IOException, finally, mask_, try, uninterruptibleMask_)
import Control.Monad (unless, void, when)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Cache (GhGroupRecordLoad (..), GhSpawnClaim, claimGhGroup, ghGroupClaimHeld, loadGhGroupRecord, releaseGhGroupClaim, removeGhGroupRecord, withGhGroupRecordLock, writeGhGroupRecord)
import Kanban.Domain
import Kanban.GitHub.Group (forceKillGhGroup, freezeThenKillOwnedGroup, groupCleanupPasses, groupConfirmedEmpty, groupMembers, ignoreIOException, killGhGroup)
import Kanban.Process (OwnedProcessGroup (..), ProcessIdentity (..), defaultProcessSnapshot, identityForPid, matchingIdentities, membersStillInGroup)
import System.IO (Handle, hClose)
import System.Posix.Process (getProcessID)
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
--
-- The mutex below orders this process's rewrites and nothing else's. Another
-- process -- a mission runner or a worker's precondition reread beside the
-- dashboard -- mints a lock of its own, so every rewrite also takes
-- 'Kanban.Cache.withGhGroupRecordLock', which is what orders processes.
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
    ghRecordHeldBack :: IORef (Maybe Text)
  }

-- | The lock every job one process schedules shares.
--
-- It carries no identity of its own. Which process wrote an entry is resolved
-- afresh for each spawn ('registerSpawnedGh'), because the same record is
-- written by dashboards, mission runners, and workers' precondition reads,
-- and an identity settled once at construction would outlive nothing it
-- describes.
newGhRecordLock :: IO GhRecordLock
newGhRecordLock = GhRecordLock <$> newMVar () <*> newIORef Nothing

-- | Serializes one read-modify-write of the durable record, within this
-- process and across processes.
--
-- The in-process mutex is taken first and the cross-process file lock inside
-- it, so two threads of one process queue on the mutex and never contend over
-- the lock's descriptor; the file lock is then what orders this process
-- against every other one rewriting the same record. Both are released however
-- the action ends, an interruption included: 'withMVar' restores the mutex and
-- 'withGhGroupRecordLock' closes its own descriptor.
--
-- 'Left' is a file lock that could not be established. The action has not run,
-- and each caller reports that the way it already reports a record write that
-- failed, rather than running it unsynchronised.
withRecordLock :: GhFetchGuard -> Repository -> IO result -> IO (Either Text result)
withRecordLock guard repository action =
  withMVar guard.ghGuardRecordLock.ghRecordMutex (const (withGhGroupRecordLock repository action))

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
  = -- | The group is on disk and marked cleanup-pending. Every later fetch
    -- re-checks it before spawning anything — this process's own, another
    -- reader's beside it, or one started long afterwards — even while the
    -- process that wrote it is still running.
    GuardRecorded
  | -- | Nothing could be recorded as pending. This process's own refusal to
    -- start another @gh@ is all that remains, and it is worth nothing once
    -- the process exits — so this is the one case that must never suggest a
    -- restart.
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
-- restarted in between. The entry is written cleanup-pending, and that mark is
-- what makes "the next fetch" true while this process is still running: an
-- unmarked entry whose writer is alive reads as that writer's live work and is
-- skipped, by this process's own next fetch as much as by anyone else's.
--
-- A group this /did/ prove gone owes one more thing before the cleanup counts
-- as clean: its entry has to leave that record. Removing it is a filesystem
-- write like any other and can fail, and an entry that outlives the process it
-- names is exactly what the next fetch holds back over — so a drop that did
-- not happen marks the entry cleanup-pending and is recorded on the guard as
-- 'GuardRecorded'. The same broken store usually refuses the mark too, and
-- then nothing durable says the entry needs re-checking: it is held back in
-- memory instead, as 'GuardInMemoryOnly', so this process refuses further
-- @gh@ rather than skipping its own leftover as live work.
--
-- A spawn admitted under in-memory protection ('GhSpawnInMemory') has no
-- entry, and its cleanup writes none: a group it cannot account for is held
-- back in memory, never recorded without a writer.
--
-- Two identities are in play and they are deliberately not merged.
-- /Signalling/ uses the pid the handle still reports, because a pid is only
-- safe to signal while the handle holds it unreaped — once reaped, that number
-- can name anything, and 'forceKillGhGroup' must never be pointed at it. The
-- /record/ needs the opposite property: it is looked up and never signalled,
-- so a stale number costs nothing there and an absent one costs everything —
-- a cleanup that cannot name the entry skips the drop and goes on to report an
-- ordinary timeout over an entry still on disk.
--
-- So the record identity is the pgid the registration wrote the entry under,
-- carried in rather than asked for — falling back to the handle's own pid. Between them they answer at every instant the entry can
-- exist, which is what makes the drop unconditional. Registration persists the
-- entry and publishes that pgid as two steps with an interruptible gap between
-- them, so an interruption landing in that gap carries no registration; but
-- nothing has reaped the handle that early, so 'getPid' still answers, with the
-- same number. The writer identity is then unknown here too, and
-- 'recordGhGroup' retains the one the entry on disk already carries — or, for
-- a spawn that never wrote one, refuses to write an entry without a writer. Later, once 'Kanban.GitHub.Run.runGh' reaps its own handle
-- before dropping the entry, 'getPid' goes empty — and by then the pgid was
-- published long ago. Neither window is open at the same time as the other.
abandonGh :: GhFetchGuard -> Repository -> Maybe GhSpawnRegistration -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> IO ()
abandonGh guard repository registration (input, _, _, processHandle) = do
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
      undropped <- dropRecordedGroup (if inMemory then Nothing else recordedGroup <|> spawnedPid)
      case undropped of
        -- Killed, confirmed, and still named on disk. That is not a clean
        -- cleanup: the entry is precisely what this could not remove, and a
        -- caller told the cleanup was clean would publish an ordinary timeout
        -- over it. Marked pending, 'GuardRecorded' is exact rather than merely
        -- conservative — the notice §17 renders points at a group a later
        -- fetch clears itself once it confirms the pgid is unoccupied. Unmarked,
        -- no later fetch would: this process's own reads it as live work while
        -- this process runs, so the refusal is held here instead.
        Just (groupPid, message) -> do
          marked <- markGhGroupPending guard repository groupPid
          writeIORef cleanupFailure . Just $ case marked of
            Right () -> GhCleanupFailure message GuardRecorded
            Left markFailure -> GhCleanupFailure (message <> "; nor could it be marked for re-verification: " <> markFailure) GuardInMemoryOnly
        -- A finding this cleanup did not make is retracted only by evidence
        -- this cleanup did make: proving the group empty. Otherwise the fetch's
        -- own finding stands, since it saw things no longer observable here.
        --
        -- Retracting on `proven` matters as much as keeping it otherwise. A
        -- cleanup that has just emptied the group and dropped its record has
        -- left nothing to hold off for, and a board held off for nothing would
        -- never refresh again.
        Nothing -> when (proven || not alreadyReported) (writeIORef cleanupFailure Nothing)
  mapM_ (ignoreIOException . hClose) input
  -- The cleanup is over, however it ended, so this process no longer manages
  -- the spawn. Released last: while the claim is held the entry reads as live
  -- work to every other reader, and from here on it must not.
  releaseSpawnClaim registration
  where
    recordedGroup = spawnRegistrationGroup <$> registration

    inMemory = case registration of
      Just (GhSpawnInMemory _) -> True
      _ -> False

    -- The identity the spawn was registered under, carried into every
    -- rewrite of its entry rather than resolved again: the entry is still
    -- the same spawn's.
    spawnWriter = case registration of
      Just (GhSpawnRecorded _ writer _) -> Just writer
      _ -> Nothing

    -- Confirmed by reading the pending mark back, not by the write's own
    -- report alone: the spawn-time entry is already on disk, so "recorded"
    -- would be true of a rewrite that never happened, and an unmarked entry
    -- whose writer is alive is skipped as live work.
    recordAndConfirm unconfirmed
      | inMemory = pure False
      | otherwise = do
          void (recordGhGroup guard repository unconfirmed {ownedProcessGroupOwner = spawnWriter, ownedProcessGroupCleanupPending = True})
          ghGroupIsPending guard repository unconfirmed.ownedProcessGroupPid

    -- 'Nothing' when there is no entry to name: a spawn held in memory never
    -- wrote one, and a run that never had a live child spawned nothing.
    dropRecordedGroup Nothing = pure Nothing
    dropRecordedGroup (Just groupPid) = do
      dropped <- dropGhGroup guard repository groupPid
      pure $ case dropped of
        Right () -> Nothing
        Left message ->
          Just
            ( groupPid,
              "gh's process group "
                <> Text.pack (show groupPid)
                <> " was terminated but its durable record entry could not be dropped: "
                <> message
            )

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
--
-- A lock that could not be established answers 'False'. This is asked to
-- confirm durable coverage, and a record that could not be read under the lock
-- confirms nothing.
ghGroupIsRecorded :: GhFetchGuard -> Repository -> Int -> IO Bool
ghGroupIsRecorded guard repository groupPid =
  either (const False) id
    <$> withRecordLock guard repository (any ((== groupPid) . ownedProcessGroupPid) <$> recordedGhGroups repository)

-- | Whether the record names this group /and/ marks it cleanup-pending.
--
-- The stronger question a failed cleanup has to ask. Its entry has been on
-- disk since the spawn, so "recorded" alone is true of a pending mark that was
-- never written — and an unmarked entry whose writer is alive is skipped by
-- every reader as that writer's live work, which is no guard at all.
ghGroupIsPending :: GhFetchGuard -> Repository -> Int -> IO Bool
ghGroupIsPending guard repository groupPid =
  either (const False) id
    <$> withRecordLock guard repository (any pendingHere <$> recordedGhGroups repository)
  where
    pendingHere group = group.ownedProcessGroupPid == groupPid && group.ownedProcessGroupCleanupPending

-- | Marks the entry recorded for a group cleanup-pending, keeping everything
-- else it says.
--
-- 'Left' when the mark could not be written, and also when there is no entry
-- to mark: a caller asking this has a leftover it could not remove, and an
-- answer of success over an entry that is not there would tell it a later
-- fetch will re-check something no later fetch can see.
markGhGroupPending :: GhFetchGuard -> Repository -> Int -> IO (Either Text ())
markGhGroupPending guard repository groupPid = fmap (either Left id) . withRecordLock guard repository $ do
  existing <- recordedGhGroups repository
  case filter ((== groupPid) . ownedProcessGroupPid) existing of
    [] -> pure (Left ("gh's process group " <> Text.pack (show groupPid) <> " is not on the record to be marked"))
    entry : _ -> writeGhGroupRecord repository (entry {ownedProcessGroupCleanupPending = True} : withoutGroup groupPid existing)

-- | How a freshly spawned @gh@ is accounted for while it runs.
data GhSpawnRegistration
  = -- | An entry naming the group is on the durable record, stamped with the
    -- identity of the process that spawned it, and this process holds the
    -- spawn's claim on it. Every later rewrite of that entry carries the same
    -- identity; the claim is released when this process stops managing the
    -- spawn ('releaseSpawnClaim').
    GhSpawnRecorded Int ProcessIdentity GhSpawnClaim
  | -- | Nothing is on the record. The writer could not be identified for this
    -- spawn, the record held nothing a reader would have to classify, and a
    -- separate fresh snapshot confirmed the child leads its own group. This
    -- process's own serialised jobs are all that keep another @gh@ from
    -- overlapping it, and a cleanup that cannot account for it is held back
    -- in memory ('GuardInMemoryOnly'), never written ownerless. A process
    -- lost while this @gh@ runs leaves it unguarded for a restart; that is
    -- the price of not refusing every fetch over one transient snapshot.
    GhSpawnInMemory Int
  deriving stock (Eq, Show)

spawnRegistrationGroup :: GhSpawnRegistration -> Int
spawnRegistrationGroup (GhSpawnRecorded groupPid _ _) = groupPid
spawnRegistrationGroup (GhSpawnInMemory groupPid) = groupPid

-- | Gives up a spawn's claim on its entry, because this process has stopped
-- managing that @gh@: it finished and its entry was dropped, or its cleanup
-- ended, however it ended. From here on a reader re-verifies the entry rather
-- than skipping it as live work, whether or not a cleanup-pending mark could be
-- written. Idempotent, and a no-op for a spawn that holds no claim.
releaseSpawnClaim :: Maybe GhSpawnRegistration -> IO ()
releaseSpawnClaim (Just (GhSpawnRecorded _ _ claim)) = releaseGhGroupClaim claim
releaseSpawnClaim _ = pure ()

-- | Everything a spawn's cleanup has to find, published the moment each piece
-- exists rather than when registration returns.
--
-- The claim is the piece that cannot wait. Registration takes it, then writes
-- the entry, then returns, and a deadline can land anywhere after the claim is
-- taken; a claim only the returned value knew about would then be held by
-- nobody's cleanup, and an entry whose claim stays held reads as live work to
-- every other reader for as long as this process runs. So it is published in
-- the same masked step that takes it, and 'abandonSpawn' releases whatever is
-- published here whether or not the registration itself ever came back.
data GhSpawnState = GhSpawnState
  { ghSpawnRegistration :: IORef (Maybe GhSpawnRegistration),
    ghSpawnClaim :: IORef (Maybe GhSpawnClaim)
  }

newGhSpawnState :: IO GhSpawnState
newGhSpawnState = GhSpawnState <$> newIORef Nothing <*> newIORef Nothing

-- | The cleanup of a spawn that is being abandoned: 'abandonGh' against what
-- registration published, shielded from the refresh timer, and then — outside
-- that bounded shield, so a cleanup cut short by its budget still does it —
-- the release of whatever claim was taken.
abandonSpawn :: GhFetchGuard -> Repository -> GhSpawnState -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> IO ()
abandonSpawn guard repository state spawned = do
  registration <- readIORef state.ghSpawnRegistration
  uninterruptibleCleanup (abandonGh guard repository registration spawned)
    `finally` (readIORef state.ghSpawnClaim >>= mapM_ releaseGhGroupClaim)

-- | Accounts for a @gh@ that has just been spawned, before it is used for
-- anything, from @census@: a process snapshot taken for this one spawn while
-- the child is still parked behind its launch barrier.
--
-- The writer is this process as that census shows it, pid and start time, so
-- every reader can later tell whether the process that wrote the entry is
-- still running. The spawn's claim is taken before the entry is written, so
-- there is no instant at which a reader finds the entry without it. The entry names only the process group besides, because
-- that is all that is known this early and all a later run needs: an
-- uncensused entry is watched until its pgid is unoccupied, which is exactly
-- the question "did that gh outlive its writer?".
--
-- A census that does not identify this process never produces an ownerless
-- entry. When the record is absent or empty the spawn is admitted as
-- 'GhSpawnInMemory' and nothing is written — the caller must still confirm
-- the child's group leadership from a snapshot of its own. When the record
-- holds anything, the spawn is refused: an entry beside it could be anyone's
-- live work or anyone's leftover, and the next reader to see this one could
-- not tell which it was either.
--
-- Each piece is published to @state@ as it comes into being, for
-- 'abandonSpawn' to find: the claim as it is taken, the registration once the
-- entry is written.
registerSpawnedGh :: GhFetchGuard -> Repository -> GhSpawnState -> Either Text [ProcessIdentity] -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> IO (Either Text GhSpawnRegistration)
registerSpawnedGh guard repository state census (_, _, _, processHandle) = do
  spawnedPid <- getPid processHandle
  case spawnedPid of
    Nothing -> pure (Left "gh reported no process id, so no guard could be written for it")
    Just pid -> do
      let groupPid = fromIntegral pid
      self <- fromIntegral <$> getProcessID
      case census >>= maybe (Left "this process was not in the snapshot") Right . identityForPid self of
        Right writer -> do
          -- Masked, so nothing is delivered between the lock being taken and
          -- the claim being published; the blocking lock itself still admits
          -- an interruption, and one taken there has taken no claim.
          claimed <- mask_ $ do
            taken <- claimGhGroup repository groupPid
            taken <$ either (const (pure ())) (writeIORef state.ghSpawnClaim . Just) taken
          case claimed of
            Left message -> pure (Left message)
            Right claim -> do
              written <- recordGhGroup guard repository (OwnedProcessGroup groupPid [] False (Just writer) False)
              case written of
                Left message -> Left message <$ releaseGhGroupClaim claim
                Right () -> publish (GhSpawnRecorded groupPid writer claim)
        Left reason -> do
          let unidentified = "could not identify the process starting gh (" <> reason <> ")"
          empty <- withRecordLock guard repository (recordHoldsNothing <$> loadGhGroupRecord repository)
          case empty of
            Left message -> pure (Left (unidentified <> ", and the record could not be read: " <> message))
            Right True -> publish (GhSpawnInMemory groupPid)
            Right False -> pure (Left (unidentified <> ", and the record holds entries that cannot be classified beside an unidentified one"))
  where
    publish registration = Right registration <$ writeIORef state.ghSpawnRegistration (Just registration)

    recordHoldsNothing GhGroupRecordAbsent = True
    recordHoldsNothing (GhGroupRecordLoaded []) = True
    recordHoldsNothing _ = False

-- | Replaces whatever is recorded for a group with `group`, keeping every
-- other repository entry.
--
-- The read and the write are one critical section. Splitting them is what
-- loses an entry: the list this rewrites is the list it just read, so a write
-- that landed in between is discarded wholesale.
--
-- A group given without a writer keeps the writer its entry already has,
-- which is how the one caller that cannot know it — a cleanup interrupted
-- before the registration was published — still rewrites the entry as the
-- same spawn's. With no writer from either, nothing is written: an ownerless
-- entry is one no reader can classify, so this process never makes one.
recordGhGroup :: GhFetchGuard -> Repository -> OwnedProcessGroup -> IO (Either Text ())
recordGhGroup guard repository group = fmap (either Left id) . withRecordLock guard repository $ do
  existing <- recordedGhGroups repository
  let groupPid = group.ownedProcessGroupPid
      retained = listToMaybe [writer | entry <- existing, entry.ownedProcessGroupPid == groupPid, Just writer <- [entry.ownedProcessGroupOwner]]
  case group.ownedProcessGroupOwner <|> retained of
    Nothing -> pure (Left ("no writer is known for gh's process group " <> Text.pack (show groupPid) <> ", and an entry without one is never written"))
    Just writer -> writeGhGroupRecord repository (group {ownedProcessGroupOwner = Just writer} : withoutGroup groupPid existing)

-- | Takes one group off the durable record, reporting whether the record
-- actually stopped naming it.
--
-- The outcome is returned rather than discarded because dropping the entry is
-- half of what makes a cleanup clean: the group has to be gone from the
-- machine /and/ gone from the record. Removing the file and rewriting it are
-- both ordinary filesystem writes that can fail — an unwritable cache
-- directory is enough — and a caller that took the removal on trust would
-- report an ordinary timeout over an entry still sitting on disk, which is the
-- one thing the record exists to stop.
--
-- Reporting the write's own outcome rather than re-reading the record
-- afterwards is deliberate. 'recordedGhGroups' reads an unusable record as an
-- empty one, so a re-read would answer \"not recorded\" for a record nobody
-- could parse — fail-open in exactly the case that most needs the opposite.
dropGhGroup :: GhFetchGuard -> Repository -> Int -> IO (Either Text ())
dropGhGroup guard repository groupPid = fmap (either Left id) . withRecordLock guard repository $ do
  existing <- recordedGhGroups repository
  case withoutGroup groupPid existing of
    [] -> removeGhGroupRecord repository
    remaining -> writeGhGroupRecord repository remaining

withoutGroup :: Int -> [OwnedProcessGroup] -> [OwnedProcessGroup]
withoutGroup groupPid = filter ((/= groupPid) . ownedProcessGroupPid)

recordedGhGroups :: Repository -> IO [OwnedProcessGroup]
recordedGhGroups repository = do
  existing <- loadGhGroupRecord repository
  pure $ case existing of
    GhGroupRecordLoaded groups -> groups
    _ -> []

-- | Whose process wrote an entry, relative to the reader asking.
data GhEntryWriter
  = WrittenByThisProcess
  | WrittenByOtherProcess ProcessIdentity
  deriving stock (Eq, Show)

-- | What a reader makes of one recorded entry. The writer's liveness decides
-- it, matched by pid and start time; nothing here decides what may be
-- signalled.
data GhEntryClass
  = -- | The writer is running and still holds the spawn's claim, and has not
    -- given up on the group: its live work. Skipped, and kept on the record.
    GhEntryActive GhEntryWriter
  | -- | The writer is running, but its own cleanup could not confirm the
    -- group gone or could not remove the entry: marked so, or with the
    -- spawn's claim released. Re-verified on every fetch.
    GhEntryCleanupPending GhEntryWriter
  | -- | The writer is confirmed exited, so nothing is left to finish this
    -- entry but a reader. Reclaimed.
    GhEntryAbandoned ProcessIdentity
  | -- | No snapshot could say whether the writer runs. Unknown is not exited,
    -- and not live either, so the entry is neither skipped nor reclaimed.
    GhEntryWriterUnknown ProcessIdentity Text
  | -- | Written before entries carried a writer. Only ever watched.
    GhEntryOwnerless
  deriving stock (Eq, Show)

-- | Classifies one entry for a reader whose pid is @self@, against @census@,
-- a snapshot taken for this reclaim, and @claimed@, whether the spawn's claim
-- on the entry is still held.
--
-- "This process" is the writer's pid being the reader's own /and/ its start
-- time still matching, so an entry left by an earlier process that held the
-- same pid reads as abandoned, as it should.
--
-- A live writer's entry is active only while its claim is held and it is not
-- marked pending. A released claim is a writer that has stopped managing the
-- spawn — its cleanup ended without taking the entry off the record — and that
-- needs no write to say, so it holds even when the pending mark could not be
-- written.
classifyGhEntry :: Int -> Either Text [ProcessIdentity] -> Bool -> OwnedProcessGroup -> GhEntryClass
classifyGhEntry self census claimed group =
  case group.ownedProcessGroupOwner of
    Nothing -> GhEntryOwnerless
    Just writer -> case census of
      Left reason -> GhEntryWriterUnknown writer reason
      Right processes
        | null (matchingIdentities processes [writer]) -> GhEntryAbandoned writer
        | group.ownedProcessGroupCleanupPending || not claimed -> GhEntryCleanupPending (relation writer)
        | otherwise -> GhEntryActive (relation writer)
  where
    relation writer
      | writer.processIdentityPid == self = WrittenByThisProcess
      | otherwise = WrittenByOtherProcess writer

-- | How a message names an entry, one spelling per class.
--
-- Nothing is invented: an ownerless entry is described as having no writer
-- rather than being given one, and the writer's pid is named whenever the
-- entry carries it.
describeGhEntry :: GhEntryClass -> Text
describeGhEntry entryClass = case entryClass of
  GhEntryActive WrittenByThisProcess -> "a gh this process is still running"
  GhEntryActive (WrittenByOtherProcess writer) -> "a gh another running Kanban process (pid " <> pidOf writer <> ") is still running"
  GhEntryCleanupPending WrittenByThisProcess -> "a gh this process started, whose cleanup is still pending"
  GhEntryCleanupPending (WrittenByOtherProcess writer) -> "a gh another running Kanban process (pid " <> pidOf writer <> ") started, whose cleanup is still pending"
  GhEntryAbandoned writer -> "a gh left by a Kanban process that has exited (pid " <> pidOf writer <> ")"
  GhEntryWriterUnknown writer _ -> "a gh recorded by Kanban process " <> pidOf writer <> ", which could not be confirmed running or exited"
  GhEntryOwnerless -> "a gh recorded without a writer identity"
  where
    pidOf writer = Text.pack (show writer.processIdentityPid)

-- | What one entry's reclaim left of it.
data EntrySettlement
  = EntryKept
  | EntryCleared
  | EntryUnresolved Text
  deriving stock (Eq)

-- | Re-verifies, and where it is safe to do so re-kills, every recorded @gh@
-- group that is not some running process's live work — including ones
-- recorded by an earlier run of the dashboard, which is the whole reason the
-- record is on disk.
--
-- Each entry is classified by its writer's liveness ('classifyGhEntry'). An
-- active entry is skipped without refusing anything and stays on the record:
-- a concurrent reader's healthy @gh@ is not a ghost. Everything else is
-- reclaimed, and an entry is taken off the record only once it is provably
-- accounted for; the entries beside it — live, or still unresolved — are
-- kept. Anything unresolved refuses the fetch outright, so a new @gh@ is never
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
    Nothing -> do
      -- One critical section from the read to the rewrite it pairs with. The
      -- rewrite discards every entry it did not read, so a rewrite landing
      -- between the two -- another process registering its gh -- would be
      -- wiped out with the entries this did account for.
      --
      -- A lock that cannot be established refuses the fetch the way an
      -- unreadable record does, whatever the record would read as without it:
      -- a record that cannot be read under the lock has not been shown to hold
      -- nothing, and a cache path that cannot even be reached is the case
      -- where a read taken anyway is least to be trusted.
      locked <- withRecordLock guard repository reclaimRecorded
      case locked of
        Right outcome -> pure outcome
        Left message -> refuse message
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
        GhGroupRecordAbsent -> pure (Right ())
        GhGroupRecordUnusable message -> refuse message
        GhGroupRecordLoaded groups -> reclaimGroups groups

    reclaimGroups groups = do
      -- A record exists from here on, so every exit other than accounting for
      -- it has to leave the guard set. It is set now, pessimistically, because
      -- the exits that matter most are the ones that never reach a `case`:
      -- the budget expiring, or this whole reclaim being abandoned.
      setCleanupFailure guard (GhCleanupFailure (refusalText interrupted) GuardRecorded)
      self <- fromIntegral <$> getProcessID
      -- One census classifies every entry, and only an entry with a writer
      -- needs one: an ownerless record asks nothing of it.
      census <-
        if any (isJust . ownedProcessGroupOwner) groups
          then defaultProcessSnapshot
          else pure (Right [])
      settlements <-
        traverse
          ( \group -> do
              claimed <- claimHeldFor group
              settleEntry (classifyGhEntry self census claimed group) group
          )
          groups
      let kept = [group | (group, settlement) <- zip groups settlements, settlement /= EntryCleared]
          unresolved = [message | EntryUnresolved message <- settlements]
      -- Still under the record lock the read above was taken under, so the
      -- list rewritten here is exactly the list that was read, less what this
      -- reclaim accounted for.
      rewritten <-
        if null kept
          then removeGhGroupRecord repository
          else
            if length kept == length groups
              then pure (Right ())
              else writeGhGroupRecord repository kept
      case (rewritten, unresolved) of
        (Left message, _) -> refuse message
        (Right (), message : _) -> refuse message
        (Right (), []) -> do
          clearCleanupFailure guard
          pure (Right ())

    -- Asked only of an entry with a writer, the only kind the claim can
    -- decide. A probe that fails reads as released, which re-verifies the
    -- entry rather than skipping it.
    claimHeldFor group
      | isJust group.ownedProcessGroupOwner = either (const False) id <$> ghGroupClaimHeld repository group.ownedProcessGroupPid
      | otherwise = pure False

    settleEntry entryClass group = case entryClass of
      GhEntryActive _ -> pure EntryKept
      GhEntryWriterUnknown _ reason ->
        pure
          ( EntryUnresolved
              (describeGhEntry entryClass <> " (pgid " <> Text.pack (show group.ownedProcessGroupPid) <> "): " <> reason)
          )
      _ -> either EntryUnresolved (const EntryCleared) <$> reclaimGhGroup entryClass group

    refuse message = do
      setCleanupFailure guard (GhCleanupFailure (refusalText message) GuardRecorded)
      pure (Left (refusalText message))

    interrupted = "reclaiming it did not run to completion"

    -- Says what happened and refuses; it says nothing about whose gh it was.
    -- It wraps both kinds of refusal — a group this process is holding back on
    -- nothing but its own word, and a recorded one — and which process a
    -- recorded one belongs to is said by the per-entry message inside the
    -- parentheses, which is the only text that knows.
    refusalText message = "a gh process could not be confirmed stopped (" <> message <> "); refusing to start another until it is"

-- | One recorded group's second chance.
--
-- A censused group is identity-pinned, so it gets the same verified
-- TERM-then-KILL escalation again. An uncensused one never can be, so it is
-- only ever observed: whatever still matches it refuses the fetch instead of
-- being signalled blind, and — crucially — an uncensused entry is never handed
-- to the group check, whose empty membership would read as vacuously absent
-- and clear a live survivor.
--
-- The entry's class adds one restriction and grants nothing: an ownerless
-- entry is observation-only whatever its census says, retained while its pgid
-- is occupied or any saved member survives elsewhere. The writer never
-- becomes a signalling target and never proves a group this repository's;
-- the census and the saved member identities remain the whole of that.
reclaimGhGroup :: GhEntryClass -> OwnedProcessGroup -> IO (Either Text ())
reclaimGhGroup entryClass group = go group.ownedProcessGroupMembers groupCleanupPasses
  where
    groupPid = group.ownedProcessGroupPid

    origin = describeGhEntry entryClass
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

    -- An uncensused or ownerless record never pins anything, so its group can
    -- only ever be watched; a censused one is ours to signal exactly while one
    -- of the identities known to be ours is still holding its PID, start
    -- time, and group.
    provablyOurs processes known =
      entryClass /= GhEntryOwnerless
        && group.ownedProcessGroupCensused
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
