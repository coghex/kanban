-- | The last-good repository snapshot and the private state directories that
-- hold it.
module Spec.Repository.State (spec) where

import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import qualified Data.Map.Strict as Map
import qualified Data.Text
import Data.Foldable (for_)
import Data.Time (UTCTime, addUTCTime)
import Kanban.Cache
  ( CacheLoad (..),
    UsageCacheLoad (..),
    UsageCommit (..),
    commitUsageSnapshots,
    loadRepositoryCache,
    loadUsageCache,
    ghGroupRecordPath,
    mergeUsageSnapshots,
    repositoryCachePath,
    repositoryCacheSchemaVersion,
    usageCacheLockPath,
    usageCachePath,
    writeGhGroupRecord
  )
import Kanban.Domain
import Spec.Support.Fixtures (epoch)
import Kanban.Settings (ChatVerbosity (..), Settings (..), saveSettings, settingsPath)
import Kanban.Transcript (closeSessionLog, openSessionLog, transcriptRoot)
import Spec.Support.Env
  ( permissionsOf,
    withEnvironmentValue,
    withFileCreationMask,
    withTemporaryCacheRoot
  )
import Spec.Support.Expect (isInvalidCache, isInvalidUsageCache)
import Spec.Support.UsageWriters (UsageWriter (..), UsageWriterOutcome (..), runConcurrentUsageWriters)
import Spec.Support.Json
  ( undecodableCacheFile,
    versionFiveCacheFile,
    emptySnapshotCacheFile,
    versionFourCacheFile,
    versionThreeCacheFile,
    versionTwoCacheFile
  )
import System.Directory
  ( createDirectory,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    removeFile
  )
import System.FilePath (takeDirectory, (</>))
import System.Posix.Files (setFileMode)
import Test.Hspec

