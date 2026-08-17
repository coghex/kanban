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
import Data.List (findIndex, isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime, utc)
import qualified Graphics.Vty.Attributes as Vty
import Kanban.ApprovalService
  ( ApprovalActivity (..),
    ApprovalState (..),
    ApprovalStatus (..),
    ApprovalUnavailable (..),
  )
import Kanban.CLI (BorderPolicy (..), Options (..))
import Data.IORef (IORef, newIORef)
import Kanban.Card (displayWidth)
import Kanban.Domain
import Kanban.Drainer (DrainerActivity (..), DrainerState (..), DrainerStatus (..))
import Kanban.Filter
  ( FilterBox (..),
    KindFacet (..),
    LifecycleFacet (..),
    boardEntryCount,
    defaultFilterCriteria,
  )
import Kanban.Fixture (fixtureBoard, fixtureCompletedHistory, fixtureSnapshot, fixtureUsage)
import Kanban.GitHub (HistoryTraversal, RefreshCoordinator, newHistoryTraversal)
import Kanban.Settings (defaultSettings)
import Kanban.UI (drawApplication)
import Kanban.UI.Board
  ( completedLoadingHeading,
    completedUnavailableHeading,
    openDataLoadingHeading,
    openDataUnavailableHeading,
  )
import Kanban.UI.Filter (focusFilterPanel, refreshVisibleBoard, toggleFilterBoxFromClick, toggleFilterPanel)
import Kanban.UI.Keys (BoardAction (..), actionKeyText)
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
    BoardRefreshOutcome,
    CompletedHistoryStatus (..),
    IncidentSelection (..),
    Overlay (..),
    ProcessSelection (..),
    ReviewBackend (..),
  )
