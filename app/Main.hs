module Main (main) where

import Control.Monad (unless)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Kanban.CLI (LaunchMode (..), Options (..), launchMode, launchModeNeedsProvider, launchModeRefusal, optionsParserInfo)
import Kanban.Config (RawConfig (..), cacheEnabled, configuredRepositoryPaths, loadRawConfig, repositoryIdentity, resolveConfig, resolveConfigPathOption, resolveGlobalConfig)
import Kanban.Domain (Repository (..))
import Kanban.GlyphTest (runGlyphTest)
import Kanban.Models (OperatingMode (..), loadModelRoster, loadedOperatingMode)
import Kanban.Ping (PingMode (..), pingBrandRefusal, pingRepositoryIdentity, pingResolvedConfig, resolvePingBrand, runPingMode)
import Kanban.Preflight (doctorLines, doctorReady, gatherPreflightEnvironment)
import Kanban.Repository (resolveRepository, resolveRepositoryRoster)
import Kanban.ReviewToolServer (serveReviewTools)
import Kanban.UI (runDashboard)
import Kanban.Usage (UsageAcquisition (..), UsageMode (..), runUsageMode)
import Kanban.Worker (runWorker)
import Options.Applicative (execParser)
import System.Exit (exitFailure, exitWith)
import System.IO (hPutStrLn, stderr, stdin, stdout)

