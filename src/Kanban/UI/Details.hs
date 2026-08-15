module Kanban.UI.Details
  ( DetailsEnv (..),
    detailsEnv,
    drawDetails,
    mergeExplanation,
  )
where


import Brick
import qualified Brick.Types as BrickTypes
import Data.List (intersperse, sort )
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (TimeZone, UTCTime )
import Kanban.Card
  ( CardChip (..),
    labelChipRows,
    overflowChipText
    )
import Kanban.Config (ResolvedConfig (..) )
import Kanban.Domain
import Kanban.Text (sanitizeText)
import Kanban.Tracker (renderTrackerDiagnostic, trackerDiagnosticsForIssue)
import Kanban.Workflow (entryItem )
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.Theme
import Kanban.UI.Selection

-- | Everything the details overlay reads. Like 'CardEnv', this exists so the
-- overlay is a pure function of retained state: opening it never issues a
-- request, and a test can render it without an 'AppState'.
data DetailsEnv = DetailsEnv
  { detailsConfig :: ResolvedConfig,
    detailsBoard :: Board,
    detailsNow :: UTCTime,
    detailsTimeZone :: TimeZone
  }

detailsEnv :: AppState -> DetailsEnv
detailsEnv state =
  DetailsEnv
    { detailsConfig = state.appConfig,
      -- The view the overlay was opened from, so a completed card's tracker
      -- context and structural diagnostics resolve exactly as they drew.
      detailsBoard = state.appVisibleBoard,
      detailsNow = state.appNow,
      detailsTimeZone = state.appTimeZone
    }

-- | The §11 details overlay: every field the design lists, in labeled
-- sections. A field that cannot apply to the item's kind -- branches or a
-- merge state on an issue -- is left out entirely rather than rendered blank,
-- so an absent section means "not applicable" and never "unknown".
drawDetails :: DetailsEnv -> BoardItem -> Widget Name
drawDetails env item =
  vBox
    ( [ withAttr cardTitleAttr (txtWrap (itemHeading item)),
        txt "",
        drawDetailsLabels env.detailsConfig.resolvedWorkflow item,
        txt "",
        withAttr headingAttr (txt "Metadata"),
        txtWrap (itemMetadata env.detailsNow item)
      ]
        <> drawPeopleDetails item
        <> drawBranchDetails item
        <> drawLinkDetails env.detailsBoard item
        <> drawMergeDetails item
        <> drawCheckDetails item
        <> drawTimestampDetails env item
        <> trackingDetails
        <> trackerDiagnosticDetails
        <> [ txt "",
             withAttr headingAttr (txt "Body"),
             txtWrap (sanitizeText (itemBody item)),
             txt "",
             withAttr headingAttr (txt "URL"),
             withAttr linkAttr (txtWrap (itemUrl item))
           ]
    )
  where
    boardEntry = findEntry env.detailsBoard (itemId item)
    trackingDetails = case boardEntry of
      Just (Tracked context _) -> drawTrackingDetails context
      _ -> []
    -- A structural header already carries the diagnostics 'deriveBoard'
    -- produced with the board's own workflow config, so prefer them over
    -- re-parsing the body here: the overlay a childless tracker opens then
    -- says exactly what its header said, under any configured tracker label.
    trackerDiagnosticDetails = case (boardEntry, item) of
      (Just (TrackerHeader tracker), _) -> drawTrackerDiagnosticDetails tracker.trackerDiagnostics
      (_, IssueItem issue) -> drawTrackerDiagnosticDetails (trackerDiagnosticsForIssue env.detailsConfig.resolvedWorkflow issue)
      (_, PullRequestItem _) -> []

-- | Label chips as wrapped rows, measured against the width the overlay
-- actually got.
--
-- A single row of chips would be cropped on the right by a viewport that only
-- scrolls vertically, taking labels -- and eventually the overflow marker
-- itself -- somewhere the reader can never reach. Wrapping instead means
-- every retained label stays on screen, and since the overlay can be as tall
-- as it likes, a chip is never evicted to make room. The only summarized
-- count is what GitHub omitted, plus any single label too wide for a whole
-- row, and it gets its own wrapped line rather than a chip that could be
-- clipped away.
drawDetailsLabels :: WorkflowConfig -> BoardItem -> Widget Name
drawDetailsLabels workflow item =
  BrickTypes.Widget BrickTypes.Greedy BrickTypes.Fixed $ do
    context <- BrickTypes.getContext
    let width = BrickTypes.availWidth context
        names = map (sanitizeText . (.labelName)) (itemLabels item)
        rows = labelChipRows width (length names + 1) names (itemLabelOverflow item)
        omitted = sum [count | row <- rows, OverflowChip count <- row]
        chipRows = filter (not . null) (map (filter isLabelChip) rows)
        drawChip (LabelChip name) = withAttr (labelAttribute workflow name) (txt (" " <> name <> " "))
        drawChip (OverflowChip count) = withAttr pendingAttr (txt (overflowChipText count))
        marker
          | omitted > 0 = [withAttr pendingAttr (txtWrap ("+" <> showText omitted <> " labels omitted"))]
          | otherwise = []
    BrickTypes.render (vBox (map (hBox . intersperse (txt " ") . map drawChip) chipRows <> marker))

