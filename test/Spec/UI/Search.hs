-- | The live column-scoped card search: what matches, what one key press
-- does, and — above all — that everything reading a column reads the same
-- filtered view.
--
-- A rendered row is a raw index into a column's entry list, so filtering only
-- what is drawn would let a visible card invoke an action on a different
-- underlying entry. The property at the bottom of the matching group is that
-- claim stated directly: at every query, every row the user can select
-- resolves to the entry the renderer drew there.
--
-- Nothing here needs a terminal or an @EventM@. Search's key decoder, its
-- query edits, its selection reconciliation, its move to another column, and
-- every mouse decision are all pure functions, which is what lets the whole
-- interaction be covered (docs\/design.md §18). Dispatch is a projection of
-- them: 'boardMouseAction' decides what a press means and 'boardMousePress'
-- is the whole of what dispatch then does with the decision, so the mouse
-- group can take a press rather than assert about the arm that would.
module Spec.UI.Search (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Graphics.Vty as Vty
import Kanban.Domain
import Kanban.Drainer (DrainerBackend (..), DrainerController (..), DrainerState (..), DrainerStatus (..))
import Kanban.Workflow (entryItem)
import Kanban.UI.Events (BoardMouseAction (..), applyCardClick, applyRunningProcessClick, boardMouseAction, boardMousePress)
import Kanban.UI.Filter (refreshVisibleBoard)
import Kanban.UI.Keys (BindingScope (..), BoardAction (..), boardAction)
import Kanban.UI.Search
import Kanban.UI.Selection (openSearchResult, selectedEntry)
import Kanban.UI.Types
import Kanban.UI.Util (entriesForBoard, safeIndex, selectedRow)
import Spec.Support.App (testAppState, withReviewSession)
import Spec.Support.Fixtures (baseIssue)
import Test.Hspec

spec :: Spec
spec = describe "column card search" $ do
  matchingSpec
  viewSpec
  transitionSpec
  transferSpec
  precedenceSpec
  mouseSpec

-- ---------------------------------------------------------------------------
-- A board with something of every shape in Issues
-- ---------------------------------------------------------------------------

-- | An issue with a title worth matching against.
titledIssue :: Int -> Text -> Issue
titledIssue number title = (baseIssue number []) {issueTitle = title}

titledTracker :: Int -> Text -> Tracker
titledTracker number title = Tracker (titledIssue number title) ChecklistMembership 0 0 Map.empty []

trackedChild :: Int -> Text -> Int -> Text -> ColumnEntry
trackedChild trackerNumber trackerTitle childNumber childTitle =
  Tracked
    (TrackingContext (TrackerMembership (titledTracker trackerNumber trackerTitle) (TrackerChild childNumber Nothing 0 False)) [])
    (IssueItem (titledIssue childNumber childTitle))

standaloneCard :: Int -> Text -> ColumnEntry
standaloneCard number title = Standalone (IssueItem (titledIssue number title))

-- | Issues, in board order: an epic with two children, a childless epic
-- header, and two standalone cards.
issuesEntries :: [ColumnEntry]
issuesEntries =
  [ trackedChild 700 "Persistence contract rollout" 711 "Adopt the versioned save envelope",
    trackedChild 700 "Persistence contract rollout" 712 "Migrate the terrain cache reader",
    TrackerHeader (titledTracker 705 "Pointer capture hardening"),
    standaloneCard 901 "Add repository snapshot cache",
    standaloneCard 812 "Modal input leaks through overlay"
  ]

-- | Active, in board order: a standalone card and an epic with one child, left
-- collapsed. A transfer into this column therefore has a card, an epic header,
-- and whitespace to land on, and a remembered row that is not its first.
activeEntries :: [ColumnEntry]
activeEntries =
  [ standaloneCard 799 "Repair stale world cache invalidation",
    trackedChild 706 "Session recovery hardening" 731 "Reattach an orphaned worker"
  ]

-- | A column whose collapsed tracker group sits below a standalone card, so
-- the first selectable row, the row above a collapsed-away anchor, and the
-- group's own row are all different rows.
laterGroupEntries :: [ColumnEntry]
laterGroupEntries =
  [ standaloneCard 901 "Add repository snapshot cache",
    trackedChild 700 "Persistence contract rollout" 711 "Adopt the versioned save envelope",
    trackedChild 700 "Persistence contract rollout" 712 "Migrate the terrain cache reader"
  ]

laterGroupBoard :: Board
laterGroupBoard = issuesBoard laterGroupEntries

-- | The same column with one child gone, as a refresh would leave it.
laterGroupBoardWithout :: Int -> Board
laterGroupBoardWithout number = issuesBoard (filter ((/= Just number) . entryNumber) laterGroupEntries)

issuesBoard :: [ColumnEntry] -> Board
issuesBoard entries = Board (Map.fromList ([(column, []) | column <- [minBound .. maxBound]] <> [(Issues, entries)]))

searchBoard :: Board
searchBoard =
  Board
    ( Map.fromList
        ( [(column, []) | column <- [minBound .. maxBound]]
            <> [(Issues, issuesEntries), (Active, activeEntries)]
        )
    )

-- | The board state every case starts from: nothing searching, epic 700
-- expanded and epic 705 left collapsed, and the first Issues row selected.
searchState :: IO AppState
searchState = do
  state <- testAppState searchBoard
  pure state {appExpandedTrackers = Set.singleton 700}

-- | The state with a query already typed, reached the way a user reaches it:
-- open search, then insert each character in turn.
searchingFor :: Text -> IO AppState
searchingFor query = do
  state <- searchState
  pure (Text.foldl' (\current character -> applySearchInput (SearchInsert character) current) (openSearch state) query)

-- | What the Issues column shows, as the identity text of each visible row.
visibleIdentities :: AppState -> [Text]
visibleIdentities state = map entryIdentityText (entriesFor state Issues)

liveSearch :: Maybe ColumnSearch
liveSearch = Just (ColumnSearch Issues "env")

-- ---------------------------------------------------------------------------

matchingSpec :: Spec
matchingSpec = describe "matching" $ do
  it "keeps a column complete under an empty query, and under one that is only whitespace" $ do
    state <- searchState
    filterEntries "" issuesEntries `shouldBe` issuesEntries
    filterEntries "   " issuesEntries `shouldBe` issuesEntries
    visibleIdentities (openSearch state) `shouldBe` map entryIdentityText issuesEntries

  it "folds case in both directions" $ do
    -- An all-caps query against a lower-case title, and a lower-case query
    -- against the capital the title actually carries.
    shouted <- searchingFor "ENVELOPE"
    quiet <- searchingFor "envelope"
    lowered <- searchingFor "adopt the versioned"
    raised <- searchingFor "Adopt The Versioned"
    visibleIdentities shouted `shouldBe` ["#711  Adopt the versioned save envelope"]
    visibleIdentities quiet `shouldBe` visibleIdentities shouted
    visibleIdentities lowered `shouldBe` visibleIdentities shouted
    visibleIdentities raised `shouldBe` visibleIdentities shouted

  it "matches on the number alone and on the title alone" $ do
    byNumber <- searchingFor "#901"
    byTitle <- searchingFor "snapshot cache"
    visibleIdentities byNumber `shouldBe` ["#901  Add repository snapshot cache"]
    visibleIdentities byTitle `shouldBe` ["#901  Add repository snapshot cache"]

  it "normalizes runs of whitespace on both sides of the match" $ do
    spaced <- searchingFor "save   envelope"
    visibleIdentities spaced `shouldBe` ["#711  Adopt the versioned save envelope"]

  it "reads only the identity, never the body, labels, assignees, or status" $ do
    -- The fixture issue bodies are all "Body"; a card would match on it if
    -- anything but '#number' and title reached the comparison.
    body <- searchingFor "Body"
    visibleIdentities body `shouldBe` []

  it "shows a distinct empty view for a query nothing matches" $ do
    missing <- searchingFor "no such card anywhere"
    entriesFor missing Issues `shouldBe` []
    selectableRows missing Issues `shouldBe` []

  it "keeps a tracker header when its own identity matches, without leaking a nonmatching child" $ do
    ownMatch <- searchingFor "Persistence contract"
    visibleIdentities ownMatch `shouldBe` ["#700  Persistence contract rollout"]
    entriesFor ownMatch Issues `shouldSatisfy` all isTrackerHeader

  it "keeps a tracker header when only a child matches, and shows only the children that match" $ do
    childMatch <- searchingFor "terrain"
    visibleIdentities childMatch `shouldBe` ["#712  Migrate the terrain cache reader"]
    entriesFor childMatch Issues `shouldSatisfy` all (not . isTrackerHeader)

  it "keeps a childless tracker header on its own identity" $ do
    headerMatch <- searchingFor "Pointer capture"
    visibleIdentities headerMatch `shouldBe` ["#705  Pointer capture hardening"]

  it "renders a matching child beneath a collapsed epic without touching the saved set" $ do
    state <- searchState
    let collapsed = state {appExpandedTrackers = Set.empty}
        searching = applySearchInput (SearchInsert 'v') (applySearchInput (SearchInsert 'n') (applySearchInput (SearchInsert 'e') (openSearch collapsed)))
    -- The match is exposed while the query is live ...
    visibleIdentities searching `shouldBe` ["#711  Adopt the versioned save envelope"]
    expandedTrackersFor searching Issues `shouldBe` Set.singleton 700
    selectableRows searching Issues `shouldBe` [0]
    -- ... but the saved set is untouched, so closing restores the collapse.
    searching.appExpandedTrackers `shouldBe` Set.empty
    (closeSearch searching).appExpandedTrackers `shouldBe` Set.empty
    expandedTrackersFor (closeSearch searching) Issues `shouldBe` Set.empty

  it "shows the visible result count over the column's full total, keeping GitHub's + on the total" $ do
    state <- searchState
    filtered <- searchingFor "envelope"
    columnCountText state Issues `shouldBe` "5"
    columnCountText (openSearch state) Issues `shouldBe` "5"
    columnCountText filtered Issues `shouldBe` "1/5"
    -- Every other column's heading is unchanged.
    columnCountText filtered Active `shouldBe` "2"

  it "counts a synthesized tracker header as the one entry it is" $ do
    ownMatch <- searchingFor "Persistence contract"
    columnCountText ownMatch Issues `shouldBe` "1/5"

-- ---------------------------------------------------------------------------

viewSpec :: Spec
viewSpec = describe "one visible view" $ do
  -- Requirement 10, driven rather than asserted about: the renderer numbers
  -- 'entriesFor' and hands each index to a 'CardTarget', so this walks the
  -- rows the renderer drew, clicks each one through the real dispatch, and
  -- insists the details that open are the card that was drawn there.
  it "opens the card drawn at a row when that row is clicked, at every query" $ do
    state <- searchState
    sequence_
      [ (query, row, detailsItem (applyCardClick Issues row selected).appOverlay)
          `shouldBe` (query, row, Just (entryItem drawn))
      | query <- searchQueries,
        let searching = withQuery query (openSearch state),
        (row, drawn) <- zip [0 ..] (entriesFor searching Issues),
        row `elem` selectableRows searching Issues,
        let selected = searching {appSelectedRows = Map.insert Issues row searching.appSelectedRows}
      ]

  -- The same walk against the raw column, which is what filtering only the
  -- drawing would have left dispatch reading. It disagrees, so the property
  -- above is a real constraint rather than a tautology about one accessor.
  it "would open a different card if a row were resolved against the raw column" $ do
    searching <- searchingFor "cache"
    let drawn = map entryNumber (entriesFor searching Issues)
        raw = map entryNumber (entriesForBoard searching.appVisibleBoard Issues)
    drawn `shouldBe` [Just 712, Just 901]
    take (length drawn) raw `shouldBe` [Just 711, Just 712]
    drawn `shouldSatisfy` (/= take (length drawn) raw)

  it "leaves every other column unfiltered while one column is searched" $ do
    filtered <- searchingFor "envelope"
    sequence_
      [ entriesFor filtered column `shouldBe` entriesForBoard filtered.appVisibleBoard column
      | column <- [Active, Reviewing, Done]
      ]

  it "keeps the open board reachable, so selection normalization and the autosolve loop still see it" $ do
    filtered <- searchingFor "envelope"
    length (entriesForBoard filtered.appBoard Issues) `shouldBe` 5
    length (entriesFor filtered Issues) `shouldBe` 1

-- | Queries covering an empty box, a whitespace-only box, a query narrowing
-- one character at a time, a number-only query, a tracker's own identity, a
-- childless header, and one nothing matches.
searchQueries :: [Text]
searchQueries = ["", " ", "e", "en", "env", "envelope", "#7", "#901", "persistence contract", "pointer", "cache", "Modal", "zzz"]

detailsItem :: Maybe Overlay -> Maybe BoardItem
detailsItem (Just (DetailsOverlay item)) = Just item
detailsItem _ = Nothing

withQuery :: Text -> AppState -> AppState
withQuery query state = Text.foldl' (\current character -> applySearchInput (SearchInsert character) current) state query

isTrackerHeader :: ColumnEntry -> Bool
isTrackerHeader (TrackerHeader _) = True
isTrackerHeader _ = False

-- ---------------------------------------------------------------------------

transitionSpec :: Spec
transitionSpec = describe "transitions" $ do
  it "opens on Issues with an empty query, selecting and revealing that column" $ do
    state <- searchState
    let opened = openSearch state {appSelectedColumn = Done, appEnsureSelectionVisible = False}
    (.searchColumn) <$> opened.appSearch `shouldBe` Just Issues
    (.searchQuery) <$> opened.appSearch `shouldBe` Just ""
    opened.appSelectedColumn `shouldBe` Issues
    opened.appEnsureSelectionVisible `shouldBe` True
    entriesFor opened Issues `shouldBe` issuesEntries

  it "appends an insertion and refilters on every keystroke, with no GitHub or cache effect" $ do
    state <- searchState
    let typed = withQuery "env" (openSearch state)
    (.searchQuery) <$> typed.appSearch `shouldBe` Just "env"
    length (entriesFor typed Issues) `shouldBe` 1
    -- Nothing a refresh owns moved.
    typed.appBoard `shouldBe` state.appBoard
    typed.appBoardFreshness `shouldBe` state.appBoardFreshness
    typed.appLastSuccessfulFetch `shouldBe` state.appLastSuccessfulFetch
    typed.appBoardRefreshQueued `shouldBe` state.appBoardRefreshQueued

  it "removes one Unicode code point per Backspace, not one byte" $ do
    -- Each of these is more than one UTF-8 byte, so a byte-wise delete would
    -- leave a broken remainder rather than the previous query.
    backspaceQuery "café" `shouldBe` "caf"
    backspaceQuery "caf" `shouldBe` "ca"
    backspaceQuery "\128devil" `shouldBe` "\128devi"
    backspaceQuery "é" `shouldBe` ""
    backspaceQuery "" `shouldBe` ""

  it "stops accepting printable input at 256 code points and accepts it again after a deletion" $ do
    let full = Text.replicate searchQueryLimit "a"
    Text.length full `shouldBe` 256
    insertQueryChar 'b' full `shouldBe` full
    Text.length (insertQueryChar 'b' (backspaceQuery full)) `shouldBe` 256
    insertQueryChar 'b' (backspaceQuery full) `shouldBe` Text.replicate 255 "a" <> "b"
    -- And one code point below the bound still accepts.
    Text.length (insertQueryChar 'b' (Text.replicate (searchQueryLimit - 1) "a")) `shouldBe` 256

  it "bounds the query the same way through the whole transition" $ do
    state <- searchState
    let filled = withQuery (Text.replicate searchQueryLimit "a") (openSearch state)
        overflowed = applySearchInput (SearchInsert 'b') filled
    (Text.length <$> ((.searchQuery) <$> overflowed.appSearch)) `shouldBe` Just 256

  it "closes on s or Esc, restoring the complete column" $ do
    filtered <- searchingFor "envelope"
    -- Both keys decode to the same input, which is what makes one transition
    -- enough to cover the pair.
    searchInput filtered.appSearch (Vty.EvKey (Vty.KChar 's') []) `shouldBe` Just SearchClose
    searchInput filtered.appSearch (Vty.EvKey Vty.KEsc []) `shouldBe` Just SearchClose
    let closed = applySearchInput SearchClose filtered
    closed.appSearch `shouldBe` Nothing
    entriesFor closed Issues `shouldBe` issuesEntries
    columnCountText closed Issues `shouldBe` "5"

  it "keeps the selected result selected by identity across an edit and a close" $ do
    state <- searchState
    -- Select #812, the last standalone, then narrow to a query it still
    -- matches: its row number changes, its identity does not.
    let selected = state {appSelectedRows = Map.insert Issues 4 state.appSelectedRows}
        searching = withQuery "modal" (openSearch selected)
    selectedRow searching Issues `shouldBe` 0
    identityOf searching `shouldBe` Just "#812  Modal input leaks through overlay"
    let closed = closeSearch searching
    closed.appSearch `shouldBe` Nothing
    selectedRow closed Issues `shouldBe` 4
    identityOf closed `shouldBe` Just "#812  Modal input leaks through overlay"

  it "takes the first visible result when the restored column has collapsed the anchor away" $ do
    -- The collapsed group is deliberately not this column's first entry: a
    -- nearest-selectable-row fallback would seat on the epic's own row, which
    -- is neither the anchored child nor the first result, and only a group
    -- with something above it tells the two apart.
    state <- testAppState laterGroupBoard
    let searching = withQuery "terrain" (openSearch state)
    -- The match is exposed and selected while the query is live ...
    identityOf searching `shouldBe` Just "#712  Migrate the terrain cache reader"
    selectedRow searching Issues `shouldBe` 0
    -- ... and closing collapses it away again, so the selection takes the
    -- first entry the restored column offers.
    let closed = closeSearch searching
    selectableRows closed Issues `shouldBe` [0, 1]
    selectedRow closed Issues `shouldBe` 0
    identityOf closed `shouldBe` Just "#901  Add repository snapshot cache"

  it "falls back to the first visible result when the selected item stops matching" $ do
    state <- searchState
    let selected = state {appSelectedRows = Map.insert Issues 4 state.appSelectedRows}
        searching = withQuery "envelope" (openSearch selected)
    identityOf searching `shouldBe` Just "#711  Adopt the versioned save envelope"
    selectedRow searching Issues `shouldBe` 0

  it "leaves nothing selected when the query empties the column" $ do
    empty <- searchingFor "nothing matches this"
    selectedEntry empty `shouldBe` Nothing
    selectableRows empty Issues `shouldBe` []

  it "moves the selection among visible results only" $ do
    searching <- searchingFor "cache"
    -- Both #712 and #901 carry "cache"; #799 does too but sits in Active.
    visibleIdentities searching `shouldBe` ["#712  Migrate the terrain cache reader", "#901  Add repository snapshot cache"]
    selectedRow searching Issues `shouldBe` 0
    let downOnce = applySearchInput (SearchMove 1) searching
        downTwice = applySearchInput (SearchMove 1) downOnce
        upAgain = applySearchInput (SearchMove (-1)) downTwice
    selectedRow downOnce Issues `shouldBe` 1
    -- The last result is the end of the list; there is nothing below it.
    selectedRow downTwice Issues `shouldBe` 1
    selectedRow upAgain Issues `shouldBe` 0

  it "re-runs the query against a refreshed board and keeps a still-matching item selected" $ do
    searching <- searchingFor "cache"
    let moved = refreshVisibleBoard searching {appBoard = boardWithout 712}
        reseated = reseatSearch (selectedAnchorIn searching Issues) moved
    -- #712 left the column, so the query's remaining match takes the
    -- selection rather than whatever moved into row 0.
    identityOf reseated `shouldBe` Just "#901  Add repository snapshot cache"
    reseated.appSelectedColumn `shouldBe` Issues

  it "keeps the searched column selected even when the item moved to another column" $ do
    searching <- searchingFor "terrain"
    identityOf searching `shouldBe` Just "#712  Migrate the terrain cache reader"
    let relocated = refreshVisibleBoard searching {appBoard = boardMoving712ToActive}
        reseated = reseatSearch (selectedAnchorIn searching Issues) relocated
    reseated.appSelectedColumn `shouldBe` Issues
    entriesFor reseated Issues `shouldBe` []
    selectedEntry reseated `shouldBe` Nothing

  it "leaves the board and the query untouched when a refresh fails" $ do
    searching <- searchingFor "cache"
    let unchanged = reseatSearch (selectedAnchorIn searching Issues) searching
    unchanged.appSearch `shouldBe` searching.appSearch
    unchanged.appBoard `shouldBe` searching.appBoard
    selectedRow unchanged Issues `shouldBe` selectedRow searching Issues

  it "reconciles a structural tracker header by its tracker issue number" $ do
    ownMatch <- searchingFor "Pointer capture"
    selectedAnchorIn ownMatch Issues `shouldBe` Just (AnchorTracker 705)
    identityOf ownMatch `shouldBe` Just "#705  Pointer capture hardening"

  -- A populated epic's header is synthesized from its child rows, so while
  -- that epic is collapsed the row the user selected is its first child while
  -- what they see and act on is the epic. Anchoring on the child loses the
  -- header the moment a query replaces the group with a synthesized
  -- 'TrackerHeader' — and loses it again on the way back.
  it "anchors a collapsed populated epic's header on the epic, not on its first child" $ do
    state <- testAppState laterGroupBoard
    selectableRows state Issues `shouldBe` [0, 1]
    anchorAt state Issues 0 `shouldBe` Just (AnchorItem (IssueId 901))
    anchorAt state Issues 1 `shouldBe` Just (AnchorTracker 700)
    -- Expanded, that same row is the child card it draws.
    let expanded = state {appExpandedTrackers = Set.singleton 700}
    anchorAt expanded Issues 1 `shouldBe` Just (AnchorItem (IssueId 711))

  it "restores a collapsed epic's header after a query that matched the epic alone" $ do
    state <- testAppState laterGroupBoard
    -- The header row is selected, and the query matches the epic's own
    -- identity while matching neither child nor the standalone above it.
    let selected = state {appSelectedRows = Map.insert Issues 1 state.appSelectedRows}
        searching = withQuery "persistence contract" (openSearch selected)
    visibleIdentities searching `shouldBe` ["#700  Persistence contract rollout"]
    selectedAnchorIn searching Issues `shouldBe` Just (AnchorTracker 700)
    -- Closing restores the children under the header, and the selection stays
    -- on that header rather than falling back to the standalone above it.
    let closed = closeSearch searching
    closed.appSearch `shouldBe` Nothing
    selectedRow closed Issues `shouldBe` 1
    selectedAnchorIn closed Issues `shouldBe` Just (AnchorTracker 700)
    identityOf closed `shouldBe` Just "#711  Adopt the versioned save envelope"

  it "keeps a collapsed epic's header selected across an edit that narrows to it and back" $ do
    state <- testAppState laterGroupBoard
    let selected = state {appSelectedRows = Map.insert Issues 1 state.appSelectedRows}
        narrowed = withQuery "persistence contract" (openSearch selected)
        -- Nine deletions leave "persistence", which still matches the epic
        -- alone, so the header row survives the edit in both directions.
        widened = Text.foldl' (\current _ -> applySearchInput SearchBackspace current) narrowed (Text.replicate 9 "x")
    selectedAnchorIn narrowed Issues `shouldBe` Just (AnchorTracker 700)
    (.searchQuery) <$> widened.appSearch `shouldBe` Just "persistence"
    visibleIdentities widened `shouldBe` ["#700  Persistence contract rollout"]
    selectedAnchorIn widened Issues `shouldBe` Just (AnchorTracker 700)

  it "re-seats a collapsed epic's header on a refreshed board" $ do
    state <- testAppState laterGroupBoard
    let selected = state {appSelectedRows = Map.insert Issues 1 state.appSelectedRows}
        searching = withQuery "persistence contract" (openSearch selected)
        -- The refresh drops the child the header row sat on; the epic and its
        -- other child remain, so the header must survive.
        refreshed = refreshVisibleBoard searching {appBoard = laterGroupBoardWithout 711}
        reseated = reseatSearch (selectedAnchorIn searching Issues) refreshed
    selectedAnchorIn reseated Issues `shouldBe` Just (AnchorTracker 700)
    selectedRow reseated Issues `shouldBe` 0

  it "never puts search state anywhere a snapshot or the cache could reach" $ do
    -- 'AppState' has no serialization instances at all, so this is really a
    -- statement about the board: a query changes what is shown and nothing
    -- about the data the cache is written from.
    searching <- searchingFor "envelope"
    plain <- searchState
    searching.appBoard `shouldBe` plain.appBoard
    searching.appExpandedTrackers `shouldBe` plain.appExpandedTrackers

identityOf :: AppState -> Maybe Text
identityOf state = entryIdentityText <$> selectedEntry state

-- | The identity of the row @column@ has selected, whether or not that column
-- is the selected one — which is exactly what a transfer moves.
identityIn :: AppState -> BoardColumn -> Maybe Text
identityIn state column = entryIdentityText <$> safeIndex (selectedRow state column) (entriesFor state column)

-- ---------------------------------------------------------------------------

-- | Moving a live search to another column, by either path.
--
-- The state a transfer reaches is the whole contract, so the click cases and
-- the key cases below are the same assertions over the same transition: a
-- click decides /whether/ to transfer ('searchMouseTransfer', covered in the
-- mouse group) and Left and Right decide /where/, and both then hand over to
-- 'transferSearchTo'.
transferSpec :: Spec
transferSpec = describe "transferring to another column" $ do
  it "moves the box, clears the query, and selects and reveals the new column" $ do
    searching <- transferring
    let moved = transferSearchTo Active searching
    (.searchColumn) <$> moved.appSearch `shouldBe` Just Active
    (.searchQuery) <$> moved.appSearch `shouldBe` Just ""
    moved.appSelectedColumn `shouldBe` Active
    moved.appEnsureSelectionVisible `shouldBe` True
    -- The box is drawn in Active and nowhere else, and both headings are back
    -- to the ordinary count form over complete columns.
    searchQueryFor moved Active `shouldBe` Just ""
    searchQueryFor moved Issues `shouldBe` Nothing
    entriesFor moved Active `shouldBe` activeEntries
    entriesFor moved Issues `shouldBe` issuesEntries
    (columnCountText moved Active, columnCountText moved Issues) `shouldBe` ("2", "5")

  it "reaches the same state through a click, through Left, and through Right" $ do
    searching <- transferring
    -- Right from Issues, a click anywhere in Active, and the transition the
    -- two share: one state, three ways to it.
    let byKey = applySearchInput (SearchTransfer 1) searching
        byClick = maybe searching (`transferSearchTo` searching) (searchMouseTransfer searching (CardTarget Active 0) Vty.BLeft)
    byKey `shouldBe'` transferSearchTo Active searching
    byClick `shouldBe'` transferSearchTo Active searching
    -- And back again by the opposite arrow, which is a transfer like any
    -- other rather than an undo: the query it cleared does not return.
    let back = applySearchInput (SearchTransfer (-1)) byKey
    back `shouldBe'` transferSearchTo Issues byKey
    (.searchColumn) <$> back.appSearch `shouldBe` Just Issues
    (.searchQuery) <$> back.appSearch `shouldBe` Just ""

  it "restores the column it left complete, keeping its selected result selected by identity" $ do
    searching <- transferring
    -- #901 is the second result of "cache" and the fourth row of the complete
    -- column, so a re-seat by row number would leave row 1 — #712's child
    -- row — selected instead.
    identityIn searching Issues `shouldBe` Just "#901  Add repository snapshot cache"
    selectedRow searching Issues `shouldBe` 1
    let moved = transferSearchTo Active searching
    selectedRow moved Issues `shouldBe` 3
    identityIn moved Issues `shouldBe` Just "#901  Add repository snapshot cache"

  it "leaves the column it enters on the row that column remembered" $ do
    searching <- transferring
    -- Active's remembered row is its collapsed epic's header, not its first
    -- row, so a transfer that re-seated the destination would move it.
    selectedRow searching Active `shouldBe` 1
    selectedAnchorIn searching Active `shouldBe` Just (AnchorTracker 706)
    let moved = transferSearchTo Active searching
    selectedRow moved Active `shouldBe` 1
    selectedAnchorIn moved Active `shouldBe` Just (AnchorTracker 706)
    -- The entry beneath that row is the epic's first child, which is what a
    -- collapsed populated group's header row is made of; the anchor above is
    -- what the row draws and what acting on it acts on.
    identityIn moved Active `shouldBe` Just "#731  Reattach an orphaned worker"

  it "does nothing else: no overlay, no epic toggled, no session touched" $ do
    searching <- transferring
    let moved = transferSearchTo Active searching
    moved.appOverlay `shouldBe` Nothing
    moved.appExpandedTrackers `shouldBe` searching.appExpandedTrackers
    expandedTrackersFor moved Active `shouldBe` expandedTrackersFor searching Active
    Map.keys moved.appReviewSessions `shouldBe` Map.keys searching.appReviewSessions
    moved.appBoard `shouldBe` searching.appBoard

  it "keeps the query, the selection, and a notice when it cannot move" $ do
    searching <- transferring
    -- Issues is the leftmost column and Done the rightmost, so these two
    -- presses resolve to the column already searched.
    let noticed = searching {appNotice = Just "Collapsed epic #700"}
        atLeft = applySearchInput (SearchTransfer (-1)) noticed
        onDone = transferSearchTo Done noticed
        atRight = applySearchInput (SearchTransfer 1) onDone
    atLeft `shouldBe'` noticed
    atLeft.appNotice `shouldBe` Just "Collapsed epic #700"
    (.searchColumn) <$> onDone.appSearch `shouldBe` Just Done
    atRight `shouldBe'` onDone

  it "closes on the column it moved to, restoring that column complete" $ do
    searching <- transferring
    let moved = transferSearchTo Active searching
        typed = withQuery "orphaned" moved
        closed = applySearchInput SearchClose typed
    -- The query filters its new target, and closing restores it.
    visibleIn typed Active `shouldBe` ["#731  Reattach an orphaned worker"]
    closed.appSearch `shouldBe` Nothing
    entriesFor closed Active `shouldBe` activeEntries
    closed.appSelectedColumn `shouldBe` Active
    columnCountText closed Active `shouldBe` "2"

  it "transfers nothing when no search is open" $ do
    plain <- searchState
    transferSearchTo Active plain `shouldBe'` plain
    transferSearchBy 1 plain `shouldBe'` plain
    sequence_
      [ searchMouseTransfer plain (CardTarget column 0) button `shouldBe` Nothing
      | column <- [minBound .. maxBound],
        button <- [Vty.BLeft, Vty.BRight]
      ]

-- | A live search on Issues, with everything a transfer into Active must
-- either move or leave alone: the second result selected in the searched
-- column, a live review session on Active's standalone card, and Active
-- remembering its collapsed epic's header rather than its first row.
transferring :: IO AppState
transferring = do
  searching <- searchingFor "cache"
  let onSecondResult = applySearchInput (SearchMove 1) searching
      seated = onSecondResult {appSelectedRows = Map.insert Active 1 onSecondResult.appSelectedRows}
  pure (withReviewSession (titledIssue 799 "Repair stale world cache invalidation") ReviewRunning seated)

visibleIn :: AppState -> BoardColumn -> [Text]
visibleIn state column = map entryIdentityText (entriesFor state column)

boardWithout :: Int -> Board
boardWithout number =
  Board
    ( Map.fromList
        ( [(column, []) | column <- [minBound .. maxBound]]
            <> [(Issues, filter ((/= Just number) . entryNumber) issuesEntries), (Active, activeEntries)]
        )
    )

boardMoving712ToActive :: Board
boardMoving712ToActive =
  Board
    ( Map.fromList
        ( [(column, []) | column <- [minBound .. maxBound]]
            <> [ (Issues, filter ((/= Just 712) . entryNumber) issuesEntries),
                 (Active, activeEntries <> [standaloneCard 712 "Migrate the terrain cache reader"])
               ]
        )
    )

entryNumber :: ColumnEntry -> Maybe Int
entryNumber (Standalone (IssueItem issue)) = Just issue.issueNumber
entryNumber (Tracked _ (IssueItem issue)) = Just issue.issueNumber
entryNumber _ = Nothing

-- ---------------------------------------------------------------------------

precedenceSpec :: Spec
precedenceSpec = describe "key precedence" $ do
  it "types the letters that are board shortcuts, instead of firing them" $
    sequence_
      [ (character, searchInput liveSearch event, boardAction BoardScope event)
          `shouldBe` (character, Just (SearchInsert character), Just action)
      | (character, action) <-
          [ ('r', ReviewSelection),
            ('S', SolveSelection),
            ('u', RefreshAll),
            ('d', ToggleDrainer),
            ('e', ToggleEpic),
            ('j', NextCard),
            ('k', PreviousCard),
            ('h', PreviousColumn),
            ('l', NextColumn),
            ('g', FirstItem),
            ('G', LastItem),
            ('i', ShowIncidents),
            ('p', ShowProcesses),
            ('c', ToggleSidebar),
            ('o', ShowSettings),
            ('m', MergeDoneCard),
            ('x', KillWorking),
            ('A', AutoSolveSelection),
            ('?', ShowHelp)
          ],
        let event = Vty.EvKey (Vty.KChar character) []
      ]

  it "closes on s and Esc rather than typing them" $ do
    searchInput liveSearch (Vty.EvKey (Vty.KChar 's') []) `shouldBe` Just SearchClose
    searchInput liveSearch (Vty.EvKey Vty.KEsc []) `shouldBe` Just SearchClose
    boardAction BoardScope (Vty.EvKey (Vty.KChar 's') []) `shouldBe` Just OpenSearch

  it "declines q and Ctrl-C, so both reach the guarded dashboard quit" $ do
    searchInput liveSearch (Vty.EvKey (Vty.KChar 'q') []) `shouldBe` Nothing
    searchInput liveSearch (Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl]) `shouldBe` Nothing
    boardAction BoardScope (Vty.EvKey (Vty.KChar 'q') []) `shouldBe` Just QuitDashboard
    boardAction BoardScope (Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl]) `shouldBe` Just QuitDashboard

  it "declines every chord carrying Ctrl, Meta, or Alt, so Ctrl-L still repaints" $ do
    searchInput liveSearch (Vty.EvKey (Vty.KChar 'l') [Vty.MCtrl]) `shouldBe` Nothing
    boardAction BoardScope (Vty.EvKey (Vty.KChar 'l') [Vty.MCtrl]) `shouldBe` Just RepaintTerminal
    sequence_
      [ searchInput liveSearch (Vty.EvKey (Vty.KChar character) modifiers) `shouldBe` Nothing
      | character <- ['a', 'r', 's', 'q', 'z'],
        modifiers <- [[Vty.MCtrl], [Vty.MMeta], [Vty.MAlt], [Vty.MCtrl, Vty.MShift]]
      ]

  it "moves the selection with Up and Down and the search itself with Left and Right" $ do
    searchInput liveSearch (Vty.EvKey Vty.KUp []) `shouldBe` Just (SearchMove (-1))
    searchInput liveSearch (Vty.EvKey Vty.KDown []) `shouldBe` Just (SearchMove 1)
    searchInput liveSearch (Vty.EvKey Vty.KLeft []) `shouldBe` Just (SearchTransfer (-1))
    searchInput liveSearch (Vty.EvKey Vty.KRight []) `shouldBe` Just (SearchTransfer 1)

  -- Requirement 8: only the arrows transfer. `h` and `l` are printable, so
  -- they were claimed as text above — the case that walks every board
  -- shortcut covers both of them — and the board's own column movement is
  -- what they would otherwise have fired.
  it "types h and l rather than moving anything with them" $ do
    searching <- searchingFor "cache"
    sequence_
      [ (character, searchInput liveSearch event, boardAction BoardScope event)
          `shouldBe` (character, Just (SearchInsert character), Just action)
      | (character, action) <- [('h', PreviousColumn), ('l', NextColumn)],
        let event = Vty.EvKey (Vty.KChar character) []
      ]
    let typed = applySearchInput (SearchInsert 'l') searching
    (.searchQuery) <$> typed.appSearch `shouldBe` Just "cachel"
    (.searchColumn) <$> typed.appSearch `shouldBe` Just Issues
    typed.appSelectedColumn `shouldBe` Issues

  it "opens details on Enter and ends search on the identity it opened" $ do
    searching <- searchingFor "modal"
    let opened = openSearchResult searching
    opened.appOverlay `shouldBe` Just (DetailsOverlay (IssueItem (titledIssue 812 "Modal input leaks through overlay")))
    opened.appSearch `shouldBe` Nothing
    entriesFor opened Issues `shouldBe` issuesEntries
    selectedRow opened Issues `shouldBe` 4

  it "opens a match found under a collapsed epic rather than asking for it to be expanded" $ do
    state <- searchState
    let searching = withQuery "envelope" (openSearch state {appExpandedTrackers = Set.empty})
        opened = openSearchResult searching
    opened.appOverlay `shouldBe` Just (DetailsOverlay (IssueItem (titledIssue 711 "Adopt the versioned save envelope")))
    opened.appSearch `shouldBe` Nothing
    -- The saved collapse survives the round trip.
    opened.appExpandedTrackers `shouldBe` Set.empty

  it "leaves search running when Enter opened nothing" $ do
    empty <- searchingFor "nothing matches this"
    let pressed = openSearchResult empty
    pressed.appOverlay `shouldBe` Nothing
    pressed.appSearch `shouldBe` empty.appSearch

  it "claims nothing at all with no search open, and nothing that is not a key press" $ do
    sequence_
      [ searchInput Nothing event `shouldBe` Nothing
      | event <- [Vty.EvKey (Vty.KChar 'a') [], Vty.EvKey Vty.KEsc [], Vty.EvKey Vty.KEnter []]
      ]
    -- Application events are matched by arms above this decoder entirely, and
    -- a non-key Vty event is declined here too, so a resize or a refresh
    -- completion is never mistaken for typing.
    searchInput liveSearch (Vty.EvResize 80 24) `shouldBe` Nothing
    searchInput liveSearch (Vty.EvKey (Vty.KChar '\t') []) `shouldBe` Nothing

