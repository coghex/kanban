module Kanban.UI.Board
  ( CardEnv (..),
    cardExcerptLimit,
    cardStatusAttribute,
    drawBase,
    drawCardFrame,
    drawLiveActivity,
    reviewPhaseGlyph,
    reviewPhaseGlyphFor,
  )
where


import Brick
import Brick.Widgets.Border (borderWithLabel, hBorder, hBorderWithLabel, vBorder)
import Brick.Widgets.Border.Style (unicodeBold)
import qualified Brick.Types as BrickTypes
import Data.List (intersperse )
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, defaultTimeLocale, formatTime, utcToZonedTime)
import Kanban.CLI (Options (..))
import Kanban.Card
  ( CardChip (..),
    boundedLines,
    displayWidth,
    labelChipRows,
    overflowChipText,
    wrappedLines,
  )
import Kanban.Config (LimitsConfig (..), ResolvedConfig (..) )
import Kanban.Domain
import Kanban.Drainer
  ( DrainerStatus (..)
    )
import Kanban.Layout (responsiveColumnWidths, responsiveOpenColumnWidths)
import Kanban.Text (excerpt, sanitizeText)
import Kanban.Tracker (renderTrackerDiagnostic, trackerDiagnosticsForIssue)
import Kanban.Workflow (entryItem, isApproved, isProblem, orderCardLabels )
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.Theme
import Kanban.UI.Selection

drawBase :: AppState -> Widget Name
drawBase state
  | usesOpenBorders state =
      withBorderStyle unicodeBold
        . vBox
        $ [hBorderWithLabel title, body, footer, hBorder]
  | otherwise = withBorderStyle (shellBorderStyle state) . borderWithLabel title $ body <=> footer
  where
    repository = state.appRepository
    title =
      withAttr titleAttr
        . txt
        $ " " <> repository.repositoryOwner <> "/" <> repository.repositoryName <> " "
    body
      | state.appSidebarVisible && usesOpenBorders state = hLimit 28 (drawUsage state) <+> str "  " <+> drawBoard state
      | state.appSidebarVisible = hLimit 28 (drawUsage state) <+> drawBoard state
      | otherwise = drawBoard state
    footer = drawFooter state

drawUsage :: AppState -> Widget Name
drawUsage state
  | usesOpenBorders state =
      withBorderStyle unicodeBold
        . vBox
        $ [ hBorderWithLabel (withAttr headingAttr (txt " USAGE ")),
            padLeftRight 1 usageContents,
            hBorder
          ]
  | otherwise =
      withBorderStyle (innerBorderStyle state)
        . borderWithLabel (withAttr headingAttr (txt " USAGE "))
        . padLeftRight 1
        $ usageContents
  where
    usageContents =
      vBox
        [ vBox [drawProvider state Codex, txt "", drawProvider state Claude],
          padTop Max (drawDrainerButton state)
        ]

drawDrainerButton :: AppState -> Widget Name
drawDrainerButton state =
  vBox
    [ clickable DrainerButton
        . withAttr (drainerStatusAttr status)
        . vBox
        $ [ txt "+--------------+",
            txt "| drain_prs.py |",
            txt "+--------------+"
          ],
      withAttr (drainerStatusAttr status) (txtWrap status.drainerDetail)
    ]
  where
    status = state.appDrainerStatus

drawProvider :: AppState -> UsageProvider -> Widget Name
drawProvider state provider =
  vBox
    ( withAttr providerAttr (txt providerName)
        : case Map.lookup provider state.appUsage of
          Nothing -> [withAttr (usageStatusAttribute freshness) (txtWrap (usageStatusText provider freshness))]
          Just snapshot -> map (drawUsageWindow state) snapshot.usageWindows <> usageSnapshotStatus freshness
    )
  where
    freshness = Map.findWithDefault NotLoaded provider state.appUsageFreshness
    providerName = case provider of
      Codex -> "Codex"
      Claude -> "Claude"

