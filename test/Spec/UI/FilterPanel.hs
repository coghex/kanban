-- | The card filter panel: its checkbox inventory, the counts it predicts, the
-- keys and clicks that edit it, how it composes with the column search, and
-- the completed-history blocker a checked @Closed@ can put up.
--
-- Everything here is decided by a total function the @EventM@ arms only
-- project — 'filterInput' and 'applyFilterInput' for the keyboard,
-- 'boardMouseAction' and 'boardMousePress' for the mouse, 'facetCount' for the
-- figures, 'cardSurfaceFor' for what the card area draws, and
-- 'blockedByCompletedLoad' for what a blocked surface may still dispatch — so
-- the whole interaction is settled without a terminal, a network, or a GitHub
-- account (@docs\/design.md@ §18). What the panel /looks/ like at each width is
-- "Spec.UI.Golden"'s.
module Spec.UI.FilterPanel (spec) where

import Data.List (isInfixOf, nub)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Graphics.Vty as Vty
import Kanban.Domain
import Kanban.Filter
import Kanban.UI.Board
  ( boardFooterHintLine,
    boardHintLine,
    emptyColumnText,
    filterChipText,
    filterFooterHintLine,
    filterSummaryText,
    footerHintLine,
    searchFooterHintLine,
  )
import Kanban.UI.Events (BoardMouseAction (..), blockedByCompletedLoad, boardMouseAction, boardMousePress, mutatesSelectedWork)
import Kanban.UI.Filter
import Kanban.UI.Keys (BindingScope (..), BoardAction (..), boardAction)
import Kanban.UI.Search (SearchInput (..), applySearchInput, entriesFor, openSearch, searchInput)
import Kanban.UI.Selection (selectedItem)
import Kanban.UI.Types
import Kanban.UI.Util (allColumns, entriesForBoard, selectedRow)
import Kanban.Workflow (deriveBoard)
import Spec.Support.App (testAppState)
import Spec.Support.Fixtures (baseIssue, basePullRequest, epoch)
import Test.Hspec

spec :: Spec
spec = describe "card filter panel" $ do
  inventorySpec
  countSpec
  transitionSpec
  compositionSpec
  bindingSpec
  blockerSpec
  mouseSpec
  presentationSpec

-- ---------------------------------------------------------------------------
-- A repository with both generations in it
-- ---------------------------------------------------------------------------

-- | Two open issues, one approved, and one open pull request.
openSnapshot :: RepoSnapshot
openSnapshot =
  RepoSnapshot
    { snapshotIssues =
        [ baseIssue 1 [],
          (baseIssue 2 []) {issueLabels = [Label "reviewed:approve" "2f9e44"]}
        ],
      snapshotPullRequests = [basePullRequest 10 [] False []],
      snapshotFetchedAt = epoch
    }

-- | One closed issue and one merged pull request, disjoint from the open
-- generation exactly as a reconciled pair of generations is (§15).
completedHistory :: CompletedHistory
completedHistory =
  CompletedHistory
    { historyIssues = [(baseIssue 3 []) {issueState = IssueClosed}],
      historyPullRequests = [(basePullRequest 11 [] False []) {pullRequestState = PullRequestMerged}],
      historyFetchedAt = epoch
    }

openEntryCount, completedEntryCount :: Int
openEntryCount = length openSnapshot.snapshotIssues + length openSnapshot.snapshotPullRequests
completedEntryCount = length completedHistory.historyIssues + length completedHistory.historyPullRequests

-- | A board with both generations published and the default criteria in force,
-- which is the state every case below starts from.
panelState :: IO AppState
panelState = do
  base <- testAppState (deriveBoard defaultWorkflowConfig openSnapshot)
  pure
    . refreshVisibleBoard
    $ base
      { appOpenSnapshot = Just openSnapshot,
        appCompletedHistory = Just completedHistory,
        appCompletedStatus = CompletedHistoryCurrent
      }

-- | The same board with the panel showing and focused, as @f@ leaves it.
shownPanel :: IO AppState
shownPanel = toggleFilterPanel <$> panelState

-- | Check or uncheck boxes through the panel's own click transition.
withBoxes :: [FilterBox] -> AppState -> AppState
withBoxes boxes state = foldl (flip toggleFilterBoxFromClick) state boxes

-- | One key press decoded and applied the way dispatch does it.
press :: Vty.Event -> AppState -> AppState
press event state = case filterInput (focusedFilterPanel state) event of
  Just input -> applyFilterInput input state
  Nothing -> state

key :: Char -> Vty.Event
key character = Vty.EvKey (Vty.KChar character) []

-- ---------------------------------------------------------------------------
-- The inventory
-- ---------------------------------------------------------------------------

