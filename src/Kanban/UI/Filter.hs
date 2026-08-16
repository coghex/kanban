-- | Where the dashboard's filter criteria meet its state: the transition that
-- recomputes the board those criteria admit, and the panel they are edited
-- through.
--
-- Every input to 'Kanban.Filter.visibleBoardFor' lives in 'AppState', so this
-- is the single place 'appVisibleBoard' is written. Anything that replaces the
-- open board, the open snapshot, the completed history, or the criteria
-- themselves ends by applying 'refreshVisibleBoard', and nothing else has to
-- know how the four combine.
--
-- The panel below is presentation state and pure transitions only. An edit
-- issues no GitHub request, writes no cache, and changes no board freshness:
-- it recomputes the admitted board and re-seats every column on the entry it
-- was showing, which is what keeps a row index from ever surviving a criteria
-- change (@docs\/design.md@ §7).
module Kanban.UI.Filter
  ( -- * The admitted board
    refreshVisibleBoard,
    applyCriteriaChange,

    -- * Read-only history
    readOnlyHistoryRefusal,
    readOnlyHistoryRefusalFor,

    -- * The panel
    FilterInput (..),
    applyFilterInput,
    closeFilterPanel,
    filterInput,
    filterPanelFocusedBox,
    focusFilterPanel,
    focusedFilterPanel,
    focusedSearch,
    toggleFilterPanel,
    toggleFilterBoxFromClick,

    -- * What the panel reports
    FacetCount (..),
    completedHistoryStatusText,
    criteriaAreFiltering,
    facetCount,
    facetCountText,
    filterBoxCountText,
    filteredCount,
    rawEntryCount,

    -- * What the card area draws
    CardSurface (..),
    cardSurfaceFor,
    completedCardsBlocked,
  )
where

import Data.List (elemIndex, find)
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (UTCTime)
import qualified Graphics.Vty as Vty
import Kanban.Config (ResolvedConfig (..))
import Kanban.Domain
import Kanban.Filter
import Kanban.UI.Search (SearchAnchor, openSearch, seatColumnOn, selectedAnchorIn)
import Kanban.UI.Types
import Kanban.UI.Util (allColumns, showText)
import Kanban.Workflow (itemCompleted, readOnlyHistoryNotice)

-- | Recompute what the criteria admit from the datasets currently held.
refreshVisibleBoard :: AppState -> AppState
refreshVisibleBoard state =
  state
    { appVisibleBoard =
        visibleBoardFor
          state.appConfig.resolvedWorkflow
          state.appFilterCriteria
          state.appBoard
          state.appOpenSnapshot
          state.appCompletedHistory
    }

-- | One criteria edit, complete: the new criteria, the board they admit, and
-- every column re-seated on the entry it was showing.
--
-- The anchors are read off the view /before/ the edit and resolved against the
-- view after it, so a card that survives keeps the selection wherever the
-- filter moved its row to, and one the criteria hid takes its column's first
-- selectable entry instead. Every column is re-seated rather than only the
-- selected one, because a criteria change is board-wide and the row each
-- column remembered indexes what that column was showing.
--
-- 'seatColumnOn' resolves against 'Kanban.UI.Search.entriesFor', which is the
-- composed view — criteria first, then any live query — so this is
-- reconciliation after filtering /and/ search rather than against a raw board.
applyCriteriaChange :: (FilterCriteria -> FilterCriteria) -> AppState -> AppState
applyCriteriaChange change state = reseat (refreshVisibleBoard edited)
  where
    edited = state {appFilterCriteria = change state.appFilterCriteria, appNotice = Nothing}
    anchors :: [(BoardColumn, Maybe SearchAnchor)]
    anchors = [(column, selectedAnchorIn state column) | column <- allColumns]
    -- Each seating selects the column it seats, so the column the user was in
    -- is seated last and is the one left selected.
    reseat seated =
      foldl
        (\current (column, anchor) -> seatColumnOn column anchor current)
        seated
        (filter ((/= state.appSelectedColumn) . fst) anchors <> filter ((== state.appSelectedColumn) . fst) anchors)

-- | Why a mutating action must decline this item, or 'Nothing' when it may
-- proceed.
--
-- The item a caller holds is not trusted on its own. A details overlay, a
-- solve chooser, and a reusable session can each have been opened while the
-- work was live and still be on screen after a refresh settled it, so the
-- newest completed generation is asked too. That is what makes this safe to
-- call at a launch boundary as well as at the key press that reached it.
readOnlyHistoryRefusal :: AppState -> BoardItem -> Maybe Text
readOnlyHistoryRefusal state item
  | itemCompleted item = Just (readOnlyHistoryNotice item)
  | otherwise = readOnlyHistoryRefusalFor state (itemId item)

