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
-- The raw board stays reachable through 'Kanban.UI.Util.entriesForBoard',
-- which is what selection normalization, the autosolve loop, and session
-- reconciliation keep using: they are about the board, not about what one
-- column is showing.
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
    selectedIdentityIn,
    seatColumnOn,
    reseatSearch,
    moveSelectionBy,

    -- * Transitions
    SearchInput (..),
    searchInput,
    searchClickAllowed,
    openSearch,
    closeSearch,
    closeSearchOn,
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

-- | What @column@ is showing: the board's entries, filtered when a live query
-- targets that column. This is the single view every consumer reads.
entriesFor :: AppState -> BoardColumn -> [ColumnEntry]
entriesFor state column = case activeQueryFor state column of
  Nothing -> raw
  Just query -> filterEntries query raw
  where
    raw = entriesForBoard state.appBoard column

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
-- column's full total, and GitHub's @+@ truncation marker stays attached to
-- that total rather than to the result count, which is never truncated.
columnCountText :: AppState -> BoardColumn -> Text
columnCountText state column = case activeQueryFor state column of
  Nothing -> total
  Just _ -> showText (length (entriesFor state column)) <> "/" <> total
  where
    total = showText (length (entriesForBoard state.appBoard column)) <> if columnMayBeTruncated then "+" else ""
    columnMayBeTruncated = case column of
      Issues -> state.appIssuesTruncated
      Active -> state.appIssuesTruncated
      Reviewing -> state.appPullRequestsTruncated
      Done -> state.appPullRequestsTruncated

-- | The identity of the entry selected in @column@, read off the view that
-- column is showing. A tracker header carries its tracker's issue number,
-- because a populated header is synthesized from child rows and so has no
-- identity of its own to keep.
selectedIdentityIn :: AppState -> BoardColumn -> Maybe ItemId
selectedIdentityIn state column = entryIdentity <$> safeIndex (selectedRow state column) (entriesFor state column)

entryIdentity :: ColumnEntry -> ItemId
entryIdentity = itemId . entryItem

-- | Seat @column@'s remembered row on the entry @anchor@ names, in whatever
-- that column shows now, and select that column.
--
-- An anchor that is gone falls back to the first selectable row, and an empty
-- view leaves nothing selected — which is what a row index no entry answers to
-- already means. An anchor that is still there but sits inside a group the
-- restored view has collapsed resolves to that group's own row, exactly as
-- 'Kanban.UI.Selection.normalizeCollapsedRow' resolves it everywhere else: it
-- is the nearest thing to the card the user was on that a collapsed column
-- offers, and sending them to the top of the column instead would lose a place
-- the rest of the board keeps. Under a live non-empty query the question does
-- not arise, because every group the query kept a child of is exposed and so
-- every visible row is selectable.
seatColumnOn :: BoardColumn -> Maybe ItemId -> AppState -> AppState
seatColumnOn column anchor state =
  state
    { appSelectedColumn = column,
      appSelectedRows = Map.insert column seated state.appSelectedRows,
      appEnsureSelectionVisible = True
    }
  where
    rows = selectableRows state column
    located = anchor >>= \identity -> findIndex ((== identity) . entryIdentity) (entriesFor state column)
    seated = case located >>= selectableRowFor rows of
      Just row -> row
      Nothing -> case rows of
        row : _ -> row
        [] -> 0

-- | The selectable row a row resolves to: itself when the view offers it, and
-- otherwise the collapsed group's own row above it.
selectableRowFor :: [Int] -> Int -> Maybe Int
selectableRowFor rows row = safeLast (filter (<= row) rows)

-- | Re-seat the search target column after anything that can change what its
-- query leaves visible. A no-op with no search live, so every other path keeps
-- deciding the selection the board's own way.
reseatSearch :: Maybe ItemId -> AppState -> AppState
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

