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
    forceCensusTick,
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
    recordCensusTick,
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
import Data.Maybe (isJust)
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
  = LocalManagedProcess ProcessHandle (Maybe CPid) (IO [ProcessIdentity]) (IO ()) (IO [ProcessIdentity])
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
-- identity. A *presumed* leader (its own verification inconclusive -- see
-- 'verifyGroupLeaderWith') starts with no seed at all. Either way, the
-- watcher's own first tick runs synchronously, immediately, before this
-- function even returns -- not after any scheduled delay -- and that
-- first tick (like every one after it) can trust its full reading via
-- either of two independently safe proofs, not the seed's overlap alone:
-- overlapping what's already `known`, or the leader simply not having
-- been reaped *by anyone* yet, an OS-level guarantee (see
-- 'startEmbeddedCensusWith') that this exact pid cannot possibly have
-- been handed to an unrelated process. This is what actually closes the
-- gap a seed-only design would otherwise leave open between "verified" (or
-- presumed) and "first independent tick": a child forked, and its leader
-- exited, entirely before verification's own snapshot ever ran is still
-- caught, seed or no seed, for as long as nothing has reaped the leader
-- yet -- which, for both a confirmed and a presumed leader alike, is true
-- from the moment 'managedProcess' is called through to whenever this
-- invocation's own normal completion eventually reaps it. Cleanup remains
-- unresolved -- rather than ever guessed at -- only for the much narrower
-- residual case where the leader is reaped before any tick, seeded or
-- not, ever had a chance to witness a genuine sibling at all.
managedProcess :: ProcessHandle -> IO (ManagedProcess, Maybe Text)
managedProcess = managedProcessWith defaultProcessSnapshot

-- | As 'managedProcess', but with the verification/census snapshot source
-- injectable -- e.g. to deterministically simulate a merely-presumed
-- leader whose pid a later, independent snapshot shows reused by an
-- unrelated process, without needing to race real OS pid reuse in a test.
managedProcessWith :: IO (Either Text [ProcessIdentity]) -> ProcessHandle -> IO (ManagedProcess, Maybe Text)
managedProcessWith takeSnapshot processHandle = do
  (verifiedPid, seedMembers, problem) <- verifyGroupLeaderWith takeSnapshot processHandle
  (peekCensus, forceTick, stopCensus) <- startEmbeddedCensusWith takeSnapshot (managedProcessHandleStillOpen processHandle) verifiedPid seedMembers
  pure (LocalManagedProcess processHandle verifiedPid peekCensus forceTick stopCensus, problem)

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
-- never returned with a census *seed* (see 'startEmbeddedCensusWith' for
-- why an empty seed here still gets a genuine, not-yet-reaped-protected
-- census watcher of its own, not no watcher at all).
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
managedProcessPid (LocalManagedProcess processHandle _ _ _ _) = getPid processHandle
managedProcessPid (PersistentManagedProcess processId) = pure (Just processId)

-- | The peek, force-tick, and stop-and-collect actions for a managed
-- process's own embedded census watcher (see
-- 'managedProcess'/'startEmbeddedCensusWith'). Every caller that owns
-- responsibility for a 'ManagedProcess' through to confirmed termination
-- must eventually run the stop action exactly once, to release the
-- watcher thread.
managedProcessCensus :: ManagedProcess -> (IO [ProcessIdentity], IO (), IO [ProcessIdentity])
managedProcessCensus (LocalManagedProcess _ _ peekCensus forceTick stopCensus) = (peekCensus, forceTick, stopCensus)
managedProcessCensus (PersistentManagedProcess _) = (pure [], pure (), pure [])

managedProcessStopsWithDashboard :: ManagedProcess -> Bool
managedProcessStopsWithDashboard (LocalManagedProcess _ _ _ _ _) = True
managedProcessStopsWithDashboard (PersistentManagedProcess _) = False

