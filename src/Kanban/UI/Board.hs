module Kanban.UI.Board
  ( CardEnv (..),
    cardExcerptLimit,
    cardStatusAttribute,
    drawBase,
    drawCardFrame,
    drawLiveActivity,
    footerHintLine,
    openDataLoadingHeading,
    openDataUnavailableHeading,
    searchFooterHintLine,
    pullRequestPhaseGlyph,
    pullRequestPhaseGlyphFor,
    reviewPhaseGlyph,
    reviewPhaseGlyphFor,
    solvePhaseGlyph,
    solvePhaseGlyphFor,
    trackerHeaderText,
    usageAgeText,
    usageResetRowText,
    usageSidebarInterior,
    usageSidebarWidth,
  )
where


import Brick
import Brick.Widgets.Border (borderWithLabel, hBorder, hBorderWithLabel, vBorder)
import Brick.Widgets.Center (center)
import Brick.Widgets.Border.Style
  ( bsCornerBL,
    bsCornerBR,
    bsCornerTL,
    bsCornerTR,
    bsHorizontal,
    bsVertical,
    unicodeBold,
  )
import qualified Brick.Types as BrickTypes
import Data.List (intersperse )
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (TimeZone, UTCTime, diffUTCTime)
import Kanban.CLI (Options (..))
import Kanban.Card
  ( CardChip (..),
    boundedLines,
    displayWidth,
    labelChipRows,
    overflowChipText,
    wrappedLines,
  )
import Kanban.Config (LimitsConfig (..), ResolvedConfig (..), usageSolveRoundEstimate )
import Kanban.Domain
import Kanban.Drainer
  ( DrainerStatus (..)
    )
import Kanban.Layout (responsiveColumnWidths, responsiveOpenColumnWidths)
import Kanban.Text (excerpt, sanitizeText)
import Kanban.Tracker (renderTrackerDiagnostic, trackerDiagnosticsForIssue)
import Kanban.Usage.Render (usageResetCountdownText, usageResetLocalText, usageSnapshotAgeText, usageSolveRoundsLeft, usageSolveRoundsSuffix)
import Kanban.Workflow (entryItem, isApproved, isProblem, itemLifecycleBadge, orderCardLabels )
import Kanban.UI.Types
import Kanban.UI.Keys (BindingScope (..), BoardAction (..), actionKeyText, footerHint, scopeBindings)
import Kanban.UI.SessionCore
import Kanban.UI.Util
import Kanban.UI.Theme
import Kanban.UI.Search

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
      | state.appSidebarVisible && usesOpenBorders state = hLimit usageSidebarWidth (drawUsage state) <+> str "  " <+> drawBoard state
      | state.appSidebarVisible = hLimit usageSidebarWidth (drawUsage state) <+> drawBoard state
      | otherwise = drawBoard state
    footer = drawFooter state

-- | The sidebar's drawn width, which §6 fixes at 28 cells and derives the
-- 164-cell four-column threshold from.
usageSidebarWidth :: Int
usageSidebarWidth = 28

-- | The cells a sidebar row actually has to itself: the drawn width less the
-- box border and the one-cell padding on each side. Every row 'drawProvider'
-- composes is budgeted against this.
usageSidebarInterior :: Int
usageSidebarInterior = usageSidebarWidth - 4

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

-- | The drainer control draws its own box out of 'innerBorderStyle' rather
-- than wrapping the label in Brick's 'Brick.Widgets.Border.border'. That keeps
-- one border policy for the sidebar in all three modes, and it keeps every
-- glyph under 'drainerStatusAttr': Brick's border widgets draw their runs
-- under @borderAttr@, which the theme does not name, so a bordered label would
-- lose the status color on its edges.
drawDrainerButton :: AppState -> Widget Name
drawDrainerButton state =
  vBox
    [ clickable DrainerButton
        . withAttr (drainerStatusAttr status)
        . vBox
        $ [ txt (edge boxStyle.bsCornerTL boxStyle.bsCornerTR),
            txt (Text.singleton boxStyle.bsVertical <> drainerLabel <> Text.singleton boxStyle.bsVertical),
            txt (edge boxStyle.bsCornerBL boxStyle.bsCornerBR)
          ],
      withAttr (drainerStatusAttr status) (txtWrap status.drainerDetail)
    ]
  where
    status = state.appDrainerStatus
    boxStyle = innerBorderStyle state
    edge leftCorner rightCorner =
      Text.singleton leftCorner
        <> Text.replicate (Text.length drainerLabel) (Text.singleton boxStyle.bsHorizontal)
        <> Text.singleton rightCorner