spec :: Spec
spec = do
  -- Nothing writes a repository snapshot any more: open cards are live-only
  -- (§13), so the loader survives only as the gate a file an earlier release
  -- left behind meets. What it has to do with such a file is nothing at all.
  describe "legacy repository snapshot compatibility" $ do
    it "treats the schema 5 file an earlier release wrote as absent, without decoding, rewriting, or removing it" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
          cachePath <- repositoryCachePath repository
          createDirectoryIfMissing True (takeDirectory cachePath)
          ByteString.writeFile cachePath (versionFiveCacheFile 5)
          asFound <- ByteString.readFile cachePath
          loadRepositoryCache repository `shouldReturn` CacheAbsent
          -- Read but never written back, and never cleaned up: the file is
          -- simply no longer this build's business.
          doesFileExist cachePath `shouldReturn` True
          ByteString.readFile cachePath `shouldReturn` asFound

    -- Proof the version gate answered rather than the decoder: a payload no
    -- snapshot decoder could accept is still silently absent while it carries
    -- an older version, and becomes ordinary corruption the moment the same
    -- bytes claim the current one.
    it "answers from the version before the payload, so an unreadable schema 5 snapshot is never decoded" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
          cachePath <- repositoryCachePath repository
          createDirectoryIfMissing True (takeDirectory cachePath)
          ByteString.writeFile cachePath (undecodableCacheFile 5)
          loadRepositoryCache repository `shouldReturn` CacheAbsent
          ByteString.writeFile cachePath (undecodableCacheFile repositoryCacheSchemaVersion)
          relabeled <- loadRepositoryCache repository
          relabeled `shouldSatisfy` isInvalidCache

    it "keeps treating every older schema version as absent rather than as corruption" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
          cachePath <- repositoryCachePath repository
          createDirectoryIfMissing True (takeDirectory cachePath)
          for_
            [versionTwoCacheFile 2, versionThreeCacheFile 3, versionFourCacheFile 4, versionFiveCacheFile 999]
            ( \contents -> do
                ByteString.writeFile cachePath contents
                loadRepositoryCache repository `shouldReturn` CacheAbsent
            )

    -- Only a version is silent. A file with no integer version to read is not
    -- "from another release", it is unreadable, and still warns.
    it "keeps warning for a corrupt file or one with no usable schema version" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
          cachePath <- repositoryCachePath repository
          createDirectoryIfMissing True (takeDirectory cachePath)
          LazyByteString.writeFile cachePath "not JSON"
          corrupt <- loadRepositoryCache repository
          corrupt `shouldSatisfy` isInvalidCache
          ByteString.writeFile cachePath "{\"repositoryKey\":\"coghex/kanban\",\"snapshot\":{}}"
          missing <- loadRepositoryCache repository
          missing `shouldSatisfy` isInvalidCache
          ByteString.writeFile cachePath "{\"schemaVersion\":\"four\",\"repositoryKey\":\"coghex/kanban\"}"
          notAnInteger <- loadRepositoryCache repository
          notAnInteger `shouldSatisfy` isInvalidCache

    -- A recognised version that names someone else's repository is a real
    -- mix-up rather than a version skew, so it keeps the warning.
    it "still reports a recognised-version file belonging to another repository as invalid" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let theirs = Repository "/tmp/other" "coghex" "other"
          theirsPath <- repositoryCachePath theirs
          createDirectoryIfMissing True (takeDirectory theirsPath)
          ByteString.writeFile theirsPath (emptySnapshotCacheFile repositoryCacheSchemaVersion)
          loadRepositoryCache theirs `shouldReturn` CacheInvalid "cache ignored: repository identity mismatch"

  describe "usage snapshot cache" $ do
    it "round-trips global usage snapshots" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let codexUsage = UsageSnapshot [UsageWindow "week" 77 epoch] epoch
              claudeUsage = UsageSnapshot [UsageWindow "5 hour" 65 epoch] epoch
              snapshots = Map.fromList [(Codex, codexUsage), (Claude, claudeUsage)]
          commitSnapshots snapshots `shouldReturn` UsageCommit (Right ()) Nothing
          loadUsageCache `shouldReturn` UsageCacheLoaded snapshots

    -- The usage cache follows the same policy, and needs the same
    -- version-before-payload order to do so: its snapshots are decoded from a
    -- shape that a future version is free to change.
    it "treats an unknown usage schema version as absent, whatever its payload looks like" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          commitSnapshots (Map.fromList [(Codex, UsageSnapshot [UsageWindow "week" 77 epoch] epoch)]) `shouldReturn` UsageCommit (Right ()) Nothing
          path <- usageCachePath
          ByteString.writeFile path "{\"schemaVersion\":999,\"snapshots\":\"whatever this came to mean\"}"
          loadUsageCache `shouldReturn` UsageCacheAbsent
          -- Relabelled as current, that same payload is a genuine decode
          -- failure -- so the version, not the decoder, produced the silence.
          ByteString.writeFile path "{\"schemaVersion\":1,\"snapshots\":\"whatever this came to mean\"}"
          relabeled <- loadUsageCache
          relabeled `shouldSatisfy` isInvalidUsageCache

    it "keeps warning for a corrupt or version-less usage cache" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          commitSnapshots Map.empty `shouldReturn` UsageCommit (Right ()) Nothing
          path <- usageCachePath
          ByteString.writeFile path "not JSON"
          corrupt <- loadUsageCache
          corrupt `shouldSatisfy` isInvalidUsageCache
          ByteString.writeFile path "{\"snapshots\":{}}"
          missing <- loadUsageCache
          missing `shouldSatisfy` isInvalidUsageCache

  -- Every usage-cache mutation is one transaction: the committed map is read,
  -- the caller's fresh provider entries are merged onto it, and the result is
  -- written, all under one cross-process lock. Before #477 the merge happened
  -- against a map the caller had read before probing its provider, so a
  -- refresh another process committed in between was silently reverted.
  describe "usage cache transactions" $ do
    it "keeps both refreshes when two independent processes commit different providers at once" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          -- The map both writers would have read had they read one: stale for
          -- both providers, so a lost update is visible as a stale entry
          -- rather than as a missing one.
          commitSnapshots (Map.fromList [(Codex, staleSnapshot), (Claude, staleSnapshot)])
            `shouldReturn` UsageCommit (Right ()) Nothing
          outcomes <-
            runConcurrentUsageWriters
              (cacheRoot </> "writers")
              [ UsageWriter "codex-writer" Codex (freshSnapshot 71),
                UsageWriter "claude-writer" Claude (freshSnapshot 22)
              ]
          -- Both report success. A test asserting only on the stored map would
          -- pass just as well if one writer had refused to write at all.
          map snd outcomes `shouldBe` [UsageWriterOutcome Nothing Nothing, UsageWriterOutcome Nothing Nothing]
          storedPercentages `shouldReturn` Map.fromList [(Codex, [71]), (Claude, [22])]

    -- The same two writers with the lock removed would each merge onto the map
    -- the seed left, and whichever committed second would carry the other's
    -- stale entry back. That is what the fresh percentages above rule out.
    it "commits a provider the caller said nothing about unchanged" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          commitSnapshots (Map.fromList [(Codex, staleSnapshot), (Claude, staleSnapshot)])
            `shouldReturn` UsageCommit (Right ()) Nothing
          commitSnapshots (Map.fromList [(Codex, freshSnapshot 71)]) `shouldReturn` UsageCommit (Right ()) Nothing
          storedPercentages `shouldReturn` Map.fromList [(Codex, [71]), (Claude, [12])]

    it "leaves a committed entry alone for a snapshot stamped before it, and still reports success" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          commitSnapshots (Map.fromList [(Codex, freshSnapshot 71)]) `shouldReturn` UsageCommit (Right ()) Nothing
          commitSnapshots (Map.fromList [(Codex, staleSnapshot)]) `shouldReturn` UsageCommit (Right ()) Nothing
          storedPercentages `shouldReturn` Map.fromList [(Codex, [71])]

    it "replaces a committed entry with a snapshot stamped after it" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          commitSnapshots (Map.fromList [(Codex, staleSnapshot)]) `shouldReturn` UsageCommit (Right ()) Nothing
          commitSnapshots (Map.fromList [(Codex, freshSnapshot 71)]) `shouldReturn` UsageCommit (Right ()) Nothing
          storedPercentages `shouldReturn` Map.fromList [(Codex, [71])]

    -- The boundary the rule is stated at. "Not older" admits an equal stamp,
    -- so a re-read of the same instant still commits: refusing it would make
    -- an entry's own timestamp behave differently on a rewrite than on the
    -- write that established it.
    it "replaces a committed entry with a snapshot stamped at the same instant" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          commitSnapshots (Map.fromList [(Codex, UsageSnapshot [UsageWindow "week" 12 epoch] staleInstant)])
            `shouldReturn` UsageCommit (Right ()) Nothing
          commitSnapshots (Map.fromList [(Codex, UsageSnapshot [UsageWindow "week" 71 epoch] staleInstant)])
            `shouldReturn` UsageCommit (Right ()) Nothing
          storedPercentages `shouldReturn` Map.fromList [(Codex, [71])]

    -- The pure rule the transaction applies, stated once and covered
    -- exhaustively here so the cases above need only show that the
    -- transaction reaches it.
    it "merges by provider, taking an incoming entry unless it is strictly older" $ do
      let older = UsageSnapshot [UsageWindow "week" 1 epoch] staleInstant
          newer = UsageSnapshot [UsageWindow "week" 2 epoch] freshInstant
      mergeUsageSnapshots Map.empty (Map.fromList [(Codex, older)]) `shouldBe` Map.fromList [(Codex, older)]
      mergeUsageSnapshots (Map.fromList [(Claude, newer)]) (Map.fromList [(Codex, older)])
        `shouldBe` Map.fromList [(Codex, older), (Claude, newer)]
      mergeUsageSnapshots (Map.fromList [(Codex, newer)]) (Map.fromList [(Codex, older)])
        `shouldBe` Map.fromList [(Codex, newer)]
      mergeUsageSnapshots (Map.fromList [(Codex, older)]) (Map.fromList [(Codex, newer)])
        `shouldBe` Map.fromList [(Codex, newer)]
      mergeUsageSnapshots (Map.fromList [(Codex, newer)]) (Map.fromList [(Codex, newer {usageWindows = []})])
        `shouldBe` Map.fromList [(Codex, newer)]

    -- Requirement 8: a transaction that cannot be established fails the write.
    -- Falling back to an unsynchronised replacement here would restore exactly
    -- the defect the lock exists to remove.
    it "fails the commit when the lock cannot be taken, leaving the stored map as it was" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          commitSnapshots (Map.fromList [(Codex, staleSnapshot)]) `shouldReturn` UsageCommit (Right ()) Nothing
          lockPath <- usageCacheLockPath
          removeFile lockPath
          createDirectory lockPath
          blocked <- commitSnapshots (Map.fromList [(Codex, freshSnapshot 71)])
          blocked.usageCommitResult `shouldSatisfy` either (Data.Text.isPrefixOf "cache write failed: ") (const False)
          blocked.usageCommitWarning `shouldBe` Nothing
          storedPercentages `shouldReturn` Map.fromList [(Codex, [12])]

    -- A stored map that exists and cannot be read is not an empty one.
    -- Merging onto empty would replace contents nothing has established, which
    -- is the lost update wearing a different hat.
    it "fails the commit rather than merging onto an empty map when the stored one cannot be read" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          path <- usageCachePath
          createDirectoryIfMissing True path
          unreadable <- commitSnapshots (Map.fromList [(Codex, freshSnapshot 71)])
          unreadable.usageCommitResult `shouldSatisfy` either (Data.Text.isPrefixOf "cache write failed: ") (const False)
          doesDirectoryExist path `shouldReturn` True

    -- Corruption stays what it has always been: warned about, not refused. The
    -- merge then replaces the unreadable file, which is what makes the warning
    -- a one-off rather than a permanent state.
    it "warns about a corrupt stored map, commits onto an empty base, and replaces it" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          commitSnapshots (Map.fromList [(Codex, staleSnapshot)]) `shouldReturn` UsageCommit (Right ()) Nothing
          path <- usageCachePath
          ByteString.writeFile path "not JSON"
          repaired <- commitSnapshots (Map.fromList [(Claude, freshSnapshot 22)])
          repaired.usageCommitResult `shouldBe` Right ()
          repaired.usageCommitWarning `shouldSatisfy` maybe False (Data.Text.isPrefixOf "usage cache ignored: ")
          storedPercentages `shouldReturn` Map.fromList [(Claude, [22])]

  -- 'createDirectoryIfMissing' gives a parent it creates the process umask,
  -- so chmodding only the leaf left ~/.cache/kanban at whatever mode the
  -- writer that happened to run first was given -- and the cache holds issue
  -- and pull request bodies from private repositories.
  describe "private state directory permissions" $ do
    it "creates every cache level it owns as 0700 under a permissive umask, and leaves the XDG root alone" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let xdgRoot = temporaryRoot </> "cache"
            repository = Repository "/tmp/project" "coghex" "kanban"
        createDirectory xdgRoot
        setFileMode xdgRoot 0o755
        withEnvironmentValue "XDG_CACHE_HOME" xdgRoot $
          withFileCreationMask 0o000 $ do
            -- The gh group record is the deepest thing the cache root still
            -- writes: kanban/gh-groups/<key>.json, so the intermediate level
            -- an earlier writer might have created loosely is covered too.
            writeGhGroupRecord repository [] `shouldReturn` Right ()
            recordPath <- ghGroupRecordPath repository
            permissionsOf (xdgRoot </> "kanban") `shouldReturn` 0o700
            permissionsOf (takeDirectory recordPath) `shouldReturn` 0o700
            permissionsOf recordPath `shouldReturn` 0o600
            permissionsOf xdgRoot `shouldReturn` 0o755

    -- The usage transaction's lock file persists between commits like the
    -- snapshot beside it, and is created by an open rather than by
    -- 'writeCacheFile', so it is the one Kanban-owned file whose mode no other
    -- case here covers.
    it "creates the usage transaction's own lock file as 0600 under a permissive umask" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let xdgRoot = temporaryRoot </> "cache"
        createDirectory xdgRoot
        setFileMode xdgRoot 0o755
        withEnvironmentValue "XDG_CACHE_HOME" xdgRoot $
          withFileCreationMask 0o000 $ do
            commitSnapshots (Map.fromList [(Codex, UsageSnapshot [UsageWindow "week" 77 epoch] epoch)])
              `shouldReturn` UsageCommit (Right ()) Nothing
            lockPath <- usageCacheLockPath
            snapshotPath <- usageCachePath
            permissionsOf (xdgRoot </> "kanban") `shouldReturn` 0o700
            permissionsOf lockPath `shouldReturn` 0o600
            permissionsOf snapshotPath `shouldReturn` 0o600
            permissionsOf xdgRoot `shouldReturn` 0o755

    -- A lock file an earlier release or a stray umask left readable is
    -- tightened by the commit that finds it, exactly as the directories above
    -- are.
    it "tightens a usage lock file left loose" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let xdgRoot = temporaryRoot </> "cache"
        createDirectory xdgRoot
        setFileMode xdgRoot 0o755
        withEnvironmentValue "XDG_CACHE_HOME" xdgRoot $ do
          createDirectoryIfMissing True (xdgRoot </> "kanban")
          lockPath <- usageCacheLockPath
          ByteString.writeFile lockPath ""
          setFileMode lockPath 0o644
          commitSnapshots (Map.fromList [(Codex, UsageSnapshot [UsageWindow "week" 77 epoch] epoch)])
            `shouldReturn` UsageCommit (Right ()) Nothing
          permissionsOf lockPath `shouldReturn` 0o600

    -- The transcript root is three levels deep, so the intermediate "logs"
    -- directory is one no writer ever chmodded; here both it and a kanban
    -- directory an earlier version left loose are tightened.
    it "tightens intermediate levels an earlier writer left loose" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let xdgRoot = temporaryRoot </> "cache"
            repository = Repository "/tmp/project" "coghex" "kanban"
        createDirectory xdgRoot
        setFileMode xdgRoot 0o755
        createDirectoryIfMissing True (xdgRoot </> "kanban" </> "logs")
        setFileMode (xdgRoot </> "kanban") 0o755
        setFileMode (xdgRoot </> "kanban" </> "logs") 0o755
        withEnvironmentValue "XDG_CACHE_HOME" xdgRoot $
          withFileCreationMask 0o000 $ do
            opened <- openSessionLog repository "solve-claude" 45 Nothing
            case opened of
              Left message -> expectationFailure (Data.Text.unpack message)
              Right sessionLog -> closeSessionLog sessionLog
            logsRoot <- transcriptRoot repository
            permissionsOf (xdgRoot </> "kanban") `shouldReturn` 0o700
            permissionsOf (xdgRoot </> "kanban" </> "logs") `shouldReturn` 0o700
            permissionsOf logsRoot `shouldReturn` 0o700
            permissionsOf xdgRoot `shouldReturn` 0o755

    it "creates the config level it owns as 0700 under a permissive umask" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let xdgRoot = temporaryRoot </> "config"
        createDirectory xdgRoot
        setFileMode xdgRoot 0o755
        withEnvironmentValue "XDG_CONFIG_HOME" xdgRoot $
          withFileCreationMask 0o000 $ do
            saveSettings (Settings FullChat) `shouldReturn` Right ()
            path <- settingsPath
            permissionsOf (xdgRoot </> "kanban") `shouldReturn` 0o700
            permissionsOf path `shouldReturn` 0o600
            permissionsOf xdgRoot `shouldReturn` 0o755

-- | Every fixture here commits through the one API production uses, so none of
-- them can seed a state no Kanban process could have produced.
commitSnapshots :: Map.Map UsageProvider UsageSnapshot -> IO UsageCommit
commitSnapshots = commitUsageSnapshots

storedPercentages :: IO (Map.Map UsageProvider [Int])
storedPercentages = do
  load <- loadUsageCache
  case load of
    UsageCacheLoaded snapshots -> pure (fmap (map (.usagePercentLeft) . (.usageWindows)) snapshots)
    UsageCacheAbsent -> pure Map.empty
    UsageCacheInvalid message -> Map.empty <$ expectationFailure (Data.Text.unpack message)

-- | Two instants an hour apart, so "older" and "newer" are decided by the
-- stamp the merge compares rather than by anything about the windows.
staleInstant, freshInstant :: UTCTime
staleInstant = epoch
freshInstant = addUTCTime 3600 epoch

staleSnapshot :: UsageSnapshot
staleSnapshot = UsageSnapshot [UsageWindow "week" 12 epoch] staleInstant

freshSnapshot :: Int -> UsageSnapshot
freshSnapshot percentLeft = UsageSnapshot [UsageWindow "week" percentLeft epoch] freshInstant
