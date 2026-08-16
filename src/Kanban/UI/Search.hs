-- | The live, column-scoped card search from @docs\/design.md@ §7.
--
-- Filtering and the interaction that reads it cannot be separated. A rendered
-- row is a raw index into a column's entry list: 'Kanban.UI.Board.drawColumn'
-- numbers 'entriesFor' and hands those indices to @CardTarget@ and
-- @EpicTarget@, and mouse dispatch resolves them back through the same
-- accessor. Filtering only what is drawn would let a visible card invoke an
-- action on a different underlying entry, so this module owns exactly one
-- visible view — 'entriesFor' — and drawing, keyboard selection, mouse target
-- resolution, boundary movement, and the column heading count all read it.
--
-- The view this filters is 'Kanban.UI.Types.appVisibleBoard' — what the filter
-- criteria admit — rather than the open board beneath it. The open board stays
-- reachable through 'Kanban.UI.Util.entriesForBoard', which is what the
-- autosolve loop and session and worker reconciliation keep using: they are
-- about live work, not about what one column is showing, and no criteria may
-- change what they decide.
--
-- Everything here is presentation state. 'Kanban.UI.Types.AppState' has no
-- serialization instances, so a query can reach neither the snapshot cache nor
-- a board snapshot, and nothing in this module issues a GitHub request or
-- changes board freshness.
module Kanban.UI.Search
  ( -- * The query
    searchQueryLimit,
    searchQueryFor,
    activeQueryFor,

    -- * Matching
    normalizeForMatch,
    entryIdentityText,
    trackerIdentityText,
    matchesQuery,
    filterEntries,

    -- * The one visible view
    entriesFor,
    expandedTrackersFor,
    selectableRows,
    visibleRowsIn,
    columnCountText,

    -- * Selection by identity
    SearchAnchor (..),
    anchorAt,
    anchorFor,
    anchorRow,
    selectedAnchorIn,
    seatColumnOn,
    reseatSearch,
    moveSelectionBy,

    -- * Transitions
    SearchInput (..),
    searchInput,
    searchMouseTransfer,
    openSearch,
    closeSearch,
    closeSearchOn,
    transferSearchTo,
    transferSearchBy,
    applySearchInput,
    insertQueryChar,
    backspaceQuery,
  )
where

import Data.Char (isPrint)
import Data.List (findIndex)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Graphics.Vty as Vty
import Kanban.Domain
import Kanban.Workflow (entryItem)
import Kanban.UI.Types
import Kanban.UI.Util

-- | The most code points a query holds. Printable input stops at the bound
-- and is accepted again as soon as a Backspace makes room.
searchQueryLimit :: Int
searchQueryLimit = 256

-- | The query the box in @column@ is showing, if a live search targets that
-- column. Unlike 'activeQueryFor' this answers for an empty query too: the box
-- is drawn from the moment search opens, while an empty query filters nothing.
searchQueryFor :: AppState -> BoardColumn -> Maybe Text
searchQueryFor state column = do
  search <- state.appSearch
  if search.searchColumn == column then Just search.searchQuery else Nothing

-- | The query actually filtering @column@ right now. A query that normalizes
-- to nothing — empty, or only whitespace — filters nothing, so it answers
-- 'Nothing' here and every consumer sees the complete column beneath the box.
activeQueryFor :: AppState -> BoardColumn -> Maybe Text
activeQueryFor state column = do
  query <- searchQueryFor state column
  if Text.null (normalizeForMatch query) then Nothing else Just query

-- | The form both sides of a match are compared in: case-folded, with runs of
-- whitespace collapsed to one space.
normalizeForMatch :: Text -> Text
normalizeForMatch = Text.toCaseFold . Text.unwords . Text.words

-- | A card's visible identity: the @#number@ and title the renderer draws,
-- sanitized exactly as it sanitizes them. Nothing else about an item — body,
-- labels, assignees, branch, or status text — can reach a match.
entryIdentityText :: ColumnEntry -> Text
entryIdentityText = itemHeading . entryItem

-- | The visible identity of the header a tracker group draws above its
-- children. A populated group's header is synthesized while rendering rather
-- than being an entry of its own, so its identity is read off the tracker.
trackerIdentityText :: Tracker -> Text
trackerIdentityText tracker = itemHeading (IssueItem tracker.trackerIssue)

-- | Whether a query matches one visible identity.
matchesQuery :: Text -> Text -> Bool
matchesQuery query = matchesNeedle (normalizeForMatch query)

