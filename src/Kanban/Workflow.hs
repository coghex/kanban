module Kanban.Workflow
  ( CardStatus (..),
    classifyPullRequest,
    deriveBoard,
    entryItem,
    hasChangesRequestedLabel,
    isApproved,
    isProblem,
    isStatusLabel,
    itemCompleted,
    itemLifecycleBadge,
    orderCardLabels,
    pullRequestStatus,
    readOnlyHistoryNotice,
    rereviewLabel,
  )
where

import Data.List (partition, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Ord (Down (..))
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime)
import Kanban.Domain
import Kanban.Tracker (implementationSortKey, membershipSortKey, trackerFromIssue)

data CardStatus
  = StatusNeutral
  | StatusPending Text
  | StatusReady
  | StatusProblem Text
  deriving stock (Eq, Show)

deriveBoard :: WorkflowConfig -> RepoSnapshot -> Board
deriveBoard config snapshot =
  Board
    . Map.fromList
    $ [(column, sortedEntries column) | column <- [minBound .. maxBound]]
  where
    trackers = map (pruneOffBoardChildren visibleChildNumbers) (mapMaybe (trackerFromIssue config) snapshot.snapshotIssues)
    -- Every recognized tracker gets exactly one card: either the header
    -- entry below, or (when at least one child is visible) the group
    -- header 'sortColumnEntries' builds from its tracked children. A
    -- tracker with no children at all (trackerTotal == 0) still needs to be
    -- excluded here, or it would additionally fall through to
    -- 'ordinaryIssues' and render a second, plain Standalone card.
    structuralTrackerNumbers =
      Set.fromList [tracker.trackerIssue.issueNumber | tracker <- trackers]
    membershipsByChild =
      Map.fromListWith (<>)
        [ (child.trackerChildIssueNumber, [TrackerMembership tracker child])
          | tracker <- trackers,
            child <- Map.elems tracker.trackerChildren
        ]
    visibleTrackerNumbers =
      Set.fromList
        [ tracker.trackerIssue.issueNumber
          | tracker <- trackers,
            child <- Map.elems tracker.trackerChildren,
            child.trackerChildIssueNumber `Set.member` visibleChildNumbers
        ]
    visibleChildNumbers =
      Set.fromList (map (.issueNumber) snapshot.snapshotIssues)
        <> Set.fromList (concatMap (.pullRequestLinkedIssues) snapshot.snapshotPullRequests)
    ordinaryIssues =
      filter
        (\issue -> issue.issueNumber `Set.notMember` structuralTrackerNumbers)
        snapshot.snapshotIssues
    issueEntries =
      [ ( issueColumn issue,
          trackedEntry (Map.findWithDefault [] issue.issueNumber membershipsByChild) (IssueItem issue)
        )
        | issue <- ordinaryIssues
      ]
    -- A tracker with no visible children has no group to sit above, so unlike
    -- every other entry its column cannot be inferred from the work it
    -- contains. It is a structural header rather than a work card, so
    -- 'issueColumn' does not apply either: an assigned epic is not itself
    -- in-progress work and must not compete for a slot in Active. Such headers
    -- always land in Issues, which keeps section 17's "tracker remains
    -- visible" true in one predictable place.
    trackerHeaderEntries =
      [ (Issues, TrackerHeader tracker)
        | tracker <- trackers,
          tracker.trackerIssue.issueNumber `Set.notMember` visibleTrackerNumbers
      ]
    pullRequestEntries =
      [ ( classifyPullRequest config pullRequest,
          trackedEntry
            (concatMap (\issueNumber -> Map.findWithDefault [] issueNumber membershipsByChild) pullRequest.pullRequestLinkedIssues)
            (PullRequestItem pullRequest)
        )
        | pullRequest <- snapshot.snapshotPullRequests
      ]
    entries = trackerHeaderEntries <> issueEntries <> pullRequestEntries
    sortedEntries column =
      sortColumnEntries config groupLifecycles [entry | (entryColumn, entry) <- entries, entryColumn == column]
    -- Decided over every column at once, because a group's membership is not
    -- confined to one: an epic whose implementation issue is closed in Issues
    -- and whose pull request merged into Done is wholly completed, and asking
    -- one column would answer for a fragment of it.
    groupLifecycles = groupLifecyclesFor (map snd entries) trackers

-- | Whether a whole tracker group is settled history, and how recently
-- anything in it moved.
--
-- Both are read off the tracker issue together with every entry grouped under
-- it, so the answer is a property of the group rather than of the column the
-- sorter happens to be looking at.
data GroupLifecycle = GroupLifecycle
  { groupWhollyCompleted :: Bool,
    groupRecency :: UTCTime
  }
  deriving stock (Eq, Show)

