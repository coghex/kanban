-- | Where a repository's missions live, and the read and write primitives
-- every other mission module persists through.
--
-- Two decisions are made here and nowhere else.
--
-- The store is under @$XDG_STATE_HOME@ rather than the cache. Mission history
-- must outlive the worker cache's fourteen-day collection
-- (@workerRetentionSeconds@ in "Kanban.Worker.Discovery"), and §17's PR
-- drainer already sets the precedent: durable per-repository status lives in
-- the state root while the data root holds only an installer's discovery
-- record. @XdgState@ is why @kanban.cabal@ bounds @directory@ at @>= 1.3.7@:
-- that is the first release providing it, and the bound this replaced admitted
-- versions where 'getXdgDirectory' has no such constructor. (The bound carries
-- no comment of its own because a whole-line comment inside a
-- @build-depends:@ block is read as a dependency by
-- @test\/Spec\/Design\/Witnesses.hs@.)
--
-- Every path derived from a 'MissionId' is validated as a single plain name
-- first. A mission identifier reaches this module from durable records and,
-- later, from a planner; treating one as a path fragment without that check is
-- how a store escapes its own directory.
--
-- Deliberately the lowest layer above "Kanban.Mission.Types": the journal,
-- lease, session and store seams all persist through these, so keeping them
-- here is what lets those modules depend on one another without a cycle.
--
-- This module is internal — "Kanban.Mission" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Mission.Paths
  ( -- * The store
    missionStoreRoot,
    missionStoreKey,
    missionDirectory,
    missionSpecificationPath,
    missionSnapshotPath,
    missionJournalPath,
    missionLeasePath,
    missionLeaseOwnerPath,
    missionArchiveDirectory,
    missionArchivePath,
    missionSealPath,
    safeMissionComponent,

    -- * Reading a versioned record
    MissionRead (..),
    readMissionRecord,
    readMissionRecordFor,

    -- * Writing
    writeMissionRecord,
    createMissionRecord,
    withStagedContent,
    commitNoReplace,
    ensureMissionDirectory,
    listMissionEntries,
    ignoreFileOperation,
  )
where

