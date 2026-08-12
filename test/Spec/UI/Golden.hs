-- | The golden-frame suite promised by @docs\/design.md@ §18.
--
-- Every case here draws the whole application through
-- 'Kanban.UI.drawApplication' -- the same composition 'Kanban.UI.runDashboard'
-- hands Brick -- into a terminal-free frame of a fixed size, and compares that
-- frame with a checked-in file. Nothing is reconstructed for the test, so a
-- regression anywhere between the shell border and a card's last excerpt row
-- lands in a reviewable diff.
--
-- Frames have to be reproducible, so every input a frame can vary over is
-- pinned: the fixture snapshot's timestamps ("Kanban.Fixture"), the redraw
-- instant and time zone, board and usage freshness, the notice line, the
-- drainer status, and the empty session, process, and worker maps.
-- Constructing 'AppState' field by field is deliberate: a new field that
-- reaches the screen cannot be added without deciding what these frames show
-- for it.
--
-- Regenerate the checked-in frames with:
--
-- > KANBAN_UPDATE_GOLDENS=1 cabal test kanban-test
--
-- and read the resulting diff before committing it. An ordinary @cabal test@
-- run never rewrites them. See "Spec.Support.Golden".
module Spec.UI.Golden (spec) where

import Brick (AttrMap)
import Brick.AttrMap (attrMapLookup)
import Brick.BChan (BChan, newBChan)
import Data.List (findIndex, isInfixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime, utc)
import qualified Graphics.Vty.Attributes as Vty
import Kanban.CLI (BorderPolicy (..), Options (..))
import Kanban.Card (displayWidth)
import Kanban.Domain
import Kanban.Drainer (DrainerActivity (..), DrainerState (..), DrainerStatus (..))
import Kanban.Fixture (fixtureBoard, fixtureUsage)
import Kanban.Settings (defaultSettings)
import Kanban.UI (drawApplication)
import Kanban.UI.Search (SearchInput (..), applySearchInput, openSearch)
import Kanban.UI.Theme
  ( approvedAttr,
    pendingAttr,
    problemAttr,
    readyAttr,
    selectedAttr,
    selectedTitleAttr,
    themeFor,
  )
import Kanban.UI.Types
  ( AppEvent,
    AppState (..),
    IncidentSelection (..),
    Overlay (..),
    ProcessSelection (..),
    ReviewBackend (..),
  )
import Spec.Support.Fixtures (itemNumber, testOptions, testResolvedConfig)
import Spec.Support.Golden (attributeGrid, expectGolden, goldenPath)
import Spec.Support.Render (FrameCell (..), frameRowText, renderFrameCells)
import Test.Hspec

