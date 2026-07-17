module Kanban.UI
  ( runDashboard,
  )
where

import Brick
import Brick.BChan (BChan, newBChan, writeBChan)
import Brick.Widgets.Border (borderWithLabel, hBorder, hBorderWithLabel, vBorder)
import Brick.Widgets.Border.Style (BorderStyle (..), ascii, unicode, unicodeBold)
import Brick.Widgets.Center (centerLayer)
import qualified Brick.Types as BrickTypes
import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forever, void)
import Control.Monad.IO.Class (liftIO)
import Data.List (findIndex, intersperse)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (TimeZone, UTCTime, defaultTimeLocale, diffUTCTime, formatTime, getCurrentTime, getCurrentTimeZone, utcToZonedTime)
import qualified Graphics.Vty as Vty
import Kanban.Cache
  ( CacheLoad (..),
    UsageCacheLoad (..),
    loadRepositoryCache,
    loadUsageCache,
    writeRepositoryCache,
    writeUsageCache,
  )
import Kanban.CLI (BorderPolicy (..), ColorPolicy (..), Options (..))
import Kanban.Claude (fetchClaudeUsage)
import Kanban.Codex (fetchCodexUsage)
import Kanban.Domain
import Kanban.Drainer
  ( DrainerController,
    DrainerState (..),
    DrainerStatus (..),
    discoverDrainerController,
    drainerIsRunning,
    queryDrainerStatus,
    setDrainerRunning,
  )
import Kanban.GitHub (GitHubResult (..), fetchGitHubSnapshot, snapshotWarnings)
import Kanban.Layout (responsiveColumnWidths, responsiveOpenColumnWidths)
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.Text (excerpt, sanitizeText)
import Kanban.Tracker (renderTrackerDiagnostic, trackerDiagnosticsForIssue)
import Kanban.Workflow (CardStatus (..), deriveBoard, entryItem, isApproved, isProblem, pullRequestStatus)
import System.Timeout (timeout)

data Name
  = BoardViewport
  | ColumnViewport BoardColumn
  | DetailsViewport
  | CardTarget BoardColumn Int
  | DetailsPanel
  | DrainerButton
  deriving stock (Eq, Ord, Show)

data Overlay = HelpOverlay | DetailsOverlay BoardItem
  deriving stock (Eq, Show)

data AppEvent
  = BoardRefreshFinished (Either ProviderError GitHubResult)
  | CodexRefreshFinished (Either ProviderError UsageSnapshot)
  | ClaudeRefreshFinished (Either ProviderError UsageSnapshot)
  | DrainerStatusRefreshed (Either Text DrainerStatus)
  | DrainerToggleFinished (Either Text DrainerStatus)

data AppState = AppState
  { appRepository :: Repository,
    appBoard :: Board,
    appUsage :: Map UsageProvider UsageSnapshot,
    appUsageFreshness :: Map UsageProvider Freshness,
    appSelectedColumn :: BoardColumn,
    appSelectedRows :: Map BoardColumn Int,
    appEnsureSelectionVisible :: Bool,
    appExpandedTrackers :: Set Int,
    appSidebarVisible :: Bool,
    appOverlay :: Maybe Overlay,
    appNotice :: Maybe Text,
    appBoardFreshness :: Freshness,
    appLastSuccessfulFetch :: Maybe UTCTime,
    appIssuesTruncated :: Bool,
    appPullRequestsTruncated :: Bool,
    appDrainerController :: Either Text DrainerController,
    appDrainerStatus :: DrainerStatus,
    appDrainerBusy :: Bool,
    appEventChannel :: BChan AppEvent,
    appNow :: UTCTime,
    appTimeZone :: TimeZone,
    appOptions :: Options
  }

runDashboard :: Options -> Repository -> IO ()
runDashboard options repository = do
  now <- getCurrentTime
  timeZone <- getCurrentTimeZone
  cacheLoad <-
    if options.optionNoCache
      then pure CacheAbsent
      else loadRepositoryCache repository
  usageCacheLoad <-
    if options.optionNoCache
      then pure UsageCacheAbsent
      else loadUsageCache
  drainerController <- discoverDrainerController
  eventChannel <- newBChan 8
  let (initialBoard, initialFreshness, initialFetchedAt, issuesTruncated, pullRequestsTruncated, initialNotice) = initialBoardState now cacheLoad
      (initialUsage, initialUsageFreshness, usageNotice) = initialUsageState usageCacheLoad
  let initialState =
        AppState
          { appRepository = repository,
            appBoard = initialBoard,
            appUsage = initialUsage,
            appUsageFreshness = initialUsageFreshness,
            appSelectedColumn = Issues,
            appSelectedRows = Map.fromList [(column, 0) | column <- allColumns],
            appEnsureSelectionVisible = True,
            appExpandedTrackers = Set.empty,
            appSidebarVisible = True,
            appOverlay = Nothing,
            appNotice = Just (initialNotice <> maybe "" (" · " <>) usageNotice),
            appBoardFreshness = initialFreshness,
            appLastSuccessfulFetch = initialFetchedAt,
            appIssuesTruncated = issuesTruncated,
            appPullRequestsTruncated = pullRequestsTruncated,
            appDrainerController = drainerController,
            appDrainerStatus =
              case drainerController of
                Right _ -> DrainerStatus DrainerStarting "checking…"
                Left message -> DrainerStatus DrainerError (sanitizeText message),
            appDrainerBusy = False,
            appEventChannel = eventChannel,
            appNow = now,
            appTimeZone = timeZone,
            appOptions = options
          }
  (_, finalVty) <- customMainWithDefaultVty (Just eventChannel) application initialState
  Vty.shutdown finalVty

initialBoardState :: UTCTime -> CacheLoad -> (Board, Freshness, Maybe UTCTime, Bool, Bool, Text)
initialBoardState now cacheLoad = case cacheLoad of
  CacheLoaded snapshot ->
    ( deriveBoard defaultWorkflowConfig snapshot,
      Fresh snapshot.snapshotFetchedAt,
      Just snapshot.snapshotFetchedAt,
      snapshot.snapshotIssuesTruncated,
      snapshot.snapshotPullRequestsTruncated,
      appendWarnings "Cached GitHub snapshot loaded · press r to refresh" (snapshotWarnings snapshot)
    )
  CacheAbsent ->
    ( deriveBoard defaultWorkflowConfig (RepoSnapshot [] [] now False False),
      NotLoaded,
      Nothing,
      False,
      False,
      "No cached GitHub snapshot · press r to refresh"
    )
  CacheInvalid warning ->
    ( deriveBoard defaultWorkflowConfig (RepoSnapshot [] [] now False False),
      NotLoaded,
      Nothing,
      False,
      False,
      warning <> " · press r to refresh"
    )