usageSnapshotStatus :: Freshness -> [Widget Name]
usageSnapshotStatus Loading = [withAttr noticeAttr (txt "refreshing…")]
usageSnapshotStatus (Stale _ message) = [withAttr pendingAttr (txtWrap ("stale · " <> message))]
usageSnapshotStatus _ = []

usageStatusText :: UsageProvider -> Freshness -> Text
usageStatusText _ Loading = "refreshing…"
usageStatusText _ (Fresh _) = "loaded"
usageStatusText _ (Stale _ message) = "stale · " <> message
usageStatusText _ (Unavailable message) = message
usageStatusText _ (Unsupported message) = message
usageStatusText _ NotLoaded = "press u to refresh"

drawUsageWindow :: AppState -> UsageWindow -> Widget Name
drawUsageWindow state usageWindow =
  vBox
    [ txt (padLabel usageWindow.usageWindowLabel <> " " <> usageBar state usageWindow.usagePercentLeft),
      withAttr dimAttr . txt $ "        " <> Text.pack (formatTime defaultTimeLocale "%a %H:%M" (utcToZonedTime state.appTimeZone usageWindow.usageResetsAt))
    ]

usageBar :: AppState -> Int -> Text
usageBar state percentage =
  left <> Text.replicate filled fullCharacter <> Text.replicate (10 - filled) emptyCharacter <> right <> " " <> Text.pack (show percentage) <> "%"
  where
    filled = max 0 (min 10 ((percentage + 5) `div` 10))
    (left, right, fullCharacter, emptyCharacter)
      | state.appOptions.optionAscii = ("[", "]", "#", ".")
      | otherwise = ("[", "]", "█", "░")

drawBoard :: AppState -> Widget Name
drawBoard state =
  BrickTypes.Widget BrickTypes.Greedy BrickTypes.Greedy $ do
    context <- BrickTypes.getContext
    let availableWidth = BrickTypes.availWidth context
        columnWidths
          | usesOpenBorders state = responsiveOpenColumnWidths availableWidth
          | otherwise = responsiveColumnWidths availableWidth
    BrickTypes.render
      . viewport BoardViewport Horizontal
      $ if usesOpenBorders state
        then drawOpenBoard state columnWidths
        else
          withBorderStyle (innerBorderStyle state)
            . vBox
            $ [drawBoardTop state columnWidths, drawBoardColumns state columnWidths, drawBoardBottom state columnWidths]

drawOpenBoard :: AppState -> [Int] -> Widget Name
drawOpenBoard state columnWidths =
  withBorderStyle unicodeBold
    . vBox
    $ [ hBox (intersperse columnGutter (zipWith drawOpenHeader allColumns columnWidths)),
        hBox (intersperse columnGutter (zipWith (drawColumn state) columnWidths allColumns)),
        hBox (intersperse columnGutter (map (\columnWidth -> hLimit columnWidth hBorder) columnWidths))
      ]
  where
    columnGutter = str "  "
    drawOpenHeader column columnWidth =
      hLimit columnWidth
        . hBorderWithLabel
        . withAttr (columnHeadingAttr column)
        . txt
        $ " " <> columnName column <> "  " <> columnCountText state column <> " "

drawBoardTop :: AppState -> [Int] -> Widget Name
drawBoardTop state columnWidths =
  hBox
    ( txt (boardTopLeft state)
        : concatMap drawHeader (zip3 [0 :: Int ..] allColumns columnWidths)
    )
  where
    drawHeader (index, column, columnWidth) =
      [ hLimit columnWidth
          . hBorderWithLabel
          . withAttr (columnHeadingAttr column)
          . txt
          $ " " <> columnName column <> "  " <> columnCountText state column <> " ",
        txt (if index == length allColumns - 1 then boardTopRight state else boardTopJunction state)
      ]

drawBoardColumns :: AppState -> [Int] -> Widget Name
drawBoardColumns state columnWidths =
  hBox
    ( vBorder
        : concatMap drawBody (zip allColumns columnWidths)
    )
  where
    drawBody (column, columnWidth) = [drawColumn state columnWidth column, vBorder]