-- | The drainer control's interior row, padded so the control keeps its
-- sixteen-column footprint.
drainerLabel :: Text
drainerLabel = " drain_prs.py "

-- | One provider's block: its name, then either the status standing in for
-- windows it has none of, or its windows and whatever status still qualifies
-- them.
--
-- The name shares its row with the age of the snapshot being drawn. That age
-- is a property of the snapshot, so it is drawn whenever one is, and never
-- gated on 'Freshness': 'Kanban.UI.initialUsageState' labels a snapshot
-- restored from the cache @Fresh@ at whatever instant it was written, so
-- gating on the constructor would hide the age in exactly the case it exists
-- for — a board opened on numbers days old.
drawProvider :: AppState -> UsageProvider -> Widget Name
drawProvider state provider =
  vBox
    ( case Map.lookup provider state.appUsage of
        Nothing ->
          [ withAttr providerAttr (txt providerName),
            withAttr (usageStatusAttribute freshness) (txtWrap (usageStatusText provider freshness))
          ]
        Just snapshot ->
          providerHeading snapshot
            : map (drawUsageWindow state estimate) snapshot.usageWindows
            <> usageSnapshotStatus freshness
    )
  where
    estimate = usageSolveRoundEstimate state.appConfig.resolvedUsage provider
    freshness = Map.findWithDefault NotLoaded provider state.appUsageFreshness
    providerName = case provider of
      Codex -> "Codex"
      Claude -> "Claude"
    providerHeading snapshot =
      withAttr providerAttr (txt providerName)
        <+> padLeft Max (withAttr dimAttr (txt (usageAgeText state.appNow snapshot)))

-- | How old the snapshot on screen is, in the wording @kanban --usage@ prints
-- it in, measured against the instant the frame is drawn for.
usageAgeText :: UTCTime -> UsageSnapshot -> Text
usageAgeText now snapshot = usageSnapshotAgeText (diffUTCTime now snapshot.usageFetchedAt)

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
usageStatusText _ NotLoaded = "press " <> actionKeyText RefreshAll <> " to refresh"

drawUsageWindow :: AppState -> Maybe Int -> UsageWindow -> Widget Name
drawUsageWindow state estimate usageWindow =
  vBox
    [ txt (padLabel usageWindow.usageWindowLabel <> " " <> usageBar state usageWindow.usagePercentLeft),
      withAttr dimAttr (txt (usageResetRowText estimate state.appTimeZone state.appNow usageWindow))
    ]

-- | A window's second row: how long until it resets, then the wall clock it
-- resets at, and — where it fits — how many solve rounds the percentage above
-- is estimated to buy.
--
-- The countdown takes the indent this row used to open with rather than a
-- third row, because the percentage row above already spends all
-- 'usageSidebarInterior' cells and the sidebar's height per provider is
-- fixed. Both halves are bounded — 'usageResetCountdownText' by
-- 'Kanban.Usage.Render.usageDurationDayBound' and the wall clock by its
-- format — so the row fits that interior for any instant a provider reports,
-- including one already behind the clock.
--
-- The estimate is the one part of this row with no such bound of its own, so
-- it is measured rather than assumed: the complete suffix is appended only
-- when the finished row still fits 'usageSidebarInterior', and is otherwise
-- dropped whole. Nothing already on the row is shortened to make room —
-- a countdown and a reset instant the user can act on outrank a figure they
-- can recompute from the percentage above.  The measurement is in terminal
-- cells because that is what the interior is counted in, and both @·@ and
-- @≈@ are East Asian ambiguous.
usageResetRowText :: Maybe Int -> TimeZone -> UTCTime -> UsageWindow -> Text
usageResetRowText estimate zone now usageWindow
  | displayWidth withEstimate <= usageSidebarInterior = withEstimate
  | otherwise = base
  where
    base =
      usageResetCountdownText (diffUTCTime usageWindow.usageResetsAt now)
        <> " · "
        <> usageResetLocalText zone usageWindow.usageResetsAt
    withEstimate =
      base <> maybe "" usageSolveRoundsSuffix (usageSolveRoundsLeft estimate usageWindow.usagePercentLeft)

usageBar :: AppState -> Int -> Text
usageBar state percentage =
  left <> Text.replicate filled fullCharacter <> Text.replicate (10 - filled) emptyCharacter <> right <> " " <> Text.pack (show percentage) <> "%"
  where
    filled = max 0 (min 10 ((percentage + 5) `div` 10))
    (left, right, fullCharacter, emptyCharacter)
      | state.appOptions.optionAscii = ("[", "]", "#", ".")
      | otherwise = ("[", "]", "█", "░")