initialUsageState :: UsageCacheLoad -> (Map UsageProvider UsageSnapshot, Map UsageProvider Freshness, Maybe Text)
initialUsageState cacheLoad = case cacheLoad of
  UsageCacheAbsent -> (Map.empty, defaultFreshness Map.empty, Nothing)
  UsageCacheLoaded snapshots -> (snapshots, defaultFreshness snapshots, Nothing)
  UsageCacheInvalid warning -> (Map.empty, defaultFreshness Map.empty, Just warning)
  where
    defaultFreshness :: Map UsageProvider UsageSnapshot -> Map UsageProvider Freshness
    defaultFreshness snapshots =
      Map.fromList
        [ (Codex, maybe NotLoaded (Fresh . (.usageFetchedAt)) (Map.lookup Codex snapshots)),
          (Claude, maybe NotLoaded (Fresh . (.usageFetchedAt)) (Map.lookup Claude snapshots))
        ]

application :: App AppState AppEvent Name
application =
  App
    { appDraw = drawApplication,
      appChooseCursor = neverShowCursor,
      appHandleEvent = handleEvent,
      appStartEvent = startApplication,
      appAttrMap = themeFor . (.appOptions)
    }

drawApplication :: AppState -> [Widget Name]
drawApplication state =
  case state.appOverlay of
    Nothing -> [drawBase state]
    Just overlay -> [drawOverlay state overlay, drawBase state]

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

drainerStatusAttr :: DrainerStatus -> AttrName
drainerStatusAttr status = case status.drainerState of
  DrainerOff -> neutralAttr
  DrainerOn -> readyAttr
  DrainerStarting -> pendingAttr
  DrainerStopping -> pendingAttr
  DrainerWarning -> pendingAttr
  DrainerError -> problemAttr

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

usageStatusAttribute :: Freshness -> AttrName
usageStatusAttribute Loading = noticeAttr
usageStatusAttribute (Stale _ _) = pendingAttr
usageStatusAttribute (Unavailable _) = problemAttr
usageStatusAttribute (Unsupported _) = dimAttr
usageStatusAttribute _ = dimAttr

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

padLabel :: Text -> Text
padLabel value = value <> Text.replicate (max 0 (7 - Text.length value)) " "

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
drawColumnEntries state column indexedEntries@((row, entry) : _) = case entry of
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
        <+> branchPrefix state column row entry
        <+> drawCardFrame state selected entry (vBox (cardLines state selected entry))
    marker = if state.appOptions.optionAscii then ">" else "▌"

drawCardFrame :: AppState -> Bool -> ColumnEntry -> Widget Name -> Widget Name
drawCardFrame state selected entry contents =
  withBorderStyle (cardBorderStyle state)
    . vBox
    $ [ hBox [withAttr topBottomAttribute (txt topLeft), withAttr topBottomAttribute hBorder, withAttr statusAttribute (txt topRight)],
        hBox
          [ withAttr leftAttribute verticalEdge,
            withAttr interiorAttribute (vLimit middleHeight (padLeftRight 1 (padRight Max contents))),
            withAttr statusAttribute verticalEdge
          ],
        hBox [withAttr topBottomAttribute (txt bottomLeft), withAttr topBottomAttribute hBorder, withAttr statusAttribute (txt bottomRight)]
      ]
  where
    item = entryItem entry
    (topLeft, topRight, bottomLeft, bottomRight, vertical)
      | state.appOptions.optionAscii = ("+", "+", "+", "+", '|')
      | otherwise = ("╭", "╮", "╰", "╯", '│')
    statusAttribute = cardStatusAttribute item
    topBottomAttribute = if selected then selectedAttr else statusAttribute
    leftAttribute = if selected then selectedAttr else statusAttribute
    interiorAttribute = if isApproved defaultWorkflowConfig item then approvedInteriorAttr else neutralAttr
    middleHeight = baseHeight + case entry of
      Standalone _ -> 0
      Tracked _ _ -> 1
    baseHeight = case item of
      IssueItem _ -> 7
      PullRequestItem _ -> 8
    verticalEdge = vBox (replicate middleHeight (str [vertical]))

cardLines :: AppState -> Bool -> ColumnEntry -> [Widget Name]
cardLines state selected entry =
  trackingLine
    <> [ withAttr (if selected then selectedTitleAttr else cardTitleAttr) (txtWrap (itemHeading item)),
    drawCardLabels state item,
    withAttr dimAttr (txtWrap (itemMetadata state item)),
    txtWrap (excerpt (itemBody item))
       ]
    <> statusLine
  where
    item = entryItem entry
    trackingLine = case entry of
      Standalone _ -> []
      Tracked context _ -> [drawTrackingLine context]
    statusLine = case item of
      IssueItem issue -> case trackerDiagnosticsForIssue defaultWorkflowConfig issue of
        [] -> []
        diagnostic : _ -> [withAttr pendingAttr (txtWrap ("TRACKER · " <> renderTrackerDiagnostic diagnostic))]
      PullRequestItem _ -> [withAttr (statusTextAttr item) (txt (itemStatusText item))]

drawTrackerHeader :: AppState -> BoardColumn -> Int -> Tracker -> Bool -> Widget Name
drawTrackerHeader state column row tracker expanded =
  visibility
    . padLeftRight 1
    . padTop (Pad 1)
    $ marker <+> withAttr headerAttribute (txtWrap headerText)
  where
    selected = not expanded && state.appSelectedColumn == column && selectedRow state column == row
    visibility = if selected && state.appEnsureSelectionVisible then visible else id
    marker
      | selected = withAttr selectedAttr (txt (if state.appOptions.optionAscii then ">" else "▌"))
      | otherwise = txt " "
    headerAttribute
      | null tracker.trackerDiagnostics = trackerAttr
      | otherwise = pendingAttr
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

drawTrackingLine :: TrackingContext -> Widget Name
drawTrackingLine context =
  withAttr trackerAttr (txt (childKey <> " · tracker #" <> showText trackerNumber))
    <+> multiTracked
  where
    child = context.trackingPrimary.membershipChild
    childKey = case child.trackerChildImplementationKey of
      Just key -> key
      Nothing -> "step " <> showText (child.trackerChildChecklistOrder + 1)
    trackerNumber = context.trackingPrimary.membershipTracker.trackerIssue.issueNumber
    multiTracked
      | null context.trackingAdditional = emptyWidget
      | otherwise = withAttr pendingAttr (txt " · MULTI-TRACKED")

