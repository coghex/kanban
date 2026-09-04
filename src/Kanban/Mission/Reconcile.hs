{-# LANGUAGE DerivingStrategies #-}

-- | What live evidence means, decided without touching any of it.
--
-- Every judgement a mission controller makes about the outside world is here,
-- as a function of a record the caller gathered: which class of external work
-- a step is looking at (issue #595, requirement 9), which typed failure a
-- settled action produced (requirement 16), whether the mission may still be
-- advanced at all, and what a fresh provider session is allowed to be told
-- when the recorded one cannot be resumed (requirements 10 and 13).
--
-- Pure on purpose, and that is the whole reason this module exists apart from
-- "Kanban.Mission.Controller". Requirement 1 asks for reconciliation logic
-- that can be exercised without Brick; the honest form of that is logic that
-- can be exercised without a process, a repository, or a clock either. A
-- fixture here stages \"a compatible live worker and a target that already
-- landed\" by writing the record down, rather than by arranging for both to be
-- true of a real machine.
--
-- The classification order is deliberate and fail-closed. Live registered work
-- is answered before the target is read, because acting on a target some
-- worker still owns is the duplication requirement 9 exists to prevent; and a
-- recorded invocation nobody can find a conclusion for is @outcome_unknown@
-- rather than a failure, because requirement 7 forbids inferring that an
-- effect did not happen from the absence of evidence that it did.
--
-- This module is internal — "Kanban.Mission" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Mission.Reconcile
  ( -- * Typed failures
    MissionStepFailure (..),
    missionStepFailures,
    missionStepFailureTag,
    missionStepFailureMessage,
    missionStepFailureLifecycle,
    missionFailureFromOutcome,
    missionFailureFromRefusal,
    missionFailureFromProviderError,

    -- * External work
    MissionExternalWork (..),
    missionExternalWorkTag,
    MissionWorkerReading (..),
    MissionWorkerConclusion (..),
    MissionStepEvidence (..),
    classifyMissionWork,

    -- * Where a runner stops
    MissionHalt (..),
    missionHaltMessage,
    missionLifecycleAdvances,
    missionLifecycleBlocks,
    missionRunnerHalt,

    -- * Plan progression
    missionStepRecordFor,
    nextDispatchableStep,
    settledMissionLifecycle,
    blockedMissionLifecycle,
    cancelledByDependency,
    unresolvedDispatchOf,
    dispatchedButUnregistered,

    -- * The registered session tree
    missionSessionSubtree,
    stepHasUnsettledDescendants,

    -- * Continuation
    MissionContinuation (..),
    missionContinuation,
    missionRecoveryBrief,
    missionRecoveryBriefLimit,
  )
where

import Data.List (find)
import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Action
  ( ActionOutcome (..),
    ActionRefusal (..),
    actionRefusalMessage,
    targetPreconditionMessage,
  )
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.Mission.Invocation
  ( MissionInvocation (..),
    MissionInvocationId (..),
    MissionInvocationOutcome (..),
    MissionInvocationState (..),
    missionInvocationResolved,
    missionStaleVersionMessage,
  )
import Kanban.Mission.Types
  ( MissionLifecycle (..),
    MissionPlanStep (..),
    MissionSessionDisposition (..),
    MissionSessionId (..),
    MissionSessionNode (..),
    MissionSnapshot (..),
    MissionSpecification (..),
    MissionStepId (..),
    MissionStepLifecycle (..),
    MissionStepRecord (..),
    MissionTarget (..),
    missionLifecycleIsTerminal,
    missionLifecycleTag,
    missionSessionDisposition,
    missionStepLifecycleIsTerminal,
  )

-- ---------------------------------------------------------------------------
-- Typed failures
-- ---------------------------------------------------------------------------

-- | Every way an action can fail that a controller has to decide differently
-- about (requirement 16).
--
-- Eight rather than one string, because each of them has a different repair
-- and three of them are not failures of the work at all. A missing executable
-- and an exhausted provider quota are conditions of this machine; a stale
-- version means nothing was mutated and the plan should be recomputed; an
-- unknown outcome means the mission must stop for a person rather than try
-- again. Reporting all of those as \"failed\" is what made a mission unable to
-- tell any of them apart, which is the collapse this vocabulary undoes.
data MissionStepFailure
  = -- | The launch's own recorded finite bound elapsed.
    MissionFailureDeadline Text
  | -- | The owning authority could not authenticate.
    MissionFailureAuthentication Text
  | -- | Configuration or the model roster could not supply what the launch
    -- needed.
    MissionFailureConfiguration Text
  | -- | A local dependency the action needs is definitely absent.
    MissionFailureExecutable Text
  | -- | The provider declined for capacity reasons.
    MissionFailureCapacity Text
  | -- | The recorded precondition had moved; nothing was mutated.
    --
    -- A sentence rather than the two readings, because the same conclusion
    -- reaches this vocabulary from three places that hold different evidence:
    -- the controller's own recheck has both readings, the registry's launch
    -- boundary has both, and a worker that refused its turn hours later has
    -- only what it wrote down. Requiring the pair would have made two of those
    -- three report a generic failure instead.
    MissionFailureStaleVersion Text
  | -- | Something may have happened and no evidence settles it.
    MissionFailureOutcomeUnknown Text
  | MissionFailureGeneric Text
  deriving stock (Eq, Show)

-- | One of each.
--
-- Enumerated here rather than in a test, for the reason every other closed
-- vocabulary in this codebase is: a constructor added without a decision about
-- what it means is a constructor this list stops covering, and the test that
-- reads it fails at the addition rather than at the first mission that hits
-- the new case.
missionStepFailures :: [MissionStepFailure]
missionStepFailures =
  [ MissionFailureDeadline "",
    MissionFailureAuthentication "",
    MissionFailureConfiguration "",
    MissionFailureExecutable "",
    MissionFailureCapacity "",
    MissionFailureStaleVersion "",
    MissionFailureOutcomeUnknown "",
    MissionFailureGeneric ""
  ]

missionStepFailureTag :: MissionStepFailure -> Text
missionStepFailureTag failure = case failure of
  MissionFailureDeadline _ -> "deadline"
  MissionFailureAuthentication _ -> "authentication"
  MissionFailureConfiguration _ -> "configuration"
  MissionFailureExecutable _ -> "executable"
  MissionFailureCapacity _ -> "capacity"
  MissionFailureStaleVersion _ -> "stale_version"
  MissionFailureOutcomeUnknown _ -> "outcome_unknown"
  MissionFailureGeneric _ -> "failed"

missionStepFailureMessage :: MissionStepFailure -> Text
missionStepFailureMessage failure = case failure of
  MissionFailureDeadline detail -> "deadline: " <> detail
  MissionFailureAuthentication detail -> "authentication: " <> detail
  MissionFailureConfiguration detail -> "configuration: " <> detail
  MissionFailureExecutable detail -> "executable: " <> detail
  MissionFailureCapacity detail -> "capacity: " <> detail
  MissionFailureStaleVersion detail -> "stale version: " <> detail
  MissionFailureOutcomeUnknown detail -> "outcome unknown: " <> detail
  MissionFailureGeneric detail -> "failed: " <> detail

-- | Which step lifecycle a failure lands the step in.
--
-- Two are not @failed@, and neither difference is cosmetic. A step nobody can
-- decide about is @outcome_unknown@ because failed is a conclusion and this is
-- the absence of one (requirement 7). And a step refused for a stale
-- precondition goes back to @pending@: nothing was mutated, the reading it was
-- planned against is simply out of date, and requirement 8 asks for
-- replanning rather than a verdict.
missionStepFailureLifecycle :: MissionStepFailure -> MissionStepLifecycle
missionStepFailureLifecycle (MissionFailureOutcomeUnknown _) = MissionStepOutcomeUnknown
missionStepFailureLifecycle (MissionFailureStaleVersion _) = MissionStepPending
missionStepFailureLifecycle _ = MissionStepFailed

-- | The registry's validated terminal result, typed.
--
-- 'Nothing' for the outcomes that are not failures. The deadline is the one
-- constructor the registry now names in its own right, which is what lets this
-- classification be exact instead of a search through a sentence.
missionFailureFromOutcome :: ActionOutcome -> Maybe MissionStepFailure
missionFailureFromOutcome outcome = case outcome of
  ActionDeadlineExceeded detail -> Just (MissionFailureDeadline detail)
  ActionTargetMoved detail -> Just (MissionFailureStaleVersion detail)
  ActionFailed detail -> Just (MissionFailureGeneric detail)
  ActionStopped detail -> Just (MissionFailureOutcomeUnknown detail)
  ActionNeedsInput _ -> Nothing
  ActionPullRequestOpened _ -> Nothing
  ActionPullRequestApproved _ -> Nothing
  ActionPullRequestVerdict _ _ -> Nothing
  ActionIssueReviewed _ _ _ -> Nothing
  ActionApprovalQueueReport _ -> Nothing

-- | A refusal raised before anything was dispatched.
--
-- Nothing was attempted for any of these, so none of them can be an unknown
-- outcome; what they decide is which /kind/ of blocked the step is, and in
-- particular whether the repair is the machine's configuration or the plan.
missionFailureFromRefusal :: ActionRefusal -> MissionStepFailure
missionFailureFromRefusal refusal = case refusal of
  -- Requirement 8's typed result, and it must not fall through to the generic
  -- arm: nothing was dispatched, so this is a plan to redo rather than work
  -- that failed.
  ActionTargetStale _ recorded observed ->
    MissionFailureStaleVersion (targetPreconditionMessage recorded observed)
  ActionCapabilityBlocked _ detail -> MissionFailureExecutable detail
  ActionRoutingUnavailable _ detail -> MissionFailureConfiguration detail
  ActionDispatchFailed _ detail -> MissionFailureGeneric detail
  ActionTurnAlreadyRunning _ detail -> MissionFailureGeneric detail
  other -> MissionFailureGeneric (actionRefusalMessage other)

-- | A provider or GitHub failure, typed by the kind the provider layer already
-- established.
--
-- This is where three of the eight failures above actually come from.
-- 'Kanban.Provider.ProviderErrorKind' has told authentication, a missing
-- executable, and an exhausted budget apart from a generic failure since long
-- before missions existed; reading them back out here is what keeps the
-- mission vocabulary from inventing a second classification of the same
-- evidence.
missionFailureFromProviderError :: ProviderError -> MissionStepFailure
missionFailureFromProviderError failure = case failure.providerErrorKind of
  AuthenticationRequired -> MissionFailureAuthentication failure.providerErrorMessage
  ExecutableMissing -> MissionFailureExecutable failure.providerErrorMessage
  RateLimited -> MissionFailureCapacity failure.providerErrorMessage
  UnsupportedVersion -> MissionFailureConfiguration failure.providerErrorMessage
  RequestTimedOut -> MissionFailureGeneric failure.providerErrorMessage
  InvalidResponse -> MissionFailureGeneric failure.providerErrorMessage
  RequestFailed -> MissionFailureGeneric failure.providerErrorMessage

-- ---------------------------------------------------------------------------
-- External work
-- ---------------------------------------------------------------------------

-- | How a registered worker ended.
--
-- Three, because a provider that stopped to ask a question neither succeeded
-- nor failed, and folding it into either is how a mission would answer its own
-- question or report a working step as broken.
data MissionWorkerConclusion
  = MissionWorkerSucceeded Text
  | MissionWorkerNeedsInput Text
  | MissionWorkerFailed MissionStepFailure
  deriving stock (Eq, Show)

-- | What a live registered worker looks like from the durable record plus one
-- observation.
data MissionWorkerReading = MissionWorkerReading
  { missionWorkerSession :: MissionSessionId,
    missionWorkerLive :: Bool,
    -- | Whether ownership /and/ intent are proven: this mission registered it,
    -- and its task is the step's task. Anything less is opaque live work,
    -- which is waited on rather than adopted.
    missionWorkerCompatible :: Bool,
    -- | 'Just' once it settled, with which of the three ways it ended.
    missionWorkerTerminal :: Maybe MissionWorkerConclusion,
    -- | The provider's own session identifier, when one was recorded and can
    -- still be resumed.
    missionWorkerProviderSession :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | Everything one step's classification is made from.
data MissionStepEvidence = MissionStepEvidence
  { missionEvidenceStep :: MissionStepId,
    missionEvidenceLifecycle :: MissionStepLifecycle,
    missionEvidenceInvocation :: Maybe MissionInvocationState,
    missionEvidenceWorker :: Maybe MissionWorkerReading,
    -- | Positive evidence that the live target already satisfies what this
    -- step was for. Read from the current canonical state, never restored
    -- from the mission's older snapshot, and never inferred from an absence:
    -- \"the item is no longer in the open read\" is 'missionEvidenceDeparted',
    -- because a closed issue with no pull request and a closed-unmerged pull
    -- request both look exactly like a satisfied one to a read that only
    -- covers open work.
    missionEvidenceSatisfied :: Maybe Text,
    -- | The target has left the read this evidence was taken from, and this
    -- read cannot say why. Never success.
    missionEvidenceDeparted :: Maybe Text,
    -- | Live work on this target that this mission did not register, and
    -- cannot prove the intent of.
    missionEvidenceForeign :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | Requirement 9's classification, plus the honest sixth answer.
data MissionExternalWork
  = -- | The result the step wanted already stands. Recorded as satisfied
    -- externally and never repeated.
    MissionWorkLanded Text
  | -- | A compatible live registered worker: attach to it rather than launch
    -- another.
    MissionWorkAttachable MissionWorkerReading
  | -- | Live work that is incompatible, or whose intent cannot be proven.
    -- Pause and hand it to the operator.
    MissionWorkConflicting Text
  | -- | An invocation was recorded and nothing conclusive can be found for it.
    MissionWorkUnresolved Text
  | MissionWorkFailedExternally MissionStepFailure
  | -- | The owning authority stopped to ask something.
    MissionWorkNeedsInput Text
  | -- | Nothing outside this mission has anything to say about this step.
    MissionWorkUnobserved
  deriving stock (Eq, Show)

missionExternalWorkTag :: MissionExternalWork -> Text
missionExternalWorkTag work = case work of
  MissionWorkLanded _ -> "satisfied_externally"
  MissionWorkAttachable _ -> "attachable"
  MissionWorkConflicting _ -> "conflicting"
  MissionWorkUnresolved _ -> "outcome_unknown"
  MissionWorkFailedExternally _ -> "external_failure"
  MissionWorkNeedsInput _ -> "needs_input"
  MissionWorkUnobserved -> "unobserved"

-- | The classification itself.
--
-- The order is the contract. Foreign live work first, because it is the one
-- reading that makes every other one unsafe to act on; then this mission's own
-- live worker, because attaching to it is what stops a second launch; then a
-- conclusive result, in either direction; and only then the invocation with
-- nothing conclusive behind it, which is the unknown outcome.
classifyMissionWork :: MissionStepEvidence -> MissionExternalWork
classifyMissionWork evidence
  | Just detail <- evidence.missionEvidenceForeign = MissionWorkConflicting detail
  | Just reading <- evidence.missionEvidenceWorker,
    reading.missionWorkerLive =
      if reading.missionWorkerCompatible
        then MissionWorkAttachable reading
        else
          MissionWorkConflicting
            ( "session "
                <> reading.missionWorkerSession.unMissionSessionId
                <> " is live on this target and its intent cannot be proven"
            )
  | Just reading <- evidence.missionEvidenceWorker,
    Just (MissionWorkerFailed failure) <- reading.missionWorkerTerminal =
      MissionWorkFailedExternally failure
  | Just reading <- evidence.missionEvidenceWorker,
    Just (MissionWorkerNeedsInput detail) <- reading.missionWorkerTerminal =
      MissionWorkNeedsInput detail
  | Just detail <- evidence.missionEvidenceSatisfied = MissionWorkLanded detail
  | Just reading <- evidence.missionEvidenceWorker,
    Just (MissionWorkerSucceeded detail) <- reading.missionWorkerTerminal =
      MissionWorkLanded detail
  -- Deliberately after both kinds of positive evidence and before the
  -- invocation record. A target that has left the open read is not a target
  -- that succeeded: requirement 9 admits a terminal external item only when it
  -- can be classified confidently, and this read cannot tell a landed result
  -- from a closed issue nobody solved.
  | Just detail <- evidence.missionEvidenceDeparted = MissionWorkUnresolved detail
  | Just state <- evidence.missionEvidenceInvocation,
    not (missionInvocationResolved state) =
      MissionWorkUnresolved (unresolvedDetail state)
  | Just state <- evidence.missionEvidenceInvocation,
    Just (MissionInvocationStale stale) <- state.missionInvocationOutcome =
      MissionWorkFailedExternally (MissionFailureStaleVersion (missionStaleVersionMessage stale))
  | otherwise = MissionWorkUnobserved
  where
    unresolvedDetail state =
      "invocation "
        <> state.missionInvocationRecord.missionInvocationId.unMissionInvocationId
        <> " was journaled and nothing conclusive was found for it"

-- ---------------------------------------------------------------------------
-- Where a runner stops
-- ---------------------------------------------------------------------------

-- | Why a foreground runner has stopped.
data MissionHalt
  = MissionHaltTerminal MissionLifecycle
  | -- | The mission reached a state that only something outside this runner
    -- can move: an answer, a barrier, capacity, a resume, or a recovery
    -- decision.
    MissionHaltBlocked MissionLifecycle Text
  deriving stock (Eq, Show)

missionHaltMessage :: MissionHalt -> Text
missionHaltMessage (MissionHaltTerminal lifecycle) = "mission " <> missionLifecycleTag lifecycle
missionHaltMessage (MissionHaltBlocked lifecycle detail) =
  "mission " <> missionLifecycleTag lifecycle <> ": " <> detail

-- | The three lifecycles a controller may advance from.
--
-- @planned@ has not started, @running@ is under way, and @recovering@ is a
-- reconciliation in progress — all three are states this runner can move on
-- its own. Every other lifecycle is either terminal or waiting on something
-- this runner is not.
missionLifecycleAdvances :: MissionLifecycle -> Bool
missionLifecycleAdvances lifecycle = case lifecycle of
  MissionPlanned -> True
  MissionRunning -> True
  MissionRecovering -> True
  MissionWaitingInput -> False
  MissionWaitingBarrier -> False
  MissionWaitingCapacity -> False
  MissionPaused -> False
  MissionInterrupted -> False
  MissionCompleted -> False
  MissionFailed -> False
  MissionCancelled -> False

-- | The blocked set requirement 1 names, enumerated rather than derived from
-- \"not terminal and not advanceable\", so it can be read and tested as the
-- list it is: @waiting_input@, @waiting_barrier@, @waiting_capacity@,
-- @paused@, and @interrupted@.
--
-- @recovering@ is deliberately not among them. It is a state this runner
-- itself passes through while reconciling, and treating it as blocked would
-- make a recovery pass stop on the state it just entered.
missionLifecycleBlocks :: MissionLifecycle -> Bool
missionLifecycleBlocks lifecycle =
  not (missionLifecycleAdvances lifecycle) && not (missionLifecycleIsTerminal lifecycle)

-- | Whether this lifecycle ends the foreground run, and why.
--
-- 'Nothing' means keep going. Every other lifecycle produces a halt, which is
-- what makes the runner provably non-resident: there is no lifecycle it idles
-- in, so a mission that reaches an answerable state ends the process instead
-- of waiting beside it (§3's non-goal).
missionRunnerHalt :: MissionLifecycle -> Maybe MissionHalt
missionRunnerHalt lifecycle
  | missionLifecycleIsTerminal lifecycle = Just (MissionHaltTerminal lifecycle)
  | missionLifecycleBlocks lifecycle = Just (MissionHaltBlocked lifecycle blockedDetail)
  | otherwise = Nothing
  where
    blockedDetail = case lifecycle of
      MissionWaitingInput -> "it is waiting for an answer this runner cannot supply"
      MissionWaitingBarrier -> "it is waiting on a barrier outside this runner"
      MissionWaitingCapacity -> "it is waiting for provider capacity"
      MissionPaused -> "it is paused and only an explicit resume restarts it"
      MissionInterrupted -> "it was interrupted and needs an explicit recovery decision"
      _ -> "it cannot be advanced from here"

-- ---------------------------------------------------------------------------
-- Plan progression
-- ---------------------------------------------------------------------------

missionStepRecordFor :: MissionStepId -> MissionSnapshot -> Maybe MissionStepRecord
missionStepRecordFor step snapshot =
  find ((== step) . (.missionStepRecordId)) snapshot.missionSnapshotSteps

-- | The first plan step that is pending and every dependency of which has
-- succeeded, in the plan's own order.
--
-- Plan order rather than snapshot order, because the plan is the immutable
-- record of what was asked for and the snapshot is a mutable projection of how
-- far it got; taking eligibility from the mutable one would let a rewritten
-- snapshot reorder a mission's work.
nextDispatchableStep :: MissionSpecification -> MissionSnapshot -> Maybe MissionPlanStep
nextDispatchableStep specification snapshot =
  find eligible specification.missionSpecificationPlan
  where
    eligible step =
      lifecycleOf step.missionPlanStepId == Just MissionStepPending
        && all succeeded step.missionPlanStepDependsOn
    succeeded dependency = lifecycleOf dependency == Just MissionStepSucceeded
    lifecycleOf step = (.missionStepRecordLifecycle) <$> missionStepRecordFor step snapshot

-- | The lifecycle a mission whose steps have all settled has reached, or
-- 'Nothing' while any of them has not.
--
-- Failed outranks cancelled and both outrank completed. The order matters and
-- is not symmetric: a step cancelled because its dependency failed sits beside
-- that failure in every such mission ('cancelledByDependency' is what put it
-- there), so reading the cancellation first would report every failed mission
-- as cancelled and lose the one word that says what went wrong. A step in
-- @needs_input@, @needs_changes@, or @outcome_unknown@ is not settled at all
-- and keeps the answer 'Nothing', which is what stops a mission reporting a
-- conclusion nobody reached.
settledMissionLifecycle :: MissionSnapshot -> Maybe MissionLifecycle
settledMissionLifecycle snapshot
  | null lifecycles = Just MissionCompleted
  | any (== MissionStepFailed) lifecycles = Just MissionFailed
  | any (== MissionStepCancelled) lifecycles = Just MissionCancelled
  | all (== MissionStepSucceeded) lifecycles = Just MissionCompleted
  | otherwise = Nothing
  where
    lifecycles = map (.missionStepRecordLifecycle) snapshot.missionSnapshotSteps

-- | The lifecycle a mission whose steps have stopped moving without settling
-- has reached, and why.
--
-- Consulted only after 'settledMissionLifecycle' has said the mission has not
-- finished and nothing is dispatchable or live. Without it a foreground runner
-- that ran out of eligible work would have no lifecycle to write and would
-- keep asking the same question, which is the idling §3 forbids.
--
-- An unknown outcome is @waiting_input@ rather than @failed@ or @interrupted@,
-- because requirement 7's repair for it is direction from a person, and
-- @waiting_input@ is the lifecycle that says so.
blockedMissionLifecycle :: MissionSnapshot -> Maybe (MissionLifecycle, Text)
blockedMissionLifecycle snapshot
  | has MissionStepOutcomeUnknown =
      Just (MissionWaitingInput, "a step's outcome is unknown and only direction or fresh evidence resolves it")
  | has MissionStepNeedsInput = Just (MissionWaitingInput, "a step is waiting for an answer")
  | has MissionStepNeedsChanges = Just (MissionWaitingInput, "a step came back with changes requested")
  | has MissionStepWaitingCapacity = Just (MissionWaitingCapacity, "a step is waiting for provider capacity")
  | has MissionStepInterrupted = Just (MissionInterrupted, "a step was interrupted")
  | has MissionStepOrphaned = Just (MissionInterrupted, "a step's processes were orphaned")
  | otherwise = Nothing
  where
    has lifecycle = lifecycle `elem` map (.missionStepRecordLifecycle) snapshot.missionSnapshotSteps

-- | A pending step whose plan dependency reached a terminal state other than
-- success, and can therefore never run.
--
-- Cancelling it is a transition rather than a silent skip: the mission's own
-- record has to say why a step it planned never happened, and a runner with a
-- step that is neither eligible nor terminal has nothing left to do and
-- nothing to write.
cancelledByDependency :: MissionSpecification -> MissionSnapshot -> Maybe (MissionPlanStep, MissionStepId)
cancelledByDependency specification snapshot =
  case [(step, dependency) | step <- specification.missionSpecificationPlan, pending step, dependency <- step.missionPlanStepDependsOn, blocked dependency] of
    (pair : _) -> Just pair
    [] -> Nothing
  where
    pending step = lifecycleOf step.missionPlanStepId == Just MissionStepPending
    blocked dependency = case lifecycleOf dependency of
      Just lifecycle -> missionStepLifecycleIsTerminal lifecycle && lifecycle /= MissionStepSucceeded
      Nothing -> False
    lifecycleOf step = (.missionStepRecordLifecycle) <$> missionStepRecordFor step snapshot

-- | A step that is still @pending@ and already has an invocation nobody saw
-- the end of.
--
-- Both durable states a crash around a launch can leave. A crash before the
-- @dispatching@ write leaves a step that still reads @pending@, which
-- 'nextDispatchableStep' would hand straight back to a dispatch — repeating an
-- effect that may already have happened, the one thing requirement 7 forbids
-- outright. A crash after the driver returned and before the invocation was
-- concluded leaves a step reading @dispatching@ beside a worker the mission
-- started and has not recorded, which the ordinary evidence pass would
-- classify as somebody else's live work and pause on.
--
-- Neither is distinguishable from a step that was never dispatched by looking
-- at the step record; only the invocation file is. A live run never sees
-- either, because between the two writes the controller never yields.
unresolvedDispatchOf :: [MissionInvocationState] -> MissionSpecification -> MissionSnapshot -> Maybe (MissionStepId, MissionInvocationId)
unresolvedDispatchOf states specification snapshot =
  case [ (step.missionPlanStepId, state.missionInvocationRecord.missionInvocationId)
       | step <- specification.missionSpecificationPlan,
         lifecycleOf step.missionPlanStepId `elem` [Just MissionStepPending, Just MissionStepDispatching],
         state <- states,
         state.missionInvocationRecord.missionInvocationStep == step.missionPlanStepId,
         not (missionInvocationResolved state)
       ] of
    (found : _) -> Just found
    [] -> Nothing
  where
    lifecycleOf step = (.missionStepRecordLifecycle) <$> missionStepRecordFor step snapshot

-- | A step whose invocation records a dispatched worker its own record does
-- not list.
--
-- The other crash window: the driver returned, the worker is running, the
-- invocation was closed with its identity — and the snapshot write that would
-- have registered the session never happened. Without this the next run reads
-- a step with no sessions, finds a live worker it cannot account for, and
-- pauses the mission for work it started itself.
--
-- The conclusion is the durable association the repair is built from, which is
-- why it is written before the snapshot rather than after.
dispatchedButUnregistered :: [MissionInvocationState] -> MissionSnapshot -> Maybe (MissionStepId, MissionSessionId)
dispatchedButUnregistered states snapshot =
  case [ (state.missionInvocationRecord.missionInvocationStep, MissionSessionId worker)
       | state <- states,
         Just (MissionInvocationDispatched worker) <- [state.missionInvocationOutcome],
         Just record <- [missionStepRecordFor state.missionInvocationRecord.missionInvocationStep snapshot],
         not (missionStepLifecycleIsTerminal record.missionStepRecordLifecycle),
         MissionSessionId worker `notElem` record.missionStepRecordSessions
       ] of
    (found : _) -> Just found
    [] -> Nothing

-- ---------------------------------------------------------------------------
-- The registered session tree
-- ---------------------------------------------------------------------------

-- | Every registered descendant of a session, the session itself included.
--
-- Recursive over the recorded parent links rather than one level deep, because
-- requirement 11 asks a termination to account for every registered
-- descendant, and a child that spawned a child of its own is exactly the case
-- a one-level walk leaves running. The walk is bounded by the node set, so a
-- record whose parent links form a cycle terminates instead of looping.
missionSessionSubtree :: MissionSnapshot -> MissionSessionId -> [MissionSessionNode]
missionSessionSubtree snapshot root = go [root] []
  where
    nodes = snapshot.missionSnapshotSessions
    go [] collected = reverse collected
    go (identity : rest) collected
      | any ((== identity) . (.missionSessionId)) collected = go rest collected
      | otherwise = case find ((== identity) . (.missionSessionId)) nodes of
          Nothing -> go rest collected
          Just node -> go (children identity <> rest) (node : collected)
    children identity =
      [node.missionSessionId | node <- nodes, node.missionSessionParent == Just identity]

-- | Whether any session this step registered /below its own root/ is still
-- live or unverifiable.
--
-- Requirement 11's rule that an owning action stays nonterminal while a
-- registered child survives. Unverifiable counts as surviving: a session
-- nothing proves is gone is one a settled parent would strand.
--
-- Strict descendants, and that is the whole of the rule rather than a
-- simplification of it. The step's own root session /is/ the owning action;
-- counting it would make a step unable to settle until something else had
-- settled the very session whose settling the step is the record of, which is
-- a deadlock rather than a safeguard. What must outlive the parent's
-- conclusion is a child, and a child is exactly what this counts.
stepHasUnsettledDescendants :: MissionSnapshot -> MissionStepId -> Bool
stepHasUnsettledDescendants snapshot step =
  any unsettled (concatMap descendants roots)
  where
    roots = [node.missionSessionId | node <- snapshot.missionSnapshotSessions, node.missionSessionStep == Just step]
    descendants root = drop 1 (missionSessionSubtree snapshot root)
    unsettled node = missionSessionDisposition node /= MissionSessionSettled

-- ---------------------------------------------------------------------------
-- Continuation
-- ---------------------------------------------------------------------------

-- | How the next turn of a step continues the one before it.
data MissionContinuation
  = -- | The recorded provider session can be resumed; this is it.
    MissionResumeSession Text
  | -- | It cannot, so a fresh session starts with this bounded brief and a new
    -- recorded identity. Never the original session under another name
    -- (requirement 13).
    MissionFreshSession Text
  deriving stock (Eq, Show)

-- | Resume when there is a session to resume, and otherwise brief a new one.
missionContinuation :: MissionSpecification -> MissionSnapshot -> MissionPlanStep -> Maybe MissionWorkerReading -> MissionContinuation
missionContinuation specification snapshot step reading =
  case reading >>= (.missionWorkerProviderSession) of
    Just session -> MissionResumeSession session
    Nothing -> MissionFreshSession (missionRecoveryBrief specification snapshot step)

-- | How much of a brief a fresh session may be given.
--
-- A bound rather than a guideline: requirement 10 says /bounded/, and an
-- unbounded brief is how a mission's whole history ends up in a prompt one
-- recovery at a time.
missionRecoveryBriefLimit :: Int
missionRecoveryBriefLimit = 4000

-- | The brief itself: the original request, what has settled, and the
-- immediate task.
--
-- Assembled only from durable mission and action state — the specification the
-- mission was created with and the snapshot it has reached. No provider text,
-- no repository content, and no issue or pull-request body, none of which the
-- mission store holds in the first place (§16). Truncated to
-- 'missionRecoveryBriefLimit' with the cut named, so a brief that lost its tail
-- says so rather than reading as a complete but shorter account.
missionRecoveryBrief :: MissionSpecification -> MissionSnapshot -> MissionPlanStep -> Text
missionRecoveryBrief specification snapshot step = bound (Text.unlines (concat sections))
  where
    sections =
      [ ["Mission request: " <> specification.missionSpecificationRequest],
        ["Planner summary: " <> summary | Just summary <- [snapshot.missionSnapshotPlannerSummary]],
        ["Settled so far:"],
        settled,
        ["Immediate task: " <> step.missionPlanStepSummary],
        ["Target: " <> renderTarget target | Just target <- [step.missionPlanStepTarget]]
      ]
    settled = case mapMaybe settledLine snapshot.missionSnapshotSteps of
      [] -> ["  (nothing has settled yet)"]
      lines' -> lines'
    settledLine record
      | record.missionStepRecordLifecycle == MissionStepSucceeded =
          Just ("  " <> record.missionStepRecordId.unMissionStepId <> ": succeeded")
      | isJust record.missionStepRecordDetail && record.missionStepRecordLifecycle /= MissionStepPending =
          Just
            ( "  "
                <> record.missionStepRecordId.unMissionStepId
                <> ": "
                <> maybe "" id record.missionStepRecordDetail
            )
      | otherwise = Nothing
    renderTarget target =
      "#" <> Text.pack (show target.missionTargetNumber) <> maybe "" (" " <>) target.missionTargetTitle
    bound text
      | Text.length text <= missionRecoveryBriefLimit = text
      | otherwise = Text.take missionRecoveryBriefLimit text <> "\n(brief truncated)\n"
