-- | Raw environment observation for Kanban's optional AI actions: probe
-- acquisition (executable resolution, a @--version@ read, a provider's own
-- auth-status query, a provider's own plugin listing, and a stat of the
-- Kanban-managed canonical review backend) and the pure classifiers that
-- turn each probe's raw output into an observation.
--
-- Every probe here is status-only and never mutates the filesystem,
-- provider configuration, launchd, or GitHub; see 'Kanban.Preflight' for
-- that discipline's full rationale. This module is internal — 'Kanban.Preflight'
-- re-exports the parts of it that module's public contract promises.
module Kanban.Preflight.Environment where

import Control.Exception (IOException, try)
import Data.Aeson (Value (..), eitherDecodeStrict')
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as ByteString
import Data.Char (isDigit)
import Data.Foldable (toList)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Kanban.CommandCapture (decodeCommandText, readProcessBytes)
import Kanban.Review (selectCanonicalIssueReviewer)
import Kanban.Solve (SolverBrand (..))
import System.Directory (doesFileExist, doesPathExist, findExecutable, pathIsSymbolicLink)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (catchIOError)
import System.Process (CreateProcess (..), proc)
import System.Timeout (timeout)
import Text.Read (readMaybe)

-- | A single status-only probe's outcome: either it could not be run to
-- completion at all (spawn failure or timeout), or it exited with the given
-- code and combined output.
type ProbeResult = Either Text (ExitCode, Text)

-- | Whether a provider CLI reports itself signed in. 'AuthUnknown' covers a
-- probe that could not be interpreted, including an installation too old to
-- offer the auth-status subcommand at all.
data AuthObservation
  = AuthAuthenticated
  | AuthNotAuthenticated Text
  | AuthUnknown Text
  deriving stock (Eq, Show)

-- | Whether the tracked Kanban workflow bundle is installed and enabled in
-- a provider's own plugin registry.
data BundleObservation
  = BundleEnabled
  | BundleDisabled
  | BundleAbsent
  | BundleUnknown Text
  deriving stock (Eq, Show)

data VersionObservation
  = VersionSupported Text
  | VersionUnsupported Text Text
  | VersionUnknown Text
  deriving stock (Eq, Show)

data ProviderProbe = ProviderProbe
  { probeBrand :: SolverBrand,
    probeExecutable :: Maybe FilePath,
    probeVersion :: VersionObservation,
    probeAuth :: AuthObservation,
    probeBundle :: BundleObservation
  }
  deriving stock (Eq, Show)

data GitHubObservation
  = GitHubReady
  | GitHubExecutableMissing
  | GitHubNotAuthenticated Text
  | GitHubUnknown Text
  deriving stock (Eq, Show)

-- | The state of the Kanban-managed canonical issue-review backend.
-- 'ReviewBackendConflicting' is the case @tools\/install_issue_review.py@
-- refuses to resolve on its own: something that is not a usable backend
-- already occupies the install path, so setup will not overwrite it and the
-- user has to clear it first. 'ReviewBackendUnresolved' is the earlier
-- failure of not knowing which path to look at, because the installer's
-- discovery record is there but unusable; it carries
-- 'Kanban.Review.selectCanonicalIssueReviewer''s own diagnostic rather than
-- restating it.
data ReviewBackendObservation
  = ReviewBackendReadyAt FilePath
  | ReviewBackendMissing FilePath
  | ReviewBackendConflicting FilePath Text
  | ReviewBackendUnresolved Text
  | ReviewBackendInterpreterMissing
  deriving stock (Eq, Show)

data PreflightEnvironment = PreflightEnvironment
  { environmentCodex :: ProviderProbe,
    environmentClaude :: ProviderProbe,
    environmentGitHub :: GitHubObservation,
    environmentReviewBackend :: ReviewBackendObservation
  }
  deriving stock (Eq, Show)

brandExecutable :: SolverBrand -> Text
brandExecutable CodexSolver = "codex"
brandExecutable ClaudeSolver = "claude"

-- | The versions the tracked plugin bundles were verified against
-- (@codex-plugin\/README.md@, @claude-plugin\/README.md@); older releases
-- do not provide the plugin subcommand family the bundles install through.
minimumCodexVersion :: [Int]
minimumCodexVersion = [0, 144, 6]

minimumClaudeVersion :: [Int]
minimumClaudeVersion = [2, 1, 216]

-- Pure classification -------------------------------------------------------

-- | @codex login status@ prints its state and exits 0 when signed in. A
-- non-zero exit from a release that understands the subcommand means "not
-- signed in"; one that does not understand it is an unknown, not a
-- negative, so an older CLI never produces a false blocking verdict.
classifyCodexAuth :: ProbeResult -> AuthObservation
classifyCodexAuth (Left message) = AuthUnknown message
classifyCodexAuth (Right (ExitSuccess, output))
  | "not logged in" `Text.isInfixOf` folded = AuthNotAuthenticated (firstLine output)
  | Text.null (Text.strip output) = AuthUnknown "codex login status printed nothing"
  | otherwise = AuthAuthenticated
  where
    folded = Text.toCaseFold output
classifyCodexAuth (Right (ExitFailure code, output))
  | unsupportedSubcommand output = AuthUnknown ("codex login status is unavailable: " <> firstLine output)
  | otherwise = AuthNotAuthenticated (probeFailureDetail "codex login status" code output)

-- | @claude auth status@ answers with a JSON object carrying @loggedIn@.
-- Only that field is treated as definitive; anything else is unknown, for
-- the same reason as 'classifyCodexAuth'.
classifyClaudeAuth :: ProbeResult -> AuthObservation
classifyClaudeAuth (Left message) = AuthUnknown message
classifyClaudeAuth (Right (code, output)) = case decodeJson output >>= loggedInField of
  Just True -> AuthAuthenticated
  Just False -> AuthNotAuthenticated "claude auth status reports no signed-in account"
  Nothing -> case code of
    ExitSuccess -> AuthUnknown "could not read a login state from claude auth status"
    ExitFailure status
      | unsupportedSubcommand output -> AuthUnknown ("claude auth status is unavailable: " <> firstLine output)
      | otherwise -> AuthNotAuthenticated (probeFailureDetail "claude auth status" status output)
  where
    loggedInField value = case value of
      Object object -> case KeyMap.lookup "loggedIn" object of
        Just (Bool flag) -> Just flag
        _ -> Nothing
      _ -> Nothing

-- | Read a provider's own @plugin list --json@ output. Both providers'
-- listings are walked structurally for an object naming @kanban@kanban@, so
-- neither listing's exact envelope is baked in here; an output that cannot
-- be read at all stays unknown rather than claiming the bundle is absent.
classifyBundleListing :: ProbeResult -> BundleObservation
classifyBundleListing (Left message) = BundleUnknown message
classifyBundleListing (Right (ExitFailure code, output))
  | unsupportedSubcommand output = BundleUnknown ("plugin listing is unavailable: " <> firstLine output)
  | otherwise = BundleUnknown (probeFailureDetail "plugin list --json" code output)
classifyBundleListing (Right (ExitSuccess, output)) = case decodeJson output of
  Nothing -> BundleUnknown "could not decode the provider's plugin listing"
  Just value -> case kanbanPluginEntries value of
    [] -> BundleAbsent
    entries
      | any entryEnabled entries -> BundleEnabled
      | any entryInstalled entries -> BundleDisabled
      | otherwise -> BundleAbsent

kanbanPluginIdentifier :: Text
kanbanPluginIdentifier = "kanban@kanban"

-- | Every object anywhere in a plugin listing that identifies itself as the
-- Kanban bundle, under either provider's identifier field.
kanbanPluginEntries :: Value -> [KeyMap.KeyMap Value]
kanbanPluginEntries value = case value of
  Object object ->
    [object | any isKanbanIdentifier (mapMaybe (`KeyMap.lookup` object) ["pluginId", "id"])]
      <> concatMap kanbanPluginEntries (KeyMap.elems object)
  Array items -> concatMap kanbanPluginEntries (toList items)
  _ -> []
  where
    isKanbanIdentifier (String text) = text == kanbanPluginIdentifier
    isKanbanIdentifier _ = False

-- | A listing that does not carry an @installed@ field enumerates installed
-- plugins only, so a listed entry counts as installed there.
entryInstalled :: KeyMap.KeyMap Value -> Bool
entryInstalled object = case KeyMap.lookup "installed" object of
  Just (Bool flag) -> flag
  _ -> True

entryEnabled :: KeyMap.KeyMap Value -> Bool
entryEnabled object =
  entryInstalled object && case KeyMap.lookup "enabled" object of
    Just (Bool flag) -> flag
    _ -> True

classifyVersion :: [Int] -> ProbeResult -> VersionObservation
classifyVersion _ (Left message) = VersionUnknown message
classifyVersion _ (Right (ExitFailure code, output)) =
  VersionUnknown (probeFailureDetail "--version" code output)
classifyVersion required (Right (ExitSuccess, output)) = case parseVersion output of
  Nothing -> VersionUnknown ("could not read a version from " <> quoted (firstLine output))
  Just (rendered, components)
    | padComponents components >= padComponents required -> VersionSupported rendered
    | otherwise -> VersionUnsupported rendered (renderVersion required)
  where
    padComponents components = take width (components <> repeat 0)
    width = max (length required) 4

-- | The first dotted-numeric token in a @--version@ line, e.g. @0.144.6@
-- from @codex-cli 0.144.6@ or @2.1.220@ from @2.1.220 (Claude Code)@.
parseVersion :: Text -> Maybe (Text, [Int])
parseVersion output = listToMaybe (mapMaybe versionToken (Text.words output))
  where
    versionToken word = do
      let candidate = Text.takeWhile (\character -> isDigit character || character == '.') word
          parts = Text.splitOn "." candidate
      components <- traverse (readMaybe . Text.unpack) parts
      if length components >= 2 && Text.all (/= ' ') candidate
        then Just (candidate, components)
        else Nothing

renderVersion :: [Int] -> Text
renderVersion = Text.intercalate "." . map (Text.pack . show)

-- | Whether a failed probe failed because the CLI does not know the
-- subcommand, rather than because of what the subcommand found.
unsupportedSubcommand :: Text -> Bool
unsupportedSubcommand output =
  any (`Text.isInfixOf` Text.toCaseFold output) ["unknown command", "unrecognized subcommand", "unknown option", "unexpected argument", "usage:"]

probeFailureDetail :: Text -> Int -> Text -> Text
probeFailureDetail command code output =
  command <> " exited " <> Text.pack (show code) <> detail
  where
    summary = firstLine output
    detail = if Text.null summary then "" else " (" <> summary <> ")"

firstLine :: Text -> Text
firstLine = Text.strip . Text.takeWhile (/= '\n') . Text.strip

quoted :: Text -> Text
quoted value = "\"" <> value <> "\""

decodeJson :: Text -> Maybe Value
decodeJson output = case eitherDecodeStrict' (TextEncoding.encodeUtf8 (Text.strip output)) of
  Left _ -> Nothing
  Right value -> Just value

-- Probing -------------------------------------------------------------------

-- | Run every status-only probe once. @workingDirectory@ is the repository
-- the board is pointed at, so a provider's plugin listing reports what a
-- session started there would actually see (Claude Code resolves
-- project-scoped installs relative to the invoking directory).
gatherPreflightEnvironment :: FilePath -> IO PreflightEnvironment
gatherPreflightEnvironment workingDirectory = do
  codex <- probeProvider workingDirectory CodexSolver
  claude <- probeProvider workingDirectory ClaudeSolver
  github <- probeGitHub workingDirectory
  reviewBackend <- probeReviewBackend
  pure
    PreflightEnvironment
      { environmentCodex = codex,
        environmentClaude = claude,
        environmentGitHub = github,
        environmentReviewBackend = reviewBackend
      }

probeProvider :: FilePath -> SolverBrand -> IO ProviderProbe
probeProvider workingDirectory brand = do
  executable <- findExecutable (Text.unpack (brandExecutable brand))
  case executable of
    Nothing ->
      pure
        ProviderProbe
          { probeBrand = brand,
            probeExecutable = Nothing,
            probeVersion = VersionUnknown "not probed",
            probeAuth = AuthUnknown "not probed",
            probeBundle = BundleUnknown "not probed"
          }
    Just path -> do
      version <- classifyVersion (minimumVersion brand) <$> runProbe workingDirectory path ["--version"]
      auth <- authClassifier brand <$> runProbe workingDirectory path (authArguments brand)
      bundle <- classifyBundleListing <$> runProbe workingDirectory path ["plugin", "list", "--json"]
      pure
        ProviderProbe
          { probeBrand = brand,
            probeExecutable = Just path,
            probeVersion = version,
            probeAuth = auth,
            probeBundle = bundle
          }
  where
    minimumVersion CodexSolver = minimumCodexVersion
    minimumVersion ClaudeSolver = minimumClaudeVersion
    authClassifier CodexSolver = classifyCodexAuth
    authClassifier ClaudeSolver = classifyClaudeAuth
    authArguments CodexSolver = ["login", "status"]
    authArguments ClaudeSolver = ["auth", "status"]

probeGitHub :: FilePath -> IO GitHubObservation
probeGitHub workingDirectory = do
  executable <- findExecutable "gh"
  case executable of
    Nothing -> pure GitHubExecutableMissing
    Just path -> do
      result <- runProbe workingDirectory path ["auth", "status"]
      pure $ case result of
        Left message -> GitHubUnknown message
        Right (ExitSuccess, _) -> GitHubReady
        Right (ExitFailure code, output)
          | unsupportedSubcommand output -> GitHubUnknown ("gh auth status is unavailable: " <> firstLine output)
          | otherwise -> GitHubNotAuthenticated (probeFailureDetail "gh auth status" code output)

-- | Stat the Kanban-managed backend install location the same way
-- 'Kanban.Review.resolveCanonicalIssueReviewer' selects it — the same
-- override, then installer-written record, then compatibility default — but
-- tell a never-installed path apart from one already occupied by something
-- else. The selection deliberately stops short of asking whether the backend
-- is there: that is the distinction this probe exists to draw.
probeReviewBackend :: IO ReviewBackendObservation
probeReviewBackend = do
  interpreter <- findExecutable "python3"
  case interpreter of
    Nothing -> pure ReviewBackendInterpreterMissing
    Just _ -> do
      selected <- selectCanonicalIssueReviewer
      case selected of
        Left message -> pure (ReviewBackendUnresolved message)
        Right (_, scriptPath) -> do
          -- The backend cannot run without its config module:
          -- approve_issues.py imports kanban_config at module scope, and the
          -- issue-review setup component installs both. A half-installed
          -- pair fails at import time, so both links are part of
          -- "installed" here.
          let companionPath = takeDirectory scriptPath </> "kanban_config.py"
          observations <- mapM probeInstalledAsset [scriptPath, companionPath]
          pure (foldr worseObservation (ReviewBackendReadyAt scriptPath) observations)

-- | Classify one installed backend file. Only a symlink resolving to a file
-- that carries that asset's own identity marker counts as installed: that
-- is the single shape @tools\/install_issue_review.py@ creates, and the
-- only one it will converge on a re-run. Anything else already occupying
-- the path — an ordinary copy, a directory, a link whose target has gone
-- away, a link to some unrelated script — is what setup refuses to replace,
-- so reporting it ready would both contradict setup and hand the canonical
-- reviewer an unrecognized file to execute.
probeInstalledAsset :: FilePath -> IO ReviewBackendObservation
probeInstalledAsset path = do
  linked <- catchIOError (pathIsSymbolicLink path) (const (pure False))
  usable <- doesFileExist path
  occupied <- doesPathExist path
  case (linked, usable, occupied) of
    (False, _, True) -> pure (ReviewBackendConflicting path "something that is not a Kanban-managed link")
    (False, _, False) -> pure (ReviewBackendMissing path)
    (True, False, _) -> pure (ReviewBackendConflicting path "a symlink that no longer resolves to a file")
    (True, True, _) -> do
      recognized <- isManagedAsset path
      pure $
        if recognized
          then ReviewBackendReadyAt path
          else ReviewBackendConflicting path "a symlink to a file that is not Kanban's own tracked backend"

-- | Whether an installed file really is this repository's tracked asset,
-- read from the identity marker the asset itself carries. Location proves
-- nothing — a link to any @.../tools/approve_issues.py@ satisfies every
-- shape test while being someone else's file — so the same marker
-- @tools\/install_issue_review.py@ checks before replacing a link is what
-- this checks before trusting one.
isManagedAsset :: FilePath -> IO Bool
isManagedAsset path = do
  content <- try (ByteString.readFile path)
  pure $ case content of
    Left (_ :: IOException) -> False
    Right bytes -> marker `ByteString.isInfixOf` bytes
  where
    marker = TextEncoding.encodeUtf8 (Text.pack ("kanban-managed-asset:issue-review/" <> takeFileName' path))

-- | The most actionable of several install-path observations: a conflict
-- the user must clear outranks a missing file, which outranks readiness.
worseObservation :: ReviewBackendObservation -> ReviewBackendObservation -> ReviewBackendObservation
worseObservation left right = case (left, right) of
  (conflicting@(ReviewBackendConflicting _ _), _) -> conflicting
  (_, conflicting@(ReviewBackendConflicting _ _)) -> conflicting
  (missing@(ReviewBackendMissing _), _) -> missing
  (_, missing@(ReviewBackendMissing _)) -> missing
  (interpreter@ReviewBackendInterpreterMissing, _) -> interpreter
  (_, other) -> other

-- | Bounded, non-interactive, output-capturing probe. Empty stdin and a
-- hard timeout keep a probe from ever waiting on a prompt.
--
-- Output is captured as bytes and decoded leniently, so what reaches the
-- classifiers is the CLI's real exit status and its real output. Decoding
-- through the locale's encoding instead meant one byte it could not read —
-- from a version banner, a sign-in message, or a plugin listing — was
-- raised as an 'IOException' and reported as a probe that could not be run,
-- replacing the provider's own answer with a decoder failure (issue #172).
runProbe :: FilePath -> FilePath -> [String] -> IO ProbeResult
runProbe workingDirectory executable arguments = do
  let spec = (proc executable arguments) {cwd = Just workingDirectory}
  outcome <- timeout probeTimeoutMicros (try (readProcessBytes spec))
  pure $ case outcome of
    Nothing -> Left (Text.pack (takeFileName' executable) <> " " <> Text.unwords (map Text.pack arguments) <> " timed out")
    Just (Left exception) -> Left (Text.pack (show (exception :: IOException)))
    Just (Right (code, out, err)) -> Right (code, decodeCommandText out <> decodeCommandText err)

takeFileName' :: FilePath -> FilePath
takeFileName' = reverse . takeWhile (/= '/') . reverse

-- | Generous next to what these probes actually cost (a full gather runs in
-- about two seconds), but small enough that a hung provider CLI delays an
-- action by seconds rather than minutes. A timed-out probe is an unknown,
-- so the action still runs.
probeTimeoutMicros :: Int
probeTimeoutMicros = 8 * 1000 * 1000