branchPrefix :: AppState -> BoardColumn -> Int -> ColumnEntry -> Widget Name
branchPrefix state column row entry = case entry of
  Standalone _ -> emptyWidget
  Tracked _ _ -> withAttr trackerAttr (txt branch)
  where
    branch
      | state.appOptions.optionAscii = if isLastInTracker then "`- " else "+- "
      | isLastInTracker = "└─ "
      | otherwise = "├─ "
    isLastInTracker = entryPrimaryTrackerNumber entry /= (entryPrimaryTrackerNumber =<< safeIndex (row + 1) (entriesFor state column))

entryPrimaryTrackerNumber :: ColumnEntry -> Maybe Int
entryPrimaryTrackerNumber (Standalone _) = Nothing
entryPrimaryTrackerNumber (Tracked context _) = Just (primaryTrackerNumber context)

primaryTrackerNumber :: TrackingContext -> Int
primaryTrackerNumber context = context.trackingPrimary.membershipTracker.trackerIssue.issueNumber

drawLabel :: AppState -> Label -> Widget Name
drawLabel _ label = withAttr (labelAttribute label.labelName) (txt (" " <> sanitizeText label.labelName <> " ")) <+> txt " "

drawCardLabels :: AppState -> BoardItem -> Widget Name
drawCardLabels state item = hBox (map (drawLabel state) visibleLabels <> overflowMarker)
  where
    labels = itemLabels item
    visibleLabels = take 4 labels
    hiddenLabels = max 0 (length labels - length visibleLabels) + itemLabelOverflow item
    overflowMarker
      | hiddenLabels > 0 = [withAttr pendingAttr (txt ("+" <> showText hiddenLabels))]
      | otherwise = []

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

itemMetadata :: AppState -> BoardItem -> Text
itemMetadata state (IssueItem issue) = ownership <> " · updated " <> relativeAge state.appNow issue.issueUpdatedAt
  where
    ownership
      | null issue.issueAssignees && issue.issueAssigneeOverflow == 0 = "unassigned"
      | otherwise =
          Text.intercalate ", " ["@" <> assignee.assigneeLogin | assignee <- issue.issueAssignees]
            <> overflowText issue.issueAssigneeOverflow
itemMetadata state (PullRequestItem pullRequest) =
  linked <> pullRequest.pullRequestAuthor <> " → " <> pullRequest.pullRequestBase <> " · updated " <> relativeAge state.appNow pullRequest.pullRequestUpdatedAt
  where
    linked = case pullRequest.pullRequestLinkedIssues of
      []
        | pullRequest.pullRequestLinkedIssueOverflow > 0 -> "+" <> showText pullRequest.pullRequestLinkedIssueOverflow <> " linked · "
        | otherwise -> "UNLINKED · "
      numbers ->
        let visibleNumbers = take 2 numbers
            hiddenNumbers = max 0 (length numbers - length visibleNumbers) + pullRequest.pullRequestLinkedIssueOverflow
         in Text.intercalate "," (map (("#" <>) . showText) visibleNumbers) <> overflowText hiddenNumbers <> " · "

overflowText :: Int -> Text
overflowText count
  | count > 0 = " +" <> showText count
  | otherwise = ""

itemStatusText :: BoardItem -> Text
itemStatusText (IssueItem _) = ""
itemStatusText (PullRequestItem pullRequest) =
  checkText pullRequest.pullRequestChecks <> " · " <> mergeText pullRequest.pullRequestMergeState

checkText :: CheckSummary -> Text
checkText ChecksNone = "no CI"
checkText (ChecksPending passed total) = "◐ CI " <> showText passed <> "/" <> showText total
checkText (ChecksPassed total) = "✓ CI " <> showText total <> "/" <> showText total
checkText (ChecksFailed passed total) = "× CI " <> showText passed <> "/" <> showText total
checkText ChecksUnknown = "? CI unknown"

mergeText :: MergeState -> Text
mergeText MergeClean = "clean"
mergeText MergeBehind = "behind"
mergeText MergeBlocked = "blocked"
mergeText MergeConflicting = "merge conflict"
mergeText MergeUnstable = "unstable"
mergeText MergeUnknown = "calculating"

cardStatusAttribute :: BoardItem -> AttrName
cardStatusAttribute item
  | isProblem defaultWorkflowConfig item = problemAttr
  | itemHasAmberWarning item = pendingAttr
  | isApproved defaultWorkflowConfig item = approvedAttr
cardStatusAttribute (PullRequestItem pullRequest) = case pullRequestStatus defaultWorkflowConfig pullRequest of
  StatusPending _ -> pendingAttr
  StatusReady -> readyAttr
  StatusProblem _ -> problemAttr
  StatusNeutral -> neutralAttr
cardStatusAttribute _ = neutralAttr

statusTextAttr :: BoardItem -> AttrName
statusTextAttr item
  | isProblem defaultWorkflowConfig item = problemAttr
  | itemHasAmberWarning item = pendingAttr
statusTextAttr (PullRequestItem pullRequest) = case pullRequestStatus defaultWorkflowConfig pullRequest of
  StatusPending _ -> pendingAttr
  StatusReady -> readyAttr
  StatusProblem _ -> problemAttr
  StatusNeutral -> dimAttr
statusTextAttr _ = dimAttr

itemHasAmberWarning :: BoardItem -> Bool
itemHasAmberWarning (IssueItem issue) =
  issue.issueLabelOverflow > 0
    || issue.issueAssigneeOverflow > 0
    || not (null (trackerDiagnosticsForIssue defaultWorkflowConfig issue))
itemHasAmberWarning (PullRequestItem pullRequest) =
  pullRequest.pullRequestLabelOverflow > 0 || pullRequest.pullRequestLinkedIssueOverflow > 0

