-- | The operations a mission's durable record supports: creating it, replacing
-- its snapshot, appending to its journal, sealing a child's log, enumerating a
-- repository's missions, and the two dispositions — archive and delete — that
-- decide entirely from what was recorded.
--
-- Three rules run through all of it.
--
-- Nothing here inspects a live process, contacts GitHub, or starts anything.
-- An operation that needs to know whether a session is still running reads the
-- disposition recorded on the node
-- ('Kanban.Mission.Types.missionSessionDisposition') and fails closed when
-- what was recorded does not settle the question. Reconciling a record against
-- live evidence is SAG-3's, and this slice deliberately ships the fields it
-- will read rather than a pass that reads them.
--
-- \"Is there already one of these?\" is answered by the filesystem, never by a
-- successful decode. A record written under a schema version this release does
-- not recognize reads as /absent/ (§16), and a write that took that absence
-- for permission would overwrite a future release's specification or reseal
-- over its archive. Both no-replace guarantees are therefore existence checks:
-- an @O_EXCL@ create for a specification, and a file test for a seal.
--
-- A refusal reports every reason it found, not the first. Delete has five
-- gates, and a caller told only about the first one repairs it, retries, and
-- is refused again — which is how a gate added later gets reported as if it
-- were the only one.
--
-- This module is internal — "Kanban.Mission" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Mission.Store
  ( -- * The store
    MissionStore (..),
    openMissionStore,
    listMissions,

    -- * The specification
    MissionCreation (..),
    createMissionSpecification,
    readMissionSpecification,

    -- * The snapshot
    writeMissionSnapshot,
    readMissionSnapshot,

    -- * The journal
    recordMissionEvent,
    readMissionJournal,

    -- * Sealed archives
    MissionSealFailure (..),
    missionSealFailureMessage,
    sealMissionLog,
    readMissionSealedArchives,
    verifyMissionSealedArchive,

    -- * Archive and delete
    MissionDispositionRefusal (..),
    missionDispositionRefusalMessage,
    archiveMission,
    deleteMission,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (filterM)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, getCurrentTime)
import Kanban.Mission.Digest (sha256Hex)
import Kanban.Mission.Journal (MissionJournalLine (MissionJournalUnknownVersion), appendMissionEvent, decodeMissionJournalLine, readMissionJournalSince)
import Kanban.Mission.Session (missionSessionTreeErrorMessage, validateMissionSessionTree)
import Kanban.Mission.Paths
  ( MissionRead (..),
    createMissionRecord,
    ensureMissionDirectory,
    MissionStore (..),
    listMissionEntries,
    missionArchiveDirectory,
    openMissionStore,
    withStagedContent,
    commitNoReplace,
    missionArchivePath,
    missionDirectory,
    missionJournalPath,
    missionSealPath,
    missionSnapshotPath,
    missionSpecificationPath,
    readMissionRecordFor,
    writeMissionRecord,
  )
import Kanban.Mission.Types
  ( MissionArchiveState (..),
    MissionEvent (..),
    MissionId (..),
    MissionLogKind,
    MissionPresentation (MissionPresentationArchived),
    MissionSealedArchive (..),
    MissionSessionDisposition (..),
    MissionSessionId (..),
    MissionSessionNode (..),
    MissionSnapshot (..),
    MissionSpecification (..),
    MissionStepId (..),
    MissionRepository (..),
    MissionStepLifecycle (MissionStepOutcomeUnknown),
    MissionStepRecord (..),
    MissionWorktreeDisposition (..),
    MissionWorktreeState (MissionWorktreeRetained),
    missionLifecycleIsTerminal,
    missionLifecycleTag,
    missionLogKindTag,
    missionSealDigestAlgorithm,
    missionSealSchemaVersion,
    missionSessionDisposition,
    missionSnapshotSchemaVersion,
    missionSpecificationSchemaVersion,
  )
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import System.Directory (doesFileExist, removePathForcibly)
import System.FilePath (takeFileName, (</>))
import System.Posix.Files (getSymbolicLinkStatus, isDirectory)

