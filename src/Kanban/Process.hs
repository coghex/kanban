{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

module Kanban.Process
  ( IdentityPresence (..),
    ManagedProcess,
    ProcessIdentity (..),
    checkGroupMembership,
    checkGroupMembershipWith,
    checkIdentityPresence,
    checkIdentityPresenceWith,
    defaultProcessSnapshot,
    descendantProcesses,
    identityForPid,
    interruptManagedProcess,
    interruptManagedProcessWith,
    interruptThenKillManagedProcess,
    killCensusVerified,
    killCensusVerifiedWith,
    killManagedProcess,
    killManagedProcessVerified,
    killVerifiedGroup,
    killVerifiedGroupWith,
    liveProcesses,
    liveProcessesWith,
    managedProcess,
    managedProcessWith,
    managedProcessGroup,
    managedProcessPid,
    managedProcessStopsWithDashboard,
    matchingIdentities,
    membersStillInGroup,
    readProcessSnapshot,
    watchManagedProcessCensus,
  )
where

import Control.Concurrent (ThreadId, forkIO, killThread, threadDelay)
import Control.Exception (IOException, try)
import Control.Monad (void, when)
import Data.Aeson (FromJSON, ToJSON)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import System.Exit (ExitCode (..))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Types (CPid)
import System.Posix.Signals (Signal, sigINT, sigKILL, sigTERM, signalProcess, signalProcessGroup)
import System.Process (ProcessHandle, getPid, getProcessExitCode, proc, readCreateProcessWithExitCode, terminateProcess)
import Text.Read (readMaybe)

data ProcessIdentity = ProcessIdentity
  { processIdentityPid :: Int,
    processIdentityParentPid :: Int,
    processIdentityGroupPid :: Int,
    processIdentityStartedAt :: Text,
    processIdentityCommand :: Text
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ManagedProcess
  = LocalManagedProcess ProcessHandle (Maybe CPid) (IO [ProcessIdentity]) (IO [ProcessIdentity])
  | PersistentManagedProcess CPid

-- | Wraps a freshly spawned local process handle as a 'ManagedProcess'.
-- Local kill/interrupt signal the process *group* led by the child's PID
-- (see 'signalOwnedGroup'), which only reaches the whole group when the
-- child was itself spawned as that group's leader (@create_group = True@) —
-- a non-leader is still reachable, but only itself, via the
-- ESRCH-triggered per-PID fallback. Registration always succeeds — refusing
-- to track an already-running process would leave it with no supervision at
-- all — but leadership is checked against a fresh process snapshot first,
-- so a violated precondition is surfaced immediately via the 'Just' case
-- rather than only showing up later as an inexplicably unkillable process
-- tree. A confirmed (or presumed -- see 'verifyGroupLeader') leader's own
-- pid is captured here, while the handle is still guaranteed alive, and
-- carried inside the 'ManagedProcess' value as its process group id --
-- 'getPid' returns 'Nothing' once the handle has since been reaped, which
-- would otherwise leave a later 'killManagedProcess' call unable to signal
-- the group at all, orphaning any surviving member.
--
-- A background census watcher (see 'startEmbeddedCensusWith') is started
-- here, automatically, for every confirmed-or-presumed leader -- carried
-- inside the value as a peek and a stop-and-collect action -- so every
-- kill function has a genuine, continuously-observed-since-spawn
-- provenance witness available, not just whatever a snapshot taken at kill
-- time happens to find sharing this pgid: a pgid that has since been fully
-- vacated and reused by an unrelated process is never mistaken for a
-- survivor of this spawn, no matter how long after spawn the kill actually
-- happens. The watcher stops *itself*, with no caller action required, the
-- first time it observes the group is genuinely empty (a live leader is
-- always a member of its own group, so that can only happen once this
-- spawn has truly, fully exited) -- so a 'ManagedProcess' whose process
-- simply runs to completion and is never explicitly killed still never
-- leaks its watcher thread.
--
-- A *confirmed* leader's census is seeded from the *complete* group
-- membership already visible in the exact same snapshot
-- 'verifyGroupLeaderWith' took to confirm leadership -- not a single bare
-- identity, and not a separate, later snapshot taken once the watcher
-- itself starts ticking. Broadly capturing every process already sharing
-- that pgid at verification time (not just the leader) means a child
-- forked before verification is trusted from the very first moment, even
-- if the leader itself happens to exit before the watcher's own first
-- independent tick ever runs -- closing the specific gap a leader-only
-- seed would otherwise leave between "confirmed leader" and "first tick",
-- during which a genuinely legitimate sibling could never establish
-- overlap with an already-vanished sole seed. The watcher's first
-- *independent* tick only runs 'censusIntervalMicros' later, same as
-- every subsequent one -- there is no separate, extra-narrow "immediate"
-- tick anymore, since the verification snapshot itself already serves
-- that role. A merely *presumed* leader (its own verification inconclusive
-- -- see 'verifyGroupLeaderWith') has no snapshot to seed from at all, and
-- the census starts genuinely empty for it: bootstrapping trust from
-- whatever a still-later, independent snapshot finds sharing that bare pid
-- would extend exactly the kind of unwitnessed trust this whole design
-- exists to avoid, into precisely the case (a leader too fast to survive
-- even its own verification snapshot) where pid reuse is most plausible.
-- Cleanup for a presumed leader is consequently left unresolved rather
-- than guessed at.
managedProcess :: ProcessHandle -> IO (ManagedProcess, Maybe Text)
managedProcess = managedProcessWith defaultProcessSnapshot

-- | As 'managedProcess', but with the verification/census snapshot source
-- injectable -- e.g. to deterministically simulate a merely-presumed
-- leader whose pid a later, independent snapshot shows reused by an
-- unrelated process, without needing to race real OS pid reuse in a test.
managedProcessWith :: IO (Either Text [ProcessIdentity]) -> ProcessHandle -> IO (ManagedProcess, Maybe Text)
managedProcessWith takeSnapshot processHandle = do
  (verifiedPid, seedMembers, problem) <- verifyGroupLeaderWith takeSnapshot processHandle
  (peekCensus, stopCensus) <- startEmbeddedCensusWith takeSnapshot verifiedPid seedMembers
  pure (LocalManagedProcess processHandle verifiedPid peekCensus stopCensus, problem)

-- | Confirms, via a fresh process snapshot taken while the leader should
-- still be alive, that a freshly spawned local process leads its own
-- process group -- and, only when confirmed, returns every process that
-- snapshot already shows sharing its pgid too (see 'managedProcess'), as a
-- census seed. A non-leader's own pid must never be signalled as if it
-- were its (shared, foreign-owned) process group, so a *confirmed*
-- non-leader yields 'Nothing' and no seed. But a leader so fast to exit
-- that even this snapshot's own external @ps@ invocation loses the race --
-- landing after the process has already exited and been zombie-filtered
-- out of the snapshot entirely -- is not the same as a confirmed
-- non-leader: POSIX setpgid for @create_group = True@ runs synchronously
-- before exec, so a captured pid this fresh is still trustworthy as its
-- own presumed group id for signalling purposes even though this
-- particular check could not verify it. Discarding it in that case would
-- recreate the reaped-leader orphan bug for exactly the fast-exiting tools
-- this is meant to fix -- but it is, precisely because it is unverified,
-- never returned with a census seed.
verifyGroupLeaderWith :: IO (Either Text [ProcessIdentity]) -> ProcessHandle -> IO (Maybe CPid, [ProcessIdentity], Maybe Text)
verifyGroupLeaderWith takeSnapshot processHandle = do
  maybePid <- getPid processHandle
  case maybePid of
    Nothing -> pure (Nothing, [], Just "process has no PID to verify group leadership")
    Just pid -> do
      snapshot <- takeSnapshot
      pure $ case snapshot of
        Left message -> (Just pid, [], Just ("could not take a process snapshot to verify group leadership: " <> message))
        Right processes -> case identityForPid (fromIntegral pid) processes of
          Nothing -> (Just pid, [], Just "process was not found in a fresh process snapshot")
          Just identity
            | identity.processIdentityGroupPid == identity.processIdentityPid ->
                (Just pid, filter ((== identity.processIdentityGroupPid) . processIdentityGroupPid) processes, Nothing)
            | otherwise -> (Nothing, [], Just "process is not the leader of its own process group")

managedProcessGroup :: CPid -> ManagedProcess
managedProcessGroup = PersistentManagedProcess

-- | The *currently live* pid of a managed process, or 'Nothing' once it has
-- exited and this handle has been reaped -- callers (e.g.
-- 'Kanban.Worker's cancellation path) rely on that transition to 'Nothing'
-- as a liveness signal. This intentionally ignores any pgid captured at
-- spawn time: 'killManagedProcessVerified' uses that captured pgid
-- directly, internally, to still reach a surviving group member after the
-- leader itself is gone, without changing what this accessor reports.
managedProcessPid :: ManagedProcess -> IO (Maybe CPid)
managedProcessPid (LocalManagedProcess processHandle _ _ _) = getPid processHandle
managedProcessPid (PersistentManagedProcess processId) = pure (Just processId)

-- | The peek and stop-and-collect actions for a managed process's own
-- embedded census watcher (see 'managedProcess'/'startEmbeddedCensusWith').
-- Every caller that owns responsibility for a 'ManagedProcess' through to
-- confirmed termination must eventually run the stop action exactly once,
-- to release the watcher thread.
managedProcessCensus :: ManagedProcess -> (IO [ProcessIdentity], IO [ProcessIdentity])
managedProcessCensus (LocalManagedProcess _ _ peekCensus stopCensus) = (peekCensus, stopCensus)
managedProcessCensus (PersistentManagedProcess _) = (pure [], pure [])

managedProcessStopsWithDashboard :: ManagedProcess -> Bool
managedProcessStopsWithDashboard (LocalManagedProcess _ _ _ _) = True
managedProcessStopsWithDashboard (PersistentManagedProcess _) = False

readProcessSnapshot :: IO (Either Text [ProcessIdentity])
readProcessSnapshot = do
  result <- try @IOException (readCreateProcessWithExitCode (proc "ps" ["-axo", "pid=,ppid=,pgid=,stat=,lstart=,command="]) "")
  pure $ case result of
    Left exception -> Left (Text.pack (show exception))
    Right (ExitFailure code, _, diagnostics) -> Left ("ps exited " <> Text.pack (show code) <> ": " <> Text.strip (Text.pack diagnostics))
    Right (ExitSuccess, output, _) -> Right (mapMaybeProcessLine (Text.lines (Text.pack output)))

-- | A recorded identity survives into `snapshot` only if the PID it names is
-- still held by a process with the same start time; a reused PID never
-- matches. Order follows the `known` list.
matchingIdentities :: [ProcessIdentity] -> [ProcessIdentity] -> [ProcessIdentity]
matchingIdentities snapshot known =
  [ process
    | process <- known,
      Just live <- [Map.lookup process.processIdentityPid snapshotByPid],
      live.processIdentityStartedAt == process.processIdentityStartedAt
  ]
  where
    snapshotByPid = Map.fromList [(process.processIdentityPid, process) | process <- snapshot]

identityForPid :: Int -> [ProcessIdentity] -> Maybe ProcessIdentity
identityForPid processId = find ((== processId) . processIdentityPid)

descendantProcesses :: [Int] -> [ProcessIdentity] -> [ProcessIdentity]
descendantProcesses roots processes = filter ((`Set.member` descendants) . processIdentityPid) processes
  where
    byParent = Map.fromListWith (<>) [(process.processIdentityParentPid, [process.processIdentityPid]) | process <- processes]
    descendants = expand (Set.fromList roots) roots
    expand known [] = known
    expand known (parent : pending) =
      let children = Map.findWithDefault [] parent byParent
          unseen = filter (`Set.notMember` known) children
       in expand (foldr Set.insert known unseen) (pending <> unseen)

-- | Whether each recorded identity in `known` still survives, as of a fresh
-- snapshot. A `ps` failure is reported as an explicit 'Left' rather than
-- collapsed into an empty survivor list, so a caller gating terminal state or
-- a lease release on "no survivors" never mistakes "could not check" for
-- "confirmed gone". Vacuously succeeds without taking a snapshot when there
-- is nothing recorded to verify.
liveProcesses :: [ProcessIdentity] -> IO (Either Text [ProcessIdentity])
liveProcesses = liveProcessesWith readProcessSnapshot

liveProcessesWith :: IO (Either Text [ProcessIdentity]) -> [ProcessIdentity] -> IO (Either Text [ProcessIdentity])
liveProcessesWith _ [] = pure (Right [])
liveProcessesWith takeSnapshot known = fmap (`matchingIdentities` known) <$> takeSnapshot

-- | Whether a set of recorded identities still holds its PIDs, as of a fresh
-- snapshot. A `ps` failure is reported distinctly from a clean snapshot that
-- simply shows the identities gone, so destructive callers never mistake
-- "could not check" for "confirmed gone".
data IdentityPresence = IdentityPresent | IdentityAbsent | IdentitySnapshotFailed Text
  deriving stock (Eq, Show)

-- | The retrying snapshot source shared by every default (non-`With`)
-- liveness check in this module, exposed so callers in other modules (e.g.
-- 'Kanban.Worker') can build their own retrying defaults on top of the same
-- source rather than each hard-coding the retry count.
defaultProcessSnapshot :: IO (Either Text [ProcessIdentity])
defaultProcessSnapshot = readProcessSnapshotRetrying snapshotRetryAttempts

checkIdentityPresence :: [ProcessIdentity] -> IO IdentityPresence
checkIdentityPresence = checkIdentityPresenceWith defaultProcessSnapshot

checkIdentityPresenceWith :: IO (Either Text [ProcessIdentity]) -> [ProcessIdentity] -> IO IdentityPresence
checkIdentityPresenceWith takeSnapshot expected = do
  result <- takeSnapshot
  pure $ case result of
    Left message -> IdentitySnapshotFailed message
    Right snapshot
      | null (matchingIdentities snapshot expected) -> IdentityAbsent
      | otherwise -> IdentityPresent

-- | Like `matchingIdentities`, but additionally requires the *live* process
-- (its current snapshot entry, not the possibly-stale recorded one) to still
-- belong to `groupPid`. A process that kept its PID and start time but moved
-- to a different group must not keep the old, now up-for-reuse group id
-- looking "owned".
membersStillInGroup :: Int -> [ProcessIdentity] -> [ProcessIdentity] -> [ProcessIdentity]
membersStillInGroup groupPid snapshot expected =
  [ process
    | process <- expected,
      Just live <- [Map.lookup process.processIdentityPid snapshotByPid],
      live.processIdentityStartedAt == process.processIdentityStartedAt,
      live.processIdentityGroupPid == groupPid
  ]
  where
    snapshotByPid = Map.fromList [(process.processIdentityPid, process) | process <- snapshot]

-- | As 'checkIdentityPresence', but for checks that gate a signal to a
-- specific process group: presence also requires the live snapshot to still
-- show the identity as a member of that exact group.
checkGroupMembership :: Int -> [ProcessIdentity] -> IO IdentityPresence
checkGroupMembership = checkGroupMembershipWith defaultProcessSnapshot

checkGroupMembershipWith :: IO (Either Text [ProcessIdentity]) -> Int -> [ProcessIdentity] -> IO IdentityPresence
checkGroupMembershipWith takeSnapshot groupPid expected = do
  result <- takeSnapshot
  pure $ case result of
    Left message -> IdentitySnapshotFailed message
    Right snapshot
      | null (membersStillInGroup groupPid snapshot expected) -> IdentityAbsent
      | otherwise -> IdentityPresent

-- | TERM, wait out the grace window, then KILL a persisted process group —
-- but only ever signal it while a fresh snapshot shows an identity-matching
-- member still present *in that group*, so a member that kept its PID and
-- start time but changed groups (freeing the old group id for reuse) is
-- never mistaken for still owning it. A snapshot failure at any checkpoint,
-- including the one after KILL, omits further signalling and is reported so
-- the caller retries rather than assumes the group is gone: KILL cannot be
-- blocked, but confirming its effect still takes a verified empty snapshot,
-- not just the act of sending the signal.
killVerifiedGroup :: Int -> [ProcessIdentity] -> IO (Either Text ())
killVerifiedGroup = killVerifiedGroupWith defaultProcessSnapshot

killVerifiedGroupWith :: IO (Either Text [ProcessIdentity]) -> Int -> [ProcessIdentity] -> IO (Either Text ())
killVerifiedGroupWith takeSnapshot groupPid expected = do
  before <- checkGroupMembershipWith takeSnapshot groupPid expected
  case before of
    IdentitySnapshotFailed message -> pure (Left message)
    IdentityAbsent -> pure (Right ())
    IdentityPresent -> do
      ignoreIOException (signalProcessGroup sigTERM (fromIntegral groupPid))
      threadDelay terminationGraceMicros
      after <- checkGroupMembershipWith takeSnapshot groupPid expected
      case after of
        IdentitySnapshotFailed message -> pure (Left message)
        IdentityAbsent -> pure (Right ())
        IdentityPresent -> do
          ignoreIOException (signalProcessGroup sigKILL (fromIntegral groupPid))
          threadDelay terminationGraceMicros
          final <- checkGroupMembershipWith takeSnapshot groupPid expected
          case final of
            IdentitySnapshotFailed message -> pure (Left message)
            IdentityAbsent -> pure (Right ())
            IdentityPresent -> pure (Left "signalled group did not exit after SIGKILL")

readProcessSnapshotRetrying :: Int -> IO (Either Text [ProcessIdentity])
readProcessSnapshotRetrying attempts = do
  result <- readProcessSnapshot
  case result of
    Right snapshot -> pure (Right snapshot)
    Left message
      | attempts <= 1 -> pure (Left message)
      | otherwise -> threadDelay snapshotRetryDelayMicros >> readProcessSnapshotRetrying (attempts - 1)

mapMaybeProcessLine :: [Text] -> [ProcessIdentity]
mapMaybeProcessLine = foldr (maybe id (:)) [] . map parseProcessLine

-- | A zombie has already been terminated by the kernel and can do no further
-- work; it is excluded here so every liveness/census check throughout this
-- module treats it as gone, rather than as a still-present process merely
-- awaiting its parent's `wait()`. A signalled process that becomes a zombie
-- (e.g. a killed supervisor whose parent process never reaps it) would
-- otherwise appear to survive its own confirmed kill indefinitely.
parseProcessLine :: Text -> Maybe ProcessIdentity
parseProcessLine line = case Text.words line of
  pidText : parentText : groupText : statText : weekday : month : day : clock : year : commandParts
    | isZombieStat statText -> Nothing
    | otherwise -> do
        pid <- readMaybe (Text.unpack pidText)
        parentPid <- readMaybe (Text.unpack parentText)
        groupPid <- readMaybe (Text.unpack groupText)
        pure
          ProcessIdentity
            { processIdentityPid = pid,
              processIdentityParentPid = parentPid,
              processIdentityGroupPid = groupPid,
              processIdentityStartedAt = Text.unwords [weekday, month, day, clock, year],
              processIdentityCommand = Text.unwords commandParts
            }
  _ -> Nothing

isZombieStat :: Text -> Bool
isZombieStat = Text.isInfixOf "Z"

-- | Unlike 'killManagedProcess' (which must still reach a group after its
-- leader has died, to clean up orphaned members left behind), SIGINT is
-- only ever meaningful to a genuinely live, listening leader -- so there is
-- nothing to lose by refusing to signal at all once that can no longer be
-- freshly verified. Merely confirming that *whoever currently holds this
-- pid* is presently a group leader is not enough: a fully unrelated
-- process that happens to lead its own, newly-created group could satisfy
-- that check just as well as the original leader, if the kernel reused
-- this exact pid/pgid after the original exited. This additionally
-- requires that pid to overlap the process's own embedded census (see
-- 'managedProcess'/'managedProcessCensus') -- a genuine, continuously-
-- observed-since-spawn witness that this really is the same spawn, not
-- merely a fresh coincidence -- before signalling; either check failing
-- silently no-ops rather than delivering an interrupt to a stranger.
interruptManagedProcess :: ManagedProcess -> IO ()
interruptManagedProcess = interruptManagedProcessWith defaultProcessSnapshot

-- | As 'interruptManagedProcess', but with the liveness/ownership snapshot
-- injectable -- e.g. to deterministically simulate a pgid that has been
-- reused by an unrelated group leader the census never witnessed, without
-- needing to race real OS pid reuse in a test.
interruptManagedProcessWith :: IO (Either Text [ProcessIdentity]) -> ManagedProcess -> IO ()
interruptManagedProcessWith _ (LocalManagedProcess processHandle Nothing _ _) = signalOwnedGroup sigINT processHandle
interruptManagedProcessWith takeSnapshot (LocalManagedProcess _ (Just pid) peekCensus _) = do
  census <- peekCensus
  snapshot <- takeSnapshot
  case snapshot of
    Left _ -> pure ()
    Right processes -> case identityForPid (fromIntegral pid) processes of
      Just identity
        | identity.processIdentityGroupPid == fromIntegral pid,
          not (null (membersStillInGroup (fromIntegral pid) processes census)) ->
            ignoreIOException (signalProcessGroup sigINT pid)
      _ -> pure ()
interruptManagedProcessWith _ (PersistentManagedProcess processId) = ignoreIOException (signalProcessGroup sigINT processId)

-- | Ctrl-C's escalation for a still-owned process: SIGINT first, then fall
-- back to 'killManagedProcess's bounded TERM/KILL escalation regardless of
-- whether the interrupt already reaped it -- signalling an empty group is a
-- harmless no-op, and 'killManagedProcess' still confirms via a fresh
-- process-group snapshot before deciding whether SIGKILL is needed, so no
-- separate liveness check is needed here before falling back to it.
interruptThenKillManagedProcess :: ManagedProcess -> IO ()
interruptThenKillManagedProcess process = do
  interruptManagedProcess process
  threadDelay terminationGraceMicros
  killManagedProcess process

-- | Terminates a managed process. A verified local leader (see
-- 'managedProcess') is always signalled by its process group id captured at
-- spawn time, regardless of whether the leader handle itself now shows as
-- exited or reaped -- 'getPid'/'getProcessExitCode' can no longer be
-- trusted at that point, but the group can still hold live members that
-- would otherwise be silently orphaned. Escalation to SIGKILL is decided by
-- a fresh process-group membership check (confirmed termination is the
-- absence of surviving group members, not merely a reaped leader), not by
-- re-inspecting the leader's own handle. An unverified local process (no
-- pid, a snapshot failure, or a confirmed non-leader) falls back to the
-- historical handle-driven behavior, since signalling its recorded group in
-- that case could reach an unrelated, foreign-owned group instead.
killManagedProcess :: ManagedProcess -> IO ()
killManagedProcess (LocalManagedProcess processHandle Nothing _ _) = do
  exitCode <- getProcessExitCode processHandle
  case exitCode of
    Just _ -> pure ()
    Nothing -> do
      signalOwnedGroup sigTERM processHandle
      threadDelay terminationGraceMicros
      stopped <- getProcessExitCode processHandle
      case stopped of
        Just _ -> pure ()
        Nothing -> signalOwnedGroup sigKILL processHandle