drawFooter :: AppState -> Widget Name
drawFooter state =
  padLeftRight 1
    . vBox
    $ [ withAttr footerAttr (txt "j/k item  h/l column  x epic  enter details  r board  u usage  R all  d drainer  s sidebar  ? help  q quit"),
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

drawOverlay :: AppState -> Overlay -> Widget Name
drawOverlay state overlay =
  centerLayer
    . panelExtent
    . hLimit 88
    . vLimit 32
    . withBorderStyle (innerBorderStyle state)
    . borderWithLabel (withAttr headingAttr (txt overlayTitle))
    . padAll 1
    $ case overlay of
      HelpOverlay -> drawHelp
      DetailsOverlay item -> viewport DetailsViewport Vertical (drawDetails state item)
  where
    panelExtent = case overlay of
      HelpOverlay -> id
      DetailsOverlay _ -> clickable DetailsPanel
    overlayTitle = case overlay of
      HelpOverlay -> " HELP "
      DetailsOverlay item -> " " <> itemHeading item <> " "

drawHelp :: Widget Name
drawHelp =
  vBox
    [ txt "j / Down    next card",
      txt "k / Up      previous card",
      txt "h / Left    previous column",
      txt "l / Right   next column",
      txt "g / G        first / last visible item",
      txt "x            expand / collapse focused epic",
      txt "Enter        details",
      txt "r / u / R    board / usage / all refresh",
      txt "d / click    start or stop PR drainer",
      txt "left click   select card; click selected card for details",
      txt "mouse wheel scroll column under pointer",
      txt "right/outside click closes card details",
      txt "s            toggle sidebar",
      txt "Ctrl-L       repaint",
      txt "Esc          close overlay",
      txt "q            quit"
    ]

drawDetails :: AppState -> BoardItem -> Widget Name
drawDetails state item =
  vBox
    ( [ withAttr cardTitleAttr (txtWrap (itemHeading item)),
        txt "",
        hBox (map drawLabelForDetails (itemLabels item) <> detailsOverflowMarker),
        txt "",
        withAttr headingAttr (txt "Metadata"),
        txtWrap (itemMetadata state item)
      ]
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
    drawLabelForDetails label = withAttr (labelAttribute label.labelName) (txt (" " <> sanitizeText label.labelName <> " ")) <+> txt " "
    detailsOverflowMarker
      | itemLabelOverflow item > 0 = [withAttr pendingAttr (txt ("+" <> showText (itemLabelOverflow item) <> " labels omitted"))]
      | otherwise = []
    trackingDetails = case findEntry state.appBoard (itemId item) of
      Just (Tracked context _) -> drawTrackingDetails context
      _ -> []
    trackerDiagnosticDetails = case item of
      IssueItem issue -> drawTrackerDiagnosticDetails (trackerDiagnosticsForIssue defaultWorkflowConfig issue)
      PullRequestItem _ -> []

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

relativeAge :: UTCTime -> UTCTime -> Text
relativeAge now thenTime
  | seconds < 60 = "now"
  | seconds < 3600 = showText (seconds `div` 60) <> "m ago"
  | seconds < 86400 = showText (seconds `div` 3600) <> "h ago"
  | otherwise = showText (seconds `div` 86400) <> "d ago"
  where
    seconds = max 0 (floor (diffUTCTime now thenTime) :: Int)

itemUrl :: BoardItem -> Text
itemUrl (IssueItem issue) = issue.issueUrl
itemUrl (PullRequestItem pullRequest) = pullRequest.pullRequestUrl

handleEvent :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleEvent event = do
  now <- liftIO getCurrentTime
  modify (\state -> state {appNow = now})
  state <- get
  case (state.appOverlay, event) of
    (_, AppEvent (BoardRefreshFinished result)) -> applyBoardRefresh result
    (_, AppEvent (CodexRefreshFinished result)) -> applyCodexRefresh result
    (_, AppEvent (ClaudeRefreshFinished result)) -> applyClaudeRefresh result
    (_, AppEvent (DrainerStatusRefreshed result)) -> applyDrainerStatus result
    (_, AppEvent (DrainerToggleFinished result)) -> applyDrainerToggle result
    (_, VtyEvent (Vty.EvKey (Vty.KChar 'q') [])) -> halt
    (Just (DetailsOverlay _), MouseDown DetailsPanel Vty.BRight _ _) -> closeOverlay
    (Just (DetailsOverlay _), MouseDown DetailsPanel _ _ _) -> pure ()
    (Just (DetailsOverlay _), MouseDown _ _ _ _) -> closeOverlay
    (Just (DetailsOverlay _), VtyEvent (Vty.EvMouseDown _ _ _ _)) -> closeOverlay
    (Just _, VtyEvent (Vty.EvKey Vty.KEsc [])) -> modify (\current -> current {appOverlay = Nothing, appNotice = Nothing})
    (Just _, VtyEvent (Vty.EvKey Vty.KDown [])) -> vScrollBy (viewportScroll DetailsViewport) 1
    (Just _, VtyEvent (Vty.EvKey (Vty.KChar 'j') [])) -> vScrollBy (viewportScroll DetailsViewport) 1
    (Just _, VtyEvent (Vty.EvKey Vty.KUp [])) -> vScrollBy (viewportScroll DetailsViewport) (-1)
    (Just _, VtyEvent (Vty.EvKey (Vty.KChar 'k') [])) -> vScrollBy (viewportScroll DetailsViewport) (-1)
    (Just _, _) -> pure ()
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar '?') [])) -> modify (\current -> current {appOverlay = Just HelpOverlay})
    (Nothing, VtyEvent (Vty.EvKey Vty.KEnter [])) -> openSelectedDetails
    (Nothing, VtyEvent (Vty.EvKey Vty.KDown [])) -> moveCard 1
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'j') [])) -> moveCard 1
    (Nothing, VtyEvent (Vty.EvKey Vty.KUp [])) -> moveCard (-1)
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'k') [])) -> moveCard (-1)
    (Nothing, VtyEvent (Vty.EvKey Vty.KLeft [])) -> moveColumn (-1)
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'h') [])) -> moveColumn (-1)
    (Nothing, VtyEvent (Vty.EvKey Vty.KRight [])) -> moveColumn 1
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'l') [])) -> moveColumn 1
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'g') [])) -> selectBoundary False
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'G') [])) -> selectBoundary True
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'x') [])) -> toggleSelectedTracker
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 's') [])) -> modify (\current -> current {appSidebarVisible = not current.appSidebarVisible})
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'r') [])) -> startBoardRefresh
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'u') [])) -> startUsageRefreshes
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'R') [])) -> startAllRefreshes
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'd') [])) -> toggleDrainer
    (Nothing, MouseDown DrainerButton Vty.BLeft [] _) -> toggleDrainer
    (Nothing, MouseDown (CardTarget column row) Vty.BLeft _ _) -> selectOrOpenCard column row
    (Nothing, MouseDown (CardTarget column _) Vty.BScrollUp _ _) -> scrollColumn column (-3)
    (Nothing, MouseDown (CardTarget column _) Vty.BScrollDown _ _) -> scrollColumn column 3
    (Nothing, MouseDown (ColumnViewport column) Vty.BScrollUp _ _) -> scrollColumn column (-3)
    (Nothing, MouseDown (ColumnViewport column) Vty.BScrollDown _ _) -> scrollColumn column 3
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'l') [Vty.MCtrl])) -> setNotice "Terminal repaint requested"
    _ -> pure ()

