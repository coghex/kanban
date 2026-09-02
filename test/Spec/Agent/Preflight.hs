-- | The preflight probes that gate every AI action.
module Spec.Agent.Preflight (spec) where

import Control.Monad (forM_)
import qualified Data.Text
import Kanban.Preflight
  ( AuthObservation (..),
    BundleObservation (..),
    GitHubObservation (..),
    IssueOrigin (..),
    PreflightAction (..),
    PreflightEnvironment (..),
    PreflightProblem (..),
    ProviderProbe (..),
    ReviewBackendObservation (..),
    VersionObservation (..),
    actionLabel,
    actionReport,
    blockingRemediation,
    canonicalReviewBrands,
    classifyBundleListing,
    classifyClaudeAuth,
    classifyCodexAuth,
    classifyVersion,
    doctorActions,
    doctorLines,
    doctorReady,
    gatherPreflightEnvironment,
    issueOriginFromBody,
    minimumClaudeVersion,
    minimumCodexVersion,
    preflightDiagnostic,
    preflightDiagnosticDetail,
    reviewBackendAction,
    revisionAuthorBrand
  )
import Kanban.PullRequestFlow (PullRequestAction (..), PullRequestOrigin (..))
import Kanban.Solve (SolverBrand (..))
import Kanban.UI.Review (canonicalReviewActivity, canonicalReviewNotice)
import Kanban.UI.Util (agentFailureNotice, failureActivity)
import Spec.Support.Expect (shouldMention)
import Spec.Support.Preflight
  ( BackendFixture (..),
    allBackendCompanions,
    allowedProbeInvocations,
    backendCompanionName,
    blockedProblems,
    bundlelessCodexFake,
    fullyProvisionedFakes,
    isConflictingBackend,
    isMissingBackend,
    isNotAuthenticated,
    isReadyBackend,
    isUnknownAuth,
    isUnknownBundle,
    isUnknownVersion,
    machineSnapshot,
    probeInvocations,
    python3Fake,
    readyClaudeFake,
    readyCodexFake,
    readyGitHubFake,
    readyPreflightEnvironment,
    readyProviderProbe,
    signedOutCodexFake,
    signedOutGitHubFake,
    withClaudeProbe,
    withCodexProbe,
    withPreflightMachine
  )
