-- | The one-live-worker invariant: the per-item lease directory a launch
-- must win before a supervisor starts, and the identity-verified rules that
-- decide whether an existing lease is still live or safe to retire.
--
-- Every judgement here fails closed. A lease whose owner cannot be proven
-- dead — an undecodable record, a snapshot that will not run, a recorded
-- identity that still matches, an unresolved pending termination — stays
-- active rather than risk a second worker on the same issue or PR, and the
-- comments on each rule record which alternative was rejected and why.
--
-- This module is internal — "Kanban.Worker" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Worker.Lease
  ( acquireWorkerLease,
    acquireWorkerLeaseFor,
    WorkerLeaseRefusal (..),
    workerLeaseRefusalMessage,
    releaseWorkerLease,
    retireStaleLease,
    leaseIsActive,
    leaseIsRecent,
    recordedIdentitiesActive,
    workerLeaseConflictMessage,
    recordLaunchedSupervisorIdentity,
    supervisorLaunchIdentityPresenceWith,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (void)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (NominalDiffTime, diffUTCTime, getCurrentTime)
import Kanban.Process (IdentityPresence (..), ProcessIdentity, checkIdentityPresenceWith, defaultProcessSnapshot, identityForPid)
import Kanban.Worker.Paths (decodeFile, ignoreFileOperation, writePrivateJson)
import Kanban.Worker.Types
  ( PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerDescriptor (..),
    WorkerId (..),
    WorkerLease (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    WorkerTask (..),
  )
import System.Directory (createDirectory, doesFileExist, getModificationTime, removeDirectory, removeFile, renameDirectory)
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Files (setFileMode)
import System.Process (ProcessHandle, getPid)

-- | Why a lease could not be taken, with the one answer a caller can act on
-- told apart from the rest.
--
-- The lease is keyed by /item/ rather than by worker id, so it is already an
-- atomic reservation of one issue's or one pull request's next turn: whoever
-- creates the directory owns that turn. What a losing caller could not do was
-- tell "someone else owns this turn" from "the lease could not be taken",
-- and a caller that cannot tell them apart reports a failure where it should
-- be joining the turn that is already running.
data WorkerLeaseRefusal
  = -- | A live worker holds this item's lease. Carries that worker's id when
    -- the owner record could be read; an owner record that will not decode
    -- still means held, and says so without naming anyone.
    WorkerLeaseHeld (Maybe WorkerId) Text
  | WorkerLeaseUnavailable Text
  deriving stock (Eq, Show)

workerLeaseRefusalMessage :: WorkerLeaseRefusal -> Text
workerLeaseRefusalMessage (WorkerLeaseHeld _ message) = message
workerLeaseRefusalMessage (WorkerLeaseUnavailable message) = message

-- | The message-shaped facade every existing caller keeps.
acquireWorkerLease :: WorkerDescriptor -> IO (Either Text ())
acquireWorkerLease descriptor =
  either (Left . workerLeaseRefusalMessage) Right <$> acquireWorkerLeaseFor descriptor

acquireWorkerLeaseFor :: WorkerDescriptor -> IO (Either WorkerLeaseRefusal ())
acquireWorkerLeaseFor descriptor = attempt workerLeaseAttempts
  where
    attempt attempts = do
      created <- try @IOException (createDirectory descriptor.workerDescriptorLeasePath)
      case created of
        Right () -> do
          setFileMode descriptor.workerDescriptorLeasePath 0o700
          written <-
            writePrivateJson
              descriptor.workerDescriptorLeaseOwnerPath
              WorkerLease
                { workerLeaseId = descriptor.workerDescriptorSpec.workerId,
                  workerLeaseCreatedAt = descriptor.workerDescriptorSpec.workerCreatedAt,
                  workerLeaseSupervisorIdentity = Nothing
                }
          case written of
            Right () -> pure (Right ())
            Left message -> do
              ignoreFileOperation (removeDirectory descriptor.workerDescriptorLeasePath)
              pure (Left (WorkerLeaseUnavailable ("could not initialize worker lease: " <> message)))
        Left exception
          | not (isAlreadyExistsError exception) ->
              pure (Left (WorkerLeaseUnavailable ("could not acquire worker lease: " <> Text.pack (show exception))))
          | attempts <= 0 ->
              pure (Left (WorkerLeaseUnavailable "could not acquire worker lease after concurrent recovery"))
          | otherwise -> do
              active <- leaseIsActive descriptor
              if active
                then do
                  owner <- decodeFile descriptor.workerDescriptorLeaseOwnerPath :: IO (Either Text WorkerLease)
                  pure
                    ( Left
                        ( WorkerLeaseHeld
                            (either (const Nothing) (Just . (.workerLeaseId)) owner)
                            (workerLeaseConflictMessage descriptor.workerDescriptorSpec.workerTask)
                        )
                    )
                else do
                  retired <- retireStaleLease descriptor
                  case retired of
                    Left message -> pure (Left (WorkerLeaseUnavailable message))
                    Right () -> attempt (attempts - 1)

leaseIsActive :: WorkerDescriptor -> IO Bool
leaseIsActive descriptor = do
  leaseResult <- decodeFile descriptor.workerDescriptorLeaseOwnerPath :: IO (Either Text WorkerLease)
  case leaseResult of
    Left _ -> leaseIsRecent descriptor
    Right lease -> do
      let ownerBase = takeDirectory descriptor.workerDescriptorLeasePath </> Text.unpack lease.workerLeaseId.unWorkerId
          statePath = ownerBase <> ".state.json"
          pendingTerminationPath = ownerBase <> ".pending-termination"
      stateResult <- decodeFile statePath :: IO (Either Text WorkerState)
      case stateResult of
        Right state -> case state.workerStateStatus of
          -- Every path that writes WorkerTerminal has already verified zero
          -- surviving identities before doing so, so this is normally
          -- redundant; it is still re-checked (rather than trusted
          -- unconditionally) so a live identity match at this exact moment —
          -- e.g. a PID somehow reused with the same recorded start time in
          -- the narrow window right after that verified write — still blocks
          -- a relaunch instead of racing it. Every recorded identity is
          -- consulted, not only the supervisor's, since a terminal write
          -- clears the supervisor's own fields on some paths while a
          -- provider or other descendant identity can still be present in
          -- 'workerStateKnownProcesses'; only when nothing at all is
          -- recorded is there nothing left to re-verify.
          WorkerTerminal _ -> do
            let identities = catMaybes [state.workerStateWorkerIdentity, state.workerStateProviderIdentity] <> state.workerStateKnownProcesses
            if null identities
              then pure False
              else do
                presence <- checkIdentityPresenceWith defaultProcessSnapshot identities
                pure (presence /= IdentityAbsent)
          -- Every other status — including Orphaned — is judged by whether
          -- any durably recorded identity for this worker still matches a
          -- process, not by the status label alone: a blanket "Orphaned is
          -- always active" would block a same-issue relaunch forever once a
          -- confirmed-gone orphan's supervisor also died without writing a
          -- terminal state, and checking only the supervisor's identity for
          -- every other status would let a relaunch start alongside a live
          -- provider or other recorded descendant whose supervisor happened
          -- to already be gone.
          _ -> recordedIdentitiesActive state pendingTerminationPath
        Left _ -> do
          -- No state file has been written yet: fall back to the
          -- supervisor's identity recorded directly on the lease at launch.
          -- Unlike every other fallback in this function, there is no
          -- elapsed-time escape hatch here: elapsed time cannot distinguish
          -- a still-slow-but-alive supervisor from a dead one, and the
          -- one-live-worker invariant must hold even in the rare case where
          -- identity capture itself never succeeds — a lease that can never
          -- be proven dead stays active rather than risk a concurrent
          -- worker.
          presence <- supervisorLaunchIdentityPresenceWith defaultProcessSnapshot descriptor
          pure (presence /= Just IdentityAbsent)

-- | A lease stays active while any durably recorded identity for its
-- worker — the supervisor itself, its provider, or any other recorded
-- descendant — still matches a fresh process snapshot: the one-live-worker
-- invariant covers the whole recorded process tree, not merely the
-- supervisor, so a descendant surviving a dead supervisor (mid-orphan-wait,
-- or a supervisor that died without a terminal write) must still block a
-- same-issue relaunch.
recordedIdentitiesActive :: WorkerState -> FilePath -> IO Bool
recordedIdentitiesActive state pendingTerminationPath = case state.workerStateWorkerIdentity of
  -- An unverified identity (a pre-identity state file) must never authorize
  -- retiring a lease that might still be live: fail closed as active rather
  -- than risk a concurrent worker.
  Nothing -> pure True
  Just workerIdentity -> do
    let identities = workerIdentity : maybe [] (: []) state.workerStateProviderIdentity <> state.workerStateKnownProcesses
    presence <- checkIdentityPresenceWith defaultProcessSnapshot identities
    case presence of
      IdentityPresent -> pure True
      IdentitySnapshotFailed _ -> pure True
      IdentityAbsent -> do
        -- Every recorded identity is confirmed gone, but if the supervisor
        -- never got to signal a pending user termination (recorded only in
        -- this marker file, not the state it stopped updating), that
        -- termination's recorded descendants are still unverified: never
        -- retire the lease out from under them.
        doesFileExist pendingTerminationPath

leaseIsRecent :: WorkerDescriptor -> IO Bool
leaseIsRecent descriptor = do
  modified <- try @IOException (getModificationTime descriptor.workerDescriptorLeasePath)
  case modified of
    Left _ -> pure False
    Right modificationTime -> do
      now <- getCurrentTime
      pure (diffUTCTime now modificationTime < workerLeaseInitializationGraceSeconds)

retireStaleLease :: WorkerDescriptor -> IO (Either Text ())
retireStaleLease descriptor = do
  let retiredPath = descriptor.workerDescriptorLeasePath <> ".stale-" <> Text.unpack descriptor.workerDescriptorSpec.workerId.unWorkerId
  renamed <- try @IOException (renameDirectory descriptor.workerDescriptorLeasePath retiredPath)
  pure $ case renamed of
    Right () -> Right ()
    Left exception
      | isDoesNotExistError exception -> Right ()
      | otherwise -> Left ("could not retire stale worker lease: " <> Text.pack (show exception))

releaseWorkerLease :: WorkerDescriptor -> IO ()
releaseWorkerLease descriptor = do
  ownerResult <- decodeFile descriptor.workerDescriptorLeaseOwnerPath :: IO (Either Text WorkerLease)
  case ownerResult of
    Right owner
      | owner.workerLeaseId == descriptor.workerDescriptorSpec.workerId -> do
          ignoreFileOperation (removeFile descriptor.workerDescriptorLeaseOwnerPath)
          ignoreFileOperation (removeDirectory descriptor.workerDescriptorLeasePath)
    _ -> pure ()

workerLeaseConflictMessage :: WorkerTask -> Text
workerLeaseConflictMessage task = case task of
  SolveWorkerTaskKind solveTask -> "issue #" <> Text.pack (show solveTask.solveWorkerIssueNumber) <> " already has a live solve worker; open it from Processes or kill it before starting another"
  PullRequestWorkerTaskKind pullRequestTask -> "PR #" <> Text.pack (show pullRequestTask.pullRequestWorkerNumber) <> " already has a live worker; open it from Processes or kill it before starting another"

-- | Durably records the freshly spawned supervisor's identity onto the
-- lease this launch already holds, so a later recovery pass with no other
-- way to learn its PID — its own state file may never appear, e.g. a slow
-- or crashed start — can still tell a live supervisor from a dead one
-- instead of guessing from elapsed time alone. Best-effort and idempotent:
-- a snapshot or lookup failure just leaves the lease without an identity
-- for this attempt (the caller retries across the whole startup window
-- rather than giving up after one), and a lease that already carries an
-- identity is left untouched rather than rewritten on every poll.
recordLaunchedSupervisorIdentity :: WorkerDescriptor -> ProcessHandle -> IO ()
recordLaunchedSupervisorIdentity descriptor processHandle = do
  existing <- decodeFile descriptor.workerDescriptorLeaseOwnerPath :: IO (Either Text WorkerLease)
  case existing of
    Right lease
      | lease.workerLeaseId == descriptor.workerDescriptorSpec.workerId,
        Nothing <- lease.workerLeaseSupervisorIdentity -> do
          maybePid <- getPid processHandle
          case maybePid of
            Nothing -> pure ()
            Just pid -> do
              snapshotResult <- defaultProcessSnapshot
              case snapshotResult of
                Left _ -> pure ()
                Right snapshot -> case identityForPid (fromIntegral pid) snapshot of
                  Nothing -> pure ()
                  Just identity -> void (writePrivateJson descriptor.workerDescriptorLeaseOwnerPath lease {workerLeaseSupervisorIdentity = Just identity})
    _ -> pure ()

-- | Whether the freshly launched supervisor identity durably recorded on
-- this lease (see 'recordLaunchedSupervisorIdentity') still matches a
-- process, for recovery paths reached before any worker state file exists
-- to consult instead. 'Nothing' means no identity was ever recorded (a
-- legacy lease predating this field, or a launch whose best-effort
-- recording failed) rather than guessing from a signal that was never
-- captured, and both callers fail closed on it: 'leaseIsActive' treats the
-- lease as active and 'recoverIfWorkerStoppedWith' declines to recover.
-- Neither has a time-based fallback, so such a lease is deliberately
-- unacquirable for good — never merely time-limited. Elapsed time cannot
-- distinguish a still-slow-but-alive supervisor from a dead one, and the
-- one-live-worker invariant is held to even in the rare case where
-- identity capture itself never succeeded.
supervisorLaunchIdentityPresenceWith :: IO (Either Text [ProcessIdentity]) -> WorkerDescriptor -> IO (Maybe IdentityPresence)
supervisorLaunchIdentityPresenceWith takeSnapshot descriptor = do
  leaseResult <- decodeFile descriptor.workerDescriptorLeaseOwnerPath :: IO (Either Text WorkerLease)
  case leaseResult of
    Left _ -> pure Nothing
    Right lease -> case lease.workerLeaseSupervisorIdentity of
      Nothing -> pure Nothing
      Just identity -> Just <$> checkIdentityPresenceWith takeSnapshot [identity]

workerLeaseInitializationGraceSeconds :: NominalDiffTime
workerLeaseInitializationGraceSeconds = 10

workerLeaseAttempts :: Int
workerLeaseAttempts = 3
