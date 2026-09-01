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

import Control.Concurrent.MVar (MVar, newMVar, tryTakeMVar)
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
import System.Directory (createDirectory, removeDirectoryRecursive, renameDirectory)
import System.FilePath ((</>))
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
    missionLeaseToken :: Text,
    -- | Full until this acquisition has been released, and taken by the
    -- release that runs. One acquisition is released once however many times
    -- 'releaseMissionLease' is called on it and from however many threads,
    -- which is what stops two releases of one value from racing each other
    -- across the gap between checking the owner and removing it.
    --
    -- In-process is the whole of what is needed: this value is a handle
    -- rather than a record, it never crosses a process boundary, and two
    -- processes therefore cannot hold the same acquisition to release twice.
    missionLeaseRelease :: MVar ()
  }

-- | Compared and shown by what identifies the acquisition. The release claim
-- is this value's own state rather than part of which lease it is, and an
-- 'MVar' has no useful comparison or rendering.
instance Eq MissionLease where
  left == right =
    left.missionLeaseMission == right.missionLeaseMission
      && left.missionLeaseRepository == right.missionLeaseRepository
      && left.missionLeaseDirectory == right.missionLeaseDirectory
      && left.missionLeaseOwnerFile == right.missionLeaseOwnerFile
      && left.missionLeaseToken == right.missionLeaseToken

instance Show MissionLease where
  show lease =
    "MissionLease {missionLeaseMission = "
      <> show lease.missionLeaseMission
      <> ", missionLeaseDirectory = "
      <> show lease.missionLeaseDirectory
      <> ", missionLeaseToken = "
      <> show lease.missionLeaseToken
      <> "}"

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
          releaseClaim <- newMVar ()
          case written of
            Left message -> do
              -- The lease was won but never recorded, so nothing could ever
              -- prove its holder gone. Giving the directory back is the only
              -- move that does not strand the mission for good, and it is
              -- given back whatever a failed write left inside it: an rmdir
              -- that refused because the directory was not empty would leave
              -- exactly the ownerless lease this is undoing.
              ignoreFileOperation (removeDirectoryRecursive leaseDirectory)
              pure (MissionLeaseUnusable ("could not record the mission lease owner: " <> message))
            Right () ->
              pure
                ( MissionLeaseAcquired
                    MissionLease
                      { missionLeaseMission = mission,
                        missionLeaseRepository = store.missionStoreRepository,
                        missionLeaseDirectory = leaseDirectory,
                        missionLeaseOwnerFile = ownerPath,
                        missionLeaseToken = token,
                        missionLeaseRelease = releaseClaim
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
                      -- One atomic move rather than an unlink and an rmdir,
                      -- for the reason 'releaseMissionLease' takes the whole
                      -- directory: between the two steps the lease stands
                      -- with no owner record, which reads as a holder that
                      -- cannot be proven gone — a mission nothing could
                      -- acquire again — and a directory holding anything
                      -- unexpected would leave it in that state for good. A
                      -- move that loses to another retirer is not an error;
                      -- the retry below settles which of them acquires.
                      retiring <- newLeaseToken
                      let retiredPath = leaseDirectory <> ".retired-" <> Text.unpack retiring
                      moved <- try @IOException (renameDirectory leaseDirectory retiredPath)
                      case moved of
                        Left _ -> pure ()
                        Right () -> ignoreFileOperation (removeDirectoryRecursive retiredPath)
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
-- Three things together, because the obvious two are not enough.
--
-- The release of one acquisition happens once. 'missionLeaseRelease' is taken
-- by whichever call gets there, and every other call on that value returns
-- having done nothing. Without it, two releases of one handle can both read a
-- matching owner record, and the second can resume long enough after the first
-- for a successor to have acquired — at which point it would delete the
-- successor's lease while the successor still believed it held one.
--
-- The lease then goes away in a single atomic step. A rename takes the whole
-- directory, owner record and all, so no observer sees a lease directory
-- standing with its owner record already gone — a state that reads as a holder
-- who cannot be proven gone, which is to say a mission nothing can ever
-- acquire again. It is also why an unexpected extra file inside the lease
-- directory cannot strand the mission: the move does not care what is in
-- there, where an unlink-then-rmdir would fail and leave the ruin behind.
--
-- And what was taken is checked again before it is destroyed. The token is
-- compared before the rename, so in the ordinary case this only confirms what
-- is already known; if it ever does disagree, the directory belonged to a
-- successor and is put straight back rather than removed.
releaseMissionLease :: MissionLease -> IO ()
releaseMissionLease lease = do
  claimed <- tryTakeMVar lease.missionLeaseRelease
  case claimed of
    Nothing -> pure ()
    Just () -> do
      ownerResult <- readOwner lease.missionLeaseOwnerFile
      case ownerResult of
        MissionPresent owner
          | owner.missionLeaseOwnerToken == lease.missionLeaseToken -> takeAside
        _ -> pure ()
  where
    -- Named for the acquisition rather than the mission, so two acquisitions
    -- can never contend for one aside directory and a leftover from a release
    -- that was interrupted cannot block a later one.
    asidePath = lease.missionLeaseDirectory <> ".released-" <> Text.unpack lease.missionLeaseToken

    readOwner path =
      readMissionRecordFor
        lease.missionLeaseMission
        [missionLeaseSchemaVersion]
        lease.missionLeaseRepository
        missionLeaseOwnerMission
        missionLeaseOwnerRepository
        path ::
        IO (MissionRead MissionLeaseOwner)

    takeAside = do
      moved <- try @IOException (renameDirectory lease.missionLeaseDirectory asidePath)
      case moved of
        -- Nothing of this acquisition's is there to remove.
        Left _ -> pure ()
        Right () -> do
          confirmed <- readOwner (asidePath </> "owner.json")
          case confirmed of
            MissionPresent owner
              | owner.missionLeaseOwnerToken == lease.missionLeaseToken ->
                  ignoreFileOperation (removeDirectoryRecursive asidePath)
            -- Unreachable while the claim above holds, and a restore rather
            -- than a removal if it ever is reached. A restore that cannot
            -- land — because something has already taken the freed name —
            -- leaves an inert directory behind rather than destroying a lease
            -- that is now somebody else's.
            _ -> ignoreFileOperation (renameDirectory asidePath lease.missionLeaseDirectory)

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
