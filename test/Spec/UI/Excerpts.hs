-- | @v@, and the runtime card-excerpt budget behind it (issue #664).
--
-- Card density used to be fixed for the life of the process: the excerpt
-- height came straight off the resolved configuration, and
-- 'Kanban.Config.parsePositiveBoundedInt' refuses a zero there, so excerpts
-- could not be hidden at all. @v@ makes the budget a runtime value between the
-- configured height and none, and the whole of what has to hold for that to
-- be a toggle rather than a redraw is here.
--
-- Three things, deliberately kept apart:
--
--   * the budget is /one/ number. A card is measured against it, drawn
--     against it, and has its cached column layout invalidated by it, so a
--     toggle cannot move one of the three and leave the other two behind —
--     which would draw a card at a height nothing measured.
--   * the reflow keeps the user where they were. Every card above the
--     selected one changes height, so the selection survives by identity on
--     its own but its /visibility/ does not, in either direction.
--   * the state is the board's alone. It reaches no GitHub request, no cache
--     write, no configuration or settings file, and no other board state, and
--     it starts at the configured height again at the next launch.
--
-- Everything below is asserted against production code. The frames come from
-- 'Kanban.UI.drawApplication' and the interaction from brick's own event loop,
-- because the reflow is a viewport fact and a state rendered in isolation
-- always starts its viewport at zero.
module Spec.UI.Excerpts (spec) where

import Brick (hLimit, txt, (<=>))
import Control.Monad (forM_)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Graphics.Vty as Vty
import Kanban.Config (LimitsConfig (..), ResolvedConfig (..))
import Kanban.Domain
import Kanban.Filter (FilterCriteria (..), LifecycleFacet (..))
import Kanban.GitHub (GitHubResult (..))
import Kanban.Layout (responsiveColumnWidths)
import Kanban.Models (OperatingMode (..))
import Kanban.UI (drawApplication)
import Kanban.UI.Board
  ( BoardMarks (..),
    boardFooterHintLine,
    boardHintLine,
    cardExcerptLimit,
    columnBodyItems,
    columnItemHeight,
    columnWindowFor,
    defaultBoardMarks,
    defaultExcerptsVisible,
    drawColumnItem,
    refreshColumnWindows,
    unmeasuredLayoutInputs,
  )
import Kanban.UI.Events (BoardActionGate (..), blockedByCompletedLoad, boardActionGate, mutatesSelectedWork)
import Kanban.UI.Keys
  ( BindingScope (..),
    BoardAction (..),
    KeyBinding (..),
    agentSurfaceRefusal,
    binding,
    boardAction,
    excerptFooterHint,
    footerHint,
    requiresLoadedAgent,
  )
import Kanban.UI.Overlay (helpLines)
import Kanban.UI.Search (columnItemsIn, entriesFor, expandedTrackersFor)
import Kanban.UI.Selection (selectedItem)
import Kanban.UI.State (toggleCardExcerpts)
import Kanban.UI.Theme (themeFor)
import Kanban.UI.Types
import Kanban.UI.Util (allColumns, selectedRow)
import Spec.Support.App (testAppState)
import Spec.Support.Dashboard (DashboardRun (..), ScriptStep (..), quitStep, runDashboardScript)
import Spec.Support.Fixtures (epoch, fixtureBoard, testOptions, testResolvedConfig)
import Spec.Support.Render (FrameCell (..), detailsText, renderDetailsForState, renderFrameCells, renderWidgetLines)
import Test.Hspec

spec :: Spec
spec = describe "card excerpt toggle" $ do
  describe "the key" $ do
    it "answers v on the board and in no other scope" $ do
      boardAction BoardScope (Vty.EvKey (Vty.KChar 'v') []) `shouldBe` Just ToggleExcerpts
      sequence_
        [ (scope, boardAction scope (Vty.EvKey (Vty.KChar 'v') [])) `shouldBe` (scope, Nothing)
          | scope <- [DetailsScope, HelpScope, OverlayScope]
        ]

    -- The three total predicates that decide where a binding is live, and the
    -- gate they compose into. Requirement 2 and the review's input-precedence
    -- amendment between them say this key reaches no card and needs no
    -- provider, so none of the three may claim it.
    it "needs no provider, reaches no card, and is not inert under the blocker" $ do
      requiresLoadedAgent ToggleExcerpts `shouldBe` False
      mutatesSelectedWork ToggleExcerpts `shouldBe` False
      blockedByCompletedLoad ToggleExcerpts `shouldBe` False
      agentSurfaceRefusal NoAgentMode ToggleExcerpts `shouldBe` Nothing
      state <- excerptState 12
      boardActionGate state ToggleExcerpts `shouldBe` DispatchBoardAction
      boardActionGate (blockedOnCompletedLoad state) ToggleExcerpts `shouldBe` DispatchBoardAction

    -- The positive control on the blocker above: a binding that /is/ inert
    -- under it really is, in the same state, so the dispatch asserted there is
    -- about this key rather than about a blocker that never came up.
    it "leaves the blocker blocking the keys that do reach a card" $ do
      state <- excerptState 12
      boardActionGate (blockedOnCompletedLoad state) ShowDetails `shouldBe` IgnoreBoardAction

    -- The review's precedence amendment. A printable key is the search box's
    -- text before it is anything else, so an open query must swallow this one
    -- exactly as it swallows the board's other lowercase bindings.
    it "types into an open search instead of toggling" $ do
      run <- script [key 's', key 'v', key 'v']
      run.runState.appExcerptsVisible `shouldBe` defaultExcerptsVisible
      fmap (.searchQuery) run.runState.appSearch `shouldBe` Just "vv"

    -- The other half of it: an overlay answers its own keys, and this one is
    -- not among them, so nothing about the board moves underneath it.
    it "leaves an open overlay's own input alone" $ do
      run <- script [Press (Vty.EvKey Vty.KEnter []), key 'v']
      run.runState.appExcerptsVisible `shouldBe` defaultExcerptsVisible

  describe "the budget" $ do
    it "is the configured height while excerpts are drawn, and none at all while they are hidden" $
      sequence_
        [ (configured, (cardExcerptLimit True config, cardExcerptLimit False config))
            `shouldBe` (configured, (configured, 0))
          | configured <- [1, 3, 5, 9],
            let config = configuredFor configured
        ]

    -- Requirement 1 and the review's zero-rows amendment, read off the drawing
    -- rather than predicted. Hiding takes the excerpt rows away and leaves
    -- every other row of the card exactly where it was, at the configured
    -- height and at one that is not the default.
    forM_ [defaultExcerptLimit, 5] $ \configured ->
      it ("takes exactly the " <> show configured <> " excerpt rows off a card and puts them back") $ do
        drawn <- excerptStateAt configured 12
        let visible = cardRows drawn
            hidden = cardRows (toggleCardExcerpts drawn)
        length (filter (Text.isInfixOf excerptMarker) visible) `shouldBe` configured
        filter (Text.isInfixOf excerptMarker) hidden `shouldBe` []
        filter (not . Text.isInfixOf excerptMarker) visible `shouldBe` hidden
        cardRows (toggleCardExcerpts (toggleCardExcerpts drawn)) `shouldBe` visible

    -- The half a measurement stands on: the rows a card is measured at are the
    -- rows it draws at, in both states and at both heights. A budget that
    -- reached the drawing without reaching 'columnItemHeight' would leave the
    -- windowed body cropping cards against heights nothing drew.
    forM_ [defaultExcerptLimit, 5] $ \configured ->
      forM_ [("drawn", True), ("hidden", False)] $ \(label, visible) ->
        it ("measures every item at the rows it draws at, " <> label <> " at " <> show configured) $ do
          state <- excerptsShown visible <$> excerptStateAt configured 12
          let items = allItems state
          items `shouldSatisfy` ((> 4) . length)
          map (columnItemHeight state issuesWidth) items `shouldBe` map (renderedHeight state) items

  describe "what the toggle invalidates" $ do
    -- The third reader of the one budget. A measurement taken under the other
    -- one no longer describes the column, and the settle is what notices:
    -- 'Kanban.UI.Board.layoutInputs' reads the same number the drawing does.
    forM_ [("hiding", True), ("showing", False)] $ \(label, startVisible) ->
      it ("drops every measurement taken under the other budget, " <> label) $ do
        measured <- settle . excerptsShown startVisible <$> excerptState 60
        let toggled = toggleCardExcerpts measured
            resettled = settle toggled
        columnWindowFor measured Issues issuesWidth `shouldSatisfy` held
        columnWindowFor resettled Issues issuesWidth `shouldSatisfy` held
        resettled.appLayoutEpoch `shouldNotBe` measured.appLayoutEpoch
        resettled.appLayoutInputs `shouldNotBe` measured.appLayoutInputs
        -- ...and the measurement the old epoch produced is not reused for the
        -- new one, which is what a frame between the two events asks.
        columnWindowFor resettled {appColumnWindows = measured.appColumnWindows} Issues issuesWidth
          `shouldSatisfy` (not . held)

    -- The review's amendment, stated as the comparison it asks for: toggle a
    -- board whose columns are already measured, and the frame it draws is the
    -- frame a board with no measurement at all draws. Issue #640's
    -- viewport-bounded rendering is what makes those two different code paths,
    -- and this is what keeps them agreeing across a height change.
    forM_ [("hiding", True), ("showing", False)] $ \(label, startVisible) ->
      it ("draws what an unmeasured board draws after " <> label) $ do
        measured <- settle . excerptsShown startVisible <$> excerptState 60
        let toggled = settle (toggleCardExcerpts measured)
        drawnItems toggled `shouldSatisfy` ((< length (allItems toggled)) . length)
        frameCells toggled `shouldBe` frameCells (unmeasure toggled)

  describe "the selection" $ do
    -- Requirement 3. The rows above the selected card all change height, so a
    -- viewport that is not moved leaves the selection off screen -- growing
    -- them pushes it past the bottom, shrinking them leaves an offset past the
    -- end of a shorter column. @G@ puts the viewport at the very bottom, which
    -- is the case the issue names, and the same card has to still be on the
    -- frame after each press.
    it "keeps the selected card selected and on screen, in both directions, from the bottom of a column" $ do
      atEnd <- script [key 'G']
      -- The viewport really is at the bottom before anything toggles: the last
      -- card is on the frame and the first is not.
      lastFrameHas atEnd (cardHeading scriptedColumnLength) `shouldBe` True
      lastFrameHas atEnd (cardHeading 1) `shouldBe` False
      forM_ [("hidden" :: String, [key 'G', key 'v']), ("shown again", [key 'G', key 'v', key 'v'])] $ \(label, steps) -> do
        run <- script steps
        (label, Map.lookup Issues run.runState.appSelectedRows)
          `shouldBe` (label, Map.lookup Issues atEnd.runState.appSelectedRows)
        (label, run.runState.appSelectedColumn) `shouldBe` (label, atEnd.runState.appSelectedColumn)
        -- Identity, not only the index: the same card is under the selection.
        (label, fmap itemId (selectedItem run.runState))
          `shouldBe` (label, fmap itemId (selectedItem atEnd.runState))
        (label, fmap itemId (selectedItem run.runState))
          `shouldBe` (label, Just (itemId (IssueItem (excerptIssue scriptedColumnLength))))
        (label, lastFrameHas run (cardHeading scriptedColumnLength)) `shouldBe` (label, True)
      -- ...and the two presses really did change the board between them, so
      -- the agreement above is not the agreement of two identical frames.
      brief <- script [key 'G', key 'v']
      lastFrameHas brief excerptMarker `shouldBe` False
      lastFrameHas atEnd excerptMarker `shouldBe` True

    it "asks for the selection to be revealed however the last event left it" $ do
      state <- excerptState 60
      sequence_
        [ (ensure, (toggleCardExcerpts state {appEnsureSelectionVisible = ensure}).appEnsureSelectionVisible)
            `shouldBe` (ensure, True)
          | ensure <- [True, False]
        ]

    it "moves no selection of its own" $ do
      state <- excerptState 60
      let toggled = toggleCardExcerpts state {appSelectedColumn = Active, appSelectedRows = Map.insert Active 3 state.appSelectedRows}
      toggled.appSelectedColumn `shouldBe` Active
      selectedRow toggled Active `shouldBe` 3

  -- Requirement 2, as the whole of what the transition writes. A press that
  -- reached GitHub, the cache, the configuration, the settings, or the board's
  -- freshness would have to move one of these.
  describe "what else it touches" $
    it "moves the excerpt flag and the reveal request, and nothing else" $ do
      state <- excerptState 12
      let toggled = toggleCardExcerpts state
          restored = toggled {appExcerptsVisible = state.appExcerptsVisible, appEnsureSelectionVisible = state.appEnsureSelectionVisible}
      toggled.appExcerptsVisible `shouldBe` not state.appExcerptsVisible
      map ($ restored) boardFacts `shouldBe` map ($ state) boardFacts

  describe "process-lifetime state" $ do
    -- Requirement 4's first half, and the launch default's one spelling.
    it "starts a fresh board at the configured height" $ do
      defaultExcerptsVisible `shouldBe` True
      state <- excerptState 12
      state.appExcerptsVisible `shouldBe` defaultExcerptsVisible
      (unmeasuredLayoutInputs testOptions testResolvedConfig).layoutExcerptLines
        `shouldBe` cardExcerptLimit defaultExcerptsVisible testResolvedConfig
      sequence_
        [ (configured, (unmeasuredLayoutInputs testOptions (configuredFor configured)).layoutExcerptLines)
            `shouldBe` (configured, configured)
          | configured <- [1, 3, 5, 9]
        ]
      -- A fresh state settles to the budget it launched under, so nothing is
      -- invalidated before anything has happened.
      (settle state).appLayoutEpoch `shouldBe` state.appLayoutEpoch

    it "returns to the default after a round trip" $ do
      state <- excerptState 12
      (toggleCardExcerpts (toggleCardExcerpts state)).appExcerptsVisible `shouldBe` defaultExcerptsVisible

    -- Requirement 4's second half, through the real event loop: a refresh
    -- rebuilds the board, a resize re-measures every column, and an overlay
    -- opens and closes over the top. None of the three is a launch.
    it "survives a refresh, a resize, and an overlay" $ do
      run <- script [key 'v', refreshTo 20, Resize resizedTo, key '?', Press (Vty.EvKey Vty.KEsc [])]
      run.runState.appExcerptsVisible `shouldBe` False
      lastFrameHas run excerptMarker `shouldBe` False
      -- The refresh really did land, so the survival is across a rebuilt board
      -- rather than across an event the dashboard dropped.
      length (entriesFor run.runState Issues) `shouldBe` 20

  describe "the footer and the help overlay" $ do
    -- Requirement 5's chip. Both spellings come from "Kanban.UI.Keys", and a
    -- board drawing its excerpts shows exactly the label the table declares,
    -- which is what leaves the default line the plain projection every other
    -- chip's is.
    it "names the state the board is in, and tells the two apart" $ do
      excerptFooterHint True `shouldBe` footerHint (binding ToggleExcerpts)
      excerptFooterHint False `shouldNotBe` excerptFooterHint True
      let drawn = boardFooterHintLine DualMode defaultBoardMarks
          brief = boardFooterHintLine DualMode defaultBoardMarks {marksExcerptsVisible = False}
      chipsOf drawn `shouldSatisfy` elem (excerptFooterHint True)
      chipsOf brief `shouldSatisfy` elem (excerptFooterHint False)
      -- One chip re-spelled, and the line's inventory otherwise unchanged.
      length (chipsOf brief) `shouldBe` length (chipsOf drawn)
      filter (`notElem` chipsOf drawn) (chipsOf brief) `shouldBe` [excerptFooterHint False]

    it "shows the board's own line whichever state it is in" $ do
      state <- excerptState 12
      boardHintLine state `shouldBe` boardFooterHintLine DualMode defaultBoardMarks
      boardHintLine (toggleCardExcerpts state)
        `shouldBe` boardFooterHintLine DualMode defaultBoardMarks {marksExcerptsVisible = False}

    -- Requirement 5's other two surfaces are projections, so they need nothing
    -- here beyond the row appearing: "Spec.UI.Keys" holds the description and
    -- the §7 contract against each other and against the document.
    it "gives the binding a help row of its own" $
      helpLines DualMode `shouldSatisfy` any (Text.isInfixOf (binding ToggleExcerpts).bindingDescription)

  -- Requirement 1's last clause and the review's amendment on it: the overlay
  -- renders the whole body, and opening it neither reads nor moves the board's
  -- own density.
  describe "the details overlay" $
    it "shows the whole body while the board is hiding excerpts" $ do
      state <- excerptState 12
      let brief = toggleCardExcerpts state
          item = IssueItem (excerptIssue 1)
      detailsText (renderDetailsForState brief item) "Body"
        `shouldBe` detailsText (renderDetailsForState state item) "Body"
      detailsText (renderDetailsForState brief item) "Body"
        `shouldSatisfy` maybe False (Text.isInfixOf excerptMarker)
      -- Opening it is not a density change either.
      (brief {appOverlay = Just (DetailsOverlay item)}).appExcerptsVisible `shouldBe` False

-- | The configured excerpt height every state below is built at unless it
-- names another, which is the compiled default 'Kanban.Config' ships.
defaultExcerptLimit :: Int
defaultExcerptLimit = cardExcerptLimit True testResolvedConfig

-- | The fixture configuration at one excerpt height.
configuredFor :: Int -> ResolvedConfig
configuredFor lines' = testResolvedConfig {resolvedLimits = LimitsConfig lines'}

