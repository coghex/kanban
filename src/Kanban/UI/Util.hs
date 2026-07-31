module Kanban.UI.Util
  ( absoluteTime,
    agentFailureNotice,
    allColumns,
    cacheEnabled,
    columnCountText,
    columnName,
    countedSource,
    directMergeNoticeFor,
    directMergeReportAfterRefresh,
    entriesFor,
    entriesForBoard,
    entryPrimaryTrackerNumber,
    failureActivity,
    formatElapsed,
    isDeadlineOutcome,
    itemBody,
    itemHeading,
    itemMetadata,
    itemStatusText,
    mergeText,
    outstandingDirectMergeReport,
    overflowText,
    padLabel,
    primaryTrackerNumber,
    pullRequestActionText,
    pullRequestAgentLabel,
    relativeAge,
    reviewAnimationIntervalMicros,
    rightOrNothing,
    safeIndex,
    safeLast,
    shortSessionId,
    showText,
    timedActivity,
    unknownAssigneesText,
    unknownLinksText,
    workflowTitle,
  )
where


import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (TimeZone, UTCTime, defaultTimeLocale, diffUTCTime, formatTime, utcToZonedTime)
import Kanban.CLI (Options (..))
import Kanban.Config (ResolvedConfig (..) )
import Kanban.Domain
import Kanban.Preflight
  ( preflightDiagnosticDetail
    )
import Kanban.PullRequestFlow
  ( PullRequestAction (..),
    authoredOnOwnBrand
    )
import Kanban.Solve
  ( SolveOutcome (..),
    SolveWorkflow (..),
    SolverBrand (..),
    claudeReviewerModel,
    codexReviewerModel,
    solverLabel
  )
import Kanban.Text (sanitizeText)
import Kanban.Worker
  ( workerDeadlineReason
  )
import Kanban.UI.Types

padLabel :: Text -> Text
padLabel value = value <> Text.replicate (max 0 (7 - Text.length value)) " "

overflowText :: Int -> Text
overflowText count
  | count > 0 = " +" <> showText count
  | otherwise = ""

formatElapsed :: UTCTime -> UTCTime -> Text
formatElapsed now startedAt
  | seconds < 60 = showText seconds <> "s"
  | seconds < 3600 = showText (seconds `div` 60) <> "m " <> twoDigits (seconds `mod` 60) <> "s"
  | otherwise = showText (seconds `div` 3600) <> "h " <> twoDigits ((seconds `div` 60) `mod` 60) <> "m"
  where
    seconds = max 0 (floor (diffUTCTime now startedAt) :: Int)
    twoDigits value
      | value < 10 = "0" <> showText value
      | otherwise = showText value

shortSessionId :: Text -> Text
shortSessionId sessionId
  | Text.length sessionId <= 12 = sessionId
  | otherwise = Text.take 8 sessionId <> "…"

-- | A timestamp in the viewer's own zone, always naming that zone so a bare
-- wall-clock reading is never ambiguous.
absoluteTime :: TimeZone -> UTCTime -> Text
absoluteTime timeZone value =
  Text.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M %Z" (utcToZonedTime timeZone value))

relativeAge :: UTCTime -> UTCTime -> Text
relativeAge now thenTime
  | seconds < 60 = "now"
  | seconds < 3600 = showText (seconds `div` 60) <> "m ago"
  | seconds < 86400 = showText (seconds `div` 3600) <> "h ago"
  | otherwise = showText (seconds `div` 86400) <> "d ago"
  where
    seconds = max 0 (floor (diffUTCTime now thenTime) :: Int)

rightOrNothing :: Either failure value -> Maybe value
rightOrNothing = either (const Nothing) Just

entriesForBoard :: Board -> BoardColumn -> [ColumnEntry]
entriesForBoard board column = Map.findWithDefault [] column board.boardColumns

safeLast :: [value] -> Maybe value
safeLast [] = Nothing
safeLast (value : values) = Just (foldl (\_ next -> next) value values)

safeIndex :: Int -> [value] -> Maybe value
safeIndex index values
  | index < 0 = Nothing
  | otherwise = case drop index values of
      value : _ -> Just value
      [] -> Nothing

allColumns :: [BoardColumn]
allColumns = [minBound .. maxBound]

columnName :: BoardColumn -> Text
columnName Issues = "ISSUES"
columnName Active = "ACTIVE"
columnName Reviewing = "REVIEWING"
columnName Done = "DONE"

