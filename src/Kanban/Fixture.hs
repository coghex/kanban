module Kanban.Fixture
  ( fixtureBoard,
    fixtureCompletedHistory,
    fixtureSnapshot,
    fixtureUsage,
  )
where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Kanban.Domain
import Kanban.Workflow (deriveBoard)

fixtureBoard :: Board
fixtureBoard = deriveBoard defaultWorkflowConfig fixtureSnapshot

fixtureUsage :: Map UsageProvider UsageSnapshot
fixtureUsage =
  Map.fromList
    [ ( Codex,
        UsageSnapshot
          { usageWindows =
              [ UsageWindow "5 hour" 63 (at 16 5),
                UsageWindow "week" 41 (onDay 21 9 0)
              ],
            usageFetchedAt = at 12 0
          }
      ),
      ( Claude,
        UsageSnapshot
          { usageWindows =
              [ UsageWindow "5 hour" 78 (at 17 30),
                UsageWindow "week" 22 (onDay 18 9 10)
              ],
            usageFetchedAt = at 12 0
          }
      )
    ]

fixtureSnapshot :: RepoSnapshot
fixtureSnapshot =
  RepoSnapshot
    { snapshotIssues =
        [ -- Two trackers, so a board drawn from this snapshot can show an
          -- expanded one beside a collapsed one. Their children are their
          -- own, which keeps every card above standalone.
          tracker 700 "Persistence contract rollout" ["[x] #711 — A1: Save envelope", "[ ] #712 — A2: Cache reader"],
          tracker 701 "Input routing hardening" ["[ ] #721 — B1: Pointer capture"],
          issue 711 "Adopt the versioned save envelope" "Write the envelope header ahead of the payload so a partial write is detectable on load." [label "feature" "a2eeef"] [],
          issue 712 "Migrate the terrain cache reader" "Read through the envelope and reject a payload whose recorded length disagrees with the file." [label "code-health" "1d76db"] [Assignee "codex-agent"],
          issue 721 "Probe pointer capture ownership" "Record which layer owns the pointer before the overlay opens, so release restores it." [label "ui" "5319e7"] [],
          issue 901 "Add repository snapshot cache" "Load the last good GitHub snapshot at startup and replace it atomically after a successful explicit refresh." [label "feature" "a2eeef"] [],
          issue 812 "Modal input leaks through overlay" "Empty modal areas currently allow pointer events to reach lower pages. This is visible when a dialog overlaps the world." [label "reviewed:approve" "2f9e44", label "bug" "d73a4a", label "ui" "5319e7"] [],
          issue 756 "Define the persistence contract" "Document root owners, snapshot barriers, and the versioned envelope before implementation begins." [label "architecture" "0e8a16"] [],
          issue 799 "Repair stale world cache invalidation" "A stale cache survives a save reload and exposes old terrain data to the renderer." [label "blocked" "b60205", label "bug" "d73a4a"] [Assignee "codex-agent"],
          issue 833 "Improve notification category defaults" "Make the fresh-install behavior explicit and keep local state outside the tracked template." [label "code-health" "1d76db"] [Assignee "claude-agent"]
        ],
      snapshotPullRequests =
        [ pullRequest 823 "Fix modal scroll routing" "Routes Shift-wheel through the same modal-aware ownership path as ordinary wheel events." [label "reviewed:approve" "2f9e44", label "input" "0075ca", label "ui" "5319e7"] False [812] ReviewApproved MergeClean (ChecksPassed 14),
          pullRequest 841 "Split the input dispatch facade" "Moves per-domain dispatch into small modules while preserving the public facade." [label "refactor" "c5def5"] False [833] ReviewRequired MergeBehind (ChecksPending 12 14 [CheckDetail "integration-suite" CheckPending, CheckDetail "docs-lint" CheckPending]),
          pullRequest 847 "Prototype native sub-issue import" "An early draft of the native GitHub sub-issue membership adapter." [label "experimental" "fbca04"] True [756] ReviewUnknown MergeUnknown ChecksUnknown,
          pullRequest 851 "Resolve save envelope conflict" "Updates the branch after the persistence registry changed on master." [label "reviewed:approve" "2f9e44"] False [] ReviewApproved MergeConflicting (ChecksPassed 12),
          -- Approved but not yet mergeable, which is the amber readiness the
          -- three-color spread would otherwise be missing: 823 is green, 851
          -- is red, and nothing else here is pending.
          pullRequest 861 "Adopt the envelope in the snapshot loader" "Reads the cache through the versioned envelope and reports a truncated payload." [label "reviewed:approve" "2f9e44", label "feature" "a2eeef"] False [901] ReviewApproved MergeBehind (ChecksPending 9 12 [CheckDetail "integration-suite" CheckPending])
        ],
      snapshotFetchedAt = at 12 0
    }