import Spec.Support.Board (inertRefreshCoordinator)
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

  -- §7: a blocking panel replaces the board rather than covering it. The
  -- fixture board is in state throughout, so what these prove is that a board
  -- no complete generation has published draws none of it -- not that there
  -- happened to be nothing to draw.
  it "draws no card from any source while either blocking panel is up, at every setting" $ do
    frames <- traverse renderCase openDataCases
    let leaked =
          [ (frameCase.frameCaseName, number)
          | (frameCase, frame) <- zip openDataCases frames,
            number <- fixtureNumbers,
            Data.Text.pack ("#" <> show number) `Data.Text.isInfixOf` frameLines frame
          ]
    leaked `shouldBe` []

  it "names the loading panel in every frame that draws it" $ do
    frames <- traverse renderCase (filter (isPanel "open-loading-") openDataCases)
    filter (not . Data.Text.isInfixOf openDataLoadingHeading . frameLines) frames `shouldBe` []

  -- The unavailable panel is the only thing on screen, so it has to carry
  -- both halves of §7's contract: the classified reason, and the key that
  -- retries.
  it "names the unavailable panel, its classified reason, and the retry key in every frame that draws it" $ do
    frames <- traverse renderCase (filter (isPanel "open-unavailable-") openDataCases)
    let missing expected = filter (not . Data.Text.isInfixOf expected . frameLines) frames
    mapM_
      (\expected -> missing expected `shouldBe` [])
      [openDataUnavailableHeading, "AUTH REQUIRED", "press " <> actionKeyText RefreshAll <> " to retry"]

  -- Requirement 8's other half: once one generation has completed, the board
  -- it published stays on screen through the next refresh and through its
  -- failure. Only the freshness marker and the notice move.
  it "keeps drawing the published board while a later refresh is loading or has failed" $ do
    let laterStates :: [(String, Freshness)]
        laterStates =
          [ ("loading", Loading),
            ("failed", Stale goldenFetchedAt "REQUEST ERROR: gh fell over")
          ]
    mapM_
      ( \(label, freshness) -> do
          frame <- renderCase wideCase {frameCaseState = \state -> state {appBoardFreshness = freshness}}
          let drawn = [number | number <- fixtureNumbers, Data.Text.pack ("#" <> show number) `Data.Text.isInfixOf` frameLines frame]
          (label, null drawn) `shouldBe` (label, False)
      )
      laterStates

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

    -- Clear of the footer's hint line, which the board never draws over. The
    -- line an open search shows is its own, so this names a chip of that one
    -- rather than of the base board's.
    box.searchBoxBottom `shouldSatisfy` (< fst (frameTextAt searched "s/esc close"))

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

  -- §7: a transfer moves the box out of Issues, empties the query, and leaves
  -- both columns whole again — so the frame that proves it has to be read for
  -- where the box is, not only for what it contains.
  it "draws the box in the column a transfer moved it to, with both headings whole" $ do
    filtered <- renderCase searchFilteredCase
    transferred <- renderCase searchTransferredCase
    let box = searchBox transferred
        (_, issuesRight) = issuesColumnBounds transferred
    -- Out of Issues entirely, and inside the column ACTIVE heads.
    box.searchBoxLeft `shouldSatisfy` (> issuesRight)
    snd (frameTextAt transferred "ACTIVE") `shouldSatisfy` (< box.searchBoxRight)
    -- Empty, where the frame it moved from still shows what was typed.
    boxContent filtered `shouldBe` "envelope"
    boxContent transferred `shouldBe` ""
    -- And both columns are counted whole, including the card the query had
    -- filtered away, back on the board.
    let rendered = frameText transferred
    (isInfixOf "ISSUES  5" rendered, isInfixOf "ISSUES  1/5" rendered) `shouldBe` (True, False)
    (isInfixOf "ACTIVE  3" rendered, isInfixOf "#901" rendered) `shouldBe` (True, True)

  it "shows No search matches, not No items, for a query nothing matched" $ do
    missing <- frameText <$> renderCase (frameCaseNamed "search-no-matches")
    (isInfixOf "No search matches" missing, isInfixOf "No items" missing) `shouldBe` (True, False)

  it "exposes a match under the collapsed epic without expanding the saved set" $ do
    exposed <- frameText <$> renderCase (frameCaseNamed "search-collapsed-child")
    -- #721 lives under epic #701, which the resting state leaves collapsed
    -- and the wide frame therefore hides.
    (isInfixOf "#701" exposed, isInfixOf "#721" exposed) `shouldBe` (True, True)
    wide <- frameText <$> renderCase wideCase
    isInfixOf "#721" wide `shouldBe` False

  -- §7: the defaults are the baseline, so the completed generation this suite
  -- now holds in memory reaches no frame that does not ask for it. Every board
  -- frame above is checked against the checked-in file it always had, and this
  -- states the reason directly rather than leaving it to those diffs.
  it "draws no completed card under the default criteria, with a whole history in memory" $ do
    frames <- traverse renderCase (wideCase : filter (isPanel "filter-panel-") filterCases)
    let leaked =
          [ number
          | frame <- frames,
            number <- completedNumbers,
            Data.Text.pack ("#" <> show number) `Data.Text.isInfixOf` frameLines frame
          ]
    leaked `shouldBe` []

  it "names all four groups, every value, and both figures in the panel" $ do
    panel <- frameText <$> renderCase (frameCaseNamed "filter-panel-wide")
    sequence_
      [ (fragment, fragment `isInfixOf` panel) `shouldBe` (fragment, True)
      | fragment <-
          ["State", "Kind", "Workflow", "Structure"]
            <> ["Open", "Closed", "Issues", "Pull requests", "Changes", "Problems", "Approved", "Other", "Epic groups", "Standalone"]
            <> ["showing ", " cards"]
      ]

  -- §7: every value starts checked except Closed, and the counts beside them
  -- predict a toggle rather than describing what is already showing — so the
  -- unchecked box carries the count of the history it would reveal.
  it "checks every box except Closed and counts what each one would admit" $ do
    panel <- Data.Text.unpack . frameLines <$> renderCase (frameCaseNamed "filter-panel-wide")
    sequence_
      [ (chip, chip `isInfixOf` panel) `shouldBe` (chip, True)
      | chip <-
          [ "[ ] Closed " <> show (length fixtureCompletedHistory.historyIssues + length fixtureCompletedHistory.historyPullRequests),
            "[x] Open " <> show (boardEntryCount fixtureBoard)
          ]
      ]

  it "keeps the query and both boxes on screen when the panel takes the keyboard" $ do
    stacked <- renderCase (frameCaseNamed "filter-and-search")
    boxContent stacked `shouldBe` "envelope"
    -- The panel is above the search box, which is above the cards it filters.
    let rendered = frameText stacked
    (isInfixOf "FILTER" rendered, isInfixOf "SEARCH" rendered) `shouldBe` (True, True)
    fst (frameTextAt stacked "FILTER") `shouldSatisfy` (< fst (frameTextAt stacked "SEARCH"))
    (searchBox stacked).searchBoxBottom `shouldSatisfy` (< firstCardRow stacked (searchBox stacked))
    -- And the panel's own hint line is what the footer shows, not search's.
    (isInfixOf "space toggle" rendered, isInfixOf "backspace delete" rendered) `shouldBe` (True, False)

  it "marks the footer chip while a non-default criteria set is hidden" $ do
    hidden <- frameText <$> renderCase (frameCaseNamed "filter-hidden-active")
    plain <- frameText <$> renderCase wideCase
    (isInfixOf "f filter*" hidden, isInfixOf "FILTER" hidden) `shouldBe` (True, False)
    (isInfixOf "f filter*" plain, isInfixOf "f filter" plain) `shouldBe` (False, True)
    -- The criteria are still in force behind the hidden panel: PR #823 is a
    -- pull request, and Kind now admits only issues.
    isInfixOf "PR #823" hidden `shouldBe` False

  it "says No filter matches, not No items or No search matches, for criteria that admit nothing" $ do
    empty <- frameText <$> renderCase (frameCaseNamed "filter-no-matches")
    (isInfixOf "No filter matches" empty, isInfixOf "No items" empty) `shouldBe` (True, False)
    isInfixOf "No search matches" empty `shouldBe` False

  it "draws the completed issues and pull requests, badged, with Open unchecked" $ do
    completed <- frameText <$> renderCase (frameCaseNamed "filter-completed-only")
    sequence_
      [ (fragment, fragment `isInfixOf` completed) `shouldBe` (fragment, True)
      | fragment <- ["#655", "#690", "PR #705", "PR #688", "CLOSED", "MERGED"]
      ]
    -- Nothing open survives an unchecked Open box.
    filter (\number -> isInfixOf ("#" <> show number) completed) fixtureNumbers `shouldBe` []

  it "replaces the whole card area while a completed generation is still running" $ do
    blocked <- renderCase (frameCaseNamed "filter-completed-loading")
    let rendered = frameLines blocked
    Data.Text.isInfixOf completedLoadingHeading rendered `shouldBe` True
    -- The traversal's own figures, and no invented denominator.
    Data.Text.isInfixOf "46 of 149 loaded" rendered `shouldBe` True
    -- The panel that put the blocker up is still there to take it down.
    Data.Text.isInfixOf "FILTER" rendered `shouldBe` True

  it "reports a completed failure with no fallback as a card-free panel" $ do
    failed <- frameLines <$> renderCase (frameCaseNamed "filter-completed-unavailable")
    sequence_
      [ (fragment, fragment `Data.Text.isInfixOf` failed) `shouldBe` (fragment, True)
      | fragment <- [completedUnavailableHeading, "RATE LIMITED", "history: failed"]
      ]

  it "draws no card from any source under either completed panel" $ do
    frames <- traverse renderCase [frameCaseNamed "filter-completed-loading", frameCaseNamed "filter-completed-unavailable"]
    let leaked =
          [ number
          | frame <- frames,
            number <- fixtureNumbers <> completedNumbers,
            Data.Text.pack ("#" <> show number) `Data.Text.isInfixOf` frameLines frame
          ]
    leaked `shouldBe` []

  -- Requirement 8's compact status, on the one row that is always on screen.
  it "states where the completed generation stands in the footer" $ do
    current <- frameLines <$> renderCase wideCase
    loading <- frameLines <$> renderCase (frameCaseNamed "filter-completed-loading")
    Data.Text.isInfixOf "history: current" current `shouldBe` True
    Data.Text.isInfixOf "history: loading 46/149" loading `shouldBe` True

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

