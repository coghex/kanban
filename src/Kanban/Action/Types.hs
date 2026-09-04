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

    -- * Preconditions
    TargetPrecondition (..),
    targetPreconditionFor,
    targetPreconditionForItem,
    targetPreconditionHolds,
    targetPreconditionMessage,
    targetPreconditionNumber,

    -- * Refusals
    checkTargetRepository,
    StructuralRefusal (..),
    structuralRefusalMessage,
    ActionRefusal (..),
    actionRefusalMessage,

    -- * Handles
    ActionAttribution (..),
    AutoSolveCursor (..),
    ActionHandle (..),
    actionHandleKind,
    actionHandleWorker,
    actionHandleRepository,

    -- * The read a resolution is made against
    TargetCatalog (..),
    CatalogHistory (..),
    catalogIdentity,
    catalogHistoryReach,
    catalogFromSnapshot,
    catalogPullRequestNumbers,

    -- * The environment a request is answered against
    ActionEnvironment (..),
    ActionRequest (..),
    actionRequest,

    -- * Observations
    ActionOutcome (..),
    actionOutcomeSucceeded,
    actionOutcomeMessage,
    settledWorkerFailure,
    ActionObservation (..),
    ApprovalQueueObservation (..),
    approvalQueueObservationMessage,
    approvalQueueWasReported,
  )
where

import Data.Char (isDigit)
import Text.Read (readMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime)
import Kanban.ApprovalService
  ( ApprovalIncident,
    ApprovalStatus (..),
    ApprovalUnavailable,
    approvalUnavailableMessage,
  )
import Kanban.Cache (normalizedRepositoryIdentity)
import Kanban.Domain
  ( BoardItem (..),
    CompletedHistory (..),
    Issue (..),
    PullRequest (..),
    RepoSnapshot (..),
    Repository,
    TargetPrecondition (..),
    WorkflowConfig,
    targetPreconditionForItem,
    targetPreconditionHolds,
    targetPreconditionMessage,
    targetPreconditionNumber,
  )
import Kanban.Models (ModelRoster, RecordedAssignment, RosterLoadError)
import Kanban.PullRequestFlow (PullRequestVerdict (..))
import Kanban.Review (ReviewStage (..))
import Kanban.Solve (ResumeProvenance (..), SolverBrand)
import Kanban.Worker (WorkerDeadline, WorkerDescriptor, WorkerParent, workerDeadlineReason)
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
-- All eight are runner-owned. 'ReviewIssue' and 'ReviseIssue' were the last
-- two that were not: they reached a lifecycle held in dashboard memory, and
-- dispatching either returned a typed refusal saying so. SAG-10 replaced that
-- refusal with the repository review host, so both now dispatch to a durable
-- child action exactly as the other six dispatch to a persistent worker.
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
    -- Read through 'Integer' and then bounded, rather than straight into
    -- 'Int'. A digit string longer than a machine word wraps silently, so
    -- @18446744073709551626@ would come back as @10@ and an external request
    -- naming a target that cannot exist would resolve and dispatch against a
    -- real one. Zero is refused with it: GitHub numbers start at one.
    number value =
      let digits = Text.dropWhile (== '#') value
       in if Text.null digits || not (Text.all isDigit digits)
            then Left ("cannot read " <> quoted value <> " as a target number")
            else case readMaybe (Text.unpack digits) :: Maybe Integer of
              Just parsed
                | parsed >= 1 && parsed <= toInteger (maxBound :: Int) -> Right (fromInteger parsed)
              _ -> Left ("target number " <> quoted value <> " is out of range")

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

