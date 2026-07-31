-- | Pure board, issue, pull request and configuration fixtures.
module Spec.Support.Fixtures
  ( epoch,
    showText,
    baseIssue,
    basePullRequest,
    zeroChildTracker,
    zeroChildDiagnostics,
    isTrackerHeaderEntry,
    fixtureTracker,
    fixtureMembership,
    fixtureTrackedEntry,
    fixtureStandaloneEntry,
    fixtureBoard,
    itemNumber,
    isStandaloneIssue,
    entryImplementationKey,
    cardFixtureIssue,
    cardFixtureEntry,
    cardFixtureTrackedEntry,
    cardFixtureLongKeyTrackedEntry,
    cardFixtureDiagnosticEntry,
    cardFixturePullRequestEntry,
    detailsFixturePullRequest,
    detailsFixtureIssue,
    detailsFixtureUpdatedAt,
    detailsFixtureBoard,
    testOptions,
    testResolvedConfig,
    fullFixtureToml
  )
where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Kanban.CLI (BorderPolicy (..), ColorPolicy (..), Options (..))
import Kanban.Config
import Kanban.Domain
import Kanban.Workflow (deriveBoard)

baseIssue :: Int -> [Assignee] -> Issue
baseIssue number assignees =
  Issue number ("Issue " <> showText number) "Body" "https://example.test" [] assignees epoch epoch 0 0 []

-- | A tracker whose child section is recognized but yields nothing usable:
-- its single row is malformed, so it is diagnosed and dropped. The tracker
-- reaches 'deriveBoard' with zero children without depending on any parser
-- defect, and #3 stays an ordinary issue.
zeroChildTracker :: Issue
zeroChildTracker =
  (baseIssue 12 [])
    { issueLabels = [Label "epic" "5319e7"],
      issueBody = "## Children\n- [?] #3 — A1: Malformed"
    }

-- | Row-level diagnostics first, then the section-level verdict, exactly as
-- 'parseTrackerBody' orders them.
zeroChildDiagnostics :: [TrackerDiagnostic]
zeroChildDiagnostics = [TrackerMalformedCheckbox 2, TrackerChildrenMissing]

isTrackerHeaderEntry :: ColumnEntry -> Bool
isTrackerHeaderEntry (TrackerHeader _) = True
isTrackerHeaderEntry _ = False

fixtureTracker :: Int -> Tracker
fixtureTracker number = Tracker (baseIssue number []) 0 0 Map.empty []

fixtureMembership :: Int -> Int -> TrackerMembership
fixtureMembership trackerNumber childNumber = TrackerMembership (fixtureTracker trackerNumber) (TrackerChild childNumber Nothing 0 False)

-- | A tracked entry whose primary tracker is 'primaryTrackerNumber'; any
-- 'additionalTrackerNumbers' become its secondary (non-primary) memberships.
fixtureTrackedEntry :: Int -> [Int] -> Int -> ColumnEntry
fixtureTrackedEntry primaryTrackerNumber additionalTrackerNumbers childNumber =
  Tracked
    (TrackingContext (fixtureMembership primaryTrackerNumber childNumber) (map (`fixtureMembership` childNumber) additionalTrackerNumbers))
    (IssueItem (baseIssue childNumber []))

fixtureStandaloneEntry :: Int -> ColumnEntry
fixtureStandaloneEntry number = Standalone (IssueItem (baseIssue number []))

fixtureBoard :: [(BoardColumn, [ColumnEntry])] -> Board
fixtureBoard populated = Board (Map.fromList ([(column, []) | column <- [minBound .. maxBound]] <> populated))

basePullRequest :: Int -> [Int] -> Bool -> [Label] -> PullRequest
basePullRequest number linked draft labels =
  PullRequest
    number
    ("PR " <> showText number)
    "Body"
    "https://example.test"
    labels
    "agent"
    draft
    "master"
    "branch"
    linked
    ReviewRequired
    MergeUnknown
    ChecksUnknown
    epoch
    epoch
    0
    0
    []

itemNumber :: BoardItem -> Int
itemNumber (IssueItem issue) = issue.issueNumber
itemNumber (PullRequestItem pullRequest) = pullRequest.pullRequestNumber

isStandaloneIssue :: Int -> ColumnEntry -> Bool
isStandaloneIssue expectedNumber (Standalone (IssueItem issue)) = issue.issueNumber == expectedNumber
isStandaloneIssue _ _ = False

