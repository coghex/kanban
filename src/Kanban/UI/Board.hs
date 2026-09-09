module Kanban.UI.Board
  ( CardEnv (..),
    approvalControlLabel,
    baseFooterRows,
    boardFooterHintLine,
    boardHintLine,
    cardExcerptLimit,
    cardStatusAttribute,
    ColumnPiece (..),
    columnBody,
    columnBodyItems,
    columnItemHeight,
    columnScrollStep,
    columnWindowFor,
    unmeasuredLayoutInputs,
    drawColumnItem,
    refreshColumnWindows,
    completedLoadingHeading,
    completedUnavailableHeading,
    drainerLabel,
    drawBase,
    drawCardFrame,
    drawFooter,
    drawLiveActivity,
    emptyColumnText,
    filterChipText,
    filterFooterHintLine,
    filterPanelLabel,
    filterSummaryText,
    footerHintLine,
    openDataLoadingHeading,
    openDataUnavailableHeading,
    overlayHintChips,
    overlayHintLine,
    searchFooterHintLine,
    pullRequestPhaseGlyph,
    pullRequestPhaseGlyphFor,
    reviewPhaseGlyph,
    reviewPhaseGlyphFor,
    solvePhaseGlyph,
    solvePhaseGlyphFor,
    trackerHeaderText,
    updateLabel,
    usageAgeText,
    usageBarWidth,
    usageLabelField,
    usagePercentField,
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
import qualified Graphics.Vty as Vty
import Data.List (intersperse, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (TimeZone, UTCTime, addUTCTime, diffUTCTime)
import Data.Vector (Vector)
import qualified Data.Vector as Vector
import Text.Wrap (defaultWrapSettings, wrapTextToLines)
import Kanban.CLI (Options (..))
import Kanban.ApprovalService
  ( ApprovalStatus (..)
    )
import Kanban.Card
  ( CardChip (..),
    boundedLines,
    displayWidth,
    elide,
    labelChipRows,
    overflowChipText,
    wrappedLines,
  )
import Kanban.Config (LimitsConfig (..), ResolvedConfig (..), usageSolveRoundEstimate )
import Kanban.Domain
import Kanban.Drainer
  ( DrainerStatus (..)
    )
import Kanban.Filter
  ( FilterBox,
    FilterGroup,
    filterBoxChecked,
    filterBoxLabel,
    filterGroupBoxes,
    filterGroupLabel,
  )
import Kanban.Layout (responsiveColumnWidths, responsiveOpenColumnWidths)
import Kanban.Text (excerpt, sanitizeText)
import Kanban.Tracker (renderTrackerDiagnostic, trackerDiagnosticsForIssue)
import Kanban.Usage.Render (usageResetCountdownText, usageResetLocalText, usageSnapshotAgeText, usageSolveRoundsLeft, usageSolveRoundsSuffix)
import Kanban.Workflow (entryItem, isApproved, isProblem, itemLifecycleBadge, orderCardLabels )
import Kanban.UI.Types
import Kanban.Models (OperatingMode (..))
import Kanban.Usage (usageProviders)
import Kanban.UI.Keys (BindingScope (..), BoardAction (..), KeyBinding (..), actionKeyText, footerHint, footerHintRow, modeScopeBindings)
import Kanban.UI.SessionCore
import Kanban.UI.Session (incidentsFooterHints, processesFooterHints)
import Kanban.UI.SessionEvents (pullRequestSessionOps, reviewSessionOps, sessionOverlayHints, solveSessionOps)
import Kanban.UI.Settings (settingsFooterHints)
import Kanban.UI.Solve (solveChooserFooterHints)
import Kanban.UI.Util
import Kanban.UI.Theme
import Kanban.UI.Search
import Kanban.UI.Filter
  ( CardSurface (..),
    cardSurfaceFor,
    completedHistoryStatusText,
    criteriaAreFiltering,
    facetCount,
    facetCountText,
    filterBoxCountText,
    filterPanelFocusedBox,
    filteredCount,
    focusedSearch,
    rawEntryCount,
  )

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
    -- With no provider loaded there are no windows to draw and no issue
    -- approval service to start, so §6's box, ` USAGE ` heading, and 28-cell
    -- width keep only the two controls that still mean something: the update
    -- `u` and `↻` share, which still refreshes the board, and the PR
    -- drainer, which merges pull requests and spawns no model.
    --
    -- The approval control going with the provider blocks is what closes its
    -- click route: brick registers a clickable extent only for a widget that
    -- was drawn, so a press cannot reach 'ApprovalButton' when this branch
    -- draws none -- and `a` itself refuses through
    -- 'Kanban.UI.Keys.agentSurfaceRefusal' whether or not it is on screen.
    --
    -- Above that floor it is one block per provider this install actually
    -- reads, taken from the same list the refreshes are started from rather
    -- than from a pair written here, so the sidebar can never show a window
    -- for an account 'Kanban.UI.Refresh.startUsageRefreshes' never probes --
    -- which in single-agent mode would be a stale cached entry for the
    -- unloaded brand presented as this install's own reading.
    usageContents = case usageProviders state.appOperatingMode of
      [] ->
        vBox
          [ drawUpdateButton state,
            padTop Max (drawDrainerButton state)
          ]
      providers ->
        vBox
          [ vBox (intersperse (txt "") (map (drawProvider state) providers)),
            drawUpdateButton state,
            -- One padded stack rather than two, so the pair stays together at
            -- the sidebar's foot: padding each separately would push the
            -- approval control up to the update button and leave the gap
            -- between two service controls that belong beside each other.
            padTop Max (vBox [drawApprovalButton state, drawDrainerButton state])
          ]

-- | One nested sidebar control, drawn under §10's convention: its own box out
-- of 'innerBorderStyle' rather than the label wrapped in Brick's
-- 'Brick.Widgets.Border.border'. That keeps one border policy for the sidebar
-- in all three modes, and it keeps every glyph under @attribute@: Brick's
-- border widgets draw their runs under @borderAttr@, which the theme does not
-- name, so a bordered label would lose the control's color on its edges.
--
-- The box is measured in terminal cells rather than code points, because that
-- is what the drawn label occupies and what the sidebar's width is counted in.
sidebarControl :: AppState -> Name -> AttrName -> Text -> Widget Name
sidebarControl state name attribute label =
  clickable name
    . withAttr attribute
    . vBox
    $ [ txt (edge boxStyle.bsCornerTL boxStyle.bsCornerTR),
        txt (Text.singleton boxStyle.bsVertical <> label <> Text.singleton boxStyle.bsVertical),
        txt (edge boxStyle.bsCornerBL boxStyle.bsCornerBR)
      ]
  where
    boxStyle = innerBorderStyle state
    edge leftCorner rightCorner =
      Text.singleton leftCorner
        <> Text.replicate (displayWidth label) (Text.singleton boxStyle.bsHorizontal)
        <> Text.singleton rightCorner

drawDrainerButton :: AppState -> Widget Name
drawDrainerButton state =
  vBox
    [ sidebarControl state DrainerButton (drainerStatusAttr status) drainerLabel,
      withAttr (drainerStatusAttr status) (txtWrap status.drainerDetail)
    ]
  where
    status = state.appDrainerStatus

-- | The drainer control's interior row, padded so the control keeps its
-- sixteen-column footprint.
drainerLabel :: Text
drainerLabel = " drain_prs.py "

-- | The issue approval service's control, drawn exactly as the drainer's is
-- and directly above it.
--
-- The detail line is 'approvalDetail' verbatim. Every wording it can carry --
-- @checking…@ before the first poll answers, the transition text a press
-- writes, and the steady, barrier, and error compositions the controller's
-- document decodes into -- is already composed in
-- "Kanban.ApprovalService" and "Kanban.UI.Approval", so composing anything
-- here would be a second place the operator's text could be decided.
drawApprovalButton :: AppState -> Widget Name
drawApprovalButton state =
  vBox
    [ sidebarControl state ApprovalButton (approvalStatusAttr status) approvalControlLabel,
      withAttr (approvalStatusAttr status) (txtWrap status.approvalDetail)
    ]
  where
    status = state.appApprovalStatus

-- | The approval control's interior row, padded the way the drainer's is.
--
-- Nineteen cells of label make a twenty-one-cell box, which is what has to
-- fit: 'usageSidebarInterior' is 24, so the widest sidebar control still
-- clears the interior it is drawn in without wrapping.
approvalControlLabel :: Text
approvalControlLabel = " approve_issues.py "

-- | The update control: the board-and-usage update @u@ performs, made
-- clickable. It carries no status or detail line of its own, because the
-- update it starts already reports itself through the provider blocks above
-- it and the notice line below the board, so it draws in the neutral color a
-- control with nothing of its own to say takes.
drawUpdateButton :: AppState -> Widget Name
drawUpdateButton state = sidebarControl state UpdateButton neutralAttr updateLabel

-- | The update control's interior row: the single glyph §6 fixes, with the
-- one-space padding the drainer control's label carries.
--
-- @↻@ (U+21BB) is not a matter of taste. It is one terminal cell wide and is
-- carried by the DejaVu Sans Mono build @tools/render_board_screenshot.py@
-- pins and verifies every frame glyph against; the similar @⟳@ (U+27F3),
-- @⟲@ (U+27F2), and @⭮@ (U+2B6E) are absent from that font in both faces and
-- would leave the tracked screenshot unrenderable.
updateLabel :: Text
updateLabel = " ↻ "

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
    [ txt (usagePercentRowText state usageWindow),
      withAttr dimAttr (txt (usageResetRowText estimate state.appTimeZone state.appNow usageWindow))
    ]

-- | The width of the label field the percentage row opens with, in terminal
-- cells.
usageLabelField :: Int
usageLabelField = 7

-- | The width of the bracketed bar, in terminal cells: the two brackets and
-- the ten cells between them. Fixed, so two rows' fills are comparable at a
-- glance.
usageBarWidth :: Int
usageBarWidth = 12

-- | The width of the percentage field the row closes with, in terminal cells:
-- the decimal right-aligned within three cells, then the @%@ marker.
usagePercentField :: Int
usagePercentField = 4

-- | A window's first row: what the window is called, how much of it is left
-- drawn as a bar, and the same figure as a number.
--
-- Every part of this row is a fixed-width field, and the fields together are
-- exactly 'usageSidebarInterior': 'usageLabelField', one separator cell,
-- 'usageBarWidth', and 'usagePercentField'. Composing it out of fields rather
-- than out of whatever its parts happen to measure is what keeps the @%@ off
-- the cell Brick clips — the row used to grow with the percentage, so a
-- hundred percent remaining drew twenty-five cells and lost its marker — and
-- what keeps every bar in a provider's block starting in the same column
-- whatever its label measures.
--
-- The percentage field is a minimum rather than a bound, because the figure
-- in it is the one thing on the row the user cannot recover from anything
-- else. Three cells hold every percentage a provider decodes, which
-- 'Kanban.UsageCommand.parseUsageWindow' bounds to 0-100; a wider figure can
-- only come from a cache written outside that bound, which
-- 'Kanban.Usage.Render.renderWindowLine' also states in full rather than
-- shortening.
usagePercentRowText :: AppState -> UsageWindow -> Text
usagePercentRowText state usageWindow =
  usageLabelText usageWindow.usageWindowLabel
    <> " "
    <> usageBar state usageWindow.usagePercentLeft
    <> usagePercentText usageWindow.usagePercentLeft

-- | A window's label in exactly 'usageLabelField' cells.
--
-- Both halves are measured in terminal cells rather than characters, because
-- the field is a column position the bar beside it depends on: a label of
-- seven wide characters counts as seven and occupies fourteen, which is how
-- a label that "fits" used to push the bar and the percentage past the
-- interior. A label too wide for the field is cut and marked with
-- 'Kanban.Card.elide'\'s ellipsis, so a shortened label reads as shortened
-- rather than as the window's real name.
--
-- Line breaks are flattened to spaces first. 'Kanban.Text.sanitizeText'
-- keeps @\n@ deliberately, and Brick draws a newline as a row break, so an
-- external command's multi-line label would otherwise put the bar and the
-- percentage on a row of their own beneath a provider block of fixed height.
usageLabelText :: Text -> Text
usageLabelText label = padToWidth usageLabelField bounded
  where
    flattened = Text.map flattenLineBreak label
    flattenLineBreak '\n' = ' '
    flattenLineBreak character = character
    bounded
      | displayWidth flattened <= usageLabelField = flattened
      | otherwise = elide usageLabelField flattened

-- | The remaining percentage as the row's closing field: right-aligned within
-- three cells so the figures in a provider's block line up under each other,
-- then the @%@ that says what they are.
--
-- Counting characters is counting cells here, unlike everywhere else on this
-- row: a decimal is digits and at most a sign, and none of those is wide.
usagePercentText :: Int -> Text
usagePercentText percentage = Text.justifyRight (usagePercentField - 1) ' ' (showText percentage) <> "%"

-- | Pad @value@ out to @width@ terminal cells. 'Data.Text.justifyLeft' counts
-- characters, which is the measure this row cannot use.
padToWidth :: Int -> Text -> Text
padToWidth width value = value <> Text.replicate (max 0 (width - displayWidth value)) " "

-- | A window's second row: how long until it resets, then the wall clock it
-- resets at, and — where it fits — how many solve rounds the percentage above
-- is estimated to buy.
--
-- The countdown takes the indent this row used to open with rather than a
-- third row, because the percentage row above spends all
-- 'usageSidebarInterior' cells on its own fields and the sidebar's height per
-- provider is fixed. Both halves are bounded — 'usageResetCountdownText' by
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

-- | The bracketed bar alone, always 'usageBarWidth' cells. The percentage it
-- draws is stated beside it by 'usagePercentText' rather than appended here,
-- so the bar cannot borrow a cell from the field after it.
usageBar :: AppState -> Int -> Text
usageBar state percentage =
  left <> Text.replicate filled fullCharacter <> Text.replicate (cells - filled) emptyCharacter <> right
  where
    cells = usageBarWidth - 2
    filled = max 0 (min cells ((percentage * cells + 50) `div` 100))
    (left, right, fullCharacter, emptyCharacter)
      | state.appOptions.optionAscii = ("[", "]", "#", ".")
      | otherwise = ("[", "]", "█", "░")

-- | The board region: the filter panel, when it is showing, above whatever
-- the card area is drawing.
--
-- The panel is part of this region's own vertical flow rather than an overlay,
-- so it shifts the columns down by exactly its own height and cannot reach the
-- usage sidebar beside it or the footer below it (§6).
drawBoard :: AppState -> Widget Name
drawBoard state = case drawFilterPanel state of
  Nothing -> cardArea
  Just panel -> panel <=> cardArea
  where
    cardArea = drawCardArea state

-- | Four columns of cards, or the centered panel that stands in for them.
--
-- A panel replaces the columns rather than being drawn over them, and that is
-- the whole of §7's "renders no cards from any source": there is no heading to
-- carry a count, no viewport holding a stale board underneath, and no partial
-- page set anything could have put there. The sidebar, the filter panel, the
-- footer, and every key that is not a card action stay exactly as they are, so
-- @F@, @u@, @q@, @Ctrl-C@, help, and options remain operable while one is up.
drawCardArea :: AppState -> Widget Name
drawCardArea state = case cardSurfaceFor state of
  CardSurfaceLoadingOpen -> drawCenteredPanel state openDataLoadingHeading openLoadingBody
  CardSurfaceUnavailableOpen reason -> drawCenteredPanel state openDataUnavailableHeading (unavailableBody reason)
  CardSurfaceLoadingCompleted progress pausedUntil ->
    drawCenteredPanel state completedLoadingHeading (completedLoadingBody state progress pausedUntil)
  CardSurfaceUnavailableCompleted reason -> drawCenteredPanel state completedUnavailableHeading (unavailableBody reason)
  CardSurfaceCards -> drawPopulatedBoard state
  where
    openLoadingBody =
      [ txtWrap "Fetching every open issue and pull request.",
        withAttr dimAttr (txtWrap "The board appears once the first complete refresh publishes.")
      ]
    unavailableBody reason =
      [ withAttr problemAttr (txtWrap reason),
        withAttr dimAttr (txtWrap ("press " <> actionKeyText RefreshAll <> " to retry"))
      ]

-- | What the completed blocker says: what is being fetched, how far it has
-- got, why it is waiting when it is, and the one press that ends it.
completedLoadingBody :: AppState -> CompletedProgress -> Maybe UTCTime -> [Widget Name]
completedLoadingBody state progress pausedUntil =
  [ txtWrap "Fetching every closed issue and completed pull request.",
    withAttr dimAttr (txtWrap (completedProgressText progress))
  ]
    <> pausedRows
    <> [withAttr dimAttr (txtWrap ("press " <> actionKeyText ShowFilter <> " and uncheck Closed to return to the open board"))]
  where
    pausedRows =
      [ withAttr pendingAttr (txtWrap (historyPausedText state.appTimeZone resetAt))
      | Just resetAt <- [pausedUntil]
      ]

-- | How far a completed traversal has got, in the honest form: a total only
-- once both connections have reported one, and no invented denominator before
-- that (§13).
completedProgressText :: CompletedProgress -> Text
completedProgressText progress = case (progress.completedIssuesTotal, progress.completedPullRequestsTotal) of
  (Just issues, Just pullRequests) -> showText loaded <> " of " <> showText (issues + pullRequests) <> " loaded"
  _ -> showText loaded <> " loaded so far"
  where
    loaded = progress.completedIssuesLoaded + progress.completedPullRequestsLoaded

-- | Why the traversal is waiting. The same fact the notice line reported when
-- the pause arrived, drawn from the status that outlives that notice.
historyPausedText :: TimeZone -> UTCTime -> Text
historyPausedText timeZone resetAt = "Paused · GitHub limit resets " <> absoluteTime timeZone resetAt

-- | The headings the centered panels are recognised by. Fixed strings rather
-- than composed ones: §7 names @OPEN DATA UNAVAILABLE@ exactly, and the golden
-- frames are what hold all four to their wording.
openDataLoadingHeading, openDataUnavailableHeading :: Text
openDataLoadingHeading = "LOADING OPEN DATA"
openDataUnavailableHeading = "OPEN DATA UNAVAILABLE"

completedLoadingHeading, completedUnavailableHeading :: Text
completedLoadingHeading = "LOADING COMPLETED HISTORY"
completedUnavailableHeading = "COMPLETED DATA UNAVAILABLE"

-- | Cells the widest panel is allowed. Narrower regions simply clip it, since
-- 'hLimit' is an upper bound; the §6 minimum column is wide enough for the
-- longest of the headings and its border.
centeredPanelWidth :: Int
centeredPanelWidth = 52

drawCenteredPanel :: AppState -> Text -> [Widget Name] -> Widget Name
drawCenteredPanel state heading body =
  center
    . hLimit centeredPanelWidth
    . withBorderStyle (cardBorderStyle state.appOptions)
    . borderWithLabel (withAttr headingAttr (txt (" " <> heading <> " ")))
    . padLeftRight 1
    . vBox
    $ body

-- | The one-line label naming the filter panel.
filterPanelLabel :: Text
filterPanelLabel = " FILTER "

-- | Cells the group-label column takes, sized from the labels themselves so a
-- renamed group cannot run into the first chip beside it.
filterGroupColumn :: Int
filterGroupColumn = maximum (1 : map (displayWidth . filterGroupLabel) [minBound .. maxBound]) + 2

-- | Cells between two chips on one row.
filterChipGap :: Text
filterChipGap = "  "

-- | The panel, or 'Nothing' while it is hidden — in which case the board
-- occupies exactly the rows it always did.
drawFilterPanel :: AppState -> Maybe (Widget Name)
drawFilterPanel state = case state.appFilterPanel of
  Nothing -> Nothing
  Just _ ->
    Just
      . withBorderStyle (cardBorderStyle state.appOptions)
      . borderWithLabel (withAttr headingAttr (txt filterPanelLabel))
      . padLeftRight 1
      $ filterPanelContents state

-- | The four groups and the summary beneath them, laid out for whatever width
-- the board region currently has. Chips wrap inside their group's own rows, so
-- a narrower terminal makes the panel taller rather than clipping a checkbox
-- the mouse can still be aimed at.
filterPanelContents :: AppState -> Widget Name
filterPanelContents state =
  BrickTypes.Widget BrickTypes.Greedy BrickTypes.Fixed $ do
    context <- BrickTypes.getContext
    -- Padded to the full region rather than to the widest chip row, because
    -- §7 has the panel span the board: a border drawn only as wide as its
    -- contents would sit over the first column or two instead.
    BrickTypes.render
      . padRight Max
      . vBox
      $ concatMap (drawFilterGroup state (BrickTypes.availWidth context)) [minBound .. maxBound]
        <> [withAttr dimAttr (txt (filterSummaryText state))]

-- | One group's rows: its label, and its chips wrapped beneath or beside it.
--
-- The label shares the first row while every chip still fits next to it, and
-- takes a row of its own once one does not. That second layout is what keeps a
-- narrow terminal honest: a chip clipped by the region would lose the count on
-- its right-hand end, which is exactly the figure the checkbox is there to
-- state.
drawFilterGroup :: AppState -> Int -> FilterGroup -> [Widget Name]
drawFilterGroup state interior group
  | widestChip <= interior - filterGroupColumn = zipWith besideLabel labels (wrapped (interior - filterGroupColumn))
  | otherwise = withAttr dimAttr (txt (filterGroupLabel group)) : map (indented . chipRow) (wrapped (max 1 (interior - 1)))
  where
    chips = [(box, filterChipText state box) | box <- filterGroupBoxes group]
    widestChip = maximum (1 : map (displayWidth . snd) chips)
    wrapped available = wrapFilterChips available chips
    -- The label leads the group's first row; its continuation rows keep the
    -- chips in the same column beneath it.
    labels = padded (filterGroupLabel group) : repeat (Text.replicate filterGroupColumn " ")
    padded label = label <> Text.replicate (max 1 (filterGroupColumn - displayWidth label)) " "
    besideLabel label row = withAttr dimAttr (txt label) <+> chipRow row
    indented row = txt " " <+> row
    chipRow row = hBox (intersperse (txt filterChipGap) (map (drawFilterChip state) row))

-- | Greedy chip wrapping: a chip goes on the current row while it and the gap
-- before it still fit, and starts a new one otherwise. A chip wider than the
-- whole region still gets a row of its own rather than disappearing.
wrapFilterChips :: Int -> [(FilterBox, Text)] -> [[(FilterBox, Text)]]
wrapFilterChips available = foldl place []
  where
    gap = displayWidth filterChipGap
    place [] chip = [[chip]]
    place rows chip = case reverse rows of
      row : earlier
        | rowWidth row + gap + displayWidth (snd chip) <= available ->
            reverse ((row <> [chip]) : earlier)
      _ -> rows <> [[chip]]
    rowWidth row = sum (map (displayWidth . snd) row) + gap * max 0 (length row - 1)

drawFilterChip :: AppState -> (FilterBox, Text) -> Widget Name
drawFilterChip state (box, label) =
  clickable (FilterBoxTarget box) (withAttr attribute (txt label))
  where
    attribute
      | filterPanelFocusedBox state == Just box = selectedAttr
      | filterBoxChecked state.appFilterCriteria box = cardTitleAttr
      | otherwise = dimAttr

-- | One checkbox as it is drawn: the focus marker, the box, its label, and the
-- count that says what checking it alone would admit.
filterChipText :: AppState -> FilterBox -> Text
filterChipText state box =
  marker <> checkbox <> " " <> filterBoxLabel box <> " " <> filterBoxCountText box (facetCount state box)
  where
    marker
      | filterPanelFocusedBox state /= Just box = " "
      | state.appOptions.optionAscii = ">"
      | otherwise = "▌"
    checkbox = if filterBoxChecked state.appFilterCriteria box then "[x]" else "[ ]"

-- | The panel's own two figures: how many cards the criteria are showing, and
-- how many the complete datasets hold.
filterSummaryText :: AppState -> Text
filterSummaryText state =
  "showing " <> facetCountText (filteredCount state) <> " of " <> facetCountText (rawEntryCount state) <> " cards"

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

-- | One column, drawn as the entries its viewport can show rather than as
-- every entry it holds.
--
-- The body is still laid out complete. Every stretch of it this frame skipped
-- is held open by a blank run of exactly the height those entries would have
-- taken, so the viewport's content is as tall as it always was, every drawn
-- item is at the row it always was, and brick's own offset, wheel scrolling,
-- and scroll-into-view keep working against it unchanged (issue #640). What
-- changes is only how much is built: a stretch of some thousands of cards
-- becomes one image.
--
-- The measurement the runs come from is 'appColumnWindows', prepared after the
-- event that produced the last frame. A frame that finds none, or finds one
-- taken at a different width or from a different board, lays the column out in
-- full instead -- correct, and as slow as it always was -- which is what keeps
-- a stale measurement from ever drawing a wrong frame.
drawColumn :: AppState -> Int -> BoardColumn -> Widget Name
drawColumn state columnWidth column =
  BrickTypes.Widget BrickTypes.Fixed BrickTypes.Greedy $ do
    context <- BrickTypes.getContext
    BrickTypes.render (drawColumnRows state columnWidth (BrickTypes.availHeight context) column)

-- | The column, given the rows its viewport will show.
--
-- The height is read from the context rather than from the measurement: it is
-- the rows this very frame has, and the viewport inside takes exactly them.
-- Recording it with the measurement instead would leave the one number a
-- stale value cannot be widened around, since a viewport that grew between
-- two frames crops rows past anything the older height could have covered.
drawColumnRows :: AppState -> Int -> Int -> BoardColumn -> Widget Name
drawColumnRows state columnWidth viewportRows column =
  columnVisibility
    . hLimit columnWidth
    . clickable (ColumnViewport column)
    . viewport (ColumnViewport column) Vertical
    . padTop (Pad 1)
    . vBox
    $ searchRows <> entryRows
  where
    -- The box is part of this column's ordinary layout flow rather than an
    -- overlay: it is drawn first, so the cards below move down by exactly its
    -- rendered height and a resize rewraps both.
    searchRows = maybe [] (pure . drawSearchBox state columnWidth) (searchQueryFor state column)
    body = columnBody state column columnWidth viewportRows
    entryRows
      | null body = [emptyColumnRow state column]
      | otherwise = map drawPiece body
    drawPiece = \case
      ColumnBlank rows -> blankRows rows
      ColumnDrawn item -> drawColumnItem state column item
    columnVisibility = if state.appSelectedColumn == column then visible else id

-- | One stretch of a column's body as a frame draws it: either an item built
-- for real, or the rows the items a frame skipped would have taken.
data ColumnPiece
  = ColumnBlank Int
  | ColumnDrawn ColumnItem
  deriving stock (Eq, Show)

-- | The body one frame of @column@ draws, in order.
--
-- This is the frame's own decision rather than a description of it:
-- 'drawColumn' draws this and nothing else, so how many items it names /is/
-- what a frame costs, and a regression can hold that to the viewport by
-- reading it.
--
-- Without a measurement it names every item, which is what the board always
-- did. With one it names the items the viewport can reach and blank runs of
-- exactly the height of everything it skipped, so the body stays exactly as
-- tall as it was and every drawn item stays at exactly the row it was at.
columnBody :: AppState -> BoardColumn -> Int -> Int -> [ColumnPiece]
columnBody state column columnWidth viewportRows = case columnWindowFor state column columnWidth of
  Nothing -> map ColumnDrawn (columnItemsIn (expandedTrackersFor state column) (entriesFor state column))
  Just window
    | Vector.null window.windowItems -> []
    -- Brick resets a viewport whose content is shorter than itself to the top,
    -- which is the one offset the ranges do not enumerate. A body that short
    -- is at most a viewport's worth of items, so drawing it whole both covers
    -- that reset and stays inside the bound.
    | contentRows window <= viewportRows -> map ColumnDrawn (Vector.toList window.windowItems)
    | otherwise -> laidOut window (drawnItemRanges state column window viewportRows)

-- | The pieces covering a whole body, given the item ranges to build.
laidOut :: ColumnWindow -> [(Int, Int)] -> [ColumnPiece]
laidOut window = walk 0
  where
    walk cursor [] = blank (window.windowTotal - cursor)
    walk cursor ((firstItem, lastItem) : remaining) =
      blank (itemTop firstItem - cursor)
        <> [ColumnDrawn (window.windowItems Vector.! index) | index <- [firstItem .. lastItem]]
        <> walk (itemTop lastItem + (window.windowHeights Vector.! lastItem)) remaining
    itemTop index = window.windowTops Vector.! index
    blank rows = [ColumnBlank rows | rows > 0]

-- | The items one frame of @column@ builds for real.
columnBodyItems :: AppState -> BoardColumn -> Int -> Int -> [ColumnItem]
columnBodyItems state column columnWidth viewportRows =
  [item | ColumnDrawn item <- columnBody state column columnWidth viewportRows]

-- | A blank run exactly @rows@ rows tall, at the width the column gives it.
--
-- One image, whatever its height. Brick's own 'fill' draws the same blank, but
-- vty builds a character fill one row at a time, so a run standing in for five
-- thousand cards would cost five thousand rows of it -- which is the shape of
-- the cost this whole measurement exists to avoid. A background fill is a
-- single node of any size.
--
-- It is drawn at the full width it is offered so the box beside it has no
-- secondary padding to add: that padding /is/ a character fill, and one row of
-- it per row of this would put the cost straight back.
blankRows :: Int -> Widget Name
blankRows rows
  | rows <= 0 = emptyWidget
  | otherwise = BrickTypes.Widget BrickTypes.Fixed BrickTypes.Fixed $ do
      context <- BrickTypes.getContext
      pure BrickTypes.emptyResult {BrickTypes.image = Vty.backgroundFill (BrickTypes.availWidth context) rows}

-- | The row a column with nothing to show draws instead of cards.
emptyColumnRow :: AppState -> BoardColumn -> Widget Name
emptyColumnRow state column = padAll 1 (withAttr dimAttr (txt (emptyColumnText state column)))

-- | Rows an empty column's own row takes: the text, and 'padAll'\'s row
-- either side of it.
emptyColumnRows :: Int
emptyColumnRows = 3

-- | The items a frame builds for real, as disjoint closed ranges into the
-- measurement, in order.
--
-- The offset this frame is cropped at is not the one that was read back:
-- brick chooses it during this very render, after the measurement was taken.
-- So the ranges cover every offset it can choose, which is a closed set.
--
--   * The recorded offset itself, when nothing moves it. Brick leaves an
--     untouched offset exactly where it is, even one the content has since
--     shrunk past.
--   * The recorded offset one wheel step either way, clamped the way
--     'Brick.Widgets.Core.viewport' clamps a scroll request -- to zero, and to
--     the last offset the content can be shown at. That clamp is what makes a
--     press after the content shrank land somewhere other than beside the
--     recorded offset.
--   * Everywhere a pending scroll-into-view can put it. Brick honors a
--     'visible' request by moving the offset just far enough to show the
--     widget that asked, so the reachable offsets run from a viewport ending
--     at the selected card to one starting at it. Covering them is what keeps
--     the card the selection just moved to from arriving in a blank run.
--
-- The one offset brick chooses that is not in that set is the reset to the top
-- it performs when the whole content is shorter than the viewport -- and a
-- body that short is drawn complete by the caller, so it is covered by not
-- being windowed at all.
--
-- Kept apart rather than spanned. A selection at the far end of a long column
-- from the viewport is exactly the case a single covering range would answer
-- with the whole column -- which is the cost this whole measurement exists to
-- avoid -- so the reaches are merged only where they actually meet.
drawnItemRanges :: AppState -> BoardColumn -> ColumnWindow -> Int -> [(Int, Int)]
drawnItemRanges state column window viewportRows = mergeRanges (scrollReaches <> selectionReach)
  where
    viewRows = max 1 viewportRows
    lastOffset = max 0 (contentRows window - viewRows)
    clampOffset value = max 0 (min lastOffset value)
    offsets =
      [ window.windowTop,
        clampOffset (window.windowTop + columnScrollStep),
        clampOffset (window.windowTop - columnScrollStep)
      ]
    scrollReaches = map reachFrom offsets
    reachFrom offset =
      itemsBetween window (offset - window.windowLeading) (offset - window.windowLeading + viewRows)
    selectionReach = case selectedItemExtent state column window of
      Nothing -> []
      Just (top, bottom) -> [itemsBetween window (top - viewRows) (bottom + viewRows)]

-- | The rows a measured column's viewport content occupies: its body, and the
-- padding and search box above it.
contentRows :: ColumnWindow -> Int
contentRows window = window.windowLeading + window.windowTotal

-- | Ranges in ascending order, with overlapping and touching ones joined, so
-- no item is drawn twice and the blank runs between them are the rows nothing
-- claimed.
mergeRanges :: [(Int, Int)] -> [(Int, Int)]
mergeRanges = foldr join [] . sortOn fst
  where
    join range [] = [range]
    join (first, final) ((nextFirst, nextFinal) : remaining)
      | final + 1 >= nextFirst = (first, max final nextFinal) : remaining
      | otherwise = (first, final) : (nextFirst, nextFinal) : remaining

-- | The items covering the rows @[low, high)@, clamped to the measurement.
itemsBetween :: ColumnWindow -> Int -> Int -> (Int, Int)
itemsBetween window low high = (first, max first final)
  where
    first = itemCoveringRow window.windowTops low
    final = itemCoveringRow window.windowTops (high - 1)

-- | The item whose rows contain @row@: the last one starting at or before it,
-- and the first item for anything above the body.
--
-- Bisection rather than a walk, so finding the window near the end of a long
-- column costs no more than finding it near the beginning -- which is the
-- other half of the bound, and the half a linear index would quietly lose.
itemCoveringRow :: Vector Int -> Int -> Int
itemCoveringRow tops row = go 0 (Vector.length tops - 1)
  where
    go low high
      | low >= high = low
      | otherwise =
          let middle = (low + high + 1) `div` 2
           in if tops Vector.! middle <= row then go middle high else go low (middle - 1)

-- | The rows the selected entry occupies, when this column is the one a
-- pending scroll-into-view would move.
--
-- 'Nothing' when nothing is going to move: another column is selected, or the
-- selection is already where the user left it and no path asked for it to be
-- revealed.
selectedItemExtent :: AppState -> BoardColumn -> ColumnWindow -> Maybe (Int, Int)
selectedItemExtent state column window
  | state.appSelectedColumn /= column = Nothing
  | not state.appEnsureSelectionVisible = Nothing
  | first >= Vector.length window.windowItemRows = Nothing
  | window.windowItemRows Vector.! first /= selected = Nothing
  | otherwise = Just (window.windowTops Vector.! first, (window.windowTops Vector.! final) + (window.windowHeights Vector.! final))
  where
    selected = selectedRow state column
    first = firstItemAtRow window.windowItemRows selected
    final = lastWhile first
    lastWhile index
      | next < Vector.length window.windowItemRows, window.windowItemRows Vector.! next == selected = lastWhile next
      | otherwise = index
      where
        next = index + 1

-- | The first item drawing entry row @row@, or one past the end when none
-- does.
firstItemAtRow :: Vector Int -> Int -> Int
firstItemAtRow rows row = go 0 (Vector.length rows)
  where
    go low high
      | low >= high = low
      | otherwise =
          let middle = (low + high) `div` 2
           in if rows Vector.! middle < row then go (middle + 1) high else go low middle

-- | One item of a column body, drawn.
drawColumnItem :: AppState -> BoardColumn -> ColumnItem -> Widget Name
drawColumnItem state column = \case
  ColumnTrackerHeader row tracker expanded -> drawTrackerHeader state column row tracker expanded
  ColumnStandaloneLabel _ -> padLeftRight 2 (withAttr dimAttr (txt standaloneLabel))
  ColumnCard row entry lastInTracker -> drawCard state column row entry lastInTracker

-- | The label above a run of untracked cards.
standaloneLabel :: Text
standaloneLabel = "STANDALONE"

-- | The rows the same item takes once drawn.
--
-- Every arm is read off the widget beside it rather than restated: a card is
-- its interior lines plus the frame and the row beneath it, a header is its
-- wrapped text plus the row above it. That is the whole reason the interior
-- lines are a function of their own -- measuring and drawing a card cannot
-- disagree about its height while both ask 'cardLines'.
columnItemHeight :: AppState -> Int -> ColumnItem -> Int
columnItemHeight state columnWidth = \case
  ColumnTrackerHeader _ tracker expanded -> trackerHeaderHeight state columnWidth tracker expanded
  ColumnStandaloneLabel _ -> 1
  ColumnCard _ entry _ -> cardHeight state columnWidth entry

-- | A card's rows: the frame's two border rows, the interior it sizes itself
-- to, and 'drawCard'\'s row of padding beneath it.
cardHeight :: AppState -> Int -> ColumnEntry -> Int
cardHeight state columnWidth entry =
  length (cardLines (cardEnv state) False entry (cardInnerWidth state columnWidth entry)) + 3

-- | An epic header's rows: the row 'drawTrackerHeader' pads above it, and the
-- rows its text wraps to at the width the marker and badges leave.
trackerHeaderHeight :: AppState -> Int -> Tracker -> Bool -> Int
trackerHeaderHeight state columnWidth tracker expanded =
  1 + max 1 (length (wrapTextToLines defaultWrapSettings headerWidth headerText))
  where
    headerWidth = max 0 (columnWidth - columnRowOverhead - badgeCells state (IssueItem tracker.trackerIssue))
    headerText = trackerHeaderText state.appOptions.optionAscii expanded tracker

-- | Cells every card and header row spends before its own content: the
-- padding a column keeps either side, and the one-cell selection marker.
columnRowOverhead :: Int
columnRowOverhead = 3

-- | Cells the branch glyph beside a tracked card takes. Both the last-child
-- and the continuing glyph are three cells wide in either glyph set, so a
-- card is laid out at the same width wherever in its group it sits.
branchPrefixWidth :: Int
branchPrefixWidth = 3

-- | The width a card lays its interior out at, once the marker, the badges,
-- the branch glyph, and the frame have taken theirs.
cardInnerWidth :: AppState -> Int -> ColumnEntry -> Int
cardInnerWidth state columnWidth entry = max 0 (cardFrameWidth - cardFrameOverhead)
  where
    cardFrameWidth =
      max 0 (columnWidth - columnRowOverhead - badgeCells state (entryItem entry) - branchCells)
    branchCells = case entry of
      Tracked _ _ -> branchPrefixWidth
      Standalone _ -> 0
      TrackerHeader _ -> 0

-- | Cells the solve and review badges beside one item take together.
badgeCells :: AppState -> BoardItem -> Int
badgeCells state item = badgeWidth (solveBadgePart state item) + badgeWidth (reviewBadgePart state item)

badgeWidth :: Maybe (AttrName, Text) -> Int
badgeWidth = maybe 0 (displayWidth . snd)

-- | Rows one wheel press moves a column, as
-- "Kanban.UI.Events" dispatches it. Named here because the frame has to know
-- it: the offset a frame is cropped at can be one press away from the one it
-- chose its range against, so the range is widened by exactly this.
columnScrollStep :: Int
columnScrollStep = 3

-- | The measurement this frame may draw @column@ from, or 'Nothing' when it
-- must lay the column out itself.
--
-- Recomputing the signature is a handful of comparisons -- an 'Int', a query,
-- the expanded set, and the badge widths of the live sessions -- and never a
-- pass over the column, which is what makes checking cheaper than trusting.
-- The deadline is the other half: every card was measured with one @now@, and
-- a measurement outlives its own relative ages only until the earliest of
-- them changes wording.
columnWindowFor :: AppState -> BoardColumn -> Int -> Maybe ColumnWindow
columnWindowFor state column columnWidth = do
  window <- Map.lookup column state.appColumnWindows
  if window.windowSignature == columnSignature state column columnWidth && not (measurementExpired state window)
    then Just window
    else Nothing

measurementExpired :: AppState -> ColumnWindow -> Bool
measurementExpired state window = maybe False (state.appNow >=) window.windowDeadline

-- | Everything the measurement of one column at one width was taken from,
-- as three values a frame compares in constant time.
columnSignature :: AppState -> BoardColumn -> Int -> ColumnSignature
columnSignature state column columnWidth =
  ColumnSignature
    { signatureContent = columnContentKey state column,
      signatureWidth = columnWidth,
      signatureLayout = state.appLayoutEpoch
    }

-- | The board-wide inputs a column measurement is taken under.
--
-- Every part of it is read in constant time -- three roster sizes and two
-- settings -- so collecting it costs the same on a dashboard holding one
-- agent session and one holding a thousand. It is still collected here rather
-- than in a frame's own check so that a frame compares one 'Int'
-- ('appLayoutEpoch') rather than a record, and so that the reasoning behind
-- the counts ('Kanban.UI.Types.ColumnBadges') lives in one place.
layoutInputs :: AppState -> LayoutInputs
layoutInputs state =
  LayoutInputs
    { layoutBadges = columnBadgeCounts state,
      layoutAscii = state.appOptions.optionAscii,
      layoutExcerptLines = cardExcerptLimit state.appConfig
    }

-- | The layout inputs a dashboard has before anything has been measured or
-- any agent session started: no badges, and whatever glyph set and excerpt
-- budget it launched under.
--
-- The one place a fresh 'appLayoutInputs' is spelled, so a launch and a test
-- seat it identically and the first settle finds nothing to move.
unmeasuredLayoutInputs :: Options -> ResolvedConfig -> LayoutInputs
unmeasuredLayoutInputs options config =
  LayoutInputs
    { layoutBadges = ColumnBadges 0 0 0,
      layoutAscii = options.optionAscii,
      layoutExcerptLines = cardExcerptLimit config
    }

columnBadgeCounts :: AppState -> ColumnBadges
columnBadgeCounts state =
  ColumnBadges
    { badgeSolveCount = Map.size state.appSolveSessions,
      badgeReviewCount = Map.size state.appReviewSessions,
      badgePullRequestCount = Map.size state.appPullRequestReviewSessions
    }

-- | Lay one column out: what it draws, how tall each of those is, and where
-- the viewport was when this was taken.
--
-- This is the pass over the column the frames after it reuse. It costs the
-- column once per change to what it shows -- a refresh, a criteria or query
-- edit, an expansion, a resize, a badge appearing, or the earliest relative
-- age on it changing wording -- and nothing per frame in between.
measureColumnWindow :: AppState -> BoardColumn -> Int -> Int -> ColumnWindow
measureColumnWindow state column columnWidth top =
  ColumnWindow
    { windowSignature = columnSignature state column columnWidth,
      windowItems = Vector.fromList items,
      windowItemRows = Vector.fromList (map columnItemRow items),
      windowSelectableRows = Vector.fromList (visibleRowsIn expanded entries),
      windowTops = Vector.fromList (take (length heights) (scanl (+) 0 heights)),
      windowHeights = Vector.fromList heights,
      windowTotal = if null items then emptyColumnRows else sum heights,
      windowLeading = columnTopPadding + searchBoxHeight state column columnWidth,
      windowShownCount = length entries,
      windowAdmittedCount = length (entriesForBoard state.appVisibleBoard column),
      windowDeadline = deadline,
      windowTop = top
    }
  where
    entries = entriesFor state column
    expanded = expandedTrackersFor state column
    items = columnItemsIn expanded entries
    heights = map (columnItemHeight state columnWidth) items
    deadline = case [nextRelativeAgeChange state.appNow (itemUpdatedAt (entryItem entry)) | ColumnCard _ entry _ <- items] of
      [] -> Nothing
      changes -> Just (minimum changes)

-- | Rows 'drawColumn' pads above its body.
columnTopPadding :: Int
columnTopPadding = 1

-- | Rows the search box takes at the top of a column, or none when no box is
-- open there.
searchBoxHeight :: AppState -> BoardColumn -> Int -> Int
searchBoxHeight state column columnWidth = case searchQueryFor state column of
  Nothing -> 0
  Just query -> length (searchBoxLines (max 0 (columnWidth - searchBoxOverhead)) query) + searchBoxFrameRows

-- | Rows the search box spends on itself: its two border rows, and the row of
-- padding beneath it.
searchBoxFrameRows :: Int
searchBoxFrameRows = 3

-- | When a card's @updated N ago@ next changes wording.
--
-- 'Kanban.UI.Util.relativeAge' counts in whole minutes below an hour, whole
-- hours below a day, and whole days above it, so a card's rows are settled
-- until the boundary of whichever unit it is currently reported in. The
-- earliest such boundary in a column is what dates that column's measurement:
-- before it no card's wording -- and so no card's wrapping, and so no card's
-- height -- can have moved.
--
-- Counted forward from @updatedAt@ rather than from @now@. The boundaries are
-- whole steps from the timestamp and an age is a fraction of a second wide, so
-- adding a whole number of seconds to @now@ instead would put the deadline up
-- to a second past the boundary and let an event in that gap reuse heights the
-- wording had already outgrown.
nextRelativeAgeChange :: UTCTime -> UTCTime -> UTCTime
nextRelativeAgeChange now updatedAt = addUTCTime (fromIntegral ((seconds `div` step + 1) * step)) updatedAt
  where
    seconds = max 0 (floor (diffUTCTime now updatedAt) :: Int)
    step
      | seconds < 3600 = 60
      | seconds < 86400 = 3600
      | otherwise = 86400

-- | Record what every column measured to, given the geometry brick reported
-- for each after the last frame.
--
-- The one writer of 'appColumnWindows', applied by
-- 'Kanban.UI.Events.handleEvent' after every event. A column whose geometry
-- brick cannot report has never been drawn -- before the first frame, or
-- after a layer covered the board -- and drops its measurement rather than
-- keeping one taken against a width nothing confirms.
--
-- A measurement whose signature still holds is kept and only re-aimed: the
-- offset and viewport height move with the frame, which is what a wheel
-- press and a resize of the terminal's height cost, and neither is a reason
-- to lay the column out again.
refreshColumnWindows :: [(BoardColumn, Maybe (Int, Int))] -> AppState -> AppState
refreshColumnWindows geometry state = settled {appColumnWindows = foldl settle settled.appColumnWindows geometry}
  where
    -- The board-wide inputs first, because every column signature below reads
    -- the epoch this decides.
    settled = settleLayoutEpoch state
    settle windows (column, Nothing) = Map.delete column windows
    settle windows (column, Just (columnWidth, top)) =
      Map.insert column (settleColumn column columnWidth top (Map.lookup column windows)) windows
    settleColumn column columnWidth top existing = case existing of
      Just window
        | window.windowSignature == columnSignature settled column columnWidth,
          not (measurementExpired settled window) ->
            window {windowTop = top}
      _ -> measureColumnWindow settled column columnWidth top

-- | Move 'appLayoutEpoch' when the board-wide inputs to a column measurement
-- have moved, and record what they are now.
settleLayoutEpoch :: AppState -> AppState
settleLayoutEpoch state
  | inputs == state.appLayoutInputs = state
  | otherwise = state {appLayoutEpoch = state.appLayoutEpoch + 1, appLayoutInputs = inputs}
  where
    inputs = layoutInputs state

-- | What a column with nothing in it says, in §7's declared precedence.
--
-- A column a query emptied, one the criteria emptied, and one that is simply
-- empty are three different facts, and none of them may be confused with a
-- loading state. The order follows the pipeline: search narrows what the
-- criteria admitted, so a query can only be blamed for a column that had
-- something to narrow — if filtering already produced zero, the filter is what
-- the row names.
--
-- Both questions are asked of /this/ column rather than of the criteria as a
-- whole. A criteria set that empties Issues says nothing about Active, and a
-- column that was already empty under the default criteria is intrinsically
-- empty however much the filter is hiding elsewhere. That per-column baseline
-- is 'appBoard' itself: the defaults admit the open board unchanged, by
-- identity rather than by a comparison somebody has to keep true.
emptyColumnText :: AppState -> BoardColumn -> Text
emptyColumnText state column
  | isJust (activeQueryFor state column), not (null eligible) = "No search matches"
  | criteriaAreFiltering state, not (null baseline) = "No filter matches"
  | otherwise = "No items"
  where
    eligible = entriesForBoard state.appVisibleBoard column
    baseline = entriesForBoard state.appBoard column

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

-- | One card. @lastInTracker@ is whether it is the last child of its group,
-- which is the only thing about the rest of the column a card needs and is
-- decided once for the whole column by 'Kanban.UI.Search.columnItemsIn'.
drawCard :: AppState -> BoardColumn -> Int -> ColumnEntry -> Bool -> Widget Name
drawCard state column row entry lastInTracker =
  padLeftRight 1
    . padBottom (Pad 1)
    . clickable (CardTarget column row)
    $ visibility card
  where
    selected = state.appSelectedColumn == column && selectedRow state column == row
    visibility = if selected && state.appEnsureSelectionVisible then visible else id
    card =
      (if selected then withAttr selectedAttr (txt marker) else txt " ")
        <+> drawBadge (solveBadgePart state (entryItem entry))
        <+> drawBadge (reviewBadgePart state (entryItem entry))
        <+> branchPrefix state entry lastInTracker
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
        -- The corners are the only two cells of a horizontal row the run does
        -- not fill, so this is the width Brick's 'hBorder' greedily took
        -- between them and the frame stays exactly as wide as its interior.
        horizontalRun = txt (Text.replicate (max 0 (BrickTypes.availWidth context - 2)) (Text.singleton horizontal))
    BrickTypes.render
      . vBox
      $ [ hBox [withAttr topBottomAttribute (txt topLeft), withAttr topBottomAttribute horizontalRun, withAttr statusAttribute (txt topRight)],
          hBox
            [ withAttr leftAttribute verticalEdge,
              withAttr interiorAttribute (padLeftRight 1 (padRight Max (vBox contents))),
              withAttr statusAttribute verticalEdge
            ],
          hBox [withAttr topBottomAttribute (txt bottomLeft), withAttr topBottomAttribute horizontalRun, withAttr statusAttribute (txt bottomRight)]
        ]
  where
    item = entryItem entry
    -- Every glyph the frame draws, the horizontal run included. Drawing that
    -- run as text rather than as Brick's 'hBorder' is what keeps §10's color
    -- on it: 'sidebarControl' records the same hazard, that a Brick border
    -- widget draws its run under @borderAttr@, which the theme does not name,
    -- so the run would land on the attribute map's default and lose the
    -- selection or status color the corners beside it keep. Card glyphs have
    -- always been chosen here rather than taken from 'cardBorderStyle' --
    -- §10's corners are rounded, which no 'BorderStyle' offers -- and the
    -- horizontal one now joins them, leaving one place a mode's glyphs are
    -- decided.
    (topLeft, topRight, bottomLeft, bottomRight, vertical, horizontal)
      | env.cardOptions.optionAscii = ("+", "+", "+", "+", '|', '-')
      | otherwise = ("╭", "╮", "╰", "╯", '│', '─')
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
    $ marker
      <+> drawBadge (solveBadgePart state (IssueItem tracker.trackerIssue))
      <+> drawBadge (reviewBadgePart state (IssueItem tracker.trackerIssue))
      <+> withAttr headerAttribute (txtWrap headerText)
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

-- | The branch glyph a tracked card draws under its epic.
--
-- Whether this is the group's last child arrives from the caller. It used to
-- be answered here by indexing the column's entry list at @row + 1@ -- which,
-- through a 'drop', walked the column once per card and made drawing one
-- quadratic in its length. The grouping already knows, so it says.
branchPrefix :: AppState -> ColumnEntry -> Bool -> Widget Name
branchPrefix state entry lastInTracker = case entry of
  Standalone _ -> emptyWidget
  Tracked _ _ -> withAttr trackerAttr (txt branch)
  TrackerHeader _ -> emptyWidget
  where
    branch
      | state.appOptions.optionAscii = if lastInTracker then "`- " else "+- "
      | lastInTracker = "└─ "
      | otherwise = "├─ "

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

-- | The badge one item's live solve draws beside its card, as the attribute
-- and the glyph rather than as the widget.
--
-- Split out because a badge is part of a card's /geometry/: it takes cells
-- from the width the frame lays its interior out at. Measuring a column asks
-- for the width and drawing asks for the widget, and both read this, so
-- neither can assume a badge the other did not.
solveBadgePart :: AppState -> BoardItem -> Maybe (AttrName, Text)
solveBadgePart _ (PullRequestItem _) = Nothing
solveBadgePart state (IssueItem issue) = do
  session <- Map.lookup issue.issueNumber state.appSolveSessions
  pure (solveSessionAttribute session, solvePhaseGlyph state session)

drawBadge :: Maybe (AttrName, Text) -> Widget Name
drawBadge = maybe emptyWidget (\(attribute, glyph) -> withAttr attribute (txt glyph))

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

-- | 'solveBadgePart' for the review half: the pull-request review badge on a
-- pull request, and the issue review badge on an issue.
reviewBadgePart :: AppState -> BoardItem -> Maybe (AttrName, Text)
reviewBadgePart state (PullRequestItem pullRequest) = do
  session <- Map.lookup pullRequest.pullRequestNumber state.appPullRequestReviewSessions
  pure (pullRequestSessionAttribute session, pullRequestPhaseGlyph state session)
reviewBadgePart state (IssueItem issue) = do
  session <- Map.lookup issue.issueNumber state.appReviewSessions
  pure (reviewPhaseAttribute session.sessionPhase, reviewPhaseGlyph state session)

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

-- | How many rows the base frame keeps for itself below an open overlay: the
-- footer it is about to draw, plus its own bottom border.
--
-- Measured by rendering the very widget 'drawBase' draws, rather than by
-- predicting its height. The footer is variable-height — the hint row, the
-- freshness row, and a notice drawn with 'txtWrap', which takes as many rows
-- as the width and the notice between them decide — so a fullscreen box that
-- reserved a fixed number would cover a wrapped notice on one terminal and
-- leave a gap above a bare footer on another. This is the only prediction
-- that cannot drift from what is drawn: it /is/ what is drawn.
--
-- @terminalWidth@ is the whole terminal's; the footer's own width is that
-- less whatever side borders the frame is drawing, which is the one thing
-- 'drawBase' decides differently between its two border styles.
baseFooterRows :: AppState -> Int -> BrickTypes.RenderM Name Int
baseFooterRows state terminalWidth = do
  rendered <- render (hLimit footerWidth (drawFooter state))
  pure (Vty.imageHeight rendered.image + baseBottomBorderRows)
  where
    footerWidth
      | usesOpenBorders state = terminalWidth
      | otherwise = max 0 (terminalWidth - 2)

-- | The frame's bottom edge, which both border styles draw as one row: the
-- closing 'hBorder' under the open style, and the box border's own bottom
-- under the other.
baseBottomBorderRows :: Int
baseBottomBorderRows = 1

drawFooter :: AppState -> Widget Name
drawFooter state =
  padLeftRight 1
    . vBox
    $ [ withAttr footerAttr (txt (boardHintLine state)),
        withAttr dimAttr (txt (boardFreshnessText state <> " · " <> completedHistoryStatusText state)),
        maybe emptyWidget (withAttr noticeAttr . txtWrap) (shownNotice state)
      ]

-- | Which hint line the footer is showing: the surface that currently has the
-- keyboard names its own keys, and the board's line otherwise.
--
-- An open overlay outranks both of the others. Nothing clears a focused
-- filter box or a live search when an overlay opens over them, so those two
-- states can still be populated underneath one; whatever they hold, the keys
-- reaching the keyboard are the overlay's, and the row has to name those.
boardHintLine :: AppState -> Text
boardHintLine state = case state.appOverlay of
  Just overlay -> overlayHintLine state overlay
  Nothing
    | isJust (filterPanelFocusedBox state) -> filterFooterHintLine
    | isJust (focusedSearch state) -> searchFooterHintLine
    | otherwise -> boardFooterHintLine state.appOperatingMode (criteriaAreFiltering state)

-- | The hint line an open overlay shows in place of the board's.
overlayHintLine :: AppState -> Overlay -> Text
overlayHintLine state = footerHintRow . overlayHintChips state

-- | Each overlay's own hint chips, from the module that answers those keys.
--
-- This module writes none of that text. The details and help overlays are
-- scopes of the table in "Kanban.UI.Keys" and project from it exactly as the
-- board's line does; the other five declare their chips beside their own
-- decoders, and the three live-agent overlays resolve theirs against the
-- focused session so the row follows its effective mode. What is here is the
-- routing and nothing else -- the same reason the help overlay's rows are
-- assembled rather than transcribed.
--
-- The two scopes of the base table follow the operating mode exactly as the
-- board's own line does, and for the same reason: a details overlay whose
-- footer named `r`, `S`, and `A` on a board that loads no provider would
-- advertise three keys that answer with a refusal. `x` is the fourth chip
-- this footer carries and it stays in every mode, because the work it
-- terminates can outlive the roster that started it (issue #546).
overlayHintChips :: AppState -> Overlay -> [Text]
overlayHintChips state = \case
  HelpOverlay -> map footerHint (modeScopeBindings state.appOperatingMode HelpScope)
  DetailsOverlay _ -> map footerHint (modeScopeBindings state.appOperatingMode DetailsScope)
  SettingsOverlay -> settingsFooterHints
  ProcessesOverlay -> processesFooterHints
  IncidentsOverlay -> incidentsFooterHints
  SolveChooser _ _ -> solveChooserFooterHints
  SolveOverlay issueNumber -> sessionOverlayHints solveSessionOps issueNumber state
  PullRequestReviewOverlay number -> sessionOverlayHints pullRequestSessionOps number state
  ReviewOverlay issueNumber -> sessionOverlayHints reviewSessionOps issueNumber state

-- | The hint line a focused filter panel shows in place of the board's.
--
-- Written here rather than projected from the table in "Kanban.UI.Keys" for
-- the same reason search's is: none of these keys is a binding while the panel
-- has focus. @d@ restores the defaults rather than toggling the drainer, and
-- the arrows move between checkboxes rather than between columns, so the
-- board's line would state both of them wrongly.
filterFooterHintLine :: Text
filterFooterHintLine =
  footerHintRow
    [ "j/k/↑/↓ box",
      "←/→ group",
      "space toggle",
      "d defaults",
      "s search",
      "F/esc close"
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
--
-- This is the dual-mode line, which is every chip the table declares. The mode
-- is a parameter of 'boardFooterHintLine' rather than of this alias because a
-- board that loads no provider draws a shorter one.
footerHintLine :: Text
footerHintLine = boardFooterHintLine DualMode False

-- | The same line with the filter chip marked while the criteria are hiding
-- cards.
--
-- The marker is the only report a non-default criteria set gets once the panel
-- is hidden, and a board that is quietly showing a subset of its work has to
-- say so somewhere that is always on screen. It marks the existing chip rather
-- than adding one, so the line's inventory still comes from the table.
--
-- The inventory follows the operating mode, through 'modeScopeBindings'
-- rather than a second list here: a board that loads no provider offers none
-- of the four agent bindings, so naming them along the bottom of the screen
-- would advertise four keys that answer with a refusal. They are still
-- dispatched -- 'Kanban.UI.Events.boardActionGate' is where a press on one
-- lands -- so this hides a chip and never a key.
boardFooterHintLine :: OperatingMode -> Bool -> Text
boardFooterHintLine mode filtering = footerHintRow (map chip (modeScopeBindings mode BoardScope))
  where
    chip candidate
      | filtering, candidate.bindingAction == ShowFilter = footerHint candidate <> "*"
      | otherwise = footerHint candidate

-- | The hint line a live search shows in place of the board's.
--
-- Written here rather than projected from the table in "Kanban.UI.Keys"
-- because none of these keys is a binding: while the box is open @h@ and @l@
-- are text, and the arrows move the search rather than the column selection.
-- The board's line names those keys the other way round — @h/← prev column@,
-- @l/→ next column@ — so showing it here would state both of them wrongly.
searchFooterHintLine :: Text
searchFooterHintLine =
  footerHintRow
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
