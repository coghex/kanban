-- | A mission session's logs, sealed into the mission's own archive before the
-- worker cache may remove the originals (D-11, RUN-4).
--
-- Two halves, and they are one rule seen from either end. The sealing half
-- copies a terminal worker's event stream, and the provider's raw log when one
-- was recorded, into the archive through 'sealMissionLog'. The retention half
-- is what the worker-cache collector asks before it removes a worker's
-- records: a worker a mission dispatched keeps every one of them until each
-- log it owes has an archived copy that verifies.
--
-- Neither half decides anything about a mission's progress. A seal that fails
-- is reported to whoever asked and attempted again by a later pass; it never
-- blocks, fails, or reorders the mission whose session it belongs to.
--
-- This module is internal — "Kanban.Mission" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Mission.Seal
  ( missionSessionLogSources,
    sealMissionSessionLogs,
    MissionSealIndex,
    loadMissionSealIndex,
    missionWorkerLogsReleasable,
  )
where

import Control.Exception (IOException, try)
import Data.List (find)
import Data.Text (Text)
import Kanban.Domain (Repository)
import Kanban.Mission.Paths (MissionStore, openMissionStore)
import Kanban.Mission.Store
  ( MissionSealFailure (..),
    listMissionsStrictly,
    missionSealFailureMessage,
    readMissionSealedArchives,
    readableMissionSealedArchives,
    sealMissionLog,
    verifyMissionSealedArchive,
  )
import Kanban.Mission.Types
  ( MissionId (..),
    MissionLogKind (..),
    MissionSealedArchive (..),
    MissionSessionId (..),
    missionLogKindTag,
  )