drawBoardBottom :: AppState -> [Int] -> Widget Name
drawBoardBottom state columnWidths =
  hBox
    ( txt (boardBottomLeft state)
        : concatMap drawSegment (zip [0 :: Int ..] columnWidths)
    )
  where
    drawSegment (index, columnWidth) =
      [ hLimit columnWidth hBorder,
        txt (if index == length allColumns - 1 then boardBottomRight state else boardBottomJunction state)
      ]

drawColumn :: AppState -> Int -> BoardColumn -> Widget Name
drawColumn state columnWidth column =
  columnVisibility
    . hLimit columnWidth
    . clickable (ColumnViewport column)
    . viewport (ColumnViewport column) Vertical
    . padTop (Pad 1)
    . vBox
    $ if null entries
      then [padAll 1 (withAttr dimAttr (txt "No items"))]
      else drawColumnEntries state column (zip [0 ..] entries)
  where
    entries = entriesFor state column
    columnVisibility = if state.appSelectedColumn == column then visible else id

drawColumnEntries :: AppState -> BoardColumn -> [(Int, ColumnEntry)] -> [Widget Name]
drawColumnEntries _ _ [] = []
drawColumnEntries state column indexedEntries@((row, entry) : remainingEntries) = case entry of
  TrackerHeader tracker ->
    let expanded = tracker.trackerIssue.issueNumber `Set.member` state.appExpandedTrackers
     in drawTrackerHeader state column row tracker expanded : drawColumnEntries state column remainingEntries
  Tracked trackingContext _ ->
    let trackerNumber = primaryTrackerNumber trackingContext
        (groupEntries, remaining) = span ((== Just trackerNumber) . entryPrimaryTrackerNumber . snd) indexedEntries
        tracker = trackingContext.trackingPrimary.membershipTracker
        expanded = trackerNumber `Set.member` state.appExpandedTrackers
        children = if expanded then map (uncurry (drawCard state column)) groupEntries else []
     in drawTrackerHeader state column row tracker expanded : children <> drawColumnEntries state column remaining
  Standalone _ ->
    let (standaloneEntries, remaining) = span ((== Nothing) . entryPrimaryTrackerNumber . snd) indexedEntries
        header = padLeftRight 2 (withAttr dimAttr (txt "STANDALONE"))
     in header : map (uncurry (drawCard state column)) standaloneEntries <> drawColumnEntries state column remaining

boardTopLeft, boardTopRight, boardTopJunction :: AppState -> Text
boardBottomLeft, boardBottomRight, boardBottomJunction :: AppState -> Text
boardTopLeft state = structuralGlyph state "┏"
boardTopRight state = structuralGlyph state "┓"
boardTopJunction state = structuralGlyph state "┳"
boardBottomLeft state = structuralGlyph state "┗"
boardBottomRight state = structuralGlyph state "┛"
boardBottomJunction state = structuralGlyph state "┻"

structuralGlyph :: AppState -> Text -> Text
structuralGlyph state boxGlyph
  | state.appOptions.optionAscii = "+"
  | otherwise = boxGlyph

drawCard :: AppState -> BoardColumn -> Int -> ColumnEntry -> Widget Name
drawCard state column row entry =
  padLeftRight 1
    . padBottom (Pad 1)
    . clickable (CardTarget column row)
    $ visibility card
  where
    selected = state.appSelectedColumn == column && selectedRow state column == row
    visibility = if selected && state.appEnsureSelectionVisible then visible else id
    card =
      (if selected then withAttr selectedAttr (txt marker) else txt " ")
        <+> solveBadge state (entryItem entry)
        <+> reviewBadge state (entryItem entry)
        <+> branchPrefix state column row entry
        <+> drawCardFrame (cardEnv state) selected entry
    marker = if state.appOptions.optionAscii then ">" else "▌"

-- | Everything a card needs to draw itself that the entry does not carry.
-- Splitting it out of 'AppState' keeps card rendering exercisable on its own.
data CardEnv = CardEnv
  { cardOptions :: Options,
    cardConfig :: ResolvedConfig,
    cardNow :: UTCTime,
    cardSolveSessions :: Map Int SolveSession
  }

