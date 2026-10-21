module Main (main) where

import Control.Monad (unless)
import qualified Data.Text as Text
import Kanban.CLI (LaunchMode (..), Options (..), launchMode, optionsParserInfo)
import Kanban.Config (RawConfig (..), cacheEnabled, configuredRepositoryPaths, loadRawConfig, repositoryIdentity, resolveConfig, resolveConfigPathOption, resolveGlobalConfig)
import Kanban.Domain (Repository (..))
import Kanban.GlyphTest (runGlyphTest)
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
  case launchMode parsedOptions of
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
          produced <- runUsageMode mode resolvedConfig
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
