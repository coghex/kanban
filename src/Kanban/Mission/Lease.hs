-- | The one-advancing-process invariant: the lease a caller must win before it
-- may advance a mission, and the identity-verified rule deciding whether an
-- existing lease is still held.
--
-- The mechanism is a directory won with @createDirectory@, as
-- "Kanban.Worker.Lease"'s is, and deliberately not "Kanban.Repository.Lease"'s
-- POSIX record lock. A record lock belongs to the /process/, so a second
-- request from inside a process that already holds one succeeds by replacing
-- the first — which is exactly wrong here, where a dashboard and a background
-- runner inside one process must contend as honestly as two processes do.
--
-- This lease is stricter than the worker lease in one respect, and the
-- difference is the point rather than an oversight.
-- @Kanban.Worker.Lease.leaseIsActive@ treats an undecodable owner record as
-- active only for an initialization grace period, after which it may retire
-- the lease; a mission lease has no such window. A holder that cannot be
-- /proven/ gone keeps the lease for good: an unreadable record, an owner
-- record this release cannot decode, and a liveness probe that could not
-- answer all leave the lease held. Elapsed time cannot distinguish a slow
-- holder from a dead one, and a mission advanced twice is not a second worker
-- on one issue — it is two runs spending an agent budget against one plan and
-- writing over each other's snapshot.
--
-- Liveness is asked of the kernel with @kill(pid, 0)@ and never of a process
-- snapshot. Reading a snapshot means running @ps@, and requirement 15 of issue
-- #592 is that this slice spawns no process at all — the same restriction the
-- hand-written SHA-256 in "Kanban.Mission.Digest" exists to respect. What that
-- costs is the start time "Kanban.Process" pins an identifier with, and the
-- loss lands entirely on the safe side: with no start time a /recycled/
-- identifier is indistinguishable from the original, so it reads as present
-- and the lease stays held. Only @ESRCH@ — the kernel saying no process has
-- this identifier — is ever read as gone, and there is no way for that answer
-- to be wrong.
--
-- This lease replaces nothing. The per-target worker lease and the canonical
-- approval lock remain the lower-level authorities over what they guard; this
-- one only says who may move a mission forward.
--
-- This module is internal — "Kanban.Mission" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Mission.Lease
  ( MissionLease (..),
    MissionLeaseAcquisition (..),
    MissionHolderPresence (..),
    acquireMissionLease,
    acquireMissionLeaseWith,
    missionHolderPresence,
    releaseMissionLease,
    readMissionLeaseOwner,
  )
where

import Control.Exception (IOException, try)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (getCurrentTime)
import Kanban.Mission.Paths
  ( MissionRead (..),
    MissionStore (..),
    ensureMissionDirectory,
    ignoreFileOperation,
    missionDirectory,
    missionLeaseOwnerPath,
    missionLeasePath,
    readMissionRecordFor,
    writeMissionRecord,
  )
import Kanban.Mission.Types
  ( MissionId (..),
    MissionLeaseOwner (..),
    MissionRepository,
    missionLeaseSchemaVersion,
  )
import System.Directory (createDirectory, removeDirectory, removeFile)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Files (setFileMode)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (nullSignal, signalProcess)
import System.Posix.Types (CPid)

-- | A held mission lease. Carries the token its owner record was written with,
-- so a release can refuse to remove a lease some later acquisition now holds.
data MissionLease = MissionLease
  { missionLeaseMission :: MissionId,
    missionLeaseRepository :: MissionRepository,
    missionLeaseDirectory :: FilePath,
    missionLeaseOwnerFile :: FilePath,
    missionLeaseToken :: Text
  }
  deriving stock (Eq, Show)

-- | What one attempt was told. Three answers rather than two, because \"someone
-- else has it\" and \"this store will not hold a lease at all\" call for
-- different responses: the first is waited out, the second is reported.
data MissionLeaseAcquisition
  = MissionLeaseAcquired MissionLease
  | MissionLeaseHeld Text
  | MissionLeaseUnusable Text
  deriving stock (Eq, Show)

-- | What is known about the process a lease record names.
data MissionHolderPresence
  = MissionHolderPresent
  | -- | The kernel says no process has this identifier. The one answer that
    -- lets a lease be retired, and the one that cannot be wrong.
    MissionHolderGone
  | MissionHolderUndecidable Text
  deriving stock (Eq, Show)

