-- | The last-good repository snapshot and the private state directories that
-- hold it.
module Spec.Repository.State (spec) where

import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import qualified Data.Map.Strict as Map
import qualified Data.Text
import Data.Foldable (for_)
import Kanban.Cache
  ( CacheLoad (..),
    UsageCacheLoad (..),
    loadRepositoryCache,
    loadUsageCache,
    ghGroupRecordPath,
    repositoryCachePath,
    repositoryCacheSchemaVersion,
    usageCachePath,
    writeGhGroupRecord,
    writeUsageCache
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
import Spec.Support.Json
  ( undecodableCacheFile,
    versionFiveCacheFile,
    versionFourCacheFile,
    versionThreeCacheFile,
    versionTwoCacheFile
  )
import System.Directory (createDirectory, createDirectoryIfMissing, doesFileExist)
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
          ByteString.writeFile theirsPath (versionFiveCacheFile repositoryCacheSchemaVersion)
          loadRepositoryCache theirs `shouldReturn` CacheInvalid "cache ignored: repository identity mismatch"

  describe "usage snapshot cache" $ do
    it "round-trips global usage snapshots" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let codexUsage = UsageSnapshot [UsageWindow "week" 77 epoch] epoch
              claudeUsage = UsageSnapshot [UsageWindow "5 hour" 65 epoch] epoch
              snapshots = Map.fromList [(Codex, codexUsage), (Claude, claudeUsage)]
          writeUsageCache snapshots `shouldReturn` Right ()
          loadUsageCache `shouldReturn` UsageCacheLoaded snapshots

    -- The usage cache follows the same policy, and needs the same
    -- version-before-payload order to do so: its snapshots are decoded from a
    -- shape that a future version is free to change.
    it "treats an unknown usage schema version as absent, whatever its payload looks like" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          writeUsageCache (Map.fromList [(Codex, UsageSnapshot [UsageWindow "week" 77 epoch] epoch)]) `shouldReturn` Right ()
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
          writeUsageCache Map.empty `shouldReturn` Right ()
          path <- usageCachePath
          ByteString.writeFile path "not JSON"
          corrupt <- loadUsageCache
          corrupt `shouldSatisfy` isInvalidUsageCache
          ByteString.writeFile path "{\"snapshots\":{}}"
          missing <- loadUsageCache
          missing `shouldSatisfy` isInvalidUsageCache

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