matchesNeedle :: Text -> Text -> Bool
matchesNeedle needle identity = needle `Text.isInfixOf` normalizeForMatch identity

-- | The entries of one column a query leaves visible, in board order.
--
-- A standalone card is kept when its own identity matches. A tracker group is
-- kept when its own identity matches or any of its children do, and only its
-- matching children are shown: a group whose header alone matches collapses to
-- a 'TrackerHeader', so the epic is still represented without leaking a child
-- that does not match. A query that normalizes to nothing keeps everything.
filterEntries :: Text -> [ColumnEntry] -> [ColumnEntry]
filterEntries query entries
  | Text.null needle = entries
  | otherwise = keep entries
  where
    needle = normalizeForMatch query
    matches = matchesNeedle needle
    keep [] = []
    keep remaining@(entry : rest) = case entry of
      Standalone _ -> [entry | matches (entryIdentityText entry)] <> keep rest
      TrackerHeader tracker -> [entry | matches (trackerIdentityText tracker)] <> keep rest
      Tracked context _ ->
        let tracker = context.trackingPrimary.membershipTracker
            (group, after) = span ((== Just (primaryTrackerNumber context)) . entryPrimaryTrackerNumber) remaining
            children = filter (matches . entryIdentityText) group
            kept
              | not (null children) = children
              | matches (trackerIdentityText tracker) = [TrackerHeader tracker]
              | otherwise = []
         in kept <> keep after

-- | What @column@ is showing: the entries the filter criteria admit, narrowed
-- again when a live query targets that column. This is the single view every
-- consumer reads.
entriesFor :: AppState -> BoardColumn -> [ColumnEntry]
entriesFor state column = case activeQueryFor state column of
  Nothing -> raw
  Just query -> filterEntries query raw
  where
    raw = entriesForBoard state.appVisibleBoard column

-- | The trackers drawing and selection treat as expanded in @column@.
--
-- A live query exposes every group that kept a child, so a match renders
-- beneath its header even under a collapsed epic. The saved set is never
-- written to, which is what lets closing search restore the column's
-- collapsed or expanded view exactly.
expandedTrackersFor :: AppState -> BoardColumn -> Set Int
expandedTrackersFor state column = case activeQueryFor state column of
  Nothing -> state.appExpandedTrackers
  Just _ -> state.appExpandedTrackers <> Set.fromList (childTrackerNumbers (entriesFor state column))

-- | The trackers a set of entries keeps at least one child of. A synthesized
-- 'TrackerHeader' is deliberately not one: it has no children to expose, so it
-- keeps whatever disclosure state the user saved for it.
childTrackerNumbers :: [ColumnEntry] -> [Int]
childTrackerNumbers entries = [number | entry@(Tracked _ _) <- entries, Just number <- [entryPrimaryTrackerNumber entry]]

-- | Which rows of a list of entries the selection may land on: every row of an
-- expanded group, and one row for a collapsed group.
visibleRowsIn :: Set Int -> [ColumnEntry] -> [Int]
visibleRowsIn expandedTrackers entries = collect (zip [0 ..] entries)
  where
    collect [] = []
    collect indexedEntries@((row, entry) : rest) = case entryPrimaryTrackerNumber entry of
      Nothing -> row : collect rest
      Just trackerNumber ->
        let (groupEntries, remaining) = span ((== Just trackerNumber) . entryPrimaryTrackerNumber . snd) indexedEntries
         in if trackerNumber `Set.member` expandedTrackers
              then map fst groupEntries <> collect remaining
              else row : collect remaining

-- | The rows @column@ offers the selection right now, in the view it is
-- showing.
selectableRows :: AppState -> BoardColumn -> [Int]
selectableRows state column = visibleRowsIn (expandedTrackersFor state column) (entriesFor state column)

-- | The count in a column's heading.
--
-- While a query is live the heading shows the visible result count over the
-- column's full total. Both are exact: a board is only ever drawn from a
-- generation that followed its connections to their end, so no total here
-- stands for more than it says (§13).
--
-- The total is counted over what the criteria admit rather than over every
-- card in memory, which is what keeps a loaded completed history from turning
-- the default heading into a ratio of a history nothing is showing.
columnCountText :: AppState -> BoardColumn -> Text
columnCountText state column = case activeQueryFor state column of
  Nothing -> total
  Just _ -> showText (length (entriesFor state column)) <> "/" <> total
  where
    total = showText (length (entriesForBoard state.appVisibleBoard column))