-- | Every item number the fixture board draws, asked of the board rather than
-- written down, so a changed fixture cannot quietly narrow what the panel
-- frames are checked against.
fixtureNumbers :: [Int]
fixtureNumbers =
  [ number
  | column <- [minBound .. maxBound],
    entry <- fixtureEntries column,
    Just number <- [entryNumber entry]
  ]

-- | Every item number the seeded completed generation holds, asked of the
-- history itself for the same reason.
completedNumbers :: [Int]
completedNumbers =
  map (.issueNumber) fixtureCompletedHistory.historyIssues
    <> map (.pullRequestNumber) fixtureCompletedHistory.historyPullRequests

-- | A frame as one searchable block of text, rows separated by newlines.
frameLines :: [[FrameCell]] -> Text
frameLines frame = Data.Text.unlines (map frameRowText frame)

isPanel :: String -> FrameCase -> Bool
isPanel prefix frameCase = prefix `isPrefixOf` frameCase.frameCaseName

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
    searchTransferredCase,
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
    <> openDataCases
    <> filterCases

-- | §7's two blocking panels at every setting the populated board is captured
-- at, because a panel that replaces the board has to survive the same
-- responsive and border decisions the board does.
--
-- Both are applied over the fixture board rather than an empty one, so what
-- the frames show is not that there was nothing to draw: it is that a board
-- no complete generation has published draws none of it.
openDataCases :: [FrameCase]
openDataCases =
  [ FrameCase
      { frameCaseName = openDataName panel setting,
        frameCaseWidth = setting.settingWidth,
        frameCaseHeight = setting.settingHeight,
        frameCaseSummary = panelSummary panel <> ", " <> setting.settingSummary,
        frameCaseState = setting.settingState . panelState panel
      }
  | panel <- [OpenDataLoadingPanel, OpenDataUnavailablePanel],
    setting <- frameSettings
  ]