inventorySpec :: Spec
inventorySpec = describe "the checkbox inventory" $ do
  it "is the four groups' boxes, in group order, with nothing repeated" $ do
    everyFilterBox `shouldBe` concatMap filterGroupBoxes [minBound .. maxBound]
    length (nub everyFilterBox) `shouldBe` length everyFilterBox

  it "keeps every box in the group that offers it" $
    sequence_
      [ (group, map filterBoxGroup (filterGroupBoxes group)) `shouldBe` (group, map (const group) (filterGroupBoxes group))
      | group <- [minBound .. maxBound]
      ]

  it "names every group and every box" $ do
    map filterGroupLabel [minBound .. maxBound] `shouldBe` ["State", "Kind", "Workflow", "Structure"]
    map filterBoxLabel everyFilterBox
      `shouldBe` [ "Open",
                   "Closed",
                   "Issues",
                   "Pull requests",
                   "Changes",
                   "Problems",
                   "Approved",
                   "Other",
                   "Epic groups",
                   "Standalone"
                 ]

  -- §7: every value is checked at process start except Closed.
  it "starts with every box checked but Closed" $
    [box | box <- everyFilterBox, not (filterBoxChecked defaultFilterCriteria box)]
      `shouldBe` [LifecycleBox LifecycleClosed]

  it "flips only the box it is given, leaving every other value alone" $
    sequence_
      [ ( box,
          [ (other, filterBoxChecked (toggleFilterBox box defaultFilterCriteria) other)
          | other <- everyFilterBox,
            other /= box
          ]
        )
          `shouldBe` ( box,
                       [ (other, filterBoxChecked defaultFilterCriteria other)
                       | other <- everyFilterBox,
                         other /= box
                       ]
                     )
      | box <- everyFilterBox
      ]

  -- §7: a group with no value checked is a valid empty result, not a reset.
  it "lets a group be emptied rather than snapping back to every value" $ do
    let emptied = toggleFilterBox (KindBox KindPullRequests) (toggleFilterBox (KindBox KindIssues) defaultFilterCriteria)
    emptied.filterKind `shouldBe` Set.empty
    board <- (.appVisibleBoard) . applyCriteriaChange (const emptied) <$> panelState
    boardEntryCount board `shouldBe` 0

  it "makes a candidate the sole selection of its own facet and preserves the rest" $ do
    let narrowed = toggleFilterBox (KindBox KindPullRequests) defaultFilterCriteria
        candidate = restrictedToBox (LifecycleBox LifecycleClosed) narrowed
    candidate.filterLifecycle `shouldBe` Set.singleton LifecycleClosed
    (candidate.filterKind, candidate.filterWorkflow, candidate.filterStructure)
      `shouldBe` (narrowed.filterKind, narrowed.filterWorkflow, narrowed.filterStructure)

-- ---------------------------------------------------------------------------
-- Predictive counts
-- ---------------------------------------------------------------------------

countSpec :: Spec
countSpec = describe "predictive facet counts" $ do
  -- §7: a value's count answers what checking it would reveal, so it is
  -- computed with that value as its facet's only selection.
  it "counts what each lifecycle value alone would admit" $ do
    state <- panelState
    facetCount state (LifecycleBox LifecycleOpen) `shouldBe` FacetCountExact openEntryCount
    facetCount state (LifecycleBox LifecycleClosed) `shouldBe` FacetCountExact completedEntryCount

  it "ignores its own group's selection, so a neighbour's toggle cannot move it" $ do
    state <- panelState
    let openOff = withBoxes [LifecycleBox LifecycleOpen] state
    facetCount openOff (LifecycleBox LifecycleClosed) `shouldBe` facetCount state (LifecycleBox LifecycleClosed)
    facetCount openOff (LifecycleBox LifecycleOpen) `shouldBe` facetCount state (LifecycleBox LifecycleOpen)

  -- ...and does honor every other group's, which is the other half of the rule.
  it "counts under every other group's current selection" $ do
    state <- panelState
    facetCount state (KindBox KindIssues) `shouldBe` FacetCountExact (length openSnapshot.snapshotIssues)
    let withClosed = withBoxes [LifecycleBox LifecycleClosed] state
    facetCount withClosed (KindBox KindIssues)
      `shouldBe` FacetCountExact (length openSnapshot.snapshotIssues + length completedHistory.historyIssues)
    facetCount withClosed (KindBox KindPullRequests)
      `shouldBe` FacetCountExact (length openSnapshot.snapshotPullRequests + length completedHistory.historyPullRequests)

  it "adds up to the whole board across an exhaustive group" $ do
    state <- panelState
    let counted box = case facetCount state box of
          FacetCountExact count -> count
          other -> error ("expected an exact count, got " <> show other)
    sum (map counted (filterGroupBoxes KindGroup)) `shouldBe` openEntryCount
    sum (map counted (filterGroupBoxes WorkflowGroup)) `shouldBe` openEntryCount
    sum (map counted (filterGroupBoxes StructureGroup)) `shouldBe` openEntryCount

  -- §13: no count stands for more than it says. A figure that would depend on
  -- a generation still being traversed is progress, never a total.
  it "reports progress instead of a total while a completed generation runs" $ do
    state <- panelState
    let loading =
          state
            { appCompletedStatus = CompletedHistoryLoading,
              appCompletedProgress = CompletedProgress 4 (Just 9) 2 (Just 5)
            }
    facetCount loading (LifecycleBox LifecycleClosed) `shouldBe` FacetCountLoading (Just (6, 14))
    -- The open half is unaffected: it depends on no generation in flight.
    facetCount loading (LifecycleBox LifecycleOpen) `shouldBe` FacetCountExact openEntryCount
    -- A group whose current selection includes Closed inherits the doubt.
    facetCount (withBoxes [LifecycleBox LifecycleClosed] loading) (KindBox KindIssues)
      `shouldBe` FacetCountLoading (Just (6, 14))

  it "reports progress without a denominator before a page has reported one" $ do
    state <- panelState
    let starting = state {appCompletedStatus = CompletedHistoryLoading, appCompletedProgress = emptyCompletedProgress}
    facetCount starting (LifecycleBox LifecycleClosed) `shouldBe` FacetCountLoading Nothing

  it "keeps reporting progress while the traversal is paused" $ do
    state <- panelState
    let paused = state {appCompletedStatus = CompletedHistoryPaused epoch, appCompletedProgress = CompletedProgress 1 (Just 9) 0 (Just 5)}
    facetCount paused (LifecycleBox LifecycleClosed) `shouldBe` FacetCountLoading (Just (1, 14))

  it "says nothing rather than zero when a completed generation failed with no fallback" $ do
    state <- panelState
    let failed = state {appCompletedHistory = Nothing, appCompletedStatus = CompletedHistoryFailed "RATE LIMITED: slow down"}
    facetCount failed (LifecycleBox LifecycleClosed) `shouldBe` FacetCountUnknown

  -- A stale history is complete, only old, so the count over it is exact.
  it "counts a stale history exactly, because a stale one is still complete" $ do
    state <- panelState
    let stale = state {appCompletedStatus = CompletedHistoryStale "REQUEST ERROR: gh fell over"}
    facetCount stale (LifecycleBox LifecycleClosed) `shouldBe` FacetCountExact completedEntryCount

  it "says nothing about open work before the first open generation publishes" $ do
    state <- panelState
    let firstLoad = state {appLastSuccessfulFetch = Nothing, appBoardFreshness = Loading}
    facetCount firstLoad (LifecycleBox LifecycleOpen) `shouldBe` FacetCountUnknown
    facetCount firstLoad (KindBox KindIssues) `shouldBe` FacetCountUnknown
    -- The settled half is still known, and says so.
    facetCount firstLoad (LifecycleBox LifecycleClosed) `shouldBe` FacetCountExact completedEntryCount

  it "reports the filtered and raw figures the panel states" $ do
    state <- panelState
    filteredCount state `shouldBe` FacetCountExact openEntryCount
    rawEntryCount state `shouldBe` FacetCountExact (openEntryCount + completedEntryCount)
    filteredCount (withBoxes [LifecycleBox LifecycleOpen] state) `shouldBe` FacetCountExact 0

  -- Nothing is on screen under the blocker, so neither figure may claim one.
  it "claims no filtered figure while the completed blocker is up" $ do
    state <- panelState
    let blocked =
          withBoxes
            [LifecycleBox LifecycleClosed]
            state {appCompletedStatus = CompletedHistoryLoading, appCompletedProgress = CompletedProgress 4 (Just 9) 2 (Just 5)}
    completedCardsBlocked blocked `shouldBe` True
    filteredCount blocked `shouldBe` FacetCountLoading (Just (6, 14))
    filterSummaryText blocked `shouldBe` "showing … of … cards"

  it "puts the traversal's progress on the Closed box alone" $ do
    let progress = FacetCountLoading (Just (6, 14))
    filterBoxCountText (LifecycleBox LifecycleClosed) progress `shouldBe` "6/14"
    sequence_
      [ (box, filterBoxCountText box progress) `shouldBe` (box, "…")
      | box <- everyFilterBox,
        box /= LifecycleBox LifecycleClosed
      ]
    filterBoxCountText (LifecycleBox LifecycleClosed) (FacetCountExact 4) `shouldBe` "4"
    facetCountText FacetCountUnknown `shouldBe` "…"

  it "draws every chip with its box, its label, and its count" $ do
    state <- shownPanel
    filterChipText state (LifecycleBox LifecycleOpen) `shouldBe` "▌[x] Open " <> showCount openEntryCount
    filterChipText state (LifecycleBox LifecycleClosed) `shouldBe` " [ ] Closed " <> showCount completedEntryCount
  where
    showCount = Text.pack . show

