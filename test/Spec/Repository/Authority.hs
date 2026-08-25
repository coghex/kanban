-- | One repository, one board: the canonical durable key, the migration that
-- brings an older release's record under it, the modes that take the lease at
-- all, and the informational owner an entry carries.
--
-- What is /not/ here is contention. Every proof about two boards needs two
-- processes and lives in "Spec.Repository.Lease" beside the harness that
-- provides them; this module is the half that one process can establish, and
-- keeping the two apart is what stops a single-process example from claiming
-- an authority it cannot demonstrate.
module Spec.Repository.Authority (spec) where

import Data.Aeson (Value (..), decode, eitherDecodeFileStrict', encode, object, toJSON, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.CLI
  ( BorderPolicy (..),
    ColorPolicy (..),
    LaunchMode (..),
    Options (..),
    acquiresRepositoryLease,
    launchMode,
  )
import Kanban.Cache
  ( GhGroupRecordLoad (..),
    canonicalRepositoryKey,
    ghGroupRecordPath,
    ghGroupRecordSchemaVersion,
    legacyGhGroupRecordCandidates,
    loadGhGroupRecord,
    mergeGhGroups,
    migrateGhGroupRecord,
    normalizedRepositoryIdentity,
    repositoryLeasePath,
    writeGhGroupRecord,
  )
import Kanban.Domain (Repository (..))
import Kanban.Process (OwnedProcessGroup (..), ProcessIdentity (..))
import Kanban.Repository.Authority
  ( BoardAuthority (..),
    acquireBoardAuthority,
    boardLeaseDiagnostic,
    releaseBoardAuthority,
  )
import Kanban.Repository.Lease
  ( BoardLeaseOutcome (..),
    RepositoryLease,
    acquireBoardLease,
    releaseRepositoryLease,
  )
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Fixtures (testOptions)
import Spec.Support.Process (processIdentity)
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.Posix.Process (getProcessID)
import Test.Hspec

spec :: Spec
spec = do
  describe "the canonical durable key" $ do
    -- The mixed-case half of the requirement, at the level the paths are
    -- decided rather than at the level two processes observe it. Both files
    -- are asserted because the lease guarding a record it does not share a key
    -- with would guard nothing.
    it "gives two spellings of one GitHub repository one record and one lease" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          canonicalRepositoryKey upperSpelling `shouldBe` canonicalRepositoryKey lowerSpelling
          upperRecord <- ghGroupRecordPath upperSpelling
          lowerRecord <- ghGroupRecordPath lowerSpelling
          upperRecord `shouldBe` lowerRecord
          upperLease <- repositoryLeasePath upperSpelling
          lowerLease <- repositoryLeasePath lowerSpelling
          upperLease `shouldBe` lowerLease

    -- The injectivity half. These two are the pair the old `safeKey` mapping
    -- confused, and 'Spec.Agent.ManagedProcess.Lifecycle' documents the same
    -- collision still standing for the worker directories, which this issue
    -- deliberately leaves alone.
    it "gives two repositories the old key confused two records and two leases" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          canonicalRepositoryKey hyphenOwner `shouldNotBe` canonicalRepositoryKey hyphenName
          firstRecord <- ghGroupRecordPath hyphenOwner
          secondRecord <- ghGroupRecordPath hyphenName
          firstRecord `shouldNotBe` secondRecord
          firstLease <- repositoryLeasePath hyphenOwner
          secondLease <- repositoryLeasePath hyphenName
          firstLease `shouldNotBe` secondLease

    it "spells the key exactly as the contract states" $
      canonicalRepositoryKey upperSpelling `shouldBe` "coghex%2Fkanban"

    -- Two paths derived from one key, in one directory, differing only in what
    -- they are for.
    it "puts the lease beside the record it guards" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          record <- ghGroupRecordPath lowerSpelling
          lease <- repositoryLeasePath lowerSpelling
          takeDirectory lease `shouldBe` takeDirectory record
          takeFileName record `shouldBe` "coghex%2Fkanban.json"
          takeFileName lease `shouldBe` "coghex%2Fkanban.lock"

    it "records the normalized identity in the envelope it writes" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          writeGhGroupRecord upperSpelling [unownedGroup 4100] `shouldReturn` Right ()
          path <- ghGroupRecordPath upperSpelling
          stored <- envelopeField path "ghGroupRepositoryKey"
          stored `shouldBe` Just (String (normalizedRepositoryIdentity lowerSpelling))
          -- And a board that spells it the other way still reads it.
          loadGhGroupRecord lowerSpelling `shouldReturn` GhGroupRecordLoaded [unownedGroup 4100]

  describe "discovering an older release's record" $ do
    it "finds a legacy record whose case differs from this board's spelling" $
      withCacheRoot $ \_ -> do
        writeLegacyRecord "Coghex-Kanban.json" "Coghex/Kanban" [unownedGroup 51]
        candidates <- legacyGhGroupRecordCandidates lowerSpelling
        fmap (map takeFileName) candidates `shouldBe` Right ["Coghex-Kanban.json"]

    -- The hazard the scan exists to avoid, asserted as an absence: a POSIX
    -- record lock is released the moment the holding process closes any
    -- descriptor on the file, so a scan that offered this repository's own
    -- lease as a candidate would hand the migration a file whose opening frees
    -- the authority it runs under.
    it "never offers a lock file as a candidate" $
      withCacheRoot $ \_ -> do
        lease <- repositoryLeasePath lowerSpelling
        createDirectoryIfMissing True (takeDirectory lease)
        writeFile lease ""
        writeFile (takeDirectory lease </> "coghex-kanban.lock") ""
        candidates <- legacyGhGroupRecordCandidates lowerSpelling
        fmap (map takeFileName) candidates `shouldBe` Right []

    it "never offers the canonical record as a candidate" $
      withCacheRoot $ \_ -> do
        writeGhGroupRecord lowerSpelling [unownedGroup 60] `shouldReturn` Right ()
        candidates <- legacyGhGroupRecordCandidates lowerSpelling
        fmap (map takeFileName) candidates `shouldBe` Right []

    it "offers nothing at all before the cache directory exists" $
      withCacheRoot $ \_ ->
        legacyGhGroupRecordCandidates lowerSpelling `shouldReturn` Right []

  describe "migrating an older release's record" $ do
    it "brings a mixed-case legacy record under the canonical one and clears it" $
      withCacheRoot $ \_ -> do
        writeLegacyRecord "Coghex-Kanban.json" "Coghex/Kanban" [unownedGroup 71]
        migrateGhGroupRecord lowerSpelling `shouldReturn` Right []
        loadGhGroupRecord lowerSpelling `shouldReturn` GhGroupRecordLoaded [unownedGroup 71]
        legacyStillPresent "Coghex-Kanban.json" `shouldReturn` False

    it "keeps every distinct group when a canonical and a legacy record both exist" $
      withCacheRoot $ \_ -> do
        writeGhGroupRecord lowerSpelling [unownedGroup 81] `shouldReturn` Right ()
        writeLegacyRecord "coghex-kanban.json" "coghex/kanban" [unownedGroup 82]
        migrateGhGroupRecord lowerSpelling `shouldReturn` Right []
        loaded <- loadGhGroupRecord lowerSpelling
        fmap (sort . map ownedProcessGroupPid) (loadedGroups loaded) `shouldBe` Just [81, 82]

    -- 'withoutGroup' keys the record by pgid, so a pgid-keyed merge would drop
    -- one of these -- and the one it dropped could be the censused entry, whose
    -- members are the only thing that makes the group killable at all.
    it "keeps two entries that share a pgid but disagree about the census" $
      withCacheRoot $ \_ -> do
        let censused = OwnedProcessGroup 90 [processIdentity 91 1 90 "gh"] True Nothing
            uncensused = OwnedProcessGroup 90 [] False Nothing
        writeGhGroupRecord lowerSpelling [censused] `shouldReturn` Right ()
        writeLegacyRecord "coghex-kanban.json" "coghex/kanban" [uncensused]
        migrateGhGroupRecord lowerSpelling `shouldReturn` Right []
        loaded <- loadGhGroupRecord lowerSpelling
        fmap sort (loadedGroups loaded) `shouldBe` Just (sort [censused, uncensused])

    it "collapses an entry that is already canonical rather than duplicating it" $
      withCacheRoot $ \_ -> do
        writeGhGroupRecord lowerSpelling [unownedGroup 95] `shouldReturn` Right ()
        writeLegacyRecord "coghex-kanban.json" "coghex/kanban" [unownedGroup 95]
        migrateGhGroupRecord lowerSpelling `shouldReturn` Right []
        loadGhGroupRecord lowerSpelling `shouldReturn` GhGroupRecordLoaded [unownedGroup 95]

    -- The lossy-key neighbour. Its file is readable and names a different
    -- repository, so it is somebody else's and stays exactly as it was found.
    it "leaves a colliding repository's record alone, unloaded and unremoved" $
      withCacheRoot $ \_ -> do
        writeLegacyRecord "coghex-kan-ban.json" "coghex-kan/ban" [unownedGroup 101]
        migrateGhGroupRecord hyphenName `shouldReturn` Right []
        loadGhGroupRecord hyphenName `shouldReturn` GhGroupRecordAbsent
        legacyStillPresent "coghex-kan-ban.json" `shouldReturn` True
        -- And the repository that does own it still takes it.
        migrateGhGroupRecord hyphenOwner `shouldReturn` Right []
        loadGhGroupRecord hyphenOwner `shouldReturn` GhGroupRecordLoaded [unownedGroup 101]
        legacyStillPresent "coghex-kan-ban.json" `shouldReturn` False

    -- Fail-closed: a file that could be this repository's and cannot be read
    -- is a file that cannot be shown to hold no live gh.
    it "refuses startup over an unreadable candidate, and neither deletes nor replaces it" $
      withCacheRoot $ \cacheRoot -> do
        let path = cacheRoot </> "kanban" </> "gh-groups" </> "coghex-kanban.json"
        createDirectoryIfMissing True (takeDirectory path)
        writeFile path "{ not json"
        outcome <- migrateGhGroupRecord lowerSpelling
        outcome `shouldSatisfy` refusalNaming path
        readFile path `shouldReturn` "{ not json"
        loadGhGroupRecord lowerSpelling `shouldReturn` GhGroupRecordAbsent

    it "refuses startup over a candidate whose schema it does not know" $
      withCacheRoot $ \cacheRoot -> do
        let path = cacheRoot </> "kanban" </> "gh-groups" </> "coghex-kanban.json"
        createDirectoryIfMissing True (takeDirectory path)
        LazyByteString.writeFile
          path
          ( encode
              ( object
                  [ "ghGroupSchemaVersion" .= (ghGroupRecordSchemaVersion + 1),
                    "ghGroupRepositoryKey" .= ("coghex/kanban" :: Text),
                    "ghGroupGroups" .= ([] :: [OwnedProcessGroup])
                  ]
              )
          )
        outcome <- migrateGhGroupRecord lowerSpelling
        outcome `shouldSatisfy` refusalNaming path
        legacyStillPresent "coghex-kanban.json" `shouldReturn` True

    -- The interruption clause, staged at the point it matters: the canonical
    -- write is what fails, so the only copy of the group must still be where it
    -- was found. A directory occupying the canonical name is how that is
    -- arranged -- 'writeCacheFile' renames its temporary file over that name,
    -- and no rename replaces a directory with a file on any platform this runs
    -- on -- rather than by revoking a permission, which the writer's own
    -- private-directory step would put back.
    it "leaves a discoverable copy of every group when its canonical write fails" $
      withCacheRoot $ \_ -> do
        writeLegacyRecord "coghex-kanban.json" "coghex/kanban" [unownedGroup 111]
        canonical <- ghGroupRecordPath lowerSpelling
        createDirectoryIfMissing True canonical
        outcome <- migrateGhGroupRecord lowerSpelling
        outcome `shouldSatisfy` either (const True) (const False)
        -- Still on disk, so nothing that may be running is unrecorded, and a
        -- run made after the obstruction is cleared finds it.
        legacyStillPresent "coghex-kanban.json" `shouldReturn` True

    it "writes canonical state before it removes the file it came from" $
      withCacheRoot $ \_ -> do
        writeLegacyRecord "coghex-kanban.json" "coghex/kanban" [unownedGroup 121]
        -- Repeating the migration is the restart: the second pass finds every
        -- entry already canonical, writes nothing new, and still converges.
        migrateGhGroupRecord lowerSpelling `shouldReturn` Right []
        migrateGhGroupRecord lowerSpelling `shouldReturn` Right []
        loadGhGroupRecord lowerSpelling `shouldReturn` GhGroupRecordLoaded [unownedGroup 121]

    it "keeps a migrated record at schema version 1" $
      withCacheRoot $ \_ -> do
        writeLegacyRecord "Coghex-Kanban.json" "Coghex/Kanban" [unownedGroup 131]
        migrateGhGroupRecord lowerSpelling `shouldReturn` Right []
        path <- ghGroupRecordPath lowerSpelling
        version <- envelopeField path "ghGroupSchemaVersion"
        version `shouldBe` Just (toJSON ghGroupRecordSchemaVersion)

  describe "merging records" $ do
    it "treats only an entry equal in every field as a duplicate" $ do
      let censused = OwnedProcessGroup 140 [processIdentity 141 1 140 "gh"] True Nothing
          uncensused = OwnedProcessGroup 140 [] False Nothing
          owned = censused {ownedProcessGroupOwner = Just (processIdentity 9 1 9 "kanban")}
      mergeGhGroups [censused] [censused] `shouldBe` [censused]
      mergeGhGroups [censused] [uncensused] `shouldBe` [censused, uncensused]
      mergeGhGroups [censused] [owned] `shouldBe` [censused, owned]

  describe "the owner an entry carries" $ do
    -- Backward compatibility, from the shape a version 1 file actually has:
    -- the key is simply not there.
    it "decodes a version 1 entry that has no owner key at all" $ do
      let legacy = object ["ownedProcessGroupPid" .= (150 :: Int), "ownedProcessGroupMembers" .= ([] :: [ProcessIdentity]), "ownedProcessGroupCensused" .= False]
      decode (encode legacy) `shouldBe` Just (unownedGroup 150)

    it "round-trips an entry with an owner and one without" $
      withCacheRoot $ \_ -> do
        let board = processIdentity 160 1 160 "kanban"
            withOwner = OwnedProcessGroup 161 [] False (Just board)
            without = unownedGroup 162
        writeGhGroupRecord lowerSpelling [withOwner, without] `shouldReturn` Right ()
        loadGhGroupRecord lowerSpelling `shouldReturn` GhGroupRecordLoaded [withOwner, without]

  describe "which invocations take the repository" $ do
    it "is the dashboard, and only the dashboard" $ do
      map launchMode everyMode
        `shouldBe` [ WorkerMode "/tmp/spec.json",
                     GlyphTestMode,
                     DoctorMode,
                     UsageQueryMode,
                     PingQueryMode,
                     DashboardMode
                   ]
      map acquiresRepositoryLease everyMode `shouldBe` [False, False, False, False, False, True]

    -- The order is §5's, and the reason it is asserted is that an invocation
    -- naming two modes must resolve to the one that does not take the lease.
    it "leaves the lease unclaimed when a dashboard flag is combined with an earlier mode" $ do
      acquiresRepositoryLease testOptions {optionWorkerSpec = Just "/tmp/spec.json", optionPing = ["codex"]} `shouldBe` False
      acquiresRepositoryLease testOptions {optionDoctor = True, optionUsage = True} `shouldBe` False
      -- Options a dashboard does carry do not change the answer.
      acquiresRepositoryLease testOptions {optionRepo = Just "coghex/kanban", optionFresh = True} `shouldBe` True

  describe "the refusal a second board is given" $ do
    it "names the repository and the holding process, and says what to do" $
      boardLeaseDiagnostic upperSpelling (BoardLeaseContended "/tmp/coghex%2Fkanban.lock" 4812)
        `shouldBe` Left "another Kanban board is already open on coghex/kanban (pid 4812).\nClose it before opening another."

    -- The distinction the whole outcome type exists for. A cache root that
    -- cannot be written must never be announced as somebody else's board.
    it "never describes an unusable lease as another board" $ do
      let refused = boardLeaseDiagnostic upperSpelling (BoardLeaseUnusable "/tmp/coghex%2Fkanban.lock" "permission denied")
      refused `shouldSatisfy` either (not . Text.isInfixOf "another Kanban board") (const False)
      refused `shouldSatisfy` either (Text.isInfixOf "/tmp/coghex%2Fkanban.lock") (const False)

    it "hands an acquired lease straight back" $
      withCacheRoot $ \_ -> do
        outcome <- acquireBoardLease lowerSpelling
        boardLeaseDiagnostic lowerSpelling outcome `shouldSatisfy` isAcquired
        releaseAcquired outcome

  describe "taking the repository for a board" $ do
    -- The whole composition, in the order 'runDashboard' calls it: the lease,
    -- then the record, then this board's own identity. Nothing below it in the
    -- dashboard may run without all three settled.
    it "holds the lease, migrates the record, and knows which process it is" $
      withCacheRoot $ \_ -> do
        writeLegacyRecord "Coghex-Kanban.json" "Coghex/Kanban" [unownedGroup 171]
        taken <- acquireBoardAuthority lowerSpelling
        case taken of
          Left message -> expectationFailure ("expected the repository to be taken, and it was refused with " <> Text.unpack message)
          Right authority -> do
            loadGhGroupRecord lowerSpelling `shouldReturn` GhGroupRecordLoaded [unownedGroup 171]
            legacyStillPresent "Coghex-Kanban.json" `shouldReturn` False
            authority.authorityNotices `shouldBe` []
            self <- getProcessID
            fmap processIdentityPid authority.authorityOwner `shouldBe` Just (fromIntegral self)
            releaseBoardAuthority authority

    -- A board that never opened holds nothing. The lease is given back on the
    -- refusal path, so the repository is not left unavailable by a process
    -- that is about to exit anyway.
    it "gives the lease back when the record it inherited refuses startup" $
      withCacheRoot $ \cacheRoot -> do
        let path = cacheRoot </> "kanban" </> "gh-groups" </> "coghex-kanban.json"
        createDirectoryIfMissing True (takeDirectory path)
        writeFile path "{ not json"
        refused <- acquireBoardAuthority lowerSpelling
        case refused of
          Right _ -> expectationFailure "expected the inherited record to refuse startup"
          Left message -> Text.unpack message `shouldContain` path
        -- Taking it again succeeds, which it could not do if the refusal had
        -- kept the lease -- the register refuses a second acquisition inside
        -- one process.
        again <- acquireBoardLease lowerSpelling
        case again of
          BoardLeaseAcquired _ -> releaseAcquired again
          other -> expectationFailure ("expected the lease to be free again, and it was " <> show other)

-- * Fixtures

-- | A repository under a temporary cache root, with no @gh-groups@ directory
-- yet: a first launch on a fresh installation is the ordinary case, and the
-- examples here would be much weaker if they all ran against one this suite
-- had already made.
withCacheRoot :: (FilePath -> IO result) -> IO result
withCacheRoot action =
  withTemporaryCacheRoot $ \cacheRoot ->
    withEnvironmentValue "XDG_CACHE_HOME" cacheRoot (action cacheRoot)

-- | Two spellings of one GitHub repository, and the two repositories the old
-- lossy key mapped onto one file.
upperSpelling, lowerSpelling, hyphenOwner, hyphenName :: Repository
upperSpelling = Repository "/nonexistent/checkout" "Coghex" "Kanban"
lowerSpelling = Repository "/nonexistent/checkout" "coghex" "kanban"
hyphenOwner = Repository "/nonexistent/checkout" "coghex-kan" "ban"
hyphenName = Repository "/nonexistent/checkout" "coghex" "kan-ban"

unownedGroup :: Int -> OwnedProcessGroup
unownedGroup groupPid = OwnedProcessGroup groupPid [] False Nothing

-- | Every mode an invocation can select, one option set each, in §5's order.
everyMode :: [Options]
everyMode =
  [ testOptions {optionWorkerSpec = Just "/tmp/spec.json"},
    testOptions {optionGlyphTest = True},
    testOptions {optionDoctor = True},
    testOptions {optionUsage = True},
    testOptions {optionPing = ["codex"]},
    testOptions {optionColor = ColorNever, optionBorder = BorderOpen}
  ]

-- | A record exactly as a release before the canonical key wrote one: at the
-- lossy path, carrying whichever spelling that invocation resolved.
writeLegacyRecord :: FilePath -> Text -> [OwnedProcessGroup] -> IO ()
writeLegacyRecord name identity groups = do
  directory <- takeDirectory <$> ghGroupRecordPath lowerSpelling
  createDirectoryIfMissing True directory
  LazyByteString.writeFile
    (directory </> name)
    ( encode
        ( object
            [ "ghGroupSchemaVersion" .= ghGroupRecordSchemaVersion,
              "ghGroupRepositoryKey" .= identity,
              "ghGroupGroups" .= groups
            ]
        )
    )

legacyStillPresent :: FilePath -> IO Bool
legacyStillPresent name = do
  directory <- takeDirectory <$> ghGroupRecordPath lowerSpelling
  entries <- listDirectory directory
  present <- doesFileExist (directory </> name)
  pure (present && name `elem` entries)

envelopeField :: FilePath -> Text -> IO (Maybe Value)
envelopeField path field = do
  decoded <- eitherDecodeFileStrict' path
  pure $ case decoded of
    Left _ -> Nothing
    Right (Object envelope) -> KeyMap.lookup (Key.fromText field) envelope
    Right _ -> Nothing

loadedGroups :: GhGroupRecordLoad -> Maybe [OwnedProcessGroup]
loadedGroups (GhGroupRecordLoaded groups) = Just groups
loadedGroups _ = Nothing

refusalNaming :: FilePath -> Either Text [Text] -> Bool
refusalNaming path = either (Text.isInfixOf (Text.pack path)) (const False)

isAcquired :: Either Text RepositoryLease -> Bool
isAcquired = either (const False) (const True)

-- | Gives a lease an example took back before it ends.
--
-- The register holds a descriptor per path for the life of the process, and
-- every example here runs under a cache root of its own, so a lease left
-- behind cannot refuse anything later -- but it is still an open descriptor
-- the suite has no further use for.
releaseAcquired :: BoardLeaseOutcome -> IO ()
releaseAcquired (BoardLeaseAcquired lease) = releaseRepositoryLease lease
releaseAcquired _ = pure ()