groupLifecyclesFor :: [ColumnEntry] -> [Tracker] -> Map.Map Int GroupLifecycle
groupLifecyclesFor entries trackers =
  Map.fromList [(number, lifecycleFor number tracker) | (number, tracker) <- numberedTrackers]
  where
    numberedTrackers = [(tracker.trackerIssue.issueNumber, tracker) | tracker <- trackers]
    membersByTracker =
      Map.fromListWith
        (<>)
        [ (number, [entryItem entry])
          | entry@(Tracked _ _) <- entries,
            Just number <- [entryPrimaryTracker entry]
        ]
    lifecycleFor number tracker =
      let trackerItem = IssueItem tracker.trackerIssue
          members = Map.findWithDefault [] number membersByTracker
       in GroupLifecycle
            { groupWhollyCompleted = all itemCompleted (trackerItem : members),
              groupRecency = maximum (map itemUpdatedAt (trackerItem : members))
            }

entryPrimaryTracker :: ColumnEntry -> Maybe Int
entryPrimaryTracker (Tracked context _) = Just (primaryTrackerNumber context)
entryPrimaryTracker (TrackerHeader tracker) = Just tracker.trackerIssue.issueNumber
entryPrimaryTracker (Standalone _) = Nothing

-- | Only an issue GitHub positively reported as having no assignees belongs in
-- the backlog column. A truncated connection means there are assignees this
-- board did not receive, and an 'AssigneesUnavailable' gap means it received
-- nothing at all -- neither is evidence of nobody working on it, so both stay
-- out of the column that presents an issue as unclaimed.
--
-- Lifecycle outranks that question entirely (§8). A closed issue is history,
-- and the assignees it carried while it was worked say nothing about where it
-- belongs now, so it lands in Issues however many of them it kept.
issueColumn :: Issue -> BoardColumn
issueColumn issue
  | issue.issueState == IssueClosed = Issues
  | null issue.issueAssignees
      && issue.issueAssigneeOverflow == 0
      && AssigneesUnavailable `notElem` issue.issueDataGaps =
      Issues
  | otherwise = Active

-- | A tracker's checklist can reference a child issue that no longer
-- appears on the live board (closed, merged, or otherwise outside the
-- current snapshot). Such a child can never be rendered or interacted
-- with, so it is dropped from 'trackerChildren' and folded into
-- 'trackerCompleted' instead of staying a permanently unreachable, always-
-- pending entry -- an off-board reference counts as done, not as blocking
-- progress forever.
--
-- That completion adjustment belongs to checklist membership alone. A
-- natively-sourced tracker's counts are GitHub's own summary over every
-- sub-issue it has, so a closed or cross-repository child is already counted
-- there; adding it again here would drift the displayed progress above the
-- number GitHub reported. Both sources still lose their non-visible children
-- from 'trackerChildren', so neither renders a card it cannot reach.
pruneOffBoardChildren :: Set.Set Int -> Tracker -> Tracker
pruneOffBoardChildren visibleChildNumbers tracker =
  tracker
    { trackerCompleted = case tracker.trackerSource of
        ChecklistMembership -> tracker.trackerCompleted + newlyCompleted
        NativeMembership -> tracker.trackerCompleted,
      trackerChildren = Map.filter isVisible tracker.trackerChildren
    }
  where
    isVisible child = child.trackerChildIssueNumber `Set.member` visibleChildNumbers
    newlyCompleted =
      length
        [ child
          | child <- Map.elems tracker.trackerChildren,
            not (isVisible child),
            not child.trackerChildComplete
        ]

trackedEntry :: [TrackerMembership] -> BoardItem -> ColumnEntry
trackedEntry rawMemberships item = case uniqueMemberships rawMemberships of
  [] -> Standalone item
  primary : additional -> Tracked (TrackingContext primary additional) item

uniqueMemberships :: [TrackerMembership] -> [TrackerMembership]
uniqueMemberships =
  sortOn membershipSortKey
    . Map.elems
    . Map.fromList
    . map (\membership -> ((membership.membershipTracker.trackerIssue.issueNumber, membership.membershipChild.trackerChildIssueNumber), membership))