cardEnv :: AppState -> CardEnv
cardEnv state =
  CardEnv
    { cardOptions = state.appOptions,
      cardConfig = state.appConfig,
      cardNow = state.appNow,
      cardSolveSessions = state.appSolveSessions
    }

-- | Cells the frame spends on itself: two border columns plus the one-cell
-- padding on either side of the interior.
cardFrameOverhead :: Int
cardFrameOverhead = 4

-- | Card titles wrap to at most two rows, so a long one cannot crowd out the
-- excerpt below it.
cardTitleLimit :: Int
cardTitleLimit = 2

-- | §11 allows two rows of label chips before the rest becomes @+N@.
cardLabelRowLimit :: Int
cardLabelRowLimit = 2

-- | Draw a card at whatever width the column leaves it, sizing the frame to
-- the content it actually laid out. Every interior widget below is exactly one
-- row wide, so the border edges match the interior and nothing is cropped.
drawCardFrame :: CardEnv -> Bool -> ColumnEntry -> Widget Name
drawCardFrame env selected entry =
  BrickTypes.Widget BrickTypes.Greedy BrickTypes.Fixed $ do
    context <- BrickTypes.getContext
    let innerWidth = max 0 (BrickTypes.availWidth context - cardFrameOverhead)
        contents = cardLines env selected entry innerWidth
        interiorHeight = length contents
        verticalEdge = vBox (replicate interiorHeight (str [vertical]))
    BrickTypes.render
      . withBorderStyle (cardBorderStyle env.cardOptions)
      . vBox
      $ [ hBox [withAttr topBottomAttribute (txt topLeft), withAttr topBottomAttribute hBorder, withAttr statusAttribute (txt topRight)],
          hBox
            [ withAttr leftAttribute verticalEdge,
              withAttr interiorAttribute (padLeftRight 1 (padRight Max (vBox contents))),
              withAttr statusAttribute verticalEdge
            ],
          hBox [withAttr topBottomAttribute (txt bottomLeft), withAttr topBottomAttribute hBorder, withAttr statusAttribute (txt bottomRight)]
        ]
  where
    item = entryItem entry
    (topLeft, topRight, bottomLeft, bottomRight, vertical)
      | env.cardOptions.optionAscii = ("+", "+", "+", "+", '|')
      | otherwise = ("╭", "╮", "╰", "╯", '│')
    statusAttribute = cardStatusAttribute env item
    topBottomAttribute = if selected then selectedAttr else statusAttribute
    leftAttribute = if selected then selectedAttr else statusAttribute
    interiorAttribute = cardInteriorAttribute statusAttribute

-- | The configured card excerpt height, in rows.
cardExcerptLimit :: ResolvedConfig -> Int
cardExcerptLimit config = config.resolvedLimits.limitsExcerptLines

-- | The card interior as one widget per rendered row, laid out for
-- @innerWidth@ cells. Titles and excerpts get their own line budgets so
-- neither can starve the other, and metadata and status content is wrapped
-- rather than dropped.
cardLines :: CardEnv -> Bool -> ColumnEntry -> Int -> [Widget Name]
cardLines env selected entry innerWidth =
  trackingLines
    <> map (withAttr titleAttribute . txt) (boundedLines innerWidth cardTitleLimit (itemHeading item))
    <> cardLabelRows env item innerWidth
    <> map (withAttr dimAttr . txt) (wrappedLines innerWidth (itemMetadata env.cardNow item))
    <> map txt (boundedLines innerWidth (cardExcerptLimit env.cardConfig) (excerpt (itemBody item)))
    <> statusLines
  where
    item = entryItem entry
    workflow = env.cardConfig.resolvedWorkflow
    titleAttribute = if selected then selectedTitleAttr else cardTitleAttr
    trackingLines = case entry of
      Standalone _ -> []
      Tracked context _ -> drawTrackingLine innerWidth context
      TrackerHeader _ -> []
    statusLines = case item of
      IssueItem issue -> concatMap diagnosticRows (trackerDiagnosticsForIssue workflow issue)
      PullRequestItem _ ->
        map (withAttr (statusTextAttr workflow item) . txt) (wrappedLines innerWidth (itemStatusText item))
    diagnosticRows diagnostic =
      map (withAttr pendingAttr . txt) (wrappedLines innerWidth ("TRACKER · " <> renderTrackerDiagnostic diagnostic))