-- ---------------------------------------------------------------------------
-- Transitions
-- ---------------------------------------------------------------------------

transitionSpec :: Spec
transitionSpec = describe "showing, hiding, and editing" $ do
  it "shows the panel focused on its first box and hides it again" $ do
    state <- panelState
    let shown = toggleFilterPanel state
        hidden = toggleFilterPanel shown
    filterPanelFocusedBox shown `shouldBe` Just (LifecycleBox LifecycleOpen)
    filterPanelFocusedBox hidden `shouldBe` Nothing
    hidden.appFilterPanel `shouldBe` Nothing

  -- §7: hiding leaves the criteria exactly as they are.
  it "leaves the criteria untouched by showing or hiding" $ do
    state <- panelState
    let edited = withBoxes [KindBox KindPullRequests] (toggleFilterPanel state)
        hidden = toggleFilterPanel edited
        shownAgain = toggleFilterPanel hidden
    map (.appFilterCriteria) [edited, hidden, shownAgain] `shouldBe` replicate 3 edited.appFilterCriteria
    hidden.appVisibleBoard `shouldBe` edited.appVisibleBoard
    criteriaAreFiltering hidden `shouldBe` True

  it "hides on Esc as well as on F" $ do
    shown <- shownPanel
    map (\event -> (press event shown).appFilterPanel) [key 'F', Vty.EvKey Vty.KEsc []]
      `shouldBe` [Nothing, Nothing]

  it "moves between boxes along the whole inventory, clamped at both ends" $ do
    shown <- shownPanel
    let focused = filterPanelFocusedBox . foldr (.) id (map press (reverse []))
    focused shown `shouldBe` Just (LifecycleBox LifecycleOpen)
    -- Down crosses the group boundary rather than stopping at it.
    filterPanelFocusedBox (press (key 'j') (press (key 'j') shown)) `shouldBe` Just (KindBox KindIssues)
    filterPanelFocusedBox (foldl (flip press) shown (replicate 3 (Vty.EvKey Vty.KDown [])))
      `shouldBe` Just (KindBox KindPullRequests)
    -- Clamped: up at the first box and down past the last both stay put.
    filterPanelFocusedBox (press (key 'k') shown) `shouldBe` Just (LifecycleBox LifecycleOpen)
    filterPanelFocusedBox (foldl (flip press) shown (replicate 40 (key 'j')))
      `shouldBe` Just (last everyFilterBox)

  it "moves between groups, keeping the option's position and clamping to a shorter group" $ do
    shown <- shownPanel
    let secondOfState = press (key 'j') shown
    filterPanelFocusedBox secondOfState `shouldBe` Just (LifecycleBox LifecycleClosed)
    -- Right keeps the second option of the next group.
    filterPanelFocusedBox (press (Vty.EvKey Vty.KRight []) secondOfState)
      `shouldBe` Just (KindBox KindPullRequests)
    -- A four-option group's fourth option clamps to a two-option group's last.
    let workflowLast = foldl (flip press) shown (replicate 7 (key 'j'))
    filterPanelFocusedBox workflowLast `shouldBe` Just (WorkflowBox WorkflowOther)
    filterPanelFocusedBox (press (Vty.EvKey Vty.KRight []) workflowLast)
      `shouldBe` Just (StructureBox StructureStandalone)
    -- Clamped at both ends, so a press at either edge changes nothing.
    filterPanelFocusedBox (press (Vty.EvKey Vty.KLeft []) shown) `shouldBe` Just (LifecycleBox LifecycleOpen)
    filterPanelFocusedBox (foldl (flip press) shown (replicate 9 (Vty.EvKey Vty.KRight [])))
      `shouldBe` Just (StructureBox StructureEpicGroups)

  it "toggles the focused box and changes the visible board at once" $ do
    shown <- shownPanel
    let closedOn = press (key ' ') (press (key 'j') shown)
    filterBoxChecked closedOn.appFilterCriteria (LifecycleBox LifecycleClosed) `shouldBe` True
    boardEntryCount closedOn.appVisibleBoard `shouldBe` openEntryCount + completedEntryCount
    -- And nothing about the board's data moved: only the view it admits.
    closedOn.appBoard `shouldBe` shown.appBoard

  it "restores the defaults with d, from any criteria" $ do
    shown <- shownPanel
    let scrambled = withBoxes [LifecycleBox LifecycleClosed, KindBox KindIssues, StructureBox StructureStandalone] shown
        restored = press (key 'd') scrambled
    criteriaAreFiltering scrambled `shouldBe` True
    restored.appFilterCriteria `shouldBe` defaultFilterCriteria
    criteriaAreFiltering restored `shouldBe` False
    restored.appVisibleBoard `shouldBe` shown.appVisibleBoard

  -- §7's process-lifetime rule, as far as a pure transition can state it: the
  -- criteria outlive the panel, an overlay, and a query.
  it "keeps the criteria across the panel, an overlay, and a search" $ do
    shown <- shownPanel
    let edited = withBoxes [KindBox KindPullRequests] shown
        survived =
          closeFilterPanel
            (openSearch edited {appOverlay = Just HelpOverlay})
    survived.appFilterCriteria `shouldBe` edited.appFilterCriteria
    boardEntryCount survived.appVisibleBoard `shouldBe` length openSnapshot.snapshotIssues

  -- §12 sorts the approved #2 above #1, so row 1 is the ordinary issue and
  -- row 0 the approved one. Both cases below read the selection by identity
  -- rather than by row, which is the property being stated.
  it "keeps the selected card selected across a criteria edit that moves its row" $ do
    shown <- shownPanel
    let selected = selectRow Issues 1 shown
        edited = withBoxes [WorkflowBox WorkflowApproved] selected
    fmap itemId (selectedItem selected) `shouldBe` Just (IssueId 1)
    -- Unchecking Approved hides #2, so #1 survives and moves up a row with
    -- the selection following it rather than the row number staying put.
    fmap itemId (selectedItem edited) `shouldBe` Just (IssueId 1)
    selectedRow edited Issues `shouldBe` 0

  it "falls back to the column's first selectable row when the criteria hide the selection" $ do
    shown <- shownPanel
    let selected = selectRow Issues 1 shown
        hidden = withBoxes [WorkflowBox WorkflowOther] selected
    -- #1 is the only WorkflowOther issue, so unchecking Other removes it.
    fmap itemId (selectedItem selected) `shouldBe` Just (IssueId 1)
    fmap itemId (selectedItem hidden) `shouldBe` Just (IssueId 2)
    selectedRow hidden Issues `shouldBe` 0

  it "leaves no column pointing past what it is showing" $ do
    shown <- shownPanel
    let emptied = withBoxes [KindBox KindIssues, KindBox KindPullRequests] shown
    sequence_
      [ (column, selectedRow emptied column) `shouldBe` (column, 0)
      | column <- allColumns
      ]
    sequence_
      [ (column, entriesFor emptied column) `shouldBe` (column, [])
      | column <- allColumns
      ]

