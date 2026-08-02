-- | Stopping a persistent worker and everything it started: the provider's
-- group, every process its recorded census holds, and finally the
-- supervisor's own group.
--
-- Every step re-verifies an identity against a fresh snapshot before
-- signalling and again after the grace window, so a PID recycled mid-kill is
-- never the thing that gets signalled, and an inconclusive step reports
-- failure rather than letting a caller finalize on a guess. The
-- pending-termination marker exists for exactly that inconclusive case.
--
-- This module is internal — "Kanban.Worker" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Worker.Termination
  ( terminateWorker,
    terminateWorkerWith,
    finalizeUserTermination,
    terminateWorkerSelfWith,
    terminateProviderGroupWith,
    terminateProviderRefWith,
    terminateRecordedProcesses,
    terminateRecordedStateProcesses,
    terminateRecordedStateProcessesWith,
    waitForGroupMembershipStop,
    recordPendingTermination,
    pendingTerminationDiagnosticPrefix,
    workerTerminationAttempts,
    workerTerminationPollMicros,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar_, withMVar)
import Control.Exception (IOException, try)
import qualified Data.ByteString as ByteString
import Data.Either (isRight)
import Data.IORef (IORef, atomicModifyIORef', readIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Control.Monad (unless, void)
import Kanban.Process
  ( IdentityPresence (..),
    ProcessIdentity (..),
    checkGroupMembershipWith,
    defaultProcessSnapshot,
    descendantProcesses,
    identityForPid,
    killManagedProcess,
    killVerifiedGroupWith,
    managedProcessPid,
  )
import Kanban.Solve (SolveOutcome (..))
import Kanban.Worker.Census (processKey)
import Kanban.Worker.Journal (appendWorkerEvent, newEventJournalLock)
import Kanban.Worker.Lease (releaseWorkerLease)
import Kanban.Worker.Paths (ignoreFileOperation, readWorkerState, writeState)
import Kanban.Worker.Types
  ( ProviderSlot (..),
    WorkerDescriptor (..),
    WorkerEvent (..),
    WorkerState (..),
    WorkerStatus (..),
  )
import System.Directory (doesFileExist, removeFile)
import System.Posix.Files (setFileMode)
import System.Posix.Signals (sigKILL, sigTERM, signalProcessGroup)

terminateWorker :: WorkerDescriptor -> IO ()
terminateWorker = terminateWorkerWith defaultProcessSnapshot

terminateWorkerWith :: IO (Either Text [ProcessIdentity]) -> WorkerDescriptor -> IO ()
terminateWorkerWith takeSnapshot descriptor = do
  stateResult <- readWorkerState descriptor
  case stateResult of
    Left _ -> pure ()
    Right state -> case state.workerStateStatus of
      WorkerTerminal _ -> pure ()
      _ -> do
        completed <- finalizeUserTermination takeSnapshot descriptor state
        if completed
          then releaseWorkerLease descriptor
          else recordPendingTermination descriptor

-- | Attempts to complete a requested termination: verifies the provider and
-- recorded-descendant groups are gone, and only then signals the
-- supervisor's own group and writes the terminal "killed by user" outcome.
-- The supervisor itself must never be signaled until its provider and
-- recorded children are confirmed handled: a real TERM there lets the
-- supervisor's own shutdown path race this function's later checks, so an
-- earlier inconclusive (snapshot-failed) step has to stop everything, not
-- just the final state write. Shared by the initial 'terminateWorkerWith'
-- call and by 'recoverIfWorkerStoppedWith' retrying a pending termination.
finalizeUserTermination :: IO (Either Text [ProcessIdentity]) -> WorkerDescriptor -> WorkerState -> IO Bool
finalizeUserTermination takeSnapshot descriptor state = do
  providerOk <- terminateProviderGroupWith takeSnapshot state
  recordedOk <- terminateRecordedStateProcessesWith takeSnapshot state
  if not (providerOk && recordedOk)
    then pure False
    else do
      selfOk <- terminateWorkerSelfWith takeSnapshot state
      if selfOk
        then do
          now <- getCurrentTime
          let outcome = SolveFailed "killed by user"
          writeState
            descriptor
            state
              { workerStateStatus = WorkerTerminal outcome,
                workerStateProviderPid = Nothing,
                workerStateProviderIdentity = Nothing,
                workerStateHeartbeatAt = now,
                workerStateLastActivity = "killed by user"
              }
          ignoreFileOperation (removeFile descriptor.workerDescriptorPendingTerminationPath)
          pure True
        else pure False

-- | The worker supervisor is its own process-group leader (`new_session =
-- True` at launch), so its recorded identity's group id is the signal
-- target; group membership (not just PID/start time) is re-verified at each
-- checkpoint so a supervisor that kept its PID and start time but moved
-- groups is never mistaken for still owning the old group id. Uses the same
-- grace-window TERM/KILL cadence as 'Kanban.Process.killVerifiedGroup' but
-- keeps the longer, more patient exit-poll this supervisor's own graceful
-- shutdown (which itself terminates its provider and recorded children) can
-- need.
terminateWorkerSelfWith :: IO (Either Text [ProcessIdentity]) -> WorkerState -> IO Bool
terminateWorkerSelfWith takeSnapshot state = case state.workerStateWorkerIdentity of
  Nothing -> pure False
  Just workerIdentity -> do
    let groupPid = workerIdentity.processIdentityGroupPid
    initial <- checkGroupMembershipWith takeSnapshot groupPid [workerIdentity]
    case initial of
      IdentitySnapshotFailed _ -> pure False
      IdentityAbsent -> pure True
      IdentityPresent -> do
        ignoreSignal (signalProcessGroup sigTERM (fromIntegral groupPid))
        stopped <- waitForGroupMembershipStop takeSnapshot groupPid [workerIdentity] workerTerminationAttempts
        if stopped
          then pure True
          else do
            final <- checkGroupMembershipWith takeSnapshot groupPid [workerIdentity]
            case final of
              IdentityPresent -> do
                ignoreSignal (signalProcessGroup sigKILL (fromIntegral groupPid))
                waitForGroupMembershipStop takeSnapshot groupPid [workerIdentity] workerTerminationAttempts
              IdentityAbsent -> pure True
              IdentitySnapshotFailed _ -> pure False

waitForGroupMembershipStop :: IO (Either Text [ProcessIdentity]) -> Int -> [ProcessIdentity] -> Int -> IO Bool
waitForGroupMembershipStop takeSnapshot groupPid expected attempts = do
  presence <- checkGroupMembershipWith takeSnapshot groupPid expected
  case presence of
    IdentityAbsent -> pure True
    _
      | attempts <= 0 -> pure False
      | otherwise -> threadDelay workerTerminationPollMicros >> waitForGroupMembershipStop takeSnapshot groupPid expected (attempts - 1)

ignoreSignal :: IO () -> IO ()
ignoreSignal action = void (try @IOException action)

terminateRecordedProcesses :: MVar WorkerState -> IO ()
terminateRecordedProcesses stateLock = withMVar stateLock (void . terminateRecordedStateProcesses)

-- | The provider group is signaled only while its recorded anchor identity
-- still matches a fresh snapshot; a provider that was never started is a
-- no-op success, while one that was started but has no recorded identity
-- (only possible from an unverifiable legacy state) is left unsignaled and
-- reported as inconclusive so the caller does not finalize on a guess.
terminateProviderGroupWith :: IO (Either Text [ProcessIdentity]) -> WorkerState -> IO Bool
terminateProviderGroupWith takeSnapshot state = case (state.workerStateProviderPid, state.workerStateProviderIdentity) of
  (Nothing, _) -> pure True
  (Just _, Nothing) -> pure False
  (Just _, Just providerIdentity) -> isRight <$> killVerifiedGroupWith takeSnapshot providerIdentity.processIdentityGroupPid [providerIdentity]

-- | Kills the provider currently referenced by a live 'providerSlotRef'
-- handle, verifying its identity against a fresh snapshot first so a PID
-- that has already been reused points nowhere. Used by the deadline
-- watchdog instead of 'terminateProviderGroupWith', which sources its
-- identity from the durable 'WorkerState': that field can still be unset
-- when the deadline fires before 'rememberProvider' has finished recording
-- it, while the live handle itself is available the moment the provider
-- starts. Returns True when there was nothing to kill (or never will be)
-- or the kill was confirmed complete; False when a snapshot failure, a
-- missing observable process id, or a spawn still genuinely in flight left
-- it unverified, so the caller retains a pending outcome rather than
-- finalize on a guess.
--
-- Also captures the provider's own current descendants into
-- 'workerStateKnownProcesses' before killing it, independent of whether
-- 'recordProviderIdentity' ever succeeded. 'recordProviderIdentity' and
-- 'refreshProcessCensus' both silently drop a snapshot failure ('Left _ ->
-- pure ()'), and neither is ever retried afterward — a single transient
-- failure at registration time permanently leaves
-- 'workerStateProviderIdentity' unset, which starves 'refreshProcessCensus'
-- of a root to descend from for this worker's entire remaining lifetime
-- (its own 'providerRoots' computation reads exactly that field). A
-- descendant the provider later spawns into its own process group would
-- then never appear in 'workerStateKnownProcesses' at all: this function's
-- own kill would still verify and terminate the provider's *own* group
-- (its identity here comes from the live handle's pid via a snapshot this
-- function takes itself, not from that possibly-never-set field), but the
-- caller's separate 'terminateRecordedStateProcessesWith' pass over
-- 'workerStateKnownProcesses' would see nothing to kill and report success
-- vacuously, letting the escaped descendant survive a "verified" deadline
-- finalization. Since this function already has to take a fresh snapshot
-- and re-derive the provider's identity to kill it at all, it walks that
-- same snapshot for the provider's descendants too and merges them into
-- the census right here — no dependency on 'recordProviderIdentity' having
-- ever run successfully. The merge is in-memory only (no direct
-- 'writeState'): the caller's very next step, either 'completeBody' or the
-- takeover path in 'watchdogLoop', emits an event through 'emitRaw', whose
-- own 'updateWorkerState' persists whatever 'workerStateKnownProcesses'
-- currently holds — so the merge reaches disk through the normal event
-- pipeline instead of a redundant explicit write.
--
-- 'ProviderSlotIdle' is only safely "nothing to verify, and nothing ever
-- will be" because claiming it is a genuine compare-and-swap into
-- 'ProviderSlotClaimedEmpty', racing directly against the same task-side
-- attempt to leave 'ProviderSlotIdle' for 'ProviderSlotSpawning' (see the
-- 'emit' case for 'WorkerProviderSpawning' in 'runWorkerWithTask').
-- Whichever side's compare-and-swap actually lands first is authoritative:
-- if this wins, the task's own attempt is guaranteed to lose and throw
-- before it ever reaches 'createProcess' — there is no window left in
-- which a real, live process could still appear after this has already
-- committed to "nothing is here." A plain read (as the old two-'IORef'
-- design used) cannot offer that guarantee no matter what order it reads
-- in: two separate refs read one after the other can only ever report a
-- combination assembled from two different instants, and a task's own
-- transition landing in the gap between those two reads produces a
-- combination that never actually existed at any single point in time. A
-- single ref, mutated only via 'atomicModifyIORef'', has no such gap: this
-- CAS either wins (a real, instantaneous "nothing here, and nothing more
-- will start") or loses cleanly, with no assembled-from-two-moments case in
-- between.
--
-- If the CAS loses, the slot was not idle at that exact instant, so a
-- second, ordinary read decides what to do about whatever is actually
-- there now: still 'ProviderSlotSpawning' (a spawn is genuinely in flight —
-- unverified, retain the pending outcome so 'waitForOrphanResolution'
-- re-polls once it settles), 'ProviderSlotRegistered' (a real process to
-- kill and verify), or, only if the spawn attempt has since concluded
-- without ever registering one, back to 'ProviderSlotIdle' (genuinely
-- nothing, safe to treat as verified) — this second read is not itself
-- racing anything new: only this task's own thread ever writes those
-- values, so whatever this observes is a real, whole state that actually
-- held at the read instant, never a torn one.
terminateProviderRefWith :: IO (Either Text [ProcessIdentity]) -> MVar WorkerState -> IORef ProviderSlot -> IO Bool
terminateProviderRefWith takeSnapshot stateLock providerSlotRef = do
  claimedEmpty <- atomicModifyIORef' providerSlotRef $ \slot -> case slot of
    ProviderSlotIdle -> (ProviderSlotClaimedEmpty, True)
    ProviderSlotClaimedEmpty -> (ProviderSlotClaimedEmpty, True)
    other -> (other, False)
  if claimedEmpty
    then pure True
    else do
      current <- readIORef providerSlotRef
      case current of
        ProviderSlotIdle -> pure True
        ProviderSlotClaimedEmpty -> pure True
        ProviderSlotSpawning -> pure False
        ProviderSlotRegistered process -> do
          maybePid <- managedProcessPid process
          case maybePid of
            Nothing -> killManagedProcess process >> pure False
            Just pid -> do
              snapshotResult <- takeSnapshot
              case snapshotResult of
                Left _ -> killManagedProcess process >> pure False
                Right snapshot -> case identityForPid (fromIntegral pid) snapshot of
                  Nothing -> pure True
                  Just identity -> do
                    let descendants = descendantProcesses [identity.processIdentityPid] snapshot
                    unless (null descendants) $
                      modifyMVar_ stateLock $ \state ->
                        pure state {workerStateKnownProcesses = Map.elems (Map.fromList [(processKey known, known) | known <- state.workerStateKnownProcesses <> descendants])}
                    isRight <$> killVerifiedGroupWith takeSnapshot identity.processIdentityGroupPid [identity]

-- | Re-verifies each recorded process's identity before signaling its group,
-- and again before the KILL that follows the grace window, so a group that
-- exited and had its pid recycled during that window is never mistakenly
-- targeted. Returns False if any group's verification hit a snapshot
-- failure (inconclusive; the caller should retry rather than finalize).
terminateRecordedStateProcesses :: WorkerState -> IO Bool
terminateRecordedStateProcesses = terminateRecordedStateProcessesWith defaultProcessSnapshot

terminateRecordedStateProcessesWith :: IO (Either Text [ProcessIdentity]) -> WorkerState -> IO Bool
terminateRecordedStateProcessesWith takeSnapshot state = do
  results <- mapM (uncurry (killVerifiedGroupWith takeSnapshot)) (Map.toList groups)
  pure (all isRight results)
  where
    groups =
      Map.fromListWith
        (<>)
        [ (process.processIdentityGroupPid, [process])
          | process <- state.workerStateKnownProcesses,
            process.processIdentityGroupPid > 1,
            process.processIdentityGroupPid /= state.workerStateWorkerPid
        ]

-- | Marks a user-requested termination that a snapshot failure kept
-- inconclusive, so a later recovery pass ('recoverIfWorkerStoppedWith')
-- retries it once the worker's heartbeat is next observed. This is a
-- dedicated marker file rather than a 'WorkerState' field: the live
-- supervisor still owns and periodically rewrites the state file from its
-- own in-memory copy (heartbeat, census), which would otherwise clobber a
-- flag set here from outside that process. Reports a diagnostic only on the
-- transition into this state, so pressing kill again while it is still
-- pending does not duplicate the message.
recordPendingTermination :: WorkerDescriptor -> IO ()
recordPendingTermination descriptor = do
  alreadyPending <- doesFileExist descriptor.workerDescriptorPendingTerminationPath
  unless alreadyPending $ do
    result <- try @IOException (ByteString.writeFile descriptor.workerDescriptorPendingTerminationPath "pending\n")
    case result of
      Left _ -> pure ()
      Right () -> setFileMode descriptor.workerDescriptorPendingTerminationPath 0o600
    -- A lock of its own, not a shared one: this runs outside the
    -- supervisor's process entirely, and cross-process append atomicity
    -- comes from 'appendWorkerEvent's single 'hPut' rather than from any
    -- lock either side holds.
    lock <- newEventJournalLock
    appendWorkerEvent descriptor lock (WorkerDiagnostic (pendingTerminationDiagnosticPrefix <> "; retaining lease and retrying"))

-- | Shared with the UI layer so it can recognize this specific diagnostic
-- (by text, since 'WorkerDiagnostic' carries free-form text) and render the
-- session as orphaned rather than running — both live and when a durable
-- worker event journal is replayed fresh after a TUI restart, since a
-- restart never re-runs the optimistic "killed by user" UI transition this
-- diagnostic would otherwise be correcting.
pendingTerminationDiagnosticPrefix :: Text
pendingTerminationDiagnosticPrefix = "user termination: could not verify recorded descendants are gone"

workerTerminationAttempts :: Int
workerTerminationAttempts = 20

workerTerminationPollMicros :: Int
workerTerminationPollMicros = 100 * 1000