-- | Every mission of this repository, sorted.
--
-- Reads the store's own directory and nothing inside a mission: no
-- specification, no snapshot, and above all no journal, so enumeration costs
-- the same whether a mission recorded three events or thirty thousand.
--
-- Every entry is checked with a /non-following/ stat and must be a real
-- directory. A symbolic link pointing at somewhere else on the filesystem, a
-- socket, a stray file — each is ignored rather than followed, which is the
-- difference between an enumeration that lists what the store holds and one
-- that can be pointed anywhere by whatever wrote a name into it.
listMissions :: MissionStore -> IO [MissionId]
listMissions store = do
  entries <- listMissionEntries store.missionStoreDirectory
  directories <- filterM (isPlainDirectory . (store.missionStoreDirectory </>)) entries
  pure (sort (map (MissionId . Text.pack . takeFileName) directories))

isPlainDirectory :: FilePath -> IO Bool
isPlainDirectory path = do
  status <- try @IOException (getSymbolicLinkStatus path)
  pure (either (const False) isDirectory status)

-- | Whether a specification was written, or one was already there.
data MissionCreation
  = MissionCreated
  | -- | A specification already exists for this identifier. The original is
    -- untouched.
    MissionSpecificationExists
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- | Writes a mission's specification, once.
--
-- Atomic and no-replace together: the file is created with @O_CREAT | O_EXCL@,
-- so two processes racing one identifier cannot both succeed and neither an
-- interruption nor a retry can rewrite a specification that is already there.
createMissionSpecification :: MissionStore -> MissionSpecification -> IO (Either Text MissionCreation)
createMissionSpecification store specification = do
  let mission = specification.missionSpecificationId
  case (,) <$> missionDirectory store.missionStoreDirectory mission <*> missionSpecificationPath store.missionStoreDirectory mission
    <* belongsHere store mission specification.missionSpecificationRepository of
    Left message -> pure (Left message)
    Right (directory, path) -> do
      prepared <- ensureMissionDirectory directory
      case prepared of
        Left message -> pure (Left message)
        Right () -> do
          created <- createMissionRecord path missionSpecificationSchemaVersion specification
          pure (fmap (\wrote -> if wrote then MissionCreated else MissionSpecificationExists) created)

-- | Refuses to write a record this store would then refuse to read.
--
-- The reader's identity check (requirement 11) exists for a record that
-- arrives some other way — a store directory copied, restored, or read for a
-- renamed repository — and it would be a strange guarantee if this release
-- could produce one itself.
belongsHere :: MissionStore -> MissionId -> MissionRepository -> Either Text ()
belongsHere store mission recorded
  | recorded == store.missionStoreRepository = Right ()
  | otherwise =
      Left
        ( "mission "
            <> mission.unMissionId
            <> " records the repository "
            <> recorded.missionRepositoryOwner
            <> "/"
            <> recorded.missionRepositoryName
            <> ", which is not the one this store holds"
        )

-- | Refuses to write a snapshot whose session tree is not one.
--
-- This is where D-14 is /enforced/ rather than merely modelled: a duplicate
-- identity, a parent that does not resolve, a parent in another mission and a
-- lineage that loops all round-trip through JSON perfectly well, and each
-- leaves "walk up to the root" a question with no answer. Refusing the write
-- is what keeps one out of the store in the first place.
wellFormedSessions :: MissionSnapshot -> Either Text ()
wellFormedSessions snapshot =
  case validateMissionSessionTree snapshot.missionSnapshotId snapshot.missionSnapshotSessions of
    Right () -> Right ()
    Left failure ->
      Left
        ( "mission "
            <> snapshot.missionSnapshotId.unMissionId
            <> ": "
            <> missionSessionTreeErrorMessage failure
        )