-- | Whether a process identifier still names a running process.
--
-- @kill(pid, 0)@ delivers nothing; it asks the kernel whether the identifier
-- resolves and whether this process could signal it. @ESRCH@ is the only
-- outcome read as gone. A permission error means a process /is/ there under
-- another user, and every other error means the question was not answered —
-- both keep the lease.
--
-- The identifier is range-checked before the call rather than passed to it. To
-- @kill@, zero and negative values name a process group or every process the
-- caller may signal, and a value too large for a @pid_t@ /becomes/ one of
-- those when it is narrowed — the largest 'Int' arrives as @-1@, which is
-- every process. A record is durable data that can be corrupted or edited, so
-- a liveness question must not be able to turn into one about an unrelated
-- group. Anything outside the range is undecidable, which keeps the lease.
missionHolderPresence :: Int -> IO MissionHolderPresence
missionHolderPresence processId
  | processId <= 0 || processId > fromIntegral (maxBound :: CPid) =
      pure
        ( MissionHolderUndecidable
            ("its recorded process identifier " <> Text.pack (show processId) <> " is not a process identifier")
        )
  | otherwise = do
      probed <- try @IOException (signalProcess nullSignal (fromIntegral processId))
      pure $ case probed of
        Right () -> MissionHolderPresent
        Left exception
          | isDoesNotExistError exception -> MissionHolderGone
          | otherwise -> MissionHolderUndecidable (Text.pack (show exception))

acquireMissionLease :: MissionStore -> MissionId -> IO MissionLeaseAcquisition
acquireMissionLease = acquireMissionLeaseWith missionHolderPresence

-- | 'acquireMissionLease' with the liveness probe injected, so a fixture can
-- stage a probe that cannot answer and prove the lease stays held.
acquireMissionLeaseWith :: (Int -> IO MissionHolderPresence) -> MissionStore -> MissionId -> IO MissionLeaseAcquisition
acquireMissionLeaseWith holderPresence store mission = case (,) <$> missionLeasePath store.missionStoreDirectory mission <*> missionLeaseOwnerPath store.missionStoreDirectory mission of
  Left message -> pure (MissionLeaseUnusable message)
  Right (leaseDirectory, ownerPath) -> case missionDirectory store.missionStoreDirectory mission of
    Left message -> pure (MissionLeaseUnusable message)
    Right directory -> do
      prepared <- ensureMissionDirectory directory
      case prepared of
        Left message -> pure (MissionLeaseUnusable ("could not prepare the mission directory: " <> message))
        Right () -> attempt leaseDirectory ownerPath True
  where
    attempt leaseDirectory ownerPath mayRetire = do
      created <- try @IOException (createDirectory leaseDirectory)
      case created of
        Right () -> do
          ignoreFileOperation (setFileMode leaseDirectory 0o700)
          token <- newLeaseToken
          now <- getCurrentTime
          processId <- getProcessID
          written <-
            writeMissionRecord
              ownerPath
              missionLeaseSchemaVersion
              MissionLeaseOwner
                { missionLeaseOwnerMission = mission,
                  missionLeaseOwnerRepository = store.missionStoreRepository,
                  missionLeaseOwnerToken = token,
                  missionLeaseOwnerAcquiredAt = now,
                  missionLeaseOwnerProcessId = fromIntegral processId
                }
          case written of
            Left message -> do
              -- The lease was won but never recorded, so nothing could ever
              -- prove its holder gone. Giving the directory back is the only
              -- move that does not strand the mission for good.
              ignoreFileOperation (removeDirectory leaseDirectory)
              pure (MissionLeaseUnusable ("could not record the mission lease owner: " <> message))
            Right () ->
              pure
                ( MissionLeaseAcquired
                    MissionLease
                      { missionLeaseMission = mission,
                        missionLeaseRepository = store.missionStoreRepository,
                        missionLeaseDirectory = leaseDirectory,
                        missionLeaseOwnerFile = ownerPath,
                        missionLeaseToken = token
                      }
                )
        Left exception
          | not (isAlreadyExistsError exception) ->
              pure (MissionLeaseUnusable ("could not acquire the mission lease: " <> Text.pack (show exception)))
          | otherwise -> do
              held <- holderStillHeld holderPresence store mission ownerPath
              case held of
                Just reason -> pure (MissionLeaseHeld reason)
                Nothing
                  | not mayRetire ->
                      pure (MissionLeaseHeld ("mission " <> mission.unMissionId <> " lease was reacquired while it was being retired"))
                  | otherwise -> do
                      ignoreFileOperation (removeFile ownerPath)
                      ignoreFileOperation (removeDirectory leaseDirectory)
                      attempt leaseDirectory ownerPath False