-- | The board body: four columns of cards, or the panel that stands in for
-- them until a complete open generation has published.
--
-- The panel replaces the columns rather than being drawn over them, and that
-- is the whole of §7's "renders no cards from any source": there is no
-- heading to carry a count, no viewport holding a stale board underneath, and
-- no partial page set anything could have put there. The sidebar, the footer,
-- and every key stay exactly as they are, so @u@, @q@, @Ctrl-C@, help, and
-- options remain operable while it is up.
drawBoard :: AppState -> Widget Name
drawBoard state = case openDataView state.appLastSuccessfulFetch state.appBoardFreshness of
  OpenDataLoading -> drawOpenDataPanel state openDataLoadingHeading loadingBody
  OpenDataUnavailable reason -> drawOpenDataPanel state openDataUnavailableHeading (unavailableBody reason)
  OpenDataBoard -> drawPopulatedBoard state
  where
    loadingBody =
      [ txtWrap "Fetching every open issue and pull request.",
        withAttr dimAttr (txtWrap "The board appears once the first complete refresh publishes.")
      ]
    unavailableBody reason =
      [ withAttr problemAttr (txtWrap reason),
        withAttr dimAttr (txtWrap ("press " <> actionKeyText RefreshAll <> " to retry"))
      ]

-- | The headings the two panels are recognised by. Fixed strings rather than
-- composed ones: §7 names @OPEN DATA UNAVAILABLE@ exactly, and the golden
-- frames are what hold both to it.
openDataLoadingHeading, openDataUnavailableHeading :: Text
openDataLoadingHeading = "LOADING OPEN DATA"
openDataUnavailableHeading = "OPEN DATA UNAVAILABLE"

-- | Cells the widest panel is allowed. Narrower regions simply clip it, since
-- 'hLimit' is an upper bound; the §6 minimum column is wide enough for the
-- longer of the two headings and its border.
openDataPanelWidth :: Int
openDataPanelWidth = 52

drawOpenDataPanel :: AppState -> Text -> [Widget Name] -> Widget Name
drawOpenDataPanel state heading body =
  center
    . hLimit openDataPanelWidth
    . withBorderStyle (cardBorderStyle state.appOptions)
    . borderWithLabel (withAttr headingAttr (txt (" " <> heading <> " ")))
    . padLeftRight 1
    . vBox
    $ body

drawPopulatedBoard :: AppState -> Widget Name
drawPopulatedBoard state =
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
    $ searchRows <> entryRows
  where
    entries = entriesFor state column
    -- The box is part of this column's ordinary layout flow rather than an
    -- overlay: it is drawn first, so the cards below move down by exactly its
    -- rendered height and a resize rewraps both.
    searchRows = maybe [] (pure . drawSearchBox state columnWidth) (searchQueryFor state column)
    entryRows
      | null entries = [padAll 1 (withAttr dimAttr (txt emptyColumnText))]
      | otherwise = drawColumnEntries state (expandedTrackersFor state column) column (zip [0 ..] entries)
    -- A column a query emptied is not the same thing as an empty column, and
    -- §7 keeps the two rows distinct.
    emptyColumnText = maybe "No items" (const "No matches") (activeQueryFor state column)
    columnVisibility = if state.appSelectedColumn == column then visible else id

-- | The one-line label naming the box a query is typed into.
searchBoxLabel :: Text
searchBoxLabel = " SEARCH "

-- | Cells the search box spends on itself in a column: the one-cell padding
-- either side of the box, its two border columns, and the one-cell padding
-- either side of its content.
searchBoxOverhead :: Int
searchBoxOverhead = 6

-- | The query as the rows the box draws, always at least one row so an empty
-- query still shows a box with a line to type into.
--
-- Wrapping is 'wrappedLines', which rebuilds from 'Data.Text.words' and so
-- collapses runs of whitespace rather than echoing them. That is the same
-- normalization the match itself applies, so what the box shows is what the
-- query is being compared as.
searchBoxLines :: Int -> Text -> [Text]
searchBoxLines innerWidth query = map pad (case wrappedLines innerWidth query of [] -> [" "]; rows -> rows)
  where
    pad row = row <> Text.replicate (max 0 (innerWidth - displayWidth row)) " "