-- | The precondition a resolved target currently satisfies.
--
-- The record itself is 'Kanban.Domain.TargetPrecondition', because the
-- persistent worker's specification carries one too and neither layer may own
-- a definition the other cannot see. This is only the projection from a
-- resolution, so the caller that plans an effect and the dispatch that
-- enforces it read the same item the same way rather than each extracting its
-- own fields.
targetPreconditionFor :: ResolvedTarget -> TargetPrecondition
targetPreconditionFor = targetPreconditionForItem . (.resolvedTargetItem)

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
  | -- | This verb needs a target and the request named none, or named one for
    -- the verb that takes none.
    ActionTargetMismatchedArity WorkflowActionKind
  | -- | A local dependency this action needs is definitely absent.
    ActionCapabilityBlocked WorkflowActionKind Text
  | -- | The model roster could not supply the cell this launch runs on.
    ActionRoutingUnavailable WorkflowActionKind Text
  | -- | This target's turn is already running, and the worker that owns it
    -- could not be found to join. Distinct from a failed dispatch: nothing
    -- went wrong, and starting a second turn is exactly what must not happen.
    ActionTurnAlreadyRunning WorkflowActionKind Text
  | -- | The owning authority refused or could not be started.
    ActionDispatchFailed WorkflowActionKind Text
  | -- | The request carried an expected target version and the live target no
    -- longer matches it. Recorded first, observed second. Nothing was
    -- dispatched, which is the whole point: a caller that planned against the
    -- first reading gets to replan rather than have its plan carried out
    -- against the second (issue #595, requirement 8).
    ActionTargetStale WorkflowActionKind TargetPrecondition TargetPrecondition
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
  ActionTurnAlreadyRunning _ detail -> detail
  ActionDispatchFailed _ detail -> detail
  ActionTargetStale _ recorded observed -> targetPreconditionMessage recorded observed
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
-- | A dispatched autosolve action's place in its loop, and the one step that
-- advances it.
--
-- Opaque, and carried on the handle rather than named here, because advancing
-- an autosolve action starts provider turns through the very dispatch that
-- returned the handle: the loop is built on top of the dispatch layer, so the
-- step is closed over when the handle is made rather than reached for when it
-- is observed. That is what lets observing an autosolve action /progress/ it
-- to the approval that is its only success, instead of reporting whichever
-- provider turn it happens to be holding.
--
-- The place itself is in memory. What the loop is doing is always recoverable
-- from the worker records, and requirement 18 leaves persistence to the
-- mission store; this is a caller's cursor into a run, not a second record of
-- one.
newtype AutoSolveCursor = AutoSolveCursor
  { advanceAutoSolveCursor :: ActionEnvironment -> IO ActionObservation
  }

data ActionHandle
  = -- | One provider turn owned by a persistent worker.
    WorkerActionHandle WorkflowActionKind ResolvedTarget WorkerDescriptor ActionAttribution
  | -- | One durable issue action owned by the repository's review host.
    --
    -- No attribution: an issue review opens no pull request, so there is no
    -- baseline to measure a new one against. The stage travels instead,
    -- because it is what decides the owning authority — and therefore what
    -- the terminal evidence looks like and what a published result may
    -- claim.
    IssueActionHandle WorkflowActionKind ResolvedTarget ReviewStage WorkerDescriptor
  | -- | The complete autosolve loop over one issue. The worker is the provider
    -- turn it started with; observing the handle advances the loop past it.
    AutoSolveActionHandle ResolvedTarget WorkerDescriptor ActionAttribution AutoSolveCursor
  | -- | The approval queue, which this action only ever reads.
    ApprovalQueueHandle Repository

actionHandleKind :: ActionHandle -> WorkflowActionKind
actionHandleKind (WorkerActionHandle kind _ _ _) = kind
actionHandleKind (IssueActionHandle kind _ _ _) = kind
actionHandleKind (AutoSolveActionHandle _ _ _ _) = AutoSolveIssue
actionHandleKind (ApprovalQueueHandle _) = ObserveApprovalQueue

actionHandleWorker :: ActionHandle -> Maybe WorkerDescriptor
actionHandleWorker (WorkerActionHandle _ _ descriptor _) = Just descriptor
actionHandleWorker (AutoSolveActionHandle _ descriptor _ _) = Just descriptor
actionHandleWorker (IssueActionHandle _ _ _ descriptor) = Just descriptor
actionHandleWorker (ApprovalQueueHandle _) = Nothing

-- | The repository an approval-queue handle observes, and nothing for the two
-- that own a worker. Exists so a caller can recognise the handle it holds
-- without matching a type that carries a closure.
actionHandleRepository :: ActionHandle -> Maybe Repository
actionHandleRepository (ApprovalQueueHandle repository) = Just repository
actionHandleRepository _ = Nothing

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
  | -- | The launch's recorded finite bound elapsed and the watchdog ended the
    -- turn (issue #595, requirement 16).
    --
    -- Its own constructor rather than an 'ActionFailed' carrying a
    -- recognizable sentence, because a controller has to /decide/ differently
    -- about it: a deadline says the work was still going when its budget ran
    -- out, which is neither a refused authority, an absent executable, an
    -- exhausted provider quota, a moved precondition, nor an outcome nobody
    -- observed. Collapsing it into the generic failure is what made a mission
    -- unable to tell "give it longer" from "this cannot work".
    ActionDeadlineExceeded Text
  | ActionFailed Text
  | -- | An issue action ran to completion and its owning authority
    -- published what that authority publishes: for a canonical initial
    -- review or rereview, the verdict @approve_issues.py@ recorded; for an
    -- interactive revision, the specification amendment its
    -- @kanban_github_issue@ tool posted.
    --
    -- The flag is read back off the child's own durable evidence, never
    -- inferred from the worker having exited cleanly. A child that completed
    -- but recorded no published result is 'ActionStopped', because
    -- requirement 6 forbids reporting an indeterminate canonical result as an
    -- approval and a worker's exit code is exactly that.
    ActionIssueReviewed Int ReviewStage Bool
  | ActionApprovalQueueReport ApprovalQueueObservation
  deriving stock (Eq, Show)

-- | Whether an outcome is the one its action was asked for. Deliberately
-- narrow: a pending verdict, a missing pull request, and a needs-input halt
-- are all honest results and none of them is success.
--
-- The queue observation is the one that has to be looked into rather than
-- taken whole. Observing the queue succeeds when the controller reported a
-- status -- whatever that status says, including a failed service, which is a
-- successful observation of a failure. It does not succeed when the
-- controller could not be discovered or its status could not be read: those
-- are indeterminate, and requirement 16 forbids reporting an indeterminate
-- result as success.
actionOutcomeSucceeded :: ActionOutcome -> Bool
actionOutcomeSucceeded outcome = case outcome of
  ActionPullRequestOpened _ -> True
  ActionPullRequestApproved _ -> True
  ActionPullRequestVerdict _ verdict -> verdict /= PullRequestVerdictPending
  ActionNeedsInput _ -> False
  ActionStopped _ -> False
  ActionDeadlineExceeded _ -> False
  ActionFailed _ -> False
  -- A published verdict is a completed review whichever way it went, exactly
  -- as a changes-requested pull-request verdict is. What is /not/ success is
  -- an action that published nothing, and that never reaches this
  -- constructor.
  ActionIssueReviewed _ _ _ -> True
  ActionApprovalQueueReport observation -> approvalQueueWasReported observation

-- | Whether the controller actually answered.
approvalQueueWasReported :: ApprovalQueueObservation -> Bool
approvalQueueWasReported (ApprovalQueueReported _ _) = True
approvalQueueWasReported (ApprovalQueueUndiscoverable _) = False
approvalQueueWasReported (ApprovalQueueQueryFailed _) = False

actionOutcomeMessage :: ActionOutcome -> Text
actionOutcomeMessage outcome = case outcome of
  ActionPullRequestOpened number -> "opened PR #" <> showNumber number
  ActionPullRequestApproved number -> "PR #" <> showNumber number <> " is approved"
  ActionPullRequestVerdict number verdict -> "PR #" <> showNumber number <> " " <> verdictWord verdict
  ActionNeedsInput detail -> "needs input: " <> detail
  ActionStopped detail -> "stopped: " <> detail
  ActionDeadlineExceeded detail -> "deadline: " <> detail
  ActionFailed detail -> "failed: " <> detail
  ActionIssueReviewed number stage approved ->
    "issue #" <> showNumber number <> " " <> issueStageWord stage <> " " <> issueVerdictWord stage approved
  ActionApprovalQueueReport observation -> approvalQueueObservationMessage observation
  where
    issueStageWord InitialReview = "review"
    issueStageWord IssueRereview = "rereview"
    issueStageWord IssueRevision = "revision"
    -- A revision never approves (requirement 6): what it publishes is the
    -- specification amendment and the move to @reviewed:revised@, so it is
    -- reported as published rather than as a verdict it has no authority to
    -- reach.
    issueVerdictWord IssueRevision _ = "published its specification amendment"
    issueVerdictWord _ True = "was approved"
    issueVerdictWord _ False = "requested changes"
    verdictWord PullRequestVerdictApproved = "is approved"
    verdictWord PullRequestVerdictChangesRequested = "has requested changes"
    verdictWord PullRequestVerdictPending = "has no verdict yet"

-- | A settled worker's failure detail, typed.
--
-- One reading, in one place, so the three observation paths that meet a
-- terminal @SolveFailed@ cannot disagree about whether it was a deadline. The
-- sentence compared against is 'Kanban.Worker.workerDeadlineReason' itself —
-- the same constant the watchdog writes — rather than a phrase spelled again
-- here, which is what keeps the two from drifting apart silently.
settledWorkerFailure :: Text -> ActionOutcome
settledWorkerFailure detail
  | detail == workerDeadlineReason = ActionDeadlineExceeded detail
  | otherwise = ActionFailed detail

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

-- ---------------------------------------------------------------------------
-- The catalog
-- ---------------------------------------------------------------------------

-- | Whether the read behind a catalog covered completed work.
--
-- 'CatalogHistoryAbsent' is not an empty history. It is the statement that the
-- completed generation was never read, which is exactly the case a settled
-- target hides in: @Kanban.UI.Filter.settledItem@ answers @Nothing@ both when
-- the target is genuinely live and when nothing was ever loaded to ask.
data CatalogHistory
  = CatalogHistoryLoaded CompletedHistory
  | CatalogHistoryAbsent
  deriving stock (Eq, Show)

-- | One read of a repository, and the reach a resolution against it inherits.
data TargetCatalog = TargetCatalog
  { catalogRepository :: Repository,
    catalogIssues :: [Issue],
    catalogPullRequests :: [PullRequest],
    catalogHistory :: CatalogHistory
  }
  deriving stock (Eq, Show)

-- | The canonical identity every resolved record carries, taken from the one
-- existing definition rather than spelled a second time here: neither 'Issue'
-- nor 'PullRequest' holds a repository, so this is where a resolved target
-- gets one.
catalogIdentity :: TargetCatalog -> Text
catalogIdentity = normalizedRepositoryIdentity . (.catalogRepository)

catalogHistoryReach :: TargetCatalog -> HistoryReach
catalogHistoryReach catalog = case catalog.catalogHistory of
  CatalogHistoryLoaded _ -> HistoryConfirmed
  CatalogHistoryAbsent -> HistoryAbsent

catalogFromSnapshot :: Repository -> RepoSnapshot -> CatalogHistory -> TargetCatalog
catalogFromSnapshot repository snapshot history =
  TargetCatalog
    { catalogRepository = repository,
      catalogIssues = snapshot.snapshotIssues,
      catalogPullRequests = snapshot.snapshotPullRequests,
      catalogHistory = history
    }

-- | Every pull-request number this read covered, which is the baseline a
-- solve's later "exactly one new pull request" attribution is measured
-- against.
catalogPullRequestNumbers :: TargetCatalog -> Set Int
catalogPullRequestNumbers catalog =
  Set.fromList (map (.pullRequestNumber) catalog.catalogPullRequests)

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

-- | Everything a request is answered against that is not the request itself.
--
-- The catalog is an input rather than something fetched here, so one read
-- answers a whole plan's worth of questions and a caller can say exactly how
-- fresh the evidence a terminal result is validated against is. A verdict
-- validated against a stale catalog is a stale verdict, which is why the
-- headless loop refreshes before every observation.
data ActionEnvironment = ActionEnvironment
  { actionRepository :: Repository,
    actionWorkflowConfig :: WorkflowConfig,
    actionConfigPath :: Maybe FilePath,
    actionRoster :: Either RosterLoadError ModelRoster,
    actionCatalog :: TargetCatalog,
    actionNow :: UTCTime,
    -- | The resolved finite bound every worker this environment launches
    -- records in its own specification (issue #595, requirement 15).
    --
    -- Resolved by the caller from configuration and carried here rather than
    -- read at each launch, for the same reason the catalog is: the registry is
    -- the one plain-IO boundary a dashboard and a headless mission runner both
    -- launch through, so a bound resolved once per environment is a bound both
    -- of them provably applied. Recovery never consults it — a worker already
    -- under way is bounded by the value its own 'WorkerSpec' recorded, whatever
    -- the configuration says now.
    actionWorkerDeadline :: WorkerDeadline
  }

-- | One request. 'actionRequest' builds the ordinary shape; the resume fields
-- are for a caller continuing a provider session it already owns.
data ActionRequest = ActionRequest
  { requestKind :: WorkflowActionKind,
    -- | The repository identity the caller means, checked against the one the
    -- catalog was read from.
    requestRepository :: Text,
    requestTarget :: ActionTargetRef,
    -- | The operator's solver choice, for the two issue-side verbs that have
    -- one. Every other brand on this path is derived by existing routing.
    requestSolverBrand :: Maybe SolverBrand,
    -- | A cell a previous worker recorded, replayed unchanged so a roster
    -- edited between two turns of one provider session cannot change what it
    -- runs on (D-7).
    requestRecordedAssignment :: Maybe RecordedAssignment,
    requestExistingSession :: Maybe Text,
    requestExistingLogPath :: Maybe FilePath,
    requestResumeProvenance :: ResumeProvenance,
    requestUserMessage :: Text,
    requestParent :: Maybe WorkerParent,
    -- | The exact target state this request was planned against, when the
    -- caller recorded one. Verified against the environment's own read
    -- immediately before the launch, and 'Nothing' for a caller with no such
    -- record — a dashboard press acts on the item the operator is looking at
    -- and has nothing older to be stale against.
    requestExpectedTarget :: Maybe TargetPrecondition
  }

actionRequest :: WorkflowActionKind -> Text -> ActionTargetRef -> ActionRequest
actionRequest kind repository target =
  ActionRequest
    { requestKind = kind,
      requestRepository = repository,
      requestTarget = target,
      requestSolverBrand = Nothing,
      requestRecordedAssignment = Nothing,
      requestExistingSession = Nothing,
      requestExistingLogPath = Nothing,
      requestResumeProvenance = ResumeAnswer,
      requestUserMessage = "",
      requestParent = Nothing,
      requestExpectedTarget = Nothing
    }

-- | Refuse a target that belongs to a repository other than the one the
-- caller means.
--
-- 'resolveActionTarget' asks this before it looks a number up, and this asks
-- it again of a record the caller resolved itself -- which is the whole reason
-- the identity is carried on the record. Every repository has a #123, so a
-- target resolved against one repository and dispatched with another's
-- environment would spawn a worker on the wrong repository entirely while the
-- record it came from still named the right one.
checkTargetRepository :: Text -> ActionTarget -> Either ActionRefusal ()
checkTargetRepository requested target = case target of
  ActionTargetRepositoryWide repository -> compareWith (normalizedRepositoryIdentity repository)
  ActionTargetItem resolved -> compareWith resolved.resolvedTargetRepository
  where
    normalized = Text.toLower (Text.strip requested)
    compareWith held
      | normalized == held = Right ()
      | otherwise = Left (ActionRepositoryMismatch normalized held)

showNumber :: Int -> Text
showNumber = Text.pack . show

quoted :: Text -> Text
quoted value = "\"" <> value <> "\""
