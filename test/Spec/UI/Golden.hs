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
import Brick.AttrMap (AttrName, attrMapLookup)
import Brick.BChan (BChan, newBChan)
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.List (findIndex, intercalate, isInfixOf, isPrefixOf, nub)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime, utc)
import qualified Graphics.Vty.Attributes as Vty
import qualified Graphics.Vty.Input.Events as VtyInput
import Kanban.ApprovalService
  ( ApprovalActivity (..),
    ApprovalBackend (..),
    ApprovalController (..),
    ApprovalState (..),
    ApprovalStatus (..),
    ApprovalUnavailable (..),
    approvalBarrierSummary,
    decodeApprovalStatus,
  )
import Kanban.CLI (BorderPolicy (..), ColorPolicy (..), Options (..))
import Data.IORef (IORef, newIORef)
import Kanban.Card (displayWidth)
import Kanban.Domain
import Kanban.Drainer (DrainerActivity (..), DrainerState (..), DrainerStatus (..), normalizedRepositoryIdentity)
import Kanban.Filter
  ( FilterBox (..),
    KindFacet (..),
    LifecycleFacet (..),
    boardEntryCount,
    defaultFilterCriteria,
  )
import Kanban.Fixture (fixtureBoard, fixtureCompletedHistory, fixtureSnapshot, fixtureUsage)
import Kanban.GitHub (HistoryTraversal, RefreshCoordinator, newHistoryTraversal)
import Kanban.Models
  ( ProviderName (..),
    RecordedAssignment,
    RoleName (..),
    RosterDefect (..),
    RosterFailure (..),
    RosterLoadError (..),
    defaultRoster,
    loadedOperatingMode,
  )
import Kanban.Solve (ResumeProvenance (..), SolveWorkflow (..), SolverBrand (..), solveAssignment)
import Kanban.Settings (defaultSettings)
import Kanban.UI (drawApplication)
import Kanban.UI.Approval (approvalStatusApplied, approvalTogglePress)
import Kanban.UI.Board
  ( approvalControlLabel,
    completedLoadingHeading,
    completedUnavailableHeading,
    drainerLabel,
    openDataLoadingHeading,
    openDataUnavailableHeading,
    updateLabel,
    usageSidebarInterior,
    usageSidebarWidth,
  )
import Kanban.UI.Filter (focusFilterPanel, refreshVisibleBoard, toggleFilterBoxFromClick, toggleFilterPanel)
import Kanban.UI.Keys (BoardAction (..), KeyBinding (..), actionKeyText, binding, footerHint)
import Kanban.UI.Search (SearchInput (..), applySearchInput, openSearch)
import Kanban.UI.Settings
  ( SettingsInput (..),
    SettingsOutcome (..),
    applyRosterWrite,
    openSettings,
    settingsOutcome,
  )
import Kanban.Review (ReviewStage (..))
import Kanban.UI.Theme
  ( approvedAttr,
    dimAttr,
    insertModeAttr,
    neutralAttr,
    pendingAttr,
    problemAttr,
    readyAttr,
    selectedAttr,
    selectedTitleAttr,
    themeFor,
  )
import Kanban.UI.SessionCore
  ( SessionFocus (..),
    SessionInputEvent (..),
    insertSessionInput,
    newAgentSession,
    removeSessionInputCharacter,
    sessionInputEvent,
    sessionModeAfter,
    setSessionMode,
  )
import Kanban.UI.Session (reviewSessionInputLive)
import Kanban.UI.SessionEvents (SessionOps (..), reviewSessionOps)
import Kanban.UI.Solve (freshSolveTranscript)
import Kanban.UI.State (plainTranscript)
import Kanban.UI.Types
  ( AgentSession (..),
    AppEvent,
    AppState (..),
    BoardRefreshOutcome,
    CompletedHistoryStatus (..),
    IncidentSelection (..),
    Overlay (..),
    ProcessSelection (..),
    ReviewBackend (..),
    ReviewDetail (..),
    ReviewPhase (..),
    ReviewSession,
    SolveDetail (..),
    SolvePhase (..),
    SolveSession,
    withModelRoster,
  )