drawSearchBox :: AppState -> Int -> Text -> Widget Name
drawSearchBox state columnWidth query =
  padLeftRight 1
    . padBottom (Pad 1)
    . withBorderStyle (cardBorderStyle state.appOptions)
    . borderWithLabel (withAttr headingAttr (txt searchBoxLabel))
    . padLeftRight 1
    . vBox
    $ map (withAttr cardTitleAttr . txt) (searchBoxLines (max 0 (columnWidth - searchBoxOverhead)) query)

drawColumnEntries :: AppState -> Set.Set Int -> BoardColumn -> [(Int, ColumnEntry)] -> [Widget Name]
drawColumnEntries _ _ _ [] = []
drawColumnEntries state expandedTrackers column indexedEntries@((row, entry) : remainingEntries) = case entry of
  TrackerHeader tracker ->
    let expanded = tracker.trackerIssue.issueNumber `Set.member` expandedTrackers
     in drawTrackerHeader state column row tracker expanded : drawColumnEntries state expandedTrackers column remainingEntries
  Tracked trackingContext _ ->
    let trackerNumber = primaryTrackerNumber trackingContext
        (groupEntries, remaining) = span ((== Just trackerNumber) . entryPrimaryTrackerNumber . snd) indexedEntries
        tracker = trackingContext.trackingPrimary.membershipTracker
        expanded = trackerNumber `Set.member` expandedTrackers
        children = if expanded then map (uncurry (drawCard state column)) groupEntries else []
     in drawTrackerHeader state column row tracker expanded : children <> drawColumnEntries state expandedTrackers column remaining
  Standalone _ ->
    let (standaloneEntries, remaining) = span ((== Nothing) . entryPrimaryTrackerNumber . snd) indexedEntries
        header = padLeftRight 2 (withAttr dimAttr (txt "STANDALONE"))
     in header : map (uncurry (drawCard state column)) standaloneEntries <> drawColumnEntries state expandedTrackers column remaining

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
    headerText = trackerHeaderText state.appOptions.optionAscii expanded tracker

-- | The one line an epic's header draws, whether it heads a populated group or
-- stands alone as a 'TrackerHeader'.
--
-- A pure projection rather than part of the drawing, because it is where §11's
-- lifecycle badge reaches a header at all: a header is built from the tracker
-- rather than from a card, so it never passes through the card metadata row the
-- badge otherwise leads.
trackerHeaderText :: Bool -> Bool -> Tracker -> Text
trackerHeaderText useAscii expanded tracker =
  disclosure
    <> " #"
    <> showText tracker.trackerIssue.issueNumber
    <> "  "
    <> sanitizeText tracker.trackerIssue.issueTitle
    <> lifecycleBadge
    <> "  "
    <> showText tracker.trackerCompleted
    <> "/"
    <> showText tracker.trackerTotal
    <> " complete"
    <> if null tracker.trackerDiagnostics then "" else "  · !" <> showText (length tracker.trackerDiagnostics)
  where
    disclosure
      | useAscii = if expanded then "v" else ">"
      | expanded = "▾"
      | otherwise = "▸"
    lifecycleBadge = maybe "" ("  " <>) (itemLifecycleBadge (IssueItem tracker.trackerIssue))

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

-- | What each 'SolvePhase' looks like as a badge. Solve and PR sessions
-- disagree about one arm only -- a finished solve has nothing left to do
-- while a finished PR review is ready -- so that arm is the parameter and
-- the rest of the table exists once.
solvePhaseGlyphs :: PhaseGlyph -> SolvePhase -> PhaseGlyph
solvePhaseGlyphs finished = \case
  SolveStarting -> PhaseSpinner
  SolveRunning -> PhaseSpinner
  SolveInterrupting -> PhaseGlyphs "◆ " "! "
  SolveAttention -> PhaseGlyphs "◆ " "! "
  SolveFinished -> finished
  SolveFailedPhase -> PhaseGlyphs "× " "x "
  SolveKilledPhase -> PhaseGlyphs "× " "x "
  SolveOrphanedPhase -> PhaseGlyphs "⚠ " "x "

reviewPhaseGlyphs :: ReviewPhase -> PhaseGlyph
reviewPhaseGlyphs = \case
  ReviewStarting -> PhaseSpinner
  ReviewRunning -> PhaseSpinner
  ReviewWaiting -> PhaseGlyphs "? " "? "
  ReviewFinished -> PhaseGlyphs "✓ " "+ "
  ReviewNeedsChanges -> PhaseGlyphs "! " "! "
  ReviewFailed -> PhaseGlyphs "× " "! "
  ReviewRevised -> PhaseGlyphs "◆ " "^ "
  ReviewInterrupted -> PhaseGlyphs "· " "- "