drawTrackerHeader :: AppState -> BoardColumn -> Int -> Tracker -> Bool -> Widget Name
drawTrackerHeader state column row tracker expanded =
  visibility
    . clickable (EpicTarget column row tracker.trackerIssue.issueNumber)
    . padLeftRight 1
    . padTop (Pad 1)
    $ marker <+> solveBadge state (IssueItem tracker.trackerIssue) <+> reviewBadge state (IssueItem tracker.trackerIssue) <+> withAttr headerAttribute (txtWrap headerText)
  where
    selected = not expanded && state.appSelectedColumn == column && selectedRow state column == row
    visibility = if selected && state.appEnsureSelectionVisible then visible else id
    marker
      | selected = withAttr selectedAttr (txt (if state.appOptions.optionAscii then ">" else "▌"))
      | otherwise = txt " "
    headerAttribute = trackerHeaderAttribute tracker
    disclosure
      | state.appOptions.optionAscii = if expanded then "v" else ">"
      | expanded = "▾"
      | otherwise = "▸"
    headerText =
      disclosure
        <> " #"
        <> showText tracker.trackerIssue.issueNumber
        <> "  "
        <> sanitizeText tracker.trackerIssue.issueTitle
        <> "  "
        <> showText tracker.trackerCompleted
        <> "/"
        <> showText tracker.trackerTotal
        <> " complete"
        <> if null tracker.trackerDiagnostics then "" else "  · !" <> showText (length tracker.trackerDiagnostics)

-- | The tracker-context rows. They wrap rather than truncate, so a long
-- implementation key or tracker reference stays fully visible and the frame
-- grows to hold it. The multi-tracked warning shares the reference's last row
-- while both fit, and otherwise keeps its own attribute on its own rows.
drawTrackingLine :: Int -> TrackingContext -> [Widget Name]
drawTrackingLine innerWidth context
  | innerWidth <= 0 = []
  | null context.trackingAdditional = referenceRows
  | displayWidth (referenceText <> inlineWarning) <= innerWidth =
      [withAttr trackerAttr (txt referenceText) <+> withAttr pendingAttr (txt inlineWarning)]
  | otherwise = referenceRows <> map (withAttr pendingAttr . txt) (wrappedLines innerWidth "MULTI-TRACKED")
  where
    child = context.trackingPrimary.membershipChild
    childKey = case child.trackerChildImplementationKey of
      Just key -> key
      Nothing -> "step " <> showText (child.trackerChildChecklistOrder + 1)
    trackerNumber = context.trackingPrimary.membershipTracker.trackerIssue.issueNumber
    referenceText = childKey <> " · tracker #" <> showText trackerNumber
    referenceRows = map (withAttr trackerAttr . txt) (wrappedLines innerWidth referenceText)
    inlineWarning = " · MULTI-TRACKED"

branchPrefix :: AppState -> BoardColumn -> Int -> ColumnEntry -> Widget Name
branchPrefix state column row entry = case entry of
  Standalone _ -> emptyWidget
  Tracked _ _ -> withAttr trackerAttr (txt branch)
  TrackerHeader _ -> emptyWidget
  where
    branch
      | state.appOptions.optionAscii = if isLastInTracker then "`- " else "+- "
      | isLastInTracker = "└─ "
      | otherwise = "├─ "
    isLastInTracker = entryPrimaryTrackerNumber entry /= (entryPrimaryTrackerNumber =<< safeIndex (row + 1) (entriesFor state column))