-- | §12's order for one column, over a board that may hold settled history
-- alongside live work.
--
-- Completed cards are attention-neutral: they never enter the rereview tier
-- and never carry a problem or an approval into an ordering decision, so
-- turning history on cannot reorder the live board underneath it. What they do
-- instead is form a block of their own at the tail of each partition —
-- completed groups after every group holding open work, completed standalone
-- cards after every open standalone card — ordered by what moved most
-- recently, because recency is the only useful order over work that is done.
sortColumnEntries :: WorkflowConfig -> Map.Map Int GroupLifecycle -> [ColumnEntry] -> [ColumnEntry]
sortColumnEntries config groupLifecycles entries =
  concatMap snd rereviewGroups
    <> rereviewStandalone
    <> concatMap snd openGroups
    <> concatMap snd completedGroups
    <> openStandalone
    <> completedStandalone
  where
    (tracked, trackerHeaders, standalone) = partitionEntries entries
    grouped =
      Map.fromListWith combineGroup
        ( [ (primaryTrackerNumber context, (context.trackingPrimary.membershipTracker, [entry]))
            | entry@(Tracked context _) <- tracked
          ]
            <> [ (tracker.trackerIssue.issueNumber, (tracker, [TrackerHeader tracker]))
                 | tracker <- trackerHeaders
               ]
        )
    orderedGroups =
      [ (tracker, sortOn trackedChildKey groupEntries)
        | (tracker, groupEntries) <- Map.elems grouped
      ]
    (settledGroups, liveGroups) = partition (whollyCompletedGroup . fst) orderedGroups
    sortedLiveGroups = sortOn (\(tracker, groupEntries) -> trackerGroupKey config tracker groupEntries) liveGroups
    rereviewGroups = filter (uncurry groupNeedsRereview) sortedLiveGroups
    openGroups = filter (not . uncurry groupNeedsRereview) sortedLiveGroups
    completedGroups = sortOn (completedGroupKey . fst) settledGroups
    (settledStandalone, liveStandalone) = partition (itemCompleted . entryItem) standalone
    rereviewStandalone = sortOn (attentionKey config . entryItem) (filter (needsRereview . entryItem) liveStandalone)
    openStandalone = sortOn (attentionKey config . entryItem) (filter (not . needsRereview . entryItem) liveStandalone)
    completedStandalone = sortOn (completedCardKey . entryItem) settledStandalone
    combineGroup (_, newEntries) (tracker, existingEntries) = (tracker, newEntries <> existingEntries)
    -- A tracker with no lifecycle recorded is one this board did not derive
    -- the group for, which cannot happen for a group it is now sorting; it
    -- reads as live, which is the answer that leaves the live order alone.
    whollyCompletedGroup tracker =
      maybe False (.groupWhollyCompleted) (Map.lookup tracker.trackerIssue.issueNumber groupLifecycles)
    completedGroupKey tracker =
      ( Down (maybe tracker.trackerIssue.issueUpdatedAt (.groupRecency) (Map.lookup number groupLifecycles)),
        number
      )
      where
        number = tracker.trackerIssue.issueNumber

-- | Settled cards in the standalone block: newest-updated first, with the
-- item's own identity as the tie-break so two cards updated in the same second
-- keep a stable order across refreshes.
completedCardKey :: BoardItem -> (Down UTCTime, ItemId)
completedCardKey item = (Down (itemUpdatedAt item), itemId item)

partitionEntries :: [ColumnEntry] -> ([ColumnEntry], [Tracker], [ColumnEntry])
partitionEntries = foldr split ([], [], [])
  where
    split entry@(Tracked _ _) (tracked, trackerHeaders, standalone) = (entry : tracked, trackerHeaders, standalone)
    split (TrackerHeader tracker) (tracked, trackerHeaders, standalone) = (tracked, tracker : trackerHeaders, standalone)
    split entry@(Standalone _) (tracked, trackerHeaders, standalone) = (tracked, trackerHeaders, entry : standalone)

primaryTrackerNumber :: TrackingContext -> Int
primaryTrackerNumber context = context.trackingPrimary.membershipTracker.trackerIssue.issueNumber

groupNeedsRereview :: Tracker -> [ColumnEntry] -> Bool
groupNeedsRereview tracker entries =
  needsRereview (IssueItem tracker.trackerIssue)
    || any (needsRereview . entryItem) entries

trackedChildKey :: ColumnEntry -> (Int, Int, Text, Int, Int)
trackedChildKey entry@(Tracked context _) =
  let (kind, natural, number, order) = implementationSortKey context.trackingPrimary.membershipChild
   in (if needsRereview (entryItem entry) then 0 else 1, kind, natural, number, order)
trackedChildKey (Standalone _) = (1, 1, "", 0, 0)
trackedChildKey (TrackerHeader _) = (1, 1, "", 0, 0)