-- | The word every fixture card's body is made of, and nothing else on a card
-- says. A row carrying it is an excerpt row; the count of them is the budget
-- in force, read off the frame rather than predicted.
excerptMarker :: Text
excerptMarker = "zzexcerpt"

-- | An issue whose body wraps to more excerpt rows than any budget here
-- allows, so the rows drawn are the budget rather than the body's own length.
excerptIssue :: Int -> Issue
excerptIssue number =
  Issue
    number
    ("Issue " <> Text.pack (show number))
    (Text.unwords (replicate 60 excerptMarker))
    "https://example.test"
    IssueOpen
    []
    []
    epoch
    epoch
    0
    0
    SubIssuesNotRequested
    []

-- | A board showing @count@ of those in Issues, with nothing measured.
excerptState :: Int -> IO AppState
excerptState = excerptStateAt defaultExcerptLimit

-- | The same board at a named configured excerpt height.
excerptStateAt :: Int -> Int -> IO AppState
excerptStateAt configured count = do
  state <- testAppState board
  pure
    state
      { appVisibleBoard = board,
        appConfig = configuredFor configured,
        appLayoutInputs = unmeasuredLayoutInputs testOptions (configuredFor configured),
        appSidebarVisible = False,
        appEnsureSelectionVisible = True
      }
  where
    board = fixtureBoard [(Issues, [Standalone (IssueItem (excerptIssue number)) | number <- [1 .. count]])]

