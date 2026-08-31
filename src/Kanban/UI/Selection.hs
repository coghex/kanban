module Kanban.UI.Selection
  ( findEntry,
    findEntryWithLocation,
    findItem,
    moveCard,
    moveColumn,
    normalizeCollapsedRow,
    normalizeSelectedRowsAfterToggle,
    openSearchResult,
    openSelectedDetails,
    openSelectedDetailsIn,
    preserveSelection,
    refreshOverlay,
    selectBoundary,
    selectedEntry,
    selectedItem,
    toggleSelectedTracker,
    toggleTrackerFromClick,
    toggleTrackerState,
    visibleSelectionRows,
  )
where


import Brick
import Data.List (findIndex )
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Kanban.Domain
import Kanban.Workflow (entryItem )
import Kanban.UI.Keys (BoardAction (..), actionKeyText)
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.Search

preserveSelection :: AppState -> Board -> (BoardColumn, Map BoardColumn Int)
preserveSelection state board =
  case selectedItem state >>= (findItem board . itemId) of
    Just (column, row, _) ->
      let visibleRow = normalizeCollapsedRow state.appExpandedTrackers board column row
       in (column, rowsWithSelection column visibleRow)
    Nothing -> (state.appSelectedColumn, clampedRows)
  where
    clampedRows =
      Map.fromList
        [ (column, normalizeCollapsedRow state.appExpandedTrackers board column (clampRow board column (selectedRow state column)))
          | column <- allColumns
        ]
    rowsWithSelection selectedColumn selectedIndex = Map.insert selectedColumn selectedIndex clampedRows

clampRow :: Board -> BoardColumn -> Int -> Int
clampRow board column row = max 0 (min row (length (entriesForBoard board column) - 1))

normalizeCollapsedRow :: Set Int -> Board -> BoardColumn -> Int -> Int
normalizeCollapsedRow expandedTrackers board column row = case safeIndex row entries >>= entryPrimaryTrackerNumber of
  Just trackerNumber
    | trackerNumber `Set.notMember` expandedTrackers ->
        maybe row id (findIndex ((== Just trackerNumber) . entryPrimaryTrackerNumber) entries)
  _ -> row
  where
    entries = entriesForBoard board column

-- | Collapsing a tracker only repairs the toggling column's own remembered
-- row; every other column can still be pointing at a row that just became
-- hidden board-wide, so re-run 'normalizeCollapsedRow' over all of them.
normalizeSelectedRowsAfterToggle :: Set Int -> Board -> Map BoardColumn Int -> Map BoardColumn Int
normalizeSelectedRowsAfterToggle expandedTrackers board = Map.mapWithKey (normalizeCollapsedRow expandedTrackers board)

refreshOverlay :: Board -> Maybe Overlay -> (Maybe Overlay, Maybe Text)
refreshOverlay _ Nothing = (Nothing, Nothing)
refreshOverlay _ (Just HelpOverlay) = (Just HelpOverlay, Nothing)
refreshOverlay _ (Just SettingsOverlay) = (Just SettingsOverlay, Nothing)
refreshOverlay _ (Just ProcessesOverlay) = (Just ProcessesOverlay, Nothing)
-- The panel is rebuilt from live state on every draw, so a refresh that
-- changes what needs attention is picked up without closing it.
refreshOverlay _ (Just IncidentsOverlay) = (Just IncidentsOverlay, Nothing)
refreshOverlay _ (Just overlay@(ReviewOverlay _)) = (Just overlay, Nothing)
refreshOverlay _ (Just overlay@(SolveOverlay _)) = (Just overlay, Nothing)
refreshOverlay _ (Just overlay@(PullRequestReviewOverlay _)) = (Just overlay, Nothing)
refreshOverlay board (Just (SolveChooser workflow oldIssue)) =
  case findItem board (IssueId oldIssue.issueNumber) of
    Just (_, _, IssueItem refreshedIssue) -> (Just (SolveChooser workflow refreshedIssue), Nothing)
    _ -> (Nothing, Just "Solve choice closed because that issue is no longer open")
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

moveCard :: Int -> EventM Name AppState ()
moveCard delta = modify (moveSelectionBy delta)

moveColumn :: Int -> EventM Name AppState ()
moveColumn delta = modify $ \state ->
  let current = fromEnum state.appSelectedColumn
      maximumColumn = fromEnum (maxBound :: BoardColumn)
      next = max 0 (min maximumColumn (current + delta))
   in noticeCleared state {appSelectedColumn = toEnum next, appEnsureSelectionVisible = True}

