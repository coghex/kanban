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
    interruptThenKillManagedProcess,
    killManagedProcess,
    killManagedProcessVerified,
    killVerifiedGroup,
    killVerifiedGroupWith,
    liveProcesses,
    liveProcessesWith,
    managedProcess,
    managedProcessGroup,
    managedProcessPid,
    managedProcessStopsWithDashboard,
    matchingIdentities,
    membersStillInGroup,
    readProcessSnapshot,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Control.Monad (void)
import Data.Aeson (FromJSON, ToJSON)
import Data.List (find)
import qualified Data.Map.Strict as Map
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
  = LocalManagedProcess ProcessHandle (Maybe CPid)
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
-- the group at all, orphaning any surviving member. Only the bare pgid is
-- kept, not a full snapshot-time identity: 'killManagedProcessVerified'
-- re-derives who is actually in that group from a fresh snapshot taken at
-- kill time, so a pgid that has since been fully vacated and reused by an
-- unrelated process is never mistaken for a survivor of this spawn.
managedProcess :: ProcessHandle -> IO (ManagedProcess, Maybe Text)
managedProcess processHandle = do
  (verifiedPid, problem) <- verifyGroupLeader processHandle
  pure (LocalManagedProcess processHandle verifiedPid, problem)

-- | Confirms, via a fresh process snapshot taken while the leader should
-- still be alive, that a freshly spawned local process leads its own
-- process group. A non-leader's own pid must never be signalled as if it
-- were its (shared, foreign-owned) process group, so a *confirmed*
-- non-leader yields 'Nothing'. But a leader so fast to exit that even this
-- snapshot's own external @ps@ invocation loses the race -- landing after
-- the process has already exited and been zombie-filtered out of the
-- snapshot entirely -- is not the same as a confirmed non-leader: POSIX
-- setpgid for @create_group = True@ runs synchronously before exec, so a
-- captured pid this fresh is still trustworthy as its own presumed group
-- id even though this particular check could not verify it. Discarding it
-- in that case would recreate the reaped-leader orphan bug for exactly the
-- fast-exiting tools this is meant to fix.
verifyGroupLeader :: ProcessHandle -> IO (Maybe CPid, Maybe Text)
verifyGroupLeader processHandle = do
  maybePid <- getPid processHandle
  case maybePid of
    Nothing -> pure (Nothing, Just "process has no PID to verify group leadership")
    Just pid -> do
      snapshot <- defaultProcessSnapshot
      pure $ case snapshot of
        Left message -> (Just pid, Just ("could not take a process snapshot to verify group leadership: " <> message))
        Right processes -> case identityForPid (fromIntegral pid) processes of
          Nothing -> (Just pid, Just "process was not found in a fresh process snapshot")
          Just identity
            | identity.processIdentityGroupPid == identity.processIdentityPid -> (Just pid, Nothing)
            | otherwise -> (Nothing, Just "process is not the leader of its own process group")

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
managedProcessPid (LocalManagedProcess processHandle _) = getPid processHandle
managedProcessPid (PersistentManagedProcess processId) = pure (Just processId)

managedProcessStopsWithDashboard :: ManagedProcess -> Bool
managedProcessStopsWithDashboard (LocalManagedProcess _ _) = True
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

interruptManagedProcess :: ManagedProcess -> IO ()
interruptManagedProcess (LocalManagedProcess processHandle Nothing) = signalOwnedGroup sigINT processHandle
interruptManagedProcess (LocalManagedProcess _ (Just pid)) = ignoreIOException (signalProcessGroup sigINT pid)
interruptManagedProcess (PersistentManagedProcess processId) = ignoreIOException (signalProcessGroup sigINT processId)

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
killManagedProcess (LocalManagedProcess processHandle Nothing) = do
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
killManagedProcess managed@(LocalManagedProcess _ (Just _)) = void (killManagedProcessVerified managed)
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
-- For a verified-or-presumed local leader, "who is in the group" is
-- re-derived from a *fresh* snapshot taken right now, at the start of this
-- call, rather than trusted from whatever was true back when the pgid was
-- captured (which could have been anywhere from moments to minutes ago,
-- for a long-running tool). Escalation from TERM to KILL then verifies
-- specifically that *those* re-derived members persist (the same
-- identity-and-group continuity check 'killVerifiedGroupWith' already
-- uses), not merely that the numeric pgid is non-empty: once every member
-- of the originally-owned group has exited, that pgid number is free for
-- the kernel to hand to a completely unrelated new process group, and a
-- bare "is this pgid non-empty" check would then TERM/KILL that foreign
-- group. Deriving `expected` fresh at the start of *this* call narrows the
-- reuse window to this call's own sub-two-second grace periods, and a
-- truly empty group right now is confirmed with no signal sent at all.
--
-- An unverified local process (no pid, a snapshot failure, or a confirmed
-- non-leader) falls back to the historical handle-driven behavior, always
-- reporting 'True': signalling its recorded group in that case could reach
-- an unrelated, foreign-owned group, so it is never treated as verified
-- either way.
killManagedProcessVerified :: ManagedProcess -> IO Bool
killManagedProcessVerified (LocalManagedProcess _ (Just pid)) = do
  expected <- groupMembersNow
  case expected of
    [] -> pure True
    _ -> do
      ignoreIOException (signalProcessGroup sigTERM pid)
      threadDelay terminationGraceMicros
      afterTerm <- checkGroupMembership groupPidInt expected
      case afterTerm of
        IdentityAbsent -> pure True
        _ -> do
          ignoreIOException (signalProcessGroup sigKILL pid)
          threadDelay terminationGraceMicros
          afterKill <- checkGroupMembership groupPidInt expected
          pure (afterKill == IdentityAbsent)
  where
    groupPidInt = fromIntegral pid
    groupMembersNow = do
      snapshot <- defaultProcessSnapshot
      pure (either (const []) (filter ((== groupPidInt) . processIdentityGroupPid)) snapshot)
killManagedProcessVerified managed = killManagedProcess managed >> pure True

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

snapshotRetryAttempts :: Int
snapshotRetryAttempts = 3

snapshotRetryDelayMicros :: Int
snapshotRetryDelayMicros = 150 * 1000