-- | The settled half of the invented repository: closed issues and pull
-- requests that are closed and merged, so a frame drawn with @Closed@ checked
-- shows both kinds and both pull-request badges.
--
-- Nothing here appears in 'fixtureSnapshot'. The two generations are
-- reconciled against each other at publication (§15), so an item in both sets
-- is a state the board never reaches and would make every count drawn from
-- this fixture ambiguous.
fixtureCompletedHistory :: CompletedHistory
fixtureCompletedHistory =
  CompletedHistory
    { historyIssues =
        [ (issue 655 "Retire the legacy snapshot writer" "The pre-envelope writer is unreachable now that every reader goes through the header." [label "code-health" "1d76db"] []) {issueState = IssueClosed},
          (issue 690 "Drop the pointer capture probe harness" "The temporary harness outlived the investigation it was written for." [label "ui" "5319e7"] []) {issueState = IssueClosed}
        ],
      historyPullRequests =
        [ (pullRequest 705 "Retire the legacy snapshot writer" "Removes the writer and the two call sites that still reached it." [label "code-health" "1d76db"] False [655] ReviewApproved MergeClean (ChecksPassed 14)) {pullRequestState = PullRequestMerged},
          (pullRequest 688 "Spike: pointer capture ownership" "Abandoned in favour of recording ownership before the overlay opens." [label "experimental" "fbca04"] False [690] ReviewUnknown MergeUnknown ChecksUnknown) {pullRequestState = PullRequestClosed}
        ],
      historyFetchedAt = at 12 0
    }

-- | A tracker issue: the @epic@ label 'defaultWorkflowConfig' recognizes, and
-- a checklist section in the shape 'Kanban.Tracker.trackerFromIssue' parses.
tracker :: Int -> Text -> [Text] -> Issue
tracker number title children =
  issue number title (Data.Text.unlines ("## Children" : ["- " <> child | child <- children])) [label "epic" "5319e7"] []

issue :: Int -> Text -> Text -> [Label] -> [Assignee] -> Issue
issue number title body labels assignees =
  Issue
    { issueNumber = number,
      issueTitle = title,
      issueBody = body,
      issueUrl = "https://example.test/issues/" <> showText number,
      issueState = IssueOpen,
      issueLabels = labels,
      issueAssignees = assignees,
      issueCreatedAt = onDay (number `mod` 12 + 1) 9 0,
      issueUpdatedAt = at 10 (number `mod` 60),
      issueLabelOverflow = 0,
      issueAssigneeOverflow = 0,
      issueSubIssues = SubIssuesNotRequested,
      issueDataGaps = []
    }

pullRequest :: Int -> Text -> Text -> [Label] -> Bool -> [Int] -> ReviewDecision -> MergeState -> CheckSummary -> PullRequest
pullRequest number title body labels draft linkedIssues review mergeState checks =
  PullRequest
    { pullRequestNumber = number,
      pullRequestTitle = title,
      pullRequestBody = body,
      pullRequestUrl = "https://example.test/pull/" <> showText number,
      pullRequestState = PullRequestOpen,
      pullRequestLabels = labels,
      pullRequestAuthor = "agent-name",
      pullRequestDraft = draft,
      pullRequestBase = "master",
      pullRequestHead = "work/issue-" <> showText number,
      pullRequestLinkedIssues = linkedIssues,
      pullRequestReviewDecision = review,
      pullRequestMergeState = mergeState,
      pullRequestChecks = checks,
      pullRequestCreatedAt = onDay (number `mod` 12 + 1) 10 0,
      pullRequestUpdatedAt = at 11 (number `mod` 60),
      pullRequestLabelOverflow = 0,
      pullRequestLinkedIssueOverflow = 0,
      pullRequestDataGaps = []
    }

label :: Text -> Text -> Label
label = Label

at :: Int -> Int -> UTCTime
at = onDay 16

onDay :: Int -> Int -> Int -> UTCTime
onDay day hour minute =
  UTCTime (fromGregorian 2026 7 day) (secondsToDiffTime (fromIntegral (hour * 3600 + minute * 60)))

showText :: Show value => value -> Text
showText = Data.Text.pack . show
