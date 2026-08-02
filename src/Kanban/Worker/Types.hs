{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | The persistent worker's vocabulary: its identity, the task it was
-- launched for, the durable @.spec.json@\/@.state.json@\/@.events.jsonl@
-- records and lease it reads and writes, and the slot its supervisor and
-- deadline watchdog arbitrate a provider through.
--
-- The hand-written 'FromJSON' instances here are schema-tolerant on purpose:
-- a worker directory written by an earlier release still decodes, so a
-- running solve survives an upgrade. Keeping them together in one module is
-- what makes that tolerance auditable in one place.
--
-- This module is internal — "Kanban.Worker" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Worker.Types
  ( WorkerId (..),
    SolveWorkerTask (..),
    PullRequestWorkerTask (..),
    WorkerTask (..),
    WorkerParent (..),
    WorkerSpec (..),
    WorkerEvent (..),
    WorkerStatus (..),
    WorkerState (..),
    WorkerLease (..),
    WorkerEnvelope (..),
    WorkerDescriptor (..),
    ProviderSlot (..),
  )
where

import Data.Aeson (FromJSON (..), ToJSON, withObject, (.!=), (.:), (.:?))
import Data.Set (Set)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Kanban.Domain (Repository, WorkflowConfig, defaultWorkflowConfig)
import Kanban.Process (ManagedProcess, ProcessIdentity)
import Kanban.PullRequestFlow (PullRequestAction, PullRequestOrigin)
import Kanban.Solve (AgentEvent, ResumeProvenance (..), SolveOutcome, SolveWorkflow, SolverBrand)

newtype WorkerId = WorkerId {unWorkerId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data SolveWorkerTask = SolveWorkerTask
  { solveWorkerIssueNumber :: Int,
    solveWorkerWorkflow :: SolveWorkflow,
    solveWorkerBrand :: SolverBrand
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data PullRequestWorkerTask = PullRequestWorkerTask
  { pullRequestWorkerNumber :: Int,
    pullRequestWorkerOrigin :: PullRequestOrigin,
    pullRequestWorkerAction :: PullRequestAction
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WorkerTask = SolveWorkerTaskKind SolveWorkerTask | PullRequestWorkerTaskKind PullRequestWorkerTask
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WorkerParent = WorkerParent
  { workerParentIssueNumber :: Int,
    workerParentReviewRound :: Int,
    workerParentSolverBrand :: SolverBrand,
    workerParentSolverSession :: Maybe Text,
    workerParentSolverLogPath :: Maybe FilePath,
    workerParentStartedAt :: UTCTime,
    workerParentKnownPullRequests :: Set Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WorkerSpec = WorkerSpec
  { workerId :: WorkerId,
    workerRepository :: Repository,
    workerTask :: WorkerTask,
    workerExistingSession :: Maybe Text,
    workerExistingLogPath :: Maybe FilePath,
    workerResumeProvenance :: ResumeProvenance,
    workerUserMessage :: Text,
    workerParent :: Maybe WorkerParent,
    workerCreatedAt :: UTCTime,
    workerMaxRuntimeSeconds :: Int,
    -- | The dashboard's selected kanban config.toml path (Nothing means the
    -- default path), forwarded to a solve or pull-request worker so its
    -- spawned agent can pass the same --config to the canonical issue gate
    -- check or PR-review coordinator.
    workerConfigPath :: Maybe FilePath,
    -- | The dashboard's resolved workflow configuration, forwarded to a
    -- pull-request worker so its spawned agent's prompt can name the same
    -- configured approval/changes-requested labels instead of the defaults.
    workerWorkflowConfig :: WorkflowConfig
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Manual instance so a durable spec file written before
-- 'workerResumeProvenance'/'workerConfigPath'/'workerWorkflowConfig' existed
-- still decodes: legacy specs default to 'ResumeAnswer'/'Nothing'/
-- 'defaultWorkflowConfig', matching every resume's framing prior to their
-- introduction.
instance FromJSON WorkerSpec where
  parseJSON = withObject "WorkerSpec" $ \object ->
    WorkerSpec
      <$> object .: "workerId"
      <*> object .: "workerRepository"
      <*> object .: "workerTask"
      <*> object .: "workerExistingSession"
      <*> object .: "workerExistingLogPath"
      <*> object .:? "workerResumeProvenance" .!= ResumeAnswer
      <*> object .: "workerUserMessage"
      <*> object .: "workerParent"
      <*> object .: "workerCreatedAt"
      <*> object .: "workerMaxRuntimeSeconds"
      <*> object .:? "workerConfigPath" .!= Nothing
      <*> object .:? "workerWorkflowConfig" .!= defaultWorkflowConfig

data WorkerEvent
  = WorkerProviderStarted Int
  | WorkerProviderSpawning Bool
  | WorkerLogOpened FilePath
  | WorkerSessionIdentified Text
  | WorkerAgentOutput AgentEvent
  | WorkerDiagnostic Text
  | WorkerOrphansDetected SolveOutcome [ProcessIdentity]
  | WorkerFinished SolveOutcome
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WorkerStatus = WorkerStarting | WorkerRunning | WorkerOrphaned SolveOutcome | WorkerTerminal SolveOutcome
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WorkerState = WorkerState
  { workerStateId :: WorkerId,
    workerStateStatus :: WorkerStatus,
    workerStateWorkerPid :: Int,
    workerStateWorkerIdentity :: Maybe ProcessIdentity,
    workerStateProviderPid :: Maybe Int,
    workerStateProviderIdentity :: Maybe ProcessIdentity,
    workerStateSessionId :: Maybe Text,
    workerStateLogPath :: Maybe FilePath,
    workerStateHeartbeatAt :: UTCTime,
    workerStateLastActivity :: Text,
    workerStateKnownProcesses :: [ProcessIdentity]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON WorkerState where
  parseJSON = withObject "WorkerState" $ \object ->
    WorkerState
      <$> object .: "workerStateId"
      <*> object .: "workerStateStatus"
      <*> object .: "workerStateWorkerPid"
      <*> object .:? "workerStateWorkerIdentity" .!= Nothing
      <*> object .: "workerStateProviderPid"
      <*> object .:? "workerStateProviderIdentity" .!= Nothing
      <*> object .: "workerStateSessionId"
      <*> object .: "workerStateLogPath"
      <*> object .: "workerStateHeartbeatAt"
      <*> object .: "workerStateLastActivity"
      <*> object .:? "workerStateKnownProcesses" .!= []

data WorkerLease = WorkerLease
  { workerLeaseId :: WorkerId,
    workerLeaseCreatedAt :: UTCTime,
    -- | The freshly spawned supervisor's identity, recorded as soon as it is
    -- known (see 'recordLaunchedSupervisorIdentity'). Durable so a recovery
    -- pass reached before any worker state file exists — the only other
    -- place a supervisor's identity would otherwise be recorded — can still
    -- tell a live pre-state supervisor from a dead one instead of guessing
    -- from elapsed time alone.
    workerLeaseSupervisorIdentity :: Maybe ProcessIdentity
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON WorkerLease where
  parseJSON = withObject "WorkerLease" $ \object ->
    WorkerLease
      <$> object .: "workerLeaseId"
      <*> object .: "workerLeaseCreatedAt"
      <*> object .:? "workerLeaseSupervisorIdentity" .!= Nothing

data WorkerEnvelope = WorkerEnvelope
  { workerEnvelopeTimestamp :: UTCTime,
    workerEnvelopeEvent :: WorkerEvent
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WorkerDescriptor = WorkerDescriptor
  { workerDescriptorSpec :: WorkerSpec,
    workerDescriptorSpecPath :: FilePath,
    workerDescriptorEventPath :: FilePath,
    workerDescriptorStatePath :: FilePath,
    workerDescriptorAckPath :: FilePath,
    workerDescriptorLeasePath :: FilePath,
    workerDescriptorLeaseOwnerPath :: FilePath,
    -- | Marks a user-requested termination a snapshot failure left
    -- unverified. Owned solely by 'terminateWorkerWith' and
    -- 'recoverIfWorkerStoppedWith' (both outside the live supervisor
    -- process), so unlike the state file it is never clobbered by the
    -- supervisor's own heartbeat or census writes.
    workerDescriptorPendingTerminationPath :: FilePath
  }
  deriving stock (Eq, Show)

-- | The single source of truth the deadline watchdog and a task's own
-- spawn-to-registration bracket both contend on, replacing what used to be
-- two separate 'IORef's ('providerRef' and a spawn-pending flag) read
-- independently of each other. Two separate refs can only ever be read one
-- after the other, never as a single atomic combined snapshot: whichever
-- order the reads happen in, a transition landing between them produces a
-- combination that never actually existed at any single instant. Folding
-- both into one 'IORef', mutated only via 'atomicModifyIORef'', gives every
-- read a genuine, whole, un-torn instant to report — closing that gap
-- structurally rather than by carefully choosing a read order (see the
-- history in 'terminateProviderRefWith' and 'rememberProvider' for what that
-- approach still missed).
--
-- 'ProviderSlotClaimedEmpty' is the watchdog's exclusive write: it marks
-- that the watchdog has already committed to "nothing is here, and nothing
-- more will start" as a genuine compare-and-swap against
-- 'ProviderSlotIdle', not a plain overwrite — so it can only ever win when
-- the slot was still idle at that exact instant, and a task's own
-- contending attempt to leave 'ProviderSlotIdle' (see the 'emit' case for
-- 'WorkerProviderSpawning' in 'runWorkerWithTask') is guaranteed to observe
-- the loss and refuse to spawn, rather than silently racing ahead to create
-- a real process the watchdog has already promised does not exist.
data ProviderSlot
  = ProviderSlotIdle
  | ProviderSlotSpawning
  | ProviderSlotRegistered ManagedProcess
  | ProviderSlotClaimedEmpty
