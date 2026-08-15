-- | The card filter criteria and the board they admit (@docs\/design.md@ §8
-- and §12, and @docs\/card_filter_design.md@'s D-6, D-12 and D-23).
--
-- Criteria are four independent facets. Values are ORed inside a facet and the
-- facets are ANDed, so an empty facet is a valid empty result rather than an
-- implicit reset. Every value starts checked except 'LifecycleClosed', which
-- is what makes the ordinary view the complete live open board.
--
-- Nothing here is serializable on purpose. Criteria are process-lifetime
-- presentation state: they initialize to 'defaultFilterCriteria' at every
-- start, survive every in-process refresh, overlay and dismissal, and are
-- never written to the cache, the settings file, or the configuration.
-- Deriving 'FromJSON' or 'ToJSON' for any type in this module would be the
-- first step toward breaking that, so none of them has one.
--
-- The pipeline is @docs\/card_filter_design.md@'s composition, in order:
-- complete datasets, criteria filtering, structural repair, and then the
-- optional search "Kanban.UI.Search" applies over the result with a structural
-- repair of its own.
module Kanban.Filter
  ( -- * The criteria
    FilterCriteria (..),
    KindFacet (..),
    LifecycleFacet (..),
    StructureFacet (..),
    WorkflowFacet (..),
    defaultFilterCriteria,
    everyFacetValue,

    -- * Classification
    itemKindFacet,
    itemLifecycleFacet,
    itemWorkflowFacet,
    entryStructureFacet,

    -- * The admitted board
    criteriaDataset,
    filterBoardEntries,
    visibleBoardFor,
  )
where

import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Time (UTCTime (..))
import Data.Time.Calendar (Day (..))
import Kanban.Domain
import Kanban.Workflow
  ( deriveBoard,
    entryItem,
    hasChangesRequestedLabel,
    isApproved,
    isProblem,
    itemCompleted,
  )

-- | Whether a card is live work or settled history. The visible @Closed@
-- checkbox means completed lifecycle across both kinds: closed issues together
-- with closed and merged pull requests.
data LifecycleFacet = LifecycleOpen | LifecycleClosed
  deriving stock (Eq, Ord, Enum, Bounded, Show)

data KindFacet = KindIssues | KindPullRequests
  deriving stock (Eq, Ord, Enum, Bounded, Show)

-- | The workflow categories, which are exclusive by strongest-state
-- precedence rather than overlapping: the configured changes-requested state
-- first, every other problem condition second, the configured approval
-- predicate third, and everything neutral, pending, ready-but-unapproved or
-- draft is 'WorkflowOther'. Exclusivity is what makes the four values
-- exhaustive, so checking all of them admits every card exactly once.
data WorkflowFacet = WorkflowChanges | WorkflowProblems | WorkflowApproved | WorkflowOther
  deriving stock (Eq, Ord, Enum, Bounded, Show)

-- | Whether a card is part of an epic group — a tracker header or a tracked
-- child — or a standalone card. This is the entry's own structure, not a
-- statement about assignment.
data StructureFacet = StructureEpicGroups | StructureStandalone
  deriving stock (Eq, Ord, Enum, Bounded, Show)

data FilterCriteria = FilterCriteria
  { filterLifecycle :: Set LifecycleFacet,
    filterKind :: Set KindFacet,
    filterWorkflow :: Set WorkflowFacet,
    filterStructure :: Set StructureFacet
  }
  deriving stock (Eq, Show)

-- | Every value of a facet, which is what all but one of them starts as.
everyFacetValue :: (Ord value, Enum value, Bounded value) => Set value
everyFacetValue = Set.fromList [minBound .. maxBound]

-- | Every value checked except 'LifecycleClosed', so the board a process
-- starts with is exactly the live open board it has always shown.
defaultFilterCriteria :: FilterCriteria
defaultFilterCriteria =
  FilterCriteria
    { filterLifecycle = Set.singleton LifecycleOpen,
      filterKind = everyFacetValue,
      filterWorkflow = everyFacetValue,
      filterStructure = everyFacetValue
    }

itemLifecycleFacet :: BoardItem -> LifecycleFacet
itemLifecycleFacet item = if itemCompleted item then LifecycleClosed else LifecycleOpen

itemKindFacet :: BoardItem -> KindFacet
itemKindFacet (IssueItem _) = KindIssues
itemKindFacet (PullRequestItem _) = KindPullRequests

itemWorkflowFacet :: WorkflowConfig -> BoardItem -> WorkflowFacet
itemWorkflowFacet config item
  | hasChangesRequestedLabel config item = WorkflowChanges
  | isProblem config item = WorkflowProblems
  | isApproved config item = WorkflowApproved
  | otherwise = WorkflowOther

entryStructureFacet :: ColumnEntry -> StructureFacet
entryStructureFacet (Standalone _) = StructureStandalone
entryStructureFacet (Tracked _ _) = StructureEpicGroups
entryStructureFacet (TrackerHeader _) = StructureEpicGroups

-- | The complete data the criteria's lifecycle facet selects, combined into
-- one dataset for 'deriveBoard' to find structure in.
--
-- Combining before deriving rather than deriving each generation separately is
-- what keeps a completed tracker a tracker: an epic closed ahead of one of its
-- children only groups that child when both reach tracker recognition at once.
--
-- 'Nothing' means the dataset is exactly the open generation, which the caller
-- already has a derived board for. That is not an optimisation detail: it is
-- how the default criteria reproduce the live board by identity rather than by
-- a comparison somebody has to keep true.
criteriaDataset ::
  FilterCriteria ->
  Maybe RepoSnapshot ->
  Maybe CompletedHistory ->
  Maybe RepoSnapshot
criteriaDataset criteria openSnapshot history
  | admitsOpen, null admittedIssues, null admittedPullRequests = Nothing
  | otherwise =
      Just
        RepoSnapshot
          { snapshotIssues = openIssues <> admittedIssues,
            snapshotPullRequests = openPullRequests <> admittedPullRequests,
            snapshotFetchedAt = fetchedAt
          }
  where
    admitsOpen = LifecycleOpen `Set.member` criteria.filterLifecycle
    admittedHistory
      | LifecycleClosed `Set.member` criteria.filterLifecycle = history
      | otherwise = Nothing
    openIssues = if admitsOpen then maybe [] (.snapshotIssues) openSnapshot else []
    openPullRequests = if admitsOpen then maybe [] (.snapshotPullRequests) openSnapshot else []
    admittedIssues = maybe [] (.historyIssues) admittedHistory
    admittedPullRequests = maybe [] (.historyPullRequests) admittedHistory
    -- Nothing derived from a dataset reads this, so any generation's own time
    -- is as good as another's; the epoch stands in only before either has
    -- published, where the dataset is empty in any case.
    fetchedAt = case (openSnapshot, history) of
      (Just snapshot, _) -> snapshot.snapshotFetchedAt
      (Nothing, Just completed) -> completed.historyFetchedAt
      (Nothing, Nothing) -> UTCTime (ModifiedJulianDay 0) 0

-- | The board those criteria admit, given the open board already derived from
-- the open generation.
--
-- With @Closed@ hidden and every other value checked — the defaults — this is
-- @openBoard@ itself, unchanged and unre-derived, which is what makes a loaded
-- completed history invisible to every column, count, badge, row index, and
-- golden frame.
--
-- @openBoard@ and @openSnapshot@ must be the two halves of one generation:
-- the board is only consulted while the criteria leave the dataset alone, and
-- the snapshot only once something has to be derived from it. An absent
-- snapshot therefore means an absent open generation, which is the state a
-- process is in before its first one publishes and the empty board it draws.
visibleBoardFor ::
  WorkflowConfig ->
  FilterCriteria ->
  -- | The board already derived from the open generation.
  Board ->
  Maybe RepoSnapshot ->
  Maybe CompletedHistory ->
  Board
visibleBoardFor config criteria openBoard openSnapshot history =
  filterBoardEntries config criteria derived
  where
    derived = maybe openBoard (deriveBoard config) (criteriaDataset criteria openSnapshot history)

-- | The kind, workflow and structure facets applied to a derived board, with
-- the structural repair the composition calls for.
--
-- A tracked child survives as a tracked child only while its own tracker
-- survives; when the criteria hide the tracker, the child falls back to
-- 'Standalone', which is exactly what the board renders for a child whose epic
-- is not on it. A tracker that survives with none of its children left
-- collapses to a 'TrackerHeader', so the epic is still represented rather than
-- vanishing behind its own filtered-out group.
--
-- Criteria admitting every card return the board untouched. That is the
-- default, and returning the same value rather than an equal one keeps every
-- row index the caller may already hold pointing at the same entry.
filterBoardEntries :: WorkflowConfig -> FilterCriteria -> Board -> Board
filterBoardEntries config criteria board
  | admitsEveryEntry criteria = board
  | otherwise = Board (Map.map (filterColumn config criteria) board.boardColumns)

-- | Whether the kind, workflow and structure facets are all complete, in which
-- case no entry can fail them. The lifecycle facet is not asked here: it
-- selects the dataset rather than filtering entries drawn from it.
admitsEveryEntry :: FilterCriteria -> Bool
admitsEveryEntry criteria =
  criteria.filterKind == everyFacetValue
    && criteria.filterWorkflow == everyFacetValue
    && criteria.filterStructure == everyFacetValue

-- | One column's entries, group by group, so a group's repair is decided with
-- its whole run of rows in hand. Groups are contiguous in a sorted column,
-- which is the same shape "Kanban.UI.Search" filters over.
filterColumn :: WorkflowConfig -> FilterCriteria -> [ColumnEntry] -> [ColumnEntry]
filterColumn config criteria = keep
  where
    keep [] = []
    keep remaining@(entry : rest) = case entry of
      Standalone _ -> [entry | admits entry] <> keep rest
      TrackerHeader _ -> [entry | admits entry] <> keep rest
      Tracked context _ ->
        let tracker = context.trackingPrimary.membershipTracker
            number = tracker.trackerIssue.issueNumber
            (group, after) = span ((== Just number) . primaryTrackerOf) remaining
            children = filter admits group
            kept
              | not (admitsTracker tracker) = map demote children
              | not (null children) = children
              | otherwise = [TrackerHeader tracker]
         in kept <> keep after
    admits entry =
      entryStructureFacet entry `Set.member` criteria.filterStructure
        && admitsItem (entryItem entry)
    -- The tracker itself is judged as the header it would draw: an epic group
    -- is structure, and the tracker issue's own kind and workflow state decide
    -- the rest.
    admitsTracker tracker =
      StructureEpicGroups `Set.member` criteria.filterStructure
        && admitsItem (IssueItem tracker.trackerIssue)
    admitsItem item =
      itemKindFacet item `Set.member` criteria.filterKind
        && itemWorkflowFacet config item `Set.member` criteria.filterWorkflow
    demote entry = Standalone (entryItem entry)
    primaryTrackerOf (Tracked context _) = Just context.trackingPrimary.membershipTracker.trackerIssue.issueNumber
    primaryTrackerOf (TrackerHeader tracker) = Just tracker.trackerIssue.issueNumber
    primaryTrackerOf (Standalone _) = Nothing