isLabelChip :: CardChip -> Bool
isLabelChip (LabelChip _) = True
isLabelChip (OverflowChip _) = False

-- | A headed block of rows, in the same style as the existing Metadata, Body,
-- and URL sections. An empty row list draws nothing at all, which is how an
-- inapplicable field disappears instead of leaving a bare heading.
detailsSection :: Text -> [Widget Name] -> [Widget Name]
detailsSection _ [] = []
detailsSection heading rows = [txt "", withAttr headingAttr (txt heading)] <> rows

-- | Who the item belongs to, following what the snapshot actually acquires:
-- issues retain assignees and pull requests retain their author, so each kind
-- shows the one it has rather than an empty row for the other.
drawPeopleDetails :: BoardItem -> [Widget Name]
drawPeopleDetails (IssueItem issue) = detailsSection "Assignees" [txtWrap (assigneeDetailText issue)]
drawPeopleDetails (PullRequestItem pullRequest) =
  detailsSection "Author" [txtWrap ("@" <> sanitizeText pullRequest.pullRequestAuthor)]

assigneeDetailText :: Issue -> Text
assigneeDetailText issue
  | AssigneesUnavailable `elem` issue.issueDataGaps = unknownAssigneesText
  | null issue.issueAssignees && issue.issueAssigneeOverflow == 0 = "unassigned"
  | otherwise =
      Text.intercalate ", " ["@" <> sanitizeText assignee.assigneeLogin | assignee <- issue.issueAssignees]
        <> overflowText issue.issueAssigneeOverflow

drawBranchDetails :: BoardItem -> [Widget Name]
drawBranchDetails (IssueItem _) = []
drawBranchDetails (PullRequestItem pullRequest) =
  detailsSection
    "Branches"
    [txtWrap (sanitizeText pullRequest.pullRequestHead <> " → " <> sanitizeText pullRequest.pullRequestBase)]

drawLinkDetails :: Board -> BoardItem -> [Widget Name]
drawLinkDetails _ (PullRequestItem pullRequest) =
  detailsSection
    "Linked issues"
    [ txtWrap
        ( if LinkedIssuesUnavailable `elem` pullRequest.pullRequestDataGaps
            then unknownLinksText
            else
              linkedRefsText
                (map (("#" <>) . showText) pullRequest.pullRequestLinkedIssues)
                pullRequest.pullRequestLinkedIssueOverflow
        )
    ]
drawLinkDetails board (IssueItem issue) =
  detailsSection
    "Linked pull requests"
    [txtWrap (linkedRefsText (map (("#" <>) . showText) (linkedPullRequests board issue.issueNumber)) 0)]

linkedRefsText :: [Text] -> Int -> Text
linkedRefsText [] overflow
  | overflow > 0 = "+" <> showText overflow <> " omitted"
  | otherwise = "none"
linkedRefsText refs overflow
  | overflow > 0 = Text.intercalate ", " refs <> " · +" <> showText overflow <> " omitted"
  | otherwise = Text.intercalate ", " refs

-- | The pull requests that close an issue. GitHub reports this relationship
-- only on the PR side, so the reverse direction is a lookup over the pull
-- requests the snapshot already retained rather than another request.
-- Relationships GitHub omitted -- from a truncated PR page, or from a capped
-- closing-issue list -- stay omitted here; the board's existing truncation and
-- @+N@ warnings are what disclose them.
linkedPullRequests :: Board -> Int -> [Int]
linkedPullRequests board issueNumber =
  sort
    [ pullRequest.pullRequestNumber
      | entry <- concat (Map.elems board.boardColumns),
        PullRequestItem pullRequest <- [entryItem entry],
        issueNumber `elem` pullRequest.pullRequestLinkedIssues
    ]

drawMergeDetails :: BoardItem -> [Widget Name]
drawMergeDetails (IssueItem _) = []
drawMergeDetails (PullRequestItem pullRequest) =
  detailsSection
    "Mergeability"
    [txtWrap (mergeText mergeState <> " — " <> mergeExplanation mergeState)]
  where
    mergeState = pullRequest.pullRequestMergeState

-- | The §9 merge vocabulary a card compresses into one word, expanded into
-- the sentence the overlay has room for. The leading term is always
-- 'mergeText', so the overlay explains exactly the state the card colored.
mergeExplanation :: MergeState -> Text
mergeExplanation MergeClean = "the head is current and merges into the base without conflict"
mergeExplanation MergeBehind = "the base has advanced past this head; update the branch before merging"
mergeExplanation MergeBlocked = "GitHub reports the merge blocked and the head is not mergeable as it stands"
mergeExplanation MergeProtected = "mergeable, and blocked only by repository policy the configured admin drainer can satisfy"
mergeExplanation MergeConflicting = "the head conflicts with the base and cannot merge until the conflict is resolved"
mergeExplanation MergeUnstable = "mergeable, but a non-required check is failing or still running"
mergeExplanation MergeUnknown = "GitHub is still calculating mergeability; the next explicit refresh resolves it"