-- | Label chips as whole rows. 'labelChipRows' decides what fits; every chip
-- it returns is drawn complete, and the @+N@ it appends counts both the labels
-- GitHub omitted and the ones that had no room here.
cardLabelRows :: CardEnv -> BoardItem -> Int -> [Widget Name]
cardLabelRows env item innerWidth = map drawRow (labelChipRows innerWidth cardLabelRowLimit names (itemLabelOverflow item))
  where
    names = map (sanitizeText . (.labelName)) (orderCardLabels env.cardConfig.resolvedWorkflow (itemLabels item))
    drawRow chips = hBox (intersperse (txt " ") (map drawChip chips))
    drawChip (LabelChip name) = withAttr (labelAttribute env.cardConfig.resolvedWorkflow name) (txt (" " <> name <> " "))
    drawChip (OverflowChip count) = withAttr pendingAttr (txt (overflowChipText count))

solveBadge :: AppState -> BoardItem -> Widget Name
solveBadge _ (PullRequestItem _) = emptyWidget
solveBadge state (IssueItem issue) = case Map.lookup issue.issueNumber state.appSolveSessions of
  Nothing -> emptyWidget
  Just session -> withAttr (solveSessionAttribute session) (txt (solvePhaseGlyph state session))

solvePhaseGlyph :: AppState -> SolveSession -> Text
solvePhaseGlyph state session
  | state.appOptions.optionAscii = case session.solveSessionPhase of
      SolveStarting -> "* "
      SolveRunning -> "* "
      SolveInterrupting -> "! "
      SolveAttention -> "! "
      SolveFinished -> "+ "
      SolveFailedPhase -> "x "
      SolveKilledPhase -> "x "
      SolveOrphanedPhase -> "x "
  | otherwise = case session.solveSessionPhase of
      SolveStarting -> spinnerGlyph session.solveSessionSpinnerFrame <> " "
      SolveRunning -> spinnerGlyph session.solveSessionSpinnerFrame <> " "
      SolveInterrupting -> "◆ "
      SolveAttention -> "◆ "
      SolveFinished -> "◇ "
      SolveFailedPhase -> "× "
      SolveKilledPhase -> "× "
      SolveOrphanedPhase -> "⚠ "

reviewBadge :: AppState -> BoardItem -> Widget Name
reviewBadge state (PullRequestItem pullRequest) = case Map.lookup pullRequest.pullRequestNumber state.appPullRequestReviewSessions of
  Nothing -> emptyWidget
  Just session -> withAttr (pullRequestSessionAttribute session) (txt (pullRequestSessionGlyph state session))
reviewBadge state (IssueItem issue) = case Map.lookup issue.issueNumber state.appReviewSessions of
  Nothing -> emptyWidget
  Just session -> withAttr (reviewPhaseAttribute session.reviewSessionPhase) (txt (reviewPhaseGlyph state session))

pullRequestSessionGlyph :: AppState -> PullRequestReviewSession -> Text
pullRequestSessionGlyph state session
  | state.appOptions.optionAscii = case session.pullRequestSessionPhase of
      SolveStarting -> "* "
      SolveRunning -> "* "
      SolveInterrupting -> "! "
      SolveAttention -> "! "
      SolveFinished -> "+ "
      SolveFailedPhase -> "x "
      SolveKilledPhase -> "x "
      SolveOrphanedPhase -> "x "
  | otherwise = case session.pullRequestSessionPhase of
      SolveStarting -> spinnerGlyph session.pullRequestSessionSpinnerFrame <> " "
      SolveRunning -> spinnerGlyph session.pullRequestSessionSpinnerFrame <> " "
      SolveInterrupting -> "◆ "
      SolveAttention -> "◆ "
      SolveFinished -> "✓ "
      SolveFailedPhase -> "× "
      SolveKilledPhase -> "× "
      SolveOrphanedPhase -> "⚠ "

reviewPhaseGlyph :: AppState -> ReviewSession -> Text
reviewPhaseGlyph state = reviewPhaseGlyphFor state.appOptions.optionAscii