showText :: Show value => value -> Text
showText = Text.pack . show

entryPrimaryTrackerNumber :: ColumnEntry -> Maybe Int
entryPrimaryTrackerNumber (Standalone _) = Nothing
entryPrimaryTrackerNumber (Tracked context _) = Just (primaryTrackerNumber context)
entryPrimaryTrackerNumber (TrackerHeader tracker) = Just tracker.trackerIssue.issueNumber

primaryTrackerNumber :: TrackingContext -> Int
primaryTrackerNumber context = context.trackingPrimary.membershipTracker.trackerIssue.issueNumber

workflowTitle :: SolveWorkflow -> Text
workflowTitle SolveOnly = "SOLVE"
workflowTitle AutoSolve = "AUTOSOLVE"

pullRequestActionText :: PullRequestAction -> Text
pullRequestActionText PullRequestReview = "review"
pullRequestActionText PullRequestRevision = "revision"
pullRequestActionText PullRequestRereview = "rereview"
pullRequestActionText PullRequestRepair = "repair"

pullRequestAgentLabel :: PullRequestAction -> SolverBrand -> Text
pullRequestAgentLabel action brand | authoredOnOwnBrand action = solverLabel brand
pullRequestAgentLabel _ CodexSolver = "codex · " <> codexReviewerModel
pullRequestAgentLabel _ ClaudeSolver = "claude · " <> claudeReviewerModel

timedActivity :: UTCTime -> Bool -> UTCTime -> Text -> Text
timedActivity now isLive startedAt activity
  | isLive = activity <> " · " <> formatElapsed now startedAt
  | otherwise = activity

itemHeading :: BoardItem -> Text
itemHeading (IssueItem issue) = "#" <> showText issue.issueNumber <> "  " <> sanitizeText issue.issueTitle
itemHeading (PullRequestItem pullRequest) =
  (if pullRequest.pullRequestDraft then "DRAFT " else "PR ")
    <> "#"
    <> showText pullRequest.pullRequestNumber
    <> "  "
    <> sanitizeText pullRequest.pullRequestTitle

itemBody :: BoardItem -> Text
itemBody (IssueItem issue) = issue.issueBody
itemBody (PullRequestItem pullRequest) = pullRequest.pullRequestBody

itemMetadata :: UTCTime -> BoardItem -> Text
itemMetadata now (IssueItem issue) = ownership <> " · updated " <> relativeAge now issue.issueUpdatedAt
  where
    ownership
      | AssigneesUnavailable `elem` issue.issueDataGaps = unknownAssigneesText
      | null issue.issueAssignees && issue.issueAssigneeOverflow == 0 = "unassigned"
      | otherwise =
          Text.intercalate ", " ["@" <> assignee.assigneeLogin | assignee <- issue.issueAssignees]
            <> overflowText issue.issueAssigneeOverflow
itemMetadata now (PullRequestItem pullRequest) =
  linked <> pullRequest.pullRequestAuthor <> " → " <> pullRequest.pullRequestBase <> " · updated " <> relativeAge now pullRequest.pullRequestUpdatedAt
  where
    linked
      | LinkedIssuesUnavailable `elem` pullRequest.pullRequestDataGaps = unknownLinksText <> " · "
      | otherwise = case pullRequest.pullRequestLinkedIssues of
          []
            | pullRequest.pullRequestLinkedIssueOverflow > 0 -> "+" <> showText pullRequest.pullRequestLinkedIssueOverflow <> " linked · "
            | otherwise -> "UNLINKED · "
          numbers ->
            let visibleNumbers = take 2 numbers
                hiddenNumbers = max 0 (length numbers - length visibleNumbers) + pullRequest.pullRequestLinkedIssueOverflow
             in Text.intercalate "," (map (("#" <>) . showText) visibleNumbers) <> overflowText hiddenNumbers <> " · "

itemStatusText :: BoardItem -> Text
itemStatusText (IssueItem _) = ""
itemStatusText (PullRequestItem pullRequest) =
  checkText pullRequest.pullRequestChecks <> " · " <> mergeText pullRequest.pullRequestMergeState

checkText :: CheckSummary -> Text
checkText ChecksNone = "no CI"
checkText (ChecksPending passed total _) = "◐ CI " <> showText passed <> "/" <> showText total
checkText (ChecksPassed total) = "✓ CI " <> showText total <> "/" <> showText total
checkText (ChecksFailed passed total _) = "× CI " <> showText passed <> "/" <> showText total
checkText ChecksUnknown = "? CI unknown"