import Spec.Support.Board (inertRefreshCoordinator)
import Spec.Support.Fixtures (itemNumber, testOptions, testResolvedConfig)
import Spec.Support.Golden (attributeGrid, expectGolden, goldenPath)
import Spec.Support.Render (FrameCell (..), frameRowText, renderFrameCells)
import Spec.Support.Roster (cellOf, claudeOnlyRoster, distinctDisplays, noAgentRoster)
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
        card = cardShowing unicodeCardGlyphs frame selectedCardText
        gutter = [cellAt frame card.cardTopRow (card.cardLeftColumn - 1)]

    -- Exactly one card in the frame draws a cyan corner, and it is the one
    -- located from its own text above.
    selectedCardCorner theme frame `shouldBe` (card.cardTopRow, card.cardLeftColumn)

    cellCharacters gutter `shouldBe` "▌"
    cellAttributes gutter `shouldBe` [cyan]

    expectCardBorder "selected wide" unicodeCardGlyphs frame card cyan status

    -- The title is the card's first interior row, so its glyphs carry the
    -- selected-title attribute rather than the ordinary card-title one.
    let titleCells =
          [ cell
          | columnIndex <- [card.cardLeftColumn + 2 .. card.cardRightColumn - 2],
            let cell = cellAt frame (card.cardTopRow + 1) columnIndex,
            frameCellCharacter cell /= ' '
          ]
    null titleCells `shouldBe` False
    cellAttributes titleCells `shouldBe` map (const cyanTitle) titleCells

  -- §10's other half: an unselected card has no cyan anywhere, so its whole
  -- border -- horizontal runs included -- is its own status color. Three
  -- cards with three different statuses, because a run that fell back to the
  -- attribute map's default could otherwise pass on a card whose status
  -- happened to be that default.
  it "draws every unselected card's whole border in its own status attribute" $ do
    frame <- renderCase wideCase
    let theme = themeFor testOptions
    mapM_
      ( \(label, needle, attribute) ->
          expectCardBorder
            (label <> " wide")
            unicodeCardGlyphs
            frame
            (cardShowing unicodeCardGlyphs frame needle)
            (attrMapLookup attribute theme)
            (attrMapLookup attribute theme)
      )
      unselectedCardCases

  -- The split is a color contract, and --ascii changes only glyphs, so every
  -- cell that was cyan or status-colored above still is. The runs are the
  -- half that has to be checked here: a card's corners and edges are drawn
  -- the same way in both modes, and its runs are the cells a border widget
  -- used to draw for it.
  it "keeps the selected split and the status borders when the glyphs are ASCII" $ do
    frame <- renderCase (frameCaseNamed "board-ascii")
    let theme = themeFor testOptions {optionAscii = True}
        cyan = attrMapLookup selectedAttr theme
        status = attrMapLookup approvedAttr theme
        card = cardShowing asciiCardGlyphs frame selectedCardText
        gutter = [cellAt frame card.cardTopRow (card.cardLeftColumn - 1)]

    cellCharacters gutter `shouldBe` ">"
    cellAttributes gutter `shouldBe` [cyan]

    expectCardBorder "selected ascii" asciiCardGlyphs frame card cyan status

    mapM_
      ( \(label, needle, attribute) ->
          expectCardBorder
            (label <> " ascii")
            asciiCardGlyphs
            frame
            (cardShowing asciiCardGlyphs frame needle)
            (attrMapLookup attribute theme)
            (attrMapLookup attribute theme)
      )
      unselectedCardCases

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
    (isInfixOf "F filter*" hidden, isInfixOf "FILTER" hidden) `shouldBe` (True, False)
    (isInfixOf "F filter*" plain, isInfixOf "F filter" plain) `shouldBe` (False, True)
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

  -- §6: the two service controls are one stack at the foot of the sidebar,
  -- the approval service above the drainer, each with its own detail line
  -- directly under its own box. Read off the frame rather than asserted about
  -- the widget tree, because the order they are drawn in is the whole claim.
  it "draws the approval control directly above the drainer control, each over its own detail" $ do
    frame <- renderCase wideCase
    let (approvalRow, approvalColumn) = controlAt frame approvalControlLabel
        (drainerRow, drainerColumn) = controlAt frame drainerLabel
    -- Three box rows and one detail line between the two label rows: the
    -- approval control's own box, its own status line, and then the drainer's
    -- box opening directly under it.
    drainerRow - approvalRow `shouldBe` 4
    approvalColumn `shouldBe` drainerColumn
    -- Each detail belongs to the box above it. The resting service is off, so
    -- both read "off" -- which is exactly why the rows have to be told apart
    -- by position rather than by text.
    approvalDetailText frame `shouldBe` "off"
    interiorRow frame drainerColumn (drainerRow + 2) `shouldBe` "off"

  -- Issue #521 requirement 4. The sidebar keeps its box, its heading, its
  -- width, and the two controls that still mean something; the provider blocks
  -- and the approval control go. Read off the drawn frame rather than off the
  -- widget tree, because "not drawn" is exactly what closes the approval
  -- control's click route: brick registers a clickable extent only for a
  -- widget a frame actually contains.
  it "keeps the sidebar's box, heading, width, and two live controls with no provider loaded" $ do
    quiet <- renderCase (frameCaseNamed "board-wide-no-agent")
    loaded <- renderCase wideCase
    sequence_
      [ (kept, kept `Data.Text.isInfixOf` sidebarText quiet) `shouldBe` (kept, True)
      | kept <- [" USAGE ", Data.Text.strip updateLabel, Data.Text.strip drainerLabel]
      ]
    -- The 28 cells §6 fixes: the drainer control opens in the same column it
    -- opens in on the loaded board, so the interior did not move.
    snd (controlAt quiet drainerLabel) `shouldBe` snd (controlAt loaded drainerLabel)

  it "draws neither provider block nor the approvals control with no provider loaded" $ do
    quiet <- renderCase (frameCaseNamed "board-wide-no-agent")
    loaded <- renderCase wideCase
    sequence_
      [ (gone, gone `Data.Text.isInfixOf` sidebarText quiet) `shouldBe` (gone, False)
      | gone <- providerSidebarText
      ]
    -- The negative control: every one of them is really there on the loaded
    -- board, so the absences above are the mode's doing rather than a fixture
    -- that never drew them.
    sequence_
      [ (gone, gone `Data.Text.isInfixOf` sidebarText loaded) `shouldBe` (gone, True)
      | gone <- providerSidebarText
      ]

  -- Requirement 1 on the two surfaces that name keys, over the whole drawn
  -- frame rather than over the projections "Spec.UI.Keys" holds -- a chip
  -- hidden from the line but still reaching the screen some other way would
  -- pass there and fail here.
  it "names none of the four agent bindings on a no-agent board or in its help overlay" $ do
    board <- renderCase (frameCaseNamed "board-wide-no-agent")
    help <- renderCase (frameCaseNamed "overlay-help-no-agent")
    loadedBoard <- renderCase wideCase
    loadedHelp <- renderCase (frameCaseNamed "overlay-help")
    sequence_
      [ (name, text, text `Data.Text.isInfixOf` frameLines frame) `shouldBe` (name, text, False)
      | (name, frame, texts) <- [("board" :: String, board, agentFooterChips), ("help", help, agentHelpDescriptions)],
        text <- texts
      ]
    -- The negative controls. Every help row really is drawn on a board that
    -- loads a provider, so the absences above are the mode's doing rather
    -- than text no frame ever carried.
    sequence_
      [ (description, description `Data.Text.isInfixOf` frameLines loadedHelp) `shouldBe` (description, True)
      | description <- agentHelpDescriptions
      ]
    -- The footer's is the same control with the line's existing clip
    -- accounted for: `txt` cuts the row at the terminal width (§6), and on
    -- the 200-cell wide board `a approvals` already sits past it, so the
    -- three chips ahead of the cut are what a loaded board draws at all.
    filter (`Data.Text.isInfixOf` frameLines loadedBoard) agentFooterChips
      `shouldBe` map
        (footerHint . binding)
        [ReviewSelection, SolveSelection, AutoSolveSelection]

    -- Requirement 1's other half, on the same two frames: the inspector and
    -- the kill key are drawn on a no-agent board and listed in its help
    -- overlay. Without this the assertion above would be satisfied by a
    -- projection that hid every agent surface, which is what issue #546 is
    -- correcting.
    sequence_
      [ (name, text, text `Data.Text.isInfixOf` frameLines frame) `shouldBe` (name, text, True)
      | (name, frame, texts) <- [("board" :: String, board, recoveryFooterChips), ("help", help, recoveryHelpDescriptions)],
        text <- texts
      ]

  -- issue #515 requirement 11's other half. The @.txt@ frames above carry the
  -- badge's text; only this carries its colour, and the colour is the whole
  -- difference between the two badges beyond one letter.
  it "draws the insert badge green and the normal badge dim, and neither under --color never" $ do
    let theme = themeFor testOptions
        badgeAttributes name badge = do
          frame <- renderCase (frameCaseNamed name)
          pure (cellAttributes (badgeCells frame badge))
    insert <- badgeAttributes "overlay-session-insert" "[I]"
    normal <- badgeAttributes "overlay-session-normal" "[N]"
    length insert `shouldBe` 3
    length normal `shouldBe` 3
    nub insert `shouldBe` [attrMapLookup insertModeAttr theme]
    nub normal `shouldBe` [attrMapLookup dimAttr theme]
    -- The two are genuinely different attributes, so a badge drawn in the
    -- wrong one cannot pass by both resolving to the same value.
    nub insert `shouldNotBe` nub normal

  it "leaves the insert badge colourless under --color never, like every attribute" $ do
    -- §10's colour policy, which 'themeFor' implements by mapping every name
    -- to the default rather than by omitting them.
    frame <-
      renderCase
        (frameCaseNamed "overlay-session-insert")
          { frameCaseState =
              withOptions (\options -> options {optionColor = ColorNever})
                . (frameCaseNamed "overlay-session-insert").frameCaseState
          }
    nub (cellAttributes (badgeCells frame "[I]")) `shouldBe` [Vty.defAttr]

  -- Requirement 2, which no @.txt@ golden can carry: the frames record
  -- characters and these record the colour each 'ApprovalState' is drawn in.
  -- Every constructor is covered, so a mapping cannot be added or repointed
  -- without a frame here naming it.
  it "colors the approval control by ApprovalState, in all six states" $ do
    let theme = themeFor testOptions
        expectations =
          [ ("off" :: String, wideCase, neutralAttr),
            ("on", frameCaseNamed "approval-on", readyAttr),
            ("starting", frameCaseNamed "approval-starting", pendingAttr),
            ("stopping", frameCaseNamed "approval-stopping", pendingAttr),
            ("warning", frameCaseNamed "approval-warning", pendingAttr),
            ("error", frameCaseNamed "approval-error", problemAttr)
          ]
    sequence_
      [ do
          frame <- renderCase frameCase
          let attributes = approvalControlAttributes frame
          (label, null attributes) `shouldBe` (label, False)
          (label, nub attributes) `shouldBe` (label, [attrMapLookup expected theme])
      | (label, frameCase, expected) <- expectations
      ]

  -- Requirement 3: the control renders what "Kanban.ApprovalService" and
  -- "Kanban.UI.Approval" composed, with nothing added on the way to the
  -- screen. Each of these is a distinct composition, and none of them is
  -- spelled anywhere in @src/Kanban/UI/Board.hs@.
  it "renders the approval detail line verbatim, in every state" $ do
    let expectations =
          [ (frameCaseNamed "approval-on", "on"),
            (frameCaseNamed "approval-starting", "starting…"),
            (frameCaseNamed "approval-stopping", "stopping…"),
            (frameCaseNamed "approval-warning", "on · unresolved incident · " <> approvalBarrierSummary 812),
            (frameCaseNamed "approval-error", "stopped · a backend pass failed")
          ]
    sequence_
      [ do
          frame <- renderCase frameCase
          (expected, approvalDetailText frame) `shouldBe` (expected, expected)
      | (frameCase, expected) <- expectations
      ]

  -- Requirement 6's other half, on the one row that reports it: a press writes
  -- its transition notice, and the frame the press produced shows it.
  it "shows the transition notice a press leaves, on both the start and the stop" $ do
    starting <- frameLines <$> renderCase (frameCaseNamed "approval-starting")
    stopping <- frameLines <$> renderCase (frameCaseNamed "approval-stopping")
    Data.Text.isInfixOf "Starting issue approval service…" starting `shouldBe` True
    Data.Text.isInfixOf "Stopping issue approval service…" stopping `shouldBe` True

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
    <> settingsCases
    <> solveModelCases
    <> sessionModeCases
    <> approvalCases
    <> operatingModeCases

