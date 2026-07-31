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
    DataGap (..),
    Freshness (..),
    Issue (..),
    ItemId (..),
    Label (..),
    MergeState (..),
    PullRequest (..),
    RepoSnapshot (..),
    Repository (..),
    ReviewDecision (..),
    Tracker (..),
    TrackerChild (..),
    TrackerDiagnostic (..),
    TrackerMembership (..),
    TrackingContext (..),
    UsageProvider (..),
    UsageSnapshot (..),
    UsageWindow (..),
    WorkflowConfig (..),
    defaultWorkflowConfig,
    itemCreatedAt,
    itemId,
    itemLabelOverflow,
    itemLabels,
    itemTitle,
    itemUpdatedAt,
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
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data Issue = Issue
  { issueNumber :: Int,
    issueTitle :: Text,
    issueBody :: Text,
    issueUrl :: Text,
    issueLabels :: [Label],
    issueAssignees :: [Assignee],
    issueCreatedAt :: UTCTime,
    issueUpdatedAt :: UTCTime,
    issueLabelOverflow :: Int,
    issueAssigneeOverflow :: Int,
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

data Tracker = Tracker
  { trackerIssue :: Issue,
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

data RepoSnapshot = RepoSnapshot
  { snapshotIssues :: [Issue],
    snapshotPullRequests :: [PullRequest],
    snapshotFetchedAt :: UTCTime,
    snapshotIssuesTruncated :: Bool,
    snapshotPullRequestsTruncated :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

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
    uiStyleLabels :: Set Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Manual instance so a durable record written before the display-only
-- styling collections existed still decodes — a worker spec persists a whole
-- 'WorkflowConfig' (see 'Kanban.Worker.WorkerSpec'), and a legacy one simply
-- has no opinion about chip styling, which is exactly the empty default.
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
      uiStyleLabels = Set.empty
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