mergeText :: MergeState -> Text
mergeText MergeClean = "clean"
mergeText MergeBehind = "behind"
mergeText MergeBlocked = "blocked"
mergeText MergeProtected = "protected"
mergeText MergeConflicting = "merge conflict"
mergeText MergeUnstable = "unstable"
mergeText MergeUnknown = "calculating"

-- | What a card says instead of a definite \"unassigned\" or \"UNLINKED\" when
-- GitHub never delivered the connection those verdicts would be read off. The
-- board must not turn an absent field into a claim about the item.
unknownAssigneesText, unknownLinksText :: Text
unknownAssigneesText = "assignees unknown"
unknownLinksText = "LINKS UNKNOWN"

columnCountText :: AppState -> BoardColumn -> Text
columnCountText state column =
  showText (length (entriesFor state column)) <> if columnMayBeTruncated then "+" else ""
  where
    columnMayBeTruncated = case column of
      Issues -> state.appIssuesTruncated
      Active -> state.appIssuesTruncated
      Reviewing -> state.appPullRequestsTruncated
      Done -> state.appPullRequestsTruncated

countedSource :: Text -> Int -> Bool -> Text
countedSource noun count truncated =
  showText count <> (if truncated then "+" else "") <> " " <> noun <> if count == 1 then "" else "s"

entriesFor :: AppState -> BoardColumn -> [ColumnEntry]
entriesFor state column = Map.findWithDefault [] column state.appBoard.boardColumns

-- | The report still worth carrying, given what is on screen now: 'Nothing'
-- once anything has replaced or cleared the notice this last wrote.
outstandingDirectMergeReport :: Maybe Text -> Maybe DirectMergeReport -> Maybe DirectMergeReport
outstandingDirectMergeReport displayed report = do
  candidate <- report
  if displayed == Just candidate.directMergeReportShown then Just candidate else Nothing

-- | A notice with an outstanding result kept in front of it, and the report
-- to carry forward -- which records this very notice, so the next question
-- about whether it is still displayed has something exact to compare with.
directMergeNoticeFor :: Maybe DirectMergeReport -> Text -> (Text, Maybe DirectMergeReport)
directMergeNoticeFor Nothing notice = (notice, Nothing)
directMergeNoticeFor (Just report) notice =
  let composed = report.directMergeReportResult <> " · " <> notice
   in (composed, Just report {directMergeReportShown = composed})

-- | The report to carry past a refresh that has just published. Dropped once
-- the refresh the merge required has actually run, and kept while that
-- refresh is still only queued -- otherwise the fetch that merely happened to
-- be in flight would carry the result away before the required one had even
-- started.
directMergeReportAfterRefresh :: Bool -> Maybe DirectMergeReport -> Maybe DirectMergeReport
directMergeReportAfterRefresh queued carried = if queued then carried else Nothing

cacheEnabled :: Options -> ResolvedConfig -> Bool
cacheEnabled options config = not options.optionNoCache && config.resolvedCache

-- | The activity text for a terminal or pending 'SolveFailed' outcome,
-- distinguishing the persistent-worker deadline and a preflight-detected
-- setup gap from a generic provider failure, so the process inspector and
-- session/card projection never collapse them.
failureActivity :: Text -> Text
failureActivity message
  | isDeadlineOutcome (SolveFailed message) = "deadline exceeded"
  | isJust (preflightDiagnosticDetail message) = "setup required"
  | otherwise = "failed"

-- | How a terminal agent failure is announced. A preflight diagnostic means
-- the agent never ran: naming the missing component and its install command
-- is the whole point, so it must not be reported as another opaque failure.
agentFailureNotice :: Text -> Text -> Text
agentFailureNotice subject message = case preflightDiagnosticDetail message of
  Just remediation -> subject <> " cannot start — " <> sanitizeText remediation
  Nothing -> subject <> " failed: " <> sanitizeText message

reviewAnimationIntervalMicros :: Int
reviewAnimationIntervalMicros = 100 * 1000

isDeadlineOutcome :: SolveOutcome -> Bool
isDeadlineOutcome (SolveFailed message) = message == workerDeadlineReason
isDeadlineOutcome _ = False