setNotice :: Text -> EventM Name AppState ()
setNotice message = modify (\state -> state {appNotice = Just message})

closeOverlay :: EventM Name AppState ()
closeOverlay = modify (\state -> state {appOverlay = Nothing, appNotice = Nothing})

scrollColumn :: BoardColumn -> Int -> EventM Name AppState ()
scrollColumn column amount = do
  modify (\state -> state {appEnsureSelectionVisible = False})
  vScrollBy (viewportScroll (ColumnViewport column)) amount

selectOrOpenCard :: BoardColumn -> Int -> EventM Name AppState ()
selectOrOpenCard column row = modify $ \state ->
  if state.appSelectedColumn == column && selectedRow state column == row
    then case safeIndex row (entriesFor state column) of
      Just entry -> state {appOverlay = Just (DetailsOverlay (entryItem entry)), appNotice = Nothing}
      Nothing -> state
    else
      state
        { appSelectedColumn = column,
          appSelectedRows = Map.insert column row state.appSelectedRows,
          appEnsureSelectionVisible = True,
          appNotice = Nothing
        }

startApplication :: EventM Name AppState ()
startApplication = do
  vty <- getVtyHandle
  liftIO (Vty.setMode (Vty.outputIface vty) Vty.Mouse True)
  startBoardRefresh
  state <- get
  case state.appDrainerController of
    Left _ -> pure ()
    Right controller ->
      void
        . liftIO
        . forkIO
        $ monitorDrainer controller state.appEventChannel

monitorDrainer :: DrainerController -> BChan AppEvent -> IO ()
monitorDrainer controller eventChannel = forever $ do
  queryDrainerStatus controller >>= writeBChan eventChannel . DrainerStatusRefreshed
  threadDelay drainerRefreshIntervalMicros

drainerRefreshIntervalMicros :: Int
drainerRefreshIntervalMicros = 10 * 1000 * 1000

toggleDrainer :: EventM Name AppState ()
toggleDrainer = do
  state <- get
  if state.appDrainerBusy
    then setNotice "PR drainer is already starting or stopping"
    else case state.appDrainerController of
      Left message -> setNotice ("PR drainer control unavailable: " <> sanitizeText message)
      Right controller -> do
        let shouldRun = not (drainerIsRunning state.appDrainerStatus)
            transition = if shouldRun then DrainerStatus DrainerStarting "starting…" else DrainerStatus DrainerStopping "stopping…"
        modify
          ( \current ->
              current
                { appDrainerStatus = transition,
                  appDrainerBusy = True,
                  appNotice = Just (if shouldRun then "Starting PR drainer…" else "Stopping PR drainer…")
                }
          )
        void
          . liftIO
          . forkIO
          $ setDrainerRunning controller shouldRun >>= writeBChan state.appEventChannel . DrainerToggleFinished

applyDrainerStatus :: Either Text DrainerStatus -> EventM Name AppState ()
applyDrainerStatus result = modify $ \state ->
  if state.appDrainerBusy
    then state
    else state {appDrainerStatus = either drainerErrorStatus id result}

applyDrainerToggle :: Either Text DrainerStatus -> EventM Name AppState ()
applyDrainerToggle result = modify $ \state ->
  let status = either drainerErrorStatus id result
      notice = case result of
        Left message -> "PR drainer control failed: " <> sanitizeText message
        Right _ -> "PR drainer is " <> status.drainerDetail
   in state
        { appDrainerStatus = status,
          appDrainerBusy = False,
          appNotice = Just notice
        }

drainerErrorStatus :: Text -> DrainerStatus
drainerErrorStatus message = DrainerStatus DrainerError (sanitizeText message)

startAllRefreshes :: EventM Name AppState ()
startAllRefreshes = do
  startBoardRefresh
  startUsageRefreshes

startUsageRefreshes :: EventM Name AppState ()
startUsageRefreshes = do
  startCodexRefresh
  startClaudeRefresh

startBoardRefresh :: EventM Name AppState ()
startBoardRefresh = do
  state <- get
  case state.appBoardFreshness of
    Loading -> setNotice "GitHub refresh is already running"
    _ -> do
      modify
        ( \current ->
            current
              { appBoardFreshness = Loading,
                appNotice = Just "Refreshing GitHub…"
              }
        )
      void
        . liftIO
        . forkIO
        $ runBoardRefresh state.appOptions state.appRepository state.appEventChannel

runBoardRefresh :: Options -> Repository -> BChan AppEvent -> IO ()
runBoardRefresh options repository eventChannel = do
  timedResult <- timeout boardRefreshTimeoutMicros (fetchGitHubSnapshot repository)
  result <- case timedResult of
    Nothing -> pure (Left (ProviderError RequestTimedOut "GitHub refresh timed out after 30 seconds"))
    Just (Left providerError) -> pure (Left providerError)
    Just (Right githubResult)
      | options.optionNoCache -> pure (Right githubResult)
      | otherwise -> do
          cacheResult <- writeRepositoryCache repository githubResult.githubSnapshot
          pure . Right $ case cacheResult of
            Left warning -> githubResult {githubWarnings = githubResult.githubWarnings <> [warning]}
            Right () -> githubResult
  writeBChan eventChannel (BoardRefreshFinished result)

startCodexRefresh :: EventM Name AppState ()
startCodexRefresh = do
  state <- get
  case Map.findWithDefault NotLoaded Codex state.appUsageFreshness of
    Loading -> setNotice "Codex usage refresh is already running"
    _ -> do
      modify
        ( \current ->
            current
              { appUsageFreshness = Map.insert Codex Loading current.appUsageFreshness,
                appNotice = Just "Refreshing Codex usage…"
              }
        )
      void
        . liftIO
        . forkIO
        $ runCodexRefresh state.appEventChannel

runCodexRefresh :: BChan AppEvent -> IO ()
runCodexRefresh eventChannel = fetchCodexUsage >>= writeBChan eventChannel . CodexRefreshFinished

startClaudeRefresh :: EventM Name AppState ()
startClaudeRefresh = do
  state <- get
  case Map.findWithDefault NotLoaded Claude state.appUsageFreshness of
    Loading -> setNotice "Claude usage refresh is already running"
    _ -> do
      modify
        ( \current ->
            current
              { appUsageFreshness = Map.insert Claude Loading current.appUsageFreshness,
                appNotice = Just "Refreshing Claude usage…"
              }
        )
      void
        . liftIO
        . forkIO
        $ runClaudeRefresh state.appEventChannel