readMissionSpecification :: MissionStore -> MissionId -> IO (MissionRead MissionSpecification)
readMissionSpecification store mission = case missionSpecificationPath store.missionStoreDirectory mission of
  Left message -> pure (MissionUnreadable message)
  Right path ->
    readMissionRecordFor
      mission
      [missionSpecificationSchemaVersion]
      store.missionStoreRepository
      missionSpecificationId
      missionSpecificationRepository
      path

-- | Replaces a mission's snapshot atomically.
--
-- Temporary file, mode, rename: an interrupted write leaves the previous
-- snapshot exactly as it was and still current, rather than a half-written one
-- a reader would report as corruption.
writeMissionSnapshot :: MissionStore -> MissionSnapshot -> IO (Either Text ())
writeMissionSnapshot store snapshot = do
  let mission = snapshot.missionSnapshotId
  case (,) <$> missionDirectory store.missionStoreDirectory mission <*> missionSnapshotPath store.missionStoreDirectory mission
    <* belongsHere store mission snapshot.missionSnapshotRepository
    <* wellFormedSessions snapshot of
    Left message -> pure (Left message)
    Right (directory, path) -> do
      prepared <- ensureMissionDirectory directory
      case prepared of
        Left message -> pure (Left message)
        Right () -> writeMissionRecord path missionSnapshotSchemaVersion snapshot

readMissionSnapshot :: MissionStore -> MissionId -> IO (MissionRead MissionSnapshot)
readMissionSnapshot store mission = case missionSnapshotPath store.missionStoreDirectory mission of
  Left message -> pure (MissionUnreadable message)
  Right path ->
    readMissionRecordFor
      mission
      [missionSnapshotSchemaVersion]
      store.missionStoreRepository
      missionSnapshotId
      missionSnapshotRepository
      path

-- | Appends one event to a mission's journal.
recordMissionEvent :: MissionStore -> MissionEvent -> IO (Either Text ())
recordMissionEvent store event = do
  let mission = event.missionEventMission
  case (,) <$> missionDirectory store.missionStoreDirectory mission <*> missionJournalPath store.missionStoreDirectory mission
    <* belongsHere store mission event.missionEventRepository of
    Left message -> pure (Left message)
    Right (directory, path) -> do
      prepared <- ensureMissionDirectory directory
      case prepared of
        Left message -> pure (Left message)
        Right () -> appendMissionEvent path event

-- | The complete journal records appended since @consumedBytes@, and the new
-- offset.
--
-- A record that was still being appended when this read ran is not in the
-- result and not consumed: the returned offset stops at the last newline, so
-- the very next read sees that record whole, once, rather than a truncated
-- version of it now and a duplicate later.
readMissionJournal :: MissionStore -> MissionId -> Int -> IO (Either Text ([MissionJournalLine], Int))
readMissionJournal store mission consumedBytes = case missionJournalPath store.missionStoreDirectory mission of
  Left message -> pure (Left message)
  Right path -> do
    result <- readMissionJournalSince path consumedBytes
    pure (fmap (\(lines', offset) -> (readable (map (decodeMissionJournalLine mission store.missionStoreRepository path) lines'), offset)) result)
  where
    -- A record written under a schema version this release does not
    -- recognize is absent (§16), and absent means the caller is not told
    -- about it. The offset is unaffected: the line was consumed, so the read
    -- after this one starts past it and the records around it are examined
    -- exactly as they would have been.
    readable = filter notUnknownVersion
    notUnknownVersion line = case line of
      MissionJournalUnknownVersion _ -> False
      _ -> True

-- | Why a seal did not happen.
data MissionSealFailure
  = MissionSealPathRefused Text
  | -- | An archive entry for this session and log kind already exists. A seal
    -- is immutable: the way to record different bytes is a different entry.
    MissionSealAlreadySealed MissionSessionId MissionLogKind
  | MissionSealSourceUnreadable FilePath Text
  | MissionSealNotWritten Text
  deriving stock (Eq, Show)

