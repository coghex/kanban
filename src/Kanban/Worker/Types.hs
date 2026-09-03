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
    ReviewCommandId (..),
    SolveWorkerTask (..),
    PullRequestWorkerTask (..),
    IssueHostWorkerTask (..),
    IssueActionWorkerTask (..),
    WorkerTask (..),
    issueActionTask,
    issueHostTask,
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
import Kanban.Models (RecordedAssignment)
import Kanban.Process (ManagedProcess, ProcessIdentity)
import Kanban.Preflight (IssueOrigin)
import Kanban.PullRequestFlow (PullRequestAction, PullRequestOrigin)
import Kanban.Review
  ( CanonicalIssueReviewResult,
    ReviewEvent,
    ReviewRequestId,
    ReviewStage,
    ReviewThreadId,
  )
import Kanban.Solve (AgentEvent, ResumeProvenance (..), SolveOutcome, SolveWorkflow, SolverBrand)

newtype WorkerId = WorkerId {unWorkerId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | One dashboard-to-child command's identity.
--
-- Declared here rather than beside the command protocol in
-- "Kanban.Worker.Command" because the /journal/ names it too: a delivery
-- writes what it delivered, and that record has to be matchable against the
-- ledger entry for the same command. The protocol built on it stays there;
-- this is just the identity, next to every other durable identity.
newtype ReviewCommandId = ReviewCommandId {unReviewCommandId :: Text}
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

-- | The repository-scoped review host (SAG-10).
--
-- One per canonical repository, and the only worker that owns a
-- 'Kanban.Review.ReviewClient' and its connection pool. It runs no review of
-- its own: every initial review, rereview, and revision is a separately
-- durable child action addressed to it, which is what lets a shared-process
-- provider multiplex two concurrent issue threads through one connection
-- while each of them still has its own lease, journal, commands, and
-- terminal result.
--
-- The identity is recorded rather than derived from 'workerRepository' at
-- read time for the reason every other durable field is: a child proves it
-- belongs to this host by naming its id, and the host proves it belongs to
-- this repository by naming the identity its launch resolved.
newtype IssueHostWorkerTask = IssueHostWorkerTask
  { issueHostRepositoryIdentity :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | One issue action owned by a repository's review host.
--
-- The stage is what decides the owning authority, and the two are never
-- interchangeable: 'Kanban.Review.InitialReview' and
-- 'Kanban.Review.IssueRereview' run the canonical @approve_issues.py@
-- backend, which is the only authority that publishes a canonical review
-- comment or moves a verdict label, while 'Kanban.Review.IssueRevision' runs
-- the embedded interactive client, whose @kanban_github_issue@ tool may
-- publish one specification amendment and move @reviewed:changes@ to
-- @reviewed:revised@ and may never approve.
--
-- The origin is recorded rather than re-read: the detached host holds no
-- issue body, and preflighting against a body refetched later would check a
-- different marker than the launch boundary allowed the action on.
data IssueActionWorkerTask = IssueActionWorkerTask
  { issueActionIssueNumber :: Int,
    issueActionStage :: ReviewStage,
    -- | The host this child belongs to. Startup discovery reattaches a child
    -- only to its owning host, so the claim has to be on the child's own
    -- durable record rather than inferred from whichever host happens to be
    -- live in the directory now.
    issueActionHost :: WorkerId,
    issueActionOrigin :: IssueOrigin
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WorkerTask
  = SolveWorkerTaskKind SolveWorkerTask
  | PullRequestWorkerTaskKind PullRequestWorkerTask
  | IssueHostWorkerTaskKind IssueHostWorkerTask
  | IssueActionWorkerTaskKind IssueActionWorkerTask
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The issue action a task is, if it is one. Written once here rather than
-- pattern-matched at each of the dozen places that ask, so a third worker
-- kind carrying an issue number cannot quietly start answering yes.
issueActionTask :: WorkerTask -> Maybe IssueActionWorkerTask
issueActionTask (IssueActionWorkerTaskKind task) = Just task
issueActionTask _ = Nothing

issueHostTask :: WorkerTask -> Maybe IssueHostWorkerTask
issueHostTask (IssueHostWorkerTaskKind task) = Just task
issueHostTask _ = Nothing

-- | What an autosolve pull-request worker records about the /solver/ that
-- launched it, so a dashboard restart can restore that solver's own session
-- beside the pull-request one it discovered.
--
-- Every field here describes the solver rather than this worker: the pull
-- request's specification already carries its own session id, log path,
-- brand, and model assignment, and reading those into the parent session is
-- how a restarted revision reaches the reviewer's provider instead of the
-- solver's.
data WorkerParent = WorkerParent
  { workerParentIssueNumber :: Int,
    workerParentReviewRound :: Int,
    workerParentSolverBrand :: SolverBrand,
    workerParentSolverSession :: Maybe Text,
    workerParentSolverLogPath :: Maybe FilePath,
    workerParentStartedAt :: UTCTime,
    workerParentKnownPullRequests :: Set Int,
    -- | The pull request the run has bound, once discovery has bound one.
    --
    -- Durable because a restart has nowhere else to learn it: the loop's
    -- discovery arm only ever binds a /new/ pull request, so a run reattached
    -- mid-revision with this absent would reach its rereview with nothing
    -- bound and halt on a pull request that is still there and may already be
    -- approved. 'Nothing' is a run that has not bound one yet -- and a parent
    -- recorded before this field existed, which is the same thing for every
    -- run that had not.
    workerParentPullRequest :: Maybe Int,
    -- | The assignment the solver's own worker recorded, so a revision
    -- launched after a restart replays the solver's cell rather than the
    -- reviewer's (D-7). 'Nothing' for a parent recorded before this field
    -- existed, which resolves once on that session's next launch exactly as
    -- any other pre-MODEL-7 session does.
    workerParentSolverAssignment :: Maybe RecordedAssignment
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Hand-written for the same reason 'WorkerSpec's is: a durable
-- specification written before 'workerParentPullRequest' or
-- 'workerParentSolverAssignment' existed still decodes, so an upgrade cannot
-- drop a running autosolve loop out of discovery.
instance FromJSON WorkerParent where
  parseJSON = withObject "WorkerParent" $ \object ->
    WorkerParent
      <$> object .: "workerParentIssueNumber"
      <*> object .: "workerParentReviewRound"
      <*> object .: "workerParentSolverBrand"
      <*> object .: "workerParentSolverSession"
      <*> object .: "workerParentSolverLogPath"
      <*> object .: "workerParentStartedAt"
      <*> object .: "workerParentKnownPullRequests"
      <*> object .:? "workerParentPullRequest" .!= Nothing
      <*> object .:? "workerParentSolverAssignment" .!= Nothing

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
    workerWorkflowConfig :: WorkflowConfig,
    -- | The roster cell this launch resolved, recorded here so the detached
    -- supervisor runs on exactly what the dashboard checked and every later
    -- resume of the same provider session replays it unchanged (D-7,
    -- MODEL-7). 'Nothing' is a specification written before this field
    -- existed: the supervisor refuses such a spec rather than resolving a
    -- cell of its own, and the launch boundary resolves once and records the
    -- result on that session's next resume.
    workerAssignment :: Maybe RecordedAssignment
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Manual instance so a durable spec file written before
-- 'workerResumeProvenance'/'workerConfigPath'/'workerWorkflowConfig'/
-- 'workerAssignment' existed still decodes: legacy specs default to
-- 'ResumeAnswer'/'Nothing'/'defaultWorkflowConfig'/'Nothing', matching every
-- resume's framing prior to their introduction.
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
      <*> object .:? "workerAssignment" .!= Nothing

data WorkerEvent
  = WorkerProviderStarted Int
  | WorkerProviderSpawning Bool
  | WorkerLogOpened FilePath
  | WorkerSessionIdentified Text
  | WorkerAgentOutput AgentEvent
  | WorkerDiagnostic Text
  | WorkerOrphansDetected SolveOutcome [ProcessIdentity]
  | -- | One review event, journaled verbatim by the repository host into the
    -- child action it belongs to.
    --
    -- Verbatim, and not a rendering of it, because a reattaching dashboard
    -- replays these through the very handler a live event reaches
    -- ('Kanban.UI.Review.applyReviewEvent'). That is what makes the
    -- reconstructed overlay the same bounded transcript suffix, pending
    -- interaction, activity, and follow state a dashboard that never closed
    -- would be showing — without the bound ever reaching back into the
    -- journal, which retains every event either way (requirement 4).
    WorkerReviewEvent ReviewEvent
  | -- | What a person typed or chose, and whether it reached the provider.
    --
    -- The overlay's own half of the transcript, journaled rather than
    -- appended optimistically in the dashboard that submitted it. A runner
    -- owns the action, so the dashboard is a viewer: it can be closed between
    -- the answer and the reply, replaced by another, or never have existed
    -- when the command was written. Recording the line here is what makes the
    -- transcript a later dashboard reconstructs identical to the one a
    -- dashboard that stayed open is showing (requirement 4) rather than one
    -- missing every word the user contributed.
    --
    -- 'Nothing' is delivered; 'Just' carries why it was not, which is the
    -- account a rejected steer needs so it can be offered back rather than
    -- left looking sent.
    --
    -- It names its command, and that is load-bearing rather than decorative.
    -- This record is written before the command's final acknowledgement, so
    -- when that write fails the ledger keeps only the claim while the journal
    -- already holds the answer. A later host reconciles the two by this id,
    -- rather than reporting a command it can see was delivered as one whose
    -- outcome nobody observed.
    WorkerReviewInput ReviewCommandId Text (Maybe Text)
  | -- | What the canonical @approve_issues.py@ backend reported for an
    -- initial review or rereview, including the reviewer route and models it
    -- selected.
    --
    -- Recorded rather than re-derived: the route and models are the
    -- backend's own choice, and a canonical child has no embedded provider
    -- session to read them off (requirement 5).
    WorkerCanonicalReviewFinished ReviewStage (Either Text CanonicalIssueReviewResult)
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
    workerStateKnownProcesses :: [ProcessIdentity],
    -- | The provider thread an interactive revision is running on, recorded
    -- as soon as the provider names it.
    --
    -- The three review identifiers below are stage-specific and optional by
    -- construction (requirement 5). A canonical initial review or rereview
    -- has no embedded provider session at all, so it records none of them
    -- and fabricates none: its subprocess is 'workerStateProviderPid' and
    -- 'workerStateProviderIdentity' like any other managed child, and its
    -- route and models arrive on 'WorkerCanonicalReviewFinished'.
    workerStateReviewThread :: Maybe ReviewThreadId,
    -- | The turn currently running on that thread, so a command submitted
    -- after a dashboard restart can name the turn it means to interrupt or
    -- steer rather than whichever one is running when it is read.
    workerStateReviewTurn :: Maybe Text,
    -- | The interaction the provider is waiting on an answer to, if any.
    -- Durable because a question raised while no dashboard was running has to
    -- still be answerable by the one that arrives next (requirement 10).
    workerStateReviewRequest :: Maybe ReviewRequestId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Hand-written for the reason 'WorkerSpec's is, and now carrying the three
-- optional review identifiers as well: a solve or pull-request state written
-- before any of them existed still decodes, which matters more here than
-- anywhere else because a state file that will not decode drops a live worker
-- out of startup discovery rather than reporting it.
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
      <*> object .:? "workerStateReviewThread" .!= Nothing
      <*> object .:? "workerStateReviewTurn" .!= Nothing
      <*> object .:? "workerStateReviewRequest" .!= Nothing

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
    -- | Where a pre-MODEL-7 worker's model-roster snapshot was written.
    --
    -- Nothing writes one any more: 'workerAssignment' carries the resolved
    -- cell to the supervisor inside the specification itself, so a second
    -- durable artifact describing the same cell was retired with it. The
    -- path survives for exactly one job — 'companionArtifactPaths' still
    -- names it, so a snapshot an upgraded-over worker left behind is
    -- collected rather than accumulating in the cache forever.
    workerDescriptorRosterPath :: FilePath,
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
    workerDescriptorPendingTerminationPath :: FilePath,
    -- | The dashboard-to-child command journal, and the acknowledgements the
    -- owning live session writes back.
    --
    -- Two files rather than one because they have different writers: a
    -- dashboard appends commands and never acknowledges them, and the host
    -- appends acknowledgements and never issues a command. Only an issue
    -- action ever has either; the paths are derived for every worker so the
    -- collection pass names them unconditionally and cannot leave one behind
    -- (see 'companionArtifactPaths').
    -- | Written by a review host that has decided to exit, before the
    -- final scan that decision rests on. Everything asking whether that host
    -- is live reads it as no, which is what orders a child's admission
    -- against the host's exit rather than leaving the two to race.
    workerDescriptorHandoffPath :: FilePath,
    workerDescriptorCommandPath :: FilePath,
    workerDescriptorCommandAckPath :: FilePath
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