runClaudeRefresh :: BChan AppEvent -> IO ()
runClaudeRefresh eventChannel = fetchClaudeUsage >>= writeBChan eventChannel . ClaudeRefreshFinished

boardRefreshTimeoutMicros :: Int
boardRefreshTimeoutMicros = 30 * 1000 * 1000

applyBoardRefresh :: Either ProviderError GitHubResult -> EventM Name AppState ()
applyBoardRefresh result = modify $ \state -> case result of
  Left providerError ->
    state
      { appBoardFreshness = failureFreshness state providerError,
        appNotice = Just (renderProviderError providerError)
      }
  Right githubResult ->
    let snapshot = githubResult.githubSnapshot
        refreshedBoard = deriveBoard defaultWorkflowConfig snapshot
        (selectedColumn, selectedRows) = preserveSelection state refreshedBoard
        (refreshedOverlay, overlayNotice) = refreshOverlay refreshedBoard state.appOverlay
        successNotice = refreshSuccessNotice snapshot githubResult.githubWarnings
     in state
          { appBoard = refreshedBoard,
            appSelectedColumn = selectedColumn,
            appSelectedRows = selectedRows,
            appOverlay = refreshedOverlay,
            appBoardFreshness = Fresh snapshot.snapshotFetchedAt,
            appLastSuccessfulFetch = Just snapshot.snapshotFetchedAt,
            appIssuesTruncated = snapshot.snapshotIssuesTruncated,
            appPullRequestsTruncated = snapshot.snapshotPullRequestsTruncated,
            appNotice = Just (maybe successNotice (<> (" · " <> successNotice)) overlayNotice)
          }

applyCodexRefresh :: Either ProviderError UsageSnapshot -> EventM Name AppState ()
applyCodexRefresh = applyUsageRefresh Codex "Codex"

applyClaudeRefresh :: Either ProviderError UsageSnapshot -> EventM Name AppState ()
applyClaudeRefresh = applyUsageRefresh Claude "Claude"

applyUsageRefresh :: UsageProvider -> Text -> Either ProviderError UsageSnapshot -> EventM Name AppState ()
applyUsageRefresh provider displayName result = case result of
  Left providerError ->
    modify
      ( \state ->
          state
            { appUsageFreshness = Map.insert provider (usageFailureFreshness provider state providerError) state.appUsageFreshness,
              appNotice = Just (displayName <> " usage refresh failed: " <> renderProviderErrorMessage providerError)
            }
      )
  Right snapshot -> do
    state <- get
    let snapshots = Map.insert provider snapshot state.appUsage
    cacheWarning <-
      if state.appOptions.optionNoCache
        then pure Nothing
        else either Just (const Nothing) <$> liftIO (writeUsageCache snapshots)
    modify
      ( \current ->
          current
            { appUsage = snapshots,
              appUsageFreshness = Map.insert provider (Fresh snapshot.usageFetchedAt) current.appUsageFreshness,
              appNotice = Just (displayName <> " usage refreshed" <> maybe "" (" · " <>) cacheWarning)
            }
      )

usageFailureFreshness :: UsageProvider -> AppState -> ProviderError -> Freshness
usageFailureFreshness provider state providerError = case Map.lookup provider state.appUsage of
  Just snapshot -> Stale snapshot.usageFetchedAt providerError.providerErrorMessage
  Nothing -> case providerError.providerErrorKind of
    UnsupportedVersion -> Unsupported providerError.providerErrorMessage
    _ -> Unavailable providerError.providerErrorMessage

failureFreshness :: AppState -> ProviderError -> Freshness
failureFreshness state providerError = case state.appLastSuccessfulFetch of
  Just fetchedAt -> Stale fetchedAt providerError.providerErrorMessage
  Nothing -> Unavailable providerError.providerErrorMessage

renderProviderError :: ProviderError -> Text
renderProviderError providerError =
  "GitHub refresh failed: " <> renderProviderErrorMessage providerError

renderProviderErrorMessage :: ProviderError -> Text
renderProviderErrorMessage providerError =
  kind <> ": " <> providerError.providerErrorMessage
  where
    kind = case providerError.providerErrorKind of
      AuthenticationRequired -> "AUTH REQUIRED"
      ExecutableMissing -> "NOT INSTALLED"
      UnsupportedVersion -> "UNSUPPORTED VERSION"
      RequestTimedOut -> "TIMED OUT"
      InvalidResponse -> "INVALID RESPONSE"
      RequestFailed -> "REQUEST ERROR"

refreshSuccessNotice :: RepoSnapshot -> [Text] -> Text
refreshSuccessNotice snapshot warnings =
  "GitHub refreshed · "
    <> countedSource "issue" (length snapshot.snapshotIssues) snapshot.snapshotIssuesTruncated
    <> " · "
    <> countedSource "PR" (length snapshot.snapshotPullRequests) snapshot.snapshotPullRequestsTruncated
    <> case warnings of
      [] -> ""
      values -> " · " <> Text.intercalate " · " values

countedSource :: Text -> Int -> Bool -> Text
countedSource noun count truncated =
  showText count <> (if truncated then "+" else "") <> " " <> noun <> if count == 1 then "" else "s"

columnCountText :: AppState -> BoardColumn -> Text
columnCountText state column =
  showText (length (entriesFor state column)) <> if columnMayBeTruncated then "+" else ""
  where
    columnMayBeTruncated = case column of
      Issues -> state.appIssuesTruncated
      Active -> state.appIssuesTruncated
      Reviewing -> state.appPullRequestsTruncated
      Done -> state.appPullRequestsTruncated

appendWarnings :: Text -> [Text] -> Text
appendWarnings message [] = message
appendWarnings message warnings = message <> " · " <> Text.intercalate " · " warnings

preserveSelection :: AppState -> Board -> (BoardColumn, Map BoardColumn Int)
preserveSelection state board =
  case selectedItem state >>= (findItem board . itemId) of
    Just (column, row, _) ->
      let visibleRow = normalizeCollapsedRow state board column row
       in (column, rowsWithSelection column visibleRow)
    Nothing -> (state.appSelectedColumn, clampedRows)
  where
    clampedRows =
      Map.fromList
        [ (column, normalizeCollapsedRow state board column (clampRow board column (selectedRow state column)))
          | column <- allColumns
        ]
    rowsWithSelection selectedColumn selectedIndex = Map.insert selectedColumn selectedIndex clampedRows

