{-# LANGUAGE DerivingStrategies #-}

-- | The workflow action registry's closed vocabularies: what can be asked
-- for, what a target resolves to, why a request is refused, what a dispatch
-- leaves behind, and what observing it reports.
--
-- Everything here is a type and a total function over one. No value in this
-- module names an @AppState@, an @EventM@, or a Brick event channel, which is
-- what lets the dashboard and a headless mission runner ask the same
-- questions of the same registry (issue #593, SAG-2).
--
-- Two of the vocabularies are worth reading before the rest.
--
-- 'WorkflowActionKind' is a closed sum of exactly eight constructors, so a
-- ninth kind is a compile error rather than a runtime surprise. That closure
-- means an "unknown action kind" is unrepresentable /in-language/: it exists
-- only where a kind arrives as data, which today is a mission plan step's
-- @missionPlanStepAction@ name (issue #592). 'decodeWorkflowActionKind' is
-- that boundary and the only place the rejection can be asserted.
--
-- 'ActionRefusal' is closed for the same reason. A request that cannot run is
-- refused with a named reason rather than a sentence, so a caller can act on
-- the distinction between "that number is another repository's", "that number
-- names a pull request and you used an issue verb", and "that number could not
-- be resolved by the read this registry actually made".
module Kanban.Action.Types
  ( -- * Action kinds
    WorkflowActionKind (..),
    workflowActionKinds,
    workflowActionKindTag,
    workflowActionKindTitle,
    workflowActionTargetKind,

    -- * The decode boundary
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

    -- * Resolved targets
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

    -- * Handles
    ActionAttribution (..),
    ActionHandle (..),
    actionHandleKind,
    actionHandleWorker,

    -- * Observations
    ActionOutcome (..),
    actionOutcomeSucceeded,
    actionOutcomeMessage,
    ActionObservation (..),
    ApprovalQueueObservation (..),
    approvalQueueObservationMessage,
  )
where

import Data.Char (isDigit)
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime)
import Kanban.ApprovalService
  ( ApprovalIncident,
    ApprovalStatus (..),
    ApprovalUnavailable,
    approvalUnavailableMessage,
  )
import Kanban.Domain (BoardItem (..), Issue (..), PullRequest (..), Repository)
import Kanban.PullRequestFlow (PullRequestVerdict (..))
import Kanban.Solve (SolverBrand)
import Kanban.Worker (WorkerDescriptor)
import Kanban.Workflow (readOnlyHistoryNotice)

-- ---------------------------------------------------------------------------
-- Action kinds
-- ---------------------------------------------------------------------------

-- | Every action the registry can be asked for, and no others.
--
-- Eight rather than seven because pull-request repair is a distinct action
-- owned by the @$repair@ authority, not a flavour of revision: the two run
-- different workflows and are selected by different rules
-- ('Kanban.PullRequestFlow.directPullRequestAction' selects repair only for an
-- approved Done pull request reporting a problem).
--
-- 'ReviewIssue' and 'ReviseIssue' are declared here — target type, capability
-- query, dispatch vocabulary and owning authority alike — but no runner owns
-- them yet. Dispatching either returns 'ActionNotRunnerOwned' rather than
-- reaching a lifecycle that only exists inside the dashboard; SAG-10 supplies
-- those two runners.
data WorkflowActionKind
  = ReviewIssue
  | ReviseIssue
  | SolveIssue
  | AutoSolveIssue
  | ReviewPullRequest
  | RevisePullRequest
  | RepairPullRequest
  | ObserveApprovalQueue
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- | Every registered kind, in declaration order.
workflowActionKinds :: [WorkflowActionKind]
workflowActionKinds = [minBound .. maxBound]

-- | The name a durable record spells a kind with. This is the wire form
-- 'decodeWorkflowActionKind' accepts, so changing one changes both.
workflowActionKindTag :: WorkflowActionKind -> Text
workflowActionKindTag kind = case kind of
  ReviewIssue -> "review_issue"
  ReviseIssue -> "revise_issue"
  SolveIssue -> "solve_issue"
  AutoSolveIssue -> "autosolve_issue"
  ReviewPullRequest -> "review_pull_request"
  RevisePullRequest -> "revise_pull_request"
  RepairPullRequest -> "repair_pull_request"
  ObserveApprovalQueue -> "observe_approval_queue"

-- | How a kind is named in a diagnostic a person reads.
workflowActionKindTitle :: WorkflowActionKind -> Text
workflowActionKindTitle kind = case kind of
  ReviewIssue -> "Review issue"
  ReviseIssue -> "Revise issue"
  SolveIssue -> "Solve issue"
  AutoSolveIssue -> "Autosolve issue"
  ReviewPullRequest -> "Review pull request"
  RevisePullRequest -> "Revise pull request"
  RepairPullRequest -> "Repair pull request"
  ObserveApprovalQueue -> "Observe approval queue"

-- | The kind of target a verb acts on, or 'Nothing' for the one action whose
-- target is the repository itself.
workflowActionTargetKind :: WorkflowActionKind -> Maybe ActionTargetKind
workflowActionTargetKind kind = case kind of
  ReviewIssue -> Just ActionTargetIssue
  ReviseIssue -> Just ActionTargetIssue
  SolveIssue -> Just ActionTargetIssue
  AutoSolveIssue -> Just ActionTargetIssue
  ReviewPullRequest -> Just ActionTargetPullRequest
  RevisePullRequest -> Just ActionTargetPullRequest
  RepairPullRequest -> Just ActionTargetPullRequest
  ObserveApprovalQueue -> Nothing

-- | The only way an unregistered action kind can be named at all.
--
-- 'WorkflowActionKind' is closed, so a caller holding one holds a registered
-- kind by construction. A name arriving as data — a mission plan step's
-- action, an external request — is not, and this is where that name is either
-- resolved or refused. Nothing downstream of a successful decode has to check
-- again.
newtype ActionKindDecodeError = UnknownWorkflowActionKind Text
  deriving stock (Eq, Show)

actionKindDecodeErrorMessage :: ActionKindDecodeError -> Text
actionKindDecodeErrorMessage (UnknownWorkflowActionKind name) =
  "unknown workflow action kind " <> quoted name <> "; the registry declares " <> declared
  where
    declared = Text.intercalate ", " (map workflowActionKindTag workflowActionKinds)

-- | Resolve a recorded action name. Case and surrounding space are not
-- significant; anything else is refused rather than guessed at.
decodeWorkflowActionKind :: Text -> Either ActionKindDecodeError WorkflowActionKind
decodeWorkflowActionKind name =
  case [kind | kind <- workflowActionKinds, workflowActionKindTag kind == normalized] of
    kind : _ -> Right kind
    [] -> Left (UnknownWorkflowActionKind name)
  where
    normalized = Text.toLower (Text.strip name)

-- ---------------------------------------------------------------------------
-- Targets
-- ---------------------------------------------------------------------------

data ActionTargetKind = ActionTargetIssue | ActionTargetPullRequest
  deriving stock (Bounded, Enum, Eq, Ord, Show)

actionTargetKindTag :: ActionTargetKind -> Text
actionTargetKindTag ActionTargetIssue = "issue"
actionTargetKindTag ActionTargetPullRequest = "pr"

-- | How a caller names what to act on.
--
-- GitHub gives issues and pull requests one number space, so an unqualified
-- number resolves authoritatively to whichever of the two it actually names —
-- and a verb that wanted the other kind is refused rather than pointed at the
-- wrong record. The explicit forms exist for clarity and for recovery from a
-- stale board: a caller who knows the number is a pull request can say so and
-- get a kind mismatch instead of silently acting on an issue a cached read
-- still shows under that number.
data ActionTargetRef
  = TargetByNumber Int
  | TargetByKind ActionTargetKind Int
  | TargetRepositoryWide
  deriving stock (Eq, Show)

actionTargetRefNumber :: ActionTargetRef -> Maybe Int
actionTargetRefNumber (TargetByNumber number) = Just number
actionTargetRefNumber (TargetByKind _ number) = Just number
actionTargetRefNumber TargetRepositoryWide = Nothing

actionTargetRefText :: ActionTargetRef -> Text
actionTargetRefText (TargetByNumber number) = "#" <> showNumber number
actionTargetRefText (TargetByKind kind number) = actionTargetKindTag kind <> " #" <> showNumber number
actionTargetRefText TargetRepositoryWide = "this repository"

-- | Parse the target forms a request may carry: @123@, @#123@, @issue 123@,
-- @pr 123@, and @repository@ for the one action whose target is not an item.
parseActionTargetRef :: Text -> Either Text ActionTargetRef
parseActionTargetRef raw = case Text.words (Text.toLower (Text.strip raw)) of
  ["repository"] -> Right TargetRepositoryWide
  [single] -> TargetByNumber <$> number single
  [qualifier, value] -> do
    kind <- targetKind qualifier
    TargetByKind kind <$> number value
  _ -> Left ("cannot read " <> quoted raw <> " as a target")
  where
    targetKind "issue" = Right ActionTargetIssue
    targetKind "pr" = Right ActionTargetPullRequest
    targetKind other = Left ("unknown target qualifier " <> quoted other)
    number value =
      let digits = Text.dropWhile (== '#') value
       in if not (Text.null digits) && Text.all isDigit digits
            then Right (read (Text.unpack digits))
            else Left ("cannot read " <> quoted value <> " as a target number")

-- ---------------------------------------------------------------------------
-- Resolved targets
-- ---------------------------------------------------------------------------

-- | Whether the target is still live work, from the record itself and from
-- whatever completed generation the read covered.
data TargetLifecycle
  = TargetOpen
  | TargetSettled
  deriving stock (Eq, Show)

-- | How far the read behind a resolution reached into completed work.
--
-- Carried on the resolved record rather than inferred, because "this target is
-- not historical" and "this read cannot say whether it is historical" are
-- different answers and only the first may be acted on as a clearance. A
-- number that is absent from the open read is never resolved at all when the
-- reach is 'HistoryAbsent' — it is refused as 'ActionTargetUnresolved', which
-- is the fail-closed half of the same distinction.
data HistoryReach
  = HistoryConfirmed
  | HistoryAbsent
  deriving stock (Eq, Show)

data TrackerChildren
  = TrackerHasChildren
  | TrackerChildless
  deriving stock (Eq, Show)

-- | The verb-relevant structure of a target.
--
-- Structural classification is a fact about the tracker hierarchy — is this
-- issue a tracker, and does it have children — and not about how a dashboard
-- happens to be displaying it. Whether a tracker's group is /collapsed/ is a
-- property of one dashboard's expansion set, so it is supplied at the call
-- site by the adapter that knows it and never returned to a headless caller
-- naming an issue by number.
data TargetStructure
  = TargetPlain
  | TargetTracker TrackerChildren
  deriving stock (Eq, Show)

-- | One target, resolved against a named read.
--
-- The canonical repository identity is carried rather than assumed: neither
-- 'Issue' nor 'PullRequest' holds one, so without it a resolved record could
-- not be checked against the repository a later caller means, and repository
-- mismatch would stop being detectable the moment resolution finished.
data ResolvedTarget = ResolvedTarget
  { resolvedTargetRepository :: Text,
    resolvedTargetKind :: ActionTargetKind,
    resolvedTargetNumber :: Int,
    resolvedTargetLifecycle :: TargetLifecycle,
    resolvedTargetHistoryReach :: HistoryReach,
    resolvedTargetStructure :: TargetStructure,
    resolvedTargetItem :: BoardItem
  }
  deriving stock (Eq, Show)

resolvedTargetIssue :: ResolvedTarget -> Maybe Issue
resolvedTargetIssue target = case target.resolvedTargetItem of
  IssueItem issue -> Just issue
  PullRequestItem _ -> Nothing

resolvedTargetPullRequest :: ResolvedTarget -> Maybe PullRequest
resolvedTargetPullRequest target = case target.resolvedTargetItem of
  PullRequestItem pullRequest -> Just pullRequest
  IssueItem _ -> Nothing

-- | What a request resolved to: one item, or the repository itself for the
-- action that observes a queue rather than a card.
data ActionTarget
  = ActionTargetItem ResolvedTarget
  | ActionTargetRepositoryWide Repository
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Refusals
-- ---------------------------------------------------------------------------

-- | Why a verb that rejects structure refuses this target.
data StructuralRefusal
  = -- | A tracker with no children to review: structure rather than
    -- reviewable work, carrying no Requirements or Acceptance for the
    -- canonical gate to read.
    StructuralTrackerHeader
  | -- | A collapsed tracker group. Supplied by a dashboard adapter, never
    -- derived here: "collapsed" is not a property a headless caller's number
    -- has.
    StructuralCollapsedGroup
  deriving stock (Eq, Show)

structuralRefusalMessage :: StructuralRefusal -> Text
structuralRefusalMessage StructuralTrackerHeader =
  "an epic is structure rather than reviewable work; select one of its children"
structuralRefusalMessage StructuralCollapsedGroup =
  "expand the epic and select one of its children"

-- | Every reason a request is refused before anything is dispatched.
data ActionRefusal
  = -- | The read covered this number and it names nothing.
    ActionTargetNotFound ActionTargetRef
  | -- | The read cannot answer for this number, which is not the same as its
    -- absence. Refusing rather than dispatching is the point: a closed or
    -- merged target and a nonexistent one look identical to a read that never
    -- covered completed work.
    ActionTargetUnresolved ActionTargetRef Text
  | -- | The request names one repository and the resolution was made against
    -- another. Requested first, resolved second.
    ActionRepositoryMismatch Text Text
  | -- | Read-only history: closed, or merged. Carries the record itself so
    -- the refusal is worded by 'readOnlyHistoryNotice', the one authority for
    -- that sentence, rather than by a second phrasing that could drift from
    -- it.
    ActionTargetHistorical BoardItem
  | ActionTargetStructural StructuralRefusal Int
  | -- | Expected kind, actual kind, number.
    ActionTargetKindMismatch ActionTargetKind ActionTargetKind Int
  | -- | The target exists and is the right kind, but its current state is not
    -- one this verb acts on.
    ActionLifecycleIncompatible WorkflowActionKind Text
  | -- | Declared, but no runner owns it in this slice.
    ActionNotRunnerOwned WorkflowActionKind
  | -- | This verb needs a target and the request named none, or named one for
    -- the verb that takes none.
    ActionTargetMismatchedArity WorkflowActionKind
  | -- | A local dependency this action needs is definitely absent.
    ActionCapabilityBlocked WorkflowActionKind Text
  | -- | The model roster could not supply the cell this launch runs on.
    ActionRoutingUnavailable WorkflowActionKind Text
  | -- | The owning authority refused or could not be started.
    ActionDispatchFailed WorkflowActionKind Text
  deriving stock (Eq, Show)

actionRefusalMessage :: ActionRefusal -> Text
actionRefusalMessage refusal = case refusal of
  ActionTargetNotFound ref -> actionTargetRefText ref <> " does not exist in this repository"
  ActionTargetUnresolved ref detail -> actionTargetRefText ref <> " could not be resolved: " <> detail
  ActionRepositoryMismatch requested resolved ->
    "this request names " <> requested <> " but the read was made against " <> resolved
  ActionTargetHistorical item -> readOnlyHistoryNotice item
  ActionTargetStructural reason number ->
    "#" <> showNumber number <> ": " <> structuralRefusalMessage reason
  ActionTargetKindMismatch expected actual number ->
    "#"
      <> showNumber number
      <> " is "
      <> article actual
      <> " and this action acts on "
      <> article expected
  ActionLifecycleIncompatible kind detail ->
    workflowActionKindTitle kind <> " does not apply here: " <> detail
  ActionNotRunnerOwned kind ->
    workflowActionKindTitle kind <> " is declared but has no runner yet"
  ActionTargetMismatchedArity kind ->
    workflowActionKindTitle kind <> " was given the wrong kind of target"
  ActionCapabilityBlocked _ detail -> detail
  -- The last two are reported verbatim. Both are raised at the launch
  -- boundary, where the dashboard has always shown the owning authority's own
  -- sentence -- the roster's unavailability, the supervisor's failure -- and
  -- decorating them here would change what the board says without changing
  -- what happened. The constructor still carries the kind for a caller that
  -- wants to say more.
  ActionRoutingUnavailable _ detail -> detail
  ActionDispatchFailed _ detail -> detail
  where
    article ActionTargetIssue = "an issue"
    article ActionTargetPullRequest = "a pull request"

-- ---------------------------------------------------------------------------
-- Handles
-- ---------------------------------------------------------------------------

-- | The baseline a solve's pull-request attribution is measured against: the
-- pull requests that already existed when the action was dispatched, and when
-- that was.
--
-- Held on the handle rather than recomputed at observation time. "Exactly one
-- /new/ attributable pull request" is only a question the moment the baseline
-- is known, and re-deriving it later from whatever the board holds then would
-- let a pull request opened by someone else in the meantime be reported as
-- this run's result.
data ActionAttribution = ActionAttribution
  { attributionKnownPullRequests :: Set Int,
    attributionStartedAt :: UTCTime,
    -- | Which solver ran, and therefore which @pr-origin@ marker the pull
    -- request this run opened must carry. Recorded rather than re-derived:
    -- the origin a run's pull request is checked against is decided by the
    -- brand that was launched, not by whatever the roster would route today.
    attributionSolverBrand :: SolverBrand
  }
  deriving stock (Eq, Show)

-- | What a dispatch leaves behind for a later observation.
--
-- Every constructor names durable state owned by the action's own authority —
-- a persistent worker's specification, or a repository's approval controller —
-- and never rendered dashboard text.
data ActionHandle
  = -- | One provider turn owned by a persistent worker.
    WorkerActionHandle WorkflowActionKind ResolvedTarget WorkerDescriptor ActionAttribution
  | -- | The complete autosolve loop over one issue. The worker is its current
    -- provider turn; the loop's own progression is advanced by observing it.
    AutoSolveActionHandle ResolvedTarget WorkerDescriptor ActionAttribution
  | -- | The approval queue, which this action only ever reads.
    ApprovalQueueHandle Repository
  deriving stock (Eq, Show)

actionHandleKind :: ActionHandle -> WorkflowActionKind
actionHandleKind (WorkerActionHandle kind _ _ _) = kind
actionHandleKind (AutoSolveActionHandle _ _ _) = AutoSolveIssue
actionHandleKind (ApprovalQueueHandle _) = ObserveApprovalQueue

actionHandleWorker :: ActionHandle -> Maybe WorkerDescriptor
actionHandleWorker (WorkerActionHandle _ _ descriptor _) = Just descriptor
actionHandleWorker (AutoSolveActionHandle _ descriptor _) = Just descriptor
actionHandleWorker (ApprovalQueueHandle _) = Nothing

-- ---------------------------------------------------------------------------
-- Observations
-- ---------------------------------------------------------------------------

-- | A validated terminal result.
--
-- Worker exit success is not one of these. Every success below names the
-- authoritative evidence that was found — the pull request a solve opened, the
-- verdict a review published — and absent, multiple, stale, or conflicting
-- evidence produces 'ActionStopped' or 'ActionFailed' instead of being
-- promoted.
data ActionOutcome
  = -- | A solve opened exactly this pull request.
    ActionPullRequestOpened Int
  | -- | An autosolve loop's bound pull request carries the current approval.
    ActionPullRequestApproved Int
  | -- | A canonical verdict now stands on this pull request.
    ActionPullRequestVerdict Int PullRequestVerdict
  | ActionNeedsInput Text
  | ActionStopped Text
  | ActionFailed Text
  | ActionApprovalQueueReport ApprovalQueueObservation
  deriving stock (Eq, Show)

-- | Whether an outcome is the one its action was asked for. Deliberately
-- narrow: a pending verdict, a missing pull request, and a needs-input halt
-- are all honest results and none of them is success.
actionOutcomeSucceeded :: ActionOutcome -> Bool
actionOutcomeSucceeded outcome = case outcome of
  ActionPullRequestOpened _ -> True
  ActionPullRequestApproved _ -> True
  ActionPullRequestVerdict _ verdict -> verdict /= PullRequestVerdictPending
  ActionNeedsInput _ -> False
  ActionStopped _ -> False
  ActionFailed _ -> False
  ActionApprovalQueueReport _ -> True

actionOutcomeMessage :: ActionOutcome -> Text
actionOutcomeMessage outcome = case outcome of
  ActionPullRequestOpened number -> "opened PR #" <> showNumber number
  ActionPullRequestApproved number -> "PR #" <> showNumber number <> " is approved"
  ActionPullRequestVerdict number verdict -> "PR #" <> showNumber number <> " " <> verdictWord verdict
  ActionNeedsInput detail -> "needs input: " <> detail
  ActionStopped detail -> "stopped: " <> detail
  ActionFailed detail -> "failed: " <> detail
  ActionApprovalQueueReport observation -> approvalQueueObservationMessage observation
  where
    verdictWord PullRequestVerdictApproved = "is approved"
    verdictWord PullRequestVerdictChangesRequested = "has requested changes"
    verdictWord PullRequestVerdictPending = "has no verdict yet"

-- | What one observation of a dispatched action found.
data ActionObservation
  = -- | Still running, with the activity the owning authority last recorded.
    ActionRunning Text
  | ActionSettled ActionOutcome
  deriving stock (Eq, Show)

-- | What observing the approval queue found.
--
-- The controller's own distinctions are preserved rather than flattened: a
-- child failure is not a controller failure, an unsupported host is not a
-- stopped service, and a status that could not be read at all is neither. The
-- full 'ApprovalStatus' is carried so no consumer has to re-derive one.
data ApprovalQueueObservation
  = ApprovalQueueReported ApprovalStatus (Maybe [ApprovalIncident])
  | ApprovalQueueUndiscoverable ApprovalUnavailable
  | ApprovalQueueQueryFailed Text
  deriving stock (Eq, Show)

approvalQueueObservationMessage :: ApprovalQueueObservation -> Text
approvalQueueObservationMessage (ApprovalQueueReported status _) = status.approvalDetail
approvalQueueObservationMessage (ApprovalQueueUndiscoverable unavailable) =
  "issue approval service unavailable: " <> approvalUnavailableMessage unavailable
approvalQueueObservationMessage (ApprovalQueueQueryFailed detail) =
  "issue approval status unavailable: " <> detail

showNumber :: Int -> Text
showNumber = Text.pack . show

quoted :: Text -> Text
quoted value = "\"" <> value <> "\""
