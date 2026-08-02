-- | Watching a persistent worker from outside its own process: replaying its
-- journal to a live event sink, and failing closed when the supervisor
-- behind that journal has stopped without ever writing a terminal envelope.
--
-- Sits above "Kanban.Worker.Journal", "Kanban.Worker.Lease", and
-- "Kanban.Worker.Termination" rather than inside any of them: recovery is
-- precisely the point where a journal drain, an identity-verified kill, and
-- a lease release have to be ordered against one another, and placing it in
-- the journal itself would make the journal depend on the termination that
-- already depends on it.
--
-- This module is internal — "Kanban.Worker" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Worker.Monitor
  ( monitorWorker,
    recoverIfWorkerStopped,
    recoverIfWorkerStoppedWith,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.Maybe (catMaybes, mapMaybe)
import Data.Text (Text)
import Data.Time (NominalDiffTime, diffUTCTime, getCurrentTime)
import Kanban.Process (IdentityPresence (..), ProcessIdentity, checkIdentityPresenceWith, defaultProcessSnapshot)
import Kanban.Solve (SolveOutcome (..))
import Kanban.Worker.Journal
  ( decodeJournalLine,
    drainJournalBeforeExit,
    emitEnvelope,
    isTerminalEnvelope,
    readJournalSince,
  )
import Kanban.Worker.Lease (releaseWorkerLease, supervisorLaunchIdentityPresenceWith)
import Kanban.Worker.Paths (ignoreFileOperation, readWorkerState, writeState)
import Kanban.Worker.Termination
  ( finalizeUserTermination,
    terminateProviderGroupWith,
    terminateRecordedStateProcessesWith,
  )
import Kanban.Worker.Types
  ( WorkerDescriptor (..),
    WorkerEvent (..),
    WorkerId (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
  )
import System.Directory (doesFileExist, removeFile)

monitorWorker :: WorkerDescriptor -> (WorkerId -> WorkerSpec -> WorkerEvent -> IO ()) -> IO ()
monitorWorker descriptor eventSink = loop 0
  where
    loop consumed = do
      readResult <- readJournalSince descriptor consumed
      case readResult of
        -- A read failure must not move the consumption position: retrying
        -- with the same offset is what makes a transient failure (EINTR,
        -- EMFILE, a race with a concurrent append) neither replay nor skip
        -- any journal line (see issue #8).
        Left _ -> threadDelay workerMonitorIntervalMicros >> loop consumed
        Right (unseen, newConsumed) -> do
          let envelopes = mapMaybe decodeJournalLine unseen
          mapM_ (emitEnvelope descriptor eventSink) envelopes
          if any isTerminalEnvelope envelopes
            then pure ()
            else do
              recovered <- recoverIfWorkerStopped descriptor eventSink newConsumed
              unless recovered $ threadDelay workerMonitorIntervalMicros >> loop newConsumed

-- A provider is deliberately subordinate to its persistent supervisor.  If
-- that supervisor disappears, fail closed instead of leaving an invisible
-- model process able to consume tokens indefinitely.
recoverIfWorkerStopped :: WorkerDescriptor -> (WorkerId -> WorkerSpec -> WorkerEvent -> IO ()) -> Int -> IO Bool
recoverIfWorkerStopped = recoverIfWorkerStoppedWith defaultProcessSnapshot

recoverIfWorkerStoppedWith :: IO (Either Text [ProcessIdentity]) -> WorkerDescriptor -> (WorkerId -> WorkerSpec -> WorkerEvent -> IO ()) -> Int -> IO Bool
recoverIfWorkerStoppedWith takeSnapshot descriptor eventSink consumedJournalBytes = do
  stateResult <- readWorkerState descriptor
  case stateResult of
    Left _ -> do
      -- No state file exists yet to consult for the supervisor's identity;
      -- fall back to the identity recorded directly on the lease at launch
      -- (see 'recordLaunchedSupervisorIdentity'), which is available to
      -- this independent recovery pass exactly because the state file is
      -- not. Unlike the prior elapsed-time heuristic this replaces, there is
      -- no time-based escape hatch: elapsed time cannot distinguish a
      -- still-slow-but-alive supervisor from a dead one, so a launch whose
      -- identity was never recorded (a legacy lease, or best-effort capture
      -- that never succeeded) is left pending rather than finalized on a
      -- guess.
      identityPresence <- supervisorLaunchIdentityPresenceWith takeSnapshot descriptor
      case identityPresence of
        Just IdentityAbsent -> finalizeMissingState
        _ -> pure False
    Right state -> case state.workerStateStatus of
      -- Mirrors leaseIsActive's own re-check for WorkerTerminal: every path
      -- that writes it has already verified zero survivors, so this is
      -- normally immediate, but releasing here unconditionally would be the
      -- one place in this module that trusts the status label over a
      -- recorded identity. A live match (e.g. this pass racing the narrow
      -- window between the terminal write and the writer's own release)
      -- leaves the lease untouched and lets the monitor loop retry rather
      -- than free it out from under something still recorded as present.
      WorkerTerminal outcome -> do
        let identities = catMaybes [state.workerStateWorkerIdentity, state.workerStateProviderIdentity] <> state.workerStateKnownProcesses
        presence <- if null identities then pure IdentityAbsent else checkIdentityPresenceWith takeSnapshot identities
        case presence of
          IdentityAbsent -> do
            drained <- drainJournalBeforeExit descriptor eventSink consumedJournalBytes
            case drained of
              Nothing -> pure False
              Just sawFinished -> do
                releaseWorkerLease descriptor
                unless sawFinished $ eventSink spec.workerId spec (WorkerFinished outcome)
                pure True
          _ -> pure False
      _ -> do
        now <- getCurrentTime
        if diffUTCTime now state.workerStateHeartbeatAt < workerStaleHeartbeatSeconds
          then retryPendingTermination state
          else case state.workerStateWorkerIdentity of
            -- No recorded identity to verify against: fail closed as still
            -- active rather than guess the worker is gone from a bare PID.
            Nothing -> pure False
            Just workerIdentity -> do
              presence <- checkIdentityPresenceWith takeSnapshot [workerIdentity]
              case presence of
                IdentityPresent -> pure False
                IdentitySnapshotFailed _ -> reportStaleRecoveryPending state
                IdentityAbsent -> do
                  providerOk <- terminateProviderGroupWith takeSnapshot state
                  recordedOk <- terminateRecordedStateProcessesWith takeSnapshot state
                  if not (providerOk && recordedOk)
                    then reportStaleRecoveryPending state
                    else do
                      drained <- drainJournalBeforeExit descriptor eventSink consumedJournalBytes
                      case drained of
                        Nothing -> pure False
                        Just sawFinished -> do
                          -- A pending user termination that outlived its supervisor
                          -- (the kill request was recorded but never reached a
                          -- supervisor that has since died on its own) still
                          -- finalizes as "killed by user" rather than the generic
                          -- unexpected-stop outcome.
                          pendingTermination <- doesFileExist descriptor.workerDescriptorPendingTerminationPath
                          let diagnostic
                                | pendingTermination = "stale-supervisor recovery: completing a pending user termination"
                                | otherwise = "persistent worker stopped unexpectedly; its provider process group was terminated"
                              outcome
                                | pendingTermination = SolveFailed "killed by user"
                                | otherwise = SolveFailed diagnostic
                              terminalState =
                                state
                                  { workerStateStatus = WorkerTerminal outcome,
                                    workerStateProviderPid = Nothing,
                                    workerStateProviderIdentity = Nothing,
                                    workerStateHeartbeatAt = now,
                                    workerStateLastActivity = "worker failed closed"
                                  }
                          writeState descriptor terminalState
                          ignoreFileOperation (removeFile descriptor.workerDescriptorPendingTerminationPath)
                          releaseWorkerLease descriptor
                          eventSink spec.workerId spec (WorkerDiagnostic diagnostic)
                          unless sawFinished $ eventSink spec.workerId spec (WorkerFinished outcome)
                          pure True
  where
    spec = descriptor.workerDescriptorSpec
    -- Reached only once the supervisor is confirmed absent by its durably
    -- recorded launch identity — its single call site above has no other
    -- entry condition, and deliberately no elapsed-time one. No state file
    -- ever appeared, so nothing was ever started to terminate beyond the
    -- lease itself.
    finalizeMissingState = do
      drained <- drainJournalBeforeExit descriptor eventSink consumedJournalBytes
      case drained of
        Nothing -> pure False
        Just sawFinished -> do
          let message = "persistent worker never published its initial state"
          releaseWorkerLease descriptor
          eventSink spec.workerId spec (WorkerDiagnostic message)
          unless sawFinished $ eventSink spec.workerId spec (WorkerFinished (SolveFailed message))
          pure True
    -- A pending user termination ('terminateWorkerWith' left it unverified)
    -- is retried here even while the supervisor's heartbeat is still fresh,
    -- since an unverified termination never signaled the supervisor and it
    -- has no reason to retry the kill itself.
    retryPendingTermination state = do
      pending <- doesFileExist descriptor.workerDescriptorPendingTerminationPath
      if not pending
        then pure False
        else do
          completed <- finalizeUserTermination takeSnapshot descriptor state
          if not completed
            then pure False
            else do
              drained <- drainJournalBeforeExit descriptor eventSink consumedJournalBytes
              case drained of
                Nothing -> pure False
                Just sawFinished -> do
                  releaseWorkerLease descriptor
                  unless sawFinished $ eventSink spec.workerId spec (WorkerFinished (SolveFailed "killed by user"))
                  pure True
    -- Reports the stale-supervisor verification failure once, on the
    -- transition into this state, rather than on every ~200ms recovery poll;
    -- the unresolved state itself remains visible via 'WorkerOrphaned'.
    reportStaleRecoveryPending state = do
      let message = "stale-supervisor recovery: a process snapshot failed while verifying the worker and its recorded descendants are gone; retaining orphan state and lease"
          pendingOutcome = SolveFailed message
      unless (state.workerStateStatus == WorkerOrphaned pendingOutcome) $ do
        writeState descriptor state {workerStateStatus = WorkerOrphaned pendingOutcome, workerStateLastActivity = "stale-recovery verification pending"}
        eventSink spec.workerId spec (WorkerDiagnostic message)
      pure False

workerMonitorIntervalMicros :: Int
workerMonitorIntervalMicros = 200 * 1000

workerStaleHeartbeatSeconds :: NominalDiffTime
workerStaleHeartbeatSeconds = 20