entryImplementationKey :: ColumnEntry -> Maybe Text
entryImplementationKey (Tracked trackingContext _) = trackingContext.trackingPrimary.membershipChild.trackerChildImplementationKey
entryImplementationKey (Standalone _) = Nothing
entryImplementationKey (TrackerHeader _) = Nothing

showText :: Show value => value -> Text
showText = Data.Text.pack . show

epoch :: UTCTime
epoch = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)

-- | An issue that exercises every §11 element at once: a title too long for
-- one row, more labels than two rows can hold plus GitHub-reported overflow,
-- an assignee, and a body far longer than the excerpt budget.
cardFixtureIssue :: Issue
cardFixtureIssue =
  Issue
    { issueNumber = 812,
      issueTitle = "Modal input leaks through the overlay and reaches the board beneath it",
      issueBody =
        "Empty modal areas currently allow pointer events to reach lower pages, which is "
          <> "visible whenever a dialog overlaps the world and the reviewer scrolls the board.",
      issueUrl = "https://example.test/issues/812",
      issueLabels =
        [ Label "ui" "5319e7",
          Label "bug" "d73a4a",
          Label "reviewed:approve" "2f9e44",
          Label "input" "0075ca",
          Label "code-health" "1d76db",
          Label "architecture" "0e8a16"
        ],
      issueAssignees = [Assignee "claude-agent"],
      issueCreatedAt = epoch,
      issueUpdatedAt = epoch,
      issueLabelOverflow = 2,
      issueAssigneeOverflow = 0,
      issueDataGaps = []
    }

cardFixtureEntry :: ColumnEntry
cardFixtureEntry = Standalone (IssueItem cardFixtureIssue)

-- | The same issue as a tracked child of two trackers, which adds the
-- tracker-context row above the title.
cardFixtureTrackedEntry :: ColumnEntry
cardFixtureTrackedEntry =
  Tracked
    (TrackingContext (TrackerMembership (fixtureTracker 700) (TrackerChild 812 (Just "F2") 1 False)) [fixtureMembership 701 812])
    (IssueItem cardFixtureIssue)

-- | A tracked child whose implementation key alone outgrows a narrow card, so
-- the tracker reference has to wrap rather than lose its tail.
cardFixtureLongKeyTrackedEntry :: ColumnEntry
cardFixtureLongKeyTrackedEntry =
  Tracked
    (TrackingContext (TrackerMembership (fixtureTracker 700) (TrackerChild 812 (Just "phase-two-renderer-contract") 1 False)) [])
    (IssueItem (baseIssue 812 []))

-- | A tracker whose checklist is malformed three separate ways, so the card
-- has more than one diagnostic to keep visible.
cardFixtureDiagnosticEntry :: ColumnEntry
cardFixtureDiagnosticEntry =
  Standalone
    ( IssueItem
        (baseIssue 900 [])
          { issueLabels = [Label "epic" "5319e7"],
            issueBody = "## Children\n- [ ] #2 — A1: Valid\n- [ ] missing reference\n- [?] #3\n- [x] #2 — duplicate"
          }
    )

-- | A pull request, which carries the CI/merge status row cards must keep.
cardFixturePullRequestEntry :: ColumnEntry
cardFixturePullRequestEntry =
  Standalone
    ( PullRequestItem
        (basePullRequest 823 [812] False [Label "reviewed:approve" "2f9e44", Label "input" "0075ca"])
          { pullRequestTitle = "Route Shift-wheel through the modal-aware ownership path",
            pullRequestBody = "Routes Shift-wheel through the same modal-aware ownership path as ordinary wheel events.",
            pullRequestChecks = ChecksPassed 14,
            pullRequestMergeState = MergeClean,
            pullRequestReviewDecision = ReviewApproved
          }
    )

-- | A pull request carrying every §11 field at once: a head and base that
-- differ, more linked issues than GitHub returned, a behind branch, and a
-- rollup with both a failure and a still-running check.
detailsFixturePullRequest :: PullRequest
detailsFixturePullRequest =
  (basePullRequest 823 [36, 812] False [Label "reviewed:approve" "2f9e44", Label "input" "0075ca"])
    { pullRequestTitle = "Route Shift-wheel through the modal-aware path",
      pullRequestBody = "Routes Shift-wheel through the modal-aware ownership path.",
      pullRequestUrl = "https://example.test/pull/823",
      pullRequestBase = "master",
      pullRequestHead = "issue-36-details",
      pullRequestMergeState = MergeBehind,
      pullRequestChecks =
        ChecksFailed 9 12 [CheckDetail "integration-suite" CheckFailed, CheckDetail "docs-lint" CheckPending],
      pullRequestLabelOverflow = 2,
      pullRequestLinkedIssueOverflow = 3,
      pullRequestCreatedAt = epoch,
      pullRequestUpdatedAt = detailsFixtureUpdatedAt
    }

