{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

module Kanban.Domain
  ( ApprovalMode (..),
    Assignee (..),
    BlockingSeverity (..),
    Board (..),
    BoardColumn (..),
    BoardItem (..),
    CheckDetail (..),
    CheckState (..),
    CheckSummary (..),
    ColumnEntry (..),
    CompletedHistory (..),
    CompletedProgress (..),
    DataGap (..),
    Freshness (..),
    Issue (..),
    IssueState (..),
    ItemId (..),
    Label (..),
    MergeState (..),
    NativeSubIssues (..),
    PullRequest (..),
    PullRequestState (..),
    RepoSnapshot (..),
    Repository (..),
    ReviewDecision (..),
    SubIssueLink (..),
    SubIssueProgress (..),
    SubIssueRelationships (..),
    Tracker (..),
    TrackerChild (..),
    TrackerDiagnostic (..),
    TrackerMembership (..),
    TrackerSource (..),
    TrackingContext (..),
    UsageProvider (..),
    UsageSnapshot (..),
    UsageWindow (..),
    WorkflowConfig (..),
    defaultWorkflowConfig,
    emptyCompletedProgress,
    historyWithoutOpen,
    itemCreatedAt,
    itemId,
    itemLabelOverflow,
    itemLabels,
    itemTitle,
    itemUpdatedAt,
    openWithoutHistory,
  )
where

import Data.Aeson (FromJSON (..), FromJSONKey, ToJSON, ToJSONKey, withObject, (.!=), (.:), (.:?))
import Data.Map.Strict (Map)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)