-- | What a selected row is, for the purpose of finding it again once the view
-- has changed.
--
-- A row that draws as a tracker header is anchored on the tracker's issue
-- number rather than on the entry beneath it, because a populated group's
-- header is synthesized from its child rows: while that group is collapsed the
-- row the user selected /is/ its first child, but what they see and act on is
-- the epic. Anchoring on the child would lose the header the moment a query
-- replaced the group with a synthesized 'TrackerHeader' — and lose it again on
-- the way back, when closing restored the children underneath it.
data SearchAnchor
  = -- | An ordinary card row, kept by the item it draws.
    AnchorItem ItemId
  | -- | A row that draws an epic's header, kept by that epic's issue number.
    AnchorTracker Int
  deriving stock (Eq, Show)

-- | The anchor for one entry, given the trackers its view treats as expanded.
anchorFor :: Set Int -> ColumnEntry -> SearchAnchor
anchorFor expandedTrackers entry = case entry of
  TrackerHeader tracker -> AnchorTracker tracker.trackerIssue.issueNumber
  Tracked context _
    | primaryTrackerNumber context `Set.notMember` expandedTrackers -> AnchorTracker (primaryTrackerNumber context)
  _ -> AnchorItem (itemId (entryItem entry))

-- | The anchor for one row of what @column@ is showing.
anchorAt :: AppState -> BoardColumn -> Int -> Maybe SearchAnchor
anchorAt state column row = anchorFor (expandedTrackersFor state column) <$> safeIndex row (entriesFor state column)

-- | The anchor of the entry selected in @column@, read off the view that
-- column is showing.
selectedAnchorIn :: AppState -> BoardColumn -> Maybe SearchAnchor
selectedAnchorIn state column = anchorAt state column (selectedRow state column)

-- | The row an anchor names in a set of entries, or 'Nothing' when nothing
-- there answers to it.
--
-- A tracker anchor resolves to its group's first row, which is the row that
-- draws the header while the group is collapsed and its first child once it is
-- not — and is the one row of the group a collapsed view offers either way. An
-- item anchor resolves only to its own row: a card the view has since
-- collapsed away is lost rather than mapped to something near it.
anchorRow :: [ColumnEntry] -> SearchAnchor -> Maybe Int
anchorRow entries = \case
  AnchorTracker number -> findIndex ((== Just number) . entryPrimaryTrackerNumber) entries
  AnchorItem identity -> findIndex ((== identity) . itemId . entryItem) entries

-- | Seat @column@'s remembered row on the entry @anchor@ names, in whatever
-- that column shows now, and select that column.
--
-- The row 'anchorRow' resolves is kept only while it is still /selectable/ in
-- the resulting view, which is an exact membership test rather than a
-- nearest-row one: a card the restored column has collapsed back under its
-- epic is not selectable, and resolving it to that epic's row would land on
-- neither the anchored card nor the first result whenever the group is not the
-- column's first. Anything else — an anchor that is gone, and one the view no
-- longer offers — takes the first selectable row, and an empty view leaves
-- nothing selected, which is what a row index no entry answers to already
-- means.
seatColumnOn :: BoardColumn -> Maybe SearchAnchor -> AppState -> AppState
seatColumnOn column anchor state =
  state
    { appSelectedColumn = column,
      appSelectedRows = Map.insert column seated state.appSelectedRows,
      appEnsureSelectionVisible = True
    }
  where
    rows = selectableRows state column
    located = anchor >>= anchorRow (entriesFor state column)
    seated = case located of
      Just row | row `elem` rows -> row
      _ -> case rows of
        row : _ -> row
        [] -> 0

-- | Re-seat the search target column after anything that can change what its
-- query leaves visible. A no-op with no search live, so every other path keeps
-- deciding the selection the board's own way.
reseatSearch :: Maybe SearchAnchor -> AppState -> AppState
reseatSearch anchor state = case state.appSearch of
  Nothing -> state
  Just search -> seatColumnOn search.searchColumn anchor state

-- | Move the selected column's selection by @amount@ rows among the ones that
-- column offers.
moveSelectionBy :: Int -> AppState -> AppState
moveSelectionBy amount state = case safeIndex nextPosition rows of
  Nothing -> state {appEnsureSelectionVisible = True, appNotice = Nothing}
  Just nextRow ->
    state
      { appSelectedRows = Map.insert column nextRow state.appSelectedRows,
        appEnsureSelectionVisible = True,
        appNotice = Nothing
      }
  where
    column = state.appSelectedColumn
    rows = selectableRows state column
    currentPosition = maybe 0 id (findIndex (== selectedRow state column) rows)
    nextPosition = max 0 (min (length rows - 1) (currentPosition + amount))

