-- | Finding a repository's workers in the cache and bounding what that cache
-- keeps: which durable specs belong to this repository, which of them a
-- restarting TUI may still attach to, and which retired leases and terminal
-- artifacts are provably safe to collect.
--
-- Collection fails closed for the same reasons lease recovery does — an
-- undecodable record, a spec this repository's history does not contain, a
-- snapshot that cannot be taken, or a single surviving identity all keep the
-- files — and is quiet throughout: a cache that cannot be tidied is a
-- hygiene problem, never a reason to fail the discovery a restart needs.
--
-- This module is internal — "Kanban.Worker" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Worker.Discovery
  ( discoverWorkers,
    discoverWorkerHistory,
    acknowledgeWorker,
    acknowledgeSupersededWorkers,
    collectWorkerCache,
    collectWorkerCacheWith,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (filterM, unless, void, when)
import qualified Data.ByteString as ByteString
import Data.Either (isRight)
import Data.List (find, sortOn)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (NominalDiffTime, diffUTCTime, getCurrentTime)
import Kanban.Domain (Repository (..))
import Kanban.Process (IdentityPresence (..), ProcessIdentity, checkIdentityPresenceWith, defaultProcessSnapshot)
import Kanban.Worker.Paths
  ( decodeFile,
    descriptorForSpec,
    ignoreFileOperation,
    listDirectoryOrEmpty,
    readWorkerState,
    safePathComponent,
    workerDirectory,
  )
import Kanban.Worker.Types
  ( PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerDescriptor (..),
    WorkerId (..),
    WorkerLease (..),
    WorkerParent (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    WorkerTask (..),
  )
import System.Directory (doesDirectoryExist, doesFileExist, removeDirectory, removeFile)
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (setFileMode)

discoverWorkers :: Repository -> IO [WorkerDescriptor]
discoverWorkers repository = do
  collectWorkerCache repository
  now <- getCurrentTime
  descriptors <- discoverWorkerHistory repository
  filterM (attachable now) descriptors
  where
    attachable now descriptor = do
      acknowledged <- doesFileExist descriptor.workerDescriptorAckPath
      stateResult <- readWorkerState descriptor
      pure $ case stateResult of
        Right state -> case state.workerStateStatus of
          WorkerStarting -> True
          WorkerRunning -> True
          WorkerOrphaned _ -> True
          WorkerTerminal _ -> not acknowledged
        Left _ -> not acknowledged && diffUTCTime now descriptor.workerDescriptorSpec.workerCreatedAt < workerDiscoveryStartupGraceSeconds

discoverWorkerHistory :: Repository -> IO [WorkerDescriptor]
discoverWorkerHistory repository = do
  directory <- workerDirectory repository
  entries <- listDirectoryOrEmpty directory
  descriptors <- mapM (descriptorFromName directory) [name | name <- entries, ".spec.json" `Text.isSuffixOf` Text.pack name]
  pure (sortOn (workerCreatedAt . (.workerDescriptorSpec)) (catMaybes descriptors))
  where
    descriptorFromName directory name = do
      decoded <- decodeFile (directory </> name)
      case decoded of
        Left _ -> pure Nothing
        Right spec
          | spec.workerRepository.repositoryRoot /= repository.repositoryRoot -> pure Nothing
          | otherwise -> do
              Just <$> descriptorForSpec spec

acknowledgeWorker :: WorkerDescriptor -> IO ()
acknowledgeWorker descriptor = do
  result <- try @IOException (ByteString.writeFile descriptor.workerDescriptorAckPath "handled\n")
  case result of
    Left _ -> pure ()
    Right () -> setFileMode descriptor.workerDescriptorAckPath 0o600

acknowledgeSupersededWorkers :: WorkerDescriptor -> IO ()
acknowledgeSupersededWorkers current = do
  history <- discoverWorkerHistory current.workerDescriptorSpec.workerRepository
  mapM_ acknowledgeWorker (filter superseded history)
  where
    currentSpec = current.workerDescriptorSpec
    superseded candidate =
      candidate.workerDescriptorSpec.workerId /= currentSpec.workerId
        && candidate.workerDescriptorSpec.workerCreatedAt <= currentSpec.workerCreatedAt
        && taskSupersedes currentSpec candidate.workerDescriptorSpec

taskSupersedes :: WorkerSpec -> WorkerSpec -> Bool
taskSupersedes current previous = case current.workerTask of
  SolveWorkerTaskKind task -> case previous.workerTask of
    SolveWorkerTaskKind oldTask -> oldTask.solveWorkerIssueNumber == task.solveWorkerIssueNumber
    PullRequestWorkerTaskKind _ -> False
  PullRequestWorkerTaskKind task -> case previous.workerTask of
    PullRequestWorkerTaskKind oldTask -> oldTask.pullRequestWorkerNumber == task.pullRequestWorkerNumber
    SolveWorkerTaskKind oldTask ->
      maybe False ((== oldTask.solveWorkerIssueNumber) . (.workerParentIssueNumber)) current.workerParent

-- | Bounds the per-repository worker cache, run from 'discoverWorkers' at
-- startup rather than on a schedule of its own: the one moment the whole
-- directory is already being scanned and decoded anyway.
--
-- Two things grew without limit before this. 'retireStaleLease' renames a
-- lease directory it has proven dead to @\<lease\>.stale-\<workerId\>@ and
-- nothing ever removed the result, so every recovered-from-crash launch left
-- one behind for good. And a finished worker's spec, state, journal, and ack
-- marker were never removed either, so 'discoverWorkerHistory' rescanned a
-- directory that gained a full agent transcript for every solve or review
-- ever run.
--
-- Quiet and non-fatal throughout: a cache that cannot be tidied is a hygiene
-- problem, never a reason to fail the discovery a restarting TUI needs to
-- reattach to live work, so every failure leaves the candidate in place for
-- the next pass and discovery proceeds regardless.
collectWorkerCache :: Repository -> IO ()
collectWorkerCache = collectWorkerCacheWith defaultProcessSnapshot

collectWorkerCacheWith :: IO (Either Text [ProcessIdentity]) -> Repository -> IO ()
collectWorkerCacheWith takeSnapshot repository = ignoreFileOperation $ do
  directory <- workerDirectory repository
  exists <- doesDirectoryExist directory
  when exists $ do
    -- 'discoverWorkerHistory' is the only thing that decodes a spec and
    -- proves it belongs to this repository, so it is the sole authority both
    -- passes below use to decide what is theirs to remove. Taken once and
    -- shared, since the terminal pass needs the whole list anyway.
    history <- discoverWorkerHistory repository
    collectRetiredLeases takeSnapshot directory history
    collectTerminalArtifacts takeSnapshot directory history

-- | Removes retired @.stale-*@ lease directories whose recorded processes are
-- all provably gone.
--
-- Fails closed exactly as lease recovery itself does ('leaseIsActive' and
-- 'recordedIdentitiesActive'): an owner record that will not decode, an owner
-- this repository's history does not contain, a state file that will not
-- decode, a snapshot that cannot be taken, a single surviving identity, or an
-- unresolved pending termination all keep the directory. Only a retired lease
-- whose every recorded identity is confirmed absent is collected.
collectRetiredLeases :: IO (Either Text [ProcessIdentity]) -> FilePath -> [WorkerDescriptor] -> IO ()
collectRetiredLeases takeSnapshot directory history = do
  entries <- listDirectoryOrEmpty directory
  mapM_ collect (filter isRetiredLeaseName entries)
  where
    isRetiredLeaseName name = safePathComponent name && ".lease.stale-" `Text.isInfixOf` Text.pack name
    collect name = ignoreFileOperation $ do
      let leasePath = directory </> name
      isDirectory <- doesDirectoryExist leasePath
      when isDirectory $ do
        retained <- retiredLeaseRetained takeSnapshot directory history leasePath
        unless retained $ do
          -- The owner record is the only file a lease directory ever holds.
          -- Removing it and then the directory itself — rather than a
          -- recursive delete — means anything unexpected inside leaves the
          -- 'removeDirectory' failing harmlessly and the directory intact.
          ignoreFileOperation (removeFile (leasePath </> "owner.json"))
          ignoreFileOperation (removeDirectory leasePath)

retiredLeaseRetained :: IO (Either Text [ProcessIdentity]) -> FilePath -> [WorkerDescriptor] -> FilePath -> IO Bool
retiredLeaseRetained takeSnapshot directory history leasePath = do
  ownerResult <- decodeFile (leasePath </> "owner.json") :: IO (Either Text WorkerLease)
  case ownerResult of
    Left _ -> pure True
    Right lease -> case find ((== lease.workerLeaseId) . (.workerId) . (.workerDescriptorSpec)) history of
      -- The retired lease names a worker whose spec this repository's history
      -- does not contain, so nothing here proves the record is ours. A worker
      -- directory is keyed by 'safeKey' over @owner-name@, and that mapping
      -- collides — @a-b/c@ and @a/b-c@ both key to @a-b-c@ — so a shared
      -- directory can just as easily hold another repository's retired lease,
      -- which is never ours to remove. Keep it and let its own repository's
      -- pass decide.
      Nothing -> pure True
      Just descriptor
        | not (artifactsWithin directory descriptor) -> pure True
        | otherwise -> do
            recorded <- recordedStateIdentities descriptor.workerDescriptorStatePath
            pending <- doesFileExist descriptor.workerDescriptorPendingTerminationPath
            case recorded of
              Nothing -> pure True
              Just identities -> do
                let candidates = maybe [] (: []) lease.workerLeaseSupervisorIdentity <> identities
                if pending || null candidates
                  then pure True
                  else do
                    presence <- checkIdentityPresenceWith takeSnapshot candidates
                    pure (presence /= IdentityAbsent)

-- | Every process identity a worker durably recorded, or 'Nothing' when a
-- state file is present but will not decode — the case that cannot be
-- verified, and so must not authorize a deletion.
recordedStateIdentities :: FilePath -> IO (Maybe [ProcessIdentity])
recordedStateIdentities statePath = do
  exists <- doesFileExist statePath
  if not exists
    then pure (Just [])
    else do
      stateResult <- decodeFile statePath :: IO (Either Text WorkerState)
      pure (either (const Nothing) (Just . recordedIdentities) stateResult)

recordedIdentities :: WorkerState -> [ProcessIdentity]
recordedIdentities state =
  catMaybes [state.workerStateWorkerIdentity, state.workerStateProviderIdentity] <> state.workerStateKnownProcesses

-- | Removes the durable artifacts of terminal workers past their retention.
--
-- Milestone 8 keeps a terminal journal discoverable "until a newer worker is
-- durable proof that their workflow step was superseded", so inside the
-- window a worker is collectable only once it has been acknowledged /and/ a
-- newer durable worker has taken over its workflow step; the newest terminal
-- worker for an item, which is the session the debugging contract promises,
-- survives however many passes run. Past 'workerRetentionSeconds' that
-- promise has expired and the rest is collected regardless.
collectTerminalArtifacts :: IO (Either Text [ProcessIdentity]) -> FilePath -> [WorkerDescriptor] -> IO ()
collectTerminalArtifacts takeSnapshot directory history = do
  now <- getCurrentTime
  candidates <- catMaybes <$> mapM withTerminalState history
  mapM_ (collect now) candidates
  where
    withTerminalState descriptor = do
      stateResult <- readWorkerState descriptor
      pure $ case stateResult of
        Right state
          | WorkerTerminal _ <- state.workerStateStatus -> Just (descriptor, state)
        _ -> Nothing
    collect now (descriptor, state) = ignoreFileOperation $ do
      -- Measured from the terminal heartbeat rather than 'workerCreatedAt':
      -- retention starts when a worker finished, and a long-running solve's
      -- launch time says nothing about how long its result has been sitting
      -- in the cache.
      let expired = diffUTCTime now state.workerStateHeartbeatAt >= workerRetentionSeconds
      eligible <-
        if expired
          then pure True
          else do
            acknowledged <- doesFileExist descriptor.workerDescriptorAckPath
            if acknowledged then supersededByDurableWorker history descriptor else pure False
      when eligible $ do
        collectable <- artifactsCollectable takeSnapshot directory descriptor state
        when collectable (removeWorkerArtifacts descriptor)

-- | Whether a newer worker is durable proof that this one's workflow step was
-- superseded: a same-repository spec discovery already decoded, ordered after
-- the candidate, matching it under 'taskSupersedes' — same-issue solves, same-PR
-- workers, and a PR worker whose parent is the candidate's issue — and backed
-- by durable state of its own rather than a spec file alone.
supersededByDurableWorker :: [WorkerDescriptor] -> WorkerDescriptor -> IO Bool
supersededByDurableWorker history descriptor = or <$> mapM durable (filter newer history)
  where
    spec = descriptor.workerDescriptorSpec
    newer candidate =
      candidateSpec.workerRepository.repositoryRoot == spec.workerRepository.repositoryRoot
        && (candidateSpec.workerCreatedAt, candidateSpec.workerId) > (spec.workerCreatedAt, spec.workerId)
        && taskSupersedes candidateSpec spec
      where
        candidateSpec = candidate.workerDescriptorSpec
    durable candidate = isRight <$> (readWorkerState candidate :: IO (Either Text WorkerState))

-- | The safety gates every collection clears before a single file is removed.
--
-- Terminal status alone is not enough — lease recovery deliberately
-- re-verifies recorded identities before releasing a terminal lease
-- ('leaseIsActive'), and the same doubt applies here. A worker still owning
-- its item's lease, or with any recorded identity a snapshot still matches,
-- keeps its artifacts; so does a snapshot that cannot be taken at all. Only a
-- worker whose serialized id is a plain component of the scanned directory is
-- collectable, so a spec file carrying a crafted id can never aim a deletion
-- outside the repository's own cache.
artifactsCollectable :: IO (Either Text [ProcessIdentity]) -> FilePath -> WorkerDescriptor -> WorkerState -> IO Bool
artifactsCollectable takeSnapshot directory descriptor state
  | not (artifactsWithin directory descriptor) = pure False
  | otherwise = do
      leased <- ownsLease descriptor
      if leased
        then pure False
        else case recordedIdentities state of
          -- Nothing was ever recorded, so there is nothing left to
          -- re-verify — the same reading 'leaseIsActive' takes of a terminal
          -- worker with no recorded identities.
          [] -> pure True
          identities -> (== IdentityAbsent) <$> checkIdentityPresenceWith takeSnapshot identities

-- | Whether this worker still holds its item's live lease. An owner record
-- that will not decode counts as held: an existing lease directory that
-- cannot be attributed must not have artifacts collected out from under it.
ownsLease :: WorkerDescriptor -> IO Bool
ownsLease descriptor = do
  leased <- doesDirectoryExist descriptor.workerDescriptorLeasePath
  if not leased
    then pure False
    else do
      ownerResult <- decodeFile descriptor.workerDescriptorLeaseOwnerPath :: IO (Either Text WorkerLease)
      pure $ case ownerResult of
        Right owner -> owner.workerLeaseId == descriptor.workerDescriptorSpec.workerId
        Left _ -> True

artifactsWithin :: FilePath -> WorkerDescriptor -> Bool
artifactsWithin directory descriptor =
  safePathComponent (Text.unpack descriptor.workerDescriptorSpec.workerId.unWorkerId)
    && all ((== directory) . takeDirectory) (workerArtifactPaths descriptor)

-- | Every durable file a worker owns. The lease paths are deliberately
-- absent: they belong to the item, not to this worker.
workerArtifactPaths :: WorkerDescriptor -> [FilePath]
workerArtifactPaths descriptor = descriptor.workerDescriptorSpecPath : companionArtifactPaths descriptor

-- | Everything except the @.spec.json@ discovery anchor.
companionArtifactPaths :: WorkerDescriptor -> [FilePath]
companionArtifactPaths descriptor =
  [ descriptor.workerDescriptorEventPath,
    descriptor.workerDescriptorStatePath,
    descriptor.workerDescriptorAckPath,
    descriptor.workerDescriptorPendingTerminationPath
  ]

-- | Removes a collected worker's files, the @.spec.json@ anchor last on
-- purpose. 'discoverWorkerHistory' reaches a worker only through that file, so
-- holding it back until every companion is gone leaves a removal that failed
-- partway fully discoverable and retryable on the next pass, rather than
-- stranding files no scan will ever find again.
removeWorkerArtifacts :: WorkerDescriptor -> IO ()
removeWorkerArtifacts descriptor = do
  cleared <- and <$> mapM removeArtifact (companionArtifactPaths descriptor)
  when cleared (void (removeArtifact descriptor.workerDescriptorSpecPath))

-- | Whether the artifact is gone afterwards. An already-absent file is a
-- success — most collected workers never wrote a pending-termination marker —
-- while a real failure reports itself so the anchor is left behind and the
-- whole set is retried later.
removeArtifact :: FilePath -> IO Bool
removeArtifact path = do
  removed <- try @IOException (removeFile path)
  pure (either isDoesNotExistError (const True) removed)

workerDiscoveryStartupGraceSeconds :: NominalDiffTime
workerDiscoveryStartupGraceSeconds = 30

-- | How long a terminal worker's durable artifacts survive once nothing else
-- has superseded them. Long enough that the latest failed session for an item
-- is still there to debug days later, short enough that a cache nobody prunes
-- by hand stops growing without bound.
workerRetentionSeconds :: NominalDiffTime
workerRetentionSeconds = 14 * 24 * 60 * 60