missionSealFailureMessage :: MissionSealFailure -> Text
missionSealFailureMessage failure = case failure of
  MissionSealPathRefused message -> message
  MissionSealAlreadySealed session kind ->
    "the " <> missionLogKindTag kind <> " of session " <> session.unMissionSessionId <> " is already sealed"
  MissionSealSourceUnreadable source message ->
    "could not read " <> Text.pack source <> " to seal it (" <> message <> ")"
  MissionSealNotWritten message -> message

-- | Copies one child's complete event stream or raw provider log into the
-- mission's own archive, and records the digest and byte length that verify
-- the copy afterwards.
--
-- The order is the guarantee. The bytes are read once, written to a temporary
-- name, and renamed into place; only then is the seal record created, and only
-- with @O_EXCL@. So a run interrupted anywhere leaves either no archive entry
-- at all or an unreferenced copy that the next attempt replaces — never a
-- sealed record naming a copy that was never finished. Digest and length are
-- taken from the same bytes that were written, so what the record describes
-- and what the archive holds cannot differ.
--
-- This takes a path. It does not decide whether the worker cache may now
-- collect that path: that judgement is a collector's, and D-23 keeps one out
-- of this arc.
sealMissionLog ::
  MissionStore ->
  MissionId ->
  MissionSessionId ->
  MissionLogKind ->
  FilePath ->
  IO (Either MissionSealFailure MissionSealedArchive)
sealMissionLog store mission session kind source =
  case (,,) <$> missionArchiveDirectory store.missionStoreDirectory mission
    <*> missionArchivePath store.missionStoreDirectory mission session kind
    <*> missionSealPath store.missionStoreDirectory mission session kind of
    Left message -> pure (Left (MissionSealPathRefused message))
    Right (archiveDirectory, archivePath, sealPath) -> do
      -- Existence, not a successful decode: a seal record written under a
      -- schema version this release does not recognize reads as absent, and
      -- resealing over it would destroy an archive entry a later release
      -- still owns. This is a fast refusal rather than the guarantee — the
      -- guarantee is the no-replace commit below, which is what settles a
      -- race this check cannot see.
      alreadySealed <- doesFileExist sealPath
      if alreadySealed
        then pure (Left (MissionSealAlreadySealed session kind))
        else do
          prepared <- ensureMissionDirectory archiveDirectory
          case prepared of
            Left message -> pure (Left (MissionSealNotWritten message))
            Right () -> do
              bytesResult <- try @IOException (ByteString.readFile source)
              case bytesResult of
                Left exception -> pure (Left (MissionSealSourceUnreadable source (Text.pack (show exception))))
                Right bytes -> do
                  published <- publishArchive archivePath bytes
                  case published of
                    Left message -> pure (Left (MissionSealNotWritten message))
                    Right _ -> commitSeal mission store.missionStoreRepository session kind source archivePath sealPath

-- | Puts the bytes in the archive under a commit that cannot replace what is
-- already there.
--
-- A rename here would be the whole race: two callers can both find no seal
-- record, and the one that loses the seal creation would still have renamed
-- /its/ bytes over the archive the winner sealed, leaving a seal that no
-- longer verifies the file it names. A link fails instead, so a committed
-- archive is immutable from the moment it exists and the loser touches
-- nothing. Reporting whether this call published is deliberately not what the
-- caller decides on: what matters is that an archive is now there, and the
-- seal is written from that file rather than from the bytes this call happens
-- to be holding.
publishArchive :: FilePath -> ByteString.ByteString -> IO (Either Text Bool)
publishArchive archivePath bytes =
  withStagedContent archivePath (LazyByteString.fromStrict bytes) (`commitNoReplace` archivePath)

