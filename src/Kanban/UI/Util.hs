module Kanban.UI.Util
  ( absoluteTime,
    agentFailureNotice,
    agentSessionLabelFor,
    allColumns,
    cacheEnabled,
    columnName,
    countedSource,
    directMergeNoticeFor,
    directMergeReportAfterRefresh,
    entriesForBoard,
    entryPrimaryTrackerNumber,
    failureActivity,
    formatElapsed,
    isDeadlineOutcome,
    itemBody,
    itemHeading,
    itemMetadata,
    itemStatusText,
    launchAssignment,
    liveAssignmentDisplay,
    mergeText,
    outstandingDirectMergeReport,
    overflowText,
    primaryTrackerNumber,
    pullRequestActionText,
    pullRequestSessionLabel,
    relativeAge,
    resolvedRosterCellFor,
    rightOrNothing,
    safeIndex,
    safeLast,
    selectedRow,
    shortSessionId,
    showText,
    solveReviewerDisplay,
    solveSessionLabel,
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
import Kanban.Config (cacheEnabled)
import Kanban.Domain
import Kanban.Models
  ( AssignmentUnavailable,
    ModelRoster,
    RecordedAssignment (..),
    RosterLoadError,
    assignmentUnavailableMessage,
    rosterErrorMessage,
    unavailableAssignmentDisplay,
  )
import Kanban.Preflight
  ( preflightDiagnosticDetail
    )
import Kanban.PullRequestFlow
  ( PullRequestAction (..),
    PullRequestOrigin,
    pullRequestAssignment,
    solveReviewerAssignment
    )
import Kanban.Solve
  ( SolveOutcome (..),
    SolveWorkflow (..),
    SolverBrand (..),
    assignmentLabel,
    brandForProvider,
    solveAssignment
  )
import Kanban.Text (sanitizeText)
import Kanban.Workflow (itemLifecycleBadge)
import Kanban.Worker
  ( workerDeadlineReason
  )
import Kanban.UI.Types

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

-- | The model-and-effort portion a surface shows for a cell it resolves
-- live, or the shared stand-in when the roster cannot supply it.
--
-- For the surfaces that name no session: a chooser row offering a brand,
-- and the autosolve reviewer line naming a review that has not started. A
-- session's own surfaces go through 'agentSessionLabelFor' instead, because
-- a session may hold a recorded assignment that outranks the live cell.
--
-- Polymorphic in the cell so the one that carries its provider
-- ('Kanban.Models.RecordedAssignment', from the task-routing resolvers) and
-- the bare 'Kanban.Models.Assignment' the review cells yield share this
-- resolution rather than each getting a near-copy of it.
liveAssignmentDisplay ::
  (cell -> Text) ->
  (ModelRoster -> Either AssignmentUnavailable cell) ->
  Either RosterLoadError ModelRoster ->
  Text
liveAssignmentDisplay display cell =
  either (const unavailableAssignmentDisplay) (display . snd) . resolvedRosterCellFor cell

-- | What a session surface calls its agent: the brand, then the display of
-- the assignment actually in force.
--
-- The assignment is 'launchAssignment''s, so the ordering is the launch's
-- own (D-7): a recorded assignment is replayed whatever the roster now says,
-- and only a session that has none -- a fresh one before its first launch,
-- or one recovered from a specification written before the field existed --
-- resolves the live cell.
--
-- The brand comes from the resolved assignment wherever there is one, since
-- a record carries the provider it was read for and that is what the
-- supervisor actually spawns. The routing's own brand stands in only for the
-- refusal, which has no assignment to read a provider from; requirement 6
-- keeps the surrounding text, so only the model-and-effort portion is
-- replaced.
agentSessionLabelFor ::
  SolverBrand ->
  Maybe RecordedAssignment ->
  (ModelRoster -> Either AssignmentUnavailable RecordedAssignment) ->
  Either RosterLoadError ModelRoster ->
  Text
agentSessionLabelFor brand recorded cell rosterResult =
  case launchAssignment recorded cell rosterResult of
    Left _ -> assignmentLabel brand unavailableAssignmentDisplay
    Right resolved ->
      assignmentLabel
        (brandForProvider resolved.recordedAssignmentProvider)
        resolved.recordedAssignmentDisplay

-- | 'agentSessionLabelFor' for a pull-request session, whose cell is chosen
-- by origin and action: @pr_review@ for the canonical review and rereview,
-- @pr_revise@ for the author-side revision and repair. That split is
-- 'Kanban.PullRequestFlow.pullRequestRole''s, consulted here rather than
-- restated, so the label can no longer name the solve assignment for an
-- own-brand action the flow actually runs on @pr_revise@.
pullRequestSessionLabel ::
  Maybe RecordedAssignment ->
  PullRequestOrigin ->
  PullRequestAction ->
  SolverBrand ->
  Either RosterLoadError ModelRoster ->
  Text
pullRequestSessionLabel recorded origin action brand =
  agentSessionLabelFor brand recorded (\roster -> pullRequestAssignment roster origin action)

-- | The assignment naming a solve session's own agent: the one its last
-- worker recorded, and only for a session that has none the live @solve@
-- cell its brand selects.
solveSessionLabel :: Either RosterLoadError ModelRoster -> SolveSession -> Text
solveSessionLabel rosterResult session =
  agentSessionLabelFor
    brand
    session.sessionDetail.solveSessionAssignment
    (`solveAssignment` brand)
    rosterResult
  where
    brand = session.sessionDetail.solveSessionBrand

-- | The reviewer an autosolve run will hand its pull request to: the
-- opposite brand's @pr_review@ display, resolved live because that review
-- has no worker yet to have recorded anything.
solveReviewerDisplay :: Either RosterLoadError ModelRoster -> SolverBrand -> Text
solveReviewerDisplay rosterResult brand =
  liveAssignmentDisplay (.recordedAssignmentDisplay) (`solveReviewerAssignment` brand) rosterResult

-- | An activity line with its elapsed time, for a live session that keeps an
-- activity clock at all. A kind that records no start time shows the bare
-- activity, which is what it showed before the clock became a shared field.
timedActivity :: UTCTime -> Bool -> Maybe UTCTime -> Text -> Text
timedActivity now isLive (Just startedAt) activity
  | isLive = activity <> " · " <> formatElapsed now startedAt
timedActivity _ _ _ activity = activity

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

-- | The roster an agent-starting path may launch against and the cell it
-- resolved from it, or the refusal it must show instead.
--
-- The one place the startup 'Either' is unwrapped, and the one place the
-- selected cell is checked, so every spawn boundary refuses on the same two
-- terms: a present-but-unusable @models.toml@ (D-3 — the message names the
-- file and the defect), and a valid roster that does not cover the cell this
-- run's routing selected. Neither falls back to the compiled defaults; an
-- absent file already yielded them inside 'Kanban.Models.loadModelRoster'.
--
-- Both halves come back because the two kinds of caller need different ones:
-- a worker launch records the cell in the specification it persists, while
-- the embedded review backend hands the whole roster to a client that reads
-- more than one of its cells over that client's life.
resolvedRosterCellFor :: (ModelRoster -> Either AssignmentUnavailable cell) -> Either RosterLoadError ModelRoster -> Either Text (ModelRoster, cell)
resolvedRosterCellFor cell rosterResult = case rosterResult of
  Left loadError -> Left (rosterErrorMessage loadError)
  Right roster -> case cell roster of
    Left unavailable -> Left (assignmentUnavailableMessage unavailable)
    Right resolved -> Right (roster, resolved)

-- | What a worker launch runs on, as one total decision (D-7, MODEL-7).
--
-- A session whose previous worker recorded an assignment replays it
-- unchanged and consults no roster at all: not the cell, not the loaded
-- provider set, and not the startup 'Either' — so a resume still launches
-- after the operator has edited a model out of @models.toml@, or left the
-- file unusable. If the provider has genuinely retired that model the CLI
-- fails visibly at resume, which is the honest outcome; silently moving a
-- live provider session onto a different model is not.
--
-- Only a launch that is not a replay resolves, and it refuses on exactly the
-- terms 'resolvedRosterCellFor' states. That covers a fresh start and the
-- first resume of a session whose worker predates the recorded field.
launchAssignment ::
  Maybe RecordedAssignment ->
  (ModelRoster -> Either AssignmentUnavailable RecordedAssignment) ->
  Either RosterLoadError ModelRoster ->
  Either Text RecordedAssignment
launchAssignment recorded cell rosterResult = case recorded of
  Just replayed -> Right replayed
  Nothing -> snd <$> resolvedRosterCellFor cell rosterResult

isDeadlineOutcome :: SolveOutcome -> Bool
isDeadlineOutcome (SolveFailed message) = message == workerDeadlineReason
isDeadlineOutcome _ = False
