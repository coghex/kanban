-- | A mission's durable record: where it lives, what it is made of, and the
-- operations that read and write it.
--
-- A mission is one natural-language request turned into a plan and run to
-- completion across many agent sessions, and this module is the first slice of
-- it (issue #592, phase 1 of the Mission Control arc). It ships the store and
-- nothing that uses one: no runner, no reconciliation against live worker or
-- GitHub state, no action registry, no console. Nothing here starts a process,
-- observes one, or contacts GitHub.
--
-- The record has four parts and each has its own discipline:
--
--   [specification] Written once with @O_CREAT | O_EXCL@ and never rewritten.
--     What the mission was asked to do stays a faithful account of the request
--     however far the run diverged from it.
--   [snapshot] Replaced whole, by rename. An interrupted replacement leaves
--     the previous snapshot readable and current rather than a half-written
--     one. Its session tree is checked on the way in and on the way out: the
--     writer's guarantee only covers records this release wrote, and a
--     restored or hand-repaired one is what a delete would decide from.
--   [journal] Appended one whole line at a time, and read by byte offset, so a
--     record still being written is read once — whole — on a later pass rather
--     than truncated now and duplicated later.
--   [sealed archives] A child's stream or raw log copied into the mission's
--     own directory with the digest and byte length that verify the copy after
--     the source is collected.
--
-- Three cross-cutting rules are worth knowing before reading any of it.
--
-- Every independently decoded record carries its own @schemaVersion@ outside
-- the payload, and a version this release does not recognize reads as absent,
-- silently, exactly as a missing file does (@docs\/design.md@ §16, issue #45).
-- A genuine decode failure keeps its diagnostic and names the mission and the
-- file.
--
-- Every one of those records also carries the repository and the mission it
-- belongs to, and is refused rather than adopted when either disagrees with
-- where it sits — the specification, the snapshot, each journal line, each
-- seal, and the lease owner alike. Each is decoded on its own, so for each of
-- them the location and the contents can be made to disagree by a store
-- restored from a backup, a directory copied to try something out, or a
-- repository renamed; and adopting one would let a foreign record authorise
-- deleting a mission, emit another mission's history as this one's, or hand
-- out a lease a live holder still has.
--
-- No write ever takes that silence for permission. \"Is there already one of
-- these?\" is always an existence check on the filesystem, never a successful
-- decode, so a specification or a sealed archive a later release wrote can
-- never be overwritten by this one.
--
-- Every judgement about whether something is still running is made from what
-- was recorded, and fails closed. A session with no observation and no
-- captured process identity is unverifiable, not finished; a mission lease
-- whose holder cannot be proven gone stays held for good.
module Kanban.Mission
  ( -- * The store
    MissionStore (..),
    openMissionStore,
    missionStoreRoot,
    listMissions,
    MissionRead (..),

    -- * Identity
    MissionId (..),
    MissionStepId (..),
    MissionSessionId (..),
    MissionRepository (..),
    missionRepository,

    -- * The specification
    MissionSpecification (..),
    MissionSelector (..),
    MissionTarget (..),
    MissionTargetKind (..),
    MissionDecisionPolicy (..),
    MissionAutonomy (..),
    MissionPlanStep (..),
    MissionCreation (..),
    createMissionSpecification,
    readMissionSpecification,

    -- * The snapshot
    MissionSnapshot (..),
    MissionStepRecord (..),
    MissionPause (..),
    MissionAttention (..),
    MissionRetryCounter (..),
    MissionReconciliation (..),
    writeMissionSnapshot,
    readMissionSnapshot,

    -- * Lifecycles
    MissionLifecycle (..),
    missionLifecycles,
    missionLifecycleTag,
    missionLifecycleIsTerminal,
    MissionStepLifecycle (..),
    missionStepLifecycles,
    missionStepLifecycleTag,
    missionStepLifecycleIsTerminal,

    -- * The session tree
    MissionSessionNode (..),
    MissionProcessOwnership (..),
    MissionLogReference (..),
    MissionLogKind (..),
    missionLogKindTag,
    MissionTerminalObservation (..),
    MissionObservedOutcome (..),
    MissionSessionDisposition (..),
    missionSessionDisposition,
    MissionSessionTreeError (..),
    validateMissionSessionTree,
    missionSessionTreeErrorMessage,

    -- * The journal
    MissionEvent (..),
    -- | Only the three a caller can receive: a record read under an
    -- unrecognized schema version is absent, and never surfaces.
    MissionJournalLine (MissionJournalEvent, MissionJournalMalformed, MissionJournalRefused),
    recordMissionEvent,
    readMissionJournal,

    -- * Sealed archives and collection evidence
    MissionArchiveState (..),
    MissionPresentation (..),
    MissionWorktreeDisposition (..),
    MissionWorktreeState (..),
    MissionSealedArchive (..),
    missionSealDigestAlgorithm,
    sha256Hex,
    MissionSealFailure (..),
    missionSealFailureMessage,
    sealMissionLog,
    readMissionSealedArchives,
    verifyMissionSealedArchive,

    -- * Archive and delete
    MissionDispositionRefusal (..),
    missionDispositionRefusalMessage,
    archiveMission,
    deleteMission,

    -- * The invocation journal
    MissionInvocationId (..),
    MissionTargetVersion (..),
    MissionIntendedEffect (..),
    missionIntendedEffectTag,
    MissionInvocation (..),
    MissionInvocationOutcome (..),
    missionInvocationOutcomeTag,
    MissionStaleVersion (..),
    missionStaleVersionMessage,
    missionVersionHolds,
    MissionInvocationState (..),
    missionInvocationResolved,
    missionInvocationFor,
    unresolvedMissionInvocations,
    newMissionInvocationId,
    recordMissionInvocation,
    concludeMissionInvocation,
    readMissionInvocations,
    missionInvocationPath,

    -- * The runner-owned control channel
    MissionControlEndpoint (..),
    MissionCommandAuthority (..),
    missionCommandAuthorityTag,
    MissionCommandPayload (..),
    missionCommandPayloadTag,
    MissionChildRequest (..),
    MissionSubmittedCommand (..),
    MissionCommandRejection (..),
    missionCommandRejectionMessage,
    MissionCommandRead (..),
    openMissionControl,
    attachMissionControl,
    submitMissionCommand,
    readMissionCommands,
    consumeMissionCommand,
    overrideAuthorized,
    parseMissionConsoleCommand,

    -- * Reconciliation
    MissionStepFailure (..),
    missionStepFailures,
    missionStepFailureTag,
    missionStepFailureMessage,
    missionStepFailureLifecycle,
    missionFailureFromOutcome,
    missionFailureFromRefusal,
    missionFailureFromProviderError,
    MissionExternalWork (..),
    missionExternalWorkTag,
    MissionWorkerReading (..),
    MissionWorkerConclusion (..),
    MissionStepEvidence (..),
    classifyMissionWork,
    MissionHalt (..),
    missionHaltMessage,
    missionLifecycleAdvances,
    missionLifecycleBlocks,
    missionRunnerHalt,
    missionStepRecordFor,
    nextDispatchableStep,
    settledMissionLifecycle,
    blockedMissionLifecycle,
    cancelledByDependency,
    missionSessionSubtree,
    stepHasUnsettledDescendants,
    MissionContinuation (..),
    missionContinuation,
    missionRecoveryBrief,
    missionRecoveryBriefLimit,

    -- * The controller
    MissionDriver (..),
    MissionInventory (..),
    MissionDispatchRequest (..),
    MissionDispatchAccepted (..),
    MissionStartRefusal (..),
    missionStartRefusalMessage,
    MissionController (..),
    MissionAttachment (..),
    startMissionController,
    attachToMission,
    stopMissionController,
    MissionTransition (..),
    missionTransitionMessage,
    MissionIteration (..),
    missionControllerIteration,

    -- * The foreground runner
    MissionRunReport (..),
    missionRunReportLines,
    missionRunSucceeded,
    runMissionMode,
    runMissionWith,
    liveMissionDriver,
    drainMissionConsole,
    drainMissionConsoleWith,
    missionVersionOf,
    preconditionOf,
    missionRunnerPollMicros,
    missionRunnerIterationBudget,

    -- * The lease
    MissionLease (..),
    MissionLeaseOwner (..),
    MissionLeaseAcquisition (..),
    MissionHolderPresence (..),
    acquireMissionLease,
    acquireMissionLeaseWith,
    missionHolderPresence,
    releaseMissionLease,
    readMissionLeaseOwner,
  )
where

import Kanban.Mission.Control
import Kanban.Mission.Controller
import Kanban.Mission.Digest (sha256Hex)
import Kanban.Mission.Invocation
import Kanban.Mission.Journal (MissionJournalLine (..))
import Kanban.Mission.Lease
  ( MissionHolderPresence (..),
    MissionLease (..),
    MissionLeaseAcquisition (..),
    acquireMissionLease,
    acquireMissionLeaseWith,
    missionHolderPresence,
    readMissionLeaseOwner,
    releaseMissionLease,
  )
import Kanban.Mission.Paths (MissionRead (..), missionInvocationPath, missionStoreRoot)
import Kanban.Mission.Reconcile
import Kanban.Mission.Runner
import Kanban.Mission.Session
  ( MissionSessionTreeError (..),
    missionSessionTreeErrorMessage,
    validateMissionSessionTree,
  )
import Kanban.Mission.Store
  ( MissionCreation (..),
    MissionDispositionRefusal (..),
    MissionSealFailure (..),
    MissionStore (..),
    archiveMission,
    createMissionSpecification,
    deleteMission,
    listMissions,
    missionDispositionRefusalMessage,
    missionSealFailureMessage,
    openMissionStore,
    readMissionJournal,
    readMissionSealedArchives,
    readMissionSnapshot,
    readMissionSpecification,
    recordMissionEvent,
    sealMissionLog,
    verifyMissionSealedArchive,
    writeMissionSnapshot,
  )
import Kanban.Mission.Types
  ( MissionArchiveState (..),
    MissionAttention (..),
    MissionAutonomy (..),
    MissionDecisionPolicy (..),
    MissionEvent (..),
    MissionId (..),
    MissionLeaseOwner (..),
    MissionLifecycle (..),
    MissionLogKind (..),
    MissionLogReference (..),
    MissionObservedOutcome (..),
    MissionPause (..),
    MissionPlanStep (..),
    MissionPresentation (..),
    MissionProcessOwnership (..),
    MissionReconciliation (..),
    MissionRepository (..),
    MissionRetryCounter (..),
    MissionSealedArchive (..),
    MissionSelector (..),
    MissionSessionDisposition (..),
    MissionSessionId (..),
    MissionSessionNode (..),
    MissionSnapshot (..),
    MissionSpecification (..),
    MissionStepId (..),
    MissionStepLifecycle (..),
    MissionStepRecord (..),
    MissionTarget (..),
    MissionTargetKind (..),
    MissionTerminalObservation (..),
    MissionWorktreeDisposition (..),
    MissionWorktreeState (..),
    missionLifecycleIsTerminal,
    missionLifecycleTag,
    missionLifecycles,
    missionLogKindTag,
    missionRepository,
    missionSealDigestAlgorithm,
    missionSessionDisposition,
    missionStepLifecycleIsTerminal,
    missionStepLifecycleTag,
    missionStepLifecycles,
  )
