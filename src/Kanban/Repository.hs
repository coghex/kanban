module Kanban.Repository
  ( parseRepositoryName,
    resolveRepository,
  )
where

import Control.Exception (IOException, try)
import Data.Char (isSpace)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Domain (Repository (..))
import System.Directory (canonicalizePath)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

resolveRepository :: Text -> FilePath -> Maybe String -> IO (Either Text Repository)
resolveRepository remoteName requestedPath explicitRepository = do
  canonicalResult <- try @IOException (canonicalizePath requestedPath)
  case canonicalResult of
    Left exception -> pure (Left ("cannot resolve repository path: " <> Text.pack (show exception)))
    Right canonicalPath -> do
      rootResult <- runGit canonicalPath ["rev-parse", "--show-toplevel"]
      case rootResult of
        Left message -> pure (Left message)
        Right rootOutput -> do
          let root = trimString rootOutput
          identityResult <- case explicitRepository of
            Just repositoryName -> pure (parseRepositoryName (Text.pack repositoryName))
            Nothing -> do
              remoteResult <- runGit root ["remote", "get-url", Text.unpack remoteName]
              pure (remoteResult >>= parseRepositoryName . Text.pack . trimString)
          pure $ do
            (owner, name) <- identityResult
            pure
              Repository
                { repositoryRoot = root,
                  repositoryOwner = owner,
                  repositoryName = name
                }

runGit :: FilePath -> [String] -> IO (Either Text String)
runGit path arguments = do
  result <- try @IOException (readProcessWithExitCode "git" (["-C", path] <> arguments) "")
  pure $ case result of
    Left exception -> Left ("could not run git: " <> Text.pack (show exception))
    Right (ExitSuccess, stdoutText, _) -> Right stdoutText
    Right (ExitFailure _, _, stderrText) ->
      Left ("git could not identify a repository: " <> Text.pack (trimString stderrText))

parseRepositoryName :: Text -> Either Text (Text, Text)
parseRepositoryName rawValue =
  case filter (not . Text.null) (Text.splitOn "/" normalized) of
    [owner, name] -> Right (owner, dropGitSuffix name)
    segments
      | length segments >= 2 ->
          let owner = segments !! (length segments - 2)
              name = dropGitSuffix (last segments)
           in if valid owner name then Right (owner, name) else invalid
    _ -> invalid
  where
    stripped = Text.strip rawValue
    withoutScheme =
      foldl stripKnownPrefix stripped ["https://", "http://", "ssh://", "git://"]
    normalized =
      Text.replace ":" "/"
        . Text.dropWhileEnd (== '/')
        . Text.replace "git@github.com" "github.com"
        $ withoutScheme
    invalid = Left ("cannot derive OWNER/NAME from repository value: " <> rawValue)
    valid owner name = not (Text.null owner) && not (Text.null name)
    stripKnownPrefix value prefix = fromMaybe value (Text.stripPrefix prefix value)

dropGitSuffix :: Text -> Text
dropGitSuffix value = fromMaybe value (Text.stripSuffix ".git" value)

trimString :: String -> String
trimString = reverse . dropWhile isSpace . reverse . dropWhile isSpace