drawCheckDetails :: BoardItem -> [Widget Name]
drawCheckDetails (IssueItem _) = []
drawCheckDetails (PullRequestItem pullRequest) =
  detailsSection "Checks" (checkSummaryRows pullRequest.pullRequestChecks)

-- | The rollup as rows: a truthful summary line, then one row per check that
-- has not passed. A rollup with nothing outstanding contributes no detail
-- rows, and a rollup past the §13 context cap says only that it is unknown --
-- the partial nodes it saw are not presented as if they were complete.
checkSummaryRows :: CheckSummary -> [Widget Name]
checkSummaryRows ChecksNone = [withAttr dimAttr (txtWrap "no checks configured")]
checkSummaryRows (ChecksPassed total) = [txtWrap (checkCountText total total)]
checkSummaryRows ChecksUnknown =
  [withAttr pendingAttr (txtWrap "unknown — the rollup exceeded the retained context cap")]
checkSummaryRows (ChecksPending passed total details) = checkDetailRows passed total details
checkSummaryRows (ChecksFailed passed total details) = checkDetailRows passed total details

checkDetailRows :: Int -> Int -> [CheckDetail] -> [Widget Name]
checkDetailRows passed total details = txtWrap (checkCountText passed total) : map drawCheckDetail details

checkCountText :: Int -> Int -> Text
checkCountText passed total = showText passed <> "/" <> showText total <> " passed"

drawCheckDetail :: CheckDetail -> Widget Name
drawCheckDetail detail =
  withAttr (checkStateAttribute detail.checkDetailState)
    . txtWrap
    $ "• " <> sanitizeText detail.checkDetailName <> " — " <> checkStateText detail.checkDetailState

checkStateText :: CheckState -> Text
checkStateText CheckPassed = "passed"
checkStateText CheckPending = "pending"
checkStateText CheckFailed = "failed"

-- | Absolute creation and update times alongside the relative age, which is
-- recomputed from the redraw's own clock rather than cached with the item.
drawTimestampDetails :: DetailsEnv -> BoardItem -> [Widget Name]
drawTimestampDetails env item =
  detailsSection
    "Timestamps"
    [ txtWrap ("created " <> absoluteTime env.detailsTimeZone (itemCreatedAt item)),
      txtWrap ("updated " <> absoluteTime env.detailsTimeZone updated <> " · " <> relativeAge env.detailsNow updated)
    ]
  where
    updated = itemUpdatedAt item

drawTrackerDiagnosticDetails :: [TrackerDiagnostic] -> [Widget Name]
drawTrackerDiagnosticDetails [] = []
drawTrackerDiagnosticDetails diagnostics =
  [txt "", withAttr pendingAttr (txt "Tracker warnings")]
    <> map (withAttr pendingAttr . txtWrap . ("• " <>) . renderTrackerDiagnostic) diagnostics

drawTrackingDetails :: TrackingContext -> [Widget Name]
drawTrackingDetails context =
  [ txt "",
    withAttr headingAttr (txt "Tracker"),
    drawMembership context.trackingPrimary
  ]
    <> map drawMembership context.trackingAdditional
    <> completionWarning
    <> multiTrackerWarning
    <> trackerWarnings
  where
    drawMembership membership =
      let tracker = membership.membershipTracker
          child = membership.membershipChild
          key = maybe ("step " <> showText (child.trackerChildChecklistOrder + 1)) id child.trackerChildImplementationKey
       in withAttr trackerAttr
            . txtWrap
            $ key
              <> " under #"
              <> showText tracker.trackerIssue.issueNumber
              <> " "
              <> sanitizeText tracker.trackerIssue.issueTitle
              <> " ("
              <> showText tracker.trackerCompleted
              <> "/"
              <> showText tracker.trackerTotal
              <> " complete)"
    completionWarning
      | context.trackingPrimary.membershipChild.trackerChildComplete =
          [withAttr pendingAttr (txtWrap "Checklist marks this still-open item complete")]
      | otherwise = []
    multiTrackerWarning
      | null context.trackingAdditional = []
      | otherwise = [withAttr pendingAttr (txtWrap "MULTI-TRACKED: memberships are listed in deterministic priority order")]
    trackerWarnings =
      concatMap
        (drawTrackerDiagnosticDetails . (.membershipTracker.trackerDiagnostics))
        (context.trackingPrimary : context.trackingAdditional)

itemUrl :: BoardItem -> Text
itemUrl (IssueItem issue) = issue.issueUrl
itemUrl (PullRequestItem pullRequest) = pullRequest.pullRequestUrl
