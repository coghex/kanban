module Kanban.Repository
  ( parseRemoteRepository,
    parseRepositoryName,
    resolveRepository,
    RosterEntry (..),
    RepositoryRoster (..),
    resolveRepositoryRoster,
    rosterDegradationNotices,
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
import Kanban.Config (asciiLowercase, repositoryIdentity)
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

--------------------------------------------------------------------------------
-- The repository roster

-- | One member of the repository roster.
--
-- An entry that degraded stays a member rather than failing the launch: it
-- is a repository the configuration names, whose checkout this machine
-- cannot currently supply.  'rosterEntryCheckout' and
-- 'rosterEntryDiagnostic' are the two halves of exactly that: one is present
-- precisely when the other is absent.
data RosterEntry = RosterEntry
  { -- | The identity this entry is keyed, queried, and reported under: a
    -- configured entry's own @[repositories."owner\/name"]@ key, or the
    -- launch checkout's resolved @owner\/name@.  Never a remote's answer for
    -- a configured entry, so nothing is ever keyed under an identity the
    -- configuration does not name.
    rosterEntryIdentity :: Text,
    -- | Where this entry's checkout is, absent exactly when the entry
    -- degraded.
    rosterEntryCheckout :: Maybe FilePath,
    -- | What was wrong, present exactly when 'rosterEntryCheckout' is
    -- absent.  It reaches the operator through the in-app startup notice
    -- rather than stderr, which Brick paints over the instant it starts.
    rosterEntryDiagnostic :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | The launch checkout's repository followed by every configured entry, in
-- canonical key order.
newtype RepositoryRoster = RepositoryRoster {rosterEntries :: [RosterEntry]}
  deriving stock (Eq, Show)

-- | Resolves the roster: exactly the configured tables that declared a
-- @path@ ('Kanban.Config.configuredRepositoryPaths'), plus the launch
-- checkout's repository, which is always a member whether or not it is
-- configured.
--
-- The launch checkout wins a collision with its own configured entry,
-- silently and without resolving that entry's path: two entries for one
-- @owner\/name@ are never held, and the checkout the operator is actually
-- sitting in is the one the session acts through -- which matters because
-- sessions are routinely launched from linked worktrees.  Membership is
-- compared under 'asciiLowercase', the same fold 'Kanban.Config.resolveConfig'
-- applies when selecting an override table, so a @Coghex\/Kanban@ clone and a
-- @coghex\/kanban@ entry are one entry.
--
-- Every configured path is resolved through 'resolveRepository' with the
-- configured remote name and no @--repo@ override: @--repo@ is the launch
-- checkout's escape hatch for the repository the operator named on this
-- invocation, and applying it to a roster entry would give every entry that
-- one identity.
--
-- Nothing here acquires board authority.  The lease is the launch
-- repository's alone (section 3), and no entry resolved here becomes a
-- board.
resolveRepositoryRoster :: Text -> [(Text, FilePath)] -> Repository -> IO RepositoryRoster
resolveRepositoryRoster remoteName configured launch = do
  configuredEntries <- traverse (resolveConfiguredEntry remoteName) (filter notLaunch configured)
  pure (RepositoryRoster (launchEntry : configuredEntries))
  where
    launchIdentity = repositoryIdentity launch.repositoryOwner launch.repositoryName
    launchEntry =
      RosterEntry
        { rosterEntryIdentity = launchIdentity,
          rosterEntryCheckout = Just launch.repositoryRoot,
          rosterEntryDiagnostic = Nothing
        }
    -- Both sides are folded rather than only the launch identity.  A
    -- configured key is canonical lowercase already, so folding it changes
    -- nothing today; spelling the comparison once on both sides is what
    -- keeps it one rule instead of two that could disagree.
    notLaunch (key, _) = asciiLowercase key /= asciiLowercase launchIdentity

resolveConfiguredEntry :: Text -> (Text, FilePath) -> IO RosterEntry
resolveConfiguredEntry remoteName (key, path) = do
  result <- resolveRepository remoteName path Nothing
  pure $ case result of
    Left message -> degradedEntry key path message
    Right resolved
      | asciiLowercase resolvedIdentity == asciiLowercase key ->
          RosterEntry
            { rosterEntryIdentity = key,
              rosterEntryCheckout = Just resolved.repositoryRoot,
              rosterEntryDiagnostic = Nothing
            }
      | otherwise -> degradedEntry key path ("it is a checkout of " <> resolvedIdentity)
      where
        -- The key wins.  A checkout whose remote names a different
        -- repository degrades rather than renaming the entry, because a
        -- mistyped key would otherwise silently produce a roster member for
        -- a repository the configuration never named -- and whose override
        -- table would then fail to apply to it.  A difference of ASCII case
        -- alone is not a different repository, so it stays usable.
        resolvedIdentity = repositoryIdentity resolved.repositoryOwner resolved.repositoryName

degradedEntry :: Text -> FilePath -> Text -> RosterEntry
degradedEntry key path detail =
  RosterEntry
    { rosterEntryIdentity = key,
      rosterEntryCheckout = Nothing,
      rosterEntryDiagnostic =
        Just
          ( "repositories.\""
              <> key
              <> "\" has no usable checkout at "
              <> Text.pack path
              <> ": "
              <> detail
          )
    }

-- | One notice fragment per degraded entry, in roster order.  This is the
-- only thing the dashboard reads a roster for in this milestone: the
-- fragments join the usage, history, settings, and authority fragments on
-- the startup notice line, so a mistyped or moved checkout is diagnosable
-- from inside the board instead of from a stderr line the terminal takeover
-- erases.
rosterDegradationNotices :: RepositoryRoster -> [Text]
rosterDegradationNotices roster =
  [diagnostic | entry <- roster.rosterEntries, Just diagnostic <- [entry.rosterEntryDiagnostic]]

--------------------------------------------------------------------------------
-- Repository identity

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