clampRow :: Board -> BoardColumn -> Int -> Int
clampRow board column row = max 0 (min row (length (entriesForBoard board column) - 1))

normalizeCollapsedRow :: AppState -> Board -> BoardColumn -> Int -> Int
normalizeCollapsedRow state board column row = case safeIndex row entries >>= entryPrimaryTrackerNumber of
  Just trackerNumber
    | trackerNumber `Set.notMember` state.appExpandedTrackers ->
        maybe row id (findIndex ((== Just trackerNumber) . entryPrimaryTrackerNumber) entries)
  _ -> row
  where
    entries = entriesForBoard board column

refreshOverlay :: Board -> Maybe Overlay -> (Maybe Overlay, Maybe Text)
refreshOverlay _ Nothing = (Nothing, Nothing)
refreshOverlay _ (Just HelpOverlay) = (Just HelpOverlay, Nothing)
refreshOverlay board (Just (DetailsOverlay oldItem)) =
  case findItem board (itemId oldItem) of
    Just (_, _, refreshedItem) -> (Just (DetailsOverlay refreshedItem), Nothing)
    Nothing -> (Nothing, Just "Details closed because that item is no longer open")

findItem :: Board -> ItemId -> Maybe (BoardColumn, Int, BoardItem)
findItem board target = (\(column, row, entry) -> (column, row, entryItem entry)) <$> findEntryWithLocation board target

findEntry :: Board -> ItemId -> Maybe ColumnEntry
findEntry board target = (\(_, _, entry) -> entry) <$> findEntryWithLocation board target

findEntryWithLocation :: Board -> ItemId -> Maybe (BoardColumn, Int, ColumnEntry)
findEntryWithLocation board target = firstMatch allColumns
  where
    firstMatch [] = Nothing
    firstMatch (column : rest) =
      let entries = entriesForBoard board column
       in case findIndex ((== target) . itemId . entryItem) entries of
            Just row -> (\entry -> (column, row, entry)) <$> safeIndex row entries
            Nothing -> firstMatch rest

entriesForBoard :: Board -> BoardColumn -> [ColumnEntry]
entriesForBoard board column = Map.findWithDefault [] column board.boardColumns

moveCard :: Int -> EventM Name AppState ()
moveCard delta = modify $ \state ->
  let column = state.appSelectedColumn
      rows = visibleSelectionRows state column
      currentPosition = maybe 0 id (findIndex (== selectedRow state column) rows)
      nextPosition = max 0 (min (length rows - 1) (currentPosition + delta))
   in case safeIndex nextPosition rows of
        Nothing -> state {appEnsureSelectionVisible = True, appNotice = Nothing}
        Just nextRow -> state {appSelectedRows = Map.insert column nextRow state.appSelectedRows, appEnsureSelectionVisible = True, appNotice = Nothing}

moveColumn :: Int -> EventM Name AppState ()
moveColumn delta = modify $ \state ->
  let current = fromEnum state.appSelectedColumn
      maximumColumn = fromEnum (maxBound :: BoardColumn)
      next = max 0 (min maximumColumn (current + delta))
   in state {appSelectedColumn = toEnum next, appEnsureSelectionVisible = True, appNotice = Nothing}

selectBoundary :: Bool -> EventM Name AppState ()
selectBoundary selectLast = modify $ \state ->
  let column = state.appSelectedColumn
      rows = visibleSelectionRows state column
      target = if selectLast then safeLast rows else safeIndex 0 rows
   in case target of
        Nothing -> state {appEnsureSelectionVisible = True, appNotice = Nothing}
        Just row -> state {appSelectedRows = Map.insert column row state.appSelectedRows, appEnsureSelectionVisible = True, appNotice = Nothing}

toggleSelectedTracker :: EventM Name AppState ()
toggleSelectedTracker = modify $ \state ->
  let column = state.appSelectedColumn
      entries = entriesFor state column
      currentRow = selectedRow state column
   in case safeIndex currentRow entries >>= entryPrimaryTrackerNumber of
        Nothing -> state {appEnsureSelectionVisible = True, appNotice = Just "Focus an epic header or child before pressing x"}
        Just trackerNumber
          | trackerNumber `Set.member` state.appExpandedTrackers ->
              let firstRow = maybe currentRow id (findIndex ((== Just trackerNumber) . entryPrimaryTrackerNumber) entries)
               in state
                    { appExpandedTrackers = Set.delete trackerNumber state.appExpandedTrackers,
                      appSelectedRows = Map.insert column firstRow state.appSelectedRows,
                      appEnsureSelectionVisible = True,
                      appNotice = Just ("Collapsed epic #" <> showText trackerNumber)
                    }
          | otherwise ->
              state
                { appExpandedTrackers = Set.insert trackerNumber state.appExpandedTrackers,
                  appEnsureSelectionVisible = True,
                  appNotice = Just ("Expanded epic #" <> showText trackerNumber)
                }

openSelectedDetails :: EventM Name AppState ()
openSelectedDetails = modify $ \state ->
  case selectedEntry state of
    Just entry@(Tracked trackingContext _)
      | primaryTrackerNumber trackingContext `Set.notMember` state.appExpandedTrackers ->
          state {appNotice = Just "Press x to expand this epic"}
      | otherwise -> openEntry state entry
    Just entry -> openEntry state entry
    Nothing -> state {appNotice = Just "No item is selected in this column"}
  where
    openEntry state entry = state {appOverlay = Just (DetailsOverlay (entryItem entry)), appNotice = Nothing}

selectedItem :: AppState -> Maybe BoardItem
selectedItem state = entryItem <$> selectedEntry state

selectedEntry :: AppState -> Maybe ColumnEntry
selectedEntry state = safeIndex (selectedRow state state.appSelectedColumn) (entriesFor state state.appSelectedColumn)

visibleSelectionRows :: AppState -> BoardColumn -> [Int]
visibleSelectionRows state column = collect (zip [0 ..] (entriesFor state column))
  where
    collect [] = []
    collect indexedEntries@((row, entry) : rest) = case entryPrimaryTrackerNumber entry of
      Nothing -> row : collect rest
      Just trackerNumber ->
        let (groupEntries, remaining) = span ((== Just trackerNumber) . entryPrimaryTrackerNumber . snd) indexedEntries
         in if trackerNumber `Set.member` state.appExpandedTrackers
              then map fst groupEntries <> collect remaining
              else row : collect remaining

safeLast :: [value] -> Maybe value
safeLast [] = Nothing
safeLast (value : values) = Just (foldl (\_ next -> next) value values)