excerptsShown :: Bool -> AppState -> AppState
excerptsShown visible state = state {appExcerptsVisible = visible}

-- | The frame width and height every assertion here is taken at, and the width
-- the Issues column is drawn at inside it. The sidebar is hidden in these
-- states, so the board keeps the whole frame less the shell border's two
-- columns, and the first of 'responsiveColumnWidths' is Issues.
frameWidth, frameHeight :: Int
frameWidth = 164

frameHeight = 50

issuesWidth :: Int
issuesWidth = case responsiveColumnWidths (frameWidth - 2) of
  width : _ -> width
  [] -> 0

-- | One settle, at the offset a frame of this size would have reported.
settle :: AppState -> AppState
settle = refreshColumnWindows [(column, Just (issuesWidth, 0)) | column <- allColumns]

-- | The same board with nothing measured, so every column draws in full.
unmeasure :: AppState -> AppState
unmeasure state = state {appColumnWindows = Map.empty}

held :: Maybe ColumnWindow -> Bool
held = maybe False (const True)

-- | Every item the whole column would draw, and the ones a frame builds.
allItems :: AppState -> [ColumnItem]
allItems state = columnItemsIn (expandedTrackersFor state Issues) (entriesFor state Issues)

drawnItems :: AppState -> [ColumnItem]
drawnItems state = columnBodyItems state Issues issuesWidth frameHeight

