-- | The recorded process census: which processes a worker has durably
-- observed for itself, kept anchored to verifiable identities rather than
-- raw PIDs.
--
-- Its own layer rather than part of the supervisor core because
-- "Kanban.Worker.Termination" needs 'processKey' to merge a provider's
-- freshly discovered descendants into the same census the supervisor's
-- loops maintain; a shared lower-level home is what keeps that from
-- becoming an import cycle.
--
-- This module is internal — "Kanban.Worker" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Worker.Census
  ( processKey,
    recordProviderIdentity,
    refreshProcessCensus,
    liveRecordedProcessesWith,
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar_, withMVar)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Kanban.Process (ProcessIdentity (..), descendantProcesses, identityForPid, liveProcessesWith, matchingIdentities, readProcessSnapshot)
import Kanban.Worker.Paths (writeState)
import Kanban.Worker.Types (WorkerDescriptor (..), WorkerState (..))

-- | Distinguishes a process from any later, unrelated one that happens to
-- reuse the same pid, so merging two process lists never conflates them.
processKey :: ProcessIdentity -> (Int, Text)
processKey process = (process.processIdentityPid, process.processIdentityStartedAt)

-- | Records the provider's PID, start identity, and group id the moment it
-- is observed, so census roots and later terminate paths always have an
-- anchor to verify against rather than trusting a raw, possibly-reused PID.
--
-- Always uses the real 'readProcessSnapshot', never the caller's own
-- injectable 'takeSnapshot': several tests deliberately inject a snapshot
-- source that fails only to exercise a *later* verification/kill step,
-- while still relying on discovery (this function and
-- 'refreshProcessCensus') running against the real system so
-- 'workerStateKnownProcesses' is genuinely populated for that later step to
-- act on. Sharing one injectable source across both would make those two
-- concerns impossible to vary independently in a test.
recordProviderIdentity :: WorkerDescriptor -> MVar WorkerState -> Int -> IO ()
recordProviderIdentity descriptor stateLock providerPid = do
  snapshotResult <- readProcessSnapshot
  case snapshotResult of
    Left _ -> pure ()
    Right snapshot -> modifyMVar_ stateLock $ \state -> do
      let updated = state {workerStateProviderIdentity = identityForPid providerPid snapshot}
      writeState descriptor updated
      pure updated

-- | A recorded process contributes as a census root only while a fresh
-- snapshot still shows its PID with the same start identity; a mismatch
-- (PID reuse) or absence drops it instead of walking into an unrelated
-- process's descendants. Previously-known entries that no longer match are
-- pruned rather than retained as raw, unverifiable PIDs.
--
-- Always uses the real 'readProcessSnapshot' for the same reason
-- 'recordProviderIdentity' does (see its own documentation) -- discovery
-- and verification are deliberately independent axes for tests to vary.
refreshProcessCensus :: WorkerDescriptor -> MVar WorkerState -> IO ()
refreshProcessCensus descriptor stateLock = do
  snapshotResult <- readProcessSnapshot
  case snapshotResult of
    Left _ -> pure ()
    Right snapshot ->
      modifyMVar_ stateLock $ \state -> do
        let survivingKnown = matchingIdentities snapshot state.workerStateKnownProcesses
            providerRoots = maybe [] (map processIdentityPid . matchingIdentities snapshot . (: [])) state.workerStateProviderIdentity
            roots = providerRoots <> map processIdentityPid survivingKnown
            observed = descendantProcesses roots snapshot
            combined = Map.elems (Map.fromList [(processKey process, process) | process <- survivingKnown <> observed])
            updatedProcesses = sortOn processIdentityPid combined
        if updatedProcesses == state.workerStateKnownProcesses
          then pure state
          else do
            let updated = state {workerStateKnownProcesses = updatedProcesses}
            writeState descriptor updated
            pure updated

liveRecordedProcessesWith :: IO (Either Text [ProcessIdentity]) -> MVar WorkerState -> IO (Either Text [ProcessIdentity])
liveRecordedProcessesWith takeSnapshot stateLock = withMVar stateLock (liveProcessesWith takeSnapshot . (.workerStateKnownProcesses))