-- | Records the seal for an archive that is already committed.
--
-- The digest and length are taken by reading the archive back, never from the
-- bytes the caller supplied, so the record describes the file it names even
-- when this call found an archive an interrupted earlier attempt had already
-- published. That is also what makes the interrupted case recoverable: an
-- archive with no seal beside it is completed by the next attempt rather than
-- left permanently unverifiable.
commitSeal ::
  MissionId ->
  MissionRepository ->
  MissionSessionId ->
  MissionLogKind ->
  FilePath ->
  FilePath ->
  FilePath ->
  IO (Either MissionSealFailure MissionSealedArchive)
commitSeal mission repository session kind source archivePath sealPath = do
  archivedResult <- try @IOException (ByteString.readFile archivePath)
  case archivedResult of
    Left exception -> pure (Left (MissionSealNotWritten (Text.pack (show exception))))
    Right archivedBytes -> do
      now <- getCurrentTime
      let sealed =
            MissionSealedArchive
              { missionSealedMission = mission,
                missionSealedRepository = repository,
                missionSealedSession = session,
                missionSealedKind = kind,
                missionSealedName = takeFileName archivePath,
                missionSealedDigestAlgorithm = missionSealDigestAlgorithm,
                missionSealedDigest = sha256Hex archivedBytes,
                missionSealedByteLength = fromIntegral (ByteString.length archivedBytes),
                missionSealedAt = now,
                missionSealedSource = source
              }
      recorded <- createMissionRecord sealPath missionSealSchemaVersion sealed
      pure $ case recorded of
        Left message -> Left (MissionSealNotWritten message)
        Right False -> Left (MissionSealAlreadySealed session kind)
        Right True -> Right sealed

-- | Every sealed archive entry a mission holds.
--
-- An entry whose record will not decode is reported rather than skipped: a
-- collector deciding what may be removed must not be told an archive is empty
-- because its index was damaged.
readMissionSealedArchives :: MissionStore -> MissionId -> IO (Either Text [MissionSealedArchive])
readMissionSealedArchives store mission = case missionArchiveDirectory store.missionStoreDirectory mission of
  Left message -> pure (Left message)
  Right archiveDirectory -> do
    entries <- listMissionEntries archiveDirectory
    let sealNames = sort (filter (".seal.json" `isSuffixOfPath`) entries)
    results <- mapM (readSeal archiveDirectory) sealNames
    pure (collect (zip sealNames results))
  where
    isSuffixOfPath suffix name = suffix `Text.isSuffixOf` Text.pack name
    readSeal archiveDirectory name =
      readMissionRecordFor
        mission
        [missionSealSchemaVersion]
        store.missionStoreRepository
        missionSealedMission
        missionSealedRepository
        (archiveDirectory </> name)
    collect pairs = case [message | (_, MissionUnreadable message) <- pairs] of
      message : _ -> Left message
      [] -> case [message | (_, MissionRefused message) <- pairs] of
        message : _ -> Left message
        [] -> Right [sealed | (_, MissionPresent sealed) <- pairs]

