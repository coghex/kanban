-- | The refresh banner's account of what a snapshot is missing: truncated
-- board limits, nested connections GitHub omitted, malformed tracker
-- checklists, and cards that arrived with incomplete data.
--
-- This reads a finished 'RepoSnapshot' and nothing else, which is why it is
-- not part of the fetch: the board asks the same question of a snapshot
-- restored from the last-good cache, which was never fetched in this run.
module Kanban.GitHub.Warnings
  ( snapshotWarnings,
  )
where

import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Config (LimitsConfig (..))
import Kanban.Domain
import Kanban.Tracker (trackerDiagnosticsForIssue)

snapshotWarnings :: LimitsConfig -> WorkflowConfig -> RepoSnapshot -> [Text]
snapshotWarnings limits workflowConfig snapshot =
  [showText limits.limitsMaxOpenIssues <> "+ open issues; board is truncated" | snapshot.snapshotIssuesTruncated]
    <> [showText limits.limitsMaxOpenPullRequests <> "+ open pull requests; board is truncated" | snapshot.snapshotPullRequestsTruncated]
    <> [ nestedCountText nestedOverflowItems
           <> " contain truncated labels, assignees, or linked issues; +N markers show omitted values"
       | nestedOverflowItems > 0
       ]
    <> [ trackerCountText malformedTrackers
           <> " have malformed or missing child checklists; amber diagnostics show the cause"
       | malformedTrackers > 0
       ]
    <> [incompleteText incompleteItems | not (null incompleteItems)]
  where
    -- Named rather than counted: the amber marker on a degraded card says
    -- something is missing, and this is what says which card. The banner is a
    -- single line, so past a few names it counts the rest with the same +N
    -- vocabulary the overflow indicators use -- visibly truncated, never
    -- silently.
    incompleteItems =
      [ "Issue #" <> showText issue.issueNumber
        | issue <- snapshot.snapshotIssues,
          not (null issue.issueDataGaps)
      ]
        <> [ "PR #" <> showText pullRequest.pullRequestNumber
             | pullRequest <- snapshot.snapshotPullRequests,
               not (null pullRequest.pullRequestDataGaps)
           ]
    incompleteText names =
      Text.intercalate ", " (take incompleteNameLimit names)
        <> (if length names > incompleteNameLimit then " +" <> showText (length names - incompleteNameLimit) <> " more" else "")
        <> ": incomplete data; GitHub did not deliver every field, and the amber cards show which"
    incompleteNameLimit = 3 :: Int
    nestedOverflowItems =
      length (filter issueHasOverflow snapshot.snapshotIssues)
        + length (filter pullRequestHasOverflow snapshot.snapshotPullRequests)
    issueHasOverflow issue = issue.issueLabelOverflow > 0 || issue.issueAssigneeOverflow > 0
    pullRequestHasOverflow pullRequest = pullRequest.pullRequestLabelOverflow > 0 || pullRequest.pullRequestLinkedIssueOverflow > 0
    malformedTrackers =
      length
        ( filter
            (not . null . trackerDiagnosticsForIssue workflowConfig)
            snapshot.snapshotIssues
        )
    nestedCountText 1 = "1 card"
    nestedCountText count = showText count <> " cards"
    trackerCountText 1 = "1 tracker"
    trackerCountText count = showText count <> " trackers"

showText :: Show value => value -> Text
showText = Text.pack . show