selectRow :: BoardColumn -> Int -> AppState -> AppState
selectRow column row state =
  state {appSelectedColumn = column, appSelectedRows = Map.insert column row state.appSelectedRows}

-- ---------------------------------------------------------------------------
-- Composition with the column search
-- ---------------------------------------------------------------------------

compositionSpec :: Spec
compositionSpec = describe "composing with the column search" $ do
  it "gives the panel the keyboard ahead of a live search" $ do
    shown <- shownPanel
    let both = openSearch shown
    focusedFilterPanel both `shouldNotBe` Nothing
    focusedSearch both `shouldBe` Nothing

  -- §7: `s` from the panel focuses search, and lowercase `f` from search
  -- focuses the panel without clearing the query.
  it "hands the keyboard to search on s and takes it back on f" $ do
    shown <- shownPanel
    let searching = press (key 's') shown
        typed = applySearchInput (SearchInsert 'x') searching
        back = focusFilterPanel typed
    (.searchQuery) <$> searching.appSearch `shouldBe` Just ""
    focusedSearch typed `shouldNotBe` Nothing
    focusedFilterPanel typed `shouldBe` Nothing
    (.searchQuery) <$> back.appSearch `shouldBe` Just "x"
    focusedFilterPanel back `shouldNotBe` Nothing
    focusedSearch back `shouldBe` Nothing

  it "keeps the panel on screen while search holds the keyboard" $ do
    shown <- shownPanel
    (press (key 's') shown).appFilterPanel `shouldNotBe` Nothing

  it "opens a search when s is pressed with none live, and reuses one that is" $ do
    shown <- shownPanel
    let opened = press (key 's') shown
        moved = press (key 's') (focusFilterPanel (applySearchInput (SearchInsert 'x') opened))
    (.searchColumn) <$> opened.appSearch `shouldBe` Just Issues
    -- The second press hands focus back rather than restarting the query.
    (.searchQuery) <$> moved.appSearch `shouldBe` Just "x"

  -- The panel takes focus back on its own, so no close path has to know it is
  -- underneath.
  it "takes the keyboard back when the search it yielded to ends" $ do
    shown <- shownPanel
    let searching = press (key 's') shown
        closed = applySearchInput SearchClose searching
    focusedFilterPanel searching `shouldBe` Nothing
    closed.appSearch `shouldBe` Nothing
    filterPanelFocusedBox closed `shouldBe` Just (LifecycleBox LifecycleOpen)

  it "narrows the filtered set with the query rather than replacing it" $ do
    shown <- shownPanel
    let closedOn = withBoxes [LifecycleBox LifecycleClosed] shown
        searching = applySearchInput (SearchInsert '3') (openSearch closedOn)
    -- Closed admits #3 into Issues, and the query then narrows to it alone.
    map itemNumberOf (entriesFor searching Issues) `shouldBe` [3]
    map itemNumberOf (entriesForBoard searching.appVisibleBoard Issues) `shouldBe` [2, 1, 3]