killManagedProcess managed@(LocalManagedProcess _ (Just _) _ _) = void (killManagedProcessVerified managed)
killManagedProcess (PersistentManagedProcess processId) = do
  ignoreIOException (signalProcessGroup sigTERM processId)
  threadDelay terminationGraceMicros
  ignoreIOException (signalProcessGroup sigKILL processId)

-- | Like 'killManagedProcess', but reports whether the group is confirmed
-- empty afterward, rather than discarding that final check -- for callers
-- (namely 'Kanban.Review's tool registry) that must not treat an invocation
-- as terminated, and safe to remove from their own bookkeeping, until they
-- know for sure.
--
-- For a verified-or-presumed local leader, this delegates straight to
-- 'killCensusVerified' using the process's own embedded, continuously-
-- recorded-since-spawn census (see 'managedProcess'/'managedProcessCensus')
-- -- a genuine, non-reusable provenance witness, not merely whatever a
-- snapshot taken at kill time happens to find sharing this pgid *right
-- now*, however long after spawn that kill actually happens. A first
-- attempt that cannot yet establish continuity (e.g. the embedded watcher
-- has not yet ticked past a since-reaped leader to catch a real, but
-- not-yet-witnessed, orphaned survivor) is retried, pausing
-- 'killConfirmRetryDelayMicros' first so the still-running watcher gets a
-- real chance to catch up before giving up.
--
-- An unverified local process (no pid or a confirmed non-leader) falls
-- back to the historical handle-driven behavior, always reporting 'True':
-- signalling its recorded group in that case could reach an unrelated,
-- foreign-owned group, so it is never treated as verified either way.
killManagedProcessVerified :: ManagedProcess -> IO Bool
killManagedProcessVerified managed@(LocalManagedProcess _ (Just _) peekCensus _) = go killConfirmAttempts
  where
    go attemptsLeft
      | attemptsLeft <= (0 :: Int) = pure False
      | otherwise = do
          confirmed <- killCensusVerified managed peekCensus
          if confirmed
            then pure True
            else threadDelay killConfirmRetryDelayMicros >> go (attemptsLeft - 1)