spec :: Spec
spec = describe "golden frames" $ do
  -- The frames index rows by character, which is the same thing as indexing
  -- by terminal cell only while every glyph is one cell wide. Several §10
  -- glyphs are East Asian ambiguous, so a changed Vty width table is what
  -- would break that assumption -- and it should break here, naming the
  -- glyph, rather than as an unreadable frame diff.
  it "measures every glyph the fixture frames draw as one terminal cell" $ do
    frames <- traverse renderCase frameCases
    let measured = [(character, displayWidth (Data.Text.singleton character)) | character <- allCharacters frames]
    filter ((/= 1) . snd) measured `shouldBe` []

  it "fills every row of every frame to the region's full width" $ do
    frames <- traverse renderCase frameCases
    let widths =
          [ (frameCase.frameCaseName, length row)
          | (frameCase, frame) <- zip frameCases frames,
            row <- frame,
            length row /= frameCase.frameCaseWidth
          ]
    widths `shouldBe` []

  mapM_ frameCaseSpec frameCases

  it "records the wide frame's attributes beside its characters" $ do
    frame <- renderCase wideCase
    expectGolden (goldenPath "board-wide.attrs") (attributeGrid frame)

  -- §10: cyan on the gutter, the left edge, the top edge, the bottom edge and
  -- the title; the card's own status color on the right edge and the two
  -- right corners. Both vertical edges are '│' and both top corners sit on
  -- the same row, so only the attributes tell the halves apart.
  it "draws the selected card's split cyan/status border" $ do
    frame <- renderCase wideCase
    let theme = themeFor testOptions
        cyan = attrMapLookup selectedAttr theme
        cyanTitle = attrMapLookup selectedTitleAttr theme
        status = attrMapLookup approvedAttr theme
        (top, left) = selectedCardCorner theme frame
        right = columnOf frame top left '╮'
        bottom = rowOf frame top left '╰'
        edge = [top + 1 .. bottom - 1]
        cells rowIndex columns = [cellAt frame rowIndex columnIndex | columnIndex <- columns]
        edgeCells columnIndex = [cellAt frame rowIndex columnIndex | rowIndex <- edge]

    cellCharacters (cells top [left - 1]) `shouldBe` "▌"
    cellAttributes (cells top [left - 1]) `shouldBe` [cyan]

    cellCharacters (cells top [left, right]) `shouldBe` "╭╮"
    cellCharacters (cells bottom [left, right]) `shouldBe` "╰╯"
    cellAttributes (cells top [left]) `shouldBe` [cyan]
    cellAttributes (cells bottom [left]) `shouldBe` [cyan]
    cellAttributes (cells top [right]) `shouldBe` [status]
    cellAttributes (cells bottom [right]) `shouldBe` [status]

    cellCharacters (edgeCells left) `shouldBe` map (const '│') edge
    cellCharacters (edgeCells right) `shouldBe` map (const '│') edge
    cellAttributes (edgeCells left) `shouldBe` map (const cyan) edge
    cellAttributes (edgeCells right) `shouldBe` map (const status) edge

    -- The title is the card's first interior row, so its glyphs carry the
    -- selected-title attribute rather than the ordinary card-title one.
    let titleCells = [cell | cell <- cells (top + 1) [left + 2 .. right - 2], frameCellCharacter cell /= ' ']
    null titleCells `shouldBe` False
    cellAttributes titleCells `shouldBe` map (const cyanTitle) titleCells

    -- The runs between the corners are drawn by Brick's own 'hBorder', which
    -- applies 'Brick.Widgets.Border.hBorderAttr' over whatever attribute the
    -- card asked for. The theme names no @border@ attribute, so they land on
    -- the attribute map's default instead of the cyan §10 asks for on a top
    -- and bottom edge -- the same reason an unselected card's runs are not
    -- its status color either. That is a rendering defect rather than
    -- something this suite introduces, so it is recorded as it draws today;
    -- these frames are what will show the repair when one lands.
    let horizontal = cells top [left + 1 .. right - 1] <> cells bottom [left + 1 .. right - 1]
    cellCharacters horizontal `shouldBe` map (const '─') horizontal
    cellAttributes horizontal `shouldBe` map (const Vty.defAttr) horizontal

  it "colors the pull-request cards red, amber and green by readiness" $ do
    frame <- renderCase wideCase
    let theme = themeFor testOptions
    cardStatusAttribute frame "PR #851" `shouldBe` attrMapLookup problemAttr theme
    cardStatusAttribute frame "PR #861" `shouldBe` attrMapLookup pendingAttr theme
    cardStatusAttribute frame "PR #823" `shouldBe` attrMapLookup readyAttr theme

  it "shows every fixture state the suite claims to cover" $ do
    frames <- traverse renderCase frameCases
    let everything = concatMap frameText frames
    filter (not . (`isInfixOf` everything)) requiredFixtureStates `shouldBe` []

  it "hides a collapsed tracker's children" $ do
    rendered <- frameText <$> renderCase wideCase
    ("▸ #701" `isInfixOf` rendered, "#721" `isInfixOf` rendered) `shouldBe` (True, False)

  -- §6: the search box is part of the Issues column's own layout flow. It
  -- sits above the cards, moves them down by exactly its own height, stays
  -- inside its column, and never reaches the footer.
  it "draws the search box above the cards, inside the Issues column, clear of the footer" $ do
    plain <- renderCase wideCase
    searched <- renderCase searchEmptyCase
    let box = searchBox searched
        height = box.searchBoxBottom - box.searchBoxTop + 1

    -- Two border rows around one content line, which is what an empty query
    -- occupies.
    height `shouldBe` 3

    -- Above the cards, which moved down by the box and the blank row it keeps
    -- between itself and them.
    box.searchBoxBottom `shouldSatisfy` (< firstCardRow searched box)
    firstCardRow searched box - firstCardRow plain box `shouldBe` height + 1

    -- Inside the column: every cell it draws lies between the board rule that
    -- opens Issues and the one that closes it.
    let (columnLeft, columnRight) = issuesColumnBounds searched
    (columnLeft < box.searchBoxLeft, box.searchBoxRight < columnRight) `shouldBe` (True, True)

    -- And nothing outside that column moved.
    fst (frameTextAt searched "#799") `shouldBe` fst (frameTextAt plain "#799")

    -- Clear of the footer's hint line, which the board never draws over.
    box.searchBoxBottom `shouldSatisfy` (< fst (frameTextAt searched "x kill"))

  it "grows the box by exactly the rows its wrapped query needs" $ do
    empty <- renderCase searchEmptyCase
    filtered <- renderCase searchFilteredCase
    wrapped <- renderCase (frameCaseNamed "search-wrapped-narrow")
    let rowsOf frame = (searchBox frame).searchBoxBottom - (searchBox frame).searchBoxTop - 1
    -- The wide column holds this query on one line; the 32-cell minimum
    -- column does not, so its box is taller by exactly the rows it needs.
    (rowsOf empty, rowsOf filtered) `shouldBe` (1, 1)
    rowsOf wrapped `shouldSatisfy` (> 1)
    -- The query wrapped, and the card it matched is drawn under the box.
    (isInfixOf "repository" (frameText wrapped), isInfixOf "#901" (frameText wrapped)) `shouldBe` (True, True)

  it "counts the results over the column's total while a query is live" $ do
    empty <- frameText <$> renderCase searchEmptyCase
    filtered <- frameText <$> renderCase searchFilteredCase
    (isInfixOf "ISSUES  5" empty, isInfixOf "ISSUES  5/5" empty) `shouldBe` (True, False)
    (isInfixOf "ISSUES  1/5" filtered, isInfixOf "envelope" filtered) `shouldBe` (True, True)

  it "shows No matches, not No items, for a query nothing matched" $ do
    missing <- frameText <$> renderCase (frameCaseNamed "search-no-matches")
    (isInfixOf "No matches" missing, isInfixOf "No items" missing) `shouldBe` (True, False)

  it "exposes a match under the collapsed epic without expanding the saved set" $ do
    exposed <- frameText <$> renderCase (frameCaseNamed "search-collapsed-child")
    -- #721 lives under epic #701, which the resting state leaves collapsed
    -- and the wide frame therefore hides.
    (isInfixOf "#701" exposed, isInfixOf "#721" exposed) `shouldBe` (True, True)
    wide <- frameText <$> renderCase wideCase
    isInfixOf "#721" wide `shouldBe` False

