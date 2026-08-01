-- | Pure action-readiness derivation and doctor rendering, built from the
-- raw observations 'Kanban.Preflight.Environment' gathers: which checks one
-- board action depends on, whether any of them blocks it, and the
-- @kanban --doctor@ report over every action.
--
-- This module is internal — 'Kanban.Preflight' re-exports the parts of it
-- that module's public contract promises.
module Kanban.Preflight.Readiness where

import Data.Char (isSpace)
import Data.List (find, nub)
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Preflight.Environment
import Kanban.PullRequestFlow (PullRequestAction (..), PullRequestOrigin (..), agentForAction, authoredOnOwnBrand)
import Kanban.Solve (SolverBrand (..))

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

-- | Which agent authored an issue, since both issue-side actions route
-- their provider work by it. 'IssueOriginConflicting' mirrors the backend's
-- own error case: a body declaring both origins.
data IssueOrigin
  = IssueOriginCodex
  | IssueOriginClaude
  | IssueOriginUnmarked
  | IssueOriginConflicting
  deriving stock (Eq, Show)

-- | The in-app AI actions launched from the board, each reported
-- separately: an action is only as ready as the dependencies it actually
-- reaches for. The PR drainer is deliberately absent — it keeps its own
-- dedicated install and status flow.
data PreflightAction
  = ActionIssueReview IssueOrigin
  | ActionIssueRevision IssueOrigin
  | ActionSolve SolverBrand
  | ActionAutoSolve SolverBrand
  | ActionPullRequestFlow PullRequestOrigin PullRequestAction
  deriving stock (Eq, Show)

-- | Read an issue's origin the way the backend that routes on it does.
-- Disagreeing here would be worse than not checking at all: a marker the
-- backend honours but this missed would make preflight demand a provider
-- the review is never going to spawn, and block an action that would have
-- worked.
issueOriginFromBody :: Text -> IssueOrigin
issueOriginFromBody body = case declaredIssueOrigins body of
  [] -> IssueOriginUnmarked
  [single]
    | single == "claude" -> IssueOriginClaude
    | single == "codex" -> IssueOriginCodex
  _ -> IssueOriginConflicting

-- | Every distinct origin a body declares, parsed exactly as
-- @ORIGIN_RE@/@issue_origin@ in @tools\/approve_issues.py@ do:
-- @\<!--\\s*issue-origin:(claude|codex)\\s*--\>@, matched case-insensitively.
declaredIssueOrigins :: Text -> [Text]
declaredIssueOrigins = nub . scan . Text.toLower
  where
    scan remaining =
      let (_, rest) = Text.breakOn "<!--" remaining
       in if Text.null rest
            then []
            else
              let body = Text.drop 4 rest
               in maybe id (:) (markerOrigin body) (scan body)
    markerOrigin body = do
      value <- Text.stripPrefix "issue-origin:" (Text.dropWhile isSpace body)
      origin <- find (`Text.isPrefixOf` value) ["claude", "codex"]
      let closing = Text.dropWhile isSpace (Text.drop (Text.length origin) value)
      if "-->" `Text.isPrefixOf` closing then Just origin else Nothing

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
-- The backend rejects a body declaring both origins before it reaches any
-- reviewer, so no provider is required. Its own error names the real
-- problem, which is a malformed issue rather than missing setup.
canonicalReviewBrands IssueOriginConflicting = []

-- | The dependencies of the *shared* revision coordinator itself, as
-- distinct from any one issue's amendment authoring: Kanban's own
-- @codex app-server@ thread and @gh@.
--
-- Deliberately origin-independent. One coordinator serves every revision
-- session, so anything origin-specific checked here would be reported
-- against sessions it has nothing to do with — a Claude-origin issue with
-- no Claude CLI would fail the backend for a Codex-origin issue queued
-- behind it. Per-issue dependencies belong to the per-session preflight,
-- which runs for each queued session once the coordinator is up.
reviewBackendAction :: PreflightAction
reviewBackendAction = ActionIssueRevision IssueOriginCodex

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
pullRequestActionLabel PullRequestRepair = "repair"

pullRequestOriginLabel :: PullRequestOrigin -> Text
pullRequestOriginLabel PullRequestCodex = "codex-origin"
pullRequestOriginLabel PullRequestClaude = "claude-origin"

originLabel :: IssueOrigin -> Text
originLabel IssueOriginCodex = "codex-origin"
originLabel IssueOriginClaude = "claude-origin"
originLabel IssueOriginUnmarked = "unmarked"
originLabel IssueOriginConflicting = "conflicting-origin"

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
      ReviewBackendUnresolved detail ->
        PreflightBlocked
          ReviewBackendUnavailable
          detail
          ("Run " <> setupCommand "issue-review" <> " to rewrite the install record.")
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
    -- brand. Revision and repair are the exception: each runs on the PR's
    -- *own* brand, then hands off to exactly one canonical rereview by
    -- spawning the opposite brand from inside that session
    -- (agent-workflow-contract §2.2, §2.7). That nested call is a direct
    -- `codex exec`/`claude -p`, so it needs the executable and a sign-in but
    -- no packaged bundle.
    checksFor (ActionPullRequestFlow origin pullRequestAction) =
      providerChecks True (environmentProbe environment launched)
        <> [ check
             | authoredOnOwnBrand pullRequestAction,
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
    ActionPullRequestFlow PullRequestClaude PullRequestRevision,
    ActionPullRequestFlow PullRequestCodex PullRequestRepair,
    ActionPullRequestFlow PullRequestClaude PullRequestRepair
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