solvePhaseGlyphFor :: Bool -> SolveSession -> Text
solvePhaseGlyphFor useAscii = renderPhaseGlyph useAscii (solvePhaseGlyphs (PhaseGlyphs "◇ " "+ "))

pullRequestPhaseGlyphFor :: Bool -> PullRequestReviewSession -> Text
pullRequestPhaseGlyphFor useAscii = renderPhaseGlyph useAscii (solvePhaseGlyphs (PhaseGlyphs "✓ " "+ "))

reviewPhaseGlyphFor :: Bool -> ReviewSession -> Text
reviewPhaseGlyphFor useAscii = renderPhaseGlyph useAscii reviewPhaseGlyphs

solvePhaseGlyph :: AppState -> SolveSession -> Text
solvePhaseGlyph state = solvePhaseGlyphFor state.appOptions.optionAscii

pullRequestPhaseGlyph :: AppState -> PullRequestReviewSession -> Text
pullRequestPhaseGlyph state = pullRequestPhaseGlyphFor state.appOptions.optionAscii

reviewPhaseGlyph :: AppState -> ReviewSession -> Text
reviewPhaseGlyph state = reviewPhaseGlyphFor state.appOptions.optionAscii

reviewBadge :: AppState -> BoardItem -> Widget Name
reviewBadge state (PullRequestItem pullRequest) = case Map.lookup pullRequest.pullRequestNumber state.appPullRequestReviewSessions of
  Nothing -> emptyWidget
  Just session -> withAttr (pullRequestSessionAttribute session) (txt (pullRequestPhaseGlyph state session))
reviewBadge state (IssueItem issue) = case Map.lookup issue.issueNumber state.appReviewSessions of
  Nothing -> emptyWidget
  Just session -> withAttr (reviewPhaseAttribute session.sessionPhase) (txt (reviewPhaseGlyph state session))

-- | The animated activity line a live solve or PR overlay shows. A session
-- kind with no activity clock ('sessionActivityStartedAt' absent) simply
-- shows no elapsed time, rather than this inventing one for it.
drawLiveActivity :: AppState -> Bool -> Int -> Maybe UTCTime -> Text -> Widget Name
drawLiveActivity state isLive frame startedAt activity
  | not isLive = emptyWidget
  | otherwise =
      withAttr reviewingAttr
        . txtWrap
        $ activityGlyph <> " " <> timedActivity state.appNow True startedAt activity
  where
    activityGlyph
      | state.appOptions.optionAscii = "*"
      | otherwise = spinnerGlyph frame

drawFooter :: AppState -> Widget Name
drawFooter state =
  padLeftRight 1
    . vBox
    $ [ withAttr footerAttr (txt (maybe footerHintLine (const searchFooterHintLine) state.appSearch)),
        withAttr dimAttr (txt (boardFreshnessText state)),
        maybe emptyWidget (withAttr noticeAttr . txtWrap) state.appNotice
      ]

-- | Every base-board binding, as one hint chip each, projected from the table
-- in "Kanban.UI.Keys" rather than transcribed here.
--
-- The line is a single row and 'txt' clips it at the terminal width, which is
-- the policy it has always had: even the shorter hand-written line this
-- replaced lost its tail on the 164-cell four-column minimum §6 names. What
-- changed is that the content is now complete — @g@, @G@, @Esc@, @Ctrl-L@,
-- and @m@ were all missing from it — so at narrow widths more of the tail is
-- clipped. The help overlay behind @?@ is, as before, the complete list, and
-- is the one that has to stay readable.
footerHintLine :: Text
footerHintLine = Text.intercalate "  " (map footerHint (scopeBindings BoardScope))

-- | The hint line a live search shows in place of the board's.
--
-- Written here rather than projected from the table in "Kanban.UI.Keys"
-- because none of these keys is a binding: while the box is open @h@ and @l@
-- are text, and the arrows move the search rather than the column selection.
-- The board's line names those keys the other way round — @h/← prev column@,
-- @l/→ next column@ — so showing it here would state both of them wrongly.
searchFooterHintLine :: Text
searchFooterHintLine =
  Text.intercalate
    "  "
    [ "h/l/any letter type",
      "backspace delete",
      "←/→ move search",
      "↑/↓ select",
      "enter details",
      "s/esc close"
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