-- | The same refusal for work named only by its number.
--
-- A session, a worker, and an overlay's resumable turn are all keyed by the
-- issue or pull-request number rather than by a card, so a launch boundary
-- reached from one of them has nothing but the number to ask with. The answer
-- comes from the newest completed generation either way, which is what makes
-- this the same question 'readOnlyHistoryRefusal' asks.
readOnlyHistoryRefusalFor :: AppState -> ItemId -> Maybe Text
readOnlyHistoryRefusalFor state target = readOnlyHistoryNotice <$> settledItem state target

-- | The item the completed generation holds under this identity, if it holds
-- one at all.
settledItem :: AppState -> ItemId -> Maybe BoardItem
settledItem state target = do
  history <- state.appCompletedHistory
  case target of
    IssueId number ->
      IssueItem <$> find ((== number) . (.issueNumber)) history.historyIssues
    PullRequestId number ->
      PullRequestItem <$> find ((== number) . (.pullRequestNumber)) history.historyPullRequests

-- ---------------------------------------------------------------------------
-- Focus
-- ---------------------------------------------------------------------------

-- | The panel a key press reaches, or 'Nothing' when nothing on screen gives
-- it the keyboard.
--
-- A panel that handed focus to a search takes it back the moment that search
-- ends, which is why this is derived rather than stored: no close path has to
-- know the panel is underneath it.
focusedFilterPanel :: AppState -> Maybe FilterPanel
focusedFilterPanel state = do
  panel <- state.appFilterPanel
  if panel.filterPanelYielded && isJust state.appSearch then Nothing else Just panel

-- | The live search a key press reaches. A focused panel outranks it, so the
-- box under the cursor is edited rather than the query typed into.
--
-- The completed blocker outranks both: it draws no column, so there is no box
-- on screen to type into and no result to move between. The query itself is
-- untouched and comes back with the columns the moment @Closed@ is unchecked.
focusedSearch :: AppState -> Maybe ColumnSearch
focusedSearch state
  | completedCardsBlocked state = Nothing
  | isJust (focusedFilterPanel state) = Nothing
  | otherwise = state.appSearch

-- | The checkbox the panel is focused on, for drawing. 'Nothing' while the
-- panel is hidden or a search has the keyboard, so the frame shows no focused
-- box the keys cannot move.
filterPanelFocusedBox :: AppState -> Maybe FilterBox
filterPanelFocusedBox state = (.filterPanelBox) <$> focusedFilterPanel state

-- | Where the panel opens: the first checkbox of the first group.
firstFilterBox :: FilterBox
firstFilterBox = case everyFilterBox of
  box : _ -> box
  -- Unreachable: every facet is 'Bounded' and non-empty.
  [] -> LifecycleBox LifecycleOpen

-- ---------------------------------------------------------------------------
-- Transitions
-- ---------------------------------------------------------------------------

-- | What one key press means while the panel has focus.
--
-- 'Nothing' means the press is not the panel's business and the base-board
-- table in "Kanban.UI.Keys" decides it, which is how @q@ keeps quitting, @?@
-- keeps opening help, @u@ keeps refreshing, and every Ctrl, Meta, or Alt
-- chord keeps its ordinary board meaning while the panel is up.
data FilterInput
  = -- | One box up or down the flat inventory, across group boundaries.
    FilterMoveBox Int
  | -- | One group left or right, keeping the option's position within it.
    FilterMoveGroup Int
  | FilterToggleBox
  | FilterRestoreDefaults
  | FilterHide
  | -- | Hand the keyboard to the column search, opening one if none is live.
    FilterFocusSearch
  deriving stock (Eq, Show)

filterInput :: Maybe FilterPanel -> Vty.Event -> Maybe FilterInput
filterInput Nothing _ = Nothing
filterInput (Just _) (Vty.EvKey key modifiers)
  | any (`elem` modifiers) [Vty.MCtrl, Vty.MMeta, Vty.MAlt] = Nothing
  | otherwise = case key of
      Vty.KChar 'j' -> Just (FilterMoveBox 1)
      Vty.KChar 'k' -> Just (FilterMoveBox (-1))
      Vty.KDown -> Just (FilterMoveBox 1)
      Vty.KUp -> Just (FilterMoveBox (-1))
      Vty.KLeft -> Just (FilterMoveGroup (-1))
      Vty.KRight -> Just (FilterMoveGroup 1)
      Vty.KChar ' ' -> Just FilterToggleBox
      Vty.KChar 'd' -> Just FilterRestoreDefaults
      Vty.KChar 'f' -> Just FilterHide
      Vty.KEsc -> Just FilterHide
      Vty.KChar 's' -> Just FilterFocusSearch
      -- Left for the guarded dashboard quit, exactly as search leaves it.
      _ -> Nothing
