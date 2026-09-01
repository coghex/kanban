-- | The workflow action registry: one plain-IO API for acting on a GitHub
-- issue or pull request, shared by the dashboard's key presses and by a
-- headless mission runner (issue #593, SAG-2).
--
-- Eight action kinds are registered, each pinned to the authority that already
-- owns it:
--
-- +----------------------------+-----------------------------------------------+
-- | Review issue               | canonical @approve_issues.py@ (SAG-10)         |
-- | Revise issue               | the issue revision coordinator (SAG-10)        |
-- | Solve issue                | the persistent solve worker                    |
-- | Autosolve issue            | the solve\/review loop, complete               |
-- | Review or rereview PR      | the canonical PR workflow                      |
-- | Revise PR                  | the canonical @pr-revise@ workflow             |
-- | Repair PR                  | the existing @repair@ authority                |
-- | Observe approval queue     | the issue-approval controller                  |
-- +----------------------------+-----------------------------------------------+
--
-- The registry adds no authority of its own. Provider, model, role and
-- opposite-brand routing are read from 'Kanban.PullRequestFlow.agentForAction'
-- and 'Kanban.PullRequestFlow.pullRequestAssignment'; readiness is
-- 'Kanban.Preflight.actionReport' over the matching 'PreflightAction'; the
-- spawn boundary is 'Kanban.Worker.launchSolveWorker' and
-- 'Kanban.Worker.launchPullRequestWorker'; the loop's progression is
-- 'Kanban.UI.AutoSolve.decideAutoSolve'. What is new is the shape: explicit
-- resolved targets in place of an @AppState@, a closed refusal vocabulary in
-- place of notice strings, a split between a nonblocking dispatch and a later
-- observation, and terminal results validated against authoritative evidence
-- rather than taken from a worker's exit.
--
-- Autosolve is the one action whose result cannot be read off the turn it is
-- holding. Its only successful terminal result is the validated approval of
-- the pull request its loop bound, which no single provider turn establishes —
-- a finished solver has opened a pull request nothing has reviewed. So
-- observing it /advances/ it: the handle a dispatch returns carries a cursor,
-- and each 'observeAction' on it moves the loop one tick until it settles on
-- that approval. ('runAutoSolveAction' is the same loop driven to its end.)
-- 'observeAutoSolveTurn' is the narrower view of one turn, which never reports
-- a success.
--
-- 'recoverAutoSolveState' rebuilds an action already under way from the
-- durable records a dashboard-launched run left behind, and
-- 'Kanban.Action.AutoSolve.autoSolveTick' is the single reading of the loop's
-- next move that the dashboard's refresh adapter takes its move from too. A
-- board press and a headless runner therefore drive one action, in one state
-- model, through one progression.
--
-- Three things this registry never does, on any path: merge a pull request,
-- add or remove an approval verdict label, or start or stop the approval
-- service while observing it. A result it cannot establish is reported as
-- 'ActionStopped' or 'ActionFailed' and never promoted to success.
--
-- This is a compatibility facade. "Kanban.Action.Types" holds the
-- vocabularies, "Kanban.Action.Target" resolution and the compatibility
-- rules, "Kanban.Action.Capability" routing and readiness,
-- "Kanban.Action.Dispatch" dispatch and observation, and
-- "Kanban.Action.AutoSolve" the complete loop. Everything below is
-- re-exported from one of those five unchanged.
module Kanban.Action
  ( -- * Action kinds and the decode boundary
    WorkflowActionKind (..),
    workflowActionKinds,
    workflowActionKindTag,
    workflowActionKindTitle,
    workflowActionTargetKind,
    ActionKindDecodeError (..),
    actionKindDecodeErrorMessage,
    decodeWorkflowActionKind,

    -- * Targets
    ActionTargetKind (..),
    actionTargetKindTag,
    ActionTargetRef (..),
    actionTargetRefNumber,
    actionTargetRefText,
    parseActionTargetRef,
    TargetLifecycle (..),
    HistoryReach (..),
    TrackerChildren (..),
    TargetStructure (..),
    ResolvedTarget (..),
    resolvedTargetIssue,
    resolvedTargetPullRequest,
    ActionTarget (..),

    -- * Refusals
    StructuralRefusal (..),
    structuralRefusalMessage,
    ActionRefusal (..),
    actionRefusalMessage,

    -- * Handles and observations
    ActionAttribution (..),
    AutoSolveCursor (..),
    ActionHandle (..),
    actionHandleKind,
    actionHandleWorker,
    actionHandleRepository,
    ActionOutcome (..),
    actionOutcomeSucceeded,
    actionOutcomeMessage,
    ActionObservation (..),
    ApprovalQueueObservation (..),
    approvalQueueObservationMessage,
    approvalQueueWasReported,

    -- * The read a resolution is made against
    TargetCatalog (..),
    CatalogHistory (..),
    catalogIdentity,
    catalogHistoryReach,
    catalogFromSnapshot,
    catalogPullRequestNumbers,
    resolveActionTarget,
    resolveHeldItem,
    targetStructureForIssue,

    -- * Compatibility rules
    actionCompatibility,
    historicalRefusal,
    settledTargetRefusal,
    structuralActionRefusal,
    structuralRefusalFor,
    pullRequestActionForKind,
    workflowActionKindForAction,
    workflowActionKindForDirectPress,
    workflowActionKindForLabelledPullRequest,

    -- * Routing and capability
    ActionRoute (..),
    routePreflightAction,
    actionRoute,
    ActionCapability (..),
    actionCapableMessage,
    actionCapability,
    actionCapabilityIO,

    -- * Dispatch and observation
    ActionEnvironment (..),
    ActionRequest (..),
    actionRequest,
    ActionPlan (..),
    planAction,
    planResolvedAction,
    checkTargetRepository,
    dispatchAction,
    dispatchProviderTurn,
    observeAction,
    observeWorkerHandle,
    observeAutoSolveTurn,
    approvalQueueObservation,
    validateWorkerOutcome,
    attributedSolvePullRequest,
    validatedPullRequestVerdict,

    -- * The autosolve loop
    AutoSolveTick (..),
    AutoSolveMove (..),
    AutoSolveConclusion (..),
    autoSolveTick,
    autoSolveConclusionOutcome,
    autoSolveCursorFor,
    autoSolveActionHandle,
    initialAutoSolveState,
    autoSolveActionActivity,
    AutoSolveState (..),
    AutoSolveSolver (..),
    AutoSolveSolverRecord (..),
    autoSolveSolverWorker,
    autoSolveSolverAssignment,
    AutoSolveTurns (..),
    liveAutoSolveTurns,
    AutoSolveDriver (..),
    autoSolveStateFromWorkers,
    recoverAutoSolveState,
    reviewPhaseForRecord,
    reviewPhaseForWorker,
    settledReviewTurn,
    workerStatusIsLive,
    advanceAutoSolveAction,
    runAutoSolveAction,
    runAutoSolveActionWith,
  )
where

import Kanban.Action.AutoSolve
import Kanban.Action.Capability
import Kanban.Action.Dispatch
import Kanban.Action.Target
import Kanban.Action.Types