reviewPhaseGlyphFor :: Bool -> ReviewSession -> Text
reviewPhaseGlyphFor useAscii session
  | useAscii = case session.reviewSessionPhase of
      ReviewStarting -> "* "
      ReviewRunning -> "* "
      ReviewWaiting -> "? "
      ReviewFinished -> "+ "
      ReviewNeedsChanges -> "! "
      ReviewFailed -> "! "
      ReviewRevised -> "^ "
      ReviewInterrupted -> "- "
  | otherwise = case session.reviewSessionPhase of
      ReviewStarting -> spinnerGlyph session.reviewSessionSpinnerFrame <> " "
      ReviewRunning -> spinnerGlyph session.reviewSessionSpinnerFrame <> " "
      ReviewWaiting -> "? "
      ReviewFinished -> "✓ "
      ReviewNeedsChanges -> "! "
      ReviewFailed -> "× "
      ReviewRevised -> "◆ "
      ReviewInterrupted -> "· "

spinnerGlyph :: Int -> Text
spinnerGlyph frame = spinnerFrames !! (frame `mod` length spinnerFrames)
  where
    spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

drawLiveActivity :: AppState -> Bool -> Int -> UTCTime -> Text -> Widget Name
drawLiveActivity state isLive frame startedAt activity
  | not isLive = emptyWidget
  | otherwise =
      withAttr reviewingAttr
        . txtWrap
        $ activityGlyph <> " " <> activity <> " · " <> formatElapsed state.appNow startedAt
  where
    activityGlyph
      | state.appOptions.optionAscii = "*"
      | otherwise = spinnerGlyph frame

drawFooter :: AppState -> Widget Name
drawFooter state =
  padLeftRight 1
    . vBox
    -- `m` is deliberately absent: the line is already at the width the
    -- narrowest supported four-column board can show, and one more entry
    -- truncates `q quit` off the end. The help overlay is the complete list.
    $ [ withAttr footerAttr (txt "j/↓ next  k/↑ previous  x kill  h/l column  e epic  enter details  r review/revise  S solve  A autosolve  p processes  i attention  u update  d drainer  c sidebar  s settings  ? help  q quit"),
        withAttr dimAttr (txt (boardFreshnessText state)),
        maybe emptyWidget (withAttr noticeAttr . txtWrap) state.appNotice
      ]

boardFreshnessText :: AppState -> Text
boardFreshnessText state = "board: " <> case state.appBoardFreshness of
  NotLoaded -> "not loaded"
  Loading -> "refreshing…"
  Fresh fetchedAt -> "updated " <> relativeAge state.appNow fetchedAt
  Stale fetchedAt _ -> "stale · last updated " <> relativeAge state.appNow fetchedAt
  Unavailable _ -> "unavailable"
  Unsupported _ -> "unsupported"

-- | A pull request's card color is always derived from its
-- 'pullRequestStatus', not the generic approved-item shortcut used for
-- issues: an approved PR that 'pullRequestStatus' reports as merely pending
-- (for example amber-blocked, once a configured 'SeverityAmber'
-- 'blockingSeverity' downgrades it from a problem) must still render
-- pending rather than the plain approved color, and only a fully ready PR
-- gets the ready color.
cardStatusAttribute :: CardEnv -> BoardItem -> AttrName
cardStatusAttribute env (PullRequestItem pullRequest) = pullRequestCardAttribute env.cardConfig.resolvedWorkflow pullRequest
cardStatusAttribute env item
  | isProblem env.cardConfig.resolvedWorkflow item = problemAttr
  | Just solveAttribute <- solveCardAttribute env item = solveAttribute
  | itemHasAmberWarning env.cardConfig.resolvedWorkflow item = pendingAttr
  | isApproved env.cardConfig.resolvedWorkflow item = approvedAttr
cardStatusAttribute _ _ = neutralAttr

solveCardAttribute :: CardEnv -> BoardItem -> Maybe AttrName
solveCardAttribute _ (PullRequestItem _) = Nothing
solveCardAttribute env (IssueItem issue) = solveSessionAttribute <$> Map.lookup issue.issueNumber env.cardSolveSessions