-- | Text the frames, taken together, have to contain. This is what stops a
-- fixture state from counting as covered while it sits below a column
-- viewport's fixed height, never rendered.
requiredFixtureStates :: [String]
requiredFixtureStates =
  [ "STANDALONE", -- the standalone section header
    "#901", -- a standalone issue in Issues
    "#799", -- a standalone issue in Active
    "DRAFT #847", -- a standalone draft pull request in Reviewing
    "PR #823", -- a standalone pull request in Done
    "▾ #700", -- an expanded tracker
    "#711", -- which is why its child is on the board at all
    "▸ #701", -- and a collapsed one beside it
    "#812", -- the approved issue
    "reviewed:approve", -- carrying its approval chip
    "UNLINKED" -- the pull request GitHub reported no linked issue for
  ]

-- | One captured frame: what it is called, how large the terminal is, and
-- what it changes about the resting state.
data FrameCase = FrameCase
  { frameCaseName :: String,
    frameCaseWidth :: Int,
    frameCaseHeight :: Int,
    frameCaseSummary :: String,
    frameCaseState :: AppState -> AppState
  }

-- | The three sizes §6 names, plus a frame for every remaining border mode
-- and overlay the contract requires. §6 puts the four-column threshold at 134
-- board cells, which the 28-cell sidebar and the shell border make a 164-cell
-- terminal, so the minimum case is exactly 164 wide and the wide case is
-- strictly wider.
frameCases :: [FrameCase]
frameCases =
  [ wideCase,
    FrameCase
      { frameCaseName = "board-minimum",
        frameCaseWidth = 164,
        frameCaseHeight = 64,
        frameCaseSummary = "the four-column minimum, 134 board cells",
        frameCaseState = id
      },
    FrameCase
      { frameCaseName = "board-narrow",
        frameCaseWidth = 36,
        frameCaseHeight = 40,
        frameCaseSummary = "one board column at a time, sidebar hidden",
        frameCaseState = \state -> state {appSidebarVisible = False}
      },
    FrameCase
      { frameCaseName = "board-open-borders",
        frameCaseWidth = 164,
        frameCaseHeight = 48,
        frameCaseSummary = "--border open, gutters and rules instead of vertical runs",
        frameCaseState = withOptions (\options -> options {optionBorder = BorderOpen})
      },
    FrameCase
      { frameCaseName = "board-ascii",
        frameCaseWidth = 164,
        frameCaseHeight = 48,
        frameCaseSummary = "--ascii, no box drawing anywhere",
        frameCaseState = withOptions (\options -> options {optionAscii = True})
      },
    FrameCase
      { frameCaseName = "overlay-details",
        frameCaseWidth = 200,
        frameCaseHeight = 48,
        frameCaseSummary = "the details overlay over the wide board",
        frameCaseState = \state -> state {appOverlay = Just (DetailsOverlay (fixtureItem 823))}
      },
    FrameCase
      { frameCaseName = "overlay-help",
        frameCaseWidth = 200,
        frameCaseHeight = 48,
        frameCaseSummary = "the help overlay over the wide board",
        frameCaseState = \state -> state {appOverlay = Just HelpOverlay}
      },
    searchEmptyCase,
    searchFilteredCase,
    FrameCase
      { frameCaseName = "search-collapsed-child",
        frameCaseWidth = 200,
        frameCaseHeight = 64,
        frameCaseSummary = "a match under the collapsed epic, exposed without expanding it",
        frameCaseState = searching "pointer"
      },
    FrameCase
      { frameCaseName = "search-no-matches",
        frameCaseWidth = 200,
        frameCaseHeight = 64,
        frameCaseSummary = "a query nothing matches, distinct from an empty column",
        frameCaseState = searching "no such card"
      },
    FrameCase
      { frameCaseName = "search-wrapped-narrow",
        frameCaseWidth = 36,
        frameCaseHeight = 40,
        frameCaseSummary = "a query too long for one line, wrapped in the narrowest column",
        frameCaseState = \state -> searching wrappingQuery state {appSidebarVisible = False}
      },
    FrameCase
      { frameCaseName = "search-open-borders",
        frameCaseWidth = 164,
        frameCaseHeight = 48,
        frameCaseSummary = "--border open, the box between the column rule and its cards",
        frameCaseState = searching "envelope" . withOptions (\options -> options {optionBorder = BorderOpen})
      },
    FrameCase
      { frameCaseName = "search-ascii",
        frameCaseWidth = 164,
        frameCaseHeight = 48,
        frameCaseSummary = "--ascii, the box drawn without box glyphs",
        frameCaseState = searching "envelope" . withOptions (\options -> options {optionAscii = True})
      }
  ]