-- | The issue side of the same contract: retained assignees plus overflow,
-- tracker membership, and pull requests that link back to it.
detailsFixtureIssue :: Issue
detailsFixtureIssue =
  (baseIssue 36 [Assignee "worker", Assignee "second"])
    { issueTitle = "Details overlay omits most required fields",
      issueBody = "The overlay renders only a subset of the fields the design requires.",
      issueUrl = "https://example.test/issues/36",
      issueLabels = [Label "bug" "d73a4a"],
      issueAssigneeOverflow = 1,
      issueCreatedAt = epoch,
      issueUpdatedAt = detailsFixtureUpdatedAt
    }

detailsFixtureUpdatedAt :: UTCTime
detailsFixtureUpdatedAt = addUTCTime 86400 epoch

-- | A board holding both fixtures, a tracker that owns the issue, and a
-- second pull request linking the same issue, so the reverse-link derivation
-- has more than one PR to find.
detailsFixtureBoard :: Board
detailsFixtureBoard =
  deriveBoard
    defaultWorkflowConfig
    ( RepoSnapshot
        [ (baseIssue 900 [])
            { issueLabels = [Label "epic" "5319e7"],
              issueBody = "## Children\n- [ ] #36 — A1: Details overlay fields"
            },
          detailsFixtureIssue
        ]
        [detailsFixturePullRequest, basePullRequest 851 [36] False []]
        epoch
        False
        False
    )

testOptions :: Options
testOptions =
  Options
    { optionPath = ".",
      optionRepo = Nothing,
      optionColor = ColorAuto,
      optionBorder = BorderBox,
      optionGlyphTest = False,
      optionDoctor = False,
      optionAscii = False,
      optionNoCache = False,
      optionConfig = Nothing,
      optionWorkerSpec = Nothing
    }

testResolvedConfig :: ResolvedConfig
testResolvedConfig =
  ResolvedConfig
    { resolvedCache = True,
      resolvedRemoteName = "origin",
      resolvedWorkflow = defaultWorkflowConfig,
      resolvedLimits = defaultLimitsConfig,
      resolvedTimeouts = defaultTimeoutsConfig,
      resolvedUsage = defaultUsageConfig
    }

fullFixtureToml :: Text
fullFixtureToml =
  "cache = false\n"
    <> "remote_name = \"upstream\"\n"
    <> "\n"
    <> "[workflow]\n"
    <> "approval_label = \"lgtm\"\n"
    <> "changes_requested_label = \"needs-work\"\n"
    <> "blocked_labels = [\"blocked\", \"urgent\"]\n"
    <> "tracker_labels = [\"epic\", \"tracker\"]\n"
    <> "additional_tracker_section_headings = [\"Milestones\"]\n"
    <> "approval_mode = \"either\"\n"
    <> "blocking_severity = \"amber\"\n"
    <> "problem_style_labels = [\"defect\"]\n"
    <> "ui_style_labels = [\"interface\", \"input\"]\n"
    <> "\n"
    <> "[limits]\n"
    <> "max_open_issues = 500\n"
    <> "max_open_pull_requests = 200\n"
    <> "excerpt_lines = 5\n"
    <> "\n"
    <> "[timeouts]\n"
    <> "github_seconds = 60\n"
    <> "codex_seconds = 20\n"
    <> "claude_seconds = 90\n"
    <> "\n"
    <> "[usage.codex]\n"
    <> "command = [\"/usr/local/bin/my-codex-usage\", \"--json\"]\n"
    <> "\n"
    <> "[usage.claude]\n"
    <> "command = [\"/usr/local/bin/my-claude-usage\", \"--json\"]\n"
    <> "\n"
    <> "unknown_top_level_key = 1\n"
    <> "\n"
    <> "[repositories.\"coghex/kanban\".workflow]\n"
    <> "approval_label = \"ship-it\"\n"
    <> "\n"
    <> "[repositories.\"coghex/kanban\".limits]\n"
    <> "max_open_issues = 999\n"
    <> "\n"
    <> "[repositories.\"coghex/kanban\".timeouts]\n"
    <> "github_seconds = 15\n"
    <> "\n"
    <> "[repositories.\"other/repo\".workflow]\n"
    <> "approval_label = \"should-not-apply\"\n"