filterInput _ _ = Nothing

-- | What one 'FilterInput' does to the dashboard. Total in 'FilterInput', so a
-- key cannot be given a meaning above without its effect being decided here —
-- and pure, so the whole interaction is exercisable without a terminal.
applyFilterInput :: FilterInput -> AppState -> AppState
applyFilterInput = \case
  FilterMoveBox amount -> moveFilterBox amount
  FilterMoveGroup delta -> moveFilterGroup delta
  FilterToggleBox -> toggleFocusedBox
  FilterRestoreDefaults -> applyCriteriaChange (const defaultFilterCriteria)
  FilterHide -> closeFilterPanel
  FilterFocusSearch -> focusSearchFromFilter

-- | Show the panel and give it the keyboard, or hide it if it is already up.
--
-- Hiding leaves the criteria exactly as they are, which is the whole reason
-- the footer marks a non-default set while the panel is gone.
toggleFilterPanel :: AppState -> AppState
toggleFilterPanel state
  | isJust state.appFilterPanel = closeFilterPanel state
  | otherwise = focusFilterPanel state

-- | Show the panel and give it the keyboard, leaving a live query untouched.
-- This is what lowercase @f@ reaches from an open search box.
--
-- A panel still on screen keeps the box it was on, so taking the keyboard back
-- from a search carries on from where it left off; one that was hidden opens
-- at the first box, because hiding it is what puts the panel away.
focusFilterPanel :: AppState -> AppState
focusFilterPanel state =
  state
    { appFilterPanel = Just (FilterPanel focusedBox False),
      appNotice = Nothing
    }
  where
    focusedBox = maybe firstFilterBox (.filterPanelBox) state.appFilterPanel

closeFilterPanel :: AppState -> AppState
closeFilterPanel state = state {appFilterPanel = Nothing, appNotice = Nothing}

-- | Hand the keyboard to the column search. With none live, one is opened on
-- the Issues column exactly as the board's own @s@ opens it, so the key means
-- the same thing from the panel as it does from the board — including under
-- the completed blocker, where the board's own @s@ is inert too because there
-- is no column drawn to search.
focusSearchFromFilter :: AppState -> AppState
focusSearchFromFilter state
  | completedCardsBlocked state = state
  | otherwise = yielded (if isJust state.appSearch then state else openSearch state)
  where
    yielded current =
      current {appFilterPanel = (\panel -> panel {filterPanelYielded = True}) <$> current.appFilterPanel}

-- | Move the focus @amount@ boxes along the flat inventory, clamped at either
-- end exactly as the board's own selection movement is clamped.
moveFilterBox :: Int -> AppState -> AppState
moveFilterBox amount state = withFocusedBox state $ \box ->
  let position = fromMaybe 0 (elemIndex box everyFilterBox)
      next = max 0 (min (length everyFilterBox - 1) (position + amount))
   in fromMaybe box (safeBox next everyFilterBox)

-- | Move the focus @delta@ groups, keeping the option's position inside the
-- group and clamping it to the shorter group's last option. Clamped between
-- groups too, so a press at either end changes nothing.
moveFilterGroup :: Int -> AppState -> AppState
moveFilterGroup delta state = withFocusedBox state $ \box ->
  let group = filterBoxGroup box
      groups = [minBound .. maxBound] :: [FilterGroup]
      position = fromMaybe 0 (elemIndex box (filterGroupBoxes group))
      nextGroup = toEnum (max 0 (min (length groups - 1) (fromEnum group + delta)))
      candidates = filterGroupBoxes nextGroup
      seated = max 0 (min (length candidates - 1) position)
   in fromMaybe box (safeBox seated candidates)

withFocusedBox :: AppState -> (FilterBox -> FilterBox) -> AppState
withFocusedBox state change = case focusedFilterPanel state of
  Nothing -> state
  Just panel -> state {appFilterPanel = Just panel {filterPanelBox = change panel.filterPanelBox}}

safeBox :: Int -> [FilterBox] -> Maybe FilterBox
safeBox index boxes
  | index < 0 = Nothing
  | otherwise = case drop index boxes of
      box : _ -> Just box
      [] -> Nothing

toggleFocusedBox :: AppState -> AppState
toggleFocusedBox state = case focusedFilterPanel state of
  Nothing -> state
  Just panel -> applyCriteriaChange (toggleFilterBox panel.filterPanelBox) state