itemNumberOf :: ColumnEntry -> Int
itemNumberOf entry = case entry of
  Standalone item -> numberOfItem item
  Tracked _ item -> numberOfItem item
  TrackerHeader tracker -> tracker.trackerIssue.issueNumber
  where
    numberOfItem (IssueItem issue) = issue.issueNumber
    numberOfItem (PullRequestItem pullRequest) = pullRequest.pullRequestNumber

-- ---------------------------------------------------------------------------
-- Bindings
-- ---------------------------------------------------------------------------

bindingSpec :: Spec
bindingSpec = describe "bindings" $ do
  it "reaches the panel from the board's own F" $
    boardAction BoardScope (key 'F') `shouldBe` Just ShowFilter

  it "decodes every key the panel answers" $ do
    shown <- shownPanel
    let decoded event = filterInput (focusedFilterPanel shown) event
    sequence_
      [ (event, decoded event) `shouldBe` (event, Just expected)
      | (event, expected) <-
          [ (key 'j', FilterMoveBox 1),
            (key 'k', FilterMoveBox (-1)),
            (Vty.EvKey Vty.KDown [], FilterMoveBox 1),
            (Vty.EvKey Vty.KUp [], FilterMoveBox (-1)),
            (Vty.EvKey Vty.KLeft [], FilterMoveGroup (-1)),
            (Vty.EvKey Vty.KRight [], FilterMoveGroup 1),
            (key ' ', FilterToggleBox),
            (key 'd', FilterRestoreDefaults),
            (key 'F', FilterHide),
            (Vty.EvKey Vty.KEsc [], FilterHide),
            (key 's', FilterFocusSearch)
          ]
      ]

  -- §7: scoped `q` and Ctrl-C quit behavior is unchanged, and every other
  -- board binding the panel does not claim still fires.
  it "declines the keys the board keeps" $ do
    shown <- shownPanel
    let decoded event = filterInput (focusedFilterPanel shown) event
    sequence_
      [ (event, decoded event) `shouldBe` (event, Nothing)
      | event <-
          [ key 'q',
            key 'u',
            key '?',
            key 'r',
            Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl],
            Vty.EvKey (Vty.KChar 'l') [Vty.MCtrl],
            Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl],
            Vty.EvKey (Vty.KChar 'F') [Vty.MAlt]
          ]
      ]
    -- ...and each of those still resolves to the board action it always did.
    boardAction BoardScope (key 'q') `shouldBe` Just QuitDashboard
    boardAction BoardScope (Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl]) `shouldBe` Just QuitDashboard
    boardAction BoardScope (key '?') `shouldBe` Just ShowHelp

  -- Requirement 5: lowercase `f` is left deliberately unbound rather than
  -- reassigned, so it decodes to nothing on the board and nothing in a focused
  -- panel until #512's fullscreen slice claims it.
  it "leaves lowercase f unbound on the board and in a focused panel" $ do
    shown <- shownPanel
    boardAction BoardScope (key 'f') `shouldBe` Nothing
    filterInput (focusedFilterPanel shown) (key 'f') `shouldBe` Nothing

  it "decodes nothing at all while the panel is hidden or unfocused" $ do
    state <- panelState
    filterInput (focusedFilterPanel state) (key ' ') `shouldBe` Nothing
    shown <- shownPanel
    filterInput (focusedFilterPanel (press (key 's') shown)) (key ' ') `shouldBe` Nothing

  -- §7: uppercase `F` moves the keyboard; lowercase `f` is text.
  it "claims uppercase F from a search box and leaves lowercase f as text" $ do
    let live = Just (ColumnSearch Issues "")
    searchInput live (key 'F') `shouldBe` Just SearchFocusFilter
    searchInput live (key 'f') `shouldBe` Just (SearchInsert 'f')
    searchInput live (key 's') `shouldBe` Just SearchClose
    searchInput live (key 'q') `shouldBe` Nothing

  it "types a lowercase f into the query it is pressed in" $ do
    shown <- shownPanel
    let typed = applySearchInput (SearchInsert 'f') (press (key 's') shown)
    (.searchQuery) <$> typed.appSearch `shouldBe` Just "f"

-- ---------------------------------------------------------------------------
-- The completed-history blocker
-- ---------------------------------------------------------------------------