main :: IO ()
main = do
  parsedOptions <- execParser optionsParserInfo
  -- Ahead of mode selection, because a malformed --ping must exit non-zero
  -- whatever else the invocation names: an earlier run-and-exit mode would
  -- otherwise run, succeed, and leave the unknown or repeated brand
  -- unreported. Only refusal is hoisted — a well-formed ping still yields to
  -- every observational mode below (§5).
  pingBrand <- case parsedOptions.optionPing of
    [] -> pure Nothing
    occurrences -> case resolvePingBrand occurrences of
      Left message -> do
        hPutStrLn stderr ("kanban: " <> Text.unpack message)
        exitFailure
      Right brand -> pure (Just brand)
  -- Selected by 'launchMode' rather than by a cascade of guards here, so that
  -- the one decision about which invocations become a board -- and therefore
  -- which of them take the repository's lease -- lives where the test suite
  -- can reach it. This module is not built by @test-suite kanban-test@.
  let selectedMode = launchMode parsedOptions
  -- The operating mode gate (§14): a mode that reaches a provider has nothing
  -- to reach when the roster loads none. Deliberately after the malformed
  -- --ping refusal above, so an unknown or repeated brand is still reported as
  -- itself; and asked only of the modes that need one, so the dashboard and
  -- the worker do not read models.toml twice. The decision is
  -- 'launchModeRefusal' in the library, which the suite covers; this reports
  -- what it answered and nothing more.
  loadedRoster <-
    if launchModeNeedsProvider selectedMode
      then Just <$> loadModelRoster
      else pure Nothing
  case launchModeRefusal selectedMode <$> loadedRoster of
    Just (Just message) -> do
      hPutStrLn stderr ("kanban: " <> Text.unpack message)
      exitFailure
    _ -> pure ()
  -- The provider set the two run-and-exit modes below report on, retained
  -- from the read the gate above already made rather than loading the file a
  -- second time. Single-agent narrows both to the one loaded brand (§14):
  -- --usage probes and prints that provider alone, and --ping refuses the
  -- other one outright instead of spending its quota.
  --
  -- 'NoAgentMode' stands for "this invocation loaded no roster", which
  -- neither arm below can observe: 'launchModeNeedsProvider' is exactly the
  -- set of modes that load one, and the gate above has already exited for a
  -- roster that loads no provider.
  let operatingMode = maybe NoAgentMode loadedOperatingMode loadedRoster
  case selectedMode of
    WorkerMode workerSpec -> do
      result <- runWorker workerSpec
      case result of
        Left message -> hPutStrLn stderr ("kanban worker: " <> Text.unpack message) >> exitFailure
        Right () -> pure ()
    -- The re-entered review tool server (D-15): speaks MCP on this
    -- process's own stdio to the provider that spawned it and proxies over
    -- the endpoint it was handed. Everything else — configuration, roster,
    -- repository — belongs to the Kanban on the other end.
    ReviewToolServerMode endpointDirectory ->
      exitWith =<< serveReviewTools stdin stdout endpointDirectory
    GlyphTestMode -> runGlyphTest
    -- Read-only, and deliberately ahead of configuration and repository
    -- resolution: a fresh clone with no configured remote still needs to be
    -- able to ask why an AI action would not start.
    DoctorMode -> do
      environment <- gatherPreflightEnvironment parsedOptions.optionPath
      mapM_ TextIO.putStrLn (doctorLines environment)
      unless (doctorReady environment) exitFailure
    -- Configuration but no repository: usage is global (§14), so this answers
    -- from a directory that is not a checkout at all, while still honoring an
    -- explicit --config and the global timeout and cache settings it carries.
    UsageQueryMode -> do
      absoluteConfigPath <- resolveConfigPathOption parsedOptions.optionConfig
      configResult <- loadRawConfig absoluteConfigPath
      case configResult of
        Left message -> do
          hPutStrLn stderr ("kanban: " <> Text.unpack message)
          exitFailure
        Right (rawConfig, warnings) -> do
          mapM_ (\warning -> hPutStrLn stderr ("kanban: warning: " <> Text.unpack warning)) warnings
          let resolvedConfig = resolveGlobalConfig rawConfig
              -- Caching off is forced-live by construction rather than by
              -- accident, so --no-cache and a global cache = false reach the
              -- same acquisition path --fresh does, as section 16 requires of
              -- either setting.
              cacheOn = cacheEnabled parsedOptions resolvedConfig
              mode =
                UsageMode
                  { usageModeAcquisition = if parsedOptions.optionFresh || not cacheOn then UsageForceFresh else UsageCacheFirst,
                    usageModeCache = cacheOn,
                    usageModeJson = parsedOptions.optionJson
                  }
          produced <- runUsageMode mode operatingMode resolvedConfig
          unless produced exitFailure
    -- Last of the run-and-exit modes, and deliberately so: it is the only one
    -- that spends the user's quota (§14), so every observational mode above
    -- wins over it and an invocation naming one of them pings nothing.
    -- The brand gate, after the mode gate above and before any configuration
    -- is read: an install that does not load the named provider spends
    -- nothing and refreshes nothing, rather than redirecting the window to
    -- the brand it does load (§5, §14).
    PingQueryMode
      | Just brand <- pingBrand,
        Just message <- pingBrandRefusal operatingMode brand -> do
          hPutStrLn stderr ("kanban: " <> Text.unpack message)
          exitFailure
    PingQueryMode | Just brand <- pingBrand -> do
      absoluteConfigPath <- resolveConfigPathOption parsedOptions.optionConfig
      configResult <- loadRawConfig absoluteConfigPath
      case configResult of
        Left message -> do
          hPutStrLn stderr ("kanban: " <> Text.unpack message)
          exitFailure
        Right (rawConfig, warnings) -> do
          mapM_ (\warning -> hPutStrLn stderr ("kanban: warning: " <> Text.unpack warning)) warnings
          -- An explicit --repo names a repository without needing a checkout;
          -- without one the invoking directory is asked, and that failing is
          -- not an error, because a ping requires neither.
          identityResult <- pingRepositoryIdentity rawConfig.rawRemoteName parsedOptions.optionPath parsedOptions.optionRepo
          case identityResult of
            Left message -> do
              hPutStrLn stderr ("kanban: " <> Text.unpack message)
              exitFailure
            Right identity -> do
              let resolvedConfig = pingResolvedConfig rawConfig identity
                  mode =
                    PingMode
                      { pingModeBrand = brand,
                        pingModeCache = cacheEnabled parsedOptions resolvedConfig
                      }
              succeeded <- runPingMode mode resolvedConfig
              unless succeeded exitFailure
    -- Unreachable: 'PingQueryMode' is exactly a non-empty @--ping@, and every
    -- such invocation either resolved a brand above or was refused before any
    -- mode ran. It is written out rather than folded into the dashboard case
    -- so that a ping can never fall through and open a board.
    PingQueryMode -> pure ()
    DashboardMode -> do
      -- An explicit --config is resolved against kanban's own launch
      -- directory here, then threaded onward (canonical issue-review and
      -- pull-request workers, spawned from the target repository's
      -- directory) as an absolute path, so it names the same file
      -- regardless of which directory later reads it.
      absoluteConfigPath <- resolveConfigPathOption parsedOptions.optionConfig
      let options = parsedOptions {optionConfig = absoluteConfigPath}
      configResult <- loadRawConfig options.optionConfig
      case configResult of
        Left message -> do
          hPutStrLn stderr ("kanban: " <> Text.unpack message)
          exitFailure
        Right (rawConfig, warnings) -> do
          mapM_ (\warning -> hPutStrLn stderr ("kanban: warning: " <> Text.unpack warning)) warnings
          repositoryResult <- resolveRepository rawConfig.rawRemoteName options.optionPath options.optionRepo
          case repositoryResult of
            Left message -> do
              hPutStrLn stderr ("kanban: " <> Text.unpack message)
              exitFailure
            Right repository -> do
              let ownerName = repositoryIdentity repository.repositoryOwner repository.repositoryName
                  resolvedConfig = resolveConfig ownerName rawConfig
              -- Resolved once the launch repository is known, because the
              -- launch checkout is always a roster member and wins a
              -- collision with its own configured entry. A degraded entry
              -- reports through the in-app notice rather than refusing the
              -- launch, so nothing here can fail the way the resolution
              -- above can.
              roster <-
                resolveRepositoryRoster
                  rawConfig.rawRemoteName
                  (configuredRepositoryPaths rawConfig)
                  repository
              runDashboard options resolvedConfig repository roster