import Control.Exception (IOException, finally, throwIO, try)
import Control.Monad (void)
import Data.Aeson (FromJSON, Result (Error, Success), ToJSON, Value (Object), eitherDecodeStrict', encode, fromJSON)
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Domain (Repository (..))
import Kanban.Mission.Types
  ( MissionEnvelope (..),
    MissionId (..),
    MissionLogKind,
    MissionRepository,
    MissionSessionId (..),
    missionLogKindTag,
    missionRepositoryMatches,
  )
import Kanban.Paths (createPrivateDirectory)
import Data.Time (getCurrentTime)
import System.Directory
  ( XdgDirectory (XdgState),
    doesDirectoryExist,
    getXdgDirectory,
    listDirectory,
    removeFile,
    renameFile,
  )
import System.FilePath ((</>))
import System.IO (Handle, hClose, hSetBinaryMode)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Files (createLink, setFdMode)
import System.Posix.IO
  ( OpenFileFlags (creat, exclusive),
    OpenMode (WriteOnly),
    closeFd,
    defaultFileFlags,
    fdToHandle,
    openFd,
  )
import System.Posix.Process (getProcessID)

-- | @$XDG_STATE_HOME/kanban/missions/<owner>-<repo>@.
--
-- The key is derived from the repository's owner and name exactly as
-- @Kanban.Worker.Paths.workerDirectory@ derives its own, so the two private
-- roots name the same repository the same way.
missionStoreRoot :: Repository -> IO FilePath
missionStoreRoot repository = do
  stateRoot <- getXdgDirectory XdgState "kanban"
  pure (stateRoot </> "missions" </> missionStoreKey repository)

-- | The one path component a repository maps to.
--
-- The replacement set is @Kanban.Worker.Paths.safeKey@'s. Restated rather
-- than imported because the worker cache's key is that subsystem's on-disk
-- compatibility surface: sharing the function would make any later change to
-- one root's naming silently rename the other's directories too, which for a
-- durable store is data loss rather than a rename.
missionStoreKey :: Repository -> FilePath
missionStoreKey repository =
  Text.unpack (Text.map replace (repository.repositoryOwner <> "-" <> repository.repositoryName))
  where
    replace character
      | character `elem` ['/', '\\', ':', ' '] = '-'
      | otherwise = character

-- | Rejects anything that is not a plain name inside the directory it would
-- sit in: the empty string, the two entries every directory has, and any
-- separator or NUL a recorded identifier could carry to escape the store.
safeMissionComponent :: FilePath -> Bool
safeMissionComponent name =
  not (null name)
    && name `notElem` [".", ".."]
    && not (any (`elem` ("/\\\NUL" :: String)) name)

-- | One mission's directory inside @store@, or the reason its identifier
-- cannot name one.
--
-- Every other path below is built from this, so no mission path exists that
-- this check did not pass.
missionDirectory :: FilePath -> MissionId -> Either Text FilePath
missionDirectory store mission
  | safeMissionComponent name = Right (store </> name)
  | otherwise =
      Left
        ( "mission identifier "
            <> Text.pack (show mission.unMissionId)
            <> " is not a single plain name and cannot address a mission directory"
        )
  where
    name = Text.unpack mission.unMissionId

missionSpecificationPath, missionSnapshotPath, missionJournalPath, missionLeasePath, missionLeaseOwnerPath, missionArchiveDirectory :: FilePath -> MissionId -> Either Text FilePath
missionSpecificationPath store mission = (</> "specification.json") <$> missionDirectory store mission
missionSnapshotPath store mission = (</> "snapshot.json") <$> missionDirectory store mission
missionJournalPath store mission = (</> "events.jsonl") <$> missionDirectory store mission
missionLeasePath store mission = (</> "lease") <$> missionDirectory store mission
missionLeaseOwnerPath store mission = (</> "owner.json") <$> missionLeasePath store mission
missionArchiveDirectory store mission = (</> "archive") <$> missionDirectory store mission

-- | The archived copy of one session's log, and the seal record beside it.
--
-- The name is the session identifier and the log kind, both validated as one
-- plain component, so a session named from a provider's own identifier can
-- never address a file outside the archive.
missionArchivePath :: FilePath -> MissionId -> MissionSessionId -> MissionLogKind -> Either Text FilePath
missionArchivePath store mission session kind = do
  directory <- missionArchiveDirectory store mission
  name <- missionArchiveName session kind
  pure (directory </> name <> ".log")

missionSealPath :: FilePath -> MissionId -> MissionSessionId -> MissionLogKind -> Either Text FilePath
missionSealPath store mission session kind = do
  directory <- missionArchiveDirectory store mission
  name <- missionArchiveName session kind
  pure (directory </> name <> ".seal.json")

missionArchiveName :: MissionSessionId -> MissionLogKind -> Either Text FilePath
missionArchiveName session kind
  | safeMissionComponent name = Right name
  | otherwise =
      Left
        ( "session identifier "
            <> Text.pack (show session.unMissionSessionId)
            <> " is not a single plain name and cannot address a sealed archive"
        )
  where
    name = Text.unpack (session.unMissionSessionId <> "-" <> missionLogKindTag kind)

-- | Creates a mission's directory with @0700@ on every level below the XDG
-- state root, whatever the umask and whichever writer created it first.
ensureMissionDirectory :: FilePath -> IO (Either Text ())
ensureMissionDirectory directory = do
  created <- try @IOException (createPrivateDirectory XdgState directory)
  pure (either (Left . Text.pack . show) Right created)

-- | What one durable mission record turned out to be.
--
-- Four answers rather than three, because \"this file is not for you\" and
-- \"this file is broken\" call for different repairs and requirement 11 of
-- issue #592 asks for both.
data MissionRead value
  = -- | No file, or a file whose schema version this release does not
    -- recognize. Silent, exactly as a missing file is: §16's rule is that a
    -- record another release wrote says nothing rather than complaining.
    MissionAbsent
  | -- | Decoded, but recorded against another repository. Refused rather
    -- than adopted.
    MissionRefused Text
  | -- | Unreadable, carrying no integer @schemaVersion@, or failing to
    -- decode under a version this release does recognize. Names the mission
    -- and the file.
    MissionUnreadable Text
  | MissionPresent value
  deriving stock (Eq, Functor, Show)

-- | Reads one versioned record, deciding on the version before the payload.
--
-- The order is the whole point. @schemaVersion@ is read out of the JSON
-- object first, and a version this release does not recognize returns
-- 'MissionAbsent' without the payload ever being decoded — so a record whose
-- shape a later release changed beyond recognition is silent rather than
-- reported as corruption. Only once the version is recognized is the payload
-- decoded, and a failure there is a genuine decode failure and keeps its
-- diagnostic.
readMissionRecord :: FromJSON value => MissionId -> [Int] -> FilePath -> IO (MissionRead value)
readMissionRecord mission recognized path = do
  bytesResult <- try @IOException (ByteString.readFile path)
  pure $ case bytesResult of
    -- A file that is not there has nothing to say. Every other read failure —
    -- a permission the store lost, a directory where a file belongs — is
    -- reported, because the repair for it is not the repair for a mission
    -- that was never written.
    Left exception
      | isDoesNotExistError exception -> MissionAbsent
      | otherwise ->
          MissionUnreadable
            ( "mission "
                <> mission.unMissionId
                <> ": "
                <> Text.pack path
                <> " could not be read ("
                <> Text.pack (show exception)
                <> ")"
            )
    Right bytes -> readBytes mission recognized path bytes

-- | 'readMissionRecord' with requirement 11's identity refusal applied: a
-- record that decodes but is not this mission's, in this repository, is
-- refused rather than adopted.
--
-- Both halves of the identity are checked, and the mission half is not a
-- formality. A record carries the mission it describes, and where it /sits/ is
-- the mission it will be read as; a store restored from a backup, a directory
-- copied to try something out, or a file moved by hand can make those two
-- disagree. Adopting such a record would let one mission's terminal snapshot
-- authorise archiving or deleting another, which is the one place a read is
-- allowed to destroy something.
readMissionRecordFor ::
  FromJSON value =>
  MissionId ->
  [Int] ->
  MissionRepository ->
  (value -> MissionId) ->
  (value -> MissionRepository) ->
  FilePath ->
  IO (MissionRead value)
readMissionRecordFor mission recognized expected recordedMission recordedRepository path = do
  result <- readMissionRecord mission recognized path
  pure $ case result of
    MissionPresent value
      | not (missionRepositoryMatches (recordedRepository value) expected) ->
          refused "another repository"
      | recordedMission value /= mission ->
          refused ("the mission " <> (recordedMission value).unMissionId)
    other -> other
  where
    refused subject =
      MissionRefused
        ( "mission "
            <> mission.unMissionId
            <> " at "
            <> Text.pack path
            <> " is recorded against "
            <> subject
            <> " and was not adopted"
        )

-- | The pure half of 'readMissionRecord', separated so the decision order is
-- readable without the IO around it.
readBytes :: forall value. FromJSON value => MissionId -> [Int] -> FilePath -> ByteString.ByteString -> MissionRead value
readBytes mission recognized path bytes = case eitherDecodeStrict' bytes :: Either String Value of
  Left message -> unreadable ("is not JSON (" <> Text.pack message <> ")")
  Right (Object fields) -> case KeyMap.lookup "schemaVersion" fields of
    Nothing -> unreadable "carries no schemaVersion"
    Just versionValue -> case fromJSON versionValue :: Result Int of
      Error _ -> unreadable "carries a schemaVersion that is not an integer"
      Success version
        | version `notElem` recognized -> MissionAbsent
        | otherwise -> case eitherDecodeStrict' bytes of
            Left message ->
              unreadable
                ( "did not decode under schema version "
                    <> Text.pack (show version)
                    <> " ("
                    <> Text.pack message
                    <> ")"
                )
            Right envelope -> MissionPresent (missionEnvelopePayload (envelope :: MissionEnvelope value))
  Right _ -> unreadable "is not a JSON object"
  where
    unreadable detail =
      MissionUnreadable ("mission " <> mission.unMissionId <> ": " <> Text.pack path <> " " <> detail)

-- | Stages @content@ in a private file beside @path@ and commits it with
-- @commit@.
--
-- Every write in this store goes through here, and the shape is what makes two
-- separate guarantees hold at once.
--
-- The staging file is opened @O_CREAT | O_EXCL@ with mode @0600@ and its mode
-- is forced on that descriptor before a byte is written, so the file is
-- user-only from the instant it exists rather than from whenever a later
-- @chmod@ arrives. Nothing tightens it afterwards, deliberately: both commits
-- below — a rename and a hard link — carry the staged /inode/ to the final
-- path, so the committed file's mode is the staged file's mode and the
-- permission the store promises is the one it was created with. A staging file
-- a crash leaves behind is @0600@ for the same reason.
--
-- The name carries this process and a timestamp so two writers never stage
-- into one file and interleave, and the exclusive create refuses a collision
-- rather than truncating whatever it found.
--
-- The staging file is removed on the way out whether or not the commit
-- happened. After a rename there is nothing left to remove; after a link, or
-- after a commit that failed, the copy is this call's litter and no reader's
-- record.
withStagedContent :: FilePath -> LazyByteString.ByteString -> (FilePath -> IO result) -> IO (Either Text result)
withStagedContent path content commit = do
  result <- try @IOException $ do
    (staged, handle) <- openPrivateStagingFile path
    ( do
        LazyByteString.hPut handle content
        hClose handle
        commit staged
      )
      `finally` (ignoreFileOperation (hClose handle) >> ignoreFileOperation (removeFile staged))
  pure (either (Left . Text.pack . show) Right result)

openPrivateStagingFile :: FilePath -> IO (FilePath, Handle)
openPrivateStagingFile path = do
  processId <- getProcessID
  now <- getCurrentTime
  attempt (path <> ".staged-" <> show processId <> "-" <> stamp now) (0 :: Int)
  where
    stamp = filter (`notElem` ("-:. TZ" :: String)) . show
    attempt base attemptsMade = do
      let candidate = if attemptsMade == 0 then base else base <> "-" <> show attemptsMade
      opened <- try @IOException (openFd candidate WriteOnly defaultFileFlags {creat = Just 0o600, exclusive = True})
      case opened of
        Left exception
          | isAlreadyExistsError exception && attemptsMade < 32 -> attempt base (attemptsMade + 1)
          | otherwise -> throwIO exception
        Right descriptor -> do
          setFdMode descriptor 0o600
          handle <- try @IOException (fdToHandle descriptor)
          case handle of
            Left exception -> ignoreFileOperation (closeFd descriptor) >> throwIO exception
            Right opening -> do
              hSetBinaryMode opening True
              pure (candidate, opening)

-- | Replaces whatever is at @path@ with one versioned record, atomically.
--
-- The record is complete before the rename that publishes it, so an
-- interrupted write leaves whatever was at @path@ exactly as it was — which is
-- what requirement 3 of issue #592 asks of a snapshot replacement — and a
-- reader never observes a record half-way between two states.
writeMissionRecord :: ToJSON value => FilePath -> Int -> value -> IO (Either Text ())
writeMissionRecord path version value =
  withStagedContent path (encode (MissionEnvelope version value)) (`renameFile` path)

-- | Publishes one versioned record at @path@ exactly once, refusing to replace
-- an existing one.
--
-- The commit is a hard link rather than a rename, and that is the whole
-- design: @link@ is atomic and it /fails/ when the target exists, where a
-- rename would happily replace it. A specification is written once
-- (requirement 2), and a second creation for the same mission identifier must
-- fail without changing the original — including when two processes race the
-- same identifier, which the kernel settles here rather than a check-then-act
-- this code could be interrupted inside.
--
-- Interruption is covered by the same shape. The bytes are written into the
-- staging file, so a crash before the link leaves no @path@ at all: nothing
-- partial is ever published, and — the failure mode a check-then-act over the
-- final path would have caused — the retry after that crash creates the
-- specification rather than reporting one already there.
createMissionRecord :: ToJSON value => FilePath -> Int -> value -> IO (Either Text Bool)
createMissionRecord path version value =
  withStagedContent path (encode (MissionEnvelope version value)) (`commitNoReplace` path)

-- | Publishes @staged@ at @path@ if nothing is there, reporting whether it
-- did.
--
-- A hard link rather than a rename, and that is the whole point: @link@ is
-- atomic and it /fails/ when the target exists, where a rename would replace
-- it. Two processes racing one path are settled by the kernel here, not by a
-- check-then-act this code could be interrupted inside, and a file this store
-- promises never to replace is a file nothing published through here can
-- replace.
commitNoReplace :: FilePath -> FilePath -> IO Bool
commitNoReplace staged path = do
  linked <- try @IOException (createLink staged path)
  case linked of
    Right () -> pure True
    Left exception
      | isAlreadyExistsError exception -> pure False
      | otherwise -> throwIO exception

-- | Every entry of the store that is a plain name.
--
-- Nothing here follows what it finds: the caller decides what to do with each
-- name, and 'listMissionEntries' never resolves one.
listMissionEntries :: FilePath -> IO [FilePath]
listMissionEntries store = do
  exists <- doesDirectoryExist store
  if not exists
    then pure []
    else either (const []) (filter safeMissionComponent) <$> try @IOException (listDirectory store)

ignoreFileOperation :: IO () -> IO ()
ignoreFileOperation operation = void (try @IOException operation)