entriesFor :: AppState -> BoardColumn -> [ColumnEntry]
entriesFor state column = Map.findWithDefault [] column state.appBoard.boardColumns

selectedRow :: AppState -> BoardColumn -> Int
selectedRow state column = Map.findWithDefault 0 column state.appSelectedRows

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

shellBorderStyle :: AppState -> BorderStyle
shellBorderStyle state
  | state.appOptions.optionAscii = ascii
  | otherwise = doubleBorderStyle

innerBorderStyle :: AppState -> BorderStyle
innerBorderStyle state
  | state.appOptions.optionAscii = ascii
  | otherwise = unicodeBold

usesOpenBorders :: AppState -> Bool
usesOpenBorders state =
  not state.appOptions.optionAscii
    && state.appOptions.optionBorder == BorderOpen

cardBorderStyle :: AppState -> BorderStyle
cardBorderStyle state
  | state.appOptions.optionAscii = ascii
  | otherwise = unicode

doubleBorderStyle :: BorderStyle
doubleBorderStyle =
  BorderStyle
    { bsCornerTL = '╔',
      bsCornerTR = '╗',
      bsCornerBR = '╝',
      bsCornerBL = '╚',
      bsIntersectFull = '╬',
      bsIntersectL = '╠',
      bsIntersectR = '╣',
      bsIntersectT = '╦',
      bsIntersectB = '╩',
      bsHorizontal = '═',
      bsVertical = '║'
    }

themeFor :: Options -> AttrMap
themeFor options
  | options.optionColor == ColorNever = attrMap Vty.defAttr [(name, Vty.defAttr) | name <- allAttributeNames]
  | otherwise =
      attrMap
        Vty.defAttr
        [ (titleAttr, foreground Vty.brightCyan `Vty.withStyle` Vty.bold),
          (headingAttr, foreground Vty.brightWhite `Vty.withStyle` Vty.bold),
          (providerAttr, foreground Vty.brightCyan `Vty.withStyle` Vty.bold),
          (footerAttr, foreground Vty.brightBlack),
          (noticeAttr, foreground Vty.yellow),
          (dimAttr, foreground Vty.brightBlack),
          (neutralAttr, foreground Vty.white),
          (selectedAttr, foreground Vty.brightCyan `Vty.withStyle` Vty.bold),
          (approvedAttr, foreground Vty.brightGreen `Vty.withStyle` Vty.bold),
          (approvedInteriorAttr, onColor Vty.black Vty.green),
          (pendingAttr, foreground Vty.yellow),
          (readyAttr, foreground Vty.brightGreen),
          (problemAttr, foreground Vty.brightRed `Vty.withStyle` Vty.bold),
          (trackerAttr, foreground (Vty.rgbColor (128 :: Int) 90 213) `Vty.withStyle` Vty.bold),
          (cardTitleAttr, Vty.defAttr `Vty.withStyle` Vty.bold),
          (selectedTitleAttr, foreground Vty.brightCyan `Vty.withStyle` Vty.bold),
          (linkAttr, foreground Vty.brightBlue),
          (labelDefaultAttr, onColor Vty.black Vty.brightWhite),
          (labelApprovalAttr, onColor Vty.black Vty.brightGreen),
          (labelProblemAttr, onColor Vty.brightWhite Vty.red),
          (labelUiAttr, onColor Vty.brightWhite Vty.blue),
          (issuesAttr, foreground Vty.brightWhite),
          (activeAttr, foreground Vty.brightBlue),
          (reviewingAttr, foreground Vty.yellow),
          (doneAttr, foreground Vty.brightGreen)
        ]
  where
    foreground = Vty.withForeColor Vty.defAttr
    onColor textColor background = Vty.withBackColor (Vty.withForeColor Vty.defAttr textColor) background

columnHeadingAttr :: BoardColumn -> AttrName
columnHeadingAttr Issues = issuesAttr
columnHeadingAttr Active = activeAttr
columnHeadingAttr Reviewing = reviewingAttr
columnHeadingAttr Done = doneAttr

labelAttribute :: Text -> AttrName
labelAttribute name
  | folded == "reviewed:approve" = labelApprovalAttr
  | folded `elem` ["blocked", "reviewed:changes", "bug"] = labelProblemAttr
  | folded `elem` ["ui", "input"] = labelUiAttr
  | otherwise = labelDefaultAttr
  where
    folded = Text.toCaseFold name

titleAttr, headingAttr, providerAttr, footerAttr, noticeAttr, dimAttr :: AttrName
neutralAttr, selectedAttr, approvedAttr, approvedInteriorAttr, pendingAttr, readyAttr, problemAttr :: AttrName
trackerAttr :: AttrName
cardTitleAttr, selectedTitleAttr, linkAttr, labelDefaultAttr, labelApprovalAttr, labelProblemAttr, labelUiAttr :: AttrName
issuesAttr, activeAttr, reviewingAttr, doneAttr :: AttrName
titleAttr = attrName "title"
headingAttr = attrName "heading"
providerAttr = attrName "provider"
footerAttr = attrName "footer"
noticeAttr = attrName "notice"
dimAttr = attrName "dim"
neutralAttr = attrName "status.neutral"
selectedAttr = attrName "status.selected"
approvedAttr = attrName "status.approved"
approvedInteriorAttr = attrName "interior.approved"
pendingAttr = attrName "status.pending"
readyAttr = attrName "status.ready"
problemAttr = attrName "status.problem"
trackerAttr = attrName "tracker"
cardTitleAttr = attrName "card.title"
selectedTitleAttr = attrName "card.title.selected"
linkAttr = attrName "link"
labelDefaultAttr = attrName "label.default"
labelApprovalAttr = attrName "label.approval"
labelProblemAttr = attrName "label.problem"
labelUiAttr = attrName "label.ui"
issuesAttr = attrName "column.issues"
activeAttr = attrName "column.active"
reviewingAttr = attrName "column.reviewing"
doneAttr = attrName "column.done"

allAttributeNames :: [AttrName]
allAttributeNames =
  [ titleAttr,
    headingAttr,
    providerAttr,
    footerAttr,
    noticeAttr,
    dimAttr,
    neutralAttr,
    selectedAttr,
    approvedAttr,
    approvedInteriorAttr,
    pendingAttr,
    readyAttr,
    problemAttr,
    trackerAttr,
    cardTitleAttr,
    selectedTitleAttr,
    linkAttr,
    labelDefaultAttr,
    labelApprovalAttr,
    labelProblemAttr,
    labelUiAttr,
    issuesAttr,
    activeAttr,
    reviewingAttr,
    doneAttr
  ]
