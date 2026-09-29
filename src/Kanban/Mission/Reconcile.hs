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
    missionDispatchInterrupted,

    -- * Where a runner stops
    MissionHalt (..),
    missionHaltMessage,
    missionLifecycleAdvances,
    missionLifecycleBlocks,
    missionRunnerHalt,
    missionRunnerHaltAt,
    missionHaltIsIndeterminate,

    -- * Provider-capacity waits
    missionCapacityBackoff,
    missionCapacityBackoffCap,
    missionCapacityWaitFor,
    MissionCapacityWake (..),
    missionCapacityWake,
    missionCapacityWakeMessage,
    missionUndatedCapacityWaits,

    -- * Plan progression
    missionStepRecordFor,
    nextDispatchableStep,
    settledMissionLifecycle,
    blockedMissionLifecycle,
    missionInterruptedStep,
    cancelledByDependency,
    MissionOpenDispatch (..),
    missionOpenDispatchIsChild,
    unresolvedDispatchOf,
    unresolvedTerminationOf,
    dispatchedButUnregistered,

    -- * The registered session tree
    missionSessionSubtree,
    stepHasUnsettledDescendants,
    stepUnverifiableDescendant,

    -- * Continuation
    MissionContinuation (..),
    missionContinuation,
    missionRecoveryBrief,
    missionRecoveryBriefLimit,
  )
where