-- | The rows one item takes once drawn, read off the drawing rather than
-- predicted: a marker row is placed under it and its position is the height.
renderedHeight :: AppState -> ColumnItem -> Int
renderedHeight state item =
  length (takeWhile (/= heightMarker) (renderWidgetLines (themeFor state.appOptions) issuesWidth widget))
  where
    widget = hLimit issuesWidth (drawColumnItem state Issues item <=> txt heightMarker)

heightMarker :: Text
heightMarker = "END"

-- | The rows the column's first card draws, with the trailing padding trimmed
-- away so two states can be compared row for row.
--
-- The first /card/, not the first item: a run of untracked entries opens with
-- the @STANDALONE@ label, which draws one row and no excerpt.
cardRows :: AppState -> [Text]
cardRows state = case [item | item@(ColumnCard _ _ _) <- allItems state] of
  item : _ -> map Text.stripEnd (renderWidgetLines (themeFor state.appOptions) issuesWidth (hLimit issuesWidth (drawColumnItem state Issues item)))
  [] -> []

-- | The whole frame as cells, characters and attributes together: §10's split
-- border is a color contract on glyphs that are identical either way, so a
-- comparison that dropped the attribute would not be a comparison of frames.
frameCells :: AppState -> [[FrameCell]]
frameCells state =
  renderFrameCells (themeFor state.appOptions) (frameWidth, frameHeight) (drawApplication state)

