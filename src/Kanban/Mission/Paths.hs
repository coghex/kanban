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
    ensureMissionDirectory,
    listMissionEntries,
    ignoreFileOperation,
  )
where

import Control.Exception (IOException, try)
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
import System.Directory
  ( XdgDirectory (XdgState),
    doesDirectoryExist,
    getXdgDirectory,
    listDirectory,
    renameFile,
  )
import System.FilePath ((</>))
import System.IO (hClose)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Files (setFdMode, setFileMode)
import System.Posix.IO
  ( OpenFileFlags (creat, exclusive),
    OpenMode (WriteOnly),
    closeFd,
    defaultFileFlags,
    fdToHandle,
    openFd,
  )

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
-- record that decodes but names another repository is refused rather than
-- adopted.
readMissionRecordFor ::
  FromJSON value =>
  MissionId ->
  [Int] ->
  MissionRepository ->
  (value -> MissionRepository) ->
  FilePath ->
  IO (MissionRead value)
readMissionRecordFor mission recognized expected recordedRepository path = do
  result <- readMissionRecord mission recognized path
  pure $ case result of
    MissionPresent value
      | not (missionRepositoryMatches (recordedRepository value) expected) ->
          MissionRefused
            ( "mission "
                <> mission.unMissionId
                <> " at "
                <> Text.pack path
                <> " is recorded against another repository and was not adopted"
            )
    other -> other

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

-- | Writes one versioned record atomically, user-only: a temporary file
-- beside the target, its mode forced to @0600@ before it holds anything the
-- caller cares about, then a rename.
--
-- An interrupted write therefore leaves whatever was at @path@ exactly as it
-- was, which is what requirement 3 asks of a snapshot replacement.
writeMissionRecord :: ToJSON value => FilePath -> Int -> value -> IO (Either Text ())
writeMissionRecord path version value = do
  let temporary = path <> ".tmp"
  result <- try @IOException $ do
    LazyByteString.writeFile temporary (encode (MissionEnvelope version value))
    setFileMode temporary 0o600
    renameFile temporary path
  pure (either (Left . Text.pack . show) Right result)

-- | Writes one versioned record exactly once, refusing to replace an
-- existing one.
--
-- @O_CREAT | O_EXCL@ rather than a rename, because a rename would happily
-- replace the file it lands on: a specification is written once (requirement
-- 2), and a second creation for the same mission identifier must fail
-- /without changing the original/. The exclusive create is also what makes
-- the refusal atomic between two processes racing the same identifier.
--
-- The interrupted case is covered by the same call: a crash before the write
-- completes leaves a file this reader rejects as undecodable rather than a
-- half-specification it would adopt, and the file exists, so a later attempt
-- is refused rather than quietly filling it in with different content.
createMissionRecord :: ToJSON value => FilePath -> Int -> value -> IO (Either Text Bool)
createMissionRecord path version value = do
  opened <- try @IOException (openFd path WriteOnly defaultFileFlags {creat = Just 0o600, exclusive = True})
  case opened of
    Left exception
      | isAlreadyExistsError exception -> pure (Right False)
      | otherwise -> pure (Left (Text.pack (show exception)))
    Right descriptor -> do
      -- The mode is forced on the descriptor just opened rather than
      -- re-resolved by path, so it always lands on the file this call
      -- created, and it is forced before a byte of the record is written.
      handleResult <- try @IOException (setFdMode descriptor 0o600 >> fdToHandle descriptor)
      case handleResult of
        Left exception -> do
          ignoreFileOperation (closeFd descriptor)
          pure (Left (Text.pack (show exception)))
        Right handle -> do
          written <- try @IOException (LazyByteString.hPut handle (encode (MissionEnvelope version value)))
          closed <- try @IOException (hClose handle)
          pure $ case (written, closed) of
            (Left exception, _) -> Left (Text.pack (show exception))
            (_, Left exception) -> Left (Text.pack (show exception))
            (Right (), Right ()) -> Right True

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
