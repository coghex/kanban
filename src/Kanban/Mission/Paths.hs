-- | Where a repository's missions live, and the read and write primitives
-- every other mission module persists through.
--
-- Three decisions are made here and nowhere else.
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
-- how a store escapes its own directory. The repository's own owner and name
-- are held to the same check, for the same reason and one level up.
--
-- A repository spells its root as separate path components under
-- @repositories@, and that spelling is injective — see 'missionStoreKey' for
-- why it has to be, and 'missionRoot' for what happens to a mission written
-- under the ambiguous one this replaced.
--
-- Deliberately the lowest layer above "Kanban.Mission.Types": the journal,
-- lease, session and store seams all persist through these, so keeping them
-- here is what lets those modules depend on one another without a cycle.
--
-- This module is internal — "Kanban.Mission" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Mission.Paths
  ( -- * The store
    MissionStore (..),
    openMissionStore,
    missionStoreRoot,
    missionStoreKey,
    missionRoot,
    withMissionRoot,
    adoptedLegacyMissions,
    LegacyClaim (..),
    legacyMissionClaim,
    missionDirectory,
    missionSpecificationPath,
    missionSnapshotPath,
    missionJournalPath,
    missionInvocationPath,
    missionControlDirectory,
    missionControlTokenPath,
    missionControlRequestDirectory,
    missionNotificationDirectory,
    missionNotificationPath,
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
    listMissionEntriesStrictly,
    isPlainDirectory,
    MissionEntry (..),
    missionEntryAt,
    ignoreFileOperation,
  )
where