-- | Everything about a board this key must leave exactly as it found it, as
-- one comparable value each.
boardFacts :: [AppState -> String]
boardFacts =
  [ show . (.appBoardFreshness),
    show . (.appBoardEpoch),
    show . (.appLastSuccessfulFetch),
    show . (.appCompletedStatus),
    show . (.appOpenGeneration),
    show . (.appCompletedGeneration),
    show . (.appFilterCriteria),
    show . (.appSearch),
    show . (.appSettings),
    show . (.appConfig),
    show . (.appOptions),
    show . (.appSidebarVisible),
    show . (.appOverlay),
    show . (.appSelectedColumn),
    show . (.appSelectedRows),
    show . (.appExpandedTrackers),
    show . (.appLayoutEpoch),
    show . (.appNotice)
  ]

chipsOf :: Text -> [Text]
chipsOf = Text.splitOn "  "

-- | A board waiting behind the completed-history blocker, which draws no card
-- at all and so makes every key that reaches one inert.
blockedOnCompletedLoad :: AppState -> AppState
blockedOnCompletedLoad state =
  state
    { appFilterCriteria =
        state.appFilterCriteria
          {filterLifecycle = Set.insert LifecycleClosed state.appFilterCriteria.filterLifecycle},
      appCompletedStatus = CompletedHistoryLoading
    }

