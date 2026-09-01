{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | The durable shape of a mission: the specification written once, the
-- snapshot replaced atomically, the events appended one line at a time, and
-- the vocabularies all three are written in.
--
-- Three properties of this module are contract rather than convenience.
--
-- * Every independently decoded record carries its own @schemaVersion@, and
--   the version sits /outside/ the payload so a reader can inspect it before
--   attempting to decode what it describes. That is what makes
--   @docs\/design.md@ §16's unknown-version-reads-as-absent rule implementable
--   for a payload whose shape a later release changed beyond recognition; the
--   envelope is 'MissionEnvelope' and the reader is
--   "Kanban.Mission.Paths".'Kanban.Mission.Paths.readMissionRecord'.
-- * Each lifecycle's wire tags are declared exactly once, by a total case
--   expression, and both JSON instances are derived from it. A second
--   hand-written table would be free to disagree with the first.
-- * Terminality is /derived/ from a lifecycle rather than stored beside it.
--   Requirement 8 of issue #592 asks the record to carry terminality as
--   collection evidence, and it does — through 'missionLifecycleIsTerminal'
--   applied to the snapshot's own lifecycle. A stored second copy is a value
--   that can contradict the lifecycle it summarises, and the collector would
--   then have two answers and no way to choose.
--
-- Nothing here launches a process, observes one, or contacts GitHub. The
-- process identities and owned groups a session records are values a runner
-- will populate; this module only says where they live and how they are
-- spelled.
module Kanban.Mission.Types
  ( -- * Identity
    MissionId (..),
    MissionStepId (..),
    MissionSessionId (..),
    MissionRepository (..),
    missionRepository,
    missionRepositoryMatches,

    -- * Envelopes
    MissionEnvelope (..),
    missionSpecificationSchemaVersion,
    missionSnapshotSchemaVersion,
    missionEventSchemaVersion,
    missionSealSchemaVersion,
    missionLeaseSchemaVersion,

    -- * The immutable specification
    MissionSpecification (..),
    MissionSelector (..),
    MissionTarget (..),
    MissionTargetKind (..),
    MissionDecisionPolicy (..),
    MissionAutonomy (..),
    MissionPlanStep (..),

    -- * The replaceable snapshot
    MissionSnapshot (..),
    MissionStepRecord (..),
    MissionPause (..),
    MissionAttention (..),
    MissionRetryCounter (..),
    MissionReconciliation (..),

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

    -- * Archive state and collection evidence
    MissionArchiveState (..),
    MissionPresentation (..),
    MissionWorktreeDisposition (..),
    MissionWorktreeState (..),
    MissionSealedArchive (..),
    missionSealDigestAlgorithm,

    -- * The journal
    MissionEvent (..),

    -- * The lease
    MissionLeaseOwner (..),
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, withText, (.:), (.=))
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Kanban.Domain (Repository (..))
import Kanban.Process (OwnedProcessGroup, ProcessIdentity)

-- | A mission's durable name. It is also a path component, so every path
-- derived from one goes through
-- "Kanban.Mission.Paths".'Kanban.Mission.Paths.missionDirectory', which
-- refuses anything that is not a single plain name.
newtype MissionId = MissionId {unMissionId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype MissionStepId = MissionStepId {unMissionStepId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype MissionSessionId = MissionSessionId {unMissionSessionId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The repository identity a mission record is bound to.
--
-- Deliberately not 'Repository': that type carries @repositoryRoot@, a local
-- checkout path which says nothing about which repository a record belongs to
-- and would make the same mission look foreign after a checkout moved.
data MissionRepository = MissionRepository
  { missionRepositoryOwner :: Text,
    missionRepositoryName :: Text
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

missionRepository :: Repository -> MissionRepository
missionRepository repository =
  MissionRepository
    { missionRepositoryOwner = repository.repositoryOwner,
      missionRepositoryName = repository.repositoryName
    }

-- | Whether a record's recorded identity is the repository it is being read
-- for. A record that fails this is refused rather than adopted (requirement
-- 11): a store directory can be moved, copied, or restored from a backup, and
-- adopting a record from another repository would attribute one repository's
-- sessions and worktrees to another.
missionRepositoryMatches :: MissionRepository -> MissionRepository -> Bool
missionRepositoryMatches = (==)

-- | A versioned wrapper around one durable payload.
--
-- The version is a sibling of the payload rather than a field inside it, so
-- 'Kanban.Mission.Paths.readMissionRecord' can read the version out of a
-- record whose payload it has no hope of decoding.
data MissionEnvelope payload = MissionEnvelope
  { missionEnvelopeSchemaVersion :: Int,
    missionEnvelopePayload :: payload
  }
  deriving stock (Eq, Show, Generic)

-- | The two wire keys are spelled here and nowhere else. @schemaVersion@ in
-- particular is what "Kanban.Mission.Paths" looks up before it decodes
-- anything, and §16 names it, so it is written out rather than left to a
-- generic derivation whose field-name convention a later refactor could move.
instance ToJSON payload => ToJSON (MissionEnvelope payload) where
  toJSON envelope =
    object
      [ "schemaVersion" .= envelope.missionEnvelopeSchemaVersion,
        "payload" .= envelope.missionEnvelopePayload
      ]

instance FromJSON payload => FromJSON (MissionEnvelope payload) where
  parseJSON =
    withObject "MissionEnvelope" $ \fields ->
      MissionEnvelope <$> fields .: "schemaVersion" <*> fields .: "payload"

missionSpecificationSchemaVersion, missionSnapshotSchemaVersion, missionEventSchemaVersion, missionSealSchemaVersion, missionLeaseSchemaVersion :: Int
missionSpecificationSchemaVersion = 1
missionSnapshotSchemaVersion = 1
missionEventSchemaVersion = 1
missionSealSchemaVersion = 1
missionLeaseSchemaVersion = 1

-- | What a mission was asked to do, fixed at creation.
--
-- Written once and never rewritten: everything that changes as a mission runs
-- lives in 'MissionSnapshot' or in the journal, so this record stays a
-- faithful account of what was asked for however far the run diverged from it.
data MissionSpecification = MissionSpecification
  { missionSpecificationId :: MissionId,
    missionSpecificationRepository :: MissionRepository,
    -- | The request as the user phrased it, kept verbatim.
    missionSpecificationRequest :: Text,
    missionSpecificationSelector :: MissionSelector,
    missionSpecificationPolicy :: MissionDecisionPolicy,
    missionSpecificationCreatedAt :: UTCTime,
    missionSpecificationPlan :: [MissionPlanStep]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The normalized selector and the targets it resolved to when the mission
-- was created.
--
-- A snapshot rather than a live query: the tracker moves, and a mission
-- resumed a day later must still be able to say which items it was started
-- for.
data MissionSelector = MissionSelector
  { missionSelectorKind :: Text,
    missionSelectorQuery :: Maybe Text,
    missionSelectorTargets :: [MissionTarget]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data MissionTarget = MissionTarget
  { missionTargetKind :: MissionTargetKind,
    missionTargetNumber :: Int,
    missionTargetTitle :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data MissionTargetKind
  = MissionTargetIssue
  | MissionTargetPullRequest
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)

instance ToJSON MissionTargetKind where
  toJSON = toJSON . missionTargetKindTag

instance FromJSON MissionTargetKind where
  parseJSON = decodeTag "MissionTargetKind" missionTargetKindTag

missionTargetKindTag :: MissionTargetKind -> Text
missionTargetKindTag kind = case kind of
  MissionTargetIssue -> "issue"
  MissionTargetPullRequest -> "pull_request"

-- | How much the mission may decide on its own.
data MissionDecisionPolicy = MissionDecisionPolicy
  { missionDecisionAutonomy :: MissionAutonomy,
    missionDecisionMaxReviewRounds :: Int,
    missionDecisionStopOnFailure :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data MissionAutonomy
  = MissionConfirmEveryStep
  | MissionConfirmOnAmbiguity
  | MissionAutonomous
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)

instance ToJSON MissionAutonomy where
  toJSON = toJSON . missionAutonomyTag

instance FromJSON MissionAutonomy where
  parseJSON = decodeTag "MissionAutonomy" missionAutonomyTag

missionAutonomyTag :: MissionAutonomy -> Text
missionAutonomyTag autonomy = case autonomy of
  MissionConfirmEveryStep -> "confirm_every_step"
  MissionConfirmOnAmbiguity -> "confirm_on_ambiguity"
  MissionAutonomous -> "autonomous"

-- | One step of the plan the mission was created with.
--
-- @missionPlanStepAction@ is a name rather than a typed action: the action
-- registry is SAG-2's, and a mission written before it exists must still name
-- what it intended to run.
data MissionPlanStep = MissionPlanStep
  { missionPlanStepId :: MissionStepId,
    missionPlanStepAction :: Text,
    missionPlanStepSummary :: Text,
    missionPlanStepTarget :: Maybe MissionTarget,
    missionPlanStepDependsOn :: [MissionStepId]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Everything about a mission that changes as it runs.
--
-- Replaced whole and atomically rather than edited in place, so a reader
-- never observes a snapshot half-way between two states and an interrupted
-- write leaves the previous one exactly as it was.
data MissionSnapshot = MissionSnapshot
  { missionSnapshotId :: MissionId,
    missionSnapshotRepository :: MissionRepository,
    missionSnapshotLifecycle :: MissionLifecycle,
    missionSnapshotCurrentStep :: Maybe MissionStepId,
    missionSnapshotNextSteps :: [MissionStepId],
    missionSnapshotSteps :: [MissionStepRecord],
    missionSnapshotPause :: MissionPause,
    missionSnapshotAttention :: Maybe MissionAttention,
    missionSnapshotPlannerSummary :: Maybe Text,
    missionSnapshotRetries :: [MissionRetryCounter],
    -- | What the last reconciliation pass concluded. SAG-3 owns the pass;
    -- this slice owns the field it writes and the readers that must not
    -- guess when it is absent.
    missionSnapshotLastReconciliation :: Maybe MissionReconciliation,
    missionSnapshotSessions :: [MissionSessionNode],
    missionSnapshotArchive :: MissionArchiveState,
    missionSnapshotUpdatedAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data MissionStepRecord = MissionStepRecord
  { missionStepRecordId :: MissionStepId,
    missionStepRecordLifecycle :: MissionStepLifecycle,
    missionStepRecordSessions :: [MissionSessionId],
    missionStepRecordDetail :: Maybe Text,
    missionStepRecordUpdatedAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data MissionPause = MissionPause
  { missionPauseRequested :: Bool,
    missionPauseReason :: Maybe Text,
    missionPauseAt :: Maybe UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The one thing a mission is waiting for a person to resolve.
data MissionAttention = MissionAttention
  { missionAttentionSummary :: Text,
    missionAttentionStep :: Maybe MissionStepId,
    missionAttentionRaisedAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data MissionRetryCounter = MissionRetryCounter
  { missionRetryCounterStep :: MissionStepId,
    missionRetryCounterAttempts :: Int,
    missionRetryCounterLastAttemptAt :: Maybe UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data MissionReconciliation = MissionReconciliation
  { missionReconciliationAt :: UTCTime,
    missionReconciliationOutcome :: Text,
    missionReconciliationSteps :: [MissionStepId]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Where a mission is. The eleven states requirement 5 of issue #592 names,
-- and no more: a twelfth would need a reason a reader must distinguish it.
data MissionLifecycle
  = MissionPlanned
  | MissionRunning
  | MissionWaitingInput
  | MissionWaitingBarrier
  | MissionWaitingCapacity
  | MissionPaused
  | MissionInterrupted
  | MissionRecovering
  | MissionCompleted
  | MissionFailed
  | MissionCancelled
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)

instance ToJSON MissionLifecycle where
  toJSON = toJSON . missionLifecycleTag

instance FromJSON MissionLifecycle where
  parseJSON = decodeTag "MissionLifecycle" missionLifecycleTag

missionLifecycles :: [MissionLifecycle]
missionLifecycles = [minBound .. maxBound]

-- | The one declaration of a mission lifecycle's wire spelling. Total by
-- construction, so a state added above fails to compile until it is spelled
-- here, and both JSON instances read it rather than restating it.
missionLifecycleTag :: MissionLifecycle -> Text
missionLifecycleTag lifecycle = case lifecycle of
  MissionPlanned -> "planned"
  MissionRunning -> "running"
  MissionWaitingInput -> "waiting_input"
  MissionWaitingBarrier -> "waiting_barrier"
  MissionWaitingCapacity -> "waiting_capacity"
  MissionPaused -> "paused"
  MissionInterrupted -> "interrupted"
  MissionRecovering -> "recovering"
  MissionCompleted -> "completed"
  MissionFailed -> "failed"
  MissionCancelled -> "cancelled"

-- | Whether a mission has stopped for good.
--
-- The single spelling of requirement 8's terminality: archive and delete both
-- gate on this, and nothing stores a second copy of the answer beside the
-- lifecycle it is computed from.
missionLifecycleIsTerminal :: MissionLifecycle -> Bool
missionLifecycleIsTerminal lifecycle = case lifecycle of
  MissionCompleted -> True
  MissionFailed -> True
  MissionCancelled -> True
  MissionPlanned -> False
  MissionRunning -> False
  MissionWaitingInput -> False
  MissionWaitingBarrier -> False
  MissionWaitingCapacity -> False
  MissionPaused -> False
  MissionInterrupted -> False
  MissionRecovering -> False

-- | Where one step is. The thirteen states requirement 5 names.
data MissionStepLifecycle
  = MissionStepPending
  | MissionStepDispatching
  | MissionStepRunning
  | MissionStepOutcomeUnknown
  | MissionStepWaitingCapacity
  | MissionStepInterrupted
  | MissionStepOrphaned
  | MissionStepRecovering
  | MissionStepSucceeded
  | MissionStepNeedsChanges
  | MissionStepNeedsInput
  | MissionStepFailed
  | MissionStepCancelled
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)

instance ToJSON MissionStepLifecycle where
  toJSON = toJSON . missionStepLifecycleTag

instance FromJSON MissionStepLifecycle where
  parseJSON = decodeTag "MissionStepLifecycle" missionStepLifecycleTag

missionStepLifecycles :: [MissionStepLifecycle]
missionStepLifecycles = [minBound .. maxBound]

missionStepLifecycleTag :: MissionStepLifecycle -> Text
missionStepLifecycleTag lifecycle = case lifecycle of
  MissionStepPending -> "pending"
  MissionStepDispatching -> "dispatching"
  MissionStepRunning -> "running"
  MissionStepOutcomeUnknown -> "outcome_unknown"
  MissionStepWaitingCapacity -> "waiting_capacity"
  MissionStepInterrupted -> "interrupted"
  MissionStepOrphaned -> "orphaned"
  MissionStepRecovering -> "recovering"
  MissionStepSucceeded -> "succeeded"
  MissionStepNeedsChanges -> "needs_changes"
  MissionStepNeedsInput -> "needs_input"
  MissionStepFailed -> "failed"
  MissionStepCancelled -> "cancelled"

-- | Whether a step has stopped for good.
--
-- @needs_changes@ and @needs_input@ are deliberately /not/ terminal: both are
-- a step waiting for something, and a collector that treated either as
-- finished would collect the worktree the next round is about to reuse.
missionStepLifecycleIsTerminal :: MissionStepLifecycle -> Bool
missionStepLifecycleIsTerminal lifecycle = case lifecycle of
  MissionStepSucceeded -> True
  MissionStepFailed -> True
  MissionStepCancelled -> True
  MissionStepPending -> False
  MissionStepDispatching -> False
  MissionStepRunning -> False
  MissionStepOutcomeUnknown -> False
  MissionStepWaitingCapacity -> False
  MissionStepInterrupted -> False
  MissionStepOrphaned -> False
  MissionStepRecovering -> False
  MissionStepNeedsChanges -> False
  MissionStepNeedsInput -> False

-- | One managed agent session a mission owns.
--
-- @missionSessionParent@ is a single optional identifier rather than a list,
-- so D-14's \"exactly one parent\" is structural for a child that has one and
-- absent for a root. That every parent named actually resolves, within this
-- mission, without a cycle, is
-- "Kanban.Mission.Session".'Kanban.Mission.Session.validateMissionSessionTree'.
data MissionSessionNode = MissionSessionNode
  { missionSessionId :: MissionSessionId,
    missionSessionMission :: MissionId,
    missionSessionParent :: Maybe MissionSessionId,
    -- | The step whose dispatch created this session.
    missionSessionStep :: Maybe MissionStepId,
    -- | The provider brand, e.g. @codex@ or @claude@.
    missionSessionProvider :: Text,
    -- | The provider's own identifier for the conversation, once it names
    -- one. A session that has not been assigned one yet is still a node.
    missionSessionProviderSessionId :: Maybe Text,
    missionSessionOwnership :: MissionProcessOwnership,
    missionSessionLog :: Maybe MissionLogReference,
    missionSessionObservation :: Maybe MissionTerminalObservation
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | What was recorded about the processes a session owns.
--
-- Both fields are 'Maybe' because both are captured best-effort: a snapshot
-- that could not be taken leaves a session with no identity at all, and every
-- judgement below treats that as unverifiable rather than as absent.
data MissionProcessOwnership = MissionProcessOwnership
  { missionProcessIdentity :: Maybe ProcessIdentity,
    missionProcessGroup :: Maybe OwnedProcessGroup
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data MissionLogReference = MissionLogReference
  { missionLogPath :: FilePath,
    missionLogKind :: MissionLogKind
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Which of the two things a session leaves behind a log reference names.
data MissionLogKind
  = -- | The provider's structured event stream, as Kanban recorded it.
    MissionEventStreamLog
  | -- | The provider's own raw log, wherever the provider put it.
    MissionRawProviderLog
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)

instance ToJSON MissionLogKind where
  toJSON = toJSON . missionLogKindTag

instance FromJSON MissionLogKind where
  parseJSON = decodeTag "MissionLogKind" missionLogKindTag

missionLogKindTag :: MissionLogKind -> Text
missionLogKindTag kind = case kind of
  MissionEventStreamLog -> "event_stream"
  MissionRawProviderLog -> "raw_provider_log"

-- | What was observed when a session's processes stopped.
data MissionTerminalObservation = MissionTerminalObservation
  { missionObservationAt :: UTCTime,
    missionObservationOutcome :: MissionObservedOutcome,
    missionObservationDetail :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The outcome half of an observation.
--
-- 'MissionObservedUnknown' is a real answer and the one that matters: it says
-- the session stopped being watched without its end being seen, which is
-- exactly the state a later collector must not treat as finished.
data MissionObservedOutcome
  = MissionObservedExit Int
  | MissionObservedSignalled Int
  | MissionObservedUnknown
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | What the recorded state of one session says about it, without looking at
-- any live process.
data MissionSessionDisposition
  = -- | Observed to have ended, with a definite outcome.
    MissionSessionSettled
  | -- | Recorded as owning processes and never observed to end.
    MissionSessionLive
  | -- | Nothing recorded proves it is gone: no observation and no recorded
    -- ownership, or an observation whose outcome was never established.
    MissionSessionUnverifiable
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)

-- | Reads one session's disposition off what was recorded, and fails closed.
--
-- The absent-evidence case is the one worth stating: a session with neither
-- an observation nor a recorded process identity is 'MissionSessionUnverifiable'
-- rather than settled. Such a node is what a crash between creating a session
-- and capturing its identity leaves behind, and calling it finished is exactly
-- how a delete would destroy the only record of a process still running.
missionSessionDisposition :: MissionSessionNode -> MissionSessionDisposition
missionSessionDisposition session = case session.missionSessionObservation of
  Just observation -> case observation.missionObservationOutcome of
    MissionObservedExit _ -> MissionSessionSettled
    MissionObservedSignalled _ -> MissionSessionSettled
    MissionObservedUnknown -> MissionSessionUnverifiable
  Nothing -> case session.missionSessionOwnership of
    MissionProcessOwnership Nothing Nothing -> MissionSessionUnverifiable
    _ -> MissionSessionLive

-- | The collection evidence a later collector decides from (D-23).
--
-- Requirement 8's five items are carried between this record and the two it
-- points at: terminality is 'missionLifecycleIsTerminal' of the snapshot's own
-- lifecycle, archive state is 'missionArchivePresentation', worktree
-- disposition is 'missionArchiveWorktrees', last access is
-- 'missionArchiveLastAccessedAt', and the sealed-log digests are the
-- 'MissionSealedArchive' records
-- "Kanban.Mission.Store".'Kanban.Mission.Store.readMissionSealedArchives'
-- enumerates. The digests are not copied here on purpose: a seal record is
-- committed by the seal itself, and a second copy in a snapshot replaced by
-- some unrelated update is a copy free to fall behind.
data MissionArchiveState = MissionArchiveState
  { missionArchivePresentation :: MissionPresentation,
    missionArchiveWorktrees :: [MissionWorktreeDisposition],
    missionArchiveLastAccessedAt :: Maybe UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Whether a mission is still part of the active presentation.
data MissionPresentation
  = MissionPresentationActive
  | MissionPresentationArchived
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)

instance ToJSON MissionPresentation where
  toJSON = toJSON . missionPresentationTag

instance FromJSON MissionPresentation where
  parseJSON = decodeTag "MissionPresentation" missionPresentationTag

missionPresentationTag :: MissionPresentation -> Text
missionPresentationTag presentation = case presentation of
  MissionPresentationActive -> "active"
  MissionPresentationArchived -> "archived"

-- | What became of one worktree a mission's steps used.
data MissionWorktreeDisposition = MissionWorktreeDisposition
  { missionWorktreePath :: FilePath,
    missionWorktreeState :: MissionWorktreeState,
    missionWorktreeStep :: Maybe MissionStepId,
    -- | Whether this mission is the only record of why that worktree is
    -- still there. Deleting such a mission strands the worktree with nothing
    -- left to explain it, which is why requirement 10 refuses it.
    missionWorktreeSoleRecoveryRecord :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data MissionWorktreeState
  = MissionWorktreeRetained
  | MissionWorktreeRemoved
  | MissionWorktreeUnknown
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)

instance ToJSON MissionWorktreeState where
  toJSON = toJSON . missionWorktreeStateTag

instance FromJSON MissionWorktreeState where
  parseJSON = decodeTag "MissionWorktreeState" missionWorktreeStateTag

missionWorktreeStateTag :: MissionWorktreeState -> Text
missionWorktreeStateTag state = case state of
  MissionWorktreeRetained -> "retained"
  MissionWorktreeRemoved -> "removed"
  MissionWorktreeUnknown -> "unknown"

-- | One sealed copy of a child's stream or raw log, and what verifies it.
--
-- The digest algorithm is recorded rather than implied, so a record written
-- under one algorithm is still checkable after a later release adds another.
data MissionSealedArchive = MissionSealedArchive
  { -- | The mission this entry belongs to. Checked against the mission whose
    -- archive it was read from, for the reason every other record's identity
    -- is checked: where a record sits and what it says about itself can be
    -- made to disagree, and a seal is what a collector trusts before removing
    -- a source.
    missionSealedMission :: MissionId,
    missionSealedRepository :: MissionRepository,
    missionSealedSession :: MissionSessionId,
    missionSealedKind :: MissionLogKind,
    -- | The archived copy's name inside the mission's @archive@ directory.
    -- A name rather than a path, so a store that moved still resolves.
    missionSealedName :: FilePath,
    missionSealedDigestAlgorithm :: Text,
    missionSealedDigest :: Text,
    missionSealedByteLength :: Integer,
    missionSealedAt :: UTCTime,
    -- | Where the bytes were copied from, for a reader asking what was
    -- sealed. Nothing verifies against it: the point of a seal is that the
    -- archived copy outlives the source.
    missionSealedSource :: FilePath
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The algorithm this release seals with.
missionSealDigestAlgorithm :: Text
missionSealDigestAlgorithm = "sha256"

-- | One journal record.
--
-- Carries both identities, like every other independently decoded record here:
-- a line is decoded on its own, so where it sits and what it says about itself
-- can be made to disagree, and a reader that took the location as the answer
-- would emit another mission's event as this one's.
--
-- The payload is deliberately a name and a free-text detail rather than a sum
-- over the runner's vocabulary: the runner is SAG-3's and its action registry
-- is SAG-2's, and a journal written today must still be readable when both
-- exist. What this slice fixes is the envelope, the ordering, and the append
-- discipline.
data MissionEvent = MissionEvent
  { missionEventAt :: UTCTime,
    missionEventMission :: MissionId,
    missionEventRepository :: MissionRepository,
    missionEventStep :: Maybe MissionStepId,
    missionEventSession :: Maybe MissionSessionId,
    missionEventKind :: Text,
    missionEventDetail :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Who holds a mission's lease.
--
-- Carries both identities for the reason every record here does, and the
-- consequence is sharper than elsewhere: an owner record from somewhere else
-- naming a process that has exited would otherwise read as proof that /this/
-- mission's holder is gone, and hand the lease out from under a holder about
-- whom nothing was recorded.
--
-- The holder is recorded as a bare process identifier rather than a
-- "Kanban.Process" identity, because capturing one of those means reading a
-- process snapshot, and reading a snapshot means running @ps@ — which
-- requirement 15 of issue #592 forbids this slice outright. What that costs is
-- the start time an identity pins a recycled identifier with; see
-- "Kanban.Mission.Lease" for why losing it moves the lease's only wrong answer
-- to the safe side.
data MissionLeaseOwner = MissionLeaseOwner
  { missionLeaseOwnerMission :: MissionId,
    missionLeaseOwnerRepository :: MissionRepository,
    -- | Unique to one acquisition, so a release can refuse to remove a lease
    -- some later acquisition now holds.
    missionLeaseOwnerToken :: Text,
    missionLeaseOwnerAcquiredAt :: UTCTime,
    missionLeaseOwnerProcessId :: Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Decodes an enumeration from its wire tag, using the same total tag
-- function the encoder uses, so the two cannot drift apart. An unrecognized
-- tag fails the parse, which is a decode failure of the payload rather than
-- an unrecognized /schema version/: the two are different answers, and only
-- the second reads as absence (see "Kanban.Mission.Paths").
decodeTag :: (Bounded value, Enum value) => String -> (value -> Text) -> Value -> Parser value
decodeTag name tag = withText name $ \wire ->
  case lookup wire [(tag value, value) | value <- [minBound .. maxBound]] of
    Just value -> pure value
    Nothing -> fail (name <> ": unrecognized tag " <> show wire)