killManagedProcessVerified managed = killManagedProcess managed >> pure True

-- | TERM, wait, verify via 'checkGroupEmpty', escalate to KILL and verify
-- again if needed -- shared by every kill path here once it has already
-- decided, via a provenance-backed census
-- ('killCensusVerified'/'killManagedProcessVerified'), that `pid`'s group
-- is worth signalling at all. `_expected` is unused by the confirmation
-- check itself: termination is confirmed only
-- once the group's *complete* current membership is empty, not merely once
-- the specific identities that justified signalling in the first place are
-- gone -- a member that forks a fresh same-group child from its own TERM
-- handler moments before dying would otherwise vanish from `_expected`'s
-- perspective while its new, never-`_expected` child survives undetected.
killIdentitiesVerified :: CPid -> [ProcessIdentity] -> IO Bool
killIdentitiesVerified pid _expected = do
  ignoreIOException (signalProcessGroup sigTERM pid)
  threadDelay terminationGraceMicros
  afterTerm <- checkGroupEmpty groupPidInt
  case afterTerm of
    Right True -> pure True
    Right False -> do
      ignoreIOException (signalProcessGroup sigKILL pid)
      threadDelay terminationGraceMicros
      afterKill <- checkGroupEmpty groupPidInt
      pure (afterKill == Right True)
    Left _ -> pure False
  where
    groupPidInt = fromIntegral pid