blockerSpec :: Spec
blockerSpec = describe "the completed-history blocker" $ do
  it "draws cards under the default criteria whatever the completed generation is doing" $ do
    state <- panelState
    sequence_
      [ (status, cardSurfaceFor state {appCompletedStatus = status}) `shouldBe` (status, CardSurfaceCards)
      | status <-
          [ CompletedHistoryLoading,
            CompletedHistoryPaused epoch,
            CompletedHistoryCurrent,
            CompletedHistoryStale "stale",
            CompletedHistoryFailed "failed"
          ]
      ]

  it "keeps §7's open panels for criteria that ask for open work" $ do
    state <- panelState
    let firstLoad = state {appLastSuccessfulFetch = Nothing, appBoardFreshness = Loading}
        firstFailure = state {appLastSuccessfulFetch = Nothing, appBoardFreshness = Unavailable "AUTH REQUIRED: nope"}
    cardSurfaceFor firstLoad `shouldBe` CardSurfaceLoadingOpen
    cardSurfaceFor firstFailure `shouldBe` CardSurfaceUnavailableOpen "AUTH REQUIRED: nope"

  -- §7 makes the completed blocker unconditional, so it outranks the open
  -- panels: on a fresh launch both generations are running and Open is still
  -- checked, and checking Closed there must report what was just asked for
  -- rather than leaving the criteria's own state unreported — and leaving
  -- every card action ungated with it.
  it "answers the checked Closed box before the open generation, with Open still checked" $ do
    state <- panelState
    let freshLaunch = state {appLastSuccessfulFetch = Nothing, appBoardFreshness = Loading}
        progress = CompletedProgress 4 (Just 9) 2 (Just 5)
        loading = withBoxes [LifecycleBox LifecycleClosed] freshLaunch {appCompletedStatus = CompletedHistoryLoading, appCompletedProgress = progress}
        paused = loading {appCompletedStatus = CompletedHistoryPaused epoch}
        failed = loading {appCompletedHistory = Nothing, appCompletedStatus = CompletedHistoryFailed "RATE LIMITED: slow down"}
    filterBoxChecked loading.appFilterCriteria (LifecycleBox LifecycleOpen) `shouldBe` True
    cardSurfaceFor loading `shouldBe` CardSurfaceLoadingCompleted progress Nothing
    cardSurfaceFor paused `shouldBe` CardSurfaceLoadingCompleted progress (Just epoch)
    cardSurfaceFor failed `shouldBe` CardSurfaceUnavailableCompleted "RATE LIMITED: slow down"
    -- ...so the card-action protection is live in that window too.
    map completedCardsBlocked [loading, paused, failed] `shouldBe` [True, True, True]
    -- The open panel is still what an unfinished open generation shows once
    -- the completed one has settled.
    cardSurfaceFor (withBoxes [LifecycleBox LifecycleClosed] freshLaunch) `shouldBe` CardSurfaceLoadingOpen

  -- With Open unchecked no card on the board came from the open generation, so
  -- its panel is not what a settled-history board waits behind.
  it "does not hold a completed-only board behind the open panel" $ do
    state <- panelState
    let settled = withBoxes [LifecycleBox LifecycleOpen, LifecycleBox LifecycleClosed] state {appLastSuccessfulFetch = Nothing, appBoardFreshness = Loading}
    cardSurfaceFor settled `shouldBe` CardSurfaceCards
    boardEntryCount settled.appVisibleBoard `shouldBe` completedEntryCount

  it "replaces the card area while Closed is checked over a running generation" $ do
    state <- panelState
    let progress = CompletedProgress 4 (Just 9) 2 (Just 5)
        loading = withBoxes [LifecycleBox LifecycleClosed] state {appCompletedStatus = CompletedHistoryLoading, appCompletedProgress = progress}
        paused = loading {appCompletedStatus = CompletedHistoryPaused epoch}
    cardSurfaceFor loading `shouldBe` CardSurfaceLoadingCompleted progress Nothing
    cardSurfaceFor paused `shouldBe` CardSurfaceLoadingCompleted progress (Just epoch)

  -- §7: unchecking Closed returns to the open interface immediately, and
  -- checking it again restores the blocker.
  it "leaves and restores the blocker as Closed is unchecked and checked" $ do
    state <- panelState
    let loading = state {appCompletedStatus = CompletedHistoryLoading}
        blocked = withBoxes [LifecycleBox LifecycleClosed] loading
        released = withBoxes [LifecycleBox LifecycleClosed] blocked
        restored = withBoxes [LifecycleBox LifecycleClosed] released
    map completedCardsBlocked [blocked, released, restored] `shouldBe` [True, False, True]
    -- The open board is back untouched the instant the box clears, and the
    -- history in memory is exactly where it was: nothing cancelled a load.
    released.appVisibleBoard `shouldBe` state.appVisibleBoard
    map (.appCompletedHistory) [blocked, released, restored] `shouldBe` replicate 3 state.appCompletedHistory

  -- The reviewer's correction: a generation that /fails/ ends the blocker too.
  it "ends the blocker on failure, keeping a complete history as stale" $ do
    state <- panelState
    let stale = withBoxes [LifecycleBox LifecycleClosed] state {appCompletedStatus = CompletedHistoryStale "REQUEST ERROR: gh fell over"}
    cardSurfaceFor stale `shouldBe` CardSurfaceCards
    boardEntryCount stale.appVisibleBoard `shouldBe` openEntryCount + completedEntryCount

  it "shows a card-free failure state when no complete history stands behind it" $ do
    state <- panelState
    let failed =
          withBoxes
            [LifecycleBox LifecycleClosed]
            state {appCompletedHistory = Nothing, appCompletedStatus = CompletedHistoryFailed "RATE LIMITED: slow down"}
    cardSurfaceFor failed `shouldBe` CardSurfaceUnavailableCompleted "RATE LIMITED: slow down"
    completedCardsBlocked failed `shouldBe` True

  -- Requirement 9 and the reviewer's clarification: every card key is inert
  -- under the blocker, and everything else stays exactly as usable.
  it "makes every card action inert and leaves the rest alone" $ do
    map blockedByCompletedLoad [NextCard, PreviousCard, PreviousColumn, NextColumn, FirstItem, LastItem]
      `shouldBe` replicate 6 True
    map blockedByCompletedLoad [OpenSearch, ToggleEpic, ShowDetails]
      `shouldBe` replicate 3 True
    map blockedByCompletedLoad [ReviewSelection, SolveSelection, AutoSolveSelection, MergeDoneCard, KillWorking]
      `shouldBe` replicate 5 True
    map blockedByCompletedLoad [ShowFilter, DismissOrClose, ShowHelp, ShowSettings, RefreshAll, ToggleDrainer, ToggleSidebar, ShowProcesses, ShowIncidents, RepaintTerminal, QuitDashboard]
      `shouldBe` replicate 11 False

  -- No column is drawn under the blocker, so there is no box to type into and
  -- none to open. The query itself survives and comes back with the columns.
  it "gives the keyboard to neither an open search nor a new one under the blocker" $ do
    state <- panelState
    let typed = applySearchInput (SearchInsert 'x') (openSearch state)
        blocked = withBoxes [LifecycleBox LifecycleClosed] (toggleFilterPanel typed {appCompletedStatus = CompletedHistoryLoading})
        pressedS = press (key 's') blocked
        released = withBoxes [LifecycleBox LifecycleClosed] pressedS
    focusedSearch blocked `shouldBe` Nothing
    -- `s` from the focused panel opens nothing while nothing is drawn.
    pressedS.appFilterPanel `shouldBe` blocked.appFilterPanel
    focusedFilterPanel pressedS `shouldNotBe` Nothing
    -- And the query is exactly where it was once the blocker lifts, reachable
    -- again through the same `s` that was inert under it.
    (.searchQuery) <$> released.appSearch `shouldBe` Just "x"
    focusedSearch (press (key 's') released) `shouldBe` released.appSearch
    (.searchQuery) <$> (press (key 's') released).appSearch `shouldBe` Just "x"

  -- A visible panel is never keyboard-dead. The blocker takes the search out
  -- of reach, so the panel it yielded to takes focus back: without that,
  -- checking Closed while search held the keyboard would leave the very box
  -- that put the blocker up unable to take it down, and `d` would fall
  -- through to the drainer binding.
  it "returns the keyboard to a yielded panel when the blocker suppresses its search" $ do
    state <- panelState
    let searching = press (key 's') (toggleFilterPanel state {appCompletedStatus = CompletedHistoryLoading})
        -- Exactly the reachable route: a click edits the criteria without
        -- taking the keyboard from the query.
        blocked = boardMousePress (ToggleFilterBoxFromClick (LifecycleBox LifecycleClosed)) searching
    focusedFilterPanel searching `shouldBe` Nothing
    completedCardsBlocked blocked `shouldBe` True
    focusedFilterPanel blocked `shouldNotBe` Nothing
    focusedSearch blocked `shouldBe` Nothing
    -- Space still takes the blocker down, and `d` is the panel's defaults
    -- rather than the board's drainer.
    filterInput (focusedFilterPanel blocked) (key 'd') `shouldBe` Just FilterRestoreDefaults
    completedCardsBlocked (press (key ' ') blocked) `shouldBe` False
    -- ...and the search gets the keyboard back the moment the blocker lifts.
    focusedSearch (press (key ' ') blocked) `shouldNotBe` Nothing

  it "blocks exactly the actions that reach a card" $
    -- Stated as a partition over the whole table, so a binding added later
    -- has to be classified rather than defaulting into either half.
    length [action | action <- [minBound .. maxBound], blockedByCompletedLoad action]
      + length [action | action <- [minBound .. maxBound], not (blockedByCompletedLoad action)]
      `shouldBe` length ([minBound .. maxBound] :: [BoardAction])