import System.Exit (ExitCode (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "workflow preflight" $ do
    describe "status-only probe classification" $ do
      it "reads a signed-in codex login status" $
        classifyCodexAuth (Right (ExitSuccess, "Logged in using ChatGPT\n")) `shouldBe` AuthAuthenticated
      it "reads a signed-out codex login status" $
        classifyCodexAuth (Right (ExitFailure 1, "Not logged in\n")) `shouldSatisfy` isNotAuthenticated
      it "reads a signed-in claude auth status from its loggedIn field" $
        classifyClaudeAuth (Right (ExitSuccess, "{\"loggedIn\": true, \"authMethod\": \"claude.ai\"}"))
          `shouldBe` AuthAuthenticated
      it "reads a signed-out claude auth status from its loggedIn field" $
        classifyClaudeAuth (Right (ExitSuccess, "{\"loggedIn\": false}")) `shouldSatisfy` isNotAuthenticated
      -- A CLI too old to know the subcommand at all must not be reported as
      -- signed out: that would block an action the user could still run.
      it "never reads an unrecognized auth subcommand as a sign-out" $ do
        classifyCodexAuth (Right (ExitFailure 2, "error: unrecognized subcommand 'login'"))
          `shouldSatisfy` isUnknownAuth
        classifyClaudeAuth (Right (ExitFailure 1, "error: unknown command 'auth'"))
          `shouldSatisfy` isUnknownAuth
      it "never reads a probe that could not run at all as a sign-out" $
        classifyCodexAuth (Left "codex login status timed out") `shouldSatisfy` isUnknownAuth
      it "reads the codex plugin listing envelope" $
        classifyBundleListing
          (Right (ExitSuccess, "{\"installed\":[{\"pluginId\":\"kanban@kanban\",\"installed\":true,\"enabled\":true}]}"))
          `shouldBe` BundleEnabled
      it "reads the claude plugin listing envelope" $
        classifyBundleListing (Right (ExitSuccess, "[{\"id\":\"kanban@kanban\",\"enabled\":false}]"))
          `shouldBe` BundleDisabled
      it "reads a marketplace offering that is not installed as absent" $
        classifyBundleListing
          (Right (ExitSuccess, "{\"installed\":[{\"pluginId\":\"kanban@kanban\",\"installed\":false}]}"))
          `shouldBe` BundleAbsent
      it "reports an absent bundle when no listing entry names it" $
        classifyBundleListing (Right (ExitSuccess, "[]")) `shouldBe` BundleAbsent
      it "never reads an undecodable listing as an absent bundle" $
        classifyBundleListing (Right (ExitSuccess, "not json")) `shouldSatisfy` isUnknownBundle
      it "accepts the versions everything Kanban asks of each CLI was verified against" $ do
        classifyVersion minimumCodexVersion (Right (ExitSuccess, "codex-cli 0.144.6\n"))
          `shouldBe` VersionSupported "0.144.6"
        classifyVersion minimumClaudeVersion (Right (ExitSuccess, "2.1.251 (Claude Code)\n"))
          `shouldBe` VersionSupported "2.1.251"
      it "rejects a release older than the one the bundle install path needs" $
        classifyVersion minimumClaudeVersion (Right (ExitSuccess, "2.1.100 (Claude Code)\n"))
          `shouldBe` VersionUnsupported "2.1.100" "2.1.251"
      -- The floor Claude's own probe raised it to (D-16). A release that
      -- installs the workflow bundle perfectly well is still below what the
      -- embedded review's interrupt exchange has been verified on, so the two
      -- reasons have to be able to disagree -- and the remediation an
      -- operator reads has to name the one that is actually blocking them.
      it "rejects a release that can install the bundle but predates the verified interrupt exchange" $
        classifyVersion minimumClaudeVersion (Right (ExitSuccess, "2.1.216 (Claude Code)\n"))
          `shouldBe` VersionUnsupported "2.1.216" "2.1.251"
      it "never reads an unparseable version banner as unsupported" $
        classifyVersion minimumCodexVersion (Right (ExitSuccess, "dev build\n"))
          `shouldSatisfy` isUnknownVersion

    describe "per-action readiness" $ do
      it "reports a fully provisioned environment as ready for every action" $
        mapM_
          (\action -> blockingRemediation (actionReport readyPreflightEnvironment action) `shouldBe` Nothing)
          doctorActions
      it "blocks only the actions that reach for a missing provider executable" $ do
        let environment = withCodexProbe (readyProviderProbe CodexSolver) {probeExecutable = Nothing}
        blockedProblems environment (ActionSolve CodexSolver) `shouldBe` [ExecutableUnavailable]
        blockedProblems environment (ActionSolve ClaudeSolver) `shouldBe` []
        -- Auto-solve reviews the PR with the opposite brand itself, so a
        -- claude auto-solve still depends on codex being installed.
        blockedProblems environment (ActionAutoSolve ClaudeSolver) `shouldBe` [ExecutableUnavailable]
        blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` []
      it "distinguishes an unauthenticated provider from a missing one" $ do
        let environment = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeAuth = AuthNotAuthenticated "signed out"}
        -- A Codex-origin PR is reviewed by Claude.
        blockedProblems environment (ActionPullRequestFlow PullRequestCodex PullRequestReview)
          `shouldBe` [ProviderUnauthenticated]
      -- The two floors no longer sit at the same capability, so the
      -- remediation cannot be one sentence: Claude's has been raised past
      -- what the bundle install path needs, and an operator on such a release
      -- would otherwise be sent looking for an install failure that is not
      -- happening.
      it "says why each brand's version floor is where it is" $ do
        let below brand = withProbe brand (readyProviderProbe brand) {probeVersion = VersionUnsupported "0.0.1" "9.9.9"}
            withProbe CodexSolver = withCodexProbe
            withProbe ClaudeSolver = withClaudeProbe
            remediationFor brand = blockingRemediation (actionReport (below brand) (ActionSolve brand))
        remediationFor ClaudeSolver
          `shouldSatisfy` maybe False (Data.Text.isInfixOf "embedded issue review's turn interruption is unverified")
        remediationFor CodexSolver
          `shouldSatisfy` maybe False (not . Data.Text.isInfixOf "turn interruption")
        mapM_
          (\brand -> remediationFor brand `shouldSatisfy` maybe False (Data.Text.isInfixOf "cannot install the Kanban workflow bundle"))
          [CodexSolver, ClaudeSolver]
      it "names the setup command when a workflow bundle is absent" $ do
        let environment = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeBundle = BundleAbsent}
        blockedProblems environment (ActionSolve ClaudeSolver) `shouldBe` [WorkflowBundleUnavailable]
        blockingRemediation (actionReport environment (ActionSolve ClaudeSolver))
          `shouldSatisfy` maybe False (Data.Text.isInfixOf "tools/setup_workflows.py --component claude-plugin")
      it "blocks the canonical review gate, but not issue revision, on a missing backend" $ do
        let environment = readyPreflightEnvironment {environmentReviewBackend = ReviewBackendMissing "/nowhere/approve_issues.py"}
        blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ReviewBackendUnavailable]
        blockedProblems environment (ActionSolve CodexSolver) `shouldBe` [ReviewBackendUnavailable]
        blockedProblems environment (ActionIssueRevision IssueOriginCodex) `shouldBe` []
      -- A Claude-origin revision authors its amendment through
      -- kanban_run_claude, so it needs that CLI even though no packaged
      -- bundle is involved; a Codex-origin one must not be blocked by it.
      it "requires the Claude CLI only for a Claude-origin revision" $ do
        let environment = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeExecutable = Nothing}
        blockedProblems environment (ActionIssueRevision IssueOriginClaude) `shouldBe` [ExecutableUnavailable]
        blockedProblems environment (ActionIssueRevision IssueOriginCodex) `shouldBe` []
      it "requires a signed-in Claude for a Claude-origin revision" $ do
        let environment = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeAuth = AuthNotAuthenticated "signed out"}
        blockedProblems environment (ActionIssueRevision IssueOriginClaude) `shouldBe` [ProviderUnauthenticated]
      -- Revision runs Kanban's own prompts through codex app-server, so a
      -- missing packaged bundle must never block it for either origin.
      -- One coordinator serves every revision session, and a backend
      -- failure fails all of them. If its preflight depended on an issue's
      -- origin, a Claude-origin issue with no Claude CLI would fail the
      -- backend for a Codex-origin revision queued behind it, and tell that
      -- session to install Claude.
      it "keeps the shared revision coordinator's preflight origin-independent" $ do
        let claudeMissing = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeExecutable = Nothing}
            codexMissing = withCodexProbe (readyProviderProbe CodexSolver) {probeExecutable = Nothing}
        blockedProblems claudeMissing reviewBackendAction `shouldBe` []
        blockedProblems claudeMissing (ActionIssueRevision IssueOriginClaude)
          `shouldBe` [ExecutableUnavailable]
        -- A genuinely shared cause still fails the coordinator, which is
        -- what every queued session needs to hear.
        blockedProblems codexMissing reviewBackendAction `shouldBe` [ExecutableUnavailable]
      it "never requires a packaged bundle for a revision of either origin" $ do
        let environment =
              readyPreflightEnvironment
                { environmentCodex = (readyProviderProbe CodexSolver) {probeBundle = BundleAbsent},
                  environmentClaude = (readyProviderProbe ClaudeSolver) {probeBundle = BundleAbsent}
                }
        blockedProblems environment (ActionIssueRevision IssueOriginCodex) `shouldBe` []
        blockedProblems environment (ActionIssueRevision IssueOriginClaude) `shouldBe` []
      it "reads an issue's origin from its marker" $ do
        issueOriginFromBody "Body\n\n<!-- issue-origin:claude -->" `shouldBe` IssueOriginClaude
        issueOriginFromBody "Body\n\n<!-- issue-origin:codex -->" `shouldBe` IssueOriginCodex
        issueOriginFromBody "Body with no marker" `shouldBe` IssueOriginUnmarked
      -- The backend routes on ORIGIN_RE, which is case-insensitive and
      -- allows whitespace on both sides of the value. Reading it more
      -- strictly here would demand a provider the review never spawns.
      it "accepts every marker spelling the backend accepts" $ do
        issueOriginFromBody "<!-- issue-origin:CLAUDE -->" `shouldBe` IssueOriginClaude
        issueOriginFromBody "<!-- ISSUE-ORIGIN:Claude -->" `shouldBe` IssueOriginClaude
        issueOriginFromBody "<!--issue-origin:codex-->" `shouldBe` IssueOriginCodex
        issueOriginFromBody "<!--   issue-origin:codex   -->" `shouldBe` IssueOriginCodex
        issueOriginFromBody "<!--\n  issue-origin:codex\n-->" `shouldBe` IssueOriginCodex
        issueOriginFromBody "a <!-- issue-origin:codex --> b <!-- issue-origin:CODEX -->"
          `shouldBe` IssueOriginCodex
      it "rejects text that only looks like a marker" $ do
        issueOriginFromBody "issue-origin:claude" `shouldBe` IssueOriginUnmarked
        issueOriginFromBody "<!-- issue-origin:claudex -->" `shouldBe` IssueOriginUnmarked
        issueOriginFromBody "<!-- issue-origin: claude -->" `shouldBe` IssueOriginUnmarked
        issueOriginFromBody "<!-- issue-origin:claude" `shouldBe` IssueOriginUnmarked
      -- The backend raises on a body declaring both, before reaching any
      -- reviewer, so preflight must not demand a provider for it either.
      it "mirrors the backend's conflicting-marker case" $ do
        let conflicting = "<!-- issue-origin:claude -->\n<!-- issue-origin:codex -->"
        issueOriginFromBody conflicting `shouldBe` IssueOriginConflicting
        canonicalReviewBrands IssueOriginConflicting `shouldBe` []
        blockedProblems readyPreflightEnvironment (ActionIssueReview IssueOriginConflicting)
          `shouldBe` []
        blockedProblems
          (withClaudeProbe (readyProviderProbe ClaudeSolver) {probeExecutable = Nothing})
          (ActionIssueReview IssueOriginConflicting)
          `shouldBe` []
      it "routes the revision amendment author by that origin" $ do
        revisionAuthorBrand IssueOriginClaude `shouldBe` ClaudeSolver
        revisionAuthorBrand IssueOriginCodex `shouldBe` CodexSolver
        revisionAuthorBrand IssueOriginUnmarked `shouldBe` CodexSolver
      -- approve_issues.py spawns the opposite brand itself, and both under
      -- the dual legacy policy Kanban always passes, so the canonical gate
      -- is only ready if that reviewer's own CLI is.
      it "routes the canonical reviewer to the opposite brand, or both when unmarked" $ do
        canonicalReviewBrands IssueOriginClaude `shouldBe` [CodexSolver]
        canonicalReviewBrands IssueOriginCodex `shouldBe` [ClaudeSolver]
        canonicalReviewBrands IssueOriginUnmarked `shouldBe` [CodexSolver, ClaudeSolver]
      it "requires the canonical reviewer's own CLI for a review" $ do
        let environment = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeExecutable = Nothing}
        blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ExecutableUnavailable]
        blockedProblems environment (ActionIssueReview IssueOriginClaude) `shouldBe` []
        blockedProblems environment (ActionIssueReview IssueOriginUnmarked) `shouldBe` [ExecutableUnavailable]
      it "requires a signed-in canonical reviewer for a review" $ do
        let environment = withCodexProbe (readyProviderProbe CodexSolver) {probeAuth = AuthNotAuthenticated "signed out"}
        blockedProblems environment (ActionIssueReview IssueOriginClaude) `shouldBe` [ProviderUnauthenticated]
        blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` []
      -- pr-revise runs on the PR's own brand and then spawns the opposite
      -- one for its single nested canonical rereview, so a revision needs
      -- both CLIs even though review and rereview need only the reviewer's.
      it "requires the nested cross-brand reviewer for a PR revision" $ do
        let environment = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeExecutable = Nothing}
        blockedProblems environment (ActionPullRequestFlow PullRequestCodex PullRequestRevision)
          `shouldBe` [ExecutableUnavailable]
        blockedProblems environment (ActionPullRequestFlow PullRequestClaude PullRequestRevision)
          `shouldBe` [ExecutableUnavailable]
        -- A Claude-origin PR is reviewed by Codex, which is present here.
        blockedProblems environment (ActionPullRequestFlow PullRequestClaude PullRequestReview)
          `shouldBe` []
        blockedProblems environment (ActionPullRequestFlow PullRequestClaude PullRequestRereview)
          `shouldBe` []
      it "requires the nested reviewer to be signed in for a PR revision" $ do
        let environment = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeAuth = AuthNotAuthenticated "signed out"}
        blockedProblems environment (ActionPullRequestFlow PullRequestCodex PullRequestRevision)
          `shouldBe` [ProviderUnauthenticated]
        blockedProblems environment (ActionPullRequestFlow PullRequestClaude PullRequestReview)
          `shouldBe` []
      -- The nested rereview is a direct `codex exec`/`claude -p` spawn by
      -- the bundled coordinator, so only the launched brand needs a bundle.
      it "requires a bundle only for the brand the PR action itself launches" $ do
        let environment = withCodexProbe (readyProviderProbe CodexSolver) {probeBundle = BundleAbsent}
        blockedProblems environment (ActionPullRequestFlow PullRequestCodex PullRequestRevision)
          `shouldBe` [WorkflowBundleUnavailable]
        blockedProblems environment (ActionPullRequestFlow PullRequestCodex PullRequestReview)
          `shouldBe` []
        blockedProblems environment (ActionPullRequestFlow PullRequestClaude PullRequestRevision)
          `shouldBe` []
      -- Repair edits the PR's own code and then hands off to one nested
      -- canonical rereview exactly as pr-revise does, so its dependency set
      -- is revise's: the launched brand's executable, sign-in and bundle,
      -- plus the opposite brand's executable and sign-in but not its bundle.
      it "gives repair the same cross-brand dependency set as a PR revision" $ do
        let missingClaude = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeExecutable = Nothing}
            signedOutClaude = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeAuth = AuthNotAuthenticated "signed out"}
            bundlelessCodex = withCodexProbe (readyProviderProbe CodexSolver) {probeBundle = BundleAbsent}
            bundlelessClaude = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeBundle = BundleAbsent}
        -- The launched brand is the PR's own, so a Codex-origin repair is
        -- blocked by Codex's missing bundle and a Claude-origin one is not.
        blockedProblems bundlelessCodex (ActionPullRequestFlow PullRequestCodex PullRequestRepair)
          `shouldBe` [WorkflowBundleUnavailable]
        blockedProblems bundlelessCodex (ActionPullRequestFlow PullRequestClaude PullRequestRepair)
          `shouldBe` []
        -- The nested rereview is a direct provider call, so the opposite
        -- brand's absent bundle never blocks repair.
        blockedProblems bundlelessClaude (ActionPullRequestFlow PullRequestCodex PullRequestRepair)
          `shouldBe` []
        -- but that brand's executable and sign-in are still required, here
        -- purely as the nested reviewer of a Codex-origin repair.
        blockedProblems missingClaude (ActionPullRequestFlow PullRequestCodex PullRequestRepair)
          `shouldBe` [ExecutableUnavailable]
        blockedProblems signedOutClaude (ActionPullRequestFlow PullRequestCodex PullRequestRepair)
          `shouldBe` [ProviderUnauthenticated]
        -- On a Claude-origin repair the same two gaps block it as the
        -- launched brand instead, so neither origin can start without both.
        blockedProblems missingClaude (ActionPullRequestFlow PullRequestClaude PullRequestRepair)
          `shouldBe` [ExecutableUnavailable]
        blockedProblems signedOutClaude (ActionPullRequestFlow PullRequestClaude PullRequestRepair)
          `shouldBe` [ProviderUnauthenticated]
      -- The backend runs `codex exec`/`claude -p` itself, so no packaged
      -- workflow bundle is involved in a canonical review.
      it "never requires a packaged bundle for a canonical review" $ do
        let environment =
              readyPreflightEnvironment
                { environmentCodex = (readyProviderProbe CodexSolver) {probeBundle = BundleAbsent},
                  environmentClaude = (readyProviderProbe ClaudeSolver) {probeBundle = BundleAbsent}
                }
        blockedProblems environment (ActionIssueReview IssueOriginUnmarked) `shouldBe` []
      it "tells an occupied install path apart from a never-installed one" $ do
        let environment = readyPreflightEnvironment {environmentReviewBackend = ReviewBackendConflicting "/occupied" "a directory"}
        blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ConflictingInstallation]
        blockingRemediation (actionReport environment (ActionIssueReview IssueOriginCodex))
          `shouldSatisfy` maybe False (Data.Text.isInfixOf "move or remove that path yourself")
      it "reports an unavailable GitHub CLI for every action" $ do
        let environment = readyPreflightEnvironment {environmentGitHub = GitHubExecutableMissing}
        mapM_ (\action -> blockedProblems environment action `shouldSatisfy` elem GitHubUnavailable) doctorActions
      -- The whole point of the unknown status: a probe Kanban could not
      -- interpret must never break a setup that actually works.
      it "never blocks an action on an inconclusive probe" $ do
        let inconclusive brand =
              (readyProviderProbe brand)
                { probeVersion = VersionUnknown "no version banner",
                  probeAuth = AuthUnknown "unreadable",
                  probeBundle = BundleUnknown "unreadable"
                }
            environment =
              readyPreflightEnvironment
                { environmentCodex = inconclusive CodexSolver,
                  environmentClaude = inconclusive ClaudeSolver,
                  environmentGitHub = GitHubUnknown "unreadable"
                }
        mapM_ (\action -> blockedProblems environment action `shouldBe` []) doctorActions
        doctorReady environment `shouldBe` True

    describe "board diagnostics" $ do
      it "round-trips a remediation through the failure message" $
        preflightDiagnosticDetail (preflightDiagnostic "install the bundle") `shouldBe` Just "install the bundle"
      it "leaves an ordinary agent failure unclassified" $
        preflightDiagnosticDetail "codex was not found on PATH" `shouldBe` Nothing
      it "reports a setup gap as unavailable rather than as another failed agent" $ do
        canonicalReviewNotice (preflightDiagnostic "no canonical issue reviewer. Run setup.")
          `shouldSatisfy` Data.Text.isInfixOf "cannot start"
        canonicalReviewNotice (preflightDiagnostic "no canonical issue reviewer. Run setup.")
          `shouldSatisfy` Data.Text.isInfixOf "Run setup."
      it "keeps a generic provider failure reading as a failure" $
        canonicalReviewNotice "the backend crashed" `shouldSatisfy` Data.Text.isInfixOf "failed:"
      it "distinguishes a setup gap from a generic failure in the activity text" $ do
        failureActivity (preflightDiagnostic "bundle absent") `shouldBe` "setup required"
        failureActivity "provider exited 1" `shouldBe` "failed"
      -- The revision path reports through canonicalReviewActivity whether
      -- the coordinator rejected the turn or preflight stopped it against
      -- an already-running backend, so both readings live here.
      it "classifies a revision start failure by cause" $ do
        canonicalReviewActivity (preflightDiagnostic "claude was not found on PATH") `shouldBe` "setup required"
        canonicalReviewActivity "the coordinator rejected the turn" `shouldBe` "failed"
      it "names the remediation when a revision cannot start" $ do
        agentFailureNotice "Issue revision" (preflightDiagnostic "claude was not found on PATH. Install it.")
          `shouldSatisfy` Data.Text.isInfixOf "Issue revision cannot start — "
        agentFailureNotice "Issue revision" (preflightDiagnostic "claude was not found on PATH. Install it.")
          `shouldSatisfy` Data.Text.isInfixOf "Install it."
        agentFailureNotice "Issue revision" "the coordinator rejected the turn"
          `shouldSatisfy` Data.Text.isInfixOf "Issue revision failed: "

    describe "hermetic fresh-machine probing" $ do
      it "reports a fully provisioned machine as ready for every action" $
        withPreflightMachine fullyProvisionedFakes BackendInstalled $
          \root _ -> do
            environment <- gatherPreflightEnvironment root
            doctorReady environment `shouldBe` True
      it "only ever runs status-only probes, and mutates nothing" $
        withPreflightMachine fullyProvisionedFakes BackendInstalled $
          \root probeLog -> do
            snapshotBefore <- machineSnapshot root
            _ <- gatherPreflightEnvironment root
            snapshotAfter <- machineSnapshot root
            snapshotAfter `shouldBe` snapshotBefore
            invocations <- probeInvocations probeLog
            invocations `shouldSatisfy` not . null
            invocations `shouldSatisfy` all (`elem` allowedProbeInvocations)
      -- With an installed backend and no provider at all, every action's
      -- one complaint is the missing executable — including the canonical
      -- gate, whose reviewer the backend spawns itself.
      it "reports absent provider executables for every action that needs one" $
        withPreflightMachine [readyGitHubFake, python3Fake] BackendInstalled $ \root _ -> do
          environment <- gatherPreflightEnvironment root
          environment.environmentReviewBackend `shouldSatisfy` isReadyBackend
          mapM_
            (\action -> blockedProblems environment action `shouldBe` [ExecutableUnavailable])
            [ ActionSolve CodexSolver,
              ActionSolve ClaudeSolver,
              ActionIssueReview IssueOriginCodex,
              ActionIssueReview IssueOriginClaude,
              ActionIssueRevision IssueOriginCodex
            ]
      it "reports an unauthenticated provider" $
        withPreflightMachine [signedOutCodexFake, readyClaudeFake, readyGitHubFake, python3Fake] BackendInstalled $
          \root _ -> do
            environment <- gatherPreflightEnvironment root
            blockedProblems environment (ActionSolve CodexSolver) `shouldBe` [ProviderUnauthenticated]
      it "reports an absent workflow bundle" $
        withPreflightMachine [bundlelessCodexFake, readyClaudeFake, readyGitHubFake, python3Fake] BackendInstalled $
          \root _ -> do
            environment <- gatherPreflightEnvironment root
            blockedProblems environment (ActionSolve CodexSolver) `shouldBe` [WorkflowBundleUnavailable]
      it "reports an uninstalled canonical review backend" $
        withPreflightMachine fullyProvisionedFakes BackendMissing $
          \root _ -> do
            environment <- gatherPreflightEnvironment root
            blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ReviewBackendUnavailable]
      it "reports an install path occupied by something Kanban did not install" $
        withPreflightMachine fullyProvisionedFakes BackendOccupied $
          \root _ -> do
            environment <- gatherPreflightEnvironment root
            blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ConflictingInstallation]
      -- Setup refuses an ordinary file on the install path, so reporting it
      -- ready here would both contradict setup and hand the canonical
      -- reviewer an unmanaged script to run.
      it "reports an ordinary file on the install path as conflicting, not ready" $
        withPreflightMachine fullyProvisionedFakes BackendOrdinaryFile $ \root _ -> do
          environment <- gatherPreflightEnvironment root
          environment.environmentReviewBackend `shouldSatisfy` isConflictingBackend
          blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ConflictingInstallation]
      it "reports a dangling managed link as conflicting" $
        withPreflightMachine fullyProvisionedFakes BackendDanglingLink $ \root _ -> do
          environment <- gatherPreflightEnvironment root
          environment.environmentReviewBackend `shouldSatisfy` isConflictingBackend
          blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ConflictingInstallation]
      -- A link resolving to a readable script under a plausible tools/
      -- path passes every shape test; only the tracked file's own identity
      -- marker tells it apart from Kanban's backend.
      it "reports a link to a file that is not Kanban's own backend as conflicting" $
        withPreflightMachine fullyProvisionedFakes BackendForeignLink $ \root _ -> do
          environment <- gatherPreflightEnvironment root
          environment.environmentReviewBackend `shouldSatisfy` isConflictingBackend
          blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ConflictingInstallation]
      -- approve_issues.py imports both companion modules at module scope, so
      -- half an installation is not an installation. Every companion is
      -- driven, rather than the one this check was first written for: a probe
      -- that required only that one would report a backend ready that cannot
      -- start.
      forM_ allBackendCompanions $ \companion -> do
        it ("reports a missing " <> backendCompanionName companion <> " as an unavailable backend") $
          withPreflightMachine fullyProvisionedFakes (BackendCompanionMissing companion) $ \root _ -> do
            environment <- gatherPreflightEnvironment root
            environment.environmentReviewBackend `shouldSatisfy` isMissingBackend
            blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ReviewBackendUnavailable]
        -- And an unmanaged copy of a companion is the conflict setup refuses
        -- to replace, not an absence it can fill -- the same distinction the
        -- script's own cases above draw.
        it ("reports an ordinary " <> backendCompanionName companion <> " on the install path as conflicting") $
          withPreflightMachine fullyProvisionedFakes (BackendCompanionOrdinaryFile companion) $ \root _ -> do
            environment <- gatherPreflightEnvironment root
            environment.environmentReviewBackend `shouldSatisfy` isConflictingBackend
            blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ConflictingInstallation]
      -- Preflight parity with Kanban.Review: a --install-dir installation is
      -- discovered through the installer's record with no environment
      -- override at all. Without this, a custom install would review fine
      -- from the board and still be reported as not installed.
      it "reports a backend the installer recorded elsewhere as ready" $
        withPreflightMachine fullyProvisionedFakes BackendRecordedElsewhere $ \root _ -> do
          environment <- gatherPreflightEnvironment root
          case environment.environmentReviewBackend of
            ReviewBackendReadyAt path ->
              Data.Text.pack path `shouldMention` "/issue-review/approve_issues.py"
            other -> expectationFailure ("expected a ready backend, got " <> show other)
          blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` []
      -- Not knowing which path to look at is an earlier failure than finding
      -- nothing there, and it has a different repair.
      it "reports an unreadable install record rather than an uninstalled backend" $
        withPreflightMachine fullyProvisionedFakes BackendRecordUnreadable $ \root _ -> do
          environment <- gatherPreflightEnvironment root
          case environment.environmentReviewBackend of
            ReviewBackendUnresolved detail -> do
              detail `shouldMention` "is unreadable"
              detail `shouldMention` "/issue-review/config.json"
            other -> expectationFailure ("expected an unresolved backend, got " <> show other)
          blockedProblems environment (ActionIssueReview IssueOriginCodex)
            `shouldBe` [ReviewBackendUnavailable]
      it "reports an unauthenticated GitHub CLI" $
        withPreflightMachine [readyCodexFake, readyClaudeFake, signedOutGitHubFake, python3Fake] BackendInstalled $
          \root _ -> do
            environment <- gatherPreflightEnvironment root
            blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [GitHubUnavailable]
      it "renders one doctor line per supported AI action" $
        withPreflightMachine [readyGitHubFake, python3Fake] BackendMissing $ \root _ -> do
          environment <- gatherPreflightEnvironment root
          let rendered = Data.Text.unlines (doctorLines environment)
          mapM_ (\action -> rendered `shouldSatisfy` Data.Text.isInfixOf (actionLabel action)) doctorActions
          -- Every action a user can select from the board gets its own
          -- line, including the ones whose dependency set happens to match
          -- another's, so a future collapse cannot silently drop one.
          mapM_
            (\action -> doctorActions `shouldSatisfy` elem action)
            [ ActionIssueReview IssueOriginCodex,
              ActionIssueReview IssueOriginClaude,
              ActionIssueReview IssueOriginUnmarked,
              ActionIssueRevision IssueOriginCodex,
              ActionIssueRevision IssueOriginClaude,
              ActionSolve CodexSolver,
              ActionSolve ClaudeSolver,
              ActionAutoSolve CodexSolver,
              ActionAutoSolve ClaudeSolver,
              ActionPullRequestFlow PullRequestCodex PullRequestReview,
              ActionPullRequestFlow PullRequestClaude PullRequestReview,
              ActionPullRequestFlow PullRequestCodex PullRequestRereview,
              ActionPullRequestFlow PullRequestClaude PullRequestRereview,
              ActionPullRequestFlow PullRequestCodex PullRequestRevision,
              ActionPullRequestFlow PullRequestClaude PullRequestRevision,
              ActionPullRequestFlow PullRequestCodex PullRequestRepair,
              ActionPullRequestFlow PullRequestClaude PullRequestRepair
            ]
          rendered `shouldSatisfy` Data.Text.isInfixOf "PR rereview (r)"
          -- Exactly one repair line per PR origin: repair is selectable on
          -- either brand's pull request, and on neither more than once.
          length (filter isRepairAction doctorActions) `shouldBe` 2
          rendered `shouldSatisfy` Data.Text.isInfixOf "PR repair (r) · codex-origin"
          rendered `shouldSatisfy` Data.Text.isInfixOf "PR repair (r) · claude-origin"
          -- The drainer keeps its own dedicated install and status flow.
          rendered `shouldSatisfy` (not . Data.Text.isInfixOf "drainer")

isRepairAction :: PreflightAction -> Bool
isRepairAction (ActionPullRequestFlow _ PullRequestRepair) = True
isRepairAction _ = False