import Control.Exception (IOException, finally, throwIO, try)
import Control.Monad (filterM, void)
import Data.Aeson (FromJSON, Result (Error, Success), ToJSON, Value (Object), eitherDecodeStrict', encode, fromJSON)
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Domain (Repository (..))
import Kanban.Mission.Types
  ( MissionEnvelope (..),
    MissionId (..),
    MissionLeaseOwner (..),
    MissionLogKind,
    MissionRepository (..),
    MissionSessionId (..),
    MissionSnapshot (..),
    MissionSpecification (..),
    missionLeaseSchemaVersion,
    missionLogKindTag,
    missionRepository,
    missionRepositoryMatches,
    missionSnapshotSchemaVersion,
    missionSpecificationSchemaVersion,
  )
import Kanban.Paths (createPrivateDirectory)
import Data.Time (getCurrentTime)
import System.Directory
  ( XdgDirectory (XdgState),
    getXdgDirectory,
    listDirectory,
    removeFile,
    renameFile,
  )
import System.FilePath ((</>))
import System.IO (Handle, hClose, hSetBinaryMode)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Files (createLink, getSymbolicLinkStatus, isDirectory, setFdMode)
import System.Posix.IO
  ( OpenFileFlags (creat, exclusive),
    OpenMode (WriteOnly),
    closeFd,
    defaultFileFlags,
    fdToHandle,
    openFd,
  )
import System.Posix.Process (getProcessID)

-- | One repository's mission store: where it is, and whose it is.
--
-- The repository identity is carried rather than re-derived at each read,
-- because it is what requirement 11's refusal compares against and a second
-- derivation is a second chance to disagree. It lives here rather than beside
-- the operations because the lease is bound to it too, and a lease that could
-- not name the repository it belongs to could be retired on another
-- repository's evidence.
--
-- Three directories rather than one, because two of them are outside this
-- repository's own root and neither is derivable from it. The legacy directory
-- is the ambiguous root the spelling before #615 wrote to, which
-- 'missionRoot' consults per mission; the holding directory is where a delete
-- moves a mission aside to, and it must sit outside every repository's
-- namespace rather than beside one of them.
data MissionStore = MissionStore
  { missionStoreDirectory :: FilePath,
    -- | @$XDG_STATE_HOME\/kanban\/missions\/<owner>-<repo>@: the root this
    -- repository's missions were written under before #615, shared with every
    -- other repository whose owner and name fall the same way. Read per
    -- mission and never adopted wholesale; see 'missionRoot'.
    missionStoreLegacyDirectory :: FilePath,
    -- | @$XDG_STATE_HOME\/kanban\/missions\/.deleted@: where a mission on
    -- its way out is moved to, one rename, before it is cleared up.
    missionStoreHoldingDirectory :: FilePath,
    missionStoreRepository :: MissionRepository
  }
  deriving stock (Eq, Show)

-- | Resolves and creates a repository's store, @0700@ on every level below the
-- XDG state root.
--
-- An identity that cannot name a safe path component is refused here, before
-- anything is created: requirement 2 of issue #615 is that such an identity
-- reports a reason rather than being mapped onto another repository's root,
-- and a refusal that had already made a directory would have written into the
-- missions tree on the strength of a name it just rejected.
openMissionStore :: Repository -> IO (Either Text MissionStore)
openMissionStore repository = case missionStoreKey repository of
  Left message -> pure (Left message)
  Right key -> do
    missions <- missionsDirectory
    let root = missions </> key
        store =
          MissionStore
            { missionStoreDirectory = root,
              missionStoreLegacyDirectory = missions </> legacyMissionStoreKey (missionRepository repository),
              missionStoreHoldingDirectory = missions </> deletedMissionsName,
              missionStoreRepository = missionRepository repository
            }
    prepared <- ensureMissionDirectory root
    pure (store <$ prepared)

-- | @$XDG_STATE_HOME\/kanban\/missions@: the one directory every root below
-- sits in, this release's and the one before it.
missionsDirectory :: IO FilePath
missionsDirectory = do
  stateRoot <- getXdgDirectory XdgState "kanban"
  pure (stateRoot </> "missions")

-- | @$XDG_STATE_HOME\/kanban\/missions\/repositories\/<owner>\/<repo>@,
-- or why this repository names no root at all.
missionStoreRoot :: Repository -> IO (Either Text FilePath)
missionStoreRoot repository = case missionStoreKey repository of
  Left message -> pure (Left message)
  Right key -> do
    missions <- missionsDirectory
    pure (Right (missions </> key))

-- | The path a repository maps to under the missions directory, or why it maps
-- to none.
--
-- __The mapping is injective__, and by construction rather than by argument.
-- The owner and the name stay separate path components, and each is refused
-- unless 'safeMissionComponent' passes it — which above all means it carries no
-- separator. A path therefore recovers the pair that produced it, so two
-- identities name one root only when they are the same identity, and every
-- component of that root is a plain name inside the directory above it, which
-- is what keeps the whole of it inside @$XDG_STATE_HOME@.
--
-- That property is the reason this spelling replaced the previous one, and it
-- is recorded here because this is the one place that decides it.
-- 'legacyMissionStoreKey' joined the owner to the name with a hyphen it also
-- substituted for separators, which is not injective at all: @data-science\/tools@
-- and @data\/science-tools@ both wrote @data-science-tools@, so one
-- repository's durable snapshot replaced the other's, one repository's
-- specification made the other's mission report that it already existed, and
-- one repository's lease blocked the other's unrelated mission (#615).
--
-- The @repositories@ segment is what keeps the two namespaces from aliasing.
-- Every key the old spelling could produce contains the hyphen it joined owner
-- to name with, and @repositories@ contains none, so no legacy root is ever a
-- new root's first segment; the same argument covers @.deleted@, the holding
-- area a delete moves a mission through.
missionStoreKey :: Repository -> Either Text FilePath
missionStoreKey repository
  | not (safeMissionComponent owner) = Left (refusal "owner" repository.repositoryOwner)
  | not (safeMissionComponent name) = Left (refusal "name" repository.repositoryName)
  | otherwise = Right ("repositories" </> owner </> name)
  where
    owner = Text.unpack repository.repositoryOwner
    name = Text.unpack repository.repositoryName
    refusal part value =
      "the repository "
        <> part
        <> " "
        <> Text.pack (show value)
        <> " is not a single plain name and cannot address a mission store"

-- | The one path component a repository mapped to before #615.
--
-- Kept as a derivation rather than as history, because a mission written under
-- it is still read there — see 'missionRoot' — and because the argument that
-- the two namespaces cannot alias is an argument about this function's range.
--
-- The replacement set is @Kanban.Worker.Paths.safeKey@'s, which still spells
-- the collectable worker cache's directories this way (#615 leaves that one
-- alone deliberately). Restated rather than imported for the reason it always
-- was: sharing the function would make any later change to one root's naming
-- silently rename the other's directories too, which for a durable store is
-- data loss rather than a rename — and here it would silently move the very
-- history this function exists to keep reachable.
legacyMissionStoreKey :: MissionRepository -> FilePath
legacyMissionStoreKey repository =
  Text.unpack (Text.map replace (repository.missionRepositoryOwner <> "-" <> repository.missionRepositoryName))
  where
    replace character
      | character `elem` ['/', '\\', ':', ' '] = '-'
      | otherwise = character

-- | The holding area every delete moves a mission through, named once.
--
-- At the missions root rather than beside a repository's own store: a
-- repository may legitimately be named @.deleted@ — GitHub allows a leading
-- dot, which is how @.github@ exists — and a holding area inside the owner's
-- directory would be that repository's store.
deletedMissionsName :: FilePath
deletedMissionsName = ".deleted"

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

missionSpecificationPath, missionSnapshotPath, missionJournalPath, missionInvocationPath, missionLeasePath, missionLeaseOwnerPath, missionArchiveDirectory, missionControlDirectory, missionControlTokenPath, missionControlRequestDirectory, missionNotificationDirectory :: FilePath -> MissionId -> Either Text FilePath
missionSpecificationPath store mission = (</> "specification.json") <$> missionDirectory store mission
missionSnapshotPath store mission = (</> "snapshot.json") <$> missionDirectory store mission
missionJournalPath store mission = (</> "events.jsonl") <$> missionDirectory store mission
missionInvocationPath store mission = (</> "invocations.jsonl") <$> missionDirectory store mission
missionLeasePath store mission = (</> "lease") <$> missionDirectory store mission
missionLeaseOwnerPath store mission = (</> "owner.json") <$> missionLeasePath store mission
missionArchiveDirectory store mission = (</> "archive") <$> missionDirectory store mission
missionControlDirectory store mission = (</> "control") <$> missionDirectory store mission
missionControlTokenPath store mission = (</> "token.json") <$> missionControlDirectory store mission
missionControlRequestDirectory store mission = (</> "requests") <$> missionControlDirectory store mission
missionNotificationDirectory store mission = (</> "notifications") <$> missionDirectory store mission

-- | Where one attention identity's notification record lives.
--
-- Named by a digest of the identity rather than by the identity itself: an
-- attention identity carries a repository, a mission and a timestamp, so it
-- spells @\/@ and @#@ and is not a path component at all. The digest is
-- "Kanban.Mission.Digest"'s, which spawns nothing, and the record inside
-- carries the identity in full so a reader never has to invert it.
--
-- Inside the mission's own directory, so the record travels with the mission:
-- archiving or deleting one takes its notification history with it, and a
-- store restored for another repository carries no suppression that could
-- silence this one.
missionNotificationPath :: FilePath -> MissionId -> Text -> Either Text FilePath
missionNotificationPath store mission digest = do
  directory <- missionNotificationDirectory store mission
  let name = Text.unpack digest <> ".json"
  if safeMissionComponent name
    then Right (directory </> name)
    else Left ("notification identity " <> Text.pack (show digest) <> " cannot name a record file")

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

-- | Which root this mission's records live under: this repository's own, or
-- the ambiguous pre-#615 one when that is where its history was written.
--
-- Issue #615's requirement 4 asked for one of two policies, stated explicitly.
-- This is the compatibility one: nothing is moved, ever. A mission whose
-- records are under the legacy root keeps being read and written there, and
-- only a mission with no legacy history at all is addressed under the
-- repository-qualified root.
--
-- Migration was the alternative and it is unsafe here, for a reason worth
-- recording. The lease is a directory inside the mission's own directory, so
-- moving a mission moves its lease; a holder still running against the old
-- path would go on writing there, recreating the mission under the legacy
-- root while a third process — finding no lease directory where the holder
-- believes it left one — acquired that mission's lease a second time. Reading
-- in place cannot produce that: every process resolves one mission to one
-- directory, so there is exactly one lease per repository-qualified mission
-- whichever release opened it.
--
-- Ownership is established per mission from what the durable records
-- themselves say, never from the legacy root as a whole: that root is shared
-- by every repository whose owner and name fall the same way, and adopting it
-- for whichever repository opened it first is the defect this resolution
-- exists to close. A legacy mission whose records disagree with one another,
-- or that names no repository at all, is attributed to nobody: it is left
-- exactly as it is and every operation on that identifier reports its path and
-- why it was refused, rather than one repository adopting what may be the
-- other's.
missionRoot :: MissionStore -> MissionId -> IO (Either Text FilePath)
missionRoot store mission =
  case (,) <$> missionDirectory store.missionStoreDirectory mission
    <*> missionDirectory store.missionStoreLegacyDirectory mission of
    Left message -> pure (Left message)
    Right (ownDirectory, legacyDirectory) -> do
      -- The common case costs one non-following stat: a repository with no
      -- legacy history reads nothing at all.
      --
      -- Absence is the /only/ answer that routes past the legacy root. A stat
      -- that could not be taken, and an entry present without being a
      -- directory this store could have written, both refuse: reading either
      -- as \"there is nothing there\" would address the new root, and a second
      -- mission — with a second advancement lease — could then be created
      -- beside history nobody could see.
      legacyPresence <- missionEntryAt legacyDirectory
      case legacyPresence of
        MissionEntryUndecidable reason -> pure (Left (undecidable legacyDirectory reason))
        MissionEntryOther -> pure (Left (undecidable legacyDirectory notADirectory))
        MissionEntryAbsent -> pure (Right store.missionStoreDirectory)
        MissionEntryDirectory -> do
          claim <- legacyMissionClaim store.missionStoreRepository mission store.missionStoreLegacyDirectory
          case claim of
            -- Another repository's mission that happens to share this
            -- identifier is invisible here, which is the whole of
            -- requirement 3: this repository addresses its own root and never
            -- learns the other exists.
            LegacyForeign -> pure (Right store.missionStoreDirectory)
            LegacyUnattributable reason -> pure (Left (unattributable legacyDirectory reason))
            LegacyOurs -> do
              ownPresence <- missionEntryAt ownDirectory
              pure $ case ownPresence of
                MissionEntryUndecidable reason -> Left (undecidable ownDirectory reason)
                MissionEntryOther -> Left (undecidable ownDirectory notADirectory)
                MissionEntryDirectory -> Left (bothPlaces ownDirectory legacyDirectory)
                MissionEntryAbsent -> Right store.missionStoreLegacyDirectory
  where
    notADirectory = "it is not a directory this store could have written"
    undecidable directory reason =
      "mission "
        <> mission.unMissionId
        <> ": whether "
        <> Text.pack directory
        <> " holds this mission's history could not be established ("
        <> reason
        <> "), and nothing was read, written, or routed past it"
    unattributable directory reason =
      "mission "
        <> mission.unMissionId
        <> ": the durable records under "
        <> Text.pack directory
        <> " could not be attributed to "
        <> store.missionStoreRepository.missionRepositoryOwner
        <> "/"
        <> store.missionStoreRepository.missionRepositoryName
        <> " ("
        <> reason
        <> "), and were neither adopted nor changed"
    bothPlaces ownDirectory legacyDirectory =
      "mission "
        <> mission.unMissionId
        <> " has durable records under both "
        <> Text.pack ownDirectory
        <> " and "
        <> Text.pack legacyDirectory
        <> ", and neither was read or replaced"

-- | Runs @act@ against the root a mission's records live under, reporting a
-- refusal through @refuse@.
--
-- Every operation resolves through here rather than reaching for
-- 'missionStoreDirectory', which is what stops one operation on a legacy
-- mission from addressing the legacy root while the next addresses the new
-- one — a split that would leave a specification in one place and the snapshot
-- describing it in another.
withMissionRoot :: MissionStore -> MissionId -> (Text -> result) -> (FilePath -> IO result) -> IO result
withMissionRoot store mission refuse act = do
  resolved <- missionRoot store mission
  either (pure . refuse) act resolved

-- | Whose a legacy mission directory is, as its own records report it.
data LegacyClaim
  = LegacyOurs
  | LegacyForeign
  | LegacyUnattributable Text
  deriving stock (Eq, Show)

-- | Reads the durable identity evidence one legacy mission carries.
--
-- Three records, each a single file at a fixed path and each carrying the
-- repository it was written for: the specification, the snapshot, and the
-- lease owner. Any that is present must decode, must name this mission, and
-- must agree with the others; one that does not makes the mission
-- unattributable rather than someone's.
--
-- The journal and the sealed archives carry a repository too and are
-- deliberately not read. Attribution runs on every operation and, for
-- enumeration, once per legacy mission, and a journal is unbounded — reading
-- one to decide where a mission lives would make the cheapest operation in the
-- store cost the whole of its history.
--
-- Nothing is lost by it, and the reason is worth being exact about. A journal
-- line or a seal written for another repository is refused by the identity
-- check every read of one already applies, so no unread record is ever handed
-- back as this repository's. The one operation that would /remove/ such a
-- record without reading it does not run against this root at all:
-- 'Kanban.Mission.Store.deleteMission' refuses a mission living here outright,
-- before consulting its state, rather than deciding from an attribution that
-- never read the records it would destroy. That refusal is what lets this
-- function stay cheap without being a hole.
legacyMissionClaim :: MissionRepository -> MissionId -> FilePath -> IO LegacyClaim
legacyMissionClaim expected mission root =
  case (,,) <$> missionSpecificationPath root mission
    <*> missionSnapshotPath root mission
    <*> missionLeaseOwnerPath root mission of
    Left message -> pure (LegacyUnattributable message)
    Right (specificationPath, snapshotPath, ownerPath) -> do
      specification <-
        legacyEvidence mission missionSpecificationSchemaVersion missionSpecificationId missionSpecificationRepository specificationPath
      snapshot <-
        legacyEvidence mission missionSnapshotSchemaVersion missionSnapshotId missionSnapshotRepository snapshotPath
      owner <-
        legacyEvidence mission missionLeaseSchemaVersion missionLeaseOwnerMission missionLeaseOwnerRepository ownerPath
      pure (decide [evidence | Just evidence <- [specification, snapshot, owner]])
  where
    decide evidence = case [reason | Left reason <- evidence] of
      reason : _ -> LegacyUnattributable reason
      [] -> case nub [recorded | Right recorded <- evidence] of
        [] ->
          LegacyUnattributable
            (Text.pack root <> " holds no durable record naming a repository")
        [only]
          | missionRepositoryMatches only expected -> LegacyOurs
          | otherwise -> LegacyForeign
        several ->
          LegacyUnattributable
            ( "its records name "
                <> Text.intercalate
                  ", "
                  [recorded.missionRepositoryOwner <> "/" <> recorded.missionRepositoryName | recorded <- several]
            )

-- | What one identity-bearing record says about whose mission this is:
-- nothing when it is not there, a reason when it cannot be believed, and the
-- repository it names otherwise.
legacyEvidence ::
  FromJSON value =>
  MissionId ->
  Int ->
  (value -> MissionId) ->
  (value -> MissionRepository) ->
  FilePath ->
  IO (Maybe (Either Text MissionRepository))
legacyEvidence mission version recordedMission recordedRepository path = do
  result <- readMissionRecord mission [version] path
  case result of
    -- 'MissionAbsent' is two different answers here, and telling them apart is
    -- the whole of this branch. A file that is not there says nothing, and the
    -- other records are asked instead. A file that /is/ there and read as
    -- absent was written under a schema version this release does not
    -- recognize — §16's silence, which is right for a read and wrong for a
    -- question about ownership: a record written for another repository under
    -- a later schema would otherwise leave this mission looking like ours, and
    -- a snapshot write would then replace it. So a present record this release
    -- cannot decide about makes the mission unattributable.
    MissionAbsent -> do
      presence <- missionEntryAt path
      pure $ case presence of
        MissionEntryAbsent -> Nothing
        MissionEntryUndecidable reason ->
          Just (Left ("whether " <> Text.pack path <> " is there could not be established (" <> reason <> ")"))
        _ ->
          Just
            ( Left
                ( Text.pack path
                    <> " was written under a schema version this release does not recognize,"
                    <> " so whose record it is cannot be established"
                )
            )
    MissionUnreadable reason -> pure (Just (Left reason))
    MissionRefused reason -> pure (Just (Left reason))
    MissionPresent value
      | recordedMission value /= mission ->
          pure
            ( Just
                ( Left
                    ( Text.pack path
                        <> " records the mission "
                        <> (recordedMission value).unMissionId
                    )
                )
            )
      | otherwise -> pure (Just (Right (recordedRepository value)))

-- | The legacy root's missions that this repository's own records claim.
--
-- Enumeration only: a directory that is attributable to another repository, or
-- to nobody, is not this repository's mission and is not listed as one.
adoptedLegacyMissions :: MissionStore -> IO [MissionId]
adoptedLegacyMissions store = do
  entries <- listMissionEntries store.missionStoreLegacyDirectory
  adopted <- filterM ours entries
  pure (map (MissionId . Text.pack) adopted)
  where
    ours name = do
      let mission = MissionId (Text.pack name)
      present <- isPlainDirectory (store.missionStoreLegacyDirectory </> name)
      if not present
        then pure False
        else do
          claim <- legacyMissionClaim store.missionStoreRepository mission store.missionStoreLegacyDirectory
          pure (claim == LegacyOurs)

-- | What is at a path, in the answers a decision can act on.
--
-- Four rather than two, and the fourth is the point. A boolean \"is this a
-- directory?\" has to answer /something/ when the question cannot be asked at
-- all — a permission the store lost, an I\/O error, a filesystem that went
-- away — and whichever way it answers, it has turned \"I could not find out\"
-- into a fact. Here that case keeps its own answer and its own diagnostic, so
-- a caller that must fail closed can.
--
-- The stat does not follow links, deliberately: a symbolic link pointing at
-- somewhere else on the filesystem, a socket, a stray file — none of them is a
-- mission this store wrote, and following one is the difference between
-- reading what the store holds and being pointed anywhere by whatever wrote a
-- name into it.
data MissionEntry
  = MissionEntryAbsent
  | MissionEntryDirectory
  | -- | Present, and not a directory in its own right.
    MissionEntryOther
  | -- | The question could not be answered.
    MissionEntryUndecidable Text
  deriving stock (Eq, Show)

missionEntryAt :: FilePath -> IO MissionEntry
missionEntryAt path = do
  status <- try @IOException (getSymbolicLinkStatus path)
  pure $ case status of
    Right entry
      | isDirectory entry -> MissionEntryDirectory
      | otherwise -> MissionEntryOther
    Left exception
      | isDoesNotExistError exception -> MissionEntryAbsent
      | otherwise -> MissionEntryUndecidable (Text.pack (show exception))

-- | Whether a path is a directory in its own right rather than a link to one.
--
-- The enumerating half of 'missionEntryAt', for the callers filtering a
-- listing rather than deciding where a mission lives: an entry that cannot be
-- statted is not one a listing can report, and every caller that must fail
-- closed asks 'missionEntryAt' instead.
isPlainDirectory :: FilePath -> IO Bool
isPlainDirectory path = (== MissionEntryDirectory) <$> missionEntryAt path

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
listMissionEntries store = either (const []) id <$> listMissionEntriesStrictly store

-- | The same enumeration, keeping the failure instead of flattening it.
--
-- 'listMissionEntries' answers \"what is in here\" and reads a directory it
-- could not list as an empty one, which is the right answer for a caller that
-- is looking for something and the wrong one for a caller that is /reporting/
-- on everything. An unreadable store directory and an empty store directory
-- are the same value to the first and opposite answers to the second: a
-- scheduler that could not enumerate a repository must not report a quiet
-- repository.
--
-- A directory that is not there is still 'Right []'. A store whose missions
-- have never been created is empty rather than broken, and 'openMissionStore'
-- creates the root before any caller reaches here.
listMissionEntriesStrictly :: FilePath -> IO (Either Text [FilePath])
listMissionEntriesStrictly store = do
  -- The root is classified with the non-following stat every other decision
  -- here uses, not with 'doesDirectoryExist'. That predicate answers False for
  -- three quite different things — nothing is there, something is there and is
  -- not a directory, and the question could not be asked because a parent is
  -- not searchable — and only the first of them means an empty store. Reading
  -- the other two as empty is how an unreachable repository reports as a quiet
  -- one.
  presence <- missionEntryAt store
  case presence of
    MissionEntryAbsent -> pure (Right [])
    MissionEntryUndecidable reason ->
      pure (Left (Text.pack store <> " could not be inspected: " <> reason))
    MissionEntryOther ->
      pure (Left (Text.pack store <> " is not a directory"))
    MissionEntryDirectory -> do
      listed <- try @IOException (listDirectory store)
      pure $ case listed of
        Left exception ->
          Left (Text.pack store <> " could not be listed: " <> Text.pack (show exception))
        Right entries -> Right (filter safeMissionComponent entries)

ignoreFileOperation :: IO () -> IO ()
ignoreFileOperation operation = void (try @IOException operation)