-- ---------------------------------------------------------------------------
-- Mouse
-- ---------------------------------------------------------------------------

mouseSpec :: Spec
mouseSpec = describe "mouse" $ do
  it "toggles the box a click names and moves the panel's focus to it" $ do
    shown <- shownPanel
    let target = FilterBoxTarget (WorkflowBox WorkflowApproved)
        action = boardMouseAction shown target Vty.BLeft []
        clicked = boardMousePress (ToggleFilterBoxFromClick (WorkflowBox WorkflowApproved)) shown
    action `shouldBe` Just (ToggleFilterBoxFromClick (WorkflowBox WorkflowApproved))
    filterBoxChecked clicked.appFilterCriteria (WorkflowBox WorkflowApproved) `shouldBe` False
    filterPanelFocusedBox clicked `shouldBe` Just (WorkflowBox WorkflowApproved)
    -- #2 is the approved issue, and the click removed it from the view.
    map itemNumberOf (entriesFor clicked Issues) `shouldBe` [1]

  it "leaves the keyboard where it was when a click edits the criteria" $ do
    shown <- shownPanel
    let searching = press (key 's') shown
        clicked = boardMousePress (ToggleFilterBoxFromClick (KindBox KindIssues)) searching
    focusedSearch clicked `shouldNotBe` Nothing
    filterPanelFocusedBox clicked `shouldBe` Nothing

  it "still resolves card, epic, and column targets with both filter and search live" $ do
    shown <- shownPanel
    let both = openSearch (withBoxes [KindBox KindPullRequests] shown)
    boardMouseAction both (CardTarget Issues 0) Vty.BLeft [] `shouldBe` Just (SelectOrOpenCardAt Issues 0)
    boardMouseAction both (EpicTarget Issues 0 7) Vty.BLeft [] `shouldBe` Just (ToggleEpicFromClick Issues 0 7)
    boardMouseAction both (ColumnViewport Issues) Vty.BScrollDown [] `shouldBe` Just (ScrollColumnBy Issues 3)
    -- A press in another column is still the search transfer §7 defines.
    boardMouseAction both (CardTarget Active 0) Vty.BLeft [] `shouldBe` Just (TransferSearch Active)

  -- The reviewer's clarification: a stale card name must resolve to no work.
  it "answers nothing for a card, epic, or column target under the blocker" $ do
    state <- panelState
    let blocked = withBoxes [LifecycleBox LifecycleClosed] (toggleFilterPanel state {appCompletedStatus = CompletedHistoryLoading})
    sequence_
      [ (name, boardMouseAction blocked name button []) `shouldBe` (name, Nothing)
      | (name, button) <-
          [ (CardTarget Issues 0, Vty.BLeft),
            (CardTarget Issues 4, Vty.BRight),
            (CardTarget Done 2, Vty.BScrollDown),
            (EpicTarget Issues 0 7, Vty.BLeft),
            (ColumnViewport Active, Vty.BScrollUp)
          ]
      ]
    -- The things drawn through the blocker still answer: the panel that put it
    -- up, and all three sidebar controls, none of which is a card target.
    boardMouseAction blocked (FilterBoxTarget (LifecycleBox LifecycleClosed)) Vty.BLeft []
      `shouldBe` Just (ToggleFilterBoxFromClick (LifecycleBox LifecycleClosed))
    boardMouseAction blocked DrainerButton Vty.BLeft [] `shouldBe` Just ToggleDrainerFromClick
    boardMouseAction blocked ApprovalButton Vty.BLeft [] `shouldBe` Just ToggleApprovalFromClick
    boardMouseAction blocked UpdateButton Vty.BLeft [] `shouldBe` Just RefreshAllFromClick
    -- And the key path the click shares its action with is not blocked either.
    blockedByCompletedLoad ToggleApproval `shouldBe` False
    mutatesSelectedWork ToggleApproval `shouldBe` False

