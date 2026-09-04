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
--
-- This is a compatibility facade: 'Kanban.Preflight.Environment' gathers and
-- classifies the raw observations, and 'Kanban.Preflight.Readiness' derives
-- action readiness and doctor rendering from them. Everything below is
-- re-exported from one of those two modules unchanged.
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
    actionReportFor,
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
    preflightBlocker,
    preflightDiagnostic,
    preflightDiagnosticDetail,
    problemLabel,
    reviewBackendAction,
  )
where

import Kanban.Preflight.Environment
import Kanban.Preflight.Readiness