-- | State equality without the fields no transition here is about, since
-- 'AppState' itself has no 'Eq'.
shouldBe' :: AppState -> AppState -> Expectation
shouldBe' actual expected =
  (actual.appSearch, actual.appSelectedColumn, actual.appSelectedRows, actual.appExpandedTrackers, actual.appOverlay, actual.appNotice)
    `shouldBe` (expected.appSearch, expected.appSelectedColumn, expected.appSelectedRows, expected.appExpandedTrackers, expected.appOverlay, expected.appNotice)

-- ---------------------------------------------------------------------------

mouseSpec :: Spec
mouseSpec = describe "mouse precedence" $ do
  -- The whole matrix §7 names, stated against the decision dispatch actually
  -- makes rather than against the classifier feeding it: three things a press
  -- can land on, two buttons that transfer and a wheel that never does,
  -- inside the searched column and outside it.
  it "transfers a left or right press anywhere in a column it is not searching" $ do
    searching <- transferring
    sequence_
      [ (landing, button, boardMouseAction searching name button [])
          `shouldBe` (landing, button, Just (TransferSearch Active))
      | (landing, name) <- columnLandings Active,
        button <- [Vty.BLeft, Vty.BRight]
      ]

  it "gives a press inside the searched column the meaning it has with no search open" $ do
    searching <- transferring
    plain <- searchState
    sequence_
      [ (landing, button, boardMouseAction searching name button [])
          `shouldBe` (landing, button, boardMouseAction plain name button [])
      | (landing, name) <- columnLandings Issues,
        button <- [Vty.BLeft, Vty.BRight]
      ]
    -- And that meaning is an action, not the absence of one, for the three
    -- presses §7 gives the searched column.
    boardMouseAction searching (CardTarget Issues 0) Vty.BLeft [] `shouldBe` Just (SelectOrOpenCardAt Issues 0)
    boardMouseAction searching (CardTarget Issues 0) Vty.BRight [] `shouldBe` Just (OpenRunningProcessAt Issues 0)
    boardMouseAction searching (EpicTarget Issues 1 700) Vty.BLeft [] `shouldBe` Just (ToggleEpicFromClick Issues 1 700)

  it "keeps the wheel scrolling the column under it, searched or not" $ do
    searching <- transferring
    sequence_
      [ (column, landing, button, boardMouseAction searching name button [])
          `shouldBe` (column, landing, button, Just (ScrollColumnBy column amount))
      | column <- [Issues, Active],
        (landing, name) <- columnLandings column,
        (button, amount) <- [(Vty.BScrollUp, -3), (Vty.BScrollDown, 3)]
      ]

  it "claims nothing at all for the middle button" $ do
    searching <- transferring
    sequence_
      [ (column, landing, boardMouseAction searching name Vty.BMiddle []) `shouldBe` (column, landing, Nothing)
      | column <- [Issues, Active],
        (landing, name) <- columnLandings column
      ]

  -- Requirement 6: the drainer button is not a column target, so it is
  -- answered ahead of the transfer and keeps the toggle it has always
  -- dispatched — the search it never sees keeps its target and its query.
  --
  -- Taken rather than asserted about: dispatch decides the press and then
  -- 'boardMousePress' is the whole of what dispatch does with the decision,
  -- so running it here is running the press. A drainer press hands its
  -- controller work off separately, which is what lets this take one without
  -- a controller subprocess.
  it "still takes the drainer button's toggle while a search is live" $ do
    searching <- transferring
    plain <- searchState
    let installed state = state {appDrainerController = Right (DrainerController "/nonexistent/kanban-test-drainer" [] DrainerLaunchd)}
        press state = boardMousePress <$> boardMouseAction state DrainerButton Vty.BLeft [] <*> pure (installed state)
    boardMouseAction searching DrainerButton Vty.BLeft [] `shouldBe` Just ToggleDrainerFromClick
    boardMouseAction plain DrainerButton Vty.BLeft [] `shouldBe` Just ToggleDrainerFromClick
    -- The toggle ran: the drainer is on its way up and the press said so.
    ((.appDrainerStatus.drainerState) <$> press searching) `shouldBe` Just DrainerStarting
    ((.appDrainerBusy) <$> press searching) `shouldBe` Just True
    ((.appNotice) <$> press searching) `shouldBe` Just (Just "Starting PR drainer…")
    -- And the search is exactly where it was, still on its query.
    ((.appSearch) <$> press searching) `shouldBe` Just searching.appSearch
    ((.appSelectedColumn) <$> press searching) `shouldBe` Just searching.appSelectedColumn
    -- The same press with nothing searching does the same thing, which is
    -- what "keeps working" means.
    ((.appDrainerStatus.drainerState) <$> press plain) `shouldBe` Just DrainerStarting
    -- Nothing about that press is a transfer, on any button.
    sequence_
      [ searchMouseTransfer searching DrainerButton button `shouldBe` Nothing
      | button <- [Vty.BLeft, Vty.BRight, Vty.BMiddle, Vty.BScrollUp, Vty.BScrollDown]
      ]

  -- The sidebar's update control, held to the same rule the drainer button
  -- is: it is not a column target, so a live search never sees the press and
  -- the control keeps the update it dispatches.
  --
  -- What the click resolves to is the whole of what there is to take. The
  -- update is not a state transition of its own — 'startAllRefreshes' is what
  -- the key reaches too, and it is where the loading marks and the in-flight
  -- coalescing are decided — so the pure press is deliberately identity, and
  -- that is asserted rather than assumed.
  it "still takes the update button's refresh while a search is live" $ do
    searching <- transferring
    plain <- searchState
    let press state = boardMousePress <$> boardMouseAction state UpdateButton Vty.BLeft [] <*> pure state
    boardMouseAction searching UpdateButton Vty.BLeft [] `shouldBe` Just RefreshAllFromClick
    boardMouseAction plain UpdateButton Vty.BLeft [] `shouldBe` Just RefreshAllFromClick
    -- The search is exactly where it was, still on its query, and the press
    -- moved neither the column nor the selection nor an overlay.
    ((.appSearch) <$> press searching) `shouldBe` Just searching.appSearch
    ((.appSelectedColumn) <$> press searching) `shouldBe` Just searching.appSelectedColumn
    ((.appOverlay) <$> press searching) `shouldBe` Just Nothing
    (flip selectedRow Issues <$> press searching) `shouldBe` Just (selectedRow searching Issues)
    -- The same press with nothing searching resolves to the same update.
    ((.appSearch) <$> press plain) `shouldBe` Just plain.appSearch
    -- Nothing about that press is a transfer, on any button.
    sequence_
      [ searchMouseTransfer searching UpdateButton button `shouldBe` Nothing
      | button <- [Vty.BLeft, Vty.BRight, Vty.BMiddle, Vty.BScrollUp, Vty.BScrollDown]
      ]

  -- Requirement 5, and the modifier the issue puts out of scope: only a plain
  -- left press means anything over the update control. Every other button and
  -- every modified left press falls through to the column arms, which name no
  -- sidebar control, so the board claims nothing at all for it — no update, no
  -- scroll, no transfer.
  it "claims nothing for any other press on either sidebar control" $ do
    searching <- transferring
    plain <- searchState
    sequence_
      [ (label, name, button, modifiers, boardMouseAction state name button modifiers)
          `shouldBe` (label, name, button, modifiers, Nothing)
      | (label, state) <- [("searching" :: Text, searching), ("plain", plain)],
        name <- [UpdateButton, DrainerButton],
        (button, modifiers) <-
          [(button', []) | button' <- [Vty.BMiddle, Vty.BRight, Vty.BScrollUp, Vty.BScrollDown]]
            <> [(Vty.BLeft, [modifier]) | modifier <- [Vty.MCtrl, Vty.MShift, Vty.MMeta, Vty.MAlt]]
      ]

  -- The other presses, taken the same way: what dispatch decides, run.
  it "takes a transferring press as the transfer and a searched-column press as its ordinary action" $ do
    searching <- transferring
    let take' name button = boardMousePress <$> boardMouseAction searching name button [] <*> pure searching
        transferred = take' (EpicTarget Active 1 706) Vty.BLeft
        ordinary = take' (CardTarget Issues 0) Vty.BLeft
    -- The epic-header press in Active moved the search and left epic 706 alone.
    ((.searchColumn) <$> (transferred >>= (.appSearch))) `shouldBe` Just Active
    ((.searchQuery) <$> (transferred >>= (.appSearch))) `shouldBe` Just ""
    (Set.member 706 . (.appExpandedTrackers) <$> transferred) `shouldBe` Just False
    ((.appOverlay) <$> transferred) `shouldBe` Just Nothing
    -- The card press inside Issues selected the result it landed on and kept
    -- the query; the selection had been on the other result.
    selectedRow searching Issues `shouldBe` 1
    ((.appSearch) <$> ordinary) `shouldBe` Just searching.appSearch
    ((.appOverlay) <$> ordinary) `shouldBe` Just Nothing
    (flip selectedRow Issues <$> ordinary) `shouldBe` Just 0

  -- The other half of requirement 2, for the press that does transfer: the
  -- epic header a transferring click landed on is not toggled, and the live
  -- session under a right click is not opened.
  it "consumes the action a transferring press would ordinarily have performed" $ do
    searching <- transferring
    let onEpic = transferSearchTo Active searching
    Set.member 706 onEpic.appExpandedTrackers `shouldBe` False
    Set.member 706 (expandedTrackersFor onEpic Active) `shouldBe` False
    onEpic.appOverlay `shouldBe` Nothing
    -- What the same press would have done without the transfer, so the case
    -- above is a real constraint: the epic expands, and the right click on
    -- Active's card opens its live session.
    let toggled = applyCardClick Active 0 (applyCardClick Active 0 searching {appSearch = Nothing})
        opened = applyRunningProcessClick Active 0 searching {appSearch = Nothing}
    toggled.appOverlay `shouldBe` Just (DetailsOverlay (IssueItem (titledIssue 799 "Repair stale world cache invalidation")))
    opened.appOverlay `shouldBe` Just (ReviewOverlay 799)

  it "selects without ending search when the click only selects" $ do
    searching <- searchingFor "cache"
    let clicked = applyCardClick Issues 1 searching
    selectedRow clicked Issues `shouldBe` 1
    clicked.appSearch `shouldBe` searching.appSearch
    clicked.appOverlay `shouldBe` Nothing

  it "ends search when a click opens details, keeping the clicked identity selected" $ do
    searching <- searchingFor "cache"
    let selected = applyCardClick Issues 1 searching
        opened = applyCardClick Issues 1 selected
    opened.appOverlay `shouldBe` Just (DetailsOverlay (IssueItem (titledIssue 901 "Add repository snapshot cache")))
    opened.appSearch `shouldBe` Nothing
    selectedRow opened Issues `shouldBe` 3

  it "ends search when a right click opens a live session's overlay" $ do
    searching <- searchingFor "cache"
    let withSession = withReviewSession (titledIssue 901 "Add repository snapshot cache") ReviewRunning searching
        clicked = applyRunningProcessClick Issues 1 withSession
    clicked.appOverlay `shouldBe` Just (ReviewOverlay 901)
    clicked.appSearch `shouldBe` Nothing
    selectedRow clicked Issues `shouldBe` 3

  it "leaves search running when a right click found no live session" $ do
    searching <- searchingFor "cache"
    let clicked = applyRunningProcessClick Issues 1 searching
    clicked.appOverlay `shouldBe` Nothing
    clicked.appSearch `shouldBe` searching.appSearch
    selectedRow clicked Issues `shouldBe` 1

  it "resolves a click to the card actually drawn at that row" $ do
    searching <- searchingFor "cache"
    -- Row 1 of the filtered view is #901; row 1 of the raw column is #712.
    (entryNumber <$> safeIndex 1 (entriesFor searching Issues)) `shouldBe` Just (Just 901)
    (entryNumber <$> safeIndex 1 (entriesForBoard searching.appVisibleBoard Issues)) `shouldBe` Just (Just 712)
    let clicked = applyCardClick Issues 1 (applyCardClick Issues 1 searching)
    clicked.appOverlay `shouldBe` Just (DetailsOverlay (IssueItem (titledIssue 901 "Add repository snapshot cache")))

-- | The three things a press can land on inside one column: a card, an epic's
-- header, and the column's own whitespace. Requirement 3 is that all three
-- transfer identically, so every mouse case above is stated over this list
-- rather than over one of them.
columnLandings :: BoardColumn -> [(String, Name)]
columnLandings column =
  [ ("card", CardTarget column 0),
    ("epic header", EpicTarget column 1 706),
    ("whitespace", ColumnViewport column)
  ]