-- | Whether the process group led by `groupPid` is, per a fresh snapshot,
-- completely empty right now -- the actual definition of "confirmed
-- terminated" (see 'killIdentitiesVerified'): restricted to whether
-- specific previously-recorded identities survive would miss a fresh
-- same-group child a dying member forked moments before exiting.
checkGroupEmpty :: Int -> IO (Either Text Bool)
checkGroupEmpty groupPid = do
  snapshot <- defaultProcessSnapshot
  pure (null . filter ((== groupPid) . processIdentityGroupPid) <$> snapshot)

-- | As 'managedProcessCensus', but wrapped in 'IO' for source
-- compatibility with existing callers written against the pre-embedded-
-- census API: the watcher is already running (started automatically by
-- 'managedProcess'), so this performs no new work of its own.
watchManagedProcessCensus :: ManagedProcess -> IO (IO [ProcessIdentity], IO [ProcessIdentity])
watchManagedProcessCensus = pure . managedProcessCensus

-- | Spawns a background watcher that, every 'censusIntervalMicros' (with
-- one synchronous tick taken before this even returns -- see below),
-- records every current member of the managed leader's process group into
-- an accumulating census, *never* clearing what has already been recorded
-- -- a tick finding the group completely empty stops the watcher (see
-- below for why) but leaves the census exactly as it last stood. Returns
-- two actions: `peek` reads everything recorded so far *without* stopping
-- the watcher, so a caller can re-check partway through a multi-attempt
-- kill sequence and see what a tick recorded in the meantime; `stop` kills
-- the watcher thread (a safe no-op if it has already stopped itself) and
-- returns its final reading. A caller that explicitly confirms termination
-- should still run `stop` once it does, to release the reference promptly,
-- but nothing leaks even if it never gets the chance to.
--
-- This exists because a descendant discovered only *after* the leader has
-- already exited can no longer be found by parent-chain descent at all --
-- once reparented (to init/launchd), its `ppid` no longer names the
-- now-gone leader. A snapshot taken only at that point has nothing but the
-- numeric pgid left to go on, and a bare pgid match alone cannot
-- distinguish a legitimate, unwitnessed member of *this* spawn from a
-- fully unrelated process group the kernel later assigned the exact same,
-- since-vacated pgid. Recording the group's membership continuously, with
-- no gap, from a verified spawn onward is what closes that: at every tick,
-- whatever currently shares this pgid is treated as a further-confirmed
-- member of the *same*, continuously-observed spawn. A verified leader
-- (see 'managedProcess') is always itself a member of its own group for as
-- long as it lives, so the group can only ever be observed empty once the
-- leader has truly exited -- at that exact point this spawn is genuinely,
-- fully gone, and this stops watching (so a 'ManagedProcess' whose process
-- simply exits on its own, with no caller ever calling a kill function on
-- it at all, does not leak this thread forever). The census itself is
-- deliberately *not* cleared at that point: 'killCensusVerified' treats a
-- non-empty census as requiring every one of its recorded identities to
-- overlap a *fresh* snapshot before trusting anything -- so once this spawn
-- has genuinely gone empty, its now-stale census can never again overlap
-- whatever a later, coincidentally-reused pgid's occupants look like, and
-- correctly keeps refusing to vouch for them. Clearing it here instead
-- would erase that evidence and let 'killCensusVerified' fall back to
-- trusting a bare, unwitnessed snapshot of exactly the reused pgid this
-- design exists to distrust.
--
-- There is no separate, synchronous "first tick" anymore: `knownRef`
-- starts seeded directly from 'verifyGroupLeaderWith's own snapshot for a
-- *confirmed* leader (already the complete group, not just the leader
-- alone -- see 'managedProcess'), and the watcher's first *independent*
-- check only runs 'censusIntervalMicros' later, exactly like every
-- subsequent one (see 'recordCensusTick'). An extra, immediate tick taken
-- right after seeding would just be a second, separate snapshot racing the
-- same reuse window verification itself is already exposed to, for no
-- additional benefit. For a merely *presumed* leader, there is no seed at
-- all -- `knownRef` starts and stays empty, and no watcher is even started
-- (nothing could ever establish overlap with an empty base to accumulate
-- anyway); see 'recordCensusTick' for why that is the correct, deliberate
-- outcome rather than a bug.
startEmbeddedCensusWith :: IO (Either Text [ProcessIdentity]) -> Maybe CPid -> [ProcessIdentity] -> IO (IO [ProcessIdentity], IO [ProcessIdentity])
startEmbeddedCensusWith _ Nothing _ = pure (pure [], pure [])
startEmbeddedCensusWith _ (Just _) [] = pure (pure [], pure [])
startEmbeddedCensusWith takeSnapshot (Just pid) seedMembers = do
  knownRef <- newIORef (Set.fromList seedMembers)
  watcherId <- forkIO (watchLoop knownRef True)
  pure (peek knownRef, stopAndCollect watcherId knownRef)
  where
    peek :: IORef (Set ProcessIdentity) -> IO [ProcessIdentity]
    peek knownRef = Set.toList <$> readIORef knownRef
    stopAndCollect :: ThreadId -> IORef (Set ProcessIdentity) -> IO [ProcessIdentity]
    stopAndCollect watcherId knownRef = do
      killThread watcherId
      Set.toList <$> readIORef knownRef
    watchLoop :: IORef (Set ProcessIdentity) -> Bool -> IO ()
    watchLoop _ False = pure ()
    watchLoop knownRef True = do
      threadDelay censusIntervalMicros
      stillOpen <- recordCensusTick takeSnapshot pid knownRef
      watchLoop knownRef stillOpen

