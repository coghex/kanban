module Kanban.Repository
  ( parseRemoteRepository,
    parseRepositoryName,
    resolveRepository,
  )
where

import Control.Exception (IOException, try)
import qualified Data.ByteString as ByteString
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, isSpace)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified GHC.Foreign
import GHC.IO.Encoding (getFileSystemEncoding)
import Kanban.CommandCapture (decodeCommandText, readProcessBytes)
import Kanban.Domain (Repository (..))
import System.Directory (canonicalizePath)
import System.Exit (ExitCode (..))
import System.Process (CreateProcess (..), proc)

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
          root <- trimString <$> decodeRepositoryPath rootOutput
          identityResult <- case explicitRepository of
            Just repositoryName -> pure (parseRepositoryName (Text.pack repositoryName))
            Nothing -> do
              remoteResult <- runGit root ["remote", "get-url", Text.unpack remoteName]
              pure (remoteResult >>= parseRemoteRepository . decodeCommandText)
          pure $ do
            (owner, name) <- identityResult
            pure
              Repository
                { repositoryRoot = root,
                  repositoryOwner = owner,
                  repositoryName = name
                }

-- | Git's output stays bytes until its caller decides what it is: a path
-- ('decodeRepositoryPath') or text ('decodeCommandText'). Decoding it here
-- through the locale's encoding is what turned a checkout whose path or
-- remote the active locale cannot decode into @could not run git@ — a git
-- that had answered correctly, reported as one that could not be run at all
-- (issue #172).
--
-- The directory travels as @cwd@ rather than as @git -C@'s argument, which
-- is the same channel every other consumer of a resolved root already uses
-- ("Kanban.Solve", "Kanban.Review", "Kanban.PullRequestFlow",
-- 'Kanban.Preflight.gatherPreflightEnvironment'). It is not a stylistic
-- choice: @System.Process@ marshals @cwd@ and the executable through
-- 'System.Posix.Internals.withFilePath' — the filesystem encoding, with the
-- surrogate escaping 'decodeRepositoryPath' relies on — but marshals
-- /arguments/ through 'Foreign.C.String.withCString', the foreign encoding,
-- whose failure mode drops what it cannot represent. A path that only the
-- filesystem encoding can carry therefore reaches git intact as @cwd@ and
-- arrives truncated as an argument. @git -C \<dir\>@ is defined as running
-- git as if it had started in @\<dir\>@, so the two are equivalent whenever
-- both work.
runGit :: FilePath -> [String] -> IO (Either Text ByteString.ByteString)
runGit path arguments = do
  result <- try @IOException (readProcessBytes ((proc "git" arguments) {cwd = Just path}))
  pure $ case result of
    Left exception -> Left ("could not run git: " <> Text.pack (show exception))
    Right (ExitSuccess, stdoutBytes, _) -> Right stdoutBytes
    Right (ExitFailure _, _, stderrBytes) ->
      Left ("git could not identify a repository: " <> Text.strip (decodeCommandText stderrBytes))

-- | Decodes bytes that *name a path* the way GHC itself decodes one, rather
-- than as text. The repository root is not a diagnostic: it is handed
-- straight back to the operating system as a subprocess @cwd@, and
-- 'System.Process' encodes a @cwd@ with this very encoding. Round-tripping
-- through it therefore reproduces git's original bytes, so the root still
-- names the real checkout even under a locale whose encoding cannot
-- represent it — where a replacement character would have named a path that
-- does not exist. Under a locale that decodes the path outright this is the
-- string the locale decoder produced anyway.
decodeRepositoryPath :: ByteString.ByteString -> IO FilePath
decodeRepositoryPath bytes = do
  encoding <- getFileSystemEncoding
  ByteString.useAsCStringLen bytes (GHC.Foreign.peekCStringLen encoding)

-- | Parses an explicit @--repo@ value, which the user chose deliberately:
-- the documented bare @OWNER\/NAME@ form, or any remote URL that
-- 'parseRemoteRepository' already accepts.  A @[repositories.*]@
-- configuration key is deliberately stricter than this — canonical lowercase
-- @owner\/name@ only, see @Kanban.Config@ — because it is a stored
-- identifier rather than input typed for one invocation.
parseRepositoryName :: Text -> Either Text (Text, Text)
parseRepositoryName rawValue
  | Just identity <- bareIdentity (Text.strip rawValue) = Right identity
  | Right identity <- parseRemoteRepository rawValue = Right identity
  | otherwise = Left ("cannot derive OWNER/NAME from repository value: " <> rawValue)

-- | Derives @OWNER\/NAME@ from a git remote URL, which the user never chose
-- for kanban's benefit.  Only remotes that unambiguously name a repository
-- on github.com resolve; local paths, other forges, and SSH host aliases
-- fail closed so the dashboard never queries GitHub for an identity the
-- remote did not actually name.  Those setups use the @--repo@ escape hatch
-- described in DESIGN.md section 5.
parseRemoteRepository :: Text -> Either Text (Text, Text)
parseRemoteRepository rawValue =
  case remoteIdentity (Text.strip rawValue) of
    Just identity -> Right identity
    Nothing ->
      Left
        ( "cannot derive OWNER/NAME from remote URL: "
            <> rawValue
            <> " (only github.com remotes resolve automatically; pass --repo OWNER/NAME)"
        )

remoteIdentity :: Text -> Maybe (Text, Text)
remoteIdentity value = case stripKnownScheme value of
  Just afterScheme -> urlIdentity afterScheme
  Nothing -> scpIdentity value

-- | @scheme://authority/path@ forms.  The allowlist covers the schemes
-- GitHub actually serves clone URLs over; @http:\/\/@ is not one of them.
stripKnownScheme :: Text -> Maybe Text
stripKnownScheme value =
  case filter (`Text.isPrefixOf` Text.toLower value) ["https://", "ssh://", "git://"] of
    (scheme : _) -> Just (Text.drop (Text.length scheme) value)
    [] -> Nothing

urlIdentity :: Text -> Maybe (Text, Text)
urlIdentity afterScheme
  | isGitHubAuthority authority = ownerNamePath (Text.drop 1 path)
  | otherwise = Nothing
  where
    (authority, path) = Text.breakOn "/" afterScheme

-- | SCP-style @[user\@]host:path@.  The colon starts the path rather than a
-- port, so @git\@github.com:22\/owner\/name@ is a three-segment path and is
-- rejected.  A slash before the colon means git reads the value as a local
-- path, not an SCP target.
scpIdentity :: Text -> Maybe (Text, Text)
scpIdentity value
  | Text.null rest = Nothing
  | Text.any (== '/') authority = Nothing
  | Text.any (== '@') authority, isGitHubHost (hostOf authority) = ownerNamePath (Text.drop 1 rest)
  | otherwise = Nothing
  where
    (authority, rest) = Text.breakOn ":" value

-- | @[userinfo\@]host[:port]@, with a numeric port when one is present.
isGitHubAuthority :: Text -> Bool
isGitHubAuthority authority =
  isGitHubHost host && (Text.null portSeparator || not (Text.null port) && Text.all isDigit port)
  where
    (host, portSeparator) = Text.breakOn ":" (hostOf authority)
    port = Text.drop 1 portSeparator

-- | Drops optional @userinfo\@@, which may itself contain @\@@.
hostOf :: Text -> Text
hostOf = Text.takeWhileEnd (/= '@')

isGitHubHost :: Text -> Bool
isGitHubHost host = Text.toLower host `elem` ["github.com", "www.github.com"]

-- | Exactly @OWNER\/NAME[.git]@, with leading and trailing slashes ignored.
-- Both segments must look like GitHub identifiers, so a trailing query or
-- fragment cannot smuggle punctuation into the GraphQL query kanban builds
-- from them.
ownerNamePath :: Text -> Maybe (Text, Text)
ownerNamePath path = case filter (not . Text.null) (Text.splitOn "/" path) of
  [owner, rawName] -> identity owner (dropGitSuffix rawName)
  _ -> Nothing
  where
    identity owner name
      | Text.null name = Nothing
      | Text.all isIdentityCharacter owner && Text.all isIdentityCharacter name = Just (owner, name)
      | otherwise = Nothing

isIdentityCharacter :: Char -> Bool
isIdentityCharacter character =
  isAsciiLower character
    || isAsciiUpper character
    || isDigit character
    || character `elem` ("._-" :: String)

-- | The bare @OWNER\/NAME[.git]@ form, rejecting anything carrying URL
-- authority punctuation so a remote URL cannot slip through as a path.
bareIdentity :: Text -> Maybe (Text, Text)
bareIdentity value
  | Text.any (`elem` (":@" :: String)) value = Nothing
  | otherwise = ownerNamePath value

dropGitSuffix :: Text -> Text
dropGitSuffix value = fromMaybe value (Text.stripSuffix ".git" value)

trimString :: String -> String
trimString = reverse . dropWhile isSpace . reverse . dropWhile isSpace
