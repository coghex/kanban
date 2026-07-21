module Main (main) where

import qualified Data.Text as Text
import Kanban.CLI (Options (..), optionsParserInfo)
import Kanban.Config (RawConfig (..), loadRawConfig, repositoryIdentity, resolveConfig, resolveConfigPathOption)
import Kanban.Domain (Repository (..))
import Kanban.GlyphTest (runGlyphTest)
import Kanban.Repository (resolveRepository)
import Kanban.UI (runDashboard)
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