-- | An open, empty search box over the wide board.
searchEmptyCase :: FrameCase
searchEmptyCase =
  FrameCase
    { frameCaseName = "search-empty",
      frameCaseWidth = 200,
      frameCaseHeight = 64,
      frameCaseSummary = "an open search box with an empty query, over the complete column",
      frameCaseState = searching ""
    }

-- | The same board with a query that leaves one card standing.
searchFilteredCase :: FrameCase
searchFilteredCase =
  FrameCase
    { frameCaseName = "search-filtered",
      frameCaseWidth = 200,
      frameCaseHeight = 64,
      frameCaseSummary = "a query that filters Issues to one result under a tracker header",
      frameCaseState = searching "envelope"
    }

-- | Long enough to wrap in the 32-cell minimum column §6 names, so the box
-- there is more than one content line tall — and still a match, so that frame
-- shows the taller box with the card it left standing under it.
wrappingQuery :: Text
wrappingQuery = "add repository snapshot cache"

-- | Open search on Issues and type @query@ into it, exactly as the
-- transitions do, so a frame can never show a query state the interaction
-- cannot reach.
searching :: Text -> AppState -> AppState
searching query state =
  Data.Text.foldl'
    (\current character -> applySearchInput (SearchInsert character) current)
    (openSearch state)
    query

