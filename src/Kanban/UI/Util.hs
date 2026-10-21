module Kanban.UI.Util
  ( absoluteTime,
    allColumns,
    cacheEnabled,
    columnName,
    countedSource,
    entriesForBoard,
    entryPrimaryTrackerNumber,
    itemBody,
    itemHeading,
    itemMetadata,
    itemStatusText,
    itemUrl,
    mergeText,
    noticeActivityLive,
    noticeCleared,
    noticeExpiryApplied,
    noticeSet,
    noticeSetFor,
    noticeSetOverStartupReport,
    outstandingStartupReport,
    overflowText,
    recordStartupShown,
    settleNoticeLifecycle,
    shownNotice,
    startupReportApplied,
    primaryTrackerNumber,
    relativeAge,
    safeIndex,
    safeLast,
    selectedRow,
    showText,
    unknownAssigneesText,
    unknownLinksText,
  )
where

import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (TimeZone, UTCTime, defaultTimeLocale, diffUTCTime, formatTime, utcToZonedTime)
import Kanban.Config (cacheEnabled)
import Kanban.Domain
import Kanban.Text (sanitizeText)
import Kanban.Workflow (itemLifecycleBadge)
import Kanban.UI.Notice
import Kanban.UI.Types

overflowText :: Int -> Text
overflowText count
  | count > 0 = " +" <> showText count
  | otherwise = ""

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

-- | The card's own page on GitHub, as the refresh that drew it retained it.
-- Reading it costs no request, which is what lets the details overlay print
-- it and @w@ open it without either one going back to GitHub.
itemUrl :: BoardItem -> Text
itemUrl (IssueItem issue) = issue.issueUrl
itemUrl (PullRequestItem pullRequest) = pullRequest.pullRequestUrl

-- | A card's metadata row, led by its lifecycle badge when it has one (§11).
--
-- The badge goes here rather than into 'itemHeading' on purpose: the heading
-- is the identity search matches against, and a settled card must be found by
-- the same @#number title@ text it always was.
itemMetadata :: UTCTime -> BoardItem -> Text
itemMetadata now item = maybe "" (<> " · ") (itemLifecycleBadge item) <> kindMetadata now item

kindMetadata :: UTCTime -> BoardItem -> Text
kindMetadata now (IssueItem issue) = ownership <> " · updated " <> relativeAge now issue.issueUpdatedAt
  where
    ownership
      | AssigneesUnavailable `elem` issue.issueDataGaps = unknownAssigneesText
      | null issue.issueAssignees && issue.issueAssigneeOverflow == 0 = "unassigned"
      | otherwise =
          Text.intercalate ", " ["@" <> assignee.assigneeLogin | assignee <- issue.issueAssignees]
            <> overflowText issue.issueAssigneeOverflow
kindMetadata now (PullRequestItem pullRequest) =
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

-- | How many of something a refresh brought back. The count is exact: both
-- open connections are followed to their final page, so there is no cap for a
-- @+@ to stand for (§13).
countedSource :: Text -> Int -> Text
countedSource noun count = showText count <> " " <> noun <> if count == 1 then "" else "s"

-- | The row a column has remembered. It indexes whatever that column is
-- showing, which under a live search is the filtered view
-- ("Kanban.UI.Search"), so it must never be resolved against the raw board.
selectedRow :: AppState -> BoardColumn -> Int
selectedRow state column = Map.findWithDefault 0 column state.appSelectedRows

-- | The whole of what showing a settled notice does to the state: a fresh
-- instance on the line, and nothing else.
--
-- Split out from 'Kanban.UI.State.setNotice' rather than written twice, so a
-- pure transition that has to leave the same mark -- a refused board press, a
-- refused right click -- makes exactly the mark the 'Brick.EventM' arm makes,
-- and the suite can take that transition without brick.
noticeSet :: Text -> AppState -> AppState
noticeSet message state = state {appNotice = showNotice SettledNotice message state.appNotice}

-- | Show a notice that explicitly reports the named tracked operation as in
-- progress. It outlives the ten-second lifetime for exactly as long as
-- 'noticeActivityLive' answers true for that activity, and settles -- taking
-- the ordinary ten seconds -- the moment it does not.
noticeSetFor :: NoticeActivity -> Text -> AppState -> AppState
noticeSetFor activity message state =
  state {appNotice = showNotice (ActiveWhile activity) message state.appNotice}

-- | Take the displayed notice off the line, retiring its instance for good.
noticeCleared :: AppState -> AppState
noticeCleared state = state {appNotice = clearNotice state.appNotice}