-- | Long enough that the viewport at either end is nowhere near the other.
scriptedColumnLength :: Int
scriptedColumnLength = 200

-- | Run one script against the real dashboard on a terminal of this size.
script :: [ScriptStep] -> IO DashboardRun
script steps = do
  state <- excerptState scriptedColumnLength
  runDashboardScript (frameWidth, frameHeight) id state (steps <> [quitStep])

key :: Char -> ScriptStep
key character = Press (Vty.EvKey (Vty.KChar character) [])

-- | The terminal the resize step ends on: narrower, so every card rewraps, and
-- taller, so the viewport shows rows no measurement before it covered.
resizedTo :: (Int, Int)
resizedTo = (frameWidth - 24, frameHeight + 14)

-- | A finished refresh publishing @count@ of the fixture issues, which is how
-- the board is rebuilt underneath a toggle.
refreshTo :: Int -> ScriptStep
refreshTo count =
  Deliver
    ( BoardRefreshFinished
        0
        (BoardRefreshCompleted (Right (GitHubResult (RepoSnapshot [excerptIssue number | number <- [1 .. count]] [] epoch) [])))
    )

-- | The heading a card draws, which is how a frame is asked whether that card
-- is on it.
cardHeading :: Int -> Text
cardHeading number = "#" <> Text.pack (show number) <> " "

-- | Whether the last frame a run painted has @needle@ anywhere on it.
lastFrameHas :: DashboardRun -> Text -> Bool
lastFrameHas run needle = any (Text.isInfixOf needle) (concatMap frameRows (take 1 (reverse run.runFrames)))
  where
    frameRows = map (Text.pack . map (.frameCellCharacter))