data OpenDataPanel = OpenDataLoadingPanel | OpenDataUnavailablePanel

openDataName :: OpenDataPanel -> FrameSetting -> String
openDataName OpenDataLoadingPanel setting = "open-loading-" <> setting.settingName
openDataName OpenDataUnavailablePanel setting = "open-unavailable-" <> setting.settingName

panelSummary :: OpenDataPanel -> String
panelSummary OpenDataLoadingPanel = "the initial loading panel"
panelSummary OpenDataUnavailablePanel = "the OPEN DATA UNAVAILABLE panel"

-- | Both panels stand for a board no generation has published, which is
-- exactly 'appLastSuccessfulFetch' being unset; the freshness then decides
-- which of the two is drawn.
panelState :: OpenDataPanel -> AppState -> AppState
panelState OpenDataLoadingPanel state =
  state
    { appLastSuccessfulFetch = Nothing,
      appBoardFreshness = Loading,
      appNotice = Just "Refreshing GitHub…"
    }
panelState OpenDataUnavailablePanel state =
  state
    { appLastSuccessfulFetch = Nothing,
      appBoardFreshness = Unavailable unavailableReason,
      appNotice = Just ("GitHub refresh failed: " <> unavailableReason)
    }

unavailableReason :: Text
unavailableReason = "AUTH REQUIRED: gh: Bad credentials (HTTP 401)"

-- | One terminal size and border mode a frame can be captured at.
data FrameSetting = FrameSetting
  { settingName :: String,
    settingWidth :: Int,
    settingHeight :: Int,
    settingSummary :: String,
    settingState :: AppState -> AppState
  }

-- | The five settings the populated board is already captured at.
frameSettings :: [FrameSetting]
frameSettings =
  [ FrameSetting "wide" 200 64 "wider than the four-column threshold" id,
    FrameSetting "minimum" 164 64 "the four-column minimum" id,
    FrameSetting "narrow" 36 40 "one column at a time, sidebar hidden" (\state -> state {appSidebarVisible = False}),
    FrameSetting "open-borders" 164 48 "--border open" (withOptions (\options -> options {optionBorder = BorderOpen})),
    FrameSetting "ascii" 164 48 "--ascii" (withOptions (\options -> options {optionAscii = True}))
  ]