-- | Whether an existing lease is still held, and why.
--
-- 'Nothing' — the only answer that lets a lease be retired — is returned in
-- exactly one case: the owner record decoded, and the kernel says no process
-- has the identifier it names. Every other outcome keeps the lease,
-- permanently.
holderStillHeld :: (Int -> IO MissionHolderPresence) -> MissionStore -> MissionId -> FilePath -> IO (Maybe Text)
holderStillHeld holderPresence store mission ownerPath = do
  ownerResult <-
    readMissionRecordFor
      mission
      [missionLeaseSchemaVersion]
      store.missionStoreRepository
      missionLeaseOwnerMission
      missionLeaseOwnerRepository
      ownerPath ::
      IO (MissionRead MissionLeaseOwner)
  case ownerResult of
    -- An owner record that is missing, unreadable, or written under a schema
    -- version this release does not know is a holder whose absence cannot be
    -- proven. §16's silence rule governs what a reader *displays*; it never
    -- authorises taking a lock away from a holder that may still be running.
    MissionAbsent -> pure (Just (blocked "its owner record is missing or was written by another release"))
    MissionUnreadable message -> pure (Just (blocked ("its owner record will not decode (" <> message <> ")")))
    -- An owner record that belongs to another mission or another repository
    -- is not this lease's holder, so the process it names says nothing about
    -- whether this mission is being advanced. A store restored from a backup
    -- or a directory copied by hand is enough to put one here, and retiring on
    -- its evidence would hand the lease out while the real holder — about whom
    -- nothing is recorded — is still running.
    MissionRefused message -> pure (Just (blocked ("its owner record was refused (" <> message <> ")")))
    MissionPresent owner -> do
      presence <- holderPresence owner.missionLeaseOwnerProcessId
      pure $ case presence of
        MissionHolderPresent -> Just (blocked "its holder is still running")
        MissionHolderUndecidable detail -> Just (blocked ("its holder could not be checked (" <> detail <> ")"))
        MissionHolderGone -> Nothing
  where
    blocked reason = "mission " <> mission.unMissionId <> " is already being advanced: " <> reason

-- | Gives a lease up, and only this lease.
--
-- The owner record is re-read and its token compared first, so a release that
-- arrives after this lease was retired and reacquired removes the successor's
-- lease rather than its own.
releaseMissionLease :: MissionLease -> IO ()
releaseMissionLease lease = do
  ownerResult <-
    readMissionRecordFor
      lease.missionLeaseMission
      [missionLeaseSchemaVersion]
      lease.missionLeaseRepository
      missionLeaseOwnerMission
      missionLeaseOwnerRepository
      lease.missionLeaseOwnerFile ::
      IO (MissionRead MissionLeaseOwner)
  case ownerResult of
    MissionPresent owner
      | owner.missionLeaseOwnerToken == lease.missionLeaseToken -> do
          ignoreFileOperation (removeFile lease.missionLeaseOwnerFile)
          ignoreFileOperation (removeDirectory lease.missionLeaseDirectory)
    _ -> pure ()

-- | The owner record of whatever holds a mission's lease, for a caller that
-- wants to say who rather than to take it.
readMissionLeaseOwner :: MissionStore -> MissionId -> IO (MissionRead MissionLeaseOwner)
readMissionLeaseOwner store mission = case missionLeaseOwnerPath store.missionStoreDirectory mission of
  Left message -> pure (MissionUnreadable message)
  Right ownerPath ->
    readMissionRecordFor
      mission
      [missionLeaseSchemaVersion]
      store.missionStoreRepository
      missionLeaseOwnerMission
      missionLeaseOwnerRepository
      ownerPath

newLeaseToken :: IO Text
newLeaseToken = do
  now <- getCurrentTime
  processId <- getProcessID
  pure (Text.filter (`notElem` ("-:. TZ" :: String)) (Text.pack (show now)) <> "-" <> Text.pack (show processId))