-- | A click on a checkbox: it toggles, and the panel's own focus moves to the
-- box that was clicked, so the keyboard carries on from where the pointer
-- left off. Which surface holds the keyboard is left alone — a click edits the
-- criteria without taking the query's focus away from it.
toggleFilterBoxFromClick :: FilterBox -> AppState -> AppState
toggleFilterBoxFromClick box state =
  applyCriteriaChange
    (toggleFilterBox box)
    state {appFilterPanel = (\panel -> panel {filterPanelBox = box}) <$> state.appFilterPanel}

-- ---------------------------------------------------------------------------
-- What the panel reports
-- ---------------------------------------------------------------------------

-- | Whether the criteria are hiding anything at all, which is what the footer
-- marks while the panel is not on screen to show them.
criteriaAreFiltering :: AppState -> Bool
criteriaAreFiltering state = state.appFilterCriteria /= defaultFilterCriteria

-- | What a count over the current datasets can honestly say.
--
-- Only 'FacetCountExact' is a number. The other two are the whole of §13's
-- rule that no count stands for more than it says: a figure that would depend
-- on an open generation that has not published, or on a completed generation
-- still being traversed, is reported as unknown or as progress rather than as
-- a total the data cannot support.
data FacetCount
  = FacetCountExact Int
  | -- | A completed generation is in flight, with its loaded/total figures
    -- when both connections have reported one.
    FacetCountLoading (Maybe (Int, Int))
  | FacetCountUnknown
  deriving stock (Eq, Show)

-- | The count beside one checkbox: how many cards its own value would admit
-- under every other group's current selection.
facetCount :: AppState -> FilterBox -> FacetCount
facetCount state box = countUnder state (restrictedToBox box state.appFilterCriteria)

-- | The panel's raw count: every card the complete datasets hold, whatever the
-- criteria currently admit.
rawEntryCount :: AppState -> FacetCount
rawEntryCount state =
  countUnder
    state
    FilterCriteria
      { filterLifecycle = everyFacetValue,
        filterKind = everyFacetValue,
        filterWorkflow = everyFacetValue,
        filterStructure = everyFacetValue
      }

-- | The panel's filtered count: how many cards the criteria in force admit.
--
-- Asked the same way every other count is rather than read off the admitted
-- board, because the two disagree in exactly the case that matters: with
-- @Closed@ checked over a generation still being traversed, the board holds
-- whatever history was seeded while the blocker is showing none of it, and a
-- figure taken from it would state a total the next publication will change.
filteredCount :: AppState -> FacetCount
filteredCount state = countUnder state state.appFilterCriteria

-- | How many cards one criteria set admits, or why that cannot be said yet.
countUnder :: AppState -> FilterCriteria -> FacetCount
countUnder state criteria
  | needsOpen, not openIsCurrent = FacetCountUnknown
  | needsClosed, not historyIsCurrent = case state.appCompletedStatus of
      CompletedHistoryLoading -> FacetCountLoading loadedOfTotal
      CompletedHistoryPaused _ -> FacetCountLoading loadedOfTotal
      _ -> FacetCountUnknown
  | otherwise =
      FacetCountExact
        . boardEntryCount
        $ visibleBoardFor
          state.appConfig.resolvedWorkflow
          criteria
          state.appBoard
          state.appOpenSnapshot
          state.appCompletedHistory
  where
    needsOpen = LifecycleOpen `Set.member` criteria.filterLifecycle
    needsClosed = LifecycleClosed `Set.member` criteria.filterLifecycle
    openIsCurrent = isJust state.appLastSuccessfulFetch
    -- A complete history that no newer generation is chasing. While one is in
    -- flight the figure is reported as progress even though the history in
    -- memory is complete, because the number the user is about to act on is
    -- the one that generation will publish.
    historyIsCurrent = case state.appCompletedStatus of
      CompletedHistoryCurrent -> isJust state.appCompletedHistory
      CompletedHistoryStale _ -> isJust state.appCompletedHistory
      _ -> False
    progress = state.appCompletedProgress
    loadedOfTotal = do
      issues <- progress.completedIssuesTotal
      pullRequests <- progress.completedPullRequestsTotal
      pure (progress.completedIssuesLoaded + progress.completedPullRequestsLoaded, issues + pullRequests)

-- | A count as any checkbox but @Closed@ states it: a number, or the mark that
-- stands for one the data cannot support.
facetCountText :: FacetCount -> Text
facetCountText = \case
  FacetCountExact count -> showText count
  FacetCountLoading _ -> unknownCountText
  FacetCountUnknown -> unknownCountText