-- ---------------------------------------------------------------------------
-- What the board says about the criteria
-- ---------------------------------------------------------------------------

presentationSpec :: Spec
presentationSpec = describe "what the board says about the criteria" $ do
  -- §7's three distinct empty rows, in their declared precedence.
  it "names why a column is empty, and never confuses the three reasons" $ do
    shown <- shownPanel
    emptyColumnText shown Active `shouldBe` "No items"
    let filtered = withBoxes [KindBox KindIssues, KindBox KindPullRequests] shown
    emptyColumnText filtered Issues `shouldBe` "No filter matches"
    let searched = applySearchInput (SearchInsert 'z') (openSearch shown)
    emptyColumnText searched Issues `shouldBe` "No search matches"
    -- Filtering to zero wins over a live query, because search had nothing to
    -- narrow.
    let both = applySearchInput (SearchInsert 'z') (openSearch filtered)
    emptyColumnText both Issues `shouldBe` "No filter matches"

  -- Each column answers for itself. A criteria set that empties Issues says
  -- nothing about a column that had nothing in it to begin with, and calling
  -- that one filtered would blame the filter for the repository's own shape.
  it "keeps No items for a column that was already empty under the defaults" $ do
    shown <- shownPanel
    -- Unchecking Approved removes #2 from Issues and touches nothing else.
    let filtered = withBoxes [WorkflowBox WorkflowApproved] shown
    criteriaAreFiltering filtered `shouldBe` True
    null (entriesForBoard filtered.appBoard Active) `shouldBe` True
    emptyColumnText filtered Active `shouldBe` "No items"
    emptyColumnText filtered Done `shouldBe` "No items"
    -- ...while the column the criteria actually emptied still says so.
    let emptied = withBoxes [KindBox KindIssues] shown
    null (entriesForBoard emptied.appBoard Issues) `shouldBe` False
    emptyColumnText emptied Issues `shouldBe` "No filter matches"

  it "marks the footer chip only while the criteria are hiding cards" $ do
    boardFooterHintLine False `shouldBe` footerHintLine
    ("F filter*" `Text.isInfixOf` boardFooterHintLine True) `shouldBe` True
    ("F filter*" `Text.isInfixOf` footerHintLine) `shouldBe` False
    -- One chip marked, and the line's inventory otherwise unchanged.
    length (Text.splitOn "  " (boardFooterHintLine True))
      `shouldBe` length (Text.splitOn "  " footerHintLine)

  it "shows each surface its own hint line" $ do
    state <- panelState
    shown <- shownPanel
    boardHintLine state `shouldBe` footerHintLine
    boardHintLine shown `shouldBe` filterFooterHintLine
    boardHintLine (press (key 's') shown) `shouldBe` searchFooterHintLine
    boardHintLine (withBoxes [KindBox KindIssues] state) `shouldBe` boardFooterHintLine True

  it "names none of the board's own column keys on the panel's line" $
    sequence_
      [ (fragment, fragment `Text.isInfixOf` filterFooterHintLine) `shouldBe` (fragment, True)
      | fragment <- ["j/k", "←/→ group", "space toggle", "d defaults", "s search", "F/esc close"]
      ]

  -- Requirement 8: the five words, off a state rather than off a notice.
  it "states where the completed generation stands, whatever cleared the notice" $ do
    state <- panelState
    let saying status = completedHistoryStatusText state {appCompletedStatus = status, appNotice = Nothing}
    map
      saying
      [ CompletedHistoryLoading,
        CompletedHistoryPaused epoch,
        CompletedHistoryCurrent,
        CompletedHistoryStale "why",
        CompletedHistoryFailed "why"
      ]
      `shouldBe` ["history: loading", "history: paused", "history: current", "history: stale", "history: failed"]

  it "adds the traversal's own figures once a page has reported them" $ do
    state <- panelState
    let counted =
          state
            { appCompletedStatus = CompletedHistoryLoading,
              appCompletedProgress = CompletedProgress 4 (Just 9) 2 (Just 5)
            }
    completedHistoryStatusText counted `shouldBe` "history: loading 6/14"

  it "states the panel's own two figures" $ do
    shown <- shownPanel
    filterSummaryText shown
      `shouldBe` Text.pack ("showing " <> show openEntryCount <> " of " <> show (openEntryCount + completedEntryCount) <> " cards")
    ("of …" `isInfixOf` Text.unpack (filterSummaryText shown {appCompletedHistory = Nothing, appCompletedStatus = CompletedHistoryFailed "x"}))
      `shouldBe` True
