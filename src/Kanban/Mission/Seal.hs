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
    missionSealCovers,
    MissionSealIndex,
    loadMissionSealIndex,
    missionWorkerLogsReleasable,
  )
where

import Control.Exception (IOException, try)
import Data.Either (isRight)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Domain (Repository)
import Kanban.Mission.Paths (MissionStore, openMissionStore)
import Kanban.Mission.Store
  ( MissionSealFailure (..),
    listMissionsStrictly,
    missionSealFailureMessage,
    missionSealedArchivePath,
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
-- worker has reached a terminal state, and says what is not sealed.
--
-- Safe to call as often as a caller likes, which is what makes it a retry. A
-- log that already has a seal is checked rather than trusted: its archived
-- copy has to verify against the recorded digest and length and still match
-- its source's length ('missionSealCovers'). One that does is done. One that
-- does not is reported every time this runs, because an archive is immutable
-- — nothing here may replace it, so the repair is an operator's, and until
-- then the worker cache keeps the source. A session with no worker record, or
-- one whose worker is still running, owes nothing yet; one whose worker state
-- cannot be read is reported, since nothing says which. A log with no seal and
-- no source is reported too: nothing is left to copy, and the worker cache
-- keeps the rest of that worker's records rather than treat the loss as
-- settled.
--
-- The answer is a list of failures for the caller to report and never an
-- 'Either': a mission does not stop, fail, or wait because one of its
-- sessions could not be archived this time.
sealMissionSessionLogs :: MissionStore -> MissionId -> [WorkerDescriptor] -> MissionSessionId -> IO [Text]
sealMissionSessionLogs store mission workers session =
  case find ((== session.unMissionSessionId) . workerIdentity) workers of
    Nothing -> withoutRecord
    Just descriptor -> do
      stateResult <- readWorkerState descriptor
      case stateResult of
        Right state
          | WorkerTerminal _ <- state.workerStateStatus -> do
              existing <- sealedFor
              concat <$> mapM (sealOne existing) (missionSessionLogSources descriptor state)
          | otherwise -> pure []
        -- Neither running nor finished as far as anything can tell, and
        -- nothing names its raw log: whatever it owes cannot even be listed,
        -- so it is reported every time rather than passed over as a session
        -- that owes nothing yet.
        Left detail ->
          pure
            [ "mission "
                <> mission.unMissionId
                <> ": the logs of session "
                <> session.unMissionSessionId
                <> " could not be sealed and will be tried again: its worker state could not be read ("
                <> detail
                <> ")"
            ]
  where
    -- No readable worker record: collected after its logs were sealed, which
    -- is the ordinary end of every mission session, or gone some other way —
    -- collected under a cache policy that did not wait for a seal, or a
    -- specification that no longer decodes. The archive is the only evidence
    -- left, so it decides. An event stream whose sealed copy is still whole is
    -- a session accounted for, and the raw log is judged the same way when
    -- one was sealed; anything else is reported on every pass, because no
    -- later pass can find what was never sealed.
    --
    -- Whole rather than rehashed. The collector verified each digest before it
    -- removed the source, and rehashing every archived log of every finished
    -- session on every pass would cost more with each mission that ever ran;
    -- what can still go wrong afterwards is a copy removed or cut short, which
    -- the recorded length catches.
    withoutRecord = do
      existing <- sealedFor
      verdicts <- mapM (\sealed -> (,) sealed.missionSealedKind <$> archiveWhole sealed) existing
      let judge kind = case [verdict | (sealedKind, verdict) <- verdicts, sealedKind == kind] of
            []
              | kind == MissionEventStreamLog -> Just "no readable worker record and no sealed event stream"
              | otherwise -> Nothing
            found
              | any isRight found -> Nothing
              | otherwise ->
                  Just
                    ( "no readable worker record, and its sealed "
                        <> missionLogKindTag kind
                        <> " is no longer whole: "
                        <> Text.intercalate "; " [detail | Left detail <- found]
                    )
      pure [recordless detail | kind <- [minBound .. maxBound], Just detail <- [judge kind]]

    archiveWhole sealed = do
      resolved <- missionSealedArchivePath store mission sealed
      case resolved of
        Left detail -> pure (Left detail)
        Right path -> do
          size <- try @IOException (getFileSize path)
          pure $ case size of
            Left exception -> Left ("could not read " <> Text.pack path <> " (" <> Text.pack (show exception) <> ")")
            Right bytes
              | bytes == sealed.missionSealedByteLength -> Right ()
              | otherwise ->
                  Left
                    ( Text.pack path
                        <> " is "
                        <> Text.pack (show bytes)
                        <> " bytes and its seal records "
                        <> Text.pack (show sealed.missionSealedByteLength)
                    )

    recordless detail =
      "mission "
        <> mission.unMissionId
        <> ": session "
        <> session.unMissionSessionId
        <> " has "
        <> detail
        <> ", so its logs cannot be accounted for and an operator has to resolve it"

    sealOne existing (kind, source) = case filter ((== kind) . (.missionSealedKind)) existing of
      [] -> do
        present <- doesFileExist source
        if not present
          then pure [failure kind ("its source " <> Text.pack source <> " is missing, so there is nothing to seal")]
          else do
            sealed <- sealMissionLog store mission session kind source
            case sealed of
              Right _ -> pure []
              -- Somebody else's attempt got there first — another pass, or the
              -- controller that watched the session end. That seal is judged
              -- like any other.
              Left (MissionSealAlreadySealed _ _) -> do
                found <- filter ((== kind) . (.missionSealedKind)) <$> sealedFor
                case found of
                  [] -> pure [failure kind "a seal record already exists for it and could not be read"]
                  seals -> judged kind source seals
              Left other -> pure [failure kind (missionSealFailureMessage other)]
      seals -> judged kind source seals

    judged kind source seals = do
      verdicts <- mapM (\sealed -> missionSealCovers store mission sealed source) seals
      pure $ case [() | Right () <- verdicts] of
        (_ : _) -> []
        [] ->
          [ "mission "
              <> mission.unMissionId
              <> ": the sealed "
              <> missionLogKindTag kind
              <> " of session "
              <> session.unMissionSessionId
              <> " cannot be relied on and cannot be replaced, so its source is kept until an operator resolves it: "
              <> Text.intercalate "; " [detail | Left detail <- verdicts]
          ]

    -- This session's readable seals, from one read of the mission's archive
    -- index.
    sealedFor = do
      (sealed, _) <- readableMissionSealedArchives store mission
      pure [entry | entry <- sealed, entry.missionSealedSession == session]

    failure kind detail =
      "mission "
        <> mission.unMissionId
        <> ": the "
        <> missionLogKindTag kind
        <> " of session "
        <> session.unMissionSessionId
        <> " could not be sealed and will be tried again: "
        <> detail

-- | Whether one seal is a complete, intact copy of the log it names.
--
-- Its archived bytes have to verify against the digest and length it
-- recorded, and — while the source is still there — the source has to be the
-- length that was sealed, so a copy taken before a stream finished is never
-- mistaken for the stream. The one statement of "sealed" both halves of this
-- module use, so the sealer and the collector cannot disagree about it.
missionSealCovers :: MissionStore -> MissionId -> MissionSealedArchive -> FilePath -> IO (Either Text ())
missionSealCovers store mission sealed source = do
  verified <- verifyMissionSealedArchive store mission sealed
  case verified of
    Left detail -> pure (Left detail)
    Right () -> do
      present <- doesFileExist source
      if not present
        then pure (Right ())
        else do
          size <- try @IOException (getFileSize source)
          pure $ case size of
            Left exception -> Left ("could not measure " <> Text.pack source <> " (" <> Text.pack (show exception) <> ")")
            Right bytes
              | bytes == sealed.missionSealedByteLength -> Right ()
              | otherwise ->
                  Left
                    ( Text.pack source
                        <> " is "
                        <> Text.pack (show bytes)
                        <> " bytes and its seal covers "
                        <> Text.pack (show sealed.missionSealedByteLength)
                    )

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
-- a seal for this session and log kind that 'missionSealCovers' accepts, for
-- every one of them.
--
-- Everything else keeps the records: no seal, whether or not its source is
-- still there, a seal that does not verify or no longer matches its source,
-- an index that could not be read, and one log sealed while the other is not.
-- What is kept is the whole worker,
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
    accountedFor (MissionSealIndex store seals) (kind, source) =
      or
        <$> mapM
          (\(mission, sealed) -> isRight <$> missionSealCovers store mission sealed source)
          [ (mission, sealed)
          | (mission, sealed) <- seals,
            sealed.missionSealedSession == session,
            sealed.missionSealedKind == kind
          ]

workerIdentity :: WorkerDescriptor -> Text
workerIdentity descriptor = descriptor.workerDescriptorSpec.workerId.unWorkerId
