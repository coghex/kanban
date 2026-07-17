module Kanban.Fixture
  ( fixtureBoard,
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
        [ issue 901 "Add repository snapshot cache" "Load the last good GitHub snapshot at startup and replace it atomically after a successful explicit refresh." [label "feature" "a2eeef"] [],
          issue 812 "Modal input leaks through overlay" "Empty modal areas currently allow pointer events to reach lower pages. This is visible when a dialog overlaps the world." [label "reviewed:approve" "2f9e44", label "bug" "d73a4a", label "ui" "5319e7"] [],
          issue 756 "Define the persistence contract" "Document root owners, snapshot barriers, and the versioned envelope before implementation begins." [label "architecture" "0e8a16"] [],
          issue 799 "Repair stale world cache invalidation" "A stale cache survives a save reload and exposes old terrain data to the renderer." [label "blocked" "b60205", label "bug" "d73a4a"] [Assignee "codex-agent"],
          issue 833 "Improve notification category defaults" "Make the fresh-install behavior explicit and keep local state outside the tracked template." [label "code-health" "1d76db"] [Assignee "claude-agent"]
        ],
      snapshotPullRequests =
        [ pullRequest 823 "Fix modal scroll routing" "Routes Shift-wheel through the same modal-aware ownership path as ordinary wheel events." [label "reviewed:approve" "2f9e44", label "input" "0075ca", label "ui" "5319e7"] False [812] ReviewApproved MergeClean (ChecksPassed 14),
          pullRequest 841 "Split the input dispatch facade" "Moves per-domain dispatch into small modules while preserving the public facade." [label "refactor" "c5def5"] False [833] ReviewRequired MergeBehind (ChecksPending 9 14),
          pullRequest 847 "Prototype native sub-issue import" "An early draft of the native GitHub sub-issue membership adapter." [label "experimental" "fbca04"] True [756] ReviewUnknown MergeUnknown ChecksUnknown,
          pullRequest 851 "Resolve save envelope conflict" "Updates the branch after the persistence registry changed on master." [label "reviewed:approve" "2f9e44"] False [] ReviewApproved MergeConflicting (ChecksPassed 12)
        ],
      snapshotFetchedAt = at 12 0,
      snapshotIssuesTruncated = False,
      snapshotPullRequestsTruncated = False
    }

issue :: Int -> Text -> Text -> [Label] -> [Assignee] -> Issue
issue number title body labels assignees =
  Issue
    { issueNumber = number,
      issueTitle = title,
      issueBody = body,
      issueUrl = "https://github.com/coghex/synarchy/issues/" <> showText number,
      issueLabels = labels,
      issueAssignees = assignees,
      issueCreatedAt = onDay (number `mod` 12 + 1) 9 0,
      issueUpdatedAt = at 10 (number `mod` 60),
      issueLabelOverflow = 0,
      issueAssigneeOverflow = 0
    }

pullRequest :: Int -> Text -> Text -> [Label] -> Bool -> [Int] -> ReviewDecision -> MergeState -> CheckSummary -> PullRequest
pullRequest number title body labels draft linkedIssues review mergeState checks =
  PullRequest
    { pullRequestNumber = number,
      pullRequestTitle = title,
      pullRequestBody = body,
      pullRequestUrl = "https://github.com/coghex/synarchy/pull/" <> showText number,
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
      pullRequestLinkedIssueOverflow = 0
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