-- | A group's attention state, read off the work in it that is still live.
-- A completed member keeps whatever status treatment its labels and checks
-- earned on its own card, but it can no longer promote the group it sits in:
-- a closed blocked issue is not an outstanding problem.
trackerGroupKey :: WorkflowConfig -> Tracker -> [ColumnEntry] -> (Int, Int, UTCTime, Int)
trackerGroupKey config tracker entries =
  ( if any (liveItem (isProblem config)) entries then 0 else 1,
    if any (liveItem (isApproved config)) entries then 0 else 1,
    tracker.trackerIssue.issueCreatedAt,
    tracker.trackerIssue.issueNumber
  )
  where
    liveItem predicate entry =
      let item = entryItem entry in not (itemCompleted item) && predicate item

-- | Lifecycle outranks the approval predicate (§8). A merged pull request is
-- the outcome Done exists to reach, and a closed one ended there too; neither
-- is under review, so neither may appear in Reviewing whatever its draft flag
-- or approval state says.
classifyPullRequest :: WorkflowConfig -> PullRequest -> BoardColumn
classifyPullRequest config pullRequest
  | pullRequest.pullRequestState /= PullRequestOpen = Done
  | pullRequest.pullRequestDraft = Reviewing
  | approvedPullRequest config pullRequest = Done
  | otherwise = Reviewing

pullRequestStatus :: WorkflowConfig -> PullRequest -> CardStatus
pullRequestStatus config pullRequest
  | pullRequest.pullRequestMergeState == MergeConflicting = StatusProblem "merge conflict"
  | checksFailed pullRequest.pullRequestChecks = StatusProblem "CI failed"
  | hasProblemLabel config pullRequest.pullRequestLabels = blockedStatus config
  | not (approvedPullRequest config pullRequest) = StatusNeutral
  | checksPending pullRequest.pullRequestChecks = StatusPending "checks pending"
  | not (mergeStateReady pullRequest.pullRequestMergeState) = StatusPending "merge pending"
  | checksReady pullRequest.pullRequestChecks = StatusReady
  | otherwise = StatusPending "checks pending"

blockedStatus :: WorkflowConfig -> CardStatus
blockedStatus config = case config.blockingSeverity of
  SeverityRed -> StatusProblem "blocked"
  SeverityAmber -> StatusPending "blocked"

isApproved :: WorkflowConfig -> BoardItem -> Bool
isApproved config (IssueItem issue) = hasLabel config.approvalLabel issue.issueLabels
isApproved config (PullRequestItem pullRequest) = approvedPullRequest config pullRequest

-- | Configurable blocking severity governs pull-request readiness and PR
-- problem sorting only; issue-card blocking-label treatment always stays red.
isProblem :: WorkflowConfig -> BoardItem -> Bool
isProblem config (IssueItem issue) = hasProblemLabel config issue.issueLabels
isProblem config (PullRequestItem pullRequest) = case pullRequestStatus config pullRequest of
  StatusProblem _ -> True
  _ -> False

approvedPullRequest :: WorkflowConfig -> PullRequest -> Bool
approvedPullRequest config pullRequest =
  case config.approvalMode of
    ApprovalByLabel -> byLabel
    ApprovalByReview -> byReview
    ApprovalByEither -> byLabel || byReview
  where
    byLabel = hasLabel config.approvalLabel pullRequest.pullRequestLabels
    byReview = pullRequest.pullRequestReviewDecision == ReviewApproved

attentionKey :: WorkflowConfig -> BoardItem -> (Int, Int, UTCTime)
attentionKey config item =
  ( if isProblem config item then 0 else 1,
    if isApproved config item then 0 else 1,
    itemCreatedAt item
  )

-- | The strongest attention tier, which settled work never enters. A closed
-- issue still carrying @reviewed:revised@ has nothing left to rereview, so it
-- promotes neither itself nor the group it belongs to (§12).
needsRereview :: BoardItem -> Bool
needsRereview item | itemCompleted item = False
needsRereview (IssueItem issue) = hasLabel rereviewLabel issue.issueLabels
needsRereview (PullRequestItem _) = False

rereviewLabel :: Text
rereviewLabel = "reviewed:revised"

-- | Whether an item is settled history rather than live work: a closed issue,
-- or a pull request that merged or was closed unmerged.
--
-- Read off the item's own decoded lifecycle rather than inferred from which
-- generation delivered it, so a card is answered for the same way whether it
-- arrived from GitHub, from the completed cache, or from an overlay that has
-- been holding it since before it settled.
itemCompleted :: BoardItem -> Bool
itemCompleted (IssueItem issue) = issue.issueState == IssueClosed
itemCompleted (PullRequestItem pullRequest) = pullRequest.pullRequestState /= PullRequestOpen