-- | Whether a click on @column@ may act while search is live.
--
-- A non-scroll click on another column is consumed instead: moving the
-- selection there would leave the searched column and the selected column
-- disagreeing, which is the same reason Left and Right are inert in this
-- phase. Wheel scrolling is not routed through this — it retargets nothing.
searchClickAllowed :: AppState -> BoardColumn -> Bool
searchClickAllowed state column = maybe True ((== column) . (.searchColumn)) state.appSearch

-- | Open search on the Issues column with an empty query. That column becomes
-- the selected one and is brought into the board viewport, and the card that
-- was selected there stays selected.
openSearch :: AppState -> AppState
openSearch state =
  seatColumnOn
    Issues
    (selectedIdentityIn state Issues)
    (state {appSearch = Just (ColumnSearch Issues ""), appNotice = Nothing})

-- | End a live search, restoring the target column complete and keeping
-- @anchor@ selected by identity rather than by row number.
closeSearchOn :: Maybe ItemId -> AppState -> AppState
closeSearchOn anchor state = case state.appSearch of
  Nothing -> state
  Just search -> seatColumnOn search.searchColumn anchor (state {appSearch = Nothing, appNotice = Nothing})

-- | 'closeSearchOn' anchored on whatever result is selected now.
closeSearch :: AppState -> AppState
closeSearch state = case state.appSearch of
  Nothing -> state
  Just search -> closeSearchOn (selectedIdentityIn state search.searchColumn) state

-- | What one key press means while search is live.
--
-- 'Nothing' means the press is not search's business and the base-board table
-- in "Kanban.UI.Keys" decides it, which is how @q@ keeps quitting and how
-- every Ctrl, Meta, or Alt chord keeps its ordinary board meaning.
data SearchInput
  = SearchInsert Char
  | SearchBackspace
  | SearchClose
  | SearchOpenDetails
  | SearchMove Int
  | SearchIgnore
  deriving stock (Eq, Show)

searchInput :: Maybe ColumnSearch -> Vty.Event -> Maybe SearchInput
searchInput Nothing _ = Nothing
searchInput (Just _) (Vty.EvKey key modifiers)
  | any (`elem` modifiers) [Vty.MCtrl, Vty.MMeta, Vty.MAlt] = Nothing
  | otherwise = case key of
      -- The two printable keys search does not take: `s` closes it, and `q`
      -- falls through to the guarded dashboard quit, which is why the letter
      -- `q` cannot be typed into a query.
      Vty.KChar 's' -> Just SearchClose
      Vty.KChar 'q' -> Nothing
      Vty.KChar character | isPrint character -> Just (SearchInsert character)
      Vty.KBS -> Just SearchBackspace
      Vty.KEsc -> Just SearchClose
      Vty.KEnter -> Just SearchOpenDetails
      Vty.KUp -> Just (SearchMove (-1))
      Vty.KDown -> Just (SearchMove 1)
      -- Consumed rather than passed on: the epic's last child gives these the
      -- column-transfer meaning, and moving the column selection now would
      -- leave the searched and selected columns disagreeing.
      Vty.KLeft -> Just SearchIgnore
      Vty.KRight -> Just SearchIgnore
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
-- 'SearchOpenDetails' is the one input this cannot finish: opening a card's
-- details is 'Kanban.UI.Selection.openSelectedDetails', so dispatch runs that
-- and then ends search on the identity it opened. Everything else, including
-- re-seating the selection after every edit, is decided here.
applySearchInput :: SearchInput -> AppState -> AppState
applySearchInput = \case
  SearchInsert character -> editQuery (insertQueryChar character)
  SearchBackspace -> editQuery backspaceQuery
  SearchClose -> closeSearch
  SearchMove amount -> moveSelectionBy amount
  SearchOpenDetails -> id
  SearchIgnore -> id

-- | Refilter the target column after a query edit, keeping whichever result
-- was selected before it selected afterwards.
editQuery :: (Text -> Text) -> AppState -> AppState
editQuery change state = case state.appSearch of
  Nothing -> state
  Just search ->
    reseatSearch
      (selectedIdentityIn state search.searchColumn)
      (state {appSearch = Just search {searchQuery = change search.searchQuery}})