-- | The board column a mouse press landed in, for the one question a live
-- search asks of a press: which column was it aimed at?
--
-- Only the three names a column draws answer. The drainer button is its own
-- 'Name' dispatched by its own arm, and every overlay target belongs to
-- something that is not a column, so neither can transfer a search.
mouseColumn :: Name -> Maybe BoardColumn
mouseColumn = \case
  CardTarget column _ -> Just column
  EpicTarget column _ _ -> Just column
  ColumnViewport column -> Just column
  _ -> Nothing

-- | The column a mouse press moves a live search to, or 'Nothing' when the
-- press is not a transfer and dispatch decides it the ordinary way.
--
-- A left or right press aimed at any column but the searched one transfers,
-- whether it landed on a card, on an epic's header, or on the column's
-- whitespace — the three are one rule, which is what makes the rule
-- predictable. Everything else is left alone: a press with no search open, one
-- inside the searched column, the wheel in any column — it retargets nothing,
-- so it keeps scrolling whatever is under the pointer — and the middle button,
-- which the board has never given a meaning.
searchMouseTransfer :: AppState -> Name -> Vty.Button -> Maybe BoardColumn
searchMouseTransfer state name button = do
  search <- state.appSearch
  column <- mouseColumn name
  if transfers && column /= search.searchColumn then Just column else Nothing
  where
    transfers = case button of
      Vty.BLeft -> True
      Vty.BRight -> True
      _ -> False

-- | Open search on the Issues column with an empty query. That column becomes
-- the selected one and is brought into the board viewport, and the card that
-- was selected there stays selected.
openSearch :: AppState -> AppState
openSearch state =
  seatColumnOn
    Issues
    (selectedAnchorIn state Issues)
    (state {appSearch = Just (ColumnSearch Issues ""), appNotice = Nothing})

-- | End a live search, restoring the target column complete and keeping
-- @anchor@ selected by identity rather than by row number.
closeSearchOn :: Maybe SearchAnchor -> AppState -> AppState
closeSearchOn anchor state = case state.appSearch of
  Nothing -> state
  Just search -> seatColumnOn search.searchColumn anchor (state {appSearch = Nothing, appNotice = Nothing})

-- | Move a live search to @column@, with an empty query, selecting and
-- revealing that column.
--
-- This is the whole transfer, and every path that transfers — a click, Left,
-- and Right — is this one transition, so the state each reaches is the same
-- state. A transfer to the column already searched is not a move at all and
-- leaves everything untouched, which is what a Left at the leftmost column
-- resolves to: the query, the selection, and any notice on screen survive a
-- press that visibly does nothing.
--
-- Both columns are re-seated by identity rather than by row number, for
-- reasons that differ. The column being left is showing a filtered view, so
-- its remembered row is an index into results; restoring it complete would
-- otherwise leave that number selecting a different card. The column being
-- entered keeps exactly the row it remembered — the anchor it is re-seated on
-- is its own current selection, and the view it is read from is the same
-- unfiltered view either side of the transfer — because a transferring click
-- moves the search and nothing else, and choosing a row there is the second
-- click's business.
transferSearchTo :: BoardColumn -> AppState -> AppState
transferSearchTo column state = case state.appSearch of
  Nothing -> state
  Just search
    | search.searchColumn == column -> state
    | otherwise ->
        seatColumnOn column (selectedAnchorIn state column)
          . seatColumnOn search.searchColumn (selectedAnchorIn state search.searchColumn)
          $ state {appSearch = Just (ColumnSearch column ""), appNotice = Nothing}

-- | Move a live search one column left (@-1@) or right (@1@).
--
-- Clamped rather than wrapped, exactly as 'Kanban.UI.Selection.moveColumn'
-- clamps the ordinary board: at the leftmost or rightmost column the
-- destination resolves to the column already searched, which 'transferSearchTo'
-- leaves alone.
transferSearchBy :: Int -> AppState -> AppState
transferSearchBy delta state = case state.appSearch of
  Nothing -> state
  Just search -> transferSearchTo (shiftColumn delta search.searchColumn) state

shiftColumn :: Int -> BoardColumn -> BoardColumn
shiftColumn delta column = toEnum (max 0 (min (fromEnum (maxBound :: BoardColumn)) (fromEnum column + delta)))