-- | The lifecycle badge a settled card carries (§11), or 'Nothing' for live
-- work, which carries none. @MERGED@ and @CLOSED@ are kept apart because they
-- are different outcomes: one landed the work and one abandoned it.
itemLifecycleBadge :: BoardItem -> Maybe Text
itemLifecycleBadge (IssueItem issue) = case issue.issueState of
  IssueOpen -> Nothing
  IssueClosed -> Just "CLOSED"
itemLifecycleBadge (PullRequestItem pullRequest) = case pullRequest.pullRequestState of
  PullRequestOpen -> Nothing
  PullRequestClosed -> Just "CLOSED"
  PullRequestMerged -> Just "MERGED"

-- | Why a mutating action declined a settled card. It names the item and the
-- outcome that settled it, so the refusal reads as a fact about the card
-- rather than as a failure of the key that was pressed.
readOnlyHistoryNotice :: BoardItem -> Text
readOnlyHistoryNotice item = subject <> " is " <> outcome <> "; completed history is read-only"
  where
    subject = case item of
      IssueItem issue -> "Issue #" <> showNumber issue.issueNumber
      PullRequestItem pullRequest -> "PR #" <> showNumber pullRequest.pullRequestNumber
    outcome = case item of
      IssueItem _ -> "closed"
      PullRequestItem pullRequest -> case pullRequest.pullRequestState of
        PullRequestMerged -> "merged"
        _ -> "closed"
    showNumber = Text.pack . show

-- | Whether an item carries the configured changes-requested label, which is
-- the strongest workflow category a filter can select on and is therefore
-- asked separately from the broader 'isProblem'.
hasChangesRequestedLabel :: WorkflowConfig -> BoardItem -> Bool
hasChangesRequestedLabel config item = hasLabel config.changesRequestedLabel (itemLabels item)

-- | Whether a label name carries workflow status: the approval,
-- changes-requested, blocked, and rereview names 'isApproved', 'isProblem',
-- and 'needsRereview' recognize, matched case-insensitively the same way.
isStatusLabel :: WorkflowConfig -> Text -> Bool
isStatusLabel config name =
  folded == Text.toCaseFold config.approvalLabel
    || folded == Text.toCaseFold config.changesRequestedLabel
    || folded == Text.toCaseFold rereviewLabel
    || folded `Set.member` Set.map Text.toCaseFold config.blockedLabels
  where
    folded = Text.toCaseFold name

-- | The card label order: workflow-status labels first, keeping the order the
-- provider returned them in, then every remaining label alphabetically.
orderCardLabels :: WorkflowConfig -> [Label] -> [Label]
orderCardLabels config labels = statusLabels <> sortOn (Text.toCaseFold . (.labelName)) otherLabels
  where
    (statusLabels, otherLabels) = partition (isStatusLabel config . (.labelName)) labels

hasProblemLabel :: WorkflowConfig -> [Label] -> Bool
hasProblemLabel config labels =
  hasLabel config.changesRequestedLabel labels
    || hasAnyLabel config.blockedLabels labels

hasAnyLabel :: Set.Set Text -> [Label] -> Bool
hasAnyLabel names labels =
  not . Set.null $ Set.intersection (Set.map Text.toCaseFold names) (Set.fromList (map (Text.toCaseFold . (.labelName)) labels))

hasLabel :: Text -> [Label] -> Bool
hasLabel name = any ((== Text.toCaseFold name) . Text.toCaseFold . (.labelName))

checksFailed :: CheckSummary -> Bool
checksFailed (ChecksFailed _ _ _) = True
checksFailed _ = False

checksReady :: CheckSummary -> Bool
checksReady ChecksNone = True
checksReady (ChecksPassed _) = True
checksReady _ = False

-- | Only a known pending/queued/in-progress check summary ranks above merge
-- readiness; 'ChecksUnknown' (a truncated rollup) must not silently gain
-- that same priority.
checksPending :: CheckSummary -> Bool
checksPending (ChecksPending _ _ _) = True
checksPending _ = False

mergeStateReady :: MergeState -> Bool
mergeStateReady MergeClean = True
mergeStateReady MergeProtected = True
mergeStateReady _ = False

entryItem :: ColumnEntry -> BoardItem
entryItem (Standalone item) = item
entryItem (Tracked _ item) = item
entryItem (TrackerHeader tracker) = IssueItem tracker.trackerIssue
