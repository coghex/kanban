{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

module Kanban.Domain
  ( ApprovalMode (..),
    Assignee (..),
    Board (..),
    BoardColumn (..),
    BoardItem (..),
    CheckSummary (..),
    ColumnEntry (..),
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
    TrackerMembership (..),
    TrackingContext (..),
    UsageProvider (..),
    UsageSnapshot (..),
    UsageWindow (..),
    WorkflowConfig (..),
    defaultWorkflowConfig,
    itemCreatedAt,
    itemId,
    itemLabels,
    itemTitle,
  )
where

import Data.Aeson (FromJSON, FromJSONKey, ToJSON, ToJSONKey)
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

data Issue = Issue
  { issueNumber :: Int,
    issueTitle :: Text,
    issueBody :: Text,
    issueUrl :: Text,
    issueLabels :: [Label],
    issueAssignees :: [Assignee],
    issueCreatedAt :: UTCTime,
    issueUpdatedAt :: UTCTime
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
  | MergeConflicting
  | MergeUnstable
  | MergeUnknown
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data CheckSummary
  = ChecksNone
  | ChecksPending Int Int
  | ChecksPassed Int
  | ChecksFailed Int Int
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
    pullRequestUpdatedAt :: UTCTime
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
    trackerChildren :: Map Int TrackerChild
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
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype Board = Board {boardColumns :: Map BoardColumn [ColumnEntry]}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data RepoSnapshot = RepoSnapshot
  { snapshotIssues :: [Issue],
    snapshotPullRequests :: [PullRequest],
    snapshotFetchedAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data UsageProvider = Codex | Claude
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

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

data WorkflowConfig = WorkflowConfig
  { approvalLabel :: Text,
    changesRequestedLabel :: Text,
    blockedLabels :: Set Text,
    trackerLabels :: Set Text,
    approvalMode :: ApprovalMode
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

defaultWorkflowConfig :: WorkflowConfig
defaultWorkflowConfig =
  WorkflowConfig
    { approvalLabel = "reviewed:approve",
      changesRequestedLabel = "reviewed:changes",
      blockedLabels = Set.singleton "blocked",
      trackerLabels = Set.singleton "epic",
      approvalMode = ApprovalByLabel
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

itemCreatedAt :: BoardItem -> UTCTime
itemCreatedAt (IssueItem issue) = issue.issueCreatedAt
itemCreatedAt (PullRequestItem pullRequest) = pullRequest.pullRequestCreatedAt