-- | Records one tick of a census (see 'startEmbeddedCensusWith'). Returns
-- 'True' while the group still has any live members at all (the watcher
-- should keep going), or 'False' the moment a tick finds it genuinely
-- empty (the watcher should stop itself) -- but never clears `knownRef`
-- either way, so a census that once recorded real members and has since
-- gone empty stays distinguishable from one that has never recorded
-- anything at all (see 'startEmbeddedCensusWith' for why that distinction
-- matters). A snapshot failure is treated as inconclusive, not as
-- emptiness -- it neither adds nor clears anything, and reports 'True' so
-- the watcher keeps trying on its next tick rather than prematurely giving
-- up on a still-live group.
--
-- Sampling only every 'censusIntervalMicros' -- not continuously -- leaves
-- a real gap: the *entire* original group could exit and this exact pgid
-- get reused by a fully unrelated process, all within a single interval,
-- with no tick ever observing genuine emptiness in between. A tick's
-- freshly-observed `groupMembers` is therefore only ever merged into the
-- trusted census when it overlaps (by identity-and-group continuity, the
-- same 'membersStillInGroup' check used everywhere else) what the census
-- already trusted -- proof that at least one already-trusted identity was
-- *still alive* at this exact tick, so whatever else shares its pgid right
-- now is a genuine sibling of that continuing spawn, not a fresh occupant
-- that arrived sometime after the last trusted member vanished. A tick
-- with zero such overlap leaves the census exactly as it was -- unresolved
-- for this tick, not extended -- rather than risk folding in a reused
-- foreign group.
--
-- There is deliberately no bootstrapping exemption for an empty
-- `knownRef`: unlike a previous design, a tick never trusts whatever it
-- finds merely because nothing has been recorded yet. A *confirmed* leader
-- never needs one -- 'startEmbeddedCensusWith' already seeds `knownRef`
-- with its verified identity before this ever runs, so the very first tick
-- overlaps that seed normally. A *presumed* leader has no seed and
-- consequently never accumulates any census evidence at all: bootstrapping
-- trust from an independent, later snapshot of a bare, unverified pid
-- would extend exactly the unwitnessed trust this design exists to avoid
-- into precisely the case -- a leader too fast to survive even its own
-- verification snapshot -- where pid reuse before that snapshot is most
-- plausible. 'killCensusVerified' already reports an empty census as
-- unresolved rather than falling back to a bare snapshot, so this
-- correctly, permanently leaves a presumed leader's cleanup unresolved
-- rather than ever guessing at it.
recordCensusTick :: IO (Either Text [ProcessIdentity]) -> CPid -> IORef (Set ProcessIdentity) -> IO Bool
recordCensusTick takeSnapshot pid knownRef = do
  snapshot <- takeSnapshot
  case snapshot of
    Left _ -> pure True
    Right processes -> case filter ((== groupPidInt) . processIdentityGroupPid) processes of
      [] -> pure False
      groupMembers -> do
        known <- readIORef knownRef
        let continuous = not (null (membersStillInGroup groupPidInt processes (Set.toList known)))
        when continuous (atomicModifyIORef' knownRef (\current -> (foldr Set.insert current groupMembers, ())))
        pure True
  where
    groupPidInt = fromIntegral pid

-- | Confirms `managed`'s recorded group terminated. `peekCensus` (see
-- 'watchManagedProcessCensus') is consulted *before* ever sending a
-- signal: if the group's current, complete membership shares no identity
-- at all with anything the census has ever continuously observed, this
-- reports unresolved without touching it, rather than guessing whether an
-- entirely unwitnessed occupant is a legitimate, if-uncaught member of
-- this spawn or an unrelated group that happened to reuse its pgid. Once
-- at least one census-recorded identity is confirmed still present, the
-- group's full current membership -- not just the matched identity -- is
-- what actually gets signalled and re-checked (TERM, verify, escalate to
-- KILL if needed), so a legitimate sibling the census also caught is
-- reached even though only one witness was strictly required to trust the
-- group at all. "Confirmed empty" is always a fresh, complete pgid check,
-- never restricted to prior identities matching -- see
-- 'killManagedProcessVerified', which this delegates the actual
-- signal/verify sequence to once continuity is established.
--
-- An empty census (e.g. the very first, synchronous tick hitting a
-- transient snapshot failure, or landing on a leader so fast to exit it
-- was already gone) reports unresolved rather than falling back to
-- trusting a single bare snapshot of whoever currently holds this pgid:
-- with no continuity evidence recorded yet at all, that occupant could
-- just as easily be an unrelated spawn that happened to receive this exact
-- pid moments after a near-instant original exit. This is self-healing
-- through retries -- see 'killManagedProcessVerified' and
-- 'Kanban.Review.confirmToolProcessTerminated' -- since the still-running
-- embedded watcher keeps ticking regardless, and its very next tick almost
-- always populates real census data for a later attempt to use.
killCensusVerified :: ManagedProcess -> IO [ProcessIdentity] -> IO Bool
killCensusVerified = killCensusVerifiedWith defaultProcessSnapshot

