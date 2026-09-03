{-# LANGUAGE DerivingStrategies #-}

-- | Where each registry action's provider work is routed, and whether this
-- machine can run it.
--
-- Neither answer is invented here. The route is read off the existing owning
-- code — 'Kanban.PullRequestFlow.originFromBody' and
-- 'Kanban.PullRequestFlow.agentForAction' for a pull request's brand,
-- 'Kanban.Preflight.issueOriginFromBody' for an issue's — so no registry path
-- adds a second brand decision, and the readiness answer is
-- 'Kanban.Preflight.actionReport' over the matching 'PreflightAction' and the
-- operating mode the roster derives, rather than another readiness model.
--
-- Seven of the eight actions map to a 'PreflightAction'. Observing the
-- approval queue is the one that does not, because it starts no provider: its
-- capability is whether this repository's approval controller can be
-- discovered at all, which is the same read-only discovery the observation
-- itself performs and never a start or a stop.
module Kanban.Action.Capability
  ( ActionRoute (..),
    routePreflightAction,
    actionRoute,
    ActionCapability (..),
    actionCapableMessage,
    actionCapability,
    actionCapabilityIO,
  )
where

import Data.Text (Text)
import Kanban.Action.Target (pullRequestActionForKind)
import Kanban.Action.Types
import Kanban.ApprovalService (approvalUnavailableMessage, discoverApprovalController)
import Kanban.Domain (Issue (..), PullRequest (..), Repository (..), WorkflowConfig)
import Kanban.Models (ModelRoster, OperatingMode, RosterLoadError, loadedOperatingMode)
import Kanban.Preflight
  ( PreflightAction (..),
    PreflightEnvironment,
    actionReport,
    blockingRemediation,
    gatherPreflightEnvironment,
    issueOriginFromBody,
    preflightDiagnostic,
  )
import Kanban.PullRequestFlow (originFromBody)
import Kanban.Solve (SolverBrand)

-- | Where one request's work goes.
data ActionRoute
  = -- | A provider session, named as the preflight already names it.
    RouteProvider PreflightAction
  | -- | The approval controller, which this action only reads.
    RouteApprovalQueue
  deriving stock (Eq, Show)

routePreflightAction :: ActionRoute -> Maybe PreflightAction
routePreflightAction (RouteProvider action) = Just action
routePreflightAction RouteApprovalQueue = Nothing

-- | Resolve one request's route, or say why it has none.
--
-- The solver brand is an input rather than a derivation: which agent solves an
-- issue is the operator's choice at the chooser, and the registry carries that
-- choice instead of picking one. Every other brand on this path is derived by
-- the existing routing.
actionRoute :: WorkflowConfig -> WorkflowActionKind -> Maybe SolverBrand -> ActionTarget -> Either ActionRefusal ActionRoute
actionRoute config kind solverBrand target = case kind of
  ObserveApprovalQueue -> Right RouteApprovalQueue
  ReviewIssue -> RouteProvider . ActionIssueReview <$> issueOrigin
  ReviseIssue -> RouteProvider . ActionIssueRevision <$> issueOrigin
  SolveIssue -> RouteProvider . ActionSolve <$> brand
  AutoSolveIssue -> RouteProvider . ActionAutoSolve <$> brand
  ReviewPullRequest -> pullRequestRoute
  RevisePullRequest -> pullRequestRoute
  RepairPullRequest -> pullRequestRoute
  where
    resolved = case target of
      ActionTargetItem item -> Just item
      ActionTargetRepositoryWide _ -> Nothing

    brand = maybe (Left (ActionRoutingUnavailable kind "no solver was selected")) Right solverBrand

    issueOrigin = case resolved >>= resolvedTargetIssue of
      Nothing -> Left (ActionTargetMismatchedArity kind)
      Just issue -> Right (issueOriginFromBody issue.issueBody)

    pullRequestRoute = case resolved >>= resolvedTargetPullRequest of
      Nothing -> Left (ActionTargetMismatchedArity kind)
      Just pullRequest -> do
        action <- pullRequestActionForKind config kind pullRequest
        case originFromBody pullRequest.pullRequestBody of
          Left message -> Left (ActionRoutingUnavailable kind message)
          Right origin -> Right (RouteProvider (ActionPullRequestFlow origin action))

-- | Whether this machine can run the action, from a definite local
-- observation only.
data ActionCapability
  = ActionCapable
  | -- | A definite local observation says this action cannot succeed, with the
    -- remediation that names what to install or sign in to.
    ActionIncapable Text
  deriving stock (Eq, Show)

actionCapableMessage :: ActionCapability -> Maybe Text
actionCapableMessage ActionCapable = Nothing
actionCapableMessage (ActionIncapable detail) = Just detail

-- | The pure half: readiness for a provider route, derived from one gathered
-- environment exactly as the board's own preflight derives it.
actionCapability :: PreflightEnvironment -> OperatingMode -> ActionRoute -> ActionCapability
actionCapability environment mode route = case routePreflightAction route of
  Nothing -> ActionCapable
  Just action ->
    maybe ActionCapable (ActionIncapable . preflightDiagnostic) (blockingRemediation (actionReport environment mode action))

-- | The gathering half. Read-only on both branches: the provider branch runs
-- the board's own probes, and the approval branch discovers the controller
-- without starting or stopping the service.
-- The roster rather than a mode, so this reads the operating mode through
-- 'loadedOperatingMode' exactly as the dashboard's own state does: a
-- @models.toml@ that will not load is no-agent here too, rather than a mode
-- the caller had to decide on its own.
actionCapabilityIO :: Repository -> Either RosterLoadError ModelRoster -> ActionRoute -> IO ActionCapability
actionCapabilityIO repository roster route = case route of
  RouteProvider _ -> do
    environment <- gatherPreflightEnvironment repository.repositoryRoot
    pure (actionCapability environment (loadedOperatingMode roster) route)
  RouteApprovalQueue -> do
    discovered <- discoverApprovalController repository
    pure $ case discovered of
      Left unavailable ->
        ActionIncapable ("issue approval service unavailable: " <> approvalUnavailableMessage unavailable)
      Right _ -> ActionCapable
