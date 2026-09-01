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
-- /proven/ gone keeps the lease for good: an unreadable record, a record with
-- no captured identity, and a process snapshot that would not run all leave
-- the lease held. Elapsed time cannot distinguish a slow holder from a dead
-- one, and a mission advanced twice is not a second worker on one issue — it
-- is two runs spending an agent budget against one plan and writing over each
-- other's snapshot.
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
    acquireMissionLease,
    acquireMissionLeaseWith,
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
    ensureMissionDirectory,
    ignoreFileOperation,
    missionDirectory,
    missionLeaseOwnerPath,
    missionLeasePath,
    readMissionRecord,
    writeMissionRecord,
  )
import Kanban.Mission.Types
  ( MissionId (..),
    MissionLeaseOwner (..),
    missionLeaseSchemaVersion,
  )
import Kanban.Process
  ( IdentityPresence (..),
    ProcessIdentity,
    checkIdentityPresenceWith,
    currentProcessIdentity,
    defaultProcessSnapshot,
  )
import System.Directory (createDirectory, removeDirectory, removeFile)
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Files (setFileMode)
import System.Posix.Process (getProcessID)

-- | A held mission lease. Carries the token its owner record was written with,
-- so a release can refuse to remove a lease some later acquisition now holds.
data MissionLease = MissionLease
  { missionLeaseMission :: MissionId,
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

acquireMissionLease :: FilePath -> MissionId -> IO MissionLeaseAcquisition
acquireMissionLease = acquireMissionLeaseWith defaultProcessSnapshot

-- | 'acquireMissionLease' with the process snapshot injected, so a fixture can
-- stage a snapshot that will not run and prove the lease stays held.
acquireMissionLeaseWith :: IO (Either Text [ProcessIdentity]) -> FilePath -> MissionId -> IO MissionLeaseAcquisition
acquireMissionLeaseWith takeSnapshot store mission = case (,) <$> missionLeasePath store mission <*> missionLeaseOwnerPath store mission of
  Left message -> pure (MissionLeaseUnusable message)
  Right (leaseDirectory, ownerPath) -> case missionDirectory store mission of
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
          identity <- capturedIdentity
          written <-
            writeMissionRecord
              ownerPath
              missionLeaseSchemaVersion
              MissionLeaseOwner
                { missionLeaseOwnerMission = mission,
                  missionLeaseOwnerToken = token,
                  missionLeaseOwnerAcquiredAt = now,
                  missionLeaseOwnerIdentity = identity
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
                        missionLeaseDirectory = leaseDirectory,
                        missionLeaseOwnerFile = ownerPath,
                        missionLeaseToken = token
                      }
                )
        Left exception
          | not (isAlreadyExistsError exception) ->
              pure (MissionLeaseUnusable ("could not acquire the mission lease: " <> Text.pack (show exception)))
          | otherwise -> do
              held <- holderStillHeld takeSnapshot mission ownerPath
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
-- exactly one case: the owner record decoded, it names a captured identity,
-- and a snapshot that /ran/ found nothing matching it. Every other outcome
-- keeps the lease, permanently.
holderStillHeld :: IO (Either Text [ProcessIdentity]) -> MissionId -> FilePath -> IO (Maybe Text)
holderStillHeld takeSnapshot mission ownerPath = do
  ownerResult <- readMissionRecord mission [missionLeaseSchemaVersion] ownerPath :: IO (MissionRead MissionLeaseOwner)
  case ownerResult of
    -- An owner record that is missing, unreadable, or written under a schema
    -- version this release does not know is a holder whose absence cannot be
    -- proven. §16's silence rule governs what a reader *displays*; it never
    -- authorises taking a lock away from a holder that may still be running.
    MissionAbsent -> pure (Just (blocked "its owner record is missing or was written by another release"))
    MissionUnreadable message -> pure (Just (blocked ("its owner record will not decode (" <> message <> ")")))
    MissionRefused message -> pure (Just (blocked ("its owner record was refused (" <> message <> ")")))
    MissionPresent owner -> case owner.missionLeaseOwnerIdentity of
      Nothing -> pure (Just (blocked "its holder's process identity was never captured, so its absence can never be proven"))
      Just identity -> do
        presence <- checkIdentityPresenceWith takeSnapshot [identity]
        pure $ case presence of
          IdentityPresent -> Just (blocked "its holder is still running")
          IdentitySnapshotFailed detail -> Just (blocked ("its holder could not be checked (" <> detail <> ")"))
          IdentityAbsent -> Nothing
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
    readMissionRecord lease.missionLeaseMission [missionLeaseSchemaVersion] lease.missionLeaseOwnerFile
      :: IO (MissionRead MissionLeaseOwner)
  case ownerResult of
    MissionPresent owner
      | owner.missionLeaseOwnerToken == lease.missionLeaseToken -> do
          ignoreFileOperation (removeFile lease.missionLeaseOwnerFile)
          ignoreFileOperation (removeDirectory lease.missionLeaseDirectory)
    _ -> pure ()

-- | The owner record of whatever holds a mission's lease, for a caller that
-- wants to say who rather than to take it.
readMissionLeaseOwner :: FilePath -> MissionId -> IO (MissionRead MissionLeaseOwner)
readMissionLeaseOwner store mission = case missionLeaseOwnerPath store mission of
  Left message -> pure (MissionUnreadable message)
  Right ownerPath -> readMissionRecord mission [missionLeaseSchemaVersion] ownerPath

-- | This acquisition's identity, or 'Nothing' when the snapshot could not be
-- taken. Best-effort by necessity, and fail-closed by consequence: a lease
-- recorded without an identity is one no successor may ever take.
capturedIdentity :: IO (Maybe ProcessIdentity)
capturedIdentity = currentProcessIdentity

newLeaseToken :: IO Text
newLeaseToken = do
  now <- getCurrentTime
  processId <- getProcessID
  pure (Text.filter (`notElem` ("-:. TZ" :: String)) (Text.pack (show now)) <> "-" <> Text.pack (show processId))