-- | Re-reads an archived copy and checks it against what the seal recorded.
--
-- The archived copy is what is verified — never the source, which the whole
-- point of a seal is to outlive.
verifyMissionSealedArchive :: MissionStore -> MissionId -> MissionSealedArchive -> IO (Either Text ())
verifyMissionSealedArchive store mission sealed =
  case missionArchivePath store.missionStoreDirectory mission sealed.missionSealedSession sealed.missionSealedKind of
    Left message -> pure (Left message)
    Right path
      -- Both identities, for the reason every read here checks both: a seal
      -- is what a collector trusts before it removes a source, and one
      -- carried in from another mission or another repository would have it
      -- verify a file it knows nothing about.
      | sealed.missionSealedMission /= mission ->
          pure (Left (foreign' ("mission " <> sealed.missionSealedMission.unMissionId)))
      | sealed.missionSealedRepository /= store.missionStoreRepository ->
          pure (Left (foreign' "another repository"))
      -- The path is recomputed from the session and log kind this record is
      -- *about*, never joined from the name it carries. A record is durable
      -- data: one that has been edited could name `../../elsewhere` or some
      -- other mission's archive, and a verification that read that file would
      -- hash whatever was there and report success against the forged digest
      -- beside it. The recorded name is still compared, so a record that
      -- disagrees with its own subject is reported rather than quietly
      -- verified against the right file.
      | sealed.missionSealedName /= takeFileName path ->
          pure
            ( Left
                ( "mission "
                    <> mission.unMissionId
                    <> ": the seal of session "
                    <> sealed.missionSealedSession.unMissionSessionId
                    <> " names the archived file "
                    <> Text.pack (show sealed.missionSealedName)
                    <> " rather than "
                    <> Text.pack (show (takeFileName path))
                    <> ", and was not verified against it"
                )
            )
      | sealed.missionSealedDigestAlgorithm /= missionSealDigestAlgorithm ->
          pure
            ( Left
                ( "the archive of session "
                    <> sealed.missionSealedSession.unMissionSessionId
                    <> " records the digest algorithm "
                    <> sealed.missionSealedDigestAlgorithm
                    <> ", which this release cannot verify"
                )
            )
      | otherwise -> do
          bytesResult <- try @IOException (ByteString.readFile path)
          pure $ case bytesResult of
            Left exception -> Left ("could not read " <> Text.pack path <> " (" <> Text.pack (show exception) <> ")")
            Right bytes
              | fromIntegral (ByteString.length bytes) /= sealed.missionSealedByteLength ->
                  Left (mismatch path "byte length" (Text.pack (show sealed.missionSealedByteLength)) (Text.pack (show (ByteString.length bytes))))
              | sha256Hex bytes /= sealed.missionSealedDigest ->
                  Left (mismatch path "digest" sealed.missionSealedDigest (sha256Hex bytes))
              | otherwise -> Right ()
      where
        mismatch path' what expected found =
          "mission "
            <> mission.unMissionId
            <> ": "
            <> Text.pack path'
            <> " has "
            <> what
            <> " "
            <> found
            <> " but its seal records "
            <> expected
        foreign' subject =
          "the seal of session "
            <> sealed.missionSealedSession.unMissionSessionId
            <> " belongs to "
            <> subject
            <> " rather than mission "
            <> mission.unMissionId
            <> ", and was not verified"

-- | Why a mission may not be archived or deleted.
data MissionDispositionRefusal
  = -- | Its snapshot is missing, will not decode, or belongs to another
    -- repository, so nothing about it can be decided.
    MissionDispositionUnreadable Text
  | MissionDispositionNotTerminal Text
  | MissionDispositionLiveSession MissionSessionId
  | MissionDispositionUnverifiableSession MissionSessionId
  | MissionDispositionOutcomeUnknownStep MissionStepId
  | MissionDispositionSoleRecoveryRecord FilePath
  deriving stock (Eq, Show)

missionDispositionRefusalMessage :: MissionDispositionRefusal -> Text
missionDispositionRefusalMessage refusal = case refusal of
  MissionDispositionUnreadable message -> message
  MissionDispositionNotTerminal lifecycle -> "the mission is " <> lifecycle <> " rather than finished"
  MissionDispositionLiveSession session ->
    "session " <> session.unMissionSessionId <> " is recorded as still running"
  MissionDispositionUnverifiableSession session ->
    "session " <> session.unMissionSessionId <> " cannot be proven to have finished"
  MissionDispositionOutcomeUnknownStep step ->
    "step " <> step.unMissionStepId <> " never learned its outcome"
  MissionDispositionSoleRecoveryRecord path ->
    "this is the only record of the retained worktree " <> Text.pack path

-- | Moves a terminal mission out of the active presentation, keeping its whole
-- history readable.
--
-- Nothing is removed and nothing is compacted: an archived mission's
-- specification, snapshot, journal and sealed archives are exactly where they
-- were, and only 'missionArchivePresentation' changed.
archiveMission :: MissionStore -> MissionId -> IO (Either [MissionDispositionRefusal] ())
archiveMission store mission = do
  snapshotResult <- readMissionSnapshot store mission
  case snapshotResult of
    MissionPresent snapshot -> case terminalRefusals snapshot of
      refusal : rest -> pure (Left (refusal : rest))
      [] -> do
        now <- getCurrentTime
        written <- writeMissionSnapshot store (archived now snapshot)
        pure (either (Left . pure . MissionDispositionUnreadable) Right written)
    other -> pure (Left [unreadableRefusal mission other])

archived :: UTCTime -> MissionSnapshot -> MissionSnapshot
archived now snapshot =
  snapshot
    { missionSnapshotArchive =
        MissionArchiveState
          { missionArchivePresentation = MissionPresentationArchived,
            missionArchiveWorktrees = snapshot.missionSnapshotArchive.missionArchiveWorktrees,
            missionArchiveLastAccessedAt = Just now
          },
      missionSnapshotUpdatedAt = now
    }

-- | Removes a mission's whole record, when every gate requirement 10 names is
-- clear.
--
-- Every refusal that applies is reported, not the first: a caller told only
-- about the nonterminal lifecycle would finish the mission, retry, and be
-- refused again for a session it was never told about.
deleteMission :: MissionStore -> MissionId -> IO (Either [MissionDispositionRefusal] ())
deleteMission store mission = do
  snapshotResult <- readMissionSnapshot store mission
  case snapshotResult of
    MissionPresent snapshot -> case terminalRefusals snapshot <> sessionRefusals snapshot <> stepRefusals snapshot <> worktreeRefusals snapshot of
      refusal : rest -> pure (Left (refusal : rest))
      [] -> case missionDirectory store.missionStoreDirectory mission of
        Left message -> pure (Left [MissionDispositionUnreadable message])
        Right directory -> do
          removed <- try @IOException (removePathForcibly directory)
          pure (either (Left . pure . MissionDispositionUnreadable . Text.pack . show) Right removed)
    other -> pure (Left [unreadableRefusal mission other])

unreadableRefusal :: MissionId -> MissionRead value -> MissionDispositionRefusal
unreadableRefusal mission result = MissionDispositionUnreadable $ case result of
  MissionUnreadable message -> message
  MissionRefused message -> message
  _ -> "mission " <> mission.unMissionId <> " has no snapshot to decide from"

terminalRefusals :: MissionSnapshot -> [MissionDispositionRefusal]
terminalRefusals snapshot
  | missionLifecycleIsTerminal snapshot.missionSnapshotLifecycle = []
  | otherwise = [MissionDispositionNotTerminal (missionLifecycleTag snapshot.missionSnapshotLifecycle)]

sessionRefusals :: MissionSnapshot -> [MissionDispositionRefusal]
sessionRefusals snapshot =
  [ refusal
    | session <- snapshot.missionSnapshotSessions,
      Just refusal <- [case missionSessionDisposition session of
                         MissionSessionLive -> Just (MissionDispositionLiveSession session.missionSessionId)
                         MissionSessionUnverifiable -> Just (MissionDispositionUnverifiableSession session.missionSessionId)
                         MissionSessionSettled -> Nothing]
  ]

stepRefusals :: MissionSnapshot -> [MissionDispositionRefusal]
stepRefusals snapshot =
  [ MissionDispositionOutcomeUnknownStep step.missionStepRecordId
    | step <- snapshot.missionSnapshotSteps,
      step.missionStepRecordLifecycle == MissionStepOutcomeUnknown
  ]

worktreeRefusals :: MissionSnapshot -> [MissionDispositionRefusal]
worktreeRefusals snapshot =
  [ MissionDispositionSoleRecoveryRecord worktree.missionWorktreePath
    | worktree <- snapshot.missionSnapshotArchive.missionArchiveWorktrees,
      worktree.missionWorktreeState == MissionWorktreeRetained,
      worktree.missionWorktreeSoleRecoveryRecord
  ]
