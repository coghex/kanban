-- | The durable @gh@ record's cross-process transaction lock (issue #720).
--
-- Every read-modify-write of a repository's record is serialised on
-- 'Kanban.Cache.ghGroupRecordLockPath' as well as on the in-process mutex, so
-- a dashboard, a mission runner, and a worker's precondition reread -- three
-- processes each holding a record lock of their own -- cannot lose each other's
-- entries. These examples hold that from the outside: two real processes
-- rewriting one record, the lease the lock sits beside, the lock file's mode,
-- a lock that cannot be established, and an interruption at either end of it.
module Spec.GitHub.RecordLock (spec) where

import Control.Concurrent (forkIO, killThread, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (finally)
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.List (sort)
import qualified Data.Text as Text
import Kanban.Cache
  ( GhGroupRecordLoad (..),
    ghGroupRecordLockPath,
    ghGroupRecordPath,
    ghGroupRecordSchemaVersion,
    loadGhGroupRecord,
    migrateGhGroupRecord,
    repositoryLeasePath,
    withGhGroupRecordLock,
    writeGhGroupRecord,
  )
import Kanban.Domain (Repository (..))
import Kanban.GitHub
  ( GhCleanupFailure (..),
    GhCleanupGuard (..),
    GhFetchGuard,
    dropGhGroup,
    ghFetchCleanupFailure,
    ghGroupIsRecorded,
    newGhFetchGuard,
    newGhRecordLock,
    reclaimRecordedGhGroups,
    recordGhGroup,
  )
import Kanban.Process (OwnedProcessGroup (..))
import Kanban.Repository.Lease (BoardLeaseOutcome (..), acquireBoardLease, releaseRepositoryLease)
import Spec.Support.Env (permissionsOf, withEnvironmentValue, withFileCreationMask, withTemporaryCacheRoot)
import Spec.Support.LeaseProbes
  ( LeaseProbe (..),
    LeaseProbeOutcome (..),
    awaitLeaseOutcome,
    openLeaseGate,
    withLeaseProbes,
  )
import Spec.Support.RecordWriters (RecordWriter (..), RecordWriterOutcome (..), runConcurrentRecordWriters)
import System.Directory (createDirectory, createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory, (</>))
import System.Posix.Files (setFileMode)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "the gh record's cross-process transaction lock" $ do
  -- The lost-update probe. Two processes, each with a record lock of its own
  -- -- which is all a mission runner beside a dashboard has -- rewrite one
  -- repository's record through the production transaction, side by side for
  -- a few hundred transactions each. Every entry either was told it recorded
  -- must be in the file afterwards. Without the file lock the interleaved
  -- read-modify-writes drop entries by the dozen.
  it "keeps every entry when two independent processes rewrite one record at once" $
    withTemporaryCacheRoot $ \root ->
      withEnvironmentValue "XDG_CACHE_HOME" (root </> "cache") $ do
        outcomes <-
          runConcurrentRecordWriters
            (root </> "writers")
            (root </> "cache")
            repository
            writerOverlap
            [RecordWriter "dashboard" 100000, RecordWriter "runner" 200000]
        map (recordWriterFailures . snd) outcomes `shouldBe` [[], []]
        -- Each writer went on for the whole overlap after seeing the other, so
        -- neither can have recorded fewer than that; asserting it keeps a writer
        -- that silently did nothing from passing the example below.
        map (\(_, outcome) -> length outcome.recordWriterRecorded >= writerOverlap) outcomes `shouldBe` [True, True]
        loaded <- loadGhGroupRecord repository
        let recorded = sort (concatMap (recordWriterRecorded . snd) outcomes)
        fmap (sort . map ownedProcessGroupPid) (loadedGroups loaded) `shouldBe` Just recorded

  -- The descriptor hazard 'repositoryLeasePath' documents: a POSIX record lock
  -- is released when its process closes any descriptor on the file. Taking and
  -- releasing the record lock must never touch the lease file, and the only
  -- way to see that it did not is to ask another process afterwards.
  it "leaves a held repository lease held after a full record lock cycle" $
    withTemporaryCacheRoot $ \root ->
      withEnvironmentValue "XDG_CACHE_HOME" (root </> "cache") $ do
        taken <- acquireBoardLease repository
        case taken of
          BoardLeaseAcquired lease -> do
            guard <- freshGuard
            recordGhGroup guard repository (unownedGroup 4242) `shouldReturn` Right ()
            ghGroupIsRecorded guard repository 4242 `shouldReturn` True
            dropGhGroup guard repository 4242 `shouldReturn` Right ()
            migrateGhGroupRecord repository `shouldReturn` Right []
            withLeaseProbes
              (root </> "probes")
              [LeaseProbe "intruder" repository (root </> "cache") "intruder"]
              $ \probes -> do
                openLeaseGate probes "intruder"
                awaitLeaseOutcome probes "intruder" `shouldReturn` ProbeHeld
            releaseRepositoryLease lease
          _ -> expectationFailure "expected the repository lease to be taken"

  it "is its own file, beside the record and the lease and neither of them" $
    withTemporaryCacheRoot $ \root ->
      withEnvironmentValue "XDG_CACHE_HOME" root $ do
        lockPath <- ghGroupRecordLockPath repository
        recordPath <- ghGroupRecordPath repository
        leasePath <- repositoryLeasePath repository
        takeDirectory lockPath `shouldBe` takeDirectory recordPath
        lockPath `shouldNotBe` recordPath
        lockPath `shouldNotBe` leasePath

  -- The D-8 migration discovers legacy records by basename. The lock file
  -- persists beside them, and a migration that took it for a record would
  -- refuse startup over a payload-free file.
  it "is never mistaken for a legacy record by the migration" $
    withTemporaryCacheRoot $ \root ->
      withEnvironmentValue "XDG_CACHE_HOME" root $ do
        guard <- freshGuard
        recordGhGroup guard repository (unownedGroup 51) `shouldReturn` Right ()
        lockPath <- ghGroupRecordLockPath repository
        doesFileExist lockPath `shouldReturn` True
        migrateGhGroupRecord repository `shouldReturn` Right []
        loadGhGroupRecord repository `shouldReturn` GhGroupRecordLoaded [unownedGroup 51]
        doesFileExist lockPath `shouldReturn` True

  describe "its mode" $ do
    it "creates the lock file as 0600 under a permissive umask" $
      withTemporaryCacheRoot $ \root ->
        withEnvironmentValue "XDG_CACHE_HOME" root $
          withFileCreationMask 0o000 $ do
            guard <- freshGuard
            recordGhGroup guard repository (unownedGroup 61) `shouldReturn` Right ()
            lockPath <- ghGroupRecordLockPath repository
            permissionsOf lockPath `shouldReturn` 0o600

    it "tightens a lock file left loose" $
      withTemporaryCacheRoot $ \root ->
        withEnvironmentValue "XDG_CACHE_HOME" root $ do
          lockPath <- ghGroupRecordLockPath repository
          createDirectoryIfMissing True (takeDirectory lockPath)
          ByteString.writeFile lockPath ""
          setFileMode lockPath 0o644
          guard <- freshGuard
          ghGroupIsRecorded guard repository 61 `shouldReturn` False
          permissionsOf lockPath `shouldReturn` 0o600

  -- Requirement 6: a lock that cannot be established never degrades into an
  -- unsynchronised rewrite. Each operation fails the way it already fails a
  -- record write, and nothing on disk moves.
  describe "a lock that cannot be established" $ do
    it "fails every rewrite, confirms nothing, and leaves the canonical and legacy records as they were" $
      withTemporaryCacheRoot $ \root ->
        withEnvironmentValue "XDG_CACHE_HOME" root $ do
          writeGhGroupRecord repository [unownedGroup 71] `shouldReturn` Right ()
          recordPath <- ghGroupRecordPath repository
          let legacyPath = takeDirectory recordPath </> "coghex-kanban.json"
          writeLegacyRecord legacyPath [unownedGroup 72]
          canonicalBefore <- ByteString.readFile recordPath
          legacyBefore <- ByteString.readFile legacyPath
          lockPath <- ghGroupRecordLockPath repository
          createDirectory lockPath
          guard <- freshGuard
          recordGhGroup guard repository (unownedGroup 73) >>= (`shouldSatisfy` isRecordWriteFailure)
          dropGhGroup guard repository 71 >>= (`shouldSatisfy` isRecordWriteFailure)
          -- The group is on disk, and still not confirmed: an answer that could
          -- not be read under the lock is no confirmation of coverage.
          ghGroupIsRecorded guard repository 71 `shouldReturn` False
          reclaimed <- reclaimRecordedGhGroups guard repository
          reclaimed `shouldSatisfy` either (Text.isInfixOf "gh group record lock could not be established") (const False)
          fmap ghCleanupGuard <$> ghFetchCleanupFailure guard `shouldReturn` Just GuardRecorded
          migrateGhGroupRecord repository >>= (`shouldSatisfy` isRecordWriteFailure . fmap (const ()))
          ByteString.readFile recordPath `shouldReturn` canonicalBefore
          ByteString.readFile legacyPath `shouldReturn` legacyBefore

    -- The one case reclaim and a drop still answer without the lock: no record
    -- at all. Nothing is reclaimed, cleared or dropped, so nothing is
    -- rewritten, and failing would report a recorded gh nobody wrote -- the
    -- registration is what fails, and it stops the gh it started.
    it "lets reclaim and a drop answer from a record that does not exist, writing nothing" $
      withTemporaryCacheRoot $ \root ->
        withEnvironmentValue "XDG_CACHE_HOME" root $ do
          lockPath <- ghGroupRecordLockPath repository
          createDirectoryIfMissing True lockPath
          guard <- freshGuard
          reclaimRecordedGhGroups guard repository `shouldReturn` Right ()
          ghFetchCleanupFailure guard `shouldReturn` Nothing
          loadGhGroupRecord repository `shouldReturn` GhGroupRecordAbsent
          recordGhGroup guard repository (unownedGroup 75) >>= (`shouldSatisfy` isRecordWriteFailure)
          dropGhGroup guard repository 75 `shouldReturn` Right ()
          loadGhGroupRecord repository `shouldReturn` GhGroupRecordAbsent

  -- Blocking contention has to stay compatible with the fetch and cleanup
  -- budgets, which end work by interrupting it. An interruption at either end
  -- -- while waiting for a holder, or while holding -- must strand neither the
  -- descriptor, the file lock, nor the in-process mutex.
  describe "an interruption" $ do
    it "queues a second rewrite behind a holder, and strands nothing when that wait is interrupted" $
      withTemporaryCacheRoot $ \root ->
        withEnvironmentValue "XDG_CACHE_HOME" root $ do
          holding <- newEmptyMVar
          letGo <- newEmptyMVar
          -- Held through the production primitive on a descriptor of its own,
          -- which contends with the guard's exactly as another process would.
          holder <- forkIO (() <$ withGhGroupRecordLock repository (putMVar holding () >> takeMVar letGo))
          takeMVar holding
          guard <- freshGuard
          ( do
              -- Queued, not refused: a refusal would come back at once.
              timeout 300000 (recordGhGroup guard repository (unownedGroup 81)) `shouldReturn` Nothing
              putMVar letGo ()
              -- The same guard, so the mutex the interrupted wait held is the
              -- one this has to take.
              timeout boundMicros (recordGhGroup guard repository (unownedGroup 82)) `shouldReturn` Just (Right ())
              loadGhGroupRecord repository `shouldReturn` GhGroupRecordLoaded [unownedGroup 82]
            )
            `finally` killThread holder

    it "releases the lock when the section holding it is interrupted" $
      withTemporaryCacheRoot $ \root ->
        withEnvironmentValue "XDG_CACHE_HOME" root $ do
          holding <- newEmptyMVar
          never <- newEmptyMVar
          holder <- forkIO (() <$ withGhGroupRecordLock repository (putMVar holding () >> takeMVar never))
          takeMVar holding
          killThread holder
          guard <- freshGuard
          timeout boundMicros (recordGhGroup guard repository (unownedGroup 91)) `shouldReturn` Just (Right ())
          loadGhGroupRecord repository `shouldReturn` GhGroupRecordLoaded [unownedGroup 91]

-- | How many transactions each writer goes on for once it has seen the other
-- rewriting: the span the lost-update probe guarantees they share.
writerOverlap :: Int
writerOverlap = 200

-- | How long an example waits for something that should be immediate before
-- calling it stranded.
boundMicros :: Int
boundMicros = 5000000

repository :: Repository
repository = Repository "/nonexistent/checkout" "coghex" "kanban"

freshGuard :: IO GhFetchGuard
freshGuard = newGhRecordLock >>= newGhFetchGuard

unownedGroup :: Int -> OwnedProcessGroup
unownedGroup groupPid = OwnedProcessGroup groupPid [] False Nothing

loadedGroups :: GhGroupRecordLoad -> Maybe [OwnedProcessGroup]
loadedGroups (GhGroupRecordLoaded groups) = Just groups
loadedGroups _ = Nothing

isRecordWriteFailure :: Either Text.Text () -> Bool
isRecordWriteFailure = either (Text.isInfixOf "gh group record lock could not be established") (const False)

-- | A record exactly as a release before the canonical key wrote one, at the
-- lossy path the migration discovers.
writeLegacyRecord :: FilePath -> [OwnedProcessGroup] -> IO ()
writeLegacyRecord path groups =
  LazyByteString.writeFile
    path
    ( encode
        ( object
            [ "ghGroupSchemaVersion" .= ghGroupRecordSchemaVersion,
              "ghGroupRepositoryKey" .= ("coghex/kanban" :: Text.Text),
              "ghGroupGroups" .= groups
            ]
        )
    )
