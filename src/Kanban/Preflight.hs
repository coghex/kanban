-- | Read-only readiness probing for Kanban's optional AI actions.
--
-- Every probe here is status-only: executable resolution, a @--version@
-- read, a provider's own auth-status query, a provider's own plugin
-- listing, and a stat of the Kanban-managed canonical review backend.
-- Nothing in this module starts an agent session, triggers a login flow,
-- consumes model quota, or mutates the filesystem, provider configuration,
-- launchd, or GitHub. That discipline is what lets the board run a
-- preflight before every AI action and lets @kanban --doctor@ run it on a
-- fresh machine.
--
-- The IO surface is one 'gatherPreflightEnvironment' call that records raw
-- observations; everything the board and the doctor report is then derived
-- purely from that record, so the derivation is unit-testable without any
-- process at all.
--
-- A probe that cannot reach a definite conclusion reports
-- 'PreflightUnknown' and never blocks: a diagnostic that guessed wrong
-- would break a working setup, which is worse than letting the action fail
-- on its own terms.
module Kanban.Preflight
  ( AuthObservation (..),
    BundleObservation (..),
    GitHubObservation (..),
    IssueOrigin (..),
    PreflightAction (..),
    PreflightCheck (..),
    PreflightEnvironment (..),
    PreflightProblem (..),
    PreflightReport (..),
    PreflightStatus (..),
    ProbeResult,
    ProviderProbe (..),
    ReviewBackendObservation (..),
    VersionObservation (..),
    actionLabel,
    actionReport,
    blockingRemediation,
    canonicalReviewBrands,
    issueOriginFromBody,
    revisionAuthorBrand,
    classifyBundleListing,
    classifyClaudeAuth,
    classifyCodexAuth,
    classifyVersion,
    doctorActions,
    doctorLines,
    doctorReady,
    gatherPreflightEnvironment,
    minimumClaudeVersion,
    minimumCodexVersion,
    preflightDiagnostic,
    preflightDiagnosticDetail,
    problemLabel,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (Value (..), eitherDecodeStrict')
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as ByteString
import Data.Char (isDigit)
import Data.Foldable (toList)
import Data.List (find)
import Data.Maybe (isNothing, listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Kanban.PullRequestFlow (PullRequestAction (..), PullRequestOrigin (..), agentForAction)
import Kanban.Review (canonicalIssueReviewerPath)
import Kanban.Solve (SolverBrand (..))
import System.Directory (doesFileExist, doesPathExist, findExecutable, pathIsSymbolicLink)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (catchIOError)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
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
-- user has to clear it first.
data ReviewBackendObservation
  = ReviewBackendReadyAt FilePath
  | ReviewBackendMissing FilePath
  | ReviewBackendConflicting FilePath Text
  | ReviewBackendInterpreterMissing
  deriving stock (Eq, Show)

data PreflightEnvironment = PreflightEnvironment
  { environmentCodex :: ProviderProbe,
    environmentClaude :: ProviderProbe,
    environmentGitHub :: GitHubObservation,
    environmentReviewBackend :: ReviewBackendObservation
  }
  deriving stock (Eq, Show)

-- | The six causes a preflight must tell apart, so the board can name the
-- remediation instead of reporting a generic agent failure.
data PreflightProblem
  = ExecutableUnavailable
  | ProviderUnauthenticated
  | WorkflowBundleUnavailable
  | ReviewBackendUnavailable
  | GitHubUnavailable
  | ConflictingInstallation
  deriving stock (Eq, Ord, Show)

problemLabel :: PreflightProblem -> Text
problemLabel ExecutableUnavailable = "executable absent or unsupported"
problemLabel ProviderUnauthenticated = "provider not authenticated"
problemLabel WorkflowBundleUnavailable = "workflow bundle absent or incompatible"
problemLabel ReviewBackendUnavailable = "canonical review backend unavailable"
problemLabel GitHubUnavailable = "GitHub CLI unavailable or not authenticated"
problemLabel ConflictingInstallation = "conflicting local installation"

-- | A check's outcome. 'PreflightBlocked' is reserved for a definite local
-- observation that the action cannot succeed; anything a probe could not
-- settle is 'PreflightUnknown' and never blocks.
data PreflightStatus
  = PreflightReady Text
  | PreflightUnknown Text
  | PreflightBlocked PreflightProblem Text Text
  deriving stock (Eq, Show)

data PreflightCheck = PreflightCheck
  { checkName :: Text,
    checkStatus :: PreflightStatus
  }
  deriving stock (Eq, Show)

-- | The in-app AI actions launched from the board, each reported
-- separately: an action is only as ready as the dependencies it actually
-- reaches for. The PR drainer is deliberately absent — it keeps its own
-- dedicated install and status flow.
-- | Which agent authored an issue, since both issue-side actions route
-- their provider work by it.
data IssueOrigin = IssueOriginCodex | IssueOriginClaude | IssueOriginUnmarked
  deriving stock (Eq, Show)

data PreflightAction
  = ActionIssueReview IssueOrigin
  | ActionIssueRevision IssueOrigin
  | ActionSolve SolverBrand
  | ActionAutoSolve SolverBrand
  | ActionPullRequestFlow PullRequestOrigin PullRequestAction
  deriving stock (Eq, Show)

issueOriginFromBody :: Text -> IssueOrigin
issueOriginFromBody body
  | "<!-- issue-origin:claude -->" `Text.isInfixOf` body = IssueOriginClaude
  | "<!-- issue-origin:codex -->" `Text.isInfixOf` body = IssueOriginCodex
  | otherwise = IssueOriginUnmarked

-- | The provider CLIs the canonical backend actually spawns for a review or
-- rereview of this issue: the opposite brand from its origin, or — under
-- the @--legacy-policy dual@ Kanban always passes — both for an unmarked
-- issue. Mirrors @reviewers_for_origin@ in @tools\/approve_issues.py@,
-- which invokes @codex exec@ and @claude -p@ directly, so no packaged
-- workflow bundle is involved.
canonicalReviewBrands :: IssueOrigin -> [SolverBrand]
canonicalReviewBrands IssueOriginClaude = [CodexSolver]
canonicalReviewBrands IssueOriginCodex = [ClaudeSolver]
canonicalReviewBrands IssueOriginUnmarked = [CodexSolver, ClaudeSolver]

-- | Which brand authors a revision's amendment content. A Claude-origin
-- issue routes that authoring through @kanban_run_claude@, so its revision
-- needs the Claude CLI as well as the Codex coordinator thread; a
-- Codex-origin or unmarked issue is authored by the coordinator itself.
-- Mirrors the REVISION rule in
-- 'Kanban.Review.reviewDeveloperInstructions'.
revisionAuthorBrand :: IssueOrigin -> SolverBrand
revisionAuthorBrand IssueOriginClaude = ClaudeSolver
revisionAuthorBrand _ = CodexSolver

data PreflightReport = PreflightReport
  { reportAction :: PreflightAction,
    reportChecks :: [PreflightCheck]
  }
  deriving stock (Eq, Show)

brandExecutable :: SolverBrand -> Text
brandExecutable CodexSolver = "codex"
brandExecutable ClaudeSolver = "claude"

brandProduct :: SolverBrand -> Text
brandProduct CodexSolver = "Codex CLI"
brandProduct ClaudeSolver = "Claude Code"

brandComponent :: SolverBrand -> Text
brandComponent CodexSolver = "codex-plugin"
brandComponent ClaudeSolver = "claude-plugin"

oppositeBrand :: SolverBrand -> SolverBrand
oppositeBrand CodexSolver = ClaudeSolver
oppositeBrand ClaudeSolver = CodexSolver

actionLabel :: PreflightAction -> Text
actionLabel (ActionIssueReview origin) = "issue review/rereview (r) · " <> originLabel origin
actionLabel (ActionIssueRevision origin) = "issue revision (r) · " <> originLabel origin
actionLabel (ActionSolve brand) = "solve (S) · " <> brandExecutable brand
actionLabel (ActionAutoSolve brand) = "auto-solve (A) · " <> brandExecutable brand
actionLabel (ActionPullRequestFlow origin action) =
  "PR " <> pullRequestActionLabel action <> " (r) · " <> pullRequestOriginLabel origin

pullRequestActionLabel :: PullRequestAction -> Text
pullRequestActionLabel PullRequestReview = "review"
pullRequestActionLabel PullRequestRereview = "rereview"
pullRequestActionLabel PullRequestRevision = "revise"

pullRequestOriginLabel :: PullRequestOrigin -> Text
pullRequestOriginLabel PullRequestCodex = "codex-origin"
pullRequestOriginLabel PullRequestClaude = "claude-origin"

originLabel :: IssueOrigin -> Text
originLabel IssueOriginCodex = "codex-origin"
originLabel IssueOriginClaude = "claude-origin"
originLabel IssueOriginUnmarked = "unmarked"

-- | The versions the tracked plugin bundles were verified against
-- (@codex-plugin\/README.md@, @claude-plugin\/README.md@); older releases
-- do not provide the plugin subcommand family the bundles install through.
minimumCodexVersion :: [Int]
minimumCodexVersion = [0, 144, 6]

minimumClaudeVersion :: [Int]
minimumClaudeVersion = [2, 1, 216]

-- | The marker a board-facing failure carries when its cause is missing
-- Kanban-owned setup rather than the agent itself, following the same
-- message-classification idiom 'Kanban.Review.outcomeUnknownDiagnostic'
-- uses.
preflightMarker :: Text
preflightMarker = "kanban setup required: "

preflightDiagnostic :: Text -> Text
preflightDiagnostic detail = preflightMarker <> detail

-- | The remediation carried by a preflight diagnostic, or 'Nothing' for any
-- other failure message.
preflightDiagnosticDetail :: Text -> Maybe Text
preflightDiagnosticDetail = Text.stripPrefix preflightMarker

setupCommand :: Text -> Text
setupCommand component =
  "`python3 tools/setup_workflows.py --component " <> component <> " --apply` from the Kanban checkout"

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

-- Check derivation ----------------------------------------------------------

environmentProbe :: PreflightEnvironment -> SolverBrand -> ProviderProbe
environmentProbe environment CodexSolver = environment.environmentCodex
environmentProbe environment ClaudeSolver = environment.environmentClaude

executableCheck :: ProviderProbe -> PreflightCheck
executableCheck probe = PreflightCheck (name <> " executable") status
  where
    name = brandExecutable probe.probeBrand
    product_ = brandProduct probe.probeBrand
    status = case probe.probeExecutable of
      Nothing ->
        PreflightBlocked
          ExecutableUnavailable
          (name <> " was not found on PATH")
          ("Install " <> product_ <> " and make `" <> name <> "` resolvable on PATH.")
      Just path -> case probe.probeVersion of
        VersionUnsupported found required ->
          PreflightBlocked
            ExecutableUnavailable
            (name <> " " <> found <> " is older than the supported " <> required)
            ("Update " <> product_ <> " to " <> required <> " or newer; older releases cannot install the Kanban workflow bundle.")
        VersionUnknown detail -> PreflightUnknown (Text.pack path <> " (" <> detail <> ")")
        VersionSupported found -> PreflightReady (Text.pack path <> " (" <> found <> ")")

authCheck :: ProviderProbe -> PreflightCheck
authCheck probe = PreflightCheck (name <> " authentication") status
  where
    name = brandExecutable probe.probeBrand
    status = case probe.probeExecutable of
      Nothing -> PreflightUnknown ("not probed; " <> name <> " is not on PATH")
      Just _ -> case probe.probeAuth of
        AuthAuthenticated -> PreflightReady "signed in"
        AuthUnknown detail -> PreflightUnknown detail
        AuthNotAuthenticated detail ->
          PreflightBlocked
            ProviderUnauthenticated
            detail
            ("Sign in with `" <> loginCommand probe.probeBrand <> "`; Kanban never installs credentials or signs in for you.")
    loginCommand CodexSolver = "codex login"
    loginCommand ClaudeSolver = "claude auth login"

bundleCheck :: ProviderProbe -> PreflightCheck
bundleCheck probe = PreflightCheck (name <> " workflow bundle") status
  where
    name = brandExecutable probe.probeBrand
    component = brandComponent probe.probeBrand
    status = case probe.probeExecutable of
      Nothing -> PreflightUnknown ("not probed; " <> name <> " is not on PATH")
      Just _ -> case probe.probeBundle of
        BundleEnabled -> PreflightReady (kanbanPluginIdentifier <> " installed and enabled")
        BundleUnknown detail -> PreflightUnknown detail
        BundleAbsent ->
          PreflightBlocked
            WorkflowBundleUnavailable
            (kanbanPluginIdentifier <> " is not installed for " <> name)
            ("Run " <> setupCommand component <> ".")
        BundleDisabled ->
          PreflightBlocked
            WorkflowBundleUnavailable
            (kanbanPluginIdentifier <> " is installed for " <> name <> " but disabled")
            ("Re-enable it in " <> brandProduct probe.probeBrand <> ", or reinstall it with " <> setupCommand component <> ".")

gitHubCheck :: PreflightEnvironment -> PreflightCheck
gitHubCheck environment = PreflightCheck "GitHub CLI" status
  where
    status = case environment.environmentGitHub of
      GitHubReady -> PreflightReady "gh is authenticated"
      GitHubUnknown detail -> PreflightUnknown detail
      GitHubExecutableMissing ->
        PreflightBlocked
          GitHubUnavailable
          "gh was not found on PATH"
          "Install the GitHub CLI; every Kanban write action goes through it."
      GitHubNotAuthenticated detail ->
        PreflightBlocked
          GitHubUnavailable
          detail
          "Run `gh auth login`; Kanban never provisions GitHub credentials."

reviewBackendCheck :: PreflightEnvironment -> PreflightCheck
reviewBackendCheck environment = PreflightCheck "canonical review backend" status
  where
    status = case environment.environmentReviewBackend of
      ReviewBackendReadyAt path -> PreflightReady (Text.pack path)
      ReviewBackendInterpreterMissing ->
        PreflightBlocked
          ReviewBackendUnavailable
          "python3 was not found on PATH"
          "Install python3; the canonical issue-review backend runs under it."
      ReviewBackendMissing path ->
        PreflightBlocked
          ReviewBackendUnavailable
          ("no canonical issue reviewer at " <> Text.pack path)
          ("Run " <> setupCommand "issue-review" <> ".")
      ReviewBackendConflicting path detail ->
        PreflightBlocked
          ConflictingInstallation
          (Text.pack path <> " is occupied by " <> detail)
          ( "Run "
              <> setupCommand "issue-review"
              <> " to see whether setup can converge it; if it refuses, move or remove that "
              <> "path yourself first. Kanban never replaces an installation it does not recognize."
          )

providerChecks :: Bool -> ProviderProbe -> [PreflightCheck]
providerChecks needsBundle probe =
  [executableCheck probe, authCheck probe] <> [bundleCheck probe | needsBundle]

-- | The checks one action actually depends on. Issue revision runs Kanban's
-- own @codex app-server@ prompts rather than a packaged workflow, so it
-- needs no bundle; auto-solve drives the PR review itself, so it needs the
-- opposite brand too.
actionReport :: PreflightEnvironment -> PreflightAction -> PreflightReport
actionReport environment action = PreflightReport action (checksFor action)
  where
    -- The canonical backend spawns the opposite brand itself (both, for an
    -- unmarked issue under the dual policy Kanban passes), so a review is
    -- only ready if that reviewer's CLI is installed and signed in. No
    -- packaged bundle: the backend runs `codex exec`/`claude -p` directly.
    checksFor (ActionIssueReview origin) =
      concatMap (providerChecks False . environmentProbe environment) (canonicalReviewBrands origin)
        <> [gitHubCheck environment, reviewBackendCheck environment]
    -- The revision coordinator is always Kanban's own @codex app-server@
    -- thread, and neither brand's packaged bundle is involved: it runs
    -- Kanban's own prompts. A Claude-origin issue additionally authors its
    -- amendment through @kanban_run_claude@, so that brand's CLI has to be
    -- installed and signed in too, or the session fails inside the tool
    -- call instead of at the door.
    checksFor (ActionIssueRevision origin) =
      providerChecks False (environmentProbe environment CodexSolver)
        <> [ check
             | revisionAuthorBrand origin == ClaudeSolver,
               check <- providerChecks False (environmentProbe environment ClaudeSolver)
           ]
        <> [gitHubCheck environment]
    checksFor (ActionSolve brand) =
      providerChecks True (environmentProbe environment brand)
        <> [gitHubCheck environment, reviewBackendCheck environment]
    checksFor (ActionAutoSolve brand) =
      providerChecks True (environmentProbe environment brand)
        <> providerChecks True (environmentProbe environment (oppositeBrand brand))
        <> [gitHubCheck environment, reviewBackendCheck environment]
    -- Review and rereview run on the opposite brand from the PR's origin
    -- and are themselves the canonical reviewer, so they need only that
    -- brand. Revision is the exception: it runs on the PR's *own* brand,
    -- then hands off to exactly one canonical rereview by spawning the
    -- opposite brand from inside that session (agent-workflow-contract
    -- §2.2). That nested call is a direct `codex exec`/`claude -p`, so it
    -- needs the executable and a sign-in but no packaged bundle.
    checksFor (ActionPullRequestFlow origin pullRequestAction) =
      providerChecks True (environmentProbe environment launched)
        <> [ check
             | pullRequestAction == PullRequestRevision,
               check <- providerChecks False (environmentProbe environment (oppositeBrand launched))
           ]
        <> [gitHubCheck environment, reviewBackendCheck environment]
      where
        launched = agentForAction origin pullRequestAction

-- | The one-line diagnostic for the first blocking check, or 'Nothing' when
-- nothing definite stands in the action's way.
blockingRemediation :: PreflightReport -> Maybe Text
blockingRemediation report = do
  check <- find (isBlocked . (.checkStatus)) report.reportChecks
  case check.checkStatus of
    PreflightBlocked problem detail remediation ->
      Just (problemLabel problem <> ": " <> detail <> ". " <> remediation)
    _ -> Nothing
  where
    isBlocked (PreflightBlocked _ _ _) = True
    isBlocked _ = False

-- Doctor report -------------------------------------------------------------

doctorActions :: [PreflightAction]
doctorActions =
  [ ActionIssueReview IssueOriginCodex,
    ActionIssueReview IssueOriginClaude,
    ActionIssueReview IssueOriginUnmarked,
    ActionIssueRevision IssueOriginCodex,
    ActionIssueRevision IssueOriginClaude,
    ActionSolve CodexSolver,
    ActionSolve ClaudeSolver,
    ActionAutoSolve CodexSolver,
    ActionAutoSolve ClaudeSolver,
    -- Every board action gets its own line, including rereview: its
    -- dependency set currently matches review's, but the doctor reports
    -- readiness per action a user can select, not per distinct set.
    ActionPullRequestFlow PullRequestCodex PullRequestReview,
    ActionPullRequestFlow PullRequestClaude PullRequestReview,
    ActionPullRequestFlow PullRequestCodex PullRequestRereview,
    ActionPullRequestFlow PullRequestClaude PullRequestRereview,
    ActionPullRequestFlow PullRequestCodex PullRequestRevision,
    ActionPullRequestFlow PullRequestClaude PullRequestRevision
  ]

doctorReady :: PreflightEnvironment -> Bool
doctorReady environment =
  all (isNothing . blockingRemediation . actionReport environment) doctorActions

doctorLines :: PreflightEnvironment -> [Text]
doctorLines environment =
  ["kanban preflight — AI-action readiness (read-only; nothing is installed or started)", ""]
    <> ["Dependencies"]
    <> concatMap renderCheck environmentChecks
    <> ["", "Actions"]
    <> concatMap renderAction doctorActions
    <> ["", summary]
  where
    environmentChecks =
      providerChecks True environment.environmentCodex
        <> providerChecks True environment.environmentClaude
        <> [gitHubCheck environment, reviewBackendCheck environment]
    renderCheck check = ["  " <> pad labelWidth check.checkName <> statusText check.checkStatus]
    renderAction action =
      let report = actionReport environment action
       in case blockingRemediation report of
            Nothing -> ["  " <> pad labelWidth (actionLabel action) <> unresolvedSuffix report]
            Just remediation -> ["  " <> pad labelWidth (actionLabel action) <> "blocked — " <> remediation]
    -- Wide enough for the longest action label, so every status starts in
    -- the same column.
    labelWidth = 35
    unresolvedSuffix report
      | any (isUnknown . (.checkStatus)) report.reportChecks = "ready (some checks were inconclusive)"
      | otherwise = "ready"
    isUnknown (PreflightUnknown _) = True
    isUnknown _ = False
    summary
      | doctorReady environment = "No blocking problems found."
      | otherwise = "Some actions are blocked; see docs/workflow-setup.md."

statusText :: PreflightStatus -> Text
statusText (PreflightReady detail) = "ready — " <> detail
statusText (PreflightUnknown detail) = "unknown — " <> detail
statusText (PreflightBlocked problem detail remediation) =
  "blocked — " <> problemLabel problem <> ": " <> detail <> ". " <> remediation

pad :: Int -> Text -> Text
pad width value = value <> Text.replicate (max 1 (width - Text.length value)) " "

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
-- 'Kanban.Review.resolveCanonicalIssueReviewer' resolves it, but tell a
-- never-installed path apart from one already occupied by something else.
probeReviewBackend :: IO ReviewBackendObservation
probeReviewBackend = do
  interpreter <- findExecutable "python3"
  case interpreter of
    Nothing -> pure ReviewBackendInterpreterMissing
    Just _ -> do
      scriptPath <- canonicalIssueReviewerPath
      -- The backend cannot run without its config module: approve_issues.py
      -- imports kanban_config at module scope, and the issue-review setup
      -- component installs both. A half-installed pair fails at import
      -- time, so both links are part of "installed" here.
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
runProbe :: FilePath -> FilePath -> [String] -> IO ProbeResult
runProbe workingDirectory executable arguments = do
  let spec = (proc executable arguments) {cwd = Just workingDirectory}
  outcome <- timeout probeTimeoutMicros (try (readCreateProcessWithExitCode spec ""))
  pure $ case outcome of
    Nothing -> Left (Text.pack (takeFileName' executable) <> " " <> Text.unwords (map Text.pack arguments) <> " timed out")
    Just (Left exception) -> Left (Text.pack (show (exception :: IOException)))
    Just (Right (code, out, err)) -> Right (code, Text.pack out <> Text.pack err)

takeFileName' :: FilePath -> FilePath
takeFileName' = reverse . takeWhile (/= '/') . reverse

-- | Generous next to what these probes actually cost (a full gather runs in
-- about two seconds), but small enough that a hung provider CLI delays an
-- action by seconds rather than minutes. A timed-out probe is an unknown,
-- so the action still runs.
probeTimeoutMicros :: Int
probeTimeoutMicros = 8 * 1000 * 1000