-- | As 'killCensusVerified', but with the continuity-gating snapshot
-- injectable -- e.g. to deterministically simulate a pgid that has been
-- reused by an unrelated process group the census never witnessed,
-- without needing to race real OS pid reuse in a test.
killCensusVerifiedWith :: IO (Either Text [ProcessIdentity]) -> ManagedProcess -> IO [ProcessIdentity] -> IO Bool
killCensusVerifiedWith takeSnapshot (LocalManagedProcess _ (Just pid) _ _) peekCensus = do
  census <- peekCensus
  case census of
    [] -> pure False
    _ -> do
      snapshot <- takeSnapshot
      case snapshot of
        -- A snapshot failure here must not fall through to a blind signal:
        -- an unreadable snapshot means the census's continuity gate below
        -- can never actually run, so there is no verified basis for
        -- reaching this pgid at all -- an unrelated group could easily be
        -- what a signal sent here actually reaches.
        Left _ -> pure False
        Right processes -> case filter ((== groupPidInt) . processIdentityGroupPid) processes of
          [] -> pure True
          currentMembers
            | null (membersStillInGroup groupPidInt processes census) -> pure False
            | otherwise -> killIdentitiesVerified pid currentMembers
  where
    groupPidInt = fromIntegral pid
killCensusVerifiedWith _ managed _peekCensus = killManagedProcessVerified managed