-- | The filter panel: at every setting the populated board is captured at,
-- because a panel that shifts the whole board down has to survive the same
-- responsive and border decisions the board does, and then once per behavior
-- §7 states for it.
--
-- Every one of these reaches its state through the panel's own transitions
-- rather than by writing criteria into the record, so no frame can show a
-- combination the interaction cannot produce.
filterCases :: [FrameCase]
filterCases =
  [ FrameCase
      { frameCaseName = "filter-panel-" <> setting.settingName,
        frameCaseWidth = setting.settingWidth,
        frameCaseHeight = setting.settingHeight,
        frameCaseSummary = "the filter panel over the board, " <> setting.settingSummary,
        frameCaseState = setting.settingState . toggleFilterPanel
      }
  | setting <- frameSettings
  ]
    <> [ FrameCase
           { frameCaseName = "filter-and-search",
             frameCaseWidth = 200,
             frameCaseHeight = 64,
             frameCaseSummary = "the panel and a live query stacked, the panel holding the keyboard",
             -- Exactly §7's transfer: lowercase `f` from an open search box
             -- moves the keyboard to the panel and leaves the query alone.
             frameCaseState = focusFilterPanel . searching "envelope"
           },
         FrameCase
           { frameCaseName = "filter-hidden-active",
             frameCaseWidth = 200,
             frameCaseHeight = 64,
             frameCaseSummary = "a non-default criteria set with the panel hidden, marked f filter* in the footer",
             frameCaseState = hidingPanel (withBoxes [KindBox KindPullRequests])
           },
         FrameCase
           { frameCaseName = "filter-no-matches",
             frameCaseWidth = 200,
             frameCaseHeight = 64,
             frameCaseSummary = "criteria admitting nothing, every column reporting No filter matches",
             frameCaseState = withBoxes [KindBox KindIssues, KindBox KindPullRequests]
           },
         FrameCase
           { frameCaseName = "filter-completed-only",
             frameCaseWidth = 200,
             frameCaseHeight = 64,
             frameCaseSummary = "Open off and Closed on: the completed issues and pull requests alone",
             frameCaseState = withBoxes [LifecycleBox LifecycleOpen, LifecycleBox LifecycleClosed]
           },
         FrameCase
           { frameCaseName = "filter-completed-loading",
             frameCaseWidth = 200,
             frameCaseHeight = 64,
             frameCaseSummary = "Closed checked while the completed generation is still running",
             frameCaseState = withBoxes [LifecycleBox LifecycleClosed] . loadingHistory
           },
         FrameCase
           { frameCaseName = "filter-completed-unavailable",
             frameCaseWidth = 200,
             frameCaseHeight = 64,
             frameCaseSummary = "Closed checked after a completed failure with no history behind it",
             frameCaseState = withBoxes [LifecycleBox LifecycleClosed] . failedHistory
           }
       ]

-- | Show the panel and toggle the named boxes through the click transition,
-- which is the same criteria edit the keyboard makes.
withBoxes :: [FilterBox] -> AppState -> AppState
withBoxes boxes state = foldl (flip toggleFilterBoxFromClick) (toggleFilterPanel state) boxes

-- | The same criteria with the panel put away again, which is the state the
-- footer's marker exists for.
hidingPanel :: (AppState -> AppState) -> AppState -> AppState
hidingPanel change = toggleFilterPanel . change

-- | A completed generation still running over the seeded history, exactly as
-- 'Kanban.UI.Refresh.startCompletedHistory' leaves the board.
loadingHistory :: AppState -> AppState
loadingHistory state =
  state
    { appCompletedStatus = CompletedHistoryLoading,
      appCompletedProgress = CompletedProgress 34 (Just 91) 12 (Just 58)
    }

-- | A completed generation that failed with nothing complete behind it, which
-- is the one failure that leaves no settled work to fall back to (§15).
failedHistory :: AppState -> AppState
failedHistory state =
  refreshVisibleBoard
    state
      { appCompletedHistory = Nothing,
        appCompletedStatus = CompletedHistoryFailed "RATE LIMITED: gh: API rate limit exceeded"
      }

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