-- | What the footer line currently says, if anything.
shownNotice :: AppState -> Maybe Text
shownNotice state = currentNotice state.appNotice

-- | The declared inventory's one reader: which tracked state keeps each
-- 'NoticeActivity' alive (issue #590 requirement 7). Total in the activity
-- type, so an operation added to the inventory cannot be shown on a notice
-- without saying here what settles it.
noticeActivityLive :: AppState -> NoticeActivity -> Bool
noticeActivityLive state activity = case activity of
  -- The startup fetch is in flight from before the first event until the
  -- first open generation settles one way or the other; 'NotLoaded' is the
  -- instant between building the state and the startup refresh claiming it.
  StartupLoadRunning -> state.appBoardFreshness == NotLoaded || state.appBoardFreshness == Loading
  BoardRefreshRunning -> state.appBoardFreshness == Loading
  UsageRefreshRunning provider -> Map.findWithDefault NotLoaded provider state.appUsageFreshness == Loading
  QuitSettling -> state.appQuitPending

-- | Classify the displayed notice against what the application still tracks
-- as running, run after every event ('Kanban.UI.State.settleNoticeExpiry').
-- This is where a settled instance first earns its ten-second deadline, and
-- where an active one whose operation has ended becomes settled.
settleNoticeLifecycle :: AppState -> AppState
settleNoticeLifecycle state =
  state {appNotice = settleNotice state.appNow (noticeActivityLive state) state.appNotice}

-- | Apply one fired 'Kanban.UI.Types.NoticeExpired' tick: clear the line
-- when the tick names the displayed instance and its deadline has passed. A
-- stale tick changes nothing at all.
noticeExpiryApplied :: Int -> AppState -> AppState
noticeExpiryApplied instanceId state
  | noticeExpiryDue instanceId state.appNow state.appNotice = noticeCleared state
  | otherwise = state

-- | The startup diagnostics still worth carrying: only while the notice
-- instance they were last shown as is the one displayed now. Compared by
-- instance identity rather than text, so a later notice repeating the same
-- words cannot adopt a retired report.
outstandingStartupReport :: Maybe Int -> Maybe StartupReport -> Maybe StartupReport
outstandingStartupReport displayed report = do
  candidate <- report
  if displayed == Just candidate.startupReportShownInstance then Just candidate else Nothing

-- | Show an event's notice without ending the startup line it would land on.
--
-- The startup diagnostics ride the line until the first open outcome, but a
-- usage result or a history pause can arrive while that fetch is still
-- running; replacing the line would discard diagnostics reported nowhere
-- else. While the report is outstanding the message is composed onto the
-- line instead — still active, because the loading fragment it keeps names
-- the fetch still in flight — and once it is not, this is exactly
-- 'noticeSet'.
noticeSetOverStartupReport :: Text -> AppState -> AppState
noticeSetOverStartupReport message state =
  case outstandingStartupReport (currentNoticeInstance state.appNotice) state.appStartupReport of
    Nothing -> noticeSet message state
    Just _ ->
      let composed = fromMaybe "" (shownNotice state) <> " · " <> message
          shown = noticeSetFor StartupLoadRunning composed state
       in recordStartupShown shown

-- | Compose the startup diagnostics onto the notice a published open outcome
-- just produced, and retire the carry for good: the settled composition takes
-- the ordinary ten seconds, and no later publish can resurrect the
-- diagnostics — least of all when a dismissal or an unrelated replacement
-- already ended them, which the instance comparison against @before@ reads as
-- nothing left to compose. @before@ is the state the outcome was applied
-- over, where "were they still displayed?" has to be answered.
startupReportApplied :: AppState -> AppState -> AppState
startupReportApplied before state =
  case outstandingStartupReport (currentNoticeInstance before.appNotice) before.appStartupReport of
    Nothing -> state {appStartupReport = Nothing}
    Just report ->
      let composed = fromMaybe "" (shownNotice state) <> " · " <> report.startupReportDiagnostics
       in (noticeSet composed state) {appStartupReport = Nothing}

-- | Stamp the carried startup report with the instance of the notice just
-- displayed, so the next outstanding question compares against what is
-- actually on screen.
recordStartupShown :: AppState -> AppState
recordStartupShown state =
  state
    { appStartupReport =
        (\report -> report {startupReportShownInstance = fromMaybe (-1) (currentNoticeInstance state.appNotice)})
          <$> state.appStartupReport
    }