import Kanban.Worker.Paths (readWorkerState)
import Kanban.Worker.Types
  ( WorkerDescriptor (..),
    WorkerId (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
  )
import System.Directory (doesFileExist, getFileSize)

-- | Every log one worker owes its mission's archive, and where each one is.
--
-- The event stream always: it is Kanban's own record of the session and the
-- file the worker cache would otherwise remove. The provider's raw log only
-- when the worker recorded one, and only where it recorded it — this names the
-- file for sealing and for the retention check, and never makes it
-- collectable.
missionSessionLogSources :: WorkerDescriptor -> WorkerState -> [(MissionLogKind, FilePath)]
missionSessionLogSources descriptor state =
  (MissionEventStreamLog, descriptor.workerDescriptorEventPath)
    : [(MissionRawProviderLog, path) | Just path <- [state.workerStateLogPath]]

-- | Seals whatever one registered session still owes the archive, once its
-- worker has reached a terminal state, and says what could not be sealed.
--
-- Safe to call as often as a caller likes, which is what makes it a retry. A
-- log that already has a seal record is left exactly as it is: an archive is
-- immutable, so the way a second attempt recognizes the first is by finding
-- it rather than by writing over it. A session with no worker record, or one
-- whose worker is still running, owes nothing yet; a log whose source is not
-- there has nothing left to copy.
--
-- The answer is a list of failures for the caller to report and never an
-- 'Either': a mission does not stop, fail, or wait because one of its
-- sessions could not be archived this time.
sealMissionSessionLogs :: MissionStore -> MissionId -> [WorkerDescriptor] -> MissionSessionId -> IO [Text]
sealMissionSessionLogs store mission workers session =
  case find ((== session.unMissionSessionId) . workerIdentity) workers of
    Nothing -> pure []
    Just descriptor -> do
      stateResult <- readWorkerState descriptor
      case stateResult of
        Right state
          | WorkerTerminal _ <- state.workerStateStatus -> do
              sealedKinds <- sealedFor
              concat <$> mapM (sealOne sealedKinds) (missionSessionLogSources descriptor state)
        _ -> pure []
  where
    sealOne sealedKinds (kind, source) = do
      let already = kind `elem` sealedKinds
      present <- doesFileExist source
      if already || not present
        then pure []
        else do
          sealed <- sealMissionLog store mission session kind source
          case sealed of
            Right _ -> pure []
            -- Somebody else's attempt got there first — another pass, or the
            -- controller that watched the session end. That is a seal, and
            -- only a record nobody can read is a failure.
            Left (MissionSealAlreadySealed _ _) -> do
              found <- sealedFor
              pure
                [ failure kind "a seal record already exists for it and could not be read"
                | kind `notElem` found
                ]
            Left other -> pure [failure kind (missionSealFailureMessage other)]

    -- The log kinds this session already has a readable seal for, from one
    -- read of the mission's archive index.
    sealedFor = do
      (sealed, _) <- readableMissionSealedArchives store mission
      pure [entry.missionSealedKind | entry <- sealed, entry.missionSealedSession == session]

    failure kind detail =
      "mission "
        <> mission.unMissionId
        <> ": the "
        <> missionLogKindTag kind
        <> " of session "
        <> session.unMissionSessionId
        <> " could not be sealed and will be tried again: "
        <> detail

-- | Every seal a repository's mission store holds, read strictly.
data MissionSealIndex = MissionSealIndex MissionStore [(MissionId, MissionSealedArchive)]

-- | Reads the index a collection decision is made from.
--
-- Strict throughout, because it is consulted before something is deleted. A
-- store that cannot be opened, a mission directory that cannot be listed, and
-- an archive entry that will not decode each make the whole index unreadable
-- rather than quietly smaller: an index missing the one seal that would have
-- kept a log is exactly how a collector removes a last copy.
loadMissionSealIndex :: Repository -> IO (Either Text MissionSealIndex)
loadMissionSealIndex repository = do
  opened <- openMissionStore repository
  case opened of
    Left message -> pure (Left message)
    Right store -> do
      (missions, unenumerable) <- listMissionsStrictly store
      case unenumerable of
        (message : _) -> pure (Left message)
        [] -> do
          archives <- mapM (\mission -> fmap (map (mission,)) <$> readMissionSealedArchives store mission) missions
          pure (MissionSealIndex store . concat <$> sequence archives)

-- | Whether the worker cache may remove this terminal worker's records.
--
-- A worker no mission dispatched always may, exactly as before: its
-- specification records no invocation, and this answers 'True' without
-- touching the mission store. A mission-dispatched worker may only once every
-- log 'missionSessionLogSources' names is accounted for, and "accounted for"
-- is deliberately narrow:
--
--   * a seal for this session and log kind whose archived copy verifies
--     against its recorded digest and length, and whose length still matches
--     the source when the source is there — so a copy taken before the stream
--     finished is not mistaken for the stream; or
--   * no seal and no source, which leaves nothing for a removal to lose.
--
-- Everything else keeps the records: no seal beside a source that is still
-- there, a seal that does not verify, an index that could not be read, and
-- one log sealed while the other is not. What is kept is the whole worker,
-- specification and state included, because they are what associates the
-- logs with their mission and names the raw log at all — which is also what
-- protects a worker created before its mission recorded the handle, since
-- the invocation is in its own specification from the moment it exists.
--
-- The index is an action rather than a value so a collection pass reads it
-- once, and only when it meets a mission's worker at all.
missionWorkerLogsReleasable :: IO (Either Text MissionSealIndex) -> WorkerDescriptor -> WorkerState -> IO Bool
missionWorkerLogsReleasable loadIndex descriptor state =
  case descriptor.workerDescriptorSpec.workerInvocation of
    Nothing -> pure True
    Just _ -> do
      loaded <- loadIndex
      case loaded of
        Left _ -> pure False
        Right index -> and <$> mapM (accountedFor index) (missionSessionLogSources descriptor state)
  where
    session = MissionSessionId (workerIdentity descriptor)
    accountedFor (MissionSealIndex store seals) (kind, source) = do
      present <- doesFileExist source
      case [ (mission, sealed)
           | (mission, sealed) <- seals,
             sealed.missionSealedSession == session,
             sealed.missionSealedKind == kind
           ] of
        [] -> pure (not present)
        candidates -> or <$> mapM (verifies store present source) candidates
    verifies store present source (mission, sealed) = do
      verified <- verifyMissionSealedArchive store mission sealed
      case verified of
        Left _ -> pure False
        Right ()
          | not present -> pure True
          | otherwise -> do
              size <- try @IOException (getFileSize source)
              pure (either (const False) (== sealed.missionSealedByteLength) size)

workerIdentity :: WorkerDescriptor -> Text
workerIdentity descriptor = descriptor.workerDescriptorSpec.workerId.unWorkerId