-- | Forces one more, synchronous census observation right now, on top of
-- whatever the background watcher's own scheduled ticks have already
-- recorded (a no-op for a 'PersistentManagedProcess', which has no
-- watcher at all). Safe to call concurrently with the watcher's own
-- ongoing ticking -- 'recordCensusTick' only ever atomically extends a
-- shared 'Data.IORef.IORef', so a forced call and a scheduled one racing
-- each other is at worst mildly redundant, never lost or corrupted.
--
-- Exists specifically for a caller about to reap a managed leader's own
-- 'ProcessHandle' itself (i.e. call @waitForProcess@/@getProcessExitCode@
-- directly, as every tool invocation's normal-completion path eventually
-- must, to read its exit code): the background watcher's *scheduled*
-- ticks run every 'censusIntervalMicros' in steady state, and a child
-- forked -- with the leader then reaped by that very caller -- entirely
-- within that gap would otherwise never be witnessed while
-- 'managedProcessHandleStillOpen' could still vouch for it, permanently
-- losing the not-yet-reaped proof for it. Calling this immediately before
-- the real reap closes that gap down to the same back-to-back-syscalls
-- window 'startEmbeddedCensusWith's own synchronous first tick already
-- achieves for the initial seed, rather than leaving it open for up to a
-- full scheduled interval.
forceCensusTick :: ManagedProcess -> IO ()
forceCensusTick (LocalManagedProcess _ _ _ forceTick _) = forceTick
forceCensusTick (PersistentManagedProcess _) = pure ()

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
-- (its current snapshot entry, not the possibly-stale recorded one) to
-- still belong to `groupPid` and still run the same command line. A
-- process that kept its PID and start time but moved to a different group
-- must not keep the old, now up-for-reuse group id looking "owned". This
-- deliberately does *not* also require the parent pid to match: a
-- genuinely tracked descendant's parent pid legitimately changes once its
-- original parent exits and it gets reparented (to init/launchd) -- the
-- entire reason this codebase tracks descendants by a continuously-updated
-- census rather than a live parent-chain walk (see
-- 'startEmbeddedCensusWith'). Requiring parent pid to stay fixed would
-- reject exactly the reparented survivors this whole design exists to
-- still reach.
--
-- KNOWN, ACCEPTED LIMITATION: `ps` only reports start times at
-- one-second resolution (see 'mapMaybeProcessLine'), and this codebase has
-- no access to a true, unambiguous process-birth identity (e.g. a
-- kernel-assigned monotonic sequence number) without additional
-- platform-specific system calls this project does not currently make.
-- Matching on pid, start time, group, and command line together
-- substantially narrows -- but provably cannot eliminate -- the
-- possibility that an unrelated process reusing the exact same pid within
-- the same reported second, running an identical command line, is
-- mistaken for the original. This is a genuine, currently irreducible gap
-- given the data available from `ps`, not an oversight; closing it fully
-- would require a different process-identity mechanism entirely.
membersStillInGroup :: Int -> [ProcessIdentity] -> [ProcessIdentity] -> [ProcessIdentity]
membersStillInGroup groupPid snapshot expected =
  [ process
    | process <- expected,
      Just live <- [Map.lookup process.processIdentityPid snapshotByPid],
      live.processIdentityStartedAt == process.processIdentityStartedAt,
      live.processIdentityGroupPid == groupPid,
      live.processIdentityCommand == process.processIdentityCommand
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
interruptManagedProcessWith _ (LocalManagedProcess processHandle Nothing _ _ _) = signalOwnedGroup sigINT processHandle
interruptManagedProcessWith takeSnapshot (LocalManagedProcess _ (Just pid) peekCensus _ _) = do
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
killManagedProcess (LocalManagedProcess processHandle Nothing _ _ _) = do
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
killManagedProcess managed@(LocalManagedProcess _ (Just _) _ _ _) = void (killManagedProcessVerified managed)
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
killManagedProcessVerified managed@(LocalManagedProcess _ (Just _) peekCensus _ _) = go killConfirmAttempts
  where
    go attemptsLeft
      | attemptsLeft <= (0 :: Int) = pure False
      | otherwise = do
          confirmed <- killCensusVerified managed peekCensus
          if confirmed
            then pure True
            else threadDelay killConfirmRetryDelayMicros >> go (attemptsLeft - 1)
killManagedProcessVerified managed = killManagedProcess managed >> pure True

-- | TERM, wait, verify via 'checkGroupEmptyWith', escalate to KILL and verify
-- again if needed -- shared by every kill path here once it has already
-- decided, via a provenance-backed census
-- ('killCensusVerified'/'killManagedProcessVerified'), that `pid`'s group
-- is worth signalling at all. `_expected` is unused by the confirmation
-- check itself: termination is confirmed only once the group's *complete*
-- current membership is empty, not merely once the specific identities
-- that justified signalling in the first place are gone -- a member that
-- forks a fresh same-group child from its own TERM handler moments before
-- dying would otherwise vanish from `_expected`'s perspective while its
-- new, never-`_expected` child survives undetected.
--
-- Escalating straight to SIGKILL the instant a post-TERM snapshot shows
-- *anything* at this pgid would itself be unsafe: if TERM genuinely
-- emptied the original group, that pgid is immediately free for the
-- kernel to hand to a fully unrelated process, and a single snapshot
-- cannot tell a freshly-reused foreign occupant apart from a legitimate
-- survivor. 'confirmEscalationTarget' ties the decision back to
-- `peekCensus` -- the same continuously-updating, provenance-backed
-- witness used to justify sending TERM in the first place -- rather than
-- a fresh, unwitnessed reading: only an occupant that is *itself* still
-- census-known is trusted enough for SIGKILL. An ambiguous reading --
-- nothing still census-known, or a snapshot failure -- reports unresolved
-- rather than ever guessing.
killIdentitiesVerified :: IO (Either Text [ProcessIdentity]) -> IO [ProcessIdentity] -> CPid -> [ProcessIdentity] -> IO Bool
killIdentitiesVerified takeSnapshot peekCensus pid _expected = do
  ignoreIOException (signalProcessGroup sigTERM pid)
  threadDelay terminationGraceMicros
  afterTerm <- checkGroupEmptyWith takeSnapshot groupPidInt
  case afterTerm of
    Right True -> pure True
    Right False -> do
      trusted <- confirmEscalationTarget takeSnapshot peekCensus groupPidInt
      case trusted of
        Nothing -> pure False
        Just _ -> do
          ignoreIOException (signalProcessGroup sigKILL pid)
          threadDelay terminationGraceMicros
          afterKill <- checkGroupEmptyWith takeSnapshot groupPidInt
          pure (afterKill == Right True)
    Left _ -> pure False
  where
    groupPidInt = fromIntegral pid

-- | Confirms whatever currently occupies `groupPid` is trustworthy enough
-- for 'killIdentitiesVerified' to escalate to SIGKILL: it is itself an
-- identity `peekCensus` has already recorded (a genuine survivor, or a
-- child the watcher's own ongoing ticking independently caught during the
-- grace wait) -- matched, like everywhere else in this module, by
-- identity-and-group continuity ('membersStillInGroup'), not merely a
-- bare pid number. A pgid reused by a fully unrelated foreign process
-- satisfies this only if it happens to also recreate a census-recorded
-- pid *and* start time *and* command line, an astronomically unlikely
-- coincidence rather than a plausible attack. Returns 'Nothing'
-- (ambiguous, do not escalate) if the group reads empty, the snapshot
-- fails, or nothing census-known survives.
--
-- An earlier design additionally trusted a fresh occupant whose
-- `processIdentityParentPid` merely *numbered* the same as some
-- previously-census-recorded pid (round 10's "TERM handler forks a child"
-- scenario: the dying member is census-known, even once it is itself
-- gone) -- but a dying member's own pid is exactly the pid TERM was just
-- sent to, and once reaped it becomes immediately eligible for OS reuse.
-- An unrelated new process spawned moments later, coincidentally reusing
-- that exact pid as its own leader and forking its own, entirely foreign
-- child, would have that child's parent pid match the same number --
-- authorizing SIGKILL against a foreign group this design was never able
-- to verify belongs to this spawn at all. Unlike a leader's own pid (see
-- 'startEmbeddedCensusWith'), this module has no live 'ProcessHandle' for
-- an arbitrary non-leader census member, so there is no not-yet-reaped
-- proof available to rescue this case safely -- it is left permanently
-- unresolved (no escalation) rather than trusting a bare, reusable pid
-- number.
confirmEscalationTarget :: IO (Either Text [ProcessIdentity]) -> IO [ProcessIdentity] -> Int -> IO (Maybe [ProcessIdentity])
confirmEscalationTarget takeSnapshot peekCensus groupPid = do
  snapshot <- takeSnapshot
  case snapshot of
    Left _ -> pure Nothing
    Right processes -> case filter ((== groupPid) . processIdentityGroupPid) processes of
      [] -> pure Nothing
      currentMembers -> do
        census <- peekCensus
        let survivors = membersStillInGroup groupPid processes census
        if null survivors
          then pure Nothing
          else pure (Just currentMembers)

