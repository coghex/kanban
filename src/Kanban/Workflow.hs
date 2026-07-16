module Kanban.Workflow
  ( CardStatus (..),
    deriveBoard,
    entryItem,
    isApproved,
    isProblem,
    pullRequestStatus,
  )
where

import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
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
    trackers = mapMaybe (trackerFromIssue config) snapshot.snapshotIssues
    structuralTrackerNumbers =
      Set.fromList
        [ tracker.trackerIssue.issueNumber
          | tracker <- trackers,
            tracker.trackerTotal > 0
        ]
    membershipsByChild =
      Map.fromListWith (<>)
        [ (child.trackerChildIssueNumber, [TrackerMembership tracker child])
          | tracker <- trackers,
            child <- Map.elems tracker.trackerChildren
        ]
    linkedIssueNumbers =
      Set.fromList (concatMap (.pullRequestLinkedIssues) snapshot.snapshotPullRequests)
    ordinaryIssues =
      filter
        ( \issue ->
            issue.issueNumber `Set.notMember` linkedIssueNumbers
              && issue.issueNumber `Set.notMember` structuralTrackerNumbers
        )
        snapshot.snapshotIssues
    issueEntries =
      [ ( if null issue.issueAssignees then Issues else Active,
          trackedEntry (Map.findWithDefault [] issue.issueNumber membershipsByChild) (IssueItem issue)
        )
        | issue <- ordinaryIssues
      ]
    pullRequestEntries =
      [ ( classifyPullRequest config pullRequest,
          trackedEntry
            (concatMap (\issueNumber -> Map.findWithDefault [] issueNumber membershipsByChild) pullRequest.pullRequestLinkedIssues)
            (PullRequestItem pullRequest)
        )
        | pullRequest <- snapshot.snapshotPullRequests
      ]
    entries = issueEntries <> pullRequestEntries
    sortedEntries column = sortColumnEntries config [entry | (entryColumn, entry) <- entries, entryColumn == column]

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

sortColumnEntries :: WorkflowConfig -> [ColumnEntry] -> [ColumnEntry]
sortColumnEntries config entries = concatMap snd sortedGroups <> sortedStandalone
  where
    (tracked, standalone) = partitionEntries entries
    grouped =
      Map.fromListWith combineGroup
        [ (primaryTrackerNumber context, (context.trackingPrimary.membershipTracker, [entry]))
          | entry@(Tracked context _) <- tracked
        ]
    sortedGroups =
      sortOn fst
        [ (trackerGroupKey config tracker groupEntries, sortOn trackedChildKey groupEntries)
          | (tracker, groupEntries) <- Map.elems grouped
        ]
    sortedStandalone = sortOn (attentionKey config . entryItem) standalone
    combineGroup (_, newEntries) (tracker, existingEntries) = (tracker, newEntries <> existingEntries)

partitionEntries :: [ColumnEntry] -> ([ColumnEntry], [ColumnEntry])
partitionEntries = foldr split ([], [])
  where
    split entry@(Tracked _ _) (tracked, standalone) = (entry : tracked, standalone)
    split entry@(Standalone _) (tracked, standalone) = (tracked, entry : standalone)

primaryTrackerNumber :: TrackingContext -> Int
primaryTrackerNumber context = context.trackingPrimary.membershipTracker.trackerIssue.issueNumber

trackedChildKey :: ColumnEntry -> (Int, Text, Int, Int)
trackedChildKey (Tracked context _) = implementationSortKey context.trackingPrimary.membershipChild
trackedChildKey (Standalone _) = (1, "", 0, 0)

trackerGroupKey :: WorkflowConfig -> Tracker -> [ColumnEntry] -> (Int, Int, UTCTime, Int)
trackerGroupKey config tracker entries =
  ( if any (isProblem config . entryItem) entries then 0 else 1,
    if any (isApproved config . entryItem) entries then 0 else 1,
    tracker.trackerIssue.issueCreatedAt,
    tracker.trackerIssue.issueNumber
  )

classifyPullRequest :: WorkflowConfig -> PullRequest -> BoardColumn
classifyPullRequest config pullRequest
  | pullRequest.pullRequestDraft = Reviewing
  | approvedPullRequest config pullRequest = Done
  | otherwise = Reviewing

pullRequestStatus :: WorkflowConfig -> PullRequest -> CardStatus
pullRequestStatus config pullRequest
  | pullRequest.pullRequestMergeState == MergeConflicting = StatusProblem "merge conflict"
  | checksFailed pullRequest.pullRequestChecks = StatusProblem "CI failed"
  | hasProblemLabel config pullRequest.pullRequestLabels = StatusProblem "blocked"
  | not (approvedPullRequest config pullRequest) = StatusNeutral
  | pullRequest.pullRequestMergeState /= MergeClean = StatusPending "merge pending"
  | checksReady pullRequest.pullRequestChecks = StatusReady
  | otherwise = StatusPending "checks pending"

isApproved :: WorkflowConfig -> BoardItem -> Bool
isApproved config (IssueItem issue) = hasLabel config.approvalLabel issue.issueLabels
isApproved config (PullRequestItem pullRequest) = approvedPullRequest config pullRequest

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
checksFailed (ChecksFailed _ _) = True
checksFailed _ = False

checksReady :: CheckSummary -> Bool
checksReady ChecksNone = True
checksReady (ChecksPassed _) = True
checksReady _ = False

entryItem :: ColumnEntry -> BoardItem
entryItem (Standalone item) = item
entryItem (Tracked _ item) = item