import Data.List (find)
import Data.Maybe (isJust, isNothing, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Kanban.Action
  ( ActionOutcome (..),
    ActionRefusal (..),
    actionRefusalMessage,
    targetPreconditionMessage,
  )
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.Mission.Invocation
  ( MissionIntendedEffect (..),
    MissionInvocation (..),
    MissionInvocationId (..),
    MissionInvocationOutcome (..),
    MissionInvocationState (..),
    missionInvocationResolved,
    missionStaleVersionMessage,
  )
import Kanban.Mission.Types
  ( MissionCapacityRetry (..),
    MissionCapacityWait (..),
    MissionLifecycle (..),
    MissionPlanStep (..),
    MissionObservedOutcome (..),
    MissionSessionDisposition (..),
    MissionTerminalObservation (..),
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
--
-- A provider-capacity limit is not a failure either (issue #752): nothing
-- about the work was wrong, and the step waits and retries rather than
-- concluding. The caller that reads the registry's result turns it into
-- 'MissionWorkerCapacityLimited' instead.
missionFailureFromOutcome :: ActionOutcome -> Maybe MissionStepFailure
missionFailureFromOutcome outcome = case outcome of
  ActionDeadlineExceeded detail -> Just (MissionFailureDeadline detail)
  ActionTargetMoved detail -> Just (MissionFailureStaleVersion detail)
  ActionCapacityLimited _ _ -> Nothing
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
-- Four, because a provider that stopped to ask a question neither succeeded
-- nor failed, and folding it into either is how a mission would answer its own
-- question or report a working step as broken — and a provider that refused
-- the turn at a positively identified rate or usage limit (issue #752) did not
-- fail the work either: the same turn is taken again once the limit lifts,
-- at the reset time the provider named when it named one.
data MissionWorkerConclusion
  = MissionWorkerSucceeded Text
  | MissionWorkerNeedsInput Text
  | MissionWorkerFailed MissionStepFailure
  | MissionWorkerCapacityLimited (Maybe UTCTime) Text
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
  | -- | This step's own attempt, the named session, ended at a provider
    -- limit: wait for it to lift and retry (issue #752).
    MissionWorkCapacityLimited MissionSessionId (Maybe UTCTime) Text
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
  MissionWorkCapacityLimited _ _ _ -> "capacity_wait"
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
    Just (MissionWorkerCapacityLimited resetsAt detail) <- reading.missionWorkerTerminal =
      MissionWorkCapacityLimited reading.missionWorkerSession resetsAt detail
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

-- | Whether a launch this store never saw the end of was cut off before it
-- produced anything a later pass can find.
--
-- The interrupted step of D-3 (as amended): a @--mission@ process journaled
-- the launch and died before any worker handle or conclusion was recorded, and
-- the evidence pass now finds nothing at all behind it — no worker of the
-- step's own, no result, no departure, and no foreign live work. That is the
-- one reading 'classifyMissionWork' reaches only through the open invocation
-- itself, so it is asked of that classification rather than restated.
--
-- Everything else an open launch can meet keeps the answer it had: a worker
-- that ended with nothing conclusive is a worker, a target that left the open
-- read is a departure, and live work nobody can vouch for is a conflict. Each
-- of those is still @outcome_unknown@ or a pause, because each is evidence
-- that something may have happened, and the interrupted step is precisely the
-- one with none.
missionDispatchInterrupted :: MissionStepEvidence -> Bool
missionDispatchInterrupted evidence = case classifyMissionWork evidence of
  MissionWorkUnresolved _ ->
    isNothing evidence.missionEvidenceWorker
      && isNothing evidence.missionEvidenceDeparted
      && maybe False (not . missionInvocationResolved) evidence.missionEvidenceInvocation
  _ -> False

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
  | -- | Blocked, and blocked on a step nothing could establish the outcome of.
    --
    -- Its own halt because it is the one stop this run may not report as a
    -- success: \"an indeterminate result is never a success\" is the contract,
    -- and a mission waiting for an answer about work that /might/ have
    -- happened is exactly that. Every other blocked state is a mission doing
    -- what it was asked — pausing, waiting for capacity, waiting for a person
    -- — and reporting one of those as a failure would make an ordinary,
    -- correct stop look like a broken run.
    MissionHaltIndeterminate MissionLifecycle Text
  deriving stock (Eq, Show)

missionHaltMessage :: MissionHalt -> Text
missionHaltMessage (MissionHaltTerminal lifecycle) = "mission " <> missionLifecycleTag lifecycle
missionHaltMessage (MissionHaltBlocked lifecycle detail) =
  "mission " <> missionLifecycleTag lifecycle <> ": " <> detail
missionHaltMessage (MissionHaltIndeterminate lifecycle detail) =
  "mission " <> missionLifecycleTag lifecycle <> ": " <> detail <> ", and an outcome it may have produced is unknown"

-- | Whether this halt leaves something nobody has established.
--
-- The one question @kanban --mission@'s exit status turns on.
missionHaltIsIndeterminate :: MissionHalt -> Bool
missionHaltIsIndeterminate (MissionHaltIndeterminate _ _) = True
missionHaltIsIndeterminate _ = False

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
missionRunnerHalt :: MissionSnapshot -> [MissionInvocationState] -> Maybe MissionHalt
missionRunnerHalt snapshot states = haltOn Nothing snapshot states

-- | 'missionRunnerHalt' at a moment, which is what lets a capacity wait end
-- (issue #752).
--
-- A mission waiting for provider capacity is blocked until one of its waits
-- is due and then it is not: the controller takes the next transition, which
-- wakes that step, instead of halting on a lifecycle nothing else will move.
-- Every other answer is the one 'missionRunnerHalt' gives, and a wait that is
-- not yet due — or whose retry time cannot be read — says so in its halt.
missionRunnerHaltAt :: UTCTime -> MissionSnapshot -> [MissionInvocationState] -> Maybe MissionHalt
missionRunnerHaltAt now = haltOn (Just now)

haltOn :: Maybe UTCTime -> MissionSnapshot -> [MissionInvocationState] -> Maybe MissionHalt
haltOn clock snapshot states
  -- An invocation recorded as unknown outranks every other reading of this
  -- snapshot, a terminal one included, and this guard is first because that is
  -- the only way to say so.
  --
  -- The lifecycle beside such a record cannot be trusted to have been written
  -- by a reader that knew about it. A run closes an effect as unknown and
  -- writes @waiting_input@ as a second, separate write; a store where that
  -- second write failed has been carried forward by whatever ran next, and a
  -- release that did not consult the record could settle the mission over it.
  -- Durable state outlives the release that wrote it, so @completed@ here is a
  -- claim about the plan and never evidence that the effect was accounted for
  -- — and reporting it as a success is precisely what section 16 forbids.
  --
  -- A step's unknown outcome is deliberately not treated this way: the pass
  -- that derives a blocked lifecycle rereads the step records every iteration,
  -- so a lifecycle write it lost is one it makes again. This record is the one
  -- nothing revisits.
  | unknownInvocation = Just (MissionHaltIndeterminate lifecycle unaccountedDetail)
  | missionLifecycleIsTerminal lifecycle = Just (MissionHaltTerminal lifecycle)
  -- A due capacity wait is the one blocked state this runner can end on its
  -- own, and it does so only once the provider's reset time has passed.
  | lifecycle == MissionWaitingCapacity,
    Just (MissionCapacityDue _) <- wake =
      Nothing
  -- Read off the record rather than off the lifecycle, because
  -- @waiting_input@ is written for several reasons and only one of them is
  -- indeterminate: a mission waiting for an answer to a question is not the
  -- same stop as one waiting to be told what became of an effect it may
  -- already have had.
  --
  -- And read off /both/ halves of that record. A plan step's unknown outcome
  -- is written on its step; the two effects with no step record of their own —
  -- a registered child and a subtree termination — have nowhere to write it
  -- but their own invocation, so a run that consulted the steps alone would
  -- exit zero over exactly the effects nobody can account for.
  -- Only a step's unknown outcome reaches here: an invocation's was answered
  -- above, whatever this lifecycle says.
  | missionLifecycleBlocks lifecycle, unknownStep = Just (MissionHaltIndeterminate lifecycle blockedDetail)
  | missionLifecycleBlocks lifecycle = Just (MissionHaltBlocked lifecycle blockedDetail)
  | otherwise = Nothing
  where
    lifecycle = snapshot.missionSnapshotLifecycle
    wake = (`missionCapacityWake` snapshot) <$> clock
    unknownStep = any ((== MissionStepOutcomeUnknown) . (.missionStepRecordLifecycle)) snapshot.missionSnapshotSteps
    unknownInvocation = any unknownOutcome states
    unknownOutcome state = case state.missionInvocationOutcome of
      Just (MissionInvocationUnknown _) -> True
      _ -> False
    -- The blocked sentence where there is one, because a mission that /is/
    -- stopped for an answer is best described as stopped for an answer; the
    -- indeterminacy is carried by the halt's own kind and by
    -- 'missionHaltMessage'. Only a lifecycle with no such sentence — one still
    -- advancing, or one already called terminal — needs this to say what
    -- stopped the run.
    unaccountedDetail
      | missionLifecycleBlocks lifecycle = blockedDetail
      | otherwise = "an effect it may have had is recorded as unaccounted for"
    blockedDetail = case lifecycle of
      MissionWaitingInput -> "it is waiting for an answer this runner cannot supply"
      MissionWaitingBarrier -> "it is waiting on a barrier outside this runner"
      MissionWaitingCapacity -> maybe "it is waiting for provider capacity" missionCapacityWakeMessage wake
      MissionPaused -> "it is paused and only an explicit resume restarts it"
      MissionInterrupted -> "it was interrupted and needs an explicit recovery decision"
      _ -> "it cannot be advanced from here"

-- ---------------------------------------------------------------------------
-- Provider-capacity waits
-- ---------------------------------------------------------------------------

-- | How long the @n@th consecutive capacity wait of one step backs off when
-- the provider named no reset time (design D-18): one minute, doubling with
-- every wait in a row, never more than 'missionCapacityBackoffCap'.
missionCapacityBackoff :: Int -> NominalDiffTime
missionCapacityBackoff consecutive = min missionCapacityBackoffCap (60 * 2 ^ (max 1 (min 16 consecutive) - 1))

-- | The longest a backoff waits: one hour.
missionCapacityBackoffCap :: NominalDiffTime
missionCapacityBackoffCap = 60 * 60

-- | The wait one failed attempt records.
--
-- Computed once, at the moment the failure is recorded, and never again. The
-- count continues the step's standing wait when it has one — the attempt that
-- just failed was the retry of that wait — and starts at one otherwise. The
-- retry time is the provider's own reset when it named one, even one already
-- past (which is due at once), and the backoff for this count when it did not.
--
-- A wait already recorded /for this very session/ is returned unchanged. That
-- is the same failure read a second time — by a pass that repeated, or a
-- runner that restarted before the step moved on — and neither the count nor
-- the deadline may move for it.
missionCapacityWaitFor :: UTCTime -> Maybe MissionCapacityWait -> MissionSessionId -> Maybe UTCTime -> Text -> MissionCapacityWait
missionCapacityWaitFor now standing session resetsAt detail = case standing of
  Just recorded
    | recorded.missionCapacitySession == Just session -> recorded
  _ ->
    MissionCapacityWait
      { missionCapacityRetryAt = MissionCapacityRetryAt (maybe (addUTCTime (missionCapacityBackoff consecutive) now) id resetsAt),
        missionCapacityConsecutive = consecutive,
        missionCapacityRecordedAt = now,
        missionCapacitySession = Just session,
        missionCapacityDetail = detail
      }
  where
    consecutive = maybe 1 ((+ 1) . (.missionCapacityConsecutive)) standing

-- | What a mission's capacity waits say at one moment.
data MissionCapacityWake
  = -- | No step is waiting for capacity.
    MissionCapacityIdle
  | -- | This step's wait has ended: it may be woken and dispatched again.
    MissionCapacityDue MissionStepId
  | -- | Every wait is still in force; the earliest ends then.
    MissionCapacityWaiting MissionStepId UTCTime
  | -- | This step is waiting and nothing records when it may retry, so it is
    -- never retried automatically.
    MissionCapacityUnreadable MissionStepId Text
  deriving stock (Eq, Show)

-- | The one reading of a mission's capacity waits, shared by the scheduler's
-- admission and the controller's own advancement so the two can never
-- disagree about whether a wait has ended.
--
-- A due wait wins, in plan order: one step's wait ending is reason enough to
-- advance the mission, and a peer whose retry time cannot be read stays
-- waiting beside it rather than holding it back. Only when nothing is due is
-- an unreadable wait the answer, because then it is the reason the mission is
-- not moving; and only when every wait is readable and in force is the
-- earliest retry time.
missionCapacityWake :: UTCTime -> MissionSnapshot -> MissionCapacityWake
missionCapacityWake now snapshot =
  case [(record.missionStepRecordId, retryOf record) | record <- snapshot.missionSnapshotSteps, record.missionStepRecordLifecycle == MissionStepWaitingCapacity] of
    [] -> MissionCapacityIdle
    waits -> case [step | (step, Right at) <- waits, at <= now] of
      (step : _) -> MissionCapacityDue step
      [] -> case [(step, reason) | (step, Left reason) <- waits] of
        ((step, reason) : _) -> MissionCapacityUnreadable step reason
        [] -> case [(at, step) | (step, Right at) <- waits] of
          pending@(_ : _) -> let (at, step) = minimum pending in MissionCapacityWaiting step at
          [] -> MissionCapacityIdle

-- | Every waiting step whose retry time cannot be read, with why.
--
-- Asked of each step on its own rather than read off 'missionCapacityWake',
-- which answers one question about the whole mission and lets a due peer
-- speak for it: a mission with one due wait and one undated one wakes the due
-- step and is running again, and the undated wait beside it is still one
-- nothing will ever retry.
missionUndatedCapacityWaits :: MissionSnapshot -> [(MissionStepId, Text)]
missionUndatedCapacityWaits snapshot =
  [ (record.missionStepRecordId, reason)
  | record <- snapshot.missionSnapshotSteps,
    record.missionStepRecordLifecycle == MissionStepWaitingCapacity,
    Left reason <- [retryOf record]
  ]

retryOf :: MissionStepRecord -> Either Text UTCTime
retryOf record = case record.missionStepRecordCapacity of
  Nothing -> Left "no retry time was recorded"
  Just wait -> case wait.missionCapacityRetryAt of
    MissionCapacityRetryAt at -> Right at
    MissionCapacityRetryUnreadable _ -> Left "its recorded retry time will not decode"

-- | What a capacity reading says, as a halt's sentence.
missionCapacityWakeMessage :: MissionCapacityWake -> Text
missionCapacityWakeMessage wake = case wake of
  MissionCapacityIdle -> "it is waiting for provider capacity"
  MissionCapacityDue step -> "step " <> step.unMissionStepId <> "'s provider-capacity wait has ended"
  MissionCapacityWaiting step at ->
    "it is waiting for provider capacity; step " <> step.unMissionStepId <> " retries at " <> Text.pack (iso8601Show at)
  MissionCapacityUnreadable step reason ->
    "it is waiting for provider capacity and step "
      <> step.unMissionStepId
      <> " is not retried automatically: "
      <> reason

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
--
-- An interrupted step comes next and outranks every ordinary wait. It is the
-- one blocked state no answer, capacity, or barrier ends: only the operator's
-- @override@ does (D-3), so a mission holding one is reported as interrupted
-- whatever else it is also waiting for, and the scheduler stops admitting it.
blockedMissionLifecycle :: MissionSnapshot -> Maybe (MissionLifecycle, Text)
blockedMissionLifecycle snapshot
  | has MissionStepOutcomeUnknown =
      Just (MissionWaitingInput, "a step's outcome is unknown and only direction or fresh evidence resolves it")
  | has MissionStepInterrupted = Just (MissionInterrupted, "a step was interrupted")
  | has MissionStepOrphaned = Just (MissionInterrupted, "a step's processes were orphaned")
  | has MissionStepNeedsInput = Just (MissionWaitingInput, "a step is waiting for an answer")
  | has MissionStepNeedsChanges = Just (MissionWaitingInput, "a step came back with changes requested")
  | has MissionStepWaitingCapacity = Just (MissionWaitingCapacity, "a step is waiting for provider capacity")
  | otherwise = Nothing
  where
    has lifecycle = lifecycle `elem` map (.missionStepRecordLifecycle) snapshot.missionSnapshotSteps

-- | The first step cut off mid-flight, if the mission holds one.
--
-- Asked before anything else a controller would do next, and answered with
-- the mission's own @interrupted@ lifecycle. D-3 stops the mission for the
-- operator the moment one step is interrupted, rather than when nothing else
-- is left to dispatch: a mission that went on launching its other steps beside
-- a launch nobody can account for would be doing more of exactly what the
-- operator has been asked to look at. It is also what closes the window
-- between the two writes: a step recorded @interrupted@ beside a lifecycle
-- still reading @running@ is found here by whichever run comes next.
missionInterruptedStep :: MissionSnapshot -> Maybe MissionStepId
missionInterruptedStep snapshot =
  case [ record.missionStepRecordId
       | record <- snapshot.missionSnapshotSteps,
         record.missionStepRecordLifecycle == MissionStepInterrupted
       ] of
    (step : _) -> Just step
    [] -> Nothing

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

-- | A launch that is still open, with the lineage its repair needs.
--
-- The durable states a crash around a launch can leave. A crash before the
-- @dispatching@ write leaves a step that still reads @pending@, which
-- 'nextDispatchableStep' would hand straight back to a dispatch — repeating an
-- effect that may already have happened, the one thing requirement 7 forbids
-- outright. A crash after the driver returned and before the invocation was
-- concluded leaves a step reading @dispatching@ beside a worker the mission
-- started and has not recorded, which the ordinary evidence pass would
-- classify as somebody else's live work and pause on. And a registered
-- child's launch leaves neither, because a child has no step record at all:
-- its whole existence is the invocation and the session write that was about
-- to follow it.
--
-- None of the three is distinguishable from a launch that never happened by
-- looking at the step records; only the invocation file is. A live run never
-- sees any of them, because between the two writes the controller never
-- yields.
unresolvedDispatchOf :: [MissionInvocationState] -> MissionSpecification -> MissionSnapshot -> Maybe MissionOpenDispatch
unresolvedDispatchOf states specification snapshot =
  case filter open (plannedDispatches <> childDispatches) of
    (found : _) -> Just found
    [] -> Nothing
  where
    open dispatch = not (missionInvocationResolved dispatch.missionOpenDispatchState)
    plannedDispatches =
      [ openDispatchOf state
      | step <- specification.missionSpecificationPlan,
        lifecycleOf step.missionPlanStepId `elem` [Just MissionStepPending, Just MissionStepDispatching],
        state <- states,
        isDispatch state,
        state.missionInvocationRecord.missionInvocationStep == step.missionPlanStepId
      ]
    -- The same window around a registered child's launch, which the plan walk
    -- above cannot see: a child's step is invented from the request and is in
    -- no plan, and nothing writes a step record for it, so the invocation file
    -- is the only place its launch is described at all. Recognized by the
    -- lineage the launch recorded, so an ordinary dispatch is never swept in
    -- here and a child is never missed for want of a plan entry.
    childDispatches =
      [ openDispatchOf state
      | state <- states,
        isDispatch state,
        Just _ <- [state.missionInvocationRecord.missionInvocationParent],
        missionStepRecordFor state.missionInvocationRecord.missionInvocationStep snapshot == Nothing
      ]
    isDispatch state = case state.missionInvocationRecord.missionInvocationEffect of
      MissionEffectDispatch _ -> True
      MissionEffectTerminateSubtree _ -> False
    openDispatchOf state =
      MissionOpenDispatch
        { missionOpenDispatchStep = state.missionInvocationRecord.missionInvocationStep,
          missionOpenDispatchInvocation = state.missionInvocationRecord.missionInvocationId,
          missionOpenDispatchParent = MissionSessionId <$> state.missionInvocationRecord.missionInvocationParent,
          missionOpenDispatchState = state
        }
    lifecycleOf step = (.missionStepRecordLifecycle) <$> missionStepRecordFor step snapshot

-- | One launch this store never saw the end of, with the lineage its repair
-- needs.
data MissionOpenDispatch = MissionOpenDispatch
  { missionOpenDispatchStep :: MissionStepId,
    missionOpenDispatchInvocation :: MissionInvocationId,
    -- | The parent to register a recovered child under. 'Nothing' for a plan
    -- step, which is nobody's child.
    missionOpenDispatchParent :: Maybe MissionSessionId,
    missionOpenDispatchState :: MissionInvocationState
  }
  deriving stock (Eq, Show)

-- | Whether this open launch is a registered child's rather than a plan
-- step's, which decides where its unknown outcome can be written down.
missionOpenDispatchIsChild :: MissionSnapshot -> MissionOpenDispatch -> Bool
missionOpenDispatchIsChild snapshot dispatch =
  missionStepRecordFor dispatch.missionOpenDispatchStep snapshot == Nothing

-- | A subtree termination this store never saw the end of.
--
-- The other half of the same crash window, and the more dangerous half: the
-- signal may already have been delivered. Nothing here decides that it was —
-- the caller reconciles it from what the registered sessions can be observed
-- to be doing now, and requires authenticated direction when that evidence
-- settles nothing. What this must never do is let the effect be repeated on
-- the strength of the record, which is why an unresolved termination is
-- reported rather than left for the ordinary command path to reissue.
unresolvedTerminationOf :: [MissionInvocationState] -> Maybe (MissionInvocationId, MissionSessionId)
unresolvedTerminationOf states =
  case [ (state.missionInvocationRecord.missionInvocationId, MissionSessionId session)
       | state <- states,
         not (missionInvocationResolved state),
         MissionEffectTerminateSubtree session <- [state.missionInvocationRecord.missionInvocationEffect]
       ] of
    (found : _) -> Just found
    [] -> Nothing

-- | A launch whose invocation records a dispatched worker the session tree
-- does not hold.
--
-- The other crash window: the driver returned, the worker is running, the
-- invocation was closed with its identity — and the snapshot write that would
-- have registered the session never happened. Without this the next run reads
-- a step with no sessions, finds a live worker it cannot account for, and
-- pauses the mission for work it started itself.
--
-- Registration is judged by the session tree rather than by the step record\'s
-- own list of identifiers, and that is what makes this cover a registered
-- child as well as a plan step. One snapshot write makes both entries, so for
-- a plan step the two questions have the same answer; for a child there is no
-- step record to ask at all, and the tree is the only place its registration
-- was ever going to live. The parent travels back with it for the same
-- reason: a child put back without its lineage is a session no termination
-- reaches and no parent waits for, which is the accounting hole the
-- registration existed to close.
--
-- The conclusion is the durable association the repair is built from, which is
-- why it is written before the snapshot rather than after.
dispatchedButUnregistered :: [MissionInvocationState] -> MissionSnapshot -> Maybe (MissionStepId, MissionSessionId, Maybe MissionSessionId)
dispatchedButUnregistered states snapshot =
  case [ ( record.missionInvocationStep,
           MissionSessionId worker,
           MissionSessionId <$> record.missionInvocationParent
         )
       | state <- states,
         Just (MissionInvocationDispatched worker) <- [state.missionInvocationOutcome],
         let record = state.missionInvocationRecord,
         stepIsOpen record.missionInvocationStep,
         not (registered (MissionSessionId worker))
       ] of
    (found : _) -> Just found
    [] -> Nothing
  where
    registered identity = any ((== identity) . (.missionSessionId)) snapshot.missionSnapshotSessions
    -- A child has no step record, and its absence is not a terminal step: it
    -- is the record that was never going to exist.
    stepIsOpen step = case missionStepRecordFor step snapshot of
      Nothing -> True
      Just record -> not (missionStepLifecycleIsTerminal record.missionStepRecordLifecycle)

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
stepHasUnsettledDescendants snapshot step = any unsettled (stepDescendants snapshot step)
  where
    unsettled node = missionSessionDisposition node /= MissionSessionSettled

-- | A registered child this step's own evidence pass /looked at/ and could not
-- establish the end of.
--
-- The difference between this and 'stepHasUnsettledDescendants' is the
-- difference between waiting and being stuck, and it is the recorded
-- observation that tells them apart. A child with no observation yet has
-- simply not been seen to end: it may be running, its parent waits for it, and
-- that wait is bounded by the child's own recorded deadline. A child carrying
-- an observation whose outcome is 'MissionObservedUnknown' is one the pass
-- asked about and could not answer for — its record was collected, or its
-- action could not be judged — and no further evidence is coming. A parent
-- left waiting on that waits for ever, which in a foreground runner is not a
-- safeguard but a process that never ends.
--
-- Naming it is what lets the step reach @outcome_unknown@ instead, which is
-- the lifecycle requirement 7 gives to exactly this: something happened,
-- nothing can say what, and only direction or fresh evidence resolves it.
stepUnverifiableDescendant :: MissionSnapshot -> MissionStepId -> Maybe MissionSessionId
stepUnverifiableDescendant snapshot step =
  case [ node.missionSessionId
       | node <- stepDescendants snapshot step,
         Just observation <- [node.missionSessionObservation],
         observation.missionObservationOutcome == MissionObservedUnknown
       ] of
    (found : _) -> Just found
    [] -> Nothing

-- | Every registered descendant of a step, its own root sessions excluded.
stepDescendants :: MissionSnapshot -> MissionStepId -> [MissionSessionNode]
stepDescendants snapshot step = concatMap descendants roots
  where
    roots = [node.missionSessionId | node <- snapshot.missionSnapshotSessions, node.missionSessionStep == Just step]
    descendants root = drop 1 (missionSessionSubtree snapshot root)

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