data Repository = Repository
  { repositoryRoot :: FilePath,
    repositoryOwner :: Text,
    repositoryName :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data Label = Label
  { labelName :: Text,
    labelColor :: Text
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype Assignee = Assignee {assigneeLogin :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

-- | One part of an item GitHub's response did not deliver in a form this build
-- can use: a nested connection left absent or nulled, or a status-check rollup
-- holding a context that could not be decoded.
--
-- These are per-item on purpose. An anomaly attributable to one issue or pull
-- request degrades that card -- amber, with a snapshot warning naming it --
-- rather than failing the page decode and leaving the board on a stale
-- snapshot. A gap is also what keeps the card honest about what it does not
-- know: an item whose assignees never arrived is not the same as one that has
-- none, and must not be shown as @unassigned@ or @UNLINKED@.
data DataGap
  = LabelsUnavailable
  | AssigneesUnavailable
  | LinkedIssuesUnavailable
  | ChecksUndecodable
  | SubIssuesUnavailable
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | One native GitHub sub-issue relationship, as GitHub reported it.
--
-- The owning repository travels with the number because 'trackerChildren' is
-- keyed by issue number alone: without it, a sub-issue #12 belonging to
-- another repository would be indistinguishable from this repository's #12
-- and would silently claim that card (§12).
data SubIssueLink = SubIssueLink
  { subIssueNumber :: Int,
    -- | @owner\/name@, exactly as GitHub returned it for the child.
    subIssueRepository :: Text,
    subIssueClosed :: Bool
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | GitHub's completed/total counts over every sub-issue an issue has,
-- including the closed ones and any this board can never render.
data SubIssueProgress = SubIssueProgress
  { subIssuesCompleted :: Int,
    subIssuesTotal :: Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | GitHub's answer about one issue's immediate native sub-issues: the
-- children in the order returned, and the summary it keeps over all of them.
--
-- Either half can be absent on its own, because a partial-error response
-- nulls exactly the fields that errored. Whatever did arrive is kept and used
-- — dropping delivered children because their summary went missing would
-- scatter a tracker's group across the board — and the item is marked
-- incomplete for the rest.
--
-- 'subIssuesRepository' is GitHub's own identity for the repository the page
-- was fetched from, taken from the same response rather than from the locally
-- configured owner and name, so a repository reached through a rename
-- redirect does not misclassify its own children as foreign.
data SubIssueRelationships = SubIssueRelationships
  { subIssuesRepository :: Text,
    -- | The immediate children in GitHub's order, or 'Nothing' when the
    -- relationship connection itself did not arrive.
    subIssuesChildren :: Maybe [SubIssueLink],
    -- | Children GitHub said exist but did not deliver in the node list.
    subIssuesOmitted :: Int,
    -- | GitHub's own counts, or 'Nothing' when the summary did not arrive.
    subIssuesProgress :: Maybe SubIssueProgress
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | What is known about an issue's native sub-issue relationships.
--
-- The three cases are deliberately distinct, because §12's fallback
-- membership hinges on telling them apart: only a set GitHub positively
-- reported as empty means a tracker really has no native children.
data NativeSubIssues
  = -- | This refresh never asked, because the GitHub deployment's schema does
    -- not expose the sub-issue fields. Membership is checklist-only exactly
    -- as it was before native membership existed, and the refresh says so
    -- once in its banner rather than degrading every card.
    SubIssuesNotRequested
  | -- | Asked for and not delivered: absent, null, or incomplete. This is an
    -- unverified absence, so it marks the item incomplete instead of standing
    -- in for \"this tracker has no children\".
    SubIssuesUnreported
  | SubIssuesReported SubIssueRelationships
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Where an issue is in its lifecycle, as GitHub reports it.
--
-- It is decoded from the item rather than inferred from the traversal that
-- returned it. The two traversals ask for disjoint states, so inference would
-- look right for as long as nothing else ever produced an item — and then be
-- silently wrong for the cached generation, whose items arrive from a file
-- with no traversal behind them at all.
data IssueState = IssueOpen | IssueClosed
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A pull request's lifecycle. Merged is a state of its own rather than a
-- flavour of closed, because §8 puts a merged pull request in Done and the
-- drainer's whole purpose is to move requests between those two endings.
data PullRequestState = PullRequestOpen | PullRequestClosed | PullRequestMerged
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data Issue = Issue
  { issueNumber :: Int,
    issueTitle :: Text,
    issueBody :: Text,
    issueUrl :: Text,
    issueState :: IssueState,
    issueLabels :: [Label],
    issueAssignees :: [Assignee],
    issueCreatedAt :: UTCTime,
    issueUpdatedAt :: UTCTime,
    issueLabelOverflow :: Int,
    issueAssigneeOverflow :: Int,
    issueSubIssues :: NativeSubIssues,
    issueDataGaps :: [DataGap]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ReviewDecision
  = ReviewApproved
  | ReviewChangesRequested
  | ReviewRequired
  | ReviewUnknown
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data MergeState
  = MergeClean
  | MergeBehind
  | MergeBlocked
  | MergeProtected
  | MergeConflicting
  | MergeUnstable
  | MergeUnknown
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The normalized state of one status-check context, after a check run's
-- status/conclusion pair or a status context's state has been classified.
data CheckState = CheckPassed | CheckPending | CheckFailed
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | One retained status check: the name GitHub reports and its normalized
-- state. This is display data for the §11 details overlay, kept alongside the
-- aggregate counts so the overlay never needs a second request.
data CheckDetail = CheckDetail
  { checkDetailName :: Text,
    checkDetailState :: CheckState
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A pull request's status-check rollup.
--
-- Only the two summaries that have something outstanding carry per-check
-- detail, and that list holds exactly the deduplicated checks that did not
-- pass. Attaching it to those constructors alone is what keeps the overlay
-- honest: 'ChecksNone' and 'ChecksPassed' have no detail rows to render, and
-- 'ChecksUnknown' -- a rollup past the §13 context cap -- cannot present the
-- partial nodes it did see as if they were the whole story.
data CheckSummary
  = ChecksNone
  | ChecksPending Int Int [CheckDetail]
  | ChecksPassed Int
  | ChecksFailed Int Int [CheckDetail]
  | ChecksUnknown
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data PullRequest = PullRequest
  { pullRequestNumber :: Int,
    pullRequestTitle :: Text,
    pullRequestBody :: Text,
    pullRequestUrl :: Text,
    pullRequestState :: PullRequestState,
    pullRequestLabels :: [Label],
    pullRequestAuthor :: Text,
    pullRequestDraft :: Bool,
    pullRequestBase :: Text,
    pullRequestHead :: Text,
    pullRequestLinkedIssues :: [Int],
    pullRequestReviewDecision :: ReviewDecision,
    pullRequestMergeState :: MergeState,
    pullRequestChecks :: CheckSummary,
    pullRequestCreatedAt :: UTCTime,
    pullRequestUpdatedAt :: UTCTime,
    pullRequestLabelOverflow :: Int,
    pullRequestLinkedIssueOverflow :: Int,
    pullRequestDataGaps :: [DataGap]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ItemId = IssueId Int | PullRequestId Int
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data BoardItem = IssueItem Issue | PullRequestItem PullRequest
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data BoardColumn = Issues | Active | Reviewing | Done
  deriving stock (Eq, Ord, Enum, Bounded, Show, Generic)
  deriving anyclass (FromJSON, ToJSON, FromJSONKey, ToJSONKey)

-- | Which of §12's ordered membership sources a tracker's children came from.
--
-- This is not presentation detail: progress means different things under the
-- two sources. Checklist progress is counted from the marks in the body and
-- is completed by off-board children, while native progress is GitHub's own
-- completed/total pair and is never adjusted locally.
data TrackerSource = ChecklistMembership | NativeMembership
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data Tracker = Tracker
  { trackerIssue :: Issue,
    trackerSource :: TrackerSource,
    trackerCompleted :: Int,
    trackerTotal :: Int,
    trackerChildren :: Map Int TrackerChild,
    trackerDiagnostics :: [TrackerDiagnostic]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data TrackerChild = TrackerChild
  { trackerChildIssueNumber :: Int,
    trackerChildImplementationKey :: Maybe Text,
    trackerChildChecklistOrder :: Int,
    trackerChildComplete :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data TrackerDiagnostic
  = TrackerSectionMissing
  | TrackerChildrenMissing
  | TrackerMalformedCheckbox Int
  | TrackerIssueReferenceMissing Int
  | TrackerDuplicateChild Int Int
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data TrackerMembership = TrackerMembership
  { membershipTracker :: Tracker,
    membershipChild :: TrackerChild
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data TrackingContext = TrackingContext
  { trackingPrimary :: TrackerMembership,
    trackingAdditional :: [TrackerMembership]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ColumnEntry
  = Standalone BoardItem
  | Tracked TrackingContext BoardItem
  | TrackerHeader Tracker
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype Board = Board {boardColumns :: Map BoardColumn [ColumnEntry]}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | One complete open generation: every open issue and every open pull
-- request the repository had, with no top-level connection left unfollowed.
-- There is nothing to say about truncation because there is no cap to reach
-- (§13); the nested @+N@ overflow markers are item-local and live on the
-- items themselves.
data RepoSnapshot = RepoSnapshot
  { snapshotIssues :: [Issue],
    snapshotPullRequests :: [PullRequest],
    snapshotFetchedAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | One complete completed generation: every closed issue and every closed or
-- merged pull request the repository had, with neither connection left
-- unfollowed (§13).
--
-- Only a whole generation is ever represented here. A partial page set, a
-- cancelled traversal, and a failed page produce no value of this type at all,
-- which is what keeps \"the history is loaded\" from ever meaning \"some of it
-- is\".
data CompletedHistory = CompletedHistory
  { historyIssues :: [Issue],
    historyPullRequests :: [PullRequest],
    historyFetchedAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | How far a completed generation has got, counted separately for the two
-- kinds because they paginate independently and one routinely finishes several
-- pages before the other.
--
-- The totals are GitHub's own @totalCount@ for each completed connection, and
-- are 'Nothing' until a page has reported one. That is deliberately not zero: a
-- traversal that has fetched nothing yet knows nothing about the size of the
-- history, and a zero would render as a finished empty one.
data CompletedProgress = CompletedProgress
  { completedIssuesLoaded :: Int,
    completedIssuesTotal :: Maybe Int,
    completedPullRequestsLoaded :: Int,
    completedPullRequestsTotal :: Maybe Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | What a completed generation reports before its first page answers.
emptyCompletedProgress :: CompletedProgress
emptyCompletedProgress = CompletedProgress 0 Nothing 0 Nothing

-- | Drops from a completed history every item the open generation lists.
--
-- Applied when an open generation publishes, which makes it the newer of the
-- two: an item GitHub has just reported open cannot also be history, so a
-- reopened item leaves the completed set here rather than appearing twice.
historyWithoutOpen :: RepoSnapshot -> CompletedHistory -> CompletedHistory
historyWithoutOpen snapshot history =
  history
    { historyIssues = filter (not . (`Set.member` openIssues) . (.issueNumber)) history.historyIssues,
      historyPullRequests =
        filter (not . (`Set.member` openPullRequests) . (.pullRequestNumber)) history.historyPullRequests
    }
  where
    openIssues = Set.fromList (map (.issueNumber) snapshot.snapshotIssues)
    openPullRequests = Set.fromList (map (.pullRequestNumber) snapshot.snapshotPullRequests)

-- | Drops from an open snapshot every item the completed generation lists.
--
-- The mirror of 'historyWithoutOpen', applied when a completed generation
-- publishes second. An open card the newer generation has proved closed is
-- stale, and leaving it would put one item in both sets — which no ordering,
-- badge, or count could then describe honestly.
openWithoutHistory :: CompletedHistory -> RepoSnapshot -> RepoSnapshot
openWithoutHistory history snapshot =
  snapshot
    { snapshotIssues = filter (not . (`Set.member` closedIssues) . (.issueNumber)) snapshot.snapshotIssues,
      snapshotPullRequests =
        filter (not . (`Set.member` settledPullRequests) . (.pullRequestNumber)) snapshot.snapshotPullRequests
    }
  where
    closedIssues = Set.fromList (map (.issueNumber) history.historyIssues)
    settledPullRequests = Set.fromList (map (.pullRequestNumber) history.historyPullRequests)

data UsageProvider = Codex | Claude
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON, FromJSONKey, ToJSONKey)

data UsageWindow = UsageWindow
  { usageWindowLabel :: Text,
    usagePercentLeft :: Int,
    usageResetsAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data UsageSnapshot = UsageSnapshot
  { usageWindows :: [UsageWindow],
    usageFetchedAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data Freshness
  = NotLoaded
  | Loading
  | Fresh UTCTime
  | Stale UTCTime Text
  | Unavailable Text
  | Unsupported Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ApprovalMode = ApprovalByLabel | ApprovalByReview | ApprovalByEither
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data BlockingSeverity = SeverityRed | SeverityAmber
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WorkflowConfig = WorkflowConfig
  { approvalLabel :: Text,
    changesRequestedLabel :: Text,
    blockedLabels :: Set Text,
    trackerLabels :: Set Text,
    additionalTrackerSectionHeadings :: [Text],
    approvalMode :: ApprovalMode,
    blockingSeverity :: BlockingSeverity,
    -- | Purely presentational: label names a repository wants tinted like a
    -- problem, and like a UI concern, in the card and details label chips.
    -- Neither carries workflow meaning — nothing reads them for status,
    -- readiness, or ordering — and both default to empty, so a repository
    -- that configures nothing gets ordinary chips rather than an invisible
    -- built-in set of names.
    problemStyleLabels :: Set Text,
    uiStyleLabels :: Set Text,
    -- | Case-sensitive, repository-relative coordination declarations — an
    -- exact file path, or a directory ending in @/@ covering every descendant
    -- by whole path component, never by glob or string prefix — whose content
    -- is coordination rather than code: the PR drainer may merge a candidate
    -- whose only distance from the default branch is a change to covered
    -- paths. Nothing in the dashboard reads them, and they default to empty,
    -- so a repository that configures nothing keeps today's behavior.
    coordinationPaths :: Set Text,
    -- | The separate direct-publication declaration carried by the shared
    -- configuration schema. The dashboard does not publish documents, but it
    -- must accept and preserve this key so every Haskell and Python consumer
    -- resolves the same configuration without spurious unknown-key warnings.
    -- It has the same path grammar and empty default as 'coordinationPaths',
    -- but grants no drainer base-advance exception.
    directPublicationPaths :: Set Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Manual instance so a durable record written before the display-only
-- styling collections or either workflow-path collection existed still
-- decodes: a worker spec persists a whole 'WorkflowConfig' (see
-- 'Kanban.Worker.WorkerSpec'), and a legacy one simply has no opinion about
-- either, which is exactly the empty default.
instance FromJSON WorkflowConfig where
  parseJSON = withObject "WorkflowConfig" $ \object ->
    WorkflowConfig
      <$> object .: "approvalLabel"
      <*> object .: "changesRequestedLabel"
      <*> object .: "blockedLabels"
      <*> object .: "trackerLabels"
      <*> object .: "additionalTrackerSectionHeadings"
      <*> object .: "approvalMode"
      <*> object .: "blockingSeverity"
      <*> object .:? "problemStyleLabels" .!= Set.empty
      <*> object .:? "uiStyleLabels" .!= Set.empty
      <*> object .:? "coordinationPaths" .!= Set.empty
      <*> object .:? "directPublicationPaths" .!= Set.empty

defaultWorkflowConfig :: WorkflowConfig
defaultWorkflowConfig =
  WorkflowConfig
    { approvalLabel = "reviewed:approve",
      changesRequestedLabel = "reviewed:changes",
      blockedLabels = Set.singleton "blocked",
      trackerLabels = Set.singleton "epic",
      additionalTrackerSectionHeadings = [],
      approvalMode = ApprovalByLabel,
      blockingSeverity = SeverityRed,
      problemStyleLabels = Set.empty,
      uiStyleLabels = Set.empty,
      coordinationPaths = Set.empty,
      directPublicationPaths = Set.empty
    }

itemId :: BoardItem -> ItemId
itemId (IssueItem issue) = IssueId issue.issueNumber
itemId (PullRequestItem pullRequest) = PullRequestId pullRequest.pullRequestNumber

itemTitle :: BoardItem -> Text
itemTitle (IssueItem issue) = issue.issueTitle
itemTitle (PullRequestItem pullRequest) = pullRequest.pullRequestTitle

itemLabels :: BoardItem -> [Label]
itemLabels (IssueItem issue) = issue.issueLabels
itemLabels (PullRequestItem pullRequest) = pullRequest.pullRequestLabels

itemLabelOverflow :: BoardItem -> Int
itemLabelOverflow (IssueItem issue) = issue.issueLabelOverflow
itemLabelOverflow (PullRequestItem pullRequest) = pullRequest.pullRequestLabelOverflow

itemCreatedAt :: BoardItem -> UTCTime
itemCreatedAt (IssueItem issue) = issue.issueCreatedAt
itemCreatedAt (PullRequestItem pullRequest) = pullRequest.pullRequestCreatedAt

itemUpdatedAt :: BoardItem -> UTCTime
itemUpdatedAt (IssueItem issue) = issue.issueUpdatedAt
itemUpdatedAt (PullRequestItem pullRequest) = pullRequest.pullRequestUpdatedAt