-- | The reference frame: wider than the four-column threshold, with the
-- approved issue selected so the §10 split border is in it.
wideCase :: FrameCase
wideCase =
  FrameCase
    { frameCaseName = "board-wide",
      frameCaseWidth = 200,
      frameCaseHeight = 64,
      frameCaseSummary = "wider than the four-column threshold",
      frameCaseState = id
    }

frameCaseSpec :: FrameCase -> Spec
frameCaseSpec frameCase =
  it ("renders " <> frameCase.frameCaseName <> " — " <> frameCase.frameCaseSummary) $ do
    frame <- renderCase frameCase
    length frame `shouldBe` frameCase.frameCaseHeight
    expectGolden (goldenPath (frameCase.frameCaseName <> ".txt")) (map (Data.Text.stripEnd . frameRowText) frame)

renderCase :: FrameCase -> IO [[FrameCell]]
renderCase frameCase = do
  -- Nothing here writes to or reads from the channel; the application state
  -- carries one and drawing never touches it.
  channel <- newBChan 1
  let state = frameCase.frameCaseState (restingState channel)
  pure (renderFrameCells (themeFor state.appOptions) (frameCase.frameCaseWidth, frameCase.frameCaseHeight) (drawApplication state))

withOptions :: (Options -> Options) -> AppState -> AppState
withOptions change state = state {appOptions = change state.appOptions}

-- | The state every case starts from: the fixture board, the fixture usage
-- snapshots, and a resting value for everything else that can reach a frame.
restingState :: BChan AppEvent -> AppState
restingState channel =
  AppState
    { appRepository = Repository "/fixture/kanban" "coghex" "kanban",
      appBoard = fixtureBoard,
      appUsage = fixtureUsage,
      appUsageFreshness = Map.map (Fresh . (.usageFetchedAt)) fixtureUsage,
      appSelectedColumn = Issues,
      appSelectedRows = Map.insert Issues (fixtureRow Issues 812) (Map.fromList [(column, 0) | column <- [minBound .. maxBound]]),
      appEnsureSelectionVisible = True,
      appExpandedTrackers = Set.singleton 700,
      appSearch = Nothing,
      appSidebarVisible = True,
      appSettings = defaultSettings,
      appLogRoot = "/fixture/logs",
      appProcessSelection = ProcessSelection Nothing 0,
      appIncidentSelection = IncidentSelection Nothing 0,
      appOverlay = Nothing,
      appNotice = Just "Cached GitHub snapshot loaded · press u to update",
      appBoardFreshness = Fresh goldenFetchedAt,
      appLastSuccessfulFetch = Just goldenFetchedAt,
      appIssuesTruncated = False,
      appPullRequestsTruncated = False,
      appDrainerController = Left "no drainer controller in the fixture",
      appDrainerStatus = DrainerStatus DrainerOff "off" DrainerServiceStopped Nothing,
      -- No controller, so no observation stands: the same unanswered source
      -- a failed discovery leaves behind.
      appDrainerIncidents = Nothing,
      appDrainerBusy = False,
      appDirectMergePending = Nothing,
      appDirectMergeResult = Nothing,
      appBoardRefreshQueued = False,
      appReviewBackend = ReviewBackendStopped,
      appReviewSessions = Map.empty,
      appSolveSessions = Map.empty,
      appSolveProcesses = Map.empty,
      appCanonicalReviewProcesses = Map.empty,
      appPullRequestReviewSessions = Map.empty,
      appPullRequestProcesses = Map.empty,
      appWorkers = Map.empty,
      appWorkerMonitors = Set.empty,
      appEventChannel = channel,
      appNow = goldenNow,
      appTimeZone = utc,
      appOptions = testOptions,
      appConfig = testResolvedConfig
    }