selectBoundary :: Bool -> EventM Name AppState ()
selectBoundary selectLast = modify $ \state ->
  let column = state.appSelectedColumn
      rows = selectableRows state column
      target = if selectLast then safeLast rows else safeIndex 0 rows
   in case target of
        Nothing -> noticeCleared state {appEnsureSelectionVisible = True}
        Just row -> noticeCleared state {appSelectedRows = Map.insert column row state.appSelectedRows, appEnsureSelectionVisible = True}

toggleSelectedTracker :: EventM Name AppState ()
toggleSelectedTracker = modify $ \state ->
  let column = state.appSelectedColumn
      entries = entriesFor state column
      currentRow = selectedRow state column
   in case safeIndex currentRow entries >>= entryPrimaryTrackerNumber of
        Nothing -> noticeSet ("Focus an epic header or child before pressing " <> actionKeyText ToggleEpic) state {appEnsureSelectionVisible = True}
        Just trackerNumber ->
          let firstRow = maybe currentRow id (findIndex ((== Just trackerNumber) . entryPrimaryTrackerNumber) entries)
           in toggleTrackerState column firstRow trackerNumber state

toggleTrackerFromClick :: BoardColumn -> Int -> Int -> EventM Name AppState ()
toggleTrackerFromClick column row trackerNumber =
  modify (toggleTrackerState column row trackerNumber)

toggleTrackerState :: BoardColumn -> Int -> Int -> AppState -> AppState
toggleTrackerState column row trackerNumber state
  | trackerNumber `Set.member` state.appExpandedTrackers =
      retarget (Set.delete trackerNumber state.appExpandedTrackers) ("Collapsed epic #" <> showText trackerNumber)
  | otherwise =
      retarget (Set.insert trackerNumber state.appExpandedTrackers) ("Expanded epic #" <> showText trackerNumber)
  where
    -- The row is an index into what @column@ is showing, so the raw-board
    -- normalization below is only right while nothing is filtering it. Under
    -- a live search the toggle is re-seated on the row it named instead, by
    -- that row's anchor; 'reseatSearch' is a no-op with no search open.
    toggled = anchorAt state column row
    retarget expandedTrackers notice =
      noticeSet notice
        . reseatSearch toggled
        $ state
          { appSelectedColumn = column,
            appExpandedTrackers = expandedTrackers,
            appSelectedRows =
              normalizeSelectedRowsAfterToggle
                expandedTrackers
                state.appVisibleBoard
                (Map.insert column row state.appSelectedRows),
            appEnsureSelectionVisible = True
          }

openSelectedDetails :: EventM Name AppState ()
openSelectedDetails = modify openSelectedDetailsIn

openSelectedDetailsIn :: AppState -> AppState
openSelectedDetailsIn state =
  case selectedEntry state of
    Just entry@(Tracked trackingContext _)
      | primaryTrackerNumber trackingContext `Set.notMember` expandedTrackersFor state state.appSelectedColumn ->
          noticeSet ("Press " <> actionKeyText ToggleEpic <> " to expand this epic") state
      | otherwise -> openEntry entry
    Just entry -> openEntry entry
    Nothing -> noticeSet "No item is selected in this column" state
  where
    openEntry entry = noticeCleared state {appOverlay = Just (DetailsOverlay (entryItem entry))}

-- | Enter on a search result: open its details the way the board always does,
-- then end search on the identity that was opened, so the restored column is
-- positioned on the same card. A press that opened nothing — a collapsed
-- epic's header — leaves search running, because nothing was gone to.
openSearchResult :: AppState -> AppState
openSearchResult state
  | opened.appOverlay /= state.appOverlay = closeSearchOn anchor opened
  | otherwise = opened
  where
    anchor = selectedAnchorIn state state.appSelectedColumn
    opened = openSelectedDetailsIn state

selectedItem :: AppState -> Maybe BoardItem
selectedItem state = entryItem <$> selectedEntry state

selectedEntry :: AppState -> Maybe ColumnEntry
selectedEntry state = safeIndex (selectedRow state state.appSelectedColumn) (entriesFor state state.appSelectedColumn)

-- | Which rows of a raw column the selection may land on. What the user can
-- actually reach is 'Kanban.UI.Search.selectableRows', which asks the same
-- question of the view a live query leaves visible.
visibleSelectionRows :: Set Int -> Board -> BoardColumn -> [Int]
visibleSelectionRows expandedTrackers board column = visibleRowsIn expandedTrackers (entriesForBoard board column)
