module Main (main) where

import Control.Monad (unless)
import qualified Data.Text as Text
import Kanban.CLI (LaunchMode (..), Options (..), launchMode, launchModeNeedsProvider, launchModeRefusal, optionsParserInfo)
import Kanban.Config (RawConfig (..), cacheEnabled, configuredRepositoryPaths, loadRawConfig, repositoryIdentity, resolveConfig, resolveConfigPathOption, resolveGlobalConfig)
import Kanban.Domain (Repository (..))
import Kanban.GlyphTest (runGlyphTest)
import Kanban.Models (OperatingMode (..), loadModelRoster, loadedOperatingMode)
import Kanban.Repository (resolveRepository, resolveRepositoryRoster)
import Kanban.UI (runDashboard)
import Kanban.Usage (UsageAcquisition (..), UsageMode (..), runUsageMode)
import Options.Applicative (execParser)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  parsedOptions <- execParser optionsParserInfo
  -- Selected by 'launchMode' rather than by a cascade of guards here, so that
  -- the one decision about which invocations become a board -- and therefore
  -- which of them take the repository's lease -- lives where the test suite
  -- can reach it. This module is not built by @test-suite kanban-test@.
  let selectedMode = launchMode parsedOptions
  -- The operating mode gate (§14): a mode that reaches a provider has nothing
  -- to reach when the roster loads none. Asked only of the modes that need
  -- one, so the dashboard does not read models.toml twice. The decision is
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
  -- The provider set the run-and-exit mode below reports on, retained from
  -- the read the gate above already made rather than loading the file a
  -- second time. Single-agent narrows it to the one loaded brand (§14).
  --
  -- 'NoAgentMode' stands for "this invocation loaded no roster", which the
  -- usage arm below cannot observe: 'launchModeNeedsProvider' is exactly the
  -- set of modes that load one, and the gate above has already exited for a
  -- roster that loads no provider.
  let operatingMode = maybe NoAgentMode loadedOperatingMode loadedRoster
  case selectedMode of
    GlyphTestMode -> runGlyphTest
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