signalOwnedGroup :: Signal -> ProcessHandle -> IO ()
signalOwnedGroup signal processHandle = do
  processId <- getPid processHandle
  case processId of
    Just pid -> signalGroupOrOwnedPid signal pid
    Nothing -> ignoreIOException (terminateProcess processHandle)

-- | Signals the process group led by `pid`; when no such group exists
-- (ESRCH — e.g. `pid` was never actually a group leader), falls back to
-- signalling `pid` itself, so a child that slipped past 'managedProcess'
-- without leading its own group is still reachable rather than silently
-- un-signalled. Any other failure is ignored, same as the group signal
-- itself: the process being already gone counts as success either way.
signalGroupOrOwnedPid :: Signal -> CPid -> IO ()
signalGroupOrOwnedPid signal pid = do
  result <- try (signalProcessGroup signal pid) :: IO (Either IOException ())
  case result of
    Right () -> pure ()
    Left exception
      | isDoesNotExistError exception -> ignoreIOException (signalProcess signal pid)
      | otherwise -> pure ()

ignoreIOException :: IO () -> IO ()
ignoreIOException action = void (try action :: IO (Either IOException ()))

terminationGraceMicros :: Int
terminationGraceMicros = 750 * 1000

-- | How often 'startEmbeddedCensusWith' takes a fresh snapshot to record new
-- descendants. Short enough that even a tool living only a couple of
-- seconds gets at least one real tick before it can need killing.
censusIntervalMicros :: Int
censusIntervalMicros = 500 * 1000

-- | Bounds 'killManagedProcessVerified's retries when its first attempt
-- cannot yet establish continuity via the embedded census (see
-- 'killConfirmRetryDelayMicros' for why a retry is worth attempting at
-- all).
killConfirmAttempts :: Int
killConfirmAttempts = 3

-- | Paced to comfortably exceed 'censusIntervalMicros', so a retry in
-- 'killManagedProcessVerified' genuinely gives the still-running embedded
-- watcher a chance to record an intervening tick -- not an immediate,
-- still-stale re-peek of exactly the same reading that just failed to
-- establish continuity.
killConfirmRetryDelayMicros :: Int
killConfirmRetryDelayMicros = 600 * 1000

snapshotRetryAttempts :: Int
snapshotRetryAttempts = 3

snapshotRetryDelayMicros :: Int
snapshotRetryDelayMicros = 150 * 1000