-- | Issue #521's two surfaces, drawn over a roster that loads no provider.
--
-- The wide board, because the footer and the sidebar both shorten and a frame
-- is the only thing that shows the two together; and the help overlay, because
-- it is the surface the mode shortens most and its box is sized from the list
-- it draws, so a row hidden without the height following it would be a border
-- drawn over its own contents.
--
-- These two are the only frames the mode moves, and issue #546 moved them
-- once more when it gave `p` and `x` back: dual mode draws exactly what it
-- drew either time, which is what the untouched frames beside these assert.
operatingModeCases :: [FrameCase]
operatingModeCases =
  [ FrameCase
      { frameCaseName = "board-wide-no-agent",
        frameCaseWidth = 200,
        frameCaseHeight = 64,
        frameCaseSummary = "the wide board with no provider loaded: no solve, review, autosolve or approvals chips, no provider blocks, no approvals control",
        frameCaseState = noAgentBoard
      },
    FrameCase
      { frameCaseName = "overlay-help-no-agent",
        frameCaseWidth = 200,
        frameCaseHeight = 48,
        frameCaseSummary = "the help overlay with no provider loaded: the four agent rows gone, the process and kill rows kept beside the session and mouse rows",
        frameCaseState = \state -> (noAgentBoard state) {appOverlay = Just HelpOverlay}
      }
  ]

