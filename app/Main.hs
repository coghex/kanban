module Main (main) where

import qualified Data.Text as Text
import Kanban.CLI (Options (..), optionsParserInfo)
import Kanban.Config (RawConfig (..), loadRawConfig, repositoryIdentity, resolveConfig)
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
  options <- execParser optionsParserInfo
  case options.optionWorkerSpec of
    Just workerSpec -> do
      result <- runWorker workerSpec
      case result of
        Left message -> hPutStrLn stderr ("kanban worker: " <> Text.unpack message) >> exitFailure
        Right () -> pure ()
    Nothing | options.optionGlyphTest -> runGlyphTest
    Nothing -> do
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
