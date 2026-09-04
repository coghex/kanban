{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Pure action-readiness derivation and doctor rendering, built from the
-- raw observations 'Kanban.Preflight.Environment' gathers: which checks one
-- board action depends on, whether any of them blocks it, and the
-- @kanban --doctor@ report over every action.
--
-- This module is internal — 'Kanban.Preflight' re-exports the parts of it
-- that module's public contract promises.
module Kanban.Preflight.Readiness where

import Data.Aeson (FromJSON, ToJSON)
import Data.Char (isSpace)
import Data.List (find, nub)
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Domain (Repository (..))
import Kanban.Models (OperatingMode (..), soleAgent)
import Kanban.Preflight.Environment
import Kanban.ProviderAdapter (brandForProvider, embeddedReviewProvider)
import Kanban.PullRequestFlow (PullRequestAction (..), PullRequestOrigin (..), agentForAction, authoredOnOwnBrand)
import Kanban.Solve (SolverBrand (..))
import GHC.Generics (Generic)

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
-- Durable because an issue action's specification records the origin its
-- launch boundary read, rather than re-reading an issue body the detached
-- host does not hold (SAG-10).
data IssueOrigin
  = IssueOriginCodex
  | IssueOriginClaude
  | IssueOriginUnmarked
  | IssueOriginConflicting
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

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

-- | 'canonicalReviewBrands' as the operating mode actually spawns them.
--
-- Single-agent collapses every routed reviewer onto the one loaded provider,
-- exactly as @reviewers_for_origin@ already does on the Python side (issue
-- #572), so an unmarked issue requires one CLI there rather than both. A body
-- declaring both origins still requires none: the backend rejects it before
-- it reaches a reviewer in every mode, and collapsing an empty list would
-- demand a provider for an issue no reviewer is ever spawned for.
canonicalReviewBrandsIn :: OperatingMode -> IssueOrigin -> [SolverBrand]
canonicalReviewBrandsIn mode origin = case canonicalReviewBrands origin of
  [] -> []
  routed -> maybe routed (pure . brandForProvider) (soleAgent mode)

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
-- 'Kanban.Review.Prompts.reviewDeveloperInstructions'.
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

-- | Why each brand's floor is where it is, so the remediation an operator
-- reads names the capability they are actually below.
--
-- The two are no longer the same sentence. Both floors start at the plugin
-- subcommand family the tracked bundles install through, but Claude's has
-- been raised past it by the embedded review's interrupt exchange (D-16),
-- and telling an operator on such a release only that they cannot install the
-- bundle would send them looking for a failure they will not find.
versionFloorReason :: SolverBrand -> Text
versionFloorReason CodexSolver = "older releases cannot install the Kanban workflow bundle."
versionFloorReason ClaudeSolver =
  "older releases cannot install the Kanban workflow bundle, and the embedded issue review's turn interruption is unverified below it."

oppositeBrand :: SolverBrand -> SolverBrand
oppositeBrand CodexSolver = ClaudeSolver
oppositeBrand ClaudeSolver = CodexSolver

-- | The brand on the /other/ side of a two-brand handoff, as the mode
-- actually reaches it: an autosolve run's review of its own pull request, and
-- the one nested canonical rereview a revision or repair spawns after
-- pushing.
--
-- Dual mode is 'oppositeBrand', unchanged. Single-agent hands off to the one
-- loaded provider, which is the brand that already ran the first half, so the
-- checks this contributes are the ones already present rather than a second
-- CLI the install does not have.
counterpartBrand :: OperatingMode -> SolverBrand -> SolverBrand
counterpartBrand mode brand = maybe (oppositeBrand brand) brandForProvider (soleAgent mode)

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
            ("Update " <> product_ <> " to " <> required <> " or newer; " <> versionFloorReason probe.probeBrand)
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
-- own embedded-review prompts rather than a packaged workflow, so it needs no
-- bundle; auto-solve drives the PR review itself, so it needs the reviewing
-- brand too.
--
-- The mode is asked rather than assumed because a check is a claim that this
-- machine must be able to run a specific executable, and single-agent mode
-- never spawns the brand it does not load. Blocking a Claude-only install on
-- a missing @codex@ would refuse every action it is perfectly able to run,
-- and every place below that used to name the opposite brand asks the mode
-- for the brand that is really on the other side of the handoff.
actionReport :: PreflightEnvironment -> OperatingMode -> PreflightAction -> PreflightReport
actionReport environment mode = actionReportFor environment mode Nothing

-- | 'actionReport' for a launch whose brand the caller already knows.
--
-- A dispatch replaying a recorded assignment does know it, and it is not
-- always what the mode would route to: the record is what the worker will
-- really spawn (D-7), and the two differ exactly when @models.toml@ has moved
-- under a session that already exists — a Codex pull-request worker created
-- in dual mode and resumed on a Claude-only roster still launches @codex@.
-- Checking the routed brand there would clear that resume against an
-- executable it is not going to run, and leave the one it is going to run
-- unprobed.
--
-- Only the /launch/ is overridden. Each handoff below keeps the live mode,
-- because the nested spawn it stands for is made fresh by the running agent
-- and routes under the roster in force when it happens, not under the one
-- this session was created against.
actionReportFor :: PreflightEnvironment -> OperatingMode -> Maybe SolverBrand -> PreflightAction -> PreflightReport
actionReportFor environment mode recordedBrand action = PreflightReport action (checksFor action)
  where
    -- The brand this action will really spawn: the recorded one where a
    -- caller supplied it, and otherwise the one this mode routes to, which is
    -- every fresh action.
    spawned routed = fromMaybe routed recordedBrand

    -- The canonical backend spawns the opposite brand itself (both, for an
    -- unmarked issue under the dual policy Kanban passes), so a review is
    -- only ready if that reviewer's CLI is installed and signed in. No
    -- packaged bundle: the backend runs `codex exec`/`claude -p` directly.
    checksFor (ActionIssueReview origin) =
      concatMap (providerChecks False . environmentProbe environment) (canonicalReviewBrandsIn mode origin)
        <> [gitHubCheck environment, reviewBackendCheck environment]
    -- The revision coordinator is always Kanban's own @codex app-server@
    -- thread, and neither brand's packaged bundle is involved: it runs
    -- Kanban's own prompts. A Claude-origin issue additionally authors its
    -- amendment through @kanban_run_claude@, so that brand's CLI has to be
    -- installed and signed in too, or the session fails inside the tool
    -- call instead of at the door.
    checksFor (ActionIssueRevision origin) =
      providerChecks False (environmentProbe environment coordinator)
        <> [ check
             | author /= coordinator,
               check <- providerChecks False (environmentProbe environment author)
           ]
        <> [gitHubCheck environment]
      where
        -- The coordinator is the brand whose embedded-review backend this
        -- install actually starts, which single-agent mode moves
        -- ('Kanban.Review.embeddedReviewProvider'), and the author is the
        -- brand that writes the amendment, which that mode collapses onto the
        -- same provider. Compared rather than tested against Claude by name,
        -- so a Claude-only install checks one CLI instead of listing the same
        -- probe twice.
        coordinator = brandForProvider (embeddedReviewProvider mode)
        author = maybe (revisionAuthorBrand origin) brandForProvider (soleAgent mode)
    checksFor (ActionSolve brand) =
      providerChecks True (environmentProbe environment (spawned brand))
        <> [gitHubCheck environment, reviewBackendCheck environment]
    checksFor (ActionAutoSolve brand) =
      providerChecks True (environmentProbe environment solver)
        <> [ check
             | reviewer <- [counterpartBrand mode solver],
               reviewer /= solver,
               check <- providerChecks True (environmentProbe environment reviewer)
           ]
        <> [gitHubCheck environment, reviewBackendCheck environment]
      where
        solver = spawned brand
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
               nested <- [counterpartBrand mode launched],
               nested /= launched,
               check <- providerChecks False (environmentProbe environment nested)
           ]
        <> [gitHubCheck environment, reviewBackendCheck environment]
      where
        launched = spawned (agentForAction mode origin pullRequestAction)

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

-- | The doctor reports the whole matrix rather than this install's mode.
--
-- @--doctor@ is answered ahead of configuration and repository resolution --
-- a fresh clone with no remote still has to be able to ask why an action
-- would not start -- so it reads no @models.toml@ and has no mode to report
-- against. Every action a user could select is listed under dual routing,
-- which is the superset: an install that is ready for all of them is ready
-- for any singleton subset of them.
doctorMode :: OperatingMode
doctorMode = DualMode

doctorReady :: PreflightEnvironment -> Bool
doctorReady environment =
  all (isNothing . blockingRemediation . actionReport environment doctorMode) doctorActions

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
      let report = actionReport environment doctorMode action
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

-- | Preflight one AI action just before spawning it, so a missing
-- Kanban-owned component is reported with the command that installs it
-- instead of surfacing minutes later as an opaque agent failure. Only a
-- definite local observation blocks; an inconclusive probe lets the action
-- run and fail on its own terms, so a setup Kanban cannot introspect is
-- never broken by its own diagnostics. Every probe is read-only.
--
-- Here rather than beside the dashboard's launch boundaries because it is no
-- longer only theirs: a detached issue-review host preflights each child
-- action at the instant it spawns that action's provider (SAG-10), and the
-- two must ask the same question of the same environment rather than one
-- reimplementing it below the other.
preflightBlocker :: Repository -> OperatingMode -> PreflightAction -> IO (Maybe Text)
preflightBlocker repository mode action = do
  environment <- gatherPreflightEnvironment repository.repositoryRoot
  pure (preflightDiagnostic <$> blockingRemediation (actionReport environment mode action))
