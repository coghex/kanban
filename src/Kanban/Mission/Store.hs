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
import Data.List (nub, sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, getCurrentTime)
import Kanban.Mission.Digest (sha256Hex)
import Kanban.Mission.Journal (MissionJournalLine (MissionJournalUnknownVersion), appendMissionEvent, decodeMissionJournalLine, readMissionJournalSince)
import Kanban.Mission.Session (missionSessionTreeErrorMessage, validateMissionSessionTree)
import Kanban.Mission.Paths
  ( MissionRead (..),
    adoptedLegacyMissions,
    createMissionRecord,
    ensureMissionDirectory,
    MissionStore (..),
    ignoreFileOperation,
    isPlainDirectory,
    listMissionEntries,
    missionRoot,
    withMissionRoot,
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
import System.Directory (doesFileExist, removePathForcibly, renameDirectory)
import System.FilePath (takeFileName, (</>))
import System.Posix.Process (getProcessID)

-- | Every mission of this repository, sorted.
--
-- Reads the store's own directory and nothing inside a mission: no
-- specification, no snapshot, and above all no journal, so enumeration costs
-- the same whether a mission recorded three events or thirty thousand.
--
-- The ambiguous legacy root is enumerated too, and there the identity records
-- do have to be read, because that root is shared with every repository whose
-- owner and name fall the same way and only a mission's own records say whose
-- it is. That read is bounded by the three fixed-path records
-- 'adoptedLegacyMissions' consults, so it is one cost per legacy mission
-- rather than one per event.
--
-- Every candidate is then put through 'missionRoot', the same decision every
-- read and write goes through, and an identifier that decision refuses is not
-- listed. Enumerating one would be reporting a mission nothing can read, write
-- or delete: a legacy directory attributable to nobody, or one identifier with
-- records under both roots, is history to be repaired rather than a mission of
-- this repository, and addressing it reports its path and the reason.
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
  legacy <- adoptedLegacyMissions store
  let candidates = sort (nub (map (MissionId . Text.pack . takeFileName) directories <> legacy))
  filterM resolves candidates
  where
    resolves mission = either (const False) (const True) <$> missionRoot store mission

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
createMissionSpecification store specification =
  withMissionRoot store mission Left $ \root ->
    case (,) <$> missionDirectory root mission <*> missionSpecificationPath root mission
      <* belongsHere store mission specification.missionSpecificationRepository of
      Left message -> pure (Left message)
      Right (directory, path) -> do
        prepared <- ensureMissionDirectory directory
        case prepared of
          Left message -> pure (Left message)
          Right () -> do
            created <- createMissionRecord path missionSpecificationSchemaVersion specification
            pure (fmap (\wrote -> if wrote then MissionCreated else MissionSpecificationExists) created)
  where
    mission = specification.missionSpecificationId

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
wellFormedSessions snapshot = case sessionTreeFailure snapshot of
  Nothing -> Right ()
  Just reason -> Left ("mission " <> snapshot.missionSnapshotId.unMissionId <> ": " <> reason)

-- | Why this snapshot's sessions are not a tree, if they are not.
--
-- The single spelling the write refusal and the read refusal both go through,
-- so the two cannot come to disagree about what a tree is.
sessionTreeFailure :: MissionSnapshot -> Maybe Text
sessionTreeFailure snapshot =
  either
    (Just . missionSessionTreeErrorMessage)
    (const Nothing)
    (validateMissionSessionTree snapshot.missionSnapshotId snapshot.missionSnapshotSessions)

readMissionSpecification :: MissionStore -> MissionId -> IO (MissionRead MissionSpecification)
readMissionSpecification store mission =
  withMissionRoot store mission MissionUnreadable $ \root ->
    case missionSpecificationPath root mission of
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
writeMissionSnapshot store snapshot =
  withMissionRoot store mission Left $ \root ->
    case (,) <$> missionDirectory root mission <*> missionSnapshotPath root mission
      <* belongsHere store mission snapshot.missionSnapshotRepository
      <* wellFormedSessions snapshot of
      Left message -> pure (Left message)
      Right (directory, path) -> do
        prepared <- ensureMissionDirectory directory
        case prepared of
          Left message -> pure (Left message)
          Right () -> writeMissionRecord path missionSnapshotSchemaVersion snapshot
  where
    mission = snapshot.missionSnapshotId

-- | Reads a mission's snapshot, and will not hand back one whose sessions are
-- not a tree.
--
-- Refusing on the way in as well as on the way out is not belt and braces. The
-- writer's guarantee only covers records this release wrote; a snapshot that
-- was restored, edited, or truncated and repaired by hand arrives with no such
-- history, and 'deleteMission' decides from exactly this value. An invalid
-- lineage makes \"which sessions does this mission own?\" a question with no
-- answer — two nodes claiming one identity, a parent that resolves to nothing,
-- a lineage that loops — and answering it wrong is how a delete removes the
-- only record of a session that is still running. It is reported rather than
-- read as absent, because a file that is there and does not cohere is a
-- repair someone has to make.
readMissionSnapshot :: MissionStore -> MissionId -> IO (MissionRead MissionSnapshot)
readMissionSnapshot store mission =
  withMissionRoot store mission MissionUnreadable $ \root ->
    case missionSnapshotPath root mission of
      Left message -> pure (MissionUnreadable message)
      Right path -> do
        result <-
          readMissionRecordFor
            mission
            [missionSnapshotSchemaVersion]
            store.missionStoreRepository
            missionSnapshotId
            missionSnapshotRepository
            path
        pure $ case result of
          MissionPresent snapshot
            | Just reason <- sessionTreeFailure snapshot ->
                MissionUnreadable
                  ( "mission "
                      <> mission.unMissionId
                      <> ": "
                      <> Text.pack path
                      <> " records sessions that are not a tree: "
                      <> reason
                  )
          other -> other

-- | Appends one event to a mission's journal.
recordMissionEvent :: MissionStore -> MissionEvent -> IO (Either Text ())
recordMissionEvent store event =
  withMissionRoot store mission Left $ \root ->
    case (,) <$> missionDirectory root mission <*> missionJournalPath root mission
      <* belongsHere store mission event.missionEventRepository of
      Left message -> pure (Left message)
      Right (directory, path) -> do
        prepared <- ensureMissionDirectory directory
        case prepared of
          Left message -> pure (Left message)
          Right () -> appendMissionEvent path event
  where
    mission = event.missionEventMission

-- | The complete journal records appended since @consumedBytes@, and the new
-- offset.
--
-- A record that was still being appended when this read ran is not in the
-- result and not consumed: the returned offset stops at the last newline, so
-- the very next read sees that record whole, once, rather than a truncated
-- version of it now and a duplicate later.
readMissionJournal :: MissionStore -> MissionId -> Int -> IO (Either Text ([MissionJournalLine], Int))
readMissionJournal store mission consumedBytes =
  withMissionRoot store mission Left $ \root -> case missionJournalPath root mission of
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
  withMissionRoot store mission (Left . MissionSealPathRefused) $ \root ->
    case (,,) <$> missionArchiveDirectory root mission
      <*> missionArchivePath root mission session kind
      <*> missionSealPath root mission session kind of
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
readMissionSealedArchives store mission =
  withMissionRoot store mission Left $ \root -> case missionArchiveDirectory root mission of
    Left message -> pure (Left message)
    Right archiveDirectory -> do
      entries <- listMissionEntries archiveDirectory
      let sealNames = sort (filter (".seal.json" `isSuffixOfPath`) entries)
      results <- mapM (readSeal root archiveDirectory) sealNames
      pure (collect (zip sealNames results))
  where
    isSuffixOfPath suffix name = suffix `Text.isSuffixOf` Text.pack name
    readSeal root archiveDirectory name = do
      result <-
        readMissionRecordFor
          mission
          [missionSealSchemaVersion]
          store.missionStoreRepository
          missionSealedMission
          missionSealedRepository
          (archiveDirectory </> name)
      pure $ case result of
        MissionPresent sealed
          | Just reason <- sealSubjectFailure root mission name sealed -> MissionUnreadable reason
        other -> other

    collect pairs = case [message | (_, MissionUnreadable message) <- pairs] of
      message : _ -> Left message
      [] -> case [message | (_, MissionRefused message) <- pairs] of
        message : _ -> Left message
        [] -> Right [sealed | (_, MissionPresent sealed) <- pairs]

-- | Why a seal record does not describe the entry it was read as, if it does
-- not.
--
-- Two ways it can fail, and both are the same mistake seen from opposite ends:
-- a record whose session and log kind do not name the file it was found under,
-- and a record whose recorded archive name is not the one its own session and
-- log kind produce. 'verifyMissionSealedArchive' already refuses to read a
-- file a record merely names, but a record handed back to a collector is data
-- that collector will act on, so an entry that does not describe itself is
-- reported here rather than returned for something else to be misled by.
sealSubjectFailure :: FilePath -> MissionId -> FilePath -> MissionSealedArchive -> Maybe Text
sealSubjectFailure root mission name sealed = case (,) <$> sealPath <*> archivePath of
  Left message -> Just message
  Right (canonicalSeal, canonicalArchive)
    | takeFileName canonicalSeal /= name ->
        Just (disagrees ("it was read from " <> Text.pack (show name)))
    | sealed.missionSealedName /= takeFileName canonicalArchive ->
        Just (disagrees ("it names the archived file " <> Text.pack (show sealed.missionSealedName)))
    | otherwise -> Nothing
  where
    sealPath = missionSealPath root mission sealed.missionSealedSession sealed.missionSealedKind
    archivePath = missionArchivePath root mission sealed.missionSealedSession sealed.missionSealedKind
    disagrees detail =
      "mission "
        <> mission.unMissionId
        <> ": a seal for session "
        <> sealed.missionSealedSession.unMissionSessionId
        <> " does not describe the entry it was read as, because "
        <> detail

-- | Re-reads an archived copy and checks it against what the seal recorded.
--
-- The archived copy is what is verified — never the source, which the whole
-- point of a seal is to outlive.
verifyMissionSealedArchive :: MissionStore -> MissionId -> MissionSealedArchive -> IO (Either Text ())
verifyMissionSealedArchive store mission sealed =
  withMissionRoot store mission Left $ \root ->
    case missionArchivePath root mission sealed.missionSealedSession sealed.missionSealedKind of
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
  | -- | This mission's records are still under the ambiguous root every
    -- repository whose owner and name fall the same way shared before #615.
    -- Nothing there can be proven to be this repository's alone, so nothing
    -- there is removed.
    MissionDispositionAmbiguousRoot FilePath
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
  MissionDispositionAmbiguousRoot root ->
    "its records are under "
      <> Text.pack root
      <> ", the root every repository whose owner and name fall the same way shared before #615,"
      <> " and nothing there can be proven to be this repository's alone"

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
--
-- A mission still living under the ambiguous pre-#615 root is refused outright,
-- and that refusal comes before every other gate because it is not about this
-- mission's state. That root is shared by every repository whose owner and name
-- fall the same way, and a delete removes a /directory/ — not the records this
-- store checked the identity of on the way in. Nothing in a shared directory
-- can be proven to be this repository's alone: the journal, the invocation log
-- and the sealed archives are only ever read record by record, a submitted
-- command and the control token name no repository at all, a record written
-- under a schema version this release does not recognize says nothing about who
-- wrote it, an unterminated tail is a record that was never decoded, and a
-- subdirectory that cannot be listed is not a subdirectory that is empty. Each
-- of those is a way to mistake \"I could not tell\" for \"it is mine\", and the
-- only answer that cannot be got wrong is to remove nothing there. That is also
-- the strongest reading of #615's requirement that history which cannot be
-- attributed be preserved rather than discarded.
--
-- The mission stays readable, writable and enumerable exactly as before; it is
-- removal, and only removal, that this refuses. Clearing one out is an
-- operator's decision about a directory two repositories may have written to,
-- which is a judgement this release has no evidence to make.
deleteMission :: MissionStore -> MissionId -> IO (Either [MissionDispositionRefusal] ())
deleteMission store mission =
  withMissionRoot store mission (Left . pure . MissionDispositionUnreadable) $ \root ->
    if root == store.missionStoreLegacyDirectory
      then pure (Left [MissionDispositionAmbiguousRoot root])
      else do
        snapshotResult <- readMissionSnapshot store mission
        case snapshotResult of
          MissionPresent snapshot -> case terminalRefusals snapshot <> sessionRefusals snapshot <> stepRefusals snapshot <> worktreeRefusals snapshot of
            refusal : rest -> pure (Left (refusal : rest))
            [] -> case missionDirectory root mission of
              Left message -> pure (Left [MissionDispositionUnreadable message])
              Right directory -> removeMissionDirectory store directory
          other -> pure (Left [unreadableRefusal mission other])

-- | Takes a mission out of the store in one move, and then clears up.
--
-- The rename is what the delete /is/: after it the mission is gone from
-- everything that reads this store, and the recursive removal that follows is
-- housekeeping. Removing in place instead would make a delete that was
-- interrupted — or that could not remove some one file — leave a mission
-- behind with only part of itself, and such a mission is stranded rather than
-- half-deleted: it still enumerates, its snapshot no longer reads, and every
-- gate that would let it be deleted again decides from that snapshot.
--
-- The holding area is the missions root's own, outside every repository's
-- namespace rather than inside or beside one, so a mission on its way out is
-- never enumerated as one that is still there and no repository can be named
-- such that its store /is/ the holding area. Nothing reads it, and a removal
-- that fails leaves it as inert litter rather than as a mission.
removeMissionDirectory :: MissionStore -> FilePath -> IO (Either [MissionDispositionRefusal] ())
removeMissionDirectory store directory = do
  token <- deletionToken
  let holding = store.missionStoreHoldingDirectory
      aside = holding </> token
  prepared <- ensureMissionDirectory holding
  case prepared of
    Left message -> pure (Left [MissionDispositionUnreadable message])
    Right () -> do
      moved <- try @IOException (renameDirectory directory aside)
      case moved of
        Left exception -> pure (Left [MissionDispositionUnreadable (Text.pack (show exception))])
        Right () -> do
          ignoreFileOperation (removePathForcibly aside)
          pure (Right ())

deletionToken :: IO FilePath
deletionToken = do
  now <- getCurrentTime
  processId <- getProcessID
  pure (filter (`notElem` ("-:. TZ" :: String)) (show now) <> "-" <> show processId)

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