noAgentBoard :: AppState -> AppState
noAgentBoard = withModelRoster (Right noAgentRoster)

-- | The three surfaces that draw a model name (MODEL-3), which no frame
-- covered before this slice: the chooser's two rows, a solve session's header
-- and reviewer line, and what a surface shows when it cannot resolve its cell
-- at all.
--
-- Every one of them is drawn over a roster whose @display@ values were moved
-- explicitly. 'Spec.Support.Roster.rerosteredDefaults' cannot serve here --
-- it rotates model and effort and leaves @display@ alone, so a frame drawn
-- over it would be byte-identical to one drawn over the compiled defaults and
-- would prove nothing about where the text came from.
solveModelCases :: [FrameCase]
solveModelCases =
  [ FrameCase
      { frameCaseName = "overlay-solve-chooser",
        frameCaseWidth = 200,
        frameCaseHeight = 48,
        frameCaseSummary = "the solve chooser over a roster whose solve displays were moved off the defaults",
        frameCaseState = withModelRoster (Right distinctDisplays) . chooserOpen
      },
    FrameCase
      { frameCaseName = "overlay-solve-session",
        frameCaseWidth = 200,
        frameCaseHeight = 48,
        frameCaseSummary = "a solve session replaying a recorded assignment the live roster no longer carries",
        frameCaseState = recordedSolveSession
      },
    FrameCase
      { frameCaseName = "overlay-solve-chooser-unavailable",
        frameCaseWidth = 200,
        frameCaseHeight = 48,
        frameCaseSummary = "the chooser over a models.toml that will not load: no model named on either row",
        frameCaseState = unusableRoster . chooserOpen
      }
  ]

