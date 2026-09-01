{-# LANGUAGE DerivingStrategies #-}

-- | Target resolution and the compatibility rules every registry action is
-- refused by, both stated over explicit records rather than over an
-- @AppState@.
--
-- That is the whole point of this module. The dashboard's predicates —
-- @solveStartDecision@, @readOnlyHistoryRefusal@, @itemReviewRefusal@ — read a
-- handful of facts out of all of @AppState@ and so could only ever answer for
-- work the board happened to be showing. The same rules stated over a
-- 'ResolvedTarget' answer for a target named by number by a headless caller,
-- and the dashboard reaches them through an adapter that supplies the same
-- facts.
--
-- Resolution is made against a named read, the 'TargetCatalog', and how far
-- that read reached is carried forward rather than assumed. GitHub gives
-- issues and pull requests one number space, so a number in the open half
-- resolves authoritatively to whichever kind it names. A number in neither
-- half is a different matter: with the completed generation in hand the
-- registry can say it does not exist, and without it the registry can only say
-- it could not tell a closed or merged target apart from a nonexistent one —
-- which is 'ActionTargetUnresolved', a refusal, never a dispatch.
module Kanban.Action.Target
  ( -- * The read a resolution is made against
    TargetCatalog (..),
    CatalogHistory (..),
    catalogIdentity,
    catalogHistoryReach,
    catalogFromSnapshot,
    catalogPullRequestNumbers,

    -- * Resolution
    resolveActionTarget,
    resolveHeldItem,
    targetStructureForIssue,

    -- * Compatibility rules
    actionCompatibility,
    historicalRefusal,
    settledTargetRefusal,
    structuralActionRefusal,
    structuralRefusalFor,

    -- * Routing the pull-request verbs
    pullRequestActionForKind,
    workflowActionKindForAction,
    workflowActionKindForDirectPress,
    workflowActionKindForLabelledPullRequest,
  )
where

import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Action.Types
import Kanban.Cache (normalizedRepositoryIdentity)
import Kanban.Domain
  ( BoardItem (..),
    CompletedHistory (..),
    Issue (..),
    ItemId (..),
    PullRequest (..),
    RepoSnapshot (..),
    Repository,
    Tracker (..),
    WorkflowConfig,
  )
import Kanban.PullRequestFlow
  ( PullRequestAction (..),
    directPullRequestAction,
    labelPullRequestAction,
  )
import Kanban.Tracker (trackerFromIssue)
import Kanban.Workflow (itemCompleted)

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
-- Resolution
-- ---------------------------------------------------------------------------

-- | Resolve a caller's target reference against one read.
--
-- The repository is checked first and by identity, not by hope: a request
-- naming another repository is refused before its number is looked up at all,
-- because a number means nothing without one and every repository has a #123.
resolveActionTarget :: WorkflowConfig -> TargetCatalog -> Text -> ActionTargetRef -> Either ActionRefusal ActionTarget
resolveActionTarget config catalog requested ref
  | normalizedRequest /= identity = Left (ActionRepositoryMismatch normalizedRequest identity)
  | otherwise = case ref of
      TargetRepositoryWide -> Right (ActionTargetRepositoryWide catalog.catalogRepository)
      TargetByNumber number -> ActionTargetItem <$> lookupNumber number
      TargetByKind kind number -> do
        resolved <- lookupNumber number
        if resolved.resolvedTargetKind == kind
          then Right (ActionTargetItem resolved)
          else Left (ActionTargetKindMismatch kind resolved.resolvedTargetKind number)
  where
    identity = catalogIdentity catalog
    normalizedRequest = Text.toLower (Text.strip requested)

    lookupNumber number = case openItem number of
      Just item -> Right (resolveHeldItem catalog (structureFor item) item)
      Nothing -> case settledItemInHistory catalog number of
        Just item -> Right (resolveHeldItem catalog (structureFor item) item)
        Nothing -> case catalog.catalogHistory of
          CatalogHistoryLoaded _ -> Left (ActionTargetNotFound ref)
          CatalogHistoryAbsent ->
            Left
              ( ActionTargetUnresolved
                  ref
                  "the completed generation was not read, so a closed or merged target cannot be told apart from one that never existed"
              )

    openItem number =
      case find ((== number) . (.issueNumber)) catalog.catalogIssues of
        Just issue -> Just (IssueItem issue)
        Nothing -> PullRequestItem <$> find ((== number) . (.pullRequestNumber)) catalog.catalogPullRequests

    structureFor (IssueItem issue) = targetStructureForIssue config issue
    structureFor (PullRequestItem _) = TargetPlain

-- | The resolved record for an item a caller already holds, with the
-- structural classification that caller's own view supplies.
--
-- The dashboard reaches the rules through this: it holds the 'BoardItem' the
-- press was made on and knows, from its visible board, whether the issue is
-- being drawn as a childless epic header — a fact about that view rather than
-- about the tracker, and one a number alone does not have.
resolveHeldItem :: TargetCatalog -> TargetStructure -> BoardItem -> ResolvedTarget
resolveHeldItem catalog structure item =
  ResolvedTarget
    { resolvedTargetRepository = catalogIdentity catalog,
      resolvedTargetKind = kindOf item,
      resolvedTargetNumber = numberOf item,
      resolvedTargetLifecycle = lifecycle,
      resolvedTargetHistoryReach = catalogHistoryReach catalog,
      resolvedTargetStructure = structure,
      resolvedTargetItem = settledRecord
    }
  where
    -- The completed generation outranks the held record: an item picked up
    -- while it was live and acted on after a refresh settled it must be
    -- refused by what the newer generation says, and reported with that
    -- generation's own copy of it.
    settledInHistory = settledItemInHistory catalog (numberOf item)
    (lifecycle, settledRecord)
      | itemCompleted item = (TargetSettled, item)
      | Just newer <- settledInHistory = (TargetSettled, newer)
      | otherwise = (TargetOpen, item)

    kindOf (IssueItem _) = ActionTargetIssue
    kindOf (PullRequestItem _) = ActionTargetPullRequest
    numberOf (IssueItem issue) = issue.issueNumber
    numberOf (PullRequestItem pullRequest) = pullRequest.pullRequestNumber

-- | What the completed generation holds under one number, if it holds
-- anything at all.
settledItemInHistory :: TargetCatalog -> Int -> Maybe BoardItem
settledItemInHistory catalog number = case catalog.catalogHistory of
  CatalogHistoryAbsent -> Nothing
  CatalogHistoryLoaded history ->
    case find ((== number) . (.issueNumber)) history.historyIssues of
      Just issue -> Just (IssueItem issue)
      Nothing -> PullRequestItem <$> find ((== number) . (.pullRequestNumber)) history.historyPullRequests

-- | An issue's tracker structure, from the tracker hierarchy itself.
--
-- A headless caller's number carries no view, so this is the only structural
-- fact available to one: is this issue a tracker, and does it have children.
-- The dashboard supplies its own classification instead, because "drawn as a
-- header with no visible children" is a fact about that board.
targetStructureForIssue :: WorkflowConfig -> Issue -> TargetStructure
targetStructureForIssue config issue = case trackerFromIssue config issue of
  Nothing -> TargetPlain
  Just tracker
    | Map.null tracker.trackerChildren -> TargetTracker TrackerChildless
    | otherwise -> TargetTracker TrackerHasChildren

-- ---------------------------------------------------------------------------
-- Compatibility
-- ---------------------------------------------------------------------------

-- | Why this verb must not act on this target, or 'Nothing' when it may.
--
-- The order is the dashboard's and is deliberate. Arity and kind come first
-- because a verb pointed at the wrong sort of thing has nothing to say about
-- its lifecycle; lifecycle outranks structure, because a closed epic is
-- read-only history first and board structure second, and reporting only the
-- second would invite expanding it to look for reviewable work that is not
-- there.
actionCompatibility :: WorkflowConfig -> WorkflowActionKind -> ActionTarget -> Maybe ActionRefusal
actionCompatibility config kind target = case (workflowActionTargetKind kind, target) of
  (Nothing, ActionTargetRepositoryWide _) -> Nothing
  (Nothing, ActionTargetItem _) -> Just (ActionTargetMismatchedArity kind)
  (Just _, ActionTargetRepositoryWide _) -> Just (ActionTargetMismatchedArity kind)
  (Just expected, ActionTargetItem resolved)
    | expected /= resolved.resolvedTargetKind ->
        Just (ActionTargetKindMismatch expected resolved.resolvedTargetKind resolved.resolvedTargetNumber)
    | Just refusal <- historicalRefusal resolved -> Just refusal
    | Just structural <- structuralRefusalFor kind resolved ->
        Just (ActionTargetStructural structural resolved.resolvedTargetNumber)
    | otherwise -> verbCompatibility config kind resolved

-- | The lifecycle half, on its own, for a caller that has already established
-- kind and structure.
historicalRefusal :: ResolvedTarget -> Maybe ActionRefusal
historicalRefusal resolved = case resolved.resolvedTargetLifecycle of
  TargetSettled -> Just (ActionTargetHistorical resolved.resolvedTargetItem)
  TargetOpen -> Nothing

-- | The same refusal for work named only by its number, which is all a
-- launch boundary reached from a session, a worker, or an overlay's resumable
-- turn has to ask with.
--
-- Deliberately silent about a number the read does not cover: this is the
-- narrow "has it settled since?" question, and answering "cannot tell" here
-- would refuse every live launch the moment the completed generation had not
-- been loaded. A caller resolving a number it has /not/ already seen asks
-- 'resolveActionTarget', which refuses that case rather than guessing.
settledTargetRefusal :: TargetCatalog -> ItemId -> Maybe ActionRefusal
settledTargetRefusal catalog target =
  ActionTargetHistorical <$> settledItemInHistory catalog (numberOf target)
  where
    numberOf (IssueId number) = number
    numberOf (PullRequestId number) = number

-- | The structural rule, over a resolved record.
structuralRefusalFor :: WorkflowActionKind -> ResolvedTarget -> Maybe StructuralRefusal
structuralRefusalFor kind resolved = structuralActionRefusal kind resolved.resolvedTargetStructure

-- | Which verbs reject structure, and which deliberately do not.
--
-- Only issue review does. An epic carries no Requirements or Acceptance for
-- the canonical @issue-review:v2@ gate to read, so a review started against
-- one only ever leaves a badge on a header. Solve and autosolve keep acting on
-- the epic issue itself, which is what the @S@ and @A@ keys have always done
-- and what @docs\/design.md@ §7 documents; making the refusal global would
-- change that.
structuralActionRefusal :: WorkflowActionKind -> TargetStructure -> Maybe StructuralRefusal
structuralActionRefusal ReviewIssue (TargetTracker TrackerChildless) = Just StructuralTrackerHeader
structuralActionRefusal _ _ = Nothing

-- | The last refusal: a target of the right kind whose current state is not
-- one this verb acts on.
verbCompatibility :: WorkflowConfig -> WorkflowActionKind -> ResolvedTarget -> Maybe ActionRefusal
verbCompatibility config kind resolved = case resolvedTargetPullRequest resolved of
  Nothing -> Nothing
  Just pullRequest -> either Just (const Nothing) (pullRequestActionForKind config kind pullRequest)

-- ---------------------------------------------------------------------------
-- The pull-request verbs
-- ---------------------------------------------------------------------------

-- | The 'PullRequestAction' one registry verb runs, derived from the existing
-- authorities and never from a table of this module's own.
--
-- Repair is separate from revision on purpose. @$repair@ and @$pr-revise@ are
-- different workflows, and 'directPullRequestAction' is the one rule that
-- selects repair — an approved Done pull request reporting a problem — so
-- asking it here is what keeps the registry's repair verb bound to exactly the
-- pull requests the @r@ key already repairs.
pullRequestActionForKind :: WorkflowConfig -> WorkflowActionKind -> PullRequest -> Either ActionRefusal PullRequestAction
pullRequestActionForKind config kind pullRequest = case kind of
  ReviewPullRequest -> case labelPullRequestAction config pullRequest of
    PullRequestRevision ->
      Left
        ( ActionLifecycleIncompatible
            kind
            "this pull request carries a changes-requested verdict; revise it instead"
        )
    action -> Right action
  RevisePullRequest -> case labelPullRequestAction config pullRequest of
    PullRequestRevision -> Right PullRequestRevision
    _ ->
      Left
        ( ActionLifecycleIncompatible
            kind
            "this pull request carries no changes-requested verdict to revise against"
        )
  RepairPullRequest -> case directPullRequestAction config pullRequest of
    PullRequestRepair -> Right PullRequestRepair
    _ ->
      Left
        ( ActionLifecycleIncompatible
            kind
            "repair applies to an approved Done pull request reporting a merge conflict, a failed check, or a blocking label"
        )
  _ -> Left (ActionTargetMismatchedArity kind)

-- | The registry verb the user's own @r@ selects, which is
-- 'directPullRequestAction' read as a kind. Round-trips: dispatching the kind
-- this returns runs exactly the action that rule chose.
workflowActionKindForDirectPress :: WorkflowConfig -> PullRequest -> WorkflowActionKind
workflowActionKindForDirectPress config pullRequest =
  kindForAction (directPullRequestAction config pullRequest)

-- | The registry verb Kanban's own automated progressions select.
--
-- Label-derived, and therefore never repair: autosolve drives its pull request
-- through review and revise itself, and a problem status on the pull request
-- it is looping over must not silently become a repair launch.
workflowActionKindForLabelledPullRequest :: WorkflowConfig -> PullRequest -> WorkflowActionKind
workflowActionKindForLabelledPullRequest config pullRequest =
  kindForAction (labelPullRequestAction config pullRequest)

-- | The registry verb one 'PullRequestAction' belongs to.
--
-- Review and rereview share a verb because they are one action kind whose
-- stage the labels decide; revision and repair each have their own, because
-- @$pr-revise@ and @$repair@ are different workflows with different
-- selection rules.
workflowActionKindForAction :: PullRequestAction -> WorkflowActionKind
workflowActionKindForAction PullRequestRepair = RepairPullRequest
workflowActionKindForAction PullRequestRevision = RevisePullRequest
workflowActionKindForAction PullRequestReview = ReviewPullRequest
workflowActionKindForAction PullRequestRereview = ReviewPullRequest

kindForAction :: PullRequestAction -> WorkflowActionKind
kindForAction = workflowActionKindForAction