-- | Whether the process group led by `groupPid` is, per a fresh snapshot,
-- completely empty right now -- the actual definition of "confirmed
-- terminated" (see 'killIdentitiesVerified'): restricted to whether
-- specific previously-recorded identities survive would miss a fresh
-- same-group child a dying member forked moments before exiting.
checkGroupEmptyWith :: IO (Either Text [ProcessIdentity]) -> Int -> IO (Either Text Bool)
checkGroupEmptyWith takeSnapshot groupPid = do
  snapshot <- takeSnapshot
  pure (null . filter ((== groupPid) . processIdentityGroupPid) <$> snapshot)

-- | As 'managedProcessCensus', but wrapped in 'IO' for source
-- compatibility with existing callers written against the pre-embedded-
-- census API: the watcher is already running (started automatically by
-- 'managedProcess'), so this performs no new work of its own.
watchManagedProcessCensus :: ManagedProcess -> IO (IO [ProcessIdentity], IO (), IO [ProcessIdentity])
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
-- `known` starts seeded directly from 'verifyGroupLeaderWith's own
-- snapshot for a *confirmed* leader (already the complete group, not just
-- the leader alone -- see 'managedProcess'). A gap remains: a child forked
-- *after* that snapshot but *before* the watcher's next tick has nothing in
-- `known` to overlap with if the leader exits in between, and a tick
-- landing only after that exit would then never record it -- not on that
-- tick, and not ever afterward, since nothing would ever again overlap a
-- permanently-vanished seed. An earlier design tried closing this by
-- promoting a reading two consecutive ticks agreed on even without any tie
-- to the original seed; that opened exactly the reuse risk this whole file
-- exists to prevent (an unrelated process that happens to occupy a
-- freshly-reused pgid for two ticks would have been promoted just as
-- readily as a genuine descendant), so 'recordCensusTick' does not do
-- that.
--
-- Instead, `known` may be extended by either of two independently safe
-- proofs: overlapping `known` itself (the original mechanism, still the
-- only proof available once the leader is reaped -- see below), or
-- 'managedProcessHandleStillOpen' reporting the leader's own
-- 'ProcessHandle' still open -- i.e. genuinely unreaped, by *anyone*,
-- anywhere in the whole program -- both immediately before and
-- immediately after this exact tick's snapshot (see 'recordCensusTick').
--
-- An earlier version of this same idea checked a bare pid's OS-level
-- existence (POSIX's null signal) instead of the handle. That was
-- unsound: existence alone only proves *something* currently occupies
-- that pid number, not that it is still the process this module spawned.
-- If the original group had already emptied and its pid/pgid gotten
-- reused by a fully unrelated foreign leader before the probe ever ran,
-- the null-signal check would succeed against that foreign occupant just
-- as readily as against a genuine survivor, and this tick would wrongly
-- adopt the foreign group as trusted provenance. 'managedProcessHandleStillOpen'
-- has no such gap: it never queries the OS process table by number at
-- all, only 'getPid's own in-memory bookkeeping for *this specific*
-- 'ProcessHandle' (see there) -- which can only ever report the leader
-- unreaped for as long as *no* successful 'getProcessExitCode'/'waitForProcess'
-- call has happened on this exact handle, from anywhere, a fact a
-- reused pid number cannot forge no matter what the kernel does with it.
-- This is a genuine identity anchor, not a bare-occupancy proxy: it is
-- tied to the one, unique, in-process value that names *this* spawn and
-- nothing else, never to a reusable OS-level number.
--
-- Checking is deliberately non-destructive and bracketed around the
-- snapshot (both immediately before and immediately after), for the same
-- two reasons established over the last two rounds: 'getProcessExitCode'/
-- 'waitForProcess' themselves must never be used for this check, since
-- the first call to ever observe a zombie leader's exit reaps it right
-- then, on the spot, which would make this exact tick's own check of it
-- report "reaped" even when the snapshot it is meant to vouch for was
-- captured while genuinely still safe -- 'getPid' has no such side effect
-- (a pure read, confirmed against the @process@ library's own source);
-- and a single check on only one side of the snapshot would leave the
-- *other* side -- where the handle could still be closed just before or
-- just after the probe ran -- unwitnessed. This closes exactly the gap
-- the two-tick mechanism tried and failed to close safely: a child
-- forked and its leader reaped (by us, elsewhere, once this invocation's
-- own normal completion runs) all before a single tick ever lands --
-- without ever trusting a bare, reusable pid number to stand in for
-- genuine identity.
--
-- The very first tick runs synchronously, here, before this function ever
-- returns a watcher to its caller -- not after the first
-- 'bootstrapBurstIntervalMicros' delay like every later tick. Since
-- nothing else has any opportunity to reap the leader before this function
-- has even returned control to its own caller ('managedProcess'), this
-- first tick in particular is *always* covered by the not-yet-reaped proof
-- above unless the leader had already been reaped by something outside
-- this module entirely (which 'managedProcess's own contract rules out).
--
-- A merely *presumed* leader (`Just pid` but an empty seed -- see
-- 'verifyGroupLeaderWith') still gets a real watcher, seeded with nothing
-- at all rather than short-circuited away entirely: the not-yet-reaped
-- proof above does not depend on independently verifying `known`'s
-- starting contents in the first place, only on the leader's own handle
-- not having been reaped yet, which holds exactly as well here as for a
-- confirmed leader -- 'managedProcessHandleStillOpen' consults the same
-- 'ProcessHandle' regardless of whether 'verifyGroupLeaderWith's own
-- snapshot ever managed to independently confirm it. What verification
-- failed to confirm was never "is this pid its own group leader" being
-- false -- that case is a *confirmed* non-leader, which returns 'Nothing'
-- for the pid entirely and never reaches this function's general case at
-- all (see 'verifyGroupLeaderWith') -- it was only that the snapshot
-- taken to confirm it either failed outright or lost the race against a
-- near-instantly-exiting leader. POSIX setpgid for @create_group = True@
-- runs synchronously before exec, so a pid this fresh is already
-- trustworthy as its own group id for querying purposes even though this
-- particular snapshot could not verify it (the same reasoning
-- 'killManagedProcess's per-pid fallback already relies on for signalling
-- a presumed leader directly). An empty starting seed simply means the
-- very first tick has nothing to overlap -- but, exactly as for a
-- confirmed leader, it does not need to: not-yet-reaped alone already
-- justifies trusting whatever that first tick finds sharing this pgid,
-- including a child forked and its leader exited before verification's
-- own snapshot ever ran.
startEmbeddedCensusWith :: IO (Either Text [ProcessIdentity]) -> IO Bool -> Maybe CPid -> [ProcessIdentity] -> IO (IO [ProcessIdentity], IO (), IO [ProcessIdentity])
startEmbeddedCensusWith _ _ Nothing _ = pure (pure [], pure (), pure [])
startEmbeddedCensusWith takeSnapshot checkHandleStillOpen (Just pid) seedMembers = do
  knownRef <- newIORef (Set.fromList seedMembers)
  stillOpenAfterFirstTick <- recordCensusTick takeSnapshot checkHandleStillOpen pid knownRef
  watcherId <- forkIO (watchLoop knownRef bootstrapBurstTicks stillOpenAfterFirstTick)
  pure (peek knownRef, forceTick knownRef, stopAndCollect watcherId knownRef)
  where
    peek :: IORef (Set ProcessIdentity) -> IO [ProcessIdentity]
    peek knownRef = Set.toList <$> readIORef knownRef
    forceTick :: IORef (Set ProcessIdentity) -> IO ()
    forceTick knownRef = void (recordCensusTick takeSnapshot checkHandleStillOpen pid knownRef)
    stopAndCollect :: ThreadId -> IORef (Set ProcessIdentity) -> IO [ProcessIdentity]
    stopAndCollect watcherId knownRef = do
      killThread watcherId
      Set.toList <$> readIORef knownRef
    watchLoop :: IORef (Set ProcessIdentity) -> Int -> Bool -> IO ()
    watchLoop _ _ False = pure ()
    watchLoop knownRef burstTicksLeft True = do
      threadDelay (if burstTicksLeft > 0 then bootstrapBurstIntervalMicros else censusIntervalMicros)
      stillOpen <- recordCensusTick takeSnapshot checkHandleStillOpen pid knownRef
      watchLoop knownRef (max 0 (burstTicksLeft - 1)) stillOpen

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
-- Sampling only every 'censusIntervalMicros' -- not continuously -- would,
-- on its own, leave a real gap: the *entire* original group could exit and
-- this exact pgid get reused by a fully unrelated process, all within a
-- single interval, with no tick ever observing genuine emptiness in
-- between. A tick's freshly-observed `groupMembers` is therefore only ever
-- merged into the trusted census when at least one of two independently
-- safe proofs holds (see 'startEmbeddedCensusWith'): it overlaps (by
-- identity-and-group continuity, the same 'membersStillInGroup' check used
-- everywhere else) what the census already trusted -- proof that at least
-- one already-trusted identity was *still alive* at this exact tick, so
-- whatever else shares its pgid right now is a genuine sibling of that
-- continuing spawn -- or `checkHandleStillOpen` (see
-- 'managedProcessHandleStillOpen') reports the leader's own
-- 'ProcessHandle' still open, both immediately before and immediately
-- after the snapshot, which is proof *this specific spawn* could not
-- possibly have been reaped -- and its pid thereby freed for reuse --
-- anywhere in that bracket, regardless of whether anything in `known`
-- happens to still be visible in the snapshot itself. This is an identity
-- check, not a bare pid-occupancy one: it can only ever report the
-- *original* leader unreaped, never a coincidentally-reused pid an
-- unrelated foreign process now happens to hold. Bracketing rather than
-- checking only once matters here: `checkHandleStillOpen` has no side
-- effect, so nothing is lost by calling it twice, and a single check on
-- only one side would leave the *other* side of the snapshot -- where the
-- handle could still have been closed before or after the probe ran --
-- unwitnessed. A tick satisfying neither proof leaves the census exactly
-- as it was -- unresolved for this tick, not extended -- rather than risk
-- folding in a reused foreign group.
recordCensusTick :: IO (Either Text [ProcessIdentity]) -> IO Bool -> CPid -> IORef (Set ProcessIdentity) -> IO Bool
recordCensusTick takeSnapshot checkHandleStillOpen pid knownRef = do
  openBefore <- checkHandleStillOpen
  snapshot <- takeSnapshot
  case snapshot of
    Left _ -> pure True
    Right processes -> case filter ((== groupPidInt) . processIdentityGroupPid) processes of
      [] -> pure False
      groupMembers -> do
        known <- readIORef knownRef
        openAfter <- checkHandleStillOpen
        let overlapsKnown = not (null (membersStillInGroup groupPidInt processes (Set.toList known)))
            notYetReaped = openBefore && openAfter
            trustworthy = overlapsKnown || notYetReaped
        when trustworthy (atomicModifyIORef' knownRef (\current -> (foldr Set.insert current groupMembers, ())))
        pure True
  where
    groupPidInt = fromIntegral pid

-- | Whether `processHandle` is still open -- i.e. whether *nothing*,
-- anywhere in the whole program, has yet reaped it via a successful
-- 'getProcessExitCode'/'waitForProcess' call. A pure, in-memory read of
-- the handle's own bookkeeping ('getPid'; confirmed non-destructive
-- against the @process@ library's own source), not a query against the
-- OS process table by bare pid number: a bare-pid existence probe (e.g.
-- POSIX's null signal) cannot distinguish "still the process we spawned"
-- from "an unrelated process the kernel has since reassigned this exact
-- pid to", since the only thing such a check can observe is whether some
-- pid number is occupied by anyone at all. This check has no such gap --
-- 'getPid' can only ever report 'Just' for a handle exactly as long as
-- the specific child *this* handle was constructed for remains unreaped,
-- regardless of what pid number the kernel has since handed to some
-- entirely different process.
managedProcessHandleStillOpen :: ProcessHandle -> IO Bool
managedProcessHandleStillOpen processHandle = isJust <$> getPid processHandle

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
killCensusVerifiedWith takeSnapshot (LocalManagedProcess _ (Just pid) _ _ _) peekCensus = do
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
            | otherwise -> killIdentitiesVerified takeSnapshot peekCensus pid currentMembers
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
-- descendants, once its initial burst (see 'bootstrapBurstTicks') is
-- exhausted. Short enough that even a tool living only a couple of seconds
-- gets at least one real tick before it can need killing.
censusIntervalMicros :: Int
censusIntervalMicros = 500 * 1000

-- | How many rapid ticks 'startEmbeddedCensusWith' takes, 'bootstrapBurstIntervalMicros'
-- apart, right after seeding a confirmed leader's census -- narrowing the
-- window during which a leader that forks a child and exits unusually
-- quickly could leave that child permanently unrecorded (see
-- 'startEmbeddedCensusWith').
bootstrapBurstTicks :: Int
bootstrapBurstTicks = 8

-- | The interval between 'startEmbeddedCensusWith's initial burst ticks --
-- deliberately much shorter than the steady-state 'censusIntervalMicros'.
bootstrapBurstIntervalMicros :: Int
bootstrapBurstIntervalMicros = 50 * 1000

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
