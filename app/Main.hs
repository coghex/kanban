module Main (main) where

import Control.Monad (unless)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Kanban.CLI (Options (..), optionsParserInfo)
import Kanban.Config (RawConfig (..), cacheEnabled, loadRawConfig, repositoryIdentity, resolveConfig, resolveConfigPathOption, resolveGlobalConfig)
import Kanban.Domain (Repository (..))
import Kanban.GlyphTest (runGlyphTest)
import Kanban.Ping (PingMode (..), resolvePingBrand, runPingMode)
import Kanban.Preflight (doctorLines, doctorReady, gatherPreflightEnvironment)
import Kanban.Repository (resolveRepository)
import Kanban.UI (runDashboard)
import Kanban.Usage (UsageAcquisition (..), UsageMode (..), runUsageMode)
import Kanban.Worker (runWorker)
import Options.Applicative (execParser)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  parsedOptions <- execParser optionsParserInfo
  case parsedOptions.optionWorkerSpec of
    Just workerSpec -> do
      result <- runWorker workerSpec
      case result of
        Left message -> hPutStrLn stderr ("kanban worker: " <> Text.unpack message) >> exitFailure
        Right () -> pure ()
    Nothing | parsedOptions.optionGlyphTest -> runGlyphTest
    -- Read-only, and deliberately ahead of configuration and repository
    -- resolution: a fresh clone with no configured remote still needs to be
    -- able to ask why an AI action would not start.
    Nothing | parsedOptions.optionDoctor -> do
      environment <- gatherPreflightEnvironment parsedOptions.optionPath
      mapM_ TextIO.putStrLn (doctorLines environment)
      unless (doctorReady environment) exitFailure
    -- Configuration but no repository: usage is global (§14), so this answers
    -- from a directory that is not a checkout at all, while still honoring an
    -- explicit --config and the global timeout and cache settings it carries.
    Nothing | parsedOptions.optionUsage -> do
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
    -- Last of the run-and-exit modes, and deliberately so: it is the only one
    -- that spends the user's quota (§14), so every observational mode above
    -- wins over it and an invocation naming one of them pings nothing. Like
    -- --usage it resolves configuration but no repository, because a ping is
    -- global and needs no checkout.
    Nothing | not (null parsedOptions.optionPing) ->
      case resolvePingBrand parsedOptions.optionPing of
        Left message -> do
          hPutStrLn stderr ("kanban: " <> Text.unpack message)
          exitFailure
        Right brand -> do
          absoluteConfigPath <- resolveConfigPathOption parsedOptions.optionConfig
          configResult <- loadRawConfig absoluteConfigPath
          case configResult of
            Left message -> do
              hPutStrLn stderr ("kanban: " <> Text.unpack message)
              exitFailure
            Right (rawConfig, warnings) -> do
              mapM_ (\warning -> hPutStrLn stderr ("kanban: warning: " <> Text.unpack warning)) warnings
              let resolvedConfig = resolveGlobalConfig rawConfig
                  mode =
                    PingMode
                      { pingModeBrand = brand,
                        pingModeCache = cacheEnabled parsedOptions resolvedConfig
                      }
              succeeded <- runPingMode mode resolvedConfig
              unless succeeded exitFailure
    Nothing -> do
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
              runDashboard options resolvedConfig repository