-- | When the fixture snapshot was fetched, and when the frames are drawn:
-- three hours later, so every relative age renders from fixed inputs rather
-- than from the clock.
goldenFetchedAt, goldenNow :: UTCTime
goldenFetchedAt = UTCTime (fromGregorian 2026 7 16) (secondsToDiffTime (12 * 3600))
goldenNow = UTCTime (fromGregorian 2026 7 16) (secondsToDiffTime (15 * 3600))

fixtureEntries :: BoardColumn -> [ColumnEntry]
fixtureEntries column = Map.findWithDefault [] column fixtureBoard.boardColumns

-- | Where an item sits in its column, asked of the board rather than written
-- down, so a changed sort moves the selection with it instead of quietly
-- selecting a different card.
fixtureRow :: BoardColumn -> Int -> Int
fixtureRow column number =
  case findIndex ((== Just number) . entryNumber) (fixtureEntries column) of
    Just row -> row
    Nothing -> error ("the fixture board has no #" <> show number <> " in " <> show column)

fixtureItem :: Int -> BoardItem
fixtureItem number =
  case [item | column <- [minBound .. maxBound], entry <- fixtureEntries column, Just item <- [entryItem entry], itemNumber item == number] of
    item : _ -> item
    [] -> error ("the fixture board has no #" <> show number)

entryItem :: ColumnEntry -> Maybe BoardItem
entryItem (Standalone item) = Just item
entryItem (Tracked _ item) = Just item
entryItem (TrackerHeader _) = Nothing

entryNumber :: ColumnEntry -> Maybe Int
entryNumber = fmap itemNumber . entryItem

allCharacters :: [[[FrameCell]]] -> [Char]
allCharacters frames = [frameCellCharacter cell | frame <- frames, row <- frame, cell <- row]

frameText :: [[FrameCell]] -> String
frameText = concatMap (Data.Text.unpack . frameRowText)

cellCharacters :: [FrameCell] -> [Char]
cellCharacters = map frameCellCharacter

cellAttributes :: [FrameCell] -> [Vty.Attr]
cellAttributes = map frameCellAttribute

frameRow :: [[FrameCell]] -> Int -> [FrameCell]
frameRow frame rowIndex = case drop rowIndex frame of
  row : _ -> row
  [] -> error ("the frame has no row " <> show rowIndex)

cellAt :: [[FrameCell]] -> Int -> Int -> FrameCell
cellAt frame rowIndex columnIndex = case drop columnIndex (frameRow frame rowIndex) of
  cell : _ -> cell
  [] -> error ("the frame has no cell at row " <> show rowIndex <> ", column " <> show columnIndex)

-- | The one card drawn with a selected top-left corner. More than one would
-- mean the frame shows two selections, which is itself worth failing on.
selectedCardCorner :: AttrMap -> [[FrameCell]] -> (Int, Int)
selectedCardCorner theme frame = case corners of
  [corner] -> corner
  _ -> error ("expected exactly one selected card corner, found " <> show (length corners))
  where
    cyan = attrMapLookup selectedAttr theme
    corners =
      [ (rowIndex, columnIndex)
      | (rowIndex, row) <- zip [0 ..] frame,
        (columnIndex, cell) <- zip [0 ..] row,
        frameCellCharacter cell == '╭',
        frameCellAttribute cell == cyan
      ]

-- | The column of the first @character@ strictly right of @fromColumn@.
columnOf :: [[FrameCell]] -> Int -> Int -> Char -> Int
columnOf frame rowIndex fromColumn character =
  case [column | (column, cell) <- drop (fromColumn + 1) (zip [0 ..] (frameRow frame rowIndex)), frameCellCharacter cell == character] of
    column : _ -> column
    [] -> error ("no " <> [character] <> " right of column " <> show fromColumn <> " on row " <> show rowIndex)