-- | The mode indicator §7 puts on every session overlay, once per mode
-- (issue #515 requirement 15). Two cases rather than one because a
-- 'FrameCase' has a single state and a session is in a single mode, so one
-- frame could only ever show one of the two badges.
--
-- Drawn on a review revision because that is the kind whose input line is on
-- screen in every phase: the badge and the draft it governs are then in the
-- same frame, and the insert case can show text that only insert mode could
-- have produced.
sessionModeCases :: [FrameCase]
sessionModeCases =
  [ FrameCase
      { frameCaseName = "overlay-session-normal",
        frameCaseWidth = 200,
        frameCaseHeight = 48,
        frameCaseSummary = "a live session overlay in normal mode, where a plain letter is a command",
        frameCaseState = revisionSession id
      },
    FrameCase
      { frameCaseName = "overlay-session-insert",
        frameCaseWidth = 200,
        frameCaseHeight = 48,
        frameCaseSummary = "the same overlay after i and a typed draft, in insert mode",
        frameCaseState = revisionSession (typedIntoSession "iCheck the retry path too")
      }
  ]

-- | An interactive issue-revision session, which is the review stage that
-- talks to the app-server and therefore the one that reads typed text.
revisionSession :: (ReviewSession -> ReviewSession) -> AppState -> AppState
revisionSession press state =
  state
    { appOverlay = Just (ReviewOverlay solveFrameIssue),
      appReviewSessions = Map.singleton solveFrameIssue (press session)
    }
  where
    session :: ReviewSession
    session =
      newAgentSession
        0
        ReviewRunning
        "thinking"
        Nothing
        (plainTranscript "Reading the issue body and the code it names…\n")
        ReviewDetail
          { reviewSessionIssue = fixtureIssue solveFrameIssue,
            reviewSessionStage = IssueRevision,
            reviewSessionThreadId = Just "thread-515",
            reviewSessionTurnId = Nothing,
            reviewSessionPending = Nothing,
            reviewSessionUndelivered = []
          }

-- | Replay a run of key presses through the overlay's own decoder and the
-- pure half of its dispatch, so the insert frame draws a state real presses
-- reach rather than one written into the record. A press the decoder declines
-- leaves the session alone, exactly as the dashboard would.
typedIntoSession :: String -> ReviewSession -> ReviewSession
typedIntoSession pressed session = foldl' press session pressed
  where
    press :: ReviewSession -> Char -> ReviewSession
    press current character =
      let caps = reviewSessionOps.sessionOpsCaps
          liveInput = reviewSessionInputLive current.sessionDetail.reviewSessionStage current.sessionPhase
          pressFocus = SessionFocus caps current.sessionMode liveInput
       in case sessionInputEvent pressFocus (VtyInput.EvKey (VtyInput.KChar character) []) of
            Nothing -> current
            Just inputEvent ->
              let moved = setSessionMode (sessionModeAfter inputEvent current.sessionMode) current
               in case inputEvent of
                    SessionInputInsert typed -> insertSessionInput typed moved
                    SessionInputBackspace -> removeSessionInputCharacter moved
                    _ -> moved

-- | The chooser as the autosolve key opens it, before any refusal: the roster
-- is not consulted until a digit is pressed, which is why the frame above can
-- draw this overlay over a roster no solve could start on.
chooserOpen :: AppState -> AppState
chooserOpen state = state {appOverlay = Just (SolveChooser AutoSolve (fixtureIssue solveFrameIssue))}

-- | A solve session in exactly the state its first launch leaves it in: the
-- transcript the fresh start wrote, and the assignment that launch resolved
-- and recorded back onto it ('Kanban.UI.Solve.launchAssignedSolveInvocation').
--
-- The live roster is left at the compiled defaults while the recorded cell
-- comes from a roster that moved every display, so the header and the
-- reviewer line beneath it cannot have come from the same place: the header
-- is the record, and the reviewer line is the live @pr_review@ cell of the
-- opposite brand.
recordedSolveSession :: AppState -> AppState
recordedSolveSession state =
  state
    { appOverlay = Just (SolveOverlay solveFrameIssue),
      appSolveSessions = Map.singleton solveFrameIssue session
    }
  where
    brand = ClaudeSolver
    recorded = cellOf (solveAssignment distinctDisplays brand) :: RecordedAssignment
    session :: SolveSession
    session =
      newAgentSession
        0
        SolveRunning
        "solving"
        (Just goldenNow)
        (plainTranscript (freshSolveTranscript state.appModelRoster AutoSolve brand))
        SolveDetail
          { solveSessionIssue = fixtureIssue solveFrameIssue,
            solveSessionWorkflow = AutoSolve,
            solveSessionBrand = brand,
            solveSessionId = Nothing,
            solveSessionAutoProgress = Nothing,
            solveSessionResumeProvenance = ResumeAnswer,
            solveSessionAssignment = Just recorded
          }

-- | The fixture issue all three frames are drawn for.
solveFrameIssue :: Int
solveFrameIssue = 812

fixtureIssue :: Int -> Issue
fixtureIssue number = case fixtureItem number of
  IssueItem issue -> issue
  PullRequestItem _ -> error ("the fixture board's #" <> show number <> " is a pull request, not an issue")

-- | The settings overlay, once per roster state §7's @o@ row promises a
-- different screen for: the compiled roster with every cell at its default,
-- the same roster with one cell edited off it, a @models.toml@ that will not
-- load at all, and the two reduced provider sets.
--
-- The last three are also the mode coverage. Each of the three
-- 'Kanban.Models.OperatingMode' labels is drawn by at least one frame here —
-- dual by the first two, single-agent by the Claude-only roster, and no-agent
-- by both the empty provider set and the unusable file that derives the same
-- mode — so a line naming the wrong one cannot pass.
--
-- The edited frame is produced by the overlay's own transitions rather than
-- by writing an assignment into the record, so no frame can show a roster the
-- interaction could not reach — including the regenerated display, which is a
-- consequence of the edit rather than a label this suite chose.
settingsCases :: [FrameCase]
settingsCases =
  [ FrameCase
      { frameCaseName = "overlay-settings",
        frameCaseWidth = 200,
        frameCaseHeight = 48,
        frameCaseSummary = "the settings overlay over the wide board, every roster cell at its compiled default",
        frameCaseState = openSettings
      },
    FrameCase
      { frameCaseName = "overlay-settings-overridden",
        frameCaseWidth = 200,
        frameCaseHeight = 48,
        frameCaseSummary = "one roster cell cycled off its compiled default, marked override beside the rest",
        frameCaseState = editedRosterCell
      },
    FrameCase
      { frameCaseName = "overlay-settings-unusable",
        frameCaseWidth = 200,
        frameCaseHeight = 48,
        frameCaseSummary = "an unusable models.toml: its defect and what d would write, instead of roster rows",
        frameCaseState = openSettings . unusableRoster
      },
    FrameCase
      { frameCaseName = "overlay-settings-single-agent",
        frameCaseWidth = 200,
        frameCaseHeight = 48,
        frameCaseSummary = "a roster loading Claude alone: single-agent on the mode line, and only that brand's rows",
        frameCaseState = openSettings . withModelRoster (Right claudeOnlyRoster)
      },
    FrameCase
      { frameCaseName = "overlay-settings-no-agent",
        frameCaseWidth = 200,
        frameCaseHeight = 48,
        frameCaseSummary = "a roster loading no provider: no-agent on the mode line, and no rows to edit",
        frameCaseState = openSettings . withModelRoster (Right noAgentRoster)
      }
  ]

-- | Open the overlay, move to the second roster row, and cycle its model
-- forward — the same three presses the keyboard makes.
--
-- The save the 'EventM' shell would perform is stood in for by
-- 'applyRosterWrite' over a successful result, which is the one thing a frame
-- cannot do for itself: the state it produces is exactly the state a real save
-- produces, and an outcome this fixture did not expect fails loudly rather
-- than quietly drawing the unedited roster.
editedRosterCell :: AppState -> AppState
editedRosterCell state = foldl press (openSettings state) [SettingsMoveRow 1, SettingsCycleModel 1]
  where
    press current input = case settingsOutcome input current.appModelRoster current.appSettingsFocus of
      SettingsRefocused moved _ -> current {appSettingsFocus = moved}
      SettingsRosterWrite write -> applyRosterWrite (Right ()) write current
      other -> error ("the settings frame expected a focus move or a roster write, and got " <> show other)

-- | A present @models.toml@ the loader refused, which is the one roster state
-- no interaction can produce: it is what the startup load answered.
unusableRoster :: AppState -> AppState
unusableRoster =
  withModelRoster
    ( Left
        ( RosterLoadError
            "/fixture/home/.config/kanban/models.toml"
            (RosterInvalid [UnknownModel PrReviewRole CodexProvider "gpt-5.9"])
        )
    )

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
             -- Exactly §7's transfer: uppercase `F` from an open search box
             -- moves the keyboard to the panel and leaves the query alone.
             frameCaseState = focusFilterPanel . searching "envelope"
           },
         FrameCase
           { frameCaseName = "filter-hidden-active",
             frameCaseWidth = 200,
             frameCaseHeight = 64,
             frameCaseSummary = "a non-default criteria set with the panel hidden, marked F filter* in the footer",
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

-- | The issue approval control's five non-resting states, each drawn above the
-- drainer's in a sidebar the board is wide enough to show.
--
-- Every board frame above already covers the sixth: 'restingState' leaves the
-- service settled off, so @off@ is what the whole existing sidebar-visible set
-- is captured with — and the narrow case, which hides the sidebar entirely,
-- keeps proving that a collapsed sidebar draws neither control.
--
-- None of these writes an 'ApprovalStatus' into the record. The two
-- transitions come from 'approvalTogglePress', which is the same press both
-- the @a@ binding and a click on the control run, and the three steady states
-- from 'decodeApprovalStatus' over a controller document, applied through the
-- poll path 'approvalStatusApplied' — so a frame cannot show a status the
-- service could not actually report, and the detail line under each box is
-- whatever those two mechanisms composed rather than anything this suite
-- wrote.
approvalCases :: [FrameCase]
approvalCases =
  [ FrameCase
      { frameCaseName = "approval-on",
        frameCaseWidth = 164,
        frameCaseHeight = 48,
        frameCaseSummary = "the approval control green above the drainer, the queue being worked",
        frameCaseState = polled (approvalDocument "running" Nothing)
      },
    FrameCase
      { frameCaseName = "approval-starting",
        frameCaseWidth = 164,
        frameCaseHeight = 48,
        frameCaseSummary = "a start pressed from off: the optimistic transition and its notice",
        frameCaseState = pressingApproval
      },
    FrameCase
      { frameCaseName = "approval-stopping",
        frameCaseWidth = 164,
        frameCaseHeight = 48,
        frameCaseSummary = "a stop pressed from on: the optimistic transition and its notice",
        frameCaseState = pressingApproval . polled (approvalDocument "running" Nothing)
      },
    FrameCase
      { frameCaseName = "approval-warning",
        frameCaseWidth = 164,
        frameCaseHeight = 48,
        frameCaseSummary = "amber at the durable barrier, naming the issue that requested changes",
        frameCaseState = polled (approvalDocument "running" (Just 812))
      },
    FrameCase
      { frameCaseName = "approval-error",
        frameCaseWidth = 164,
        frameCaseHeight = 48,
        frameCaseSummary = "red on a backend pass that failed and ended the run",
        frameCaseState = polled (approvalDocument "child_failure" Nothing)
      }
  ]

-- | One controller status document, in the shape "Spec.ApprovalService"
-- already builds them in: the schema and version this reader pins, the
-- repository the fixture board is for, a state, and — for the barrier case —
-- the durable record that outlives a stop.
approvalDocument :: String -> Maybe Int -> LazyByteString.ByteString
approvalDocument state barrier =
  LazyByteString.pack
    ( "{"
        <> intercalate
          ","
          ( [ "\"schema\":\"kanban-issue-approval-status\"",
              "\"version\":1",
              "\"repository\":\"" <> Data.Text.unpack (normalizedRepositoryIdentity fixtureRepository) <> "\"",
              "\"state\":\"" <> state <> "\""
            ]
              <> foldMap (\issue -> ["\"barrier_issue\":" <> show issue]) barrier
          )
        <> "}"
    )

-- | One controller document applied the way a poll applies it.
polled :: LazyByteString.ByteString -> AppState -> AppState
polled document state =
  fst
    ( approvalStatusApplied
        state.appApprovalTransition
        (decodeApprovalStatus (normalizedRepositoryIdentity state.appRepository) document)
        state
    )

-- | One press of the approval control, taken against a discovered controller
-- so the press is a real transition rather than the unavailable refusal the
-- resting state's absent controller produces. The handoff the press returns is
-- deliberately dropped: nothing a frame shows depends on it.
pressingApproval :: AppState -> AppState
pressingApproval state =
  fst (approvalTogglePress state {appApprovalController = Right fixtureApprovalController})

-- | A controller that exists as a value and names a path nothing will run.
-- 'approvalTogglePress' only reads it into the handoff it returns, which these
-- frames discard.
fixtureApprovalController :: ApprovalController
fixtureApprovalController =
  ApprovalController "/nonexistent/kanban-test-approval-controller" [] ApprovalLaunchd

-- | The repository every frame is drawn for, named once so the controller
-- documents above are addressed to the same identity 'restingState' carries.
fixtureRepository :: Repository
fixtureRepository = Repository "/fixture/kanban" "coghex" "kanban"

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
    { appRepository = fixtureRepository,
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
      -- The pure compiled value, not a load: a golden frame must not read
      -- the developer's real XDG configuration. A frame drawn over another
      -- roster moves it with 'Kanban.UI.Types.withModelRoster', so no frame
      -- can name a mode its roster does not derive.
      appModelRoster = Right defaultRoster,
      appOperatingMode = loadedOperatingMode (Right defaultRoster),
      appSettingsFocus = Nothing,
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

-- | The cells of the one session-mode badge a frame draws, located by the
-- text itself rather than by a written-down row and column, so the overlay's
-- layout can move without this pointing at whatever took its place.
badgeCells :: [[FrameCell]] -> Text -> [FrameCell]
badgeCells frame badge = case matches of
  cells : _ -> cells
  [] -> error ("no row of the frame draws " <> Data.Text.unpack badge)
  where
    width = Data.Text.length badge
    matches =
      [ take width (drop column row)
      | row <- frame,
        column <- [0 .. length row - width],
        Data.Text.pack (cellCharacters (take width (drop column row))) == badge
      ]

frameRow :: [[FrameCell]] -> Int -> [FrameCell]
frameRow frame rowIndex = case drop rowIndex frame of
  row : _ -> row
  [] -> error ("the frame has no row " <> show rowIndex)

cellAt :: [[FrameCell]] -> Int -> Int -> FrameCell
cellAt frame rowIndex columnIndex = case drop columnIndex (frameRow frame rowIndex) of
  cell : _ -> cell
  [] -> error ("the frame has no cell at row " <> show rowIndex <> ", column " <> show columnIndex)

-- | The text the selected fixture card draws, short enough to stay on one
-- row in every frame width this suite renders.
selectedCardText :: Text
selectedCardText = "#812 Modal input leaks"

-- | Three unselected fixture cards whose statuses colour them differently,
-- each named by text that stays on one row at every frame width here and
-- each drawn whole -- corners included -- inside the shortest frame these
-- assertions render.
unselectedCardCases :: [(String, Text, AttrName)]
unselectedCardCases =
  [ ("neutral issue", "#711 Adopt the", neutralAttr),
    ("conflicted pull request", "PR #851 Resolve save", problemAttr),
    ("ready pull request", "PR #823 Fix modal scroll", readyAttr)
  ]

-- | The six glyphs a card frame draws itself with. §10's border contract is a
-- statement about the attributes those cells carry, not about the glyphs, so
-- both modes are here: --ascii keeps the whole contract and changes only
-- which characters it lands on.
data CardGlyphs = CardGlyphs
  { cardTopLeftGlyph :: Char,
    cardTopRightGlyph :: Char,
    cardBottomLeftGlyph :: Char,
    cardBottomRightGlyph :: Char,
    cardHorizontalGlyph :: Char,
    cardVerticalGlyph :: Char
  }
  deriving stock (Eq, Show)

unicodeCardGlyphs :: CardGlyphs
unicodeCardGlyphs = CardGlyphs '╭' '╮' '╰' '╯' '─' '│'

asciiCardGlyphs :: CardGlyphs
asciiCardGlyphs = CardGlyphs '+' '+' '+' '+' '-' '|'

-- | Where one card's own frame runs in a rendered frame.
data CardExtent = CardExtent
  { cardTopRow :: Int,
    cardBottomRow :: Int,
    cardLeftColumn :: Int,
    cardRightColumn :: Int
  }
  deriving stock (Eq, Show)

-- | The card that draws @needle@, located from that text rather than from a
-- corner glyph: under --ascii every corner is '+', which the shell border,
-- the board rules and the sidebar controls draw too, so a frame-wide glyph
-- search cannot tell a card from anything else. The card's own left edge is
-- the nearest vertical run left of the text, and the frame is bounded from
-- the first corner above that edge.
cardShowing :: CardGlyphs -> [[FrameCell]] -> Text -> CardExtent
cardShowing glyphs frame needle = CardExtent top (rowOf frame top left glyphs.cardBottomLeftGlyph) left (columnOf frame top left glyphs.cardTopRightGlyph)
  where
    (textRow, textColumn) = frameTextAt frame needle
    left = case [columnIndex | (columnIndex, cell) <- take textColumn (zip [0 ..] (frameRow frame textRow)), frameCellCharacter cell == glyphs.cardVerticalGlyph] of
      columns@(_ : _) -> last columns
      [] -> error ("no card edge left of " <> Data.Text.unpack needle)
    top = case [rowIndex | rowIndex <- [textRow - 1, textRow - 2 .. 0], frameCellCharacter (cellAt frame rowIndex left) == glyphs.cardTopLeftGlyph] of
      rowIndex : _ -> rowIndex
      [] -> error ("no card corner above " <> Data.Text.unpack needle)

-- | §10's border contract for one card, cell by cell: the left edge, both
-- horizontal runs and the two left corners under @leftAttribute@, the right
-- edge and the two right corners under @rightAttribute@. The two attributes
-- are the same on an unselected card and differ on the selected one, which is
-- the whole of what the split means. @label@ travels into every failure so a
-- table of cards says which row failed.
expectCardBorder :: String -> CardGlyphs -> [[FrameCell]] -> CardExtent -> Vty.Attr -> Vty.Attr -> Expectation
expectCardBorder label glyphs frame extent leftAttribute rightAttribute = do
  expect "top-left corner" [cellAt frame extent.cardTopRow extent.cardLeftColumn] glyphs.cardTopLeftGlyph leftAttribute
  expect "bottom-left corner" [cellAt frame extent.cardBottomRow extent.cardLeftColumn] glyphs.cardBottomLeftGlyph leftAttribute
  expect "top-right corner" [cellAt frame extent.cardTopRow extent.cardRightColumn] glyphs.cardTopRightGlyph rightAttribute
  expect "bottom-right corner" [cellAt frame extent.cardBottomRow extent.cardRightColumn] glyphs.cardBottomRightGlyph rightAttribute
  expect "left edge" (edgeCells extent.cardLeftColumn) glyphs.cardVerticalGlyph leftAttribute
  expect "right edge" (edgeCells extent.cardRightColumn) glyphs.cardVerticalGlyph rightAttribute
  expect "top run" (runCells extent.cardTopRow) glyphs.cardHorizontalGlyph leftAttribute
  expect "bottom run" (runCells extent.cardBottomRow) glyphs.cardHorizontalGlyph leftAttribute
  where
    interior = [extent.cardTopRow + 1 .. extent.cardBottomRow - 1]
    run = [extent.cardLeftColumn + 1 .. extent.cardRightColumn - 1]
    edgeCells columnIndex = [cellAt frame rowIndex columnIndex | rowIndex <- interior]
    runCells rowIndex = [cellAt frame rowIndex columnIndex | columnIndex <- run]
    expect what cells character attribute = do
      -- An empty run would let every assertion below pass without looking at
      -- a single cell, so the cells being there is itself part of the check.
      (label <> " " <> what <> " is drawn", null cells) `shouldBe` (label <> " " <> what <> " is drawn", False)
      (label <> " " <> what <> " glyphs", cellCharacters cells) `shouldBe` (label <> " " <> what <> " glyphs", map (const character) cells)
      (label <> " " <> what <> " attributes", cellAttributes cells) `shouldBe` (label <> " " <> what <> " attributes", map (const attribute) cells)

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

-- | Where one sidebar control's box is: the row its label is drawn on, and
-- the column that box opens at. Located by the label the control is declared
-- with rather than by a copy of it, so a renamed control moves these with it.
-- | The sidebar's own columns of every row, which is where a provider block
-- or a control is drawn and nowhere else. Read as one text so an assertion
-- about the sidebar cannot pass or fail on a card's excerpt.
sidebarText :: [[FrameCell]] -> Text
sidebarText frame =
  Data.Text.unlines
    [ Data.Text.pack [frameCellCharacter (cellAt frame rowIndex columnIndex) | columnIndex <- [0 .. usageSidebarWidth]]
    | rowIndex <- [0 .. length frame - 1]
    ]

-- | What the sidebar draws only while a provider is loaded: the two provider
-- names, a window row that could only come from a snapshot, and the approval
-- control's label.
providerSidebarText :: [Text]
providerSidebarText = ["Codex", "Claude", "5 hour", "week", Data.Text.strip approvalControlLabel]

-- | Issue #521's bindings as issue #546 left them: the four that start agent
-- work, in table order.
agentBindings :: [BoardAction]
agentBindings = [ReviewSelection, SolveSelection, AutoSolveSelection, ToggleApproval]

-- | The two issue #546 took back out of that set, which reach work already
-- running rather than starting any, and so are drawn in every mode.
recoveryBindings :: [BoardAction]
recoveryBindings = [KillWorking, ShowProcesses]

-- | The chip each of them puts on the footer, composed by the projection the
-- footer itself uses rather than transcribed.
agentFooterChips, recoveryFooterChips :: [Text]
agentFooterChips = map (footerHint . binding) agentBindings
recoveryFooterChips = map (footerHint . binding) recoveryBindings

-- | The description each of them puts on its help row, which is the other
-- text a frame can be searched for.
agentHelpDescriptions, recoveryHelpDescriptions :: [Text]
agentHelpDescriptions = map ((.bindingDescription) . binding) agentBindings
recoveryHelpDescriptions = map ((.bindingDescription) . binding) recoveryBindings

controlAt :: [[FrameCell]] -> Text -> (Int, Int)
controlAt frame label = (row, column - 2)
  where
    -- The label is drawn one cell inside its own vertical edge, so the box
    -- opens two cells left of where the stripped text starts.
    (row, column) = frameTextAt frame (Data.Text.strip label)

-- | One row of the sidebar's interior, read from the column a control's box
-- opens at rather than from a fixed offset, so this holds at every width the
-- sidebar is drawn at.
interiorRow :: [[FrameCell]] -> Int -> Int -> Text
interiorRow frame left rowIndex =
  Data.Text.strip . Data.Text.pack $
    [ frameCellCharacter (cellAt frame rowIndex columnIndex)
    | columnIndex <- [left .. left + usageSidebarInterior - 1]
    ]

-- | The status line drawn under the approval control's box: every interior
-- row between that box and the drainer's, rejoined the way 'txtWrap' split
-- it, so a detail too long for the 24-cell interior is read back whole rather
-- than as its first line.
approvalDetailText :: [[FrameCell]] -> Text
approvalDetailText frame =
  Data.Text.unwords
    ( filter
        (not . Data.Text.null)
        [interiorRow frame left rowIndex | rowIndex <- [row + 2 .. drainerRow - 2]]
    )
  where
    (row, left) = controlAt frame approvalControlLabel
    (drainerRow, _) = controlAt frame drainerLabel

-- | The attribute every glyph of the approval control carries: its own box,
-- edge to edge, and the status line under it.
--
-- The edges are read rather than only the label because they are the point of
-- §10's own-box rule: Brick's border widgets draw their runs under an
-- attribute the theme does not name, so a control that wrapped its label in
-- one would lose its colour exactly there.
approvalControlAttributes :: [[FrameCell]] -> [Vty.Attr]
approvalControlAttributes frame =
  [ frameCellAttribute cell
  | rowIndex <- [row - 1 .. drainerRow - 2],
    columnIndex <- [left .. left + displayWidth approvalControlLabel + 1],
    let cell = cellAt frame rowIndex columnIndex,
    frameCellCharacter cell /= ' '
  ]
  where
    (row, left) = controlAt frame approvalControlLabel
    (drainerRow, _) = controlAt frame drainerLabel

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