-- | The same search moved on to Active, which is where §7's transfer leaves
-- it: the box drawn in a column that is not Issues, with the query it was
-- carrying emptied and both columns complete again.
searchTransferredCase :: FrameCase
searchTransferredCase =
  FrameCase
    { frameCaseName = "search-transferred",
      frameCaseWidth = 200,
      frameCaseHeight = 64,
      frameCaseSummary = "a search moved on to Active, its query cleared and both columns whole",
      frameCaseState = applySearchInput (SearchTransfer 1) . searching "envelope"
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
  refreshCoordinator <- inertRefreshCoordinator
  historyTraversal <- newHistoryTraversal
  approvalEpoch <- newIORef 0
  let state = frameCase.frameCaseState (restingState channel refreshCoordinator historyTraversal approvalEpoch)
  pure (renderFrameCells (themeFor state.appOptions) (frameCase.frameCaseWidth, frameCase.frameCaseHeight) (drawApplication state))

withOptions :: (Options -> Options) -> AppState -> AppState
withOptions change state = state {appOptions = change state.appOptions}

-- | The state every case starts from: the fixture board, the fixture usage
-- snapshots, and a resting value for everything else that can reach a frame.
restingState :: BChan AppEvent -> RefreshCoordinator BoardRefreshOutcome -> HistoryTraversal -> IORef Int -> AppState
restingState channel refreshCoordinator historyTraversal approvalEpoch =
  AppState
    { appRepository = Repository "/fixture/kanban" "coghex" "kanban",
      appBoard = fixtureBoard,
      -- The default criteria admit the open board unchanged, so every golden
      -- frame is drawn from exactly the board it always was.
      appVisibleBoard = fixtureBoard,
      appFilterCriteria = defaultFilterCriteria,
      appFilterPanel = Nothing,
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
      appOpenGeneration = 0,
      -- Both generations have published, which is what a board with a
      -- recorded fetch and a current history means. The completed one is held
      -- in memory and drawn nowhere: under the default criteria every frame
      -- below is the open board exactly as it always was, which is the whole
      -- point of capturing it beside a loaded history rather than instead of
      -- one.
      appOpenSnapshot = Just fixtureSnapshot,
      appHistoryTraversal = historyTraversal,
      appCompletedHistory = Just fixtureCompletedHistory,
      appCompletedGeneration = 0,
      appCompletedProgress = emptyCompletedProgress,
      appCompletedStatus = CompletedHistoryCurrent,
      appDrainerController = Left "no drainer controller in the fixture",
      appDrainerStatus = DrainerStatus DrainerOff "off" DrainerServiceStopped Nothing,
      -- No controller, so no observation stands: the same unanswered source
      -- a failed discovery leaves behind.
      appDrainerIncidents = Nothing,
      appDrainerBusy = False,
      appApprovalController = Left (ApprovalUndiscoverable "no issue approval service in tests"),
      appApprovalStatus = ApprovalStatus ApprovalOff "off" ApprovalServiceStopped Nothing Nothing,
      appApprovalIncidents = Just [],
      appApprovalBusy = False,
      appApprovalTransition = 0,
      appApprovalEpoch = approvalEpoch,
      appApprovalResult = Nothing,
      appDirectMergePending = Nothing,
      appDirectMergeResult = Nothing,
      appBoardRefreshQueued = False,
      appRefreshCoordinator = refreshCoordinator,
      appQuitPending = False,
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

-- | The query the box is showing, read off the cells inside its own border.
boxContent :: [[FrameCell]] -> Text
boxContent frame =
  Data.Text.strip . Data.Text.pack $
    [ frameCellCharacter (cellAt frame rowIndex columnIndex)
    | let box = searchBox frame,
      rowIndex <- [box.searchBoxTop + 1 .. box.searchBoxBottom - 1],
      columnIndex <- [box.searchBoxLeft + 1 .. box.searchBoxRight - 1]
    ]

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
