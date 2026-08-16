-- | The Brick-free half of the usage surface: which process a provider
-- refresh actually runs (§14's external-command escape hatch), the timeouts it
-- runs under, and the cache-first or forced-live acquisition policy behind
-- @kanban --usage@.
--
-- The routing lives here rather than beside the dashboard's refresh handlers
-- so both callers reach the same decision.  A second copy would let @--usage@
-- and the board disagree about whether a provider has a configured command,
-- which is exactly the divergence the escape hatch cannot afford.
module Kanban.Usage
  ( UsageAcquisition (..),
    UsageMode (..),
    UsageOutcome (..),
    UsageReport (..),
    acquireUsageReport,
    claudeRefreshTimeoutMicros,
    codexRefreshTimeoutMicros,
    fetchProviderUsage,
    formatUsageDuration,
    renderUsageReport,
    runUsageMode,
    runUsageProvider,
    usageProviderKey,
    usageProviderName,
    usageProviders,
    usageReportDocument,
    usageReportProduced,
  )
where

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy.Char8 as LazyChar8
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Data.Time (getCurrentTime, getCurrentTimeZone)
import Kanban.Cache (UsageCacheLoad (..), loadUsageCache, writeUsageCache)
import Kanban.Claude (fetchClaudeUsage)
import Kanban.Codex (fetchCodexUsage)
import Kanban.Config (ResolvedConfig (..), TimeoutsConfig (..), UsageCommandConfig (..), UsageConfig (..))
import Kanban.Domain (UsageProvider (..), UsageSnapshot (..))
import Kanban.Provider (ProviderError (..))
import Kanban.Usage.Render
  ( UsageOutcome (..),
    UsageReport (..),
    formatUsageDuration,
    renderUsageReport,
    usageProviderKey,
    usageProviderName,
    usageReportDocument,
    usageReportProduced,
  )
import Kanban.UsageCommand (runUsageCommand)
import System.IO (hPutStrLn, stderr)

-- | Every provider the mode reports on, in the order it reports them.
usageProviders :: [UsageProvider]
usageProviders = [Codex, Claude]

-- | Which acquisition path a run selects.
data UsageAcquisition
  = -- | Print a usable cached snapshot without spawning that provider, and
    -- probe live only for a provider the cache has nothing to print for.
    UsageCacheFirst
  | -- | Probe both providers regardless of what the cache holds.
    UsageForceFresh
  deriving stock (Eq, Show)

-- | Everything the run-and-exit mode needs that is not configuration.
--
-- @usageModeCache@ is the effective snapshot-caching decision — @--no-cache@
-- or a global @cache = false@ turns it off — and governs the @usage.json@
-- snapshot file only.  A configured usage command still gets the XDG scratch
-- directory it is launched from either way; that directory is not a snapshot.
data UsageMode = UsageMode
  { usageModeAcquisition :: UsageAcquisition,
    usageModeCache :: Bool,
    usageModeJson :: Bool
  }
  deriving stock (Eq, Show)

-- | Routes a usage refresh to the configured external command when one is set,
-- or to the built-in provider otherwise (§14: "the external command is the
-- provider").
runUsageProvider :: Int -> Maybe UsageCommandConfig -> (Int -> IO (Either ProviderError UsageSnapshot)) -> IO (Either ProviderError UsageSnapshot)
runUsageProvider timeoutMicros Nothing builtIn = builtIn timeoutMicros
runUsageProvider timeoutMicros (Just command) _ = runUsageCommand timeoutMicros command.usageCommandArgv

codexRefreshTimeoutMicros, claudeRefreshTimeoutMicros :: ResolvedConfig -> Int
codexRefreshTimeoutMicros config = config.resolvedTimeouts.timeoutsCodexSeconds * 1000000
claudeRefreshTimeoutMicros config = config.resolvedTimeouts.timeoutsClaudeSeconds * 1000000

-- | The one place a provider's timeout, its configured command, and its
-- built-in integration are put together.
--
-- @kanban --ping@'s post-ping refresh comes through here too, so a configured
-- command replaces the built-in probe there exactly as it does for the board
-- and @--usage@ — and replaces only that refresh, never the ping itself.
fetchProviderUsage :: ResolvedConfig -> UsageProvider -> IO (Either ProviderError UsageSnapshot)
fetchProviderUsage config Codex =
  runUsageProvider (codexRefreshTimeoutMicros config) config.resolvedUsage.usageCodexCommand fetchCodexUsage
fetchProviderUsage config Claude =
  runUsageProvider (claudeRefreshTimeoutMicros config) config.resolvedUsage.usageClaudeCommand fetchClaudeUsage

-- | Where one provider's reported windows came from.  Only a live result is
-- ever written back, so a cache hit cannot rewrite the file it was read from,
-- and a provider that failed live cannot erase the last good snapshot stored
-- beside it.
data Acquired
  = AcquiredFromCache UsageSnapshot
  | AcquiredLive (Either ProviderError UsageSnapshot)

-- | Acquires both providers under the selected path, returning the report and
-- any non-fatal cache warnings.
--
-- The report always describes what the selected path produced: a forced-live
-- run that fails reports that failure rather than substituting the older
-- cached snapshot, even though an enabled cache keeps that snapshot on disk.
acquireUsageReport :: UsageAcquisition -> Bool -> ResolvedConfig -> IO (UsageReport, [Text])
acquireUsageReport acquisition cacheOn config = do
  (cached, loadWarnings) <- if cacheOn then loadCached else pure (Map.empty, [])
  acquired <- mapM (\provider -> (,) provider <$> acquireOne cached provider) usageProviders
  writeWarnings <- writeBack cached acquired
  pure (UsageReport (map (fmap outcomeOf) acquired), loadWarnings <> writeWarnings)
  where
    loadCached = do
      load <- loadUsageCache
      pure $ case load of
        UsageCacheAbsent -> (Map.empty, [])
        UsageCacheInvalid message -> (Map.empty, [message])
        UsageCacheLoaded snapshots -> (snapshots, [])

    acquireOne cached provider = case acquisition of
      UsageCacheFirst | Just snapshot <- usableCached cached provider -> pure (AcquiredFromCache snapshot)
      _ -> AcquiredLive <$> fetchProviderUsage config provider

    -- Merged onto whatever was already stored rather than replacing it, so a
    -- run in which one provider fails preserves the other's cached snapshot
    -- exactly as the dashboard's own refresh does.
    writeBack cached acquired
      | not cacheOn || Map.null fresh = pure []
      | otherwise = either (: []) (const []) <$> writeUsageCache (Map.union fresh cached)
      where
        fresh = Map.fromList [(provider, snapshot) | (provider, AcquiredLive (Right snapshot)) <- acquired]

    outcomeOf (AcquiredFromCache snapshot) = UsageAvailable snapshot
    outcomeOf (AcquiredLive (Right snapshot)) = UsageAvailable snapshot
    outcomeOf (AcquiredLive (Left providerError)) = UsageFailed providerError.providerErrorMessage

-- | A cached entry counts as a hit only when it actually holds windows.
-- Treating an empty snapshot as one would both suppress the live probe a cold
-- provider is owed and report success for a provider that produced nothing.
usableCached :: Map UsageProvider UsageSnapshot -> UsageProvider -> Maybe UsageSnapshot
usableCached cached provider = do
  snapshot <- Map.lookup provider cached
  if null snapshot.usageWindows then Nothing else Just snapshot

-- | The whole run-and-exit mode, returning whether any provider produced
-- windows so the caller can set the exit status.
--
-- Warnings go to stderr in both renderings, so a @--json@ consumer's stdout
-- carries the document and nothing else.  The clock and zone are read once
-- here and handed to the pure renderer; nothing below this point reads either.
runUsageMode :: UsageMode -> ResolvedConfig -> IO Bool
runUsageMode mode config = do
  (report, warnings) <- acquireUsageReport mode.usageModeAcquisition mode.usageModeCache config
  mapM_ (\warning -> hPutStrLn stderr ("kanban: warning: " <> Text.unpack warning)) warnings
  if mode.usageModeJson
    then LazyChar8.putStrLn (encode (usageReportDocument report))
    else do
      zone <- getCurrentTimeZone
      now <- getCurrentTime
      mapM_ TextIO.putStrLn (renderUsageReport zone now report)
  pure (usageReportProduced report)