-- | A count as one checkbox states it.
--
-- @Closed@ is the one box whose own data is what a running traversal is
-- fetching, so it is where that traversal's loaded/total figure belongs. Every
-- other box would repeat the same pair — its count depends on the completed
-- generation only because @Closed@ is checked — so it shows the unknown mark
-- instead and the progress is stated once.
filterBoxCountText :: FilterBox -> FacetCount -> Text
filterBoxCountText box count = case (box, count) of
  (LifecycleBox LifecycleClosed, FacetCountLoading (Just (loaded, total))) ->
    showText loaded <> "/" <> showText total
  _ -> facetCountText count

-- | What a count that cannot be stated shows instead of a false zero.
unknownCountText :: Text
unknownCountText = "…"

-- | The five words §7 gives the completed generation, for the footer.
completedHistoryStatusText :: AppState -> Text
completedHistoryStatusText state = "history: " <> case state.appCompletedStatus of
  CompletedHistoryLoading -> "loading" <> loadedSuffix
  CompletedHistoryPaused _ -> "paused" <> loadedSuffix
  CompletedHistoryCurrent -> "current"
  CompletedHistoryStale _ -> "stale"
  CompletedHistoryFailed _ -> "failed"
  where
    progress = state.appCompletedProgress
    loadedSuffix = case (progress.completedIssuesTotal, progress.completedPullRequestsTotal) of
      (Just issues, Just pullRequests) ->
        " "
          <> showText (progress.completedIssuesLoaded + progress.completedPullRequestsLoaded)
          <> "/"
          <> showText (issues + pullRequests)
      _ -> ""

-- ---------------------------------------------------------------------------
-- What the card area draws
-- ---------------------------------------------------------------------------

-- | What the board's card area shows, decided from the criteria and the two
-- generations and from nothing else.
--
-- The open panels come first and only while the criteria ask for open work, so
-- the default criteria keep §7's loading and unavailable states exactly as they
-- are while a board showing only settled history is not held up by an open
-- generation nothing on it came from.
data CardSurface
  = -- | No complete open generation has published yet (§7).
    CardSurfaceLoadingOpen
  | -- | The first live open generation failed, with its classified reason.
    CardSurfaceUnavailableOpen Text
  | -- | @Closed@ is checked and the completed generation has not finished, so
    -- the whole area is a progress state: no open, completed, cached, or
    -- search-result card is drawn under it. Carries how far the traversal has
    -- got and, when it is paused, the instant it may resume at.
    CardSurfaceLoadingCompleted CompletedProgress (Maybe UTCTime)
  | -- | @Closed@ is checked and the completed generation failed with no
    -- complete history behind it, so there is no settled work to show at all.
    CardSurfaceUnavailableCompleted Text
  | CardSurfaceCards
  deriving stock (Eq, Show)

cardSurfaceFor :: AppState -> CardSurface
cardSurfaceFor state
  | admitsOpen, OpenDataLoading <- openView = CardSurfaceLoadingOpen
  | admitsOpen, OpenDataUnavailable reason <- openView = CardSurfaceUnavailableOpen reason
  | admitsClosed = case state.appCompletedStatus of
      CompletedHistoryLoading -> CardSurfaceLoadingCompleted state.appCompletedProgress Nothing
      CompletedHistoryPaused resetAt -> CardSurfaceLoadingCompleted state.appCompletedProgress (Just resetAt)
      -- A failed generation over a complete history keeps that history on
      -- screen with the footer marking it stale; only a failure with nothing
      -- behind it empties the area.
      CompletedHistoryFailed reason -> CardSurfaceUnavailableCompleted reason
      CompletedHistoryStale _ -> CardSurfaceCards
      CompletedHistoryCurrent -> CardSurfaceCards
  | otherwise = CardSurfaceCards
  where
    admitsOpen = LifecycleOpen `Set.member` state.appFilterCriteria.filterLifecycle
    admitsClosed = LifecycleClosed `Set.member` state.appFilterCriteria.filterLifecycle
    openView = openDataView state.appLastSuccessfulFetch state.appBoardFreshness

-- | Whether the completed criteria are standing between the user and the
-- cards. Every card target and card action is inert while this holds, however
-- stale the row a name or a remembered selection still points at.
completedCardsBlocked :: AppState -> Bool
completedCardsBlocked state = case cardSurfaceFor state of
  CardSurfaceLoadingCompleted _ _ -> True
  CardSurfaceUnavailableCompleted _ -> True
  CardSurfaceLoadingOpen -> False
  CardSurfaceUnavailableOpen _ -> False
  CardSurfaceCards -> False