-- | 'closeSearchOn' anchored on whatever result is selected now.
closeSearch :: AppState -> AppState
closeSearch state = case state.appSearch of
  Nothing -> state
  Just search -> closeSearchOn (selectedAnchorIn state search.searchColumn) state

-- | What one key press means while search is live.
--
-- 'Nothing' means the press is not search's business and the base-board table
-- in "Kanban.UI.Keys" decides it, which is how @q@ keeps quitting and how
-- every Ctrl, Meta, or Alt chord keeps its ordinary board meaning.
data SearchInput
  = SearchInsert Char
  | SearchBackspace
  | SearchClose
  | -- | Hand the keyboard to the card filter panel, showing it if it is
    -- hidden and leaving the query exactly as it is. Applying it is
    -- "Kanban.UI.Filter"'s, which this module cannot import, so dispatch
    -- carries it out for the same reason it carries out 'SearchOpenDetails'.
    SearchFocusFilter
  | SearchOpenDetails
  | SearchMove Int
  | -- | Move the search one column left or right, by the same clamped step
    -- the ordinary board's column movement takes.
    SearchTransfer Int
  deriving stock (Eq, Show)

searchInput :: Maybe ColumnSearch -> Vty.Event -> Maybe SearchInput
searchInput Nothing _ = Nothing
searchInput (Just _) (Vty.EvKey key modifiers)
  | any (`elem` modifiers) [Vty.MCtrl, Vty.MMeta, Vty.MAlt] = Nothing
  | otherwise = case key of
      -- The three printable keys search does not take: `s` closes it, `f`
      -- moves the keyboard to the filter panel with the query intact, and `q`
      -- falls through to the guarded dashboard quit -- which is why neither
      -- letter can be typed into a query. Uppercase `F` is claimed below as
      -- ordinary text, exactly as every other printable key is.
      Vty.KChar 's' -> Just SearchClose
      Vty.KChar 'f' -> Just SearchFocusFilter
      Vty.KChar 'q' -> Nothing
      Vty.KChar character | isPrint character -> Just (SearchInsert character)
      Vty.KBS -> Just SearchBackspace
      Vty.KEsc -> Just SearchClose
      Vty.KEnter -> Just SearchOpenDetails
      Vty.KUp -> Just (SearchMove (-1))
      Vty.KDown -> Just (SearchMove 1)
      -- The arrows move the search itself rather than the column selection
      -- beneath it, which is what keeps the searched and the selected column
      -- from ever disagreeing. `h` and `l` are printable, so they were claimed
      -- above as text: only the arrows transfer.
      Vty.KLeft -> Just (SearchTransfer (-1))
      Vty.KRight -> Just (SearchTransfer 1)
      _ -> Nothing
searchInput _ _ = Nothing

-- | The query after one insertion, bounded at 'searchQueryLimit' code points.
insertQueryChar :: Char -> Text -> Text
insertQueryChar character query
  | Text.length query >= searchQueryLimit = query
  | otherwise = Text.snoc query character

-- | The query after one Backspace: one code point shorter, never one byte.
backspaceQuery :: Text -> Text
backspaceQuery = Text.dropEnd 1

-- | What one 'SearchInput' does to the dashboard on its own.
--
-- Two inputs this cannot finish: opening a card's details is
-- 'Kanban.UI.Selection.openSelectedDetails', so dispatch runs that and then
-- ends search on the identity it opened, and focusing the filter panel is
-- 'Kanban.UI.Filter.focusFilterPanel', which imports this module. Everything
-- else, including re-seating the selection after every edit, is decided here.
applySearchInput :: SearchInput -> AppState -> AppState
applySearchInput = \case
  SearchInsert character -> editQuery (insertQueryChar character)
  SearchBackspace -> editQuery backspaceQuery
  SearchClose -> closeSearch
  SearchMove amount -> moveSelectionBy amount
  SearchTransfer delta -> transferSearchBy delta
  SearchFocusFilter -> id
  SearchOpenDetails -> id

-- | Refilter the target column after a query edit, keeping whichever result
-- was selected before it selected afterwards.
editQuery :: (Text -> Text) -> AppState -> AppState
editQuery change state = case state.appSearch of
  Nothing -> state
  Just search ->
    reseatSearch
      (selectedAnchorIn state search.searchColumn)
      (state {appSearch = Just search {searchQuery = change search.searchQuery}})