-- | The row of the first @character@ strictly below @fromRow@ in @columnIndex@.
rowOf :: [[FrameCell]] -> Int -> Int -> Char -> Int
rowOf frame fromRow columnIndex character =
  case [row | (row, _) <- drop (fromRow + 1) (zip [0 ..] frame), frameCellCharacter (cellAt frame row columnIndex) == character] of
    row : _ -> row
    [] -> error ("no " <> [character] <> " below row " <> show fromRow <> " in column " <> show columnIndex)

-- | Where the search box's own border runs in a frame.
data SearchBoxExtent = SearchBoxExtent
  { searchBoxTop :: Int,
    searchBoxBottom :: Int,
    searchBoxLeft :: Int,
    searchBoxRight :: Int
  }
  deriving stock (Eq, Show)

-- | The box, located from its label and then followed down its own left edge.
-- Its square corners are its alone: §10 cards draw rounded ones, so nothing
-- else in a frame can be mistaken for it.
searchBox :: [[FrameCell]] -> SearchBoxExtent
searchBox frame = SearchBoxExtent top (rowOf frame top left '└') left (columnOf frame top left '┐')
  where
    top = fst (frameTextAt frame "SEARCH")
    left = columnOf frame top (-1) '┌'

-- | The row the first card in the Issues column starts on, found by its
-- rounded top-left corner inside the cells the search box occupies.
firstCardRow :: [[FrameCell]] -> SearchBoxExtent -> Int
firstCardRow frame box = case rows of
  row : _ -> row
  [] -> error "the frame draws no card in the Issues column"
  where
    rows =
      [ rowIndex
      | (rowIndex, row) <- zip [0 ..] frame,
        (columnIndex, cell) <- zip [0 ..] row,
        columnIndex >= box.searchBoxLeft,
        columnIndex <= box.searchBoxRight,
        frameCellCharacter cell == '╭'
      ]

-- | The cells the Issues column is bounded by, read off the board's own top
-- rule: the corner that opens the board and the junction that closes its
-- first column.
issuesColumnBounds :: [[FrameCell]] -> (Int, Int)
issuesColumnBounds frame = (left, columnOf frame boardTop left '┳')
  where
    boardTop = fst (frameTextAt frame "ISSUES")
    left = columnOf frame boardTop (-1) '┏'

-- | Where a piece of text first appears: its row, and the cell it starts at.
frameTextAt :: [[FrameCell]] -> Text -> (Int, Int)
frameTextAt frame needle = case locations of
  location : _ -> location
  [] -> error ("the frame does not contain " <> Data.Text.unpack needle)
  where
    locations =
      [ (rowIndex, Data.Text.length leading)
      | (rowIndex, row) <- zip [0 ..] frame,
        let (leading, trailing) = Data.Text.breakOn needle (frameRowText row),
        not (Data.Text.null trailing)
      ]

frameCaseNamed :: String -> FrameCase
frameCaseNamed name = case filter ((== name) . frameCaseName) frameCases of
  frameCase : _ -> frameCase
  [] -> error ("no frame case named " <> name)

-- | The attribute of the card border right of @heading@: the status half of
-- the §10 split, which an unselected card draws all the way round and a
-- selected one keeps only on its right edge.
cardStatusAttribute :: [[FrameCell]] -> Text -> Vty.Attr
cardStatusAttribute frame heading = case locations of
  (rowIndex, columnIndex) : _ -> frameCellAttribute (cellAt frame rowIndex (columnOf frame rowIndex columnIndex '│'))
  [] -> error ("no card headed " <> Data.Text.unpack heading <> " in the frame")
  where
    locations =
      [ (rowIndex, Data.Text.length leading)
      | (rowIndex, row) <- zip [0 ..] frame,
        let (leading, trailing) = Data.Text.breakOn heading (frameRowText row),
        not (Data.Text.null trailing)
      ]
