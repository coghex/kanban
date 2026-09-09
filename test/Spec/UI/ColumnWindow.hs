-- | The bound on what one board frame costs (issue #640).
--
-- A column used to build every card it held on every frame, so a repository
-- with thousands of open items paid for all of them on every key press, every
-- mouse event, and every refresh. It now builds the cards its viewport can
-- reach and holds every stretch it skipped open with a blank run of exactly
-- the height those cards would have taken.
--
-- Three things have to hold for that to be a fix rather than a trade, and each
-- is asserted here against production code rather than against a helper
-- written for the test:
--
--   * every item is measured at the rows it actually draws at, and a
--     measurement is dated at the instant its earliest relative age changes
--     wording, since the blank runs are built from those heights;
--   * a measured dashboard draws what an unmeasured one draws and resolves
--     clicks to the same cards -- including through brick's own event loop,
--     where a column's scroll offset persists from frame to frame and a wheel
--     press is what moves it; and
--   * what a frame costs stops growing with the column.
module Spec.UI.ColumnWindow (spec) where

import Brick (hLimit, txt, (<=>))
import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.List (isSubsequenceOf)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import Data.Time (UTCTime, addUTCTime)
import Data.Int (Int64)
import GHC.Conc (getAllocationCounter)
import qualified Graphics.Vty as Vty
import Kanban.CLI (Options (..))
import Kanban.Domain
import Kanban.Layout (responsiveColumnWidths)
import Kanban.UI (drawApplication)
import Kanban.Card (displayWidth)
import Kanban.Config (ResolvedConfig (..))
import Kanban.UI.Board
  ( ColumnPiece (..),
    columnBody,
    columnBodyItems,
    columnItemHeight,
    columnScrollStep,
    columnWindowFor,
    drawColumnItem,
    pullRequestPhaseGlyphFor,
    refreshColumnWindows,
    reviewPhaseGlyphFor,
    solvePhaseGlyphFor,
  )
import Kanban.UI.Events (BoardMouseAction (..), boardMousePress)
import Kanban.GitHub (GitHubResult (..))
import Kanban.Filter (FilterBox (..), KindFacet (..), everyFilterBox, toggleFilterBox)
import Kanban.UI.Filter (applyCriteriaChange, facetCount, filteredCount, focusFilterPanel, rawEntryCount, refreshVisibleBoard, settleFacetCounts)
import Kanban.UI.Reconcile (reconcilePullRequestSessions, reconcileReviewSessions)
import Kanban.UI.Search (columnCountText, columnItemsIn, entriesFor, expandedTrackersFor, moveSelectionBy, selectableRowsIn)
import Kanban.UI.Selection (toggleTrackerState)
import Kanban.UI.Theme (themeFor)
import Kanban.UI.Types
import Kanban.UI.Util (allColumns, relativeAge, selectedRow, showText)
import Kanban.Workflow (entryItem)
import Spec.Support.App (testAppState, testPullRequestSession, testReviewSession, testSolveSession, withSolveSession)
import Spec.Support.Dashboard (DashboardRun (..), ScriptStep (..), quitStep, runDashboardScript)
import Spec.Support.Fixtures (baseIssue, basePullRequest, epoch, fixtureBoard, fixtureTrackedEntry, testOptions)
import Spec.Support.Render (FrameCell (..), renderFrameCells, renderWidgetLines)
import Test.Hspec

spec :: Spec
spec = describe "board frame cost" $ do
  describe "measuring an item" $ do
    forM_ [("box glyphs", testOptions), ("ascii glyphs", testOptions {optionAscii = True})] $ \(label, options) ->
      it ("measures every item at the rows it draws at, in " <> label) $ do
        state <- (\value -> value {appOptions = options}) <$> measuredState 40 0
        let items = allItems state
        items `shouldSatisfy` ((> 10) . length)
        map (columnItemHeight state issuesWidth) items `shouldBe` map (renderedHeight state) items

    it "measures a collapsed epic's header" $ do
      state <- (\value -> value {appExpandedTrackers = Set.empty}) <$> measuredState 40 0
      let items = allItems state
      map (columnItemHeight state issuesWidth) items `shouldBe` map (renderedHeight state) items

    it "measures a card a solve badge has narrowed" $ do
      state <- withSolveSession (baseIssue 7 []) SolveRunning <$> measuredState 40 0
      let items = allItems state
      map (columnItemHeight state issuesWidth) items `shouldBe` map (renderedHeight state) items

  describe "dating a measurement" $
    -- A measurement is only good while every card still words its age the way
    -- it did when measured, and an age is a fraction of a second wide. A
    -- deadline computed by adding whole seconds to @now@ instead of counting
    -- from the timestamp lands after the boundary, and the events in between
    -- reuse heights the wording has already outgrown.
    forM_ [0, 0.1, 0.5, 0.9, 0.999] $ \fraction ->
      it ("ends at the instant a card's wording changes, " <> show (fraction :: Double) <> "s into a second") $ do
        state <- agedState fraction
        window <- windowOf state
        deadline <- maybe (fail "the measurement was expected to carry a deadline") pure window.windowDeadline
        let updatedAt = ageFixtureUpdatedAt
        relativeAge state.appNow updatedAt
          `shouldBe` relativeAge (addUTCTime (-0.001) deadline) updatedAt
        relativeAge deadline updatedAt
          `shouldNotBe` relativeAge state.appNow updatedAt

  describe "what a frame builds" $ do
    it "builds every card of a column nothing has measured" $ do
      state <- unmeasuredState 400
      length (drawnItems state) `shouldBe` length (allItems state)

    it "builds the viewport's worth of a measured column, whatever the column holds" $ do
      small <- measuredState 100 0
      large <- measuredState 5000 0
      length (drawnItems small) `shouldBe` length (drawnItems large)
      length (drawnItems large) `shouldSatisfy` (< frameHeight)

    it "builds the viewport's worth wherever in the column the viewport is" $
      forM_ [0, 500, 5000, 40000] $ \top -> do
        state <- measuredState 5000 top
        length (drawnItems state) `shouldSatisfy` (< frameHeight)

    it "builds the viewport's worth for an offset the column has since shrunk past" $ do
      -- Brick clamps a scroll request to the offsets the content can be shown
      -- at, so a press here lands a long way from the recorded offset. Both
      -- reaches are covered and both are bounded.
      state <- measuredState 300 40000
      length (drawnItems state) `shouldSatisfy` (< frameHeight)

    it "builds exactly the items the whole column would draw, in the order it would draw them" $ do
      -- Their rows and entries are what @CardTarget@ and @EpicTarget@ dispatch
      -- through, so a frame that drew a different item at a row would act on a
      -- different card than the one under the pointer.
      state <- measuredState 300 200
      let built = drawnItems state
      built `shouldSatisfy` (not . null)
      built `shouldSatisfy` (`isSubsequenceOf` allItems state)

    it "reaches the selection and the viewport separately when they are far apart" $ do
      -- The selection sits at the top and the viewport two hundred rows down,
      -- so one range covering both would be the whole column between them.
      state <- measuredState 300 200
      length (drawnRuns (body state)) `shouldBe` 2

    it "lays a body out at exactly the rows the whole column takes" $ do
      state <- measuredState 300 200
      window <- windowOf state
      let pieces = body state
          blank = sum [rows | ColumnBlank rows <- pieces]
          built = sum [columnItemHeight state issuesWidth item | ColumnDrawn item <- pieces]
      blank + built `shouldBe` window.windowTotal

  describe "what a frame draws" $ do
    it "draws what the whole column draws, at the top" $
      framesAgree 800 0 0

    it "draws what the whole column draws, with the selection at the last row" $
      framesAgree 800 799 0

    it "draws what the whole column draws, with the selection among an epic's children" $
      framesAgree 800 2 0

    it "draws what the whole column draws, with the selection mid-column" $
      framesAgree 800 400 0

    it "draws what the whole column draws, with a viewport offset that clips a card" $
      framesAgree 800 400 7

    it "draws what the whole column draws while a query narrows it" $ do
      state <- searchedState 800 "Card 12"
      frameCells frameHeight state `shouldBe` frameCells frameHeight (unmeasure state)

    it "draws what the whole column draws with every epic collapsed" $ do
      state <- (\value -> value {appExpandedTrackers = Set.empty}) <$> selectedState 800 400 0
      frameCells frameHeight state `shouldBe` frameCells frameHeight (unmeasure state)

    it "draws what the whole column draws after the column shrank past the offset it was measured at" $ do
      -- The settle measures the new, shorter column against the offset the
      -- taller one left behind, so the recorded offset is past the end of what
      -- there is to show. Brick answers that by putting the crop back at the
      -- top, and nothing here is going to pull it anywhere else: the selection
      -- is where the user left it, so no scroll-into-view is pending.
      state <- unmeasuredState 3
      let shrunk = settleAt 4000 state {appEnsureSelectionVisible = False}
      frameCells frameHeight shrunk `shouldBe` frameCells frameHeight (unmeasure shrunk)

    it "draws what the whole column draws into a viewport taller than the one it was measured for" $
      -- The rows a viewport shows are read from the frame's own context rather
      -- than from the measurement, so a viewport that grew -- a filter panel
      -- closing, a wrapped footer shrinking, a taller terminal -- crops rows
      -- the measurement never knew about and still finds them drawn.
      forM_ [frameHeight, frameHeight + 20, frameHeight + 60] $ \height -> do
        state <- selectedState 800 400 0
        frameCells height state `shouldBe` frameCells height (unmeasure state)

  describe "a dashboard driven through brick's own event loop" $ do
    it "draws what an unmeasured one draws while the wheel scrolls a column" $
      scriptAgrees (replicate 12 wheelDown) >>= \run ->
        -- A positive control on every script below: the wheel really moved the
        -- viewport, so these are comparisons of scrolled frames.
        take 1 run.runFrames `shouldNotBe` take 1 (reverse run.runFrames)

    it "draws what an unmeasured one draws when a query shrinks a column under a scrolled viewport" $ do
      -- The offset is most of the way down eight hundred cards when the query
      -- leaves a handful. The settle re-measures the shorter column against
      -- the offset the taller one ended at, which is the offset brick is about
      -- to clamp away from.
      _ <- scriptAgrees (replicate 30 wheelDown <> map key "sCard 123")
      pure ()

    it "draws what an unmeasured one draws when an epic collapses under a scrolled viewport" $ do
      _ <- scriptAgrees (replicate 20 wheelDown <> [key 'g', key 'e'])
      pure ()

    it "draws what an unmeasured one draws when criteria filtering empties a scrolled column" $ do
      -- The panel takes the keyboard and Space toggles the box it focuses,
      -- which is a criteria edit: the admitted board is rebuilt and every
      -- column re-seated, under a viewport sitting well down the old one.
      measured <- scriptAgrees (replicate 30 wheelDown <> [key 'F', space])
      -- The edit reached the criteria rather than being swallowed by the
      -- panel: the column is showing something other than what it held.
      shownIn measured Issues `shouldNotBe` scriptedColumnLength

    it "draws what an unmeasured one draws when a refresh shrinks a column under a viewport at its very bottom" $ do
      -- @G@ selects the column's last entry and reveals it, which puts the
      -- viewport at the end of eight hundred cards rather than merely a long
      -- way down them. Then the board comes back holding twelve, and the
      -- settle measures that against the offset the tall column ended at --
      -- which is past everything there now is to show.
      atEnd <- runScript [key 'G'] id
      -- The viewport really is at the bottom: the last card of the column is
      -- on screen and the first is not.
      lastFrameHas atEnd (lastCardHeading scriptedColumnLength) `shouldBe` True
      lastFrameHas atEnd firstCardHeading `shouldBe` False
      measured <- scriptAgrees [key 'G', refreshTo 12]
      shownIn measured Issues `shouldBe` 12

    it "draws what an unmeasured one draws when the terminal is resized under a scrolled column" $ do
      -- A resize changes the width every card wraps at and the rows the
      -- viewport shows at once, so no measurement taken before it describes
      -- the column any more.
      measured <- scriptAgrees (replicate 12 wheelDown <> [Resize resizedTo, wheelDown, wheelDown])
      -- The terminal really did change size: the last frame is the new one.
      map length (take 1 (reverse measured.runFrames)) `shouldBe` [snd resizedTo]

    it "draws what an unmeasured one draws when the filter panel gives a scrolled column its rows back" $ do
      -- The panel takes rows from every column while it is up, so hiding it
      -- again leaves the columns taller than they were when brick last
      -- reported their geometry. Those extra rows are cropped from a
      -- measurement that never saw them.
      _ <- scriptAgrees (replicate 12 wheelDown <> [key 'F', key 'F'])
      pure ()

    it "resolves a click after scrolling to the same card an unmeasured one does" $ do
      let script = replicate 12 wheelDown <> [press cardPoint]
      measured <- runScript script id
      whole <- runScript script unmeasure
      measured.runState.appSelectedRows `shouldBe` whole.runState.appSelectedRows
      measured.runState.appSelectedColumn `shouldBe` whole.runState.appSelectedColumn
      -- And the click resolved to a card rather than to nothing, so the
      -- agreement above is about a target and not about two no-ops.
      Map.lookup Issues measured.runState.appSelectedRows `shouldNotBe` Just 0
      measured.runFrames `shouldBe` whole.runFrames

    it "resolves a click on an epic header after the viewport has been scrolled" $ do
      -- Down and back up again, both through real scroll requests, so the
      -- header is clicked in a viewport whose offset brick has moved rather
      -- than one that never left the top.
      let script = replicate 12 wheelDown <> replicate 12 wheelUp <> [press epicPoint]
      measured <- runScript script id
      whole <- runScript script unmeasure
      measured.runState.appExpandedTrackers `shouldBe` whole.runState.appExpandedTrackers
      measured.runState.appSelectedRows `shouldBe` whole.runState.appSelectedRows
      -- The click reached the epic: its group is no longer open.
      measured.runState.appExpandedTrackers `shouldBe` Set.empty
      measured.runFrames `shouldBe` whole.runFrames

  describe "what a badge costs a card" $ do
    -- The measurement stands on this: every badge is the same width, so which
    -- cards carry one decides the geometry and which phase they are in does
    -- not. Asked of every phase of every kind in both glyph sets, so a new
    -- phase or a re-spelled glyph of another width fails here rather than by
    -- drawing a card at a height nothing measured.
    forM_ [("box glyphs", False), ("ascii glyphs", True)] $ \(label, useAscii) ->
      it ("is two cells wide in every phase, in " <> label) $ do
        let solveWidths = [displayWidth (solvePhaseGlyphFor useAscii (testSolveSession (baseIssue 1 []) phase)) | phase <- [minBound .. maxBound]]
            reviewWidths = [displayWidth (reviewPhaseGlyphFor useAscii (testReviewSession (baseIssue 1 []) phase)) | phase <- [minBound .. maxBound]]
            pullRequestWidths =
              [ displayWidth (pullRequestPhaseGlyphFor useAscii (testPullRequestSession (basePullRequest 1 [] False []) phase))
                | phase <- [minBound .. maxBound]
              ]
        solveWidths `shouldSatisfy` ((>= 8) . length)
        reviewWidths `shouldSatisfy` ((>= 8) . length)
        (solveWidths <> reviewWidths <> pullRequestWidths) `shouldSatisfy` all (== badgeCellWidth)

    it "changes a roster's size when a card starts carrying one" $ do
      -- Which is what lets three sizes stand for the whole badge geometry.
      state <- unmeasuredState 20
      let running = withSolveSession (baseIssue 4 []) SolveRunning state
      Map.size running.appSolveSessions `shouldNotBe` Map.size state.appSolveSessions

    it "keeps a roster's keys through the reconciliations that rebuild one" $ do
      -- The other half of that: a size stands for a membership only while
      -- nothing removes a key, and these two are the only paths that rebuild
      -- a roster at all.
      state <- unmeasuredState 20
      let sessions = (withSolveSession (baseIssue 4 []) SolveRunning state).appSolveSessions
          reviews = Map.fromList [(4, testReviewSession (baseIssue 4 []) ReviewRunning)]
          pullRequests = Map.fromList [(9, testPullRequestSession (basePullRequest 9 [] False []) SolveRunning)]
      Map.keys (reconcileReviewSessions state.appConfig.resolvedWorkflow [] reviews) `shouldBe` Map.keys reviews
      Map.keys (reconcilePullRequestSessions [] pullRequests) `shouldBe` Map.keys pullRequests
      Map.keys sessions `shouldBe` [4]

  describe "what invalidates a measurement" $ do
    it "keeps one taken from the state that is still current" $ do
      state <- measuredState 200 0
      columnWindowFor state Issues issuesWidth `shouldSatisfy` measurementHeld

    it "drops one taken at another width, which is what a resize leaves behind" $ do
      state <- measuredState 200 0
      columnWindowFor state Issues (issuesWidth - 1) `shouldSatisfy` (not . measurementHeld)

    it "drops one taken from another board, which is what a refresh or a criteria edit leaves behind" $ do
      state <- measuredState 200 0
      columnWindowFor state {appBoardEpoch = state.appBoardEpoch + 1} Issues issuesWidth
        `shouldSatisfy` (not . measurementHeld)

    it "drops one taken before a search box opened" $ do
      state <- measuredState 200 0
      columnWindowFor state {appSearch = Just (ColumnSearch Issues "")} Issues issuesWidth
        `shouldSatisfy` (not . measurementHeld)

    it "drops one taken before an epic's disclosure changed" $ do
      state <- measuredState 200 0
      columnWindowFor (toggleTrackerState Issues 0 epicNumber state) Issues issuesWidth
        `shouldSatisfy` (not . measurementHeld)

    it "moves the expansion counter with the set every toggle writes" $ do
      state <- measuredState 200 0
      let toggled = toggleTrackerState Issues 0 epicNumber state
      toggled.appExpandedTrackers `shouldNotBe` state.appExpandedTrackers
      toggled.appExpansionEpoch `shouldNotBe` state.appExpansionEpoch

    it "stops trusting one taken before a badge appeared beside a card" $ do
      -- A badge takes cells from the width its card wraps at, so a
      -- measurement taken without it no longer describes the column. The
      -- settle is what notices, because noticing costs the sessions the
      -- dashboard holds and a frame's own check has to stay constant-time.
      state <- measuredState 200 0
      let running = settle (withSolveSession (baseIssue 4 []) SolveRunning state)
      running.appLayoutEpoch `shouldNotBe` state.appLayoutEpoch
      columnWindowFor running {appColumnWindows = state.appColumnWindows} Issues issuesWidth
        `shouldSatisfy` (not . measurementHeld)

    it "drops one whose earliest relative age has since changed wording" $ do
      state <- measuredState 200 0
      window <- windowOf state
      deadline <- maybe (fail "the measurement was expected to carry a deadline") pure window.windowDeadline
      columnWindowFor state {appNow = deadline} Issues issuesWidth `shouldSatisfy` (not . measurementHeld)

    it "bumps the board epoch every time the admitted board is rebuilt" $ do
      state <- unmeasuredState 10
      (refreshVisibleBoard state).appBoardEpoch `shouldBe` state.appBoardEpoch + 1

  describe "what a measurement answers for" $
    it "counts a column's heading from the measurement it already took" $ do
      measured <- measuredState 200 0
      unmeasured <- unmeasuredState 200
      columnCountText measured Issues `shouldBe` columnCountText unmeasured Issues
      columnCountText measured Issues `shouldBe` showText (200 :: Int)

  describe "the wheel" $ do
    it "moves a column by three rows" $
      columnScrollStep `shouldBe` 3

    it "does not pull the selection back into view" $ do
      state <- measuredState 200 0
      let scrolled = boardMousePress (ScrollColumnBy Issues columnScrollStep) state
      scrolled.appEnsureSelectionVisible `shouldBe` False
      scrolled.appSelectedRows `shouldBe` state.appSelectedRows

  describe "what a selection move costs" $ do
    it "stops growing with the column it moves through" $ do
      -- Moving the selection used to rebuild the column's selectable rows and
      -- then walk them twice, for the current position and for the length. It
      -- reads the prepared ones now, and a bisection of five thousand rows is
      -- not meaningfully longer than one of a hundred.
      small <- measuredState 100 0
      large <- measuredState 5000 0
      smallCost <- movementAllocations small
      largeCost <- movementAllocations large
      (fromIntegral largeCost / fromIntegral (max 1 smallCost) :: Double) `shouldSatisfy` (< 3)

    it "stops growing at either end of the column it moves through" $ do
      small <- measuredState 100 0
      large <- measuredState 5000 0
      smallCost <- boundaryAllocations small
      largeCost <- boundaryAllocations large
      (fromIntegral largeCost / fromIntegral (max 1 smallCost) :: Double) `shouldSatisfy` (< 3)

    it "moves the selection to the same rows a column with no measurement does" $ do
      -- Bounded and identical: the prepared rows are the rows the column
      -- always offered, so a move resolves the same way with or without them.
      measured <- measuredState 300 0
      let whole = unmeasure measured
          walk state = scanl (\current amount -> moveSelectionBy amount current) state movements
          rowsOf state = [Map.lookup Issues value.appSelectedRows | value <- walk state]
      rowsOf measured `shouldBe` rowsOf whole
      rowsOf measured `shouldSatisfy` ((> 3) . length . filter (/= Just 0))

  describe "what a filter-panel frame costs" $ do
    it "stops growing with the board once the panel's figures are worked out" $ do
      -- Every checkbox shows a count over the complete datasets and the panel
      -- states two more, so a frame that worked them out cost sixteen passes
      -- over everything the board holds -- on every redraw the panel was up
      -- for, including one that only moved the focus.
      small <- panelState 100
      large <- panelState 5000
      smallCost <- frameAllocations small
      largeCost <- frameAllocations large
      (fromIntegral largeCost / fromIntegral (max 1 smallCost) :: Double) `shouldSatisfy` (< 3)

    it "shows the figures a panel that counted them per frame would show" $ do
      -- Prepared and identical: the same counts, from the same function.
      prepared <- panelState 300
      let counted = prepared {appFacetCounts = Nothing}
      map (facetCount prepared) everyFilterBox `shouldBe` map (facetCount counted) everyFilterBox
      filteredCount prepared `shouldBe` filteredCount counted
      rawEntryCount prepared `shouldBe` rawEntryCount counted
      map (facetCount prepared) everyFilterBox `shouldSatisfy` any (/= FacetCountExact 0)

    it "works them out again when the criteria they were counted under change" $ do
      prepared <- panelState 300
      let edited = settleFacetCounts (applyCriteriaChange (toggleFilterBox (KindBox KindPullRequests)) prepared)
      edited.appFacetCounts `shouldNotBe` prepared.appFacetCounts

    it "keeps none while the panel is hidden" $ do
      prepared <- panelState 300
      (settleFacetCounts prepared {appFilterPanel = Nothing}).appFacetCounts `shouldBe` Nothing

  describe "what a settle costs" $
    it "stops growing with the sessions a dashboard has kept" $ do
      -- Deciding whether a measurement still holds must not cost the agent
      -- sessions a long-lived dashboard has accumulated. Both settles below
      -- find everything current and rebuild nothing, so what they differ by is
      -- exactly the cost of asking.
      few <- withRetainedSessions 2 <$> measuredState 200 0
      many <- withRetainedSessions 2000 <$> measuredState 200 0
      fewCost <- settleAllocations few
      manyCost <- settleAllocations many
      Map.size many.appSolveSessions `shouldBe` 2000
      manyCost `shouldBe` fewCost

  describe "what a frame costs" $
    forM_ selectionCases $ \(label, row) ->
      it ("stops growing with the column a measurement covers, with the selection " <> label) $ do
        measuredGrowth <- costGrowth row id
        wholeGrowth <- costGrowth row unmeasure
        -- The baseline is the same production frame with nothing measured,
        -- which is what the board did before this: fifty times the cards
        -- allocate tens of times as much. Measured, both frames allocate about
        -- the same few megabytes.
        wholeGrowth `shouldSatisfy` (> 10)
        measuredGrowth `shouldSatisfy` (< 3)
        wholeGrowth / measuredGrowth `shouldSatisfy` (> 10)

-- | The selections the cost of a frame is measured at: the row a column opens
-- on, a child inside its epic, and the row at its far end.
selectionCases :: [(String, Int -> Int)]
selectionCases = [("at the first row", const 0), ("among an epic's children", const 2), ("at the last row", subtract 1)]

-- | The frame width and height every assertion here is taken at.
frameWidth, frameHeight :: Int
frameWidth = 164

frameHeight = 50

-- | The width the Issues column is drawn at in that frame.
--
-- The sidebar is hidden in these states, so the board keeps the whole frame
-- less the shell border's two columns, and the first of
-- 'responsiveColumnWidths' is Issues.
issuesWidth :: Int
issuesWidth = case responsiveColumnWidths (frameWidth - 2) of
  width : _ -> width
  [] -> 0

-- | A dashboard showing @count@ entries in Issues, with nothing measured.
unmeasuredState :: Int -> IO AppState
unmeasuredState count = do
  state <- testAppState board
  pure
    state
      { appVisibleBoard = board,
        appSidebarVisible = False,
        appExpandedTrackers = Set.singleton epicNumber,
        appEnsureSelectionVisible = True
      }
  where
    board = fixtureBoard [(Issues, columnEntries count)]

-- | The same dashboard, measured against the geometry brick would have
-- reported for it after the frame before this one.
measuredState :: Int -> Int -> IO AppState
measuredState count top = settleAt top <$> unmeasuredState count

-- | One settle, at the offset brick last reported.
settleAt :: Int -> AppState -> AppState
settleAt top = refreshColumnWindows [(column, Just (issuesWidth, top)) | column <- allColumns]

settle :: AppState -> AppState
settle = settleAt 0

-- | The same dashboard with nothing measured, so every column draws in full.
-- This is what the board did before issue #640, produced by the same
-- production code with the preparation suppressed.
unmeasure :: AppState -> AppState
unmeasure state = state {appColumnWindows = Map.empty}

-- | A measured dashboard with @row@ selected and waiting to be revealed.
selectedState :: Int -> Int -> Int -> IO AppState
selectedState count row top = do
  state <- unmeasuredState count
  pure (settleAt top state {appSelectedRows = Map.insert Issues row state.appSelectedRows})

-- | A measured dashboard with a live query narrowing Issues.
searchedState :: Int -> Text -> IO AppState
searchedState count query = do
  state <- unmeasuredState count
  pure (settle state {appSearch = Just (ColumnSearch Issues query)})

-- | A measured dashboard whose one card was updated @fraction@ of a second
-- past a whole second ago, so its wording boundary falls between two ticks.
agedState :: Double -> IO AppState
agedState fraction = do
  state <- testAppState board
  pure
    ( settle
        state
          { appVisibleBoard = board,
            appSidebarVisible = False,
            appNow = addUTCTime (realToFrac (59 + fraction)) ageFixtureUpdatedAt
          }
    )
  where
    board = fixtureBoard [(Issues, [Standalone (IssueItem (baseIssue 1 []) {issueUpdatedAt = ageFixtureUpdatedAt})])]

ageFixtureUpdatedAt :: UTCTime
ageFixtureUpdatedAt = epoch

-- | The measured frame and the whole-column frame, cell for cell.
framesAgree :: Int -> Int -> Int -> Expectation
framesAgree count row top = do
  state <- selectedState count row top
  drawnItems state `shouldSatisfy` ((< length (allItems state)) . length)
  frameCells frameHeight state `shouldBe` frameCells frameHeight (unmeasure state)

-- | The whole frame as cells, characters and attributes together: §10's split
-- border is a color contract on glyphs that are identical either way, so a
-- comparison that dropped the attribute would not be a comparison of frames.
frameCells :: Int -> AppState -> [[FrameCell]]
frameCells height state =
  renderFrameCells (themeFor state.appOptions) (frameWidth, height) (drawApplication state)

-- | The body one frame of Issues draws, and the items in it.
body :: AppState -> [ColumnPiece]
body state = columnBody state Issues issuesWidth frameHeight

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

-- | Every item the whole column would draw.
allItems :: AppState -> [ColumnItem]
allItems state = columnItemsIn (expandedTrackersFor state Issues) (entriesFor state Issues)

windowOf :: AppState -> IO ColumnWindow
windowOf state = case columnWindowFor state Issues issuesWidth of
  Just window -> pure window
  Nothing -> fail "the state was expected to carry a current measurement of Issues"

measurementHeld :: Maybe ColumnWindow -> Bool
measurementHeld = maybe False (const True)

-- | The runs of items a body builds, split by the blank runs between them.
drawnRuns :: [ColumnPiece] -> [[ColumnItem]]
drawnRuns pieces = filter (not . null) (foldr collect [[]] pieces)
  where
    collect (ColumnBlank _) runs = [] : runs
    collect (ColumnDrawn item) (run : rest) = (item : run) : rest
    collect (ColumnDrawn item) [] = [[item]]

-- | Run one script against the real dashboard, twice, and require the two to
-- have painted the same terminal.
--
-- One run is the dashboard as it behaves; the other suppresses the
-- measurement after every event, which is the same production draw and
-- dispatch with the preparation taken away -- the board before issue #640.
-- Anything the windowing gets wrong about where brick will crop shows up as a
-- frame that differs.
scriptAgrees :: [ScriptStep] -> IO DashboardRun
scriptAgrees script = do
  measured <- runScript script id
  whole <- runScript script unmeasure
  length measured.runFrames `shouldBe` length whole.runFrames
  measured.runFrames `shouldBe` whole.runFrames
  pure measured

-- | How many entries a run's dashboard ended up showing in @column@.
shownIn :: DashboardRun -> BoardColumn -> Int
shownIn run column = length (entriesFor run.runState column)

-- | Whether the last frame a run painted has @needle@ anywhere on it.
lastFrameHas :: DashboardRun -> Text -> Bool
lastFrameHas run needle = any (Text.isInfixOf needle) (concatMap frameRows (take 1 (reverse run.runFrames)))
  where
    frameRows = map (Text.pack . map (.frameCellCharacter))

-- | The heading a card draws, which is how a frame is asked whether that card
-- is on it.
firstCardHeading :: Text
firstCardHeading = "#1 "

lastCardHeading :: Int -> Text
lastCardHeading count = "#" <> showText count <> " "

-- | The terminal the resize script ends on: narrower, so every card rewraps,
-- and taller, so the viewport shows rows no measurement before it covered.
resizedTo :: (Int, Int)
resizedTo = (frameWidth - 24, frameHeight + 14)

runScript :: [ScriptStep] -> (AppState -> AppState) -> IO DashboardRun
runScript script adjust = do
  state <- unmeasuredState scriptedColumnLength
  runDashboardScript (frameWidth, frameHeight) adjust state (script <> [quitStep])

-- | Long enough that a scrolled viewport is nowhere near either end, short
-- enough that the unmeasured half of each comparison stays quick.
scriptedColumnLength :: Int
scriptedColumnLength = 800

-- | Where a press lands on the board: a point inside a card of the Issues
-- column, and a point on the epic header that column opens with.
--
-- Both are read off the frame the same way a user would: the shell border
-- takes the first column and row, the board's own heading row the second, and
-- the column\'s top padding the third.
cardPoint, epicPoint :: (Int, Int)
cardPoint = (10, 10)

epicPoint = (10, 4)

-- | A wheel press over a card of the Issues column.
wheelDown, wheelUp :: ScriptStep
wheelDown = Press (Vty.EvMouseDown (fst cardPoint) (snd cardPoint) Vty.BScrollDown [])

wheelUp = Press (Vty.EvMouseDown (fst cardPoint) (snd cardPoint) Vty.BScrollUp [])

press :: (Int, Int) -> ScriptStep
press (x, y) = Press (Vty.EvMouseDown x y Vty.BLeft [])

key :: Char -> ScriptStep
key character = Press (Vty.EvKey (Vty.KChar character) [])

space :: ScriptStep
space = Press (Vty.EvKey (Vty.KChar ' ') [])

-- | A finished refresh publishing @count@ standalone issues, which is how a
-- board shrinks underneath a viewport that is nowhere near the top.
refreshTo :: Int -> ScriptStep
refreshTo count =
  Deliver
    ( BoardRefreshFinished
        0
        (BoardRefreshCompleted (Right (GitHubResult (RepoSnapshot issues [] epoch) [])))
    )
  where
    issues = [issueOf (varyingEntry number) | number <- [4 .. 3 + count]]
    issueOf entry = case entryItem entry of
      IssueItem issue -> issue
      PullRequestItem _ -> baseIssue 0 []

-- | How much more a frame of a five-thousand-card column costs than one of a
-- hundred-card column, in bytes the production frame allocates with every cell
-- forced to normal form.
--
-- Allocation rather than elapsed time, deliberately: this suite already
-- carries one timing-sensitive example that flakes under load, and what is
-- being told apart here is a factor of fifty against a factor of one.
costGrowth :: (Int -> Int) -> (AppState -> AppState) -> IO Double
costGrowth row adjust = do
  small <- selectedState 100 (row 100) 0 >>= frameAllocations . adjust
  large <- selectedState 5000 (row 5000) 0 >>= frameAllocations . adjust
  pure (fromIntegral large / fromIntegral (max 1 small))

-- | A dashboard holding @count@ finished sessions of each kind, none of which
-- any card on these boards is for.
withRetainedSessions :: Int -> AppState -> AppState
withRetainedSessions count state =
  state
    { appSolveSessions = Map.fromList [(number, testSolveSession (baseIssue number []) SolveFinished) | number <- numbers],
      appReviewSessions = Map.fromList [(number, testReviewSession (baseIssue number []) ReviewFinished) | number <- numbers],
      appPullRequestReviewSessions =
        Map.fromList [(number, testPullRequestSession (basePullRequest number [] False []) SolveFinished) | number <- numbers]
    }
  where
    numbers = [100000 .. 100000 + count - 1]

-- | Bytes one settle allocates once everything it could prepare is already
-- prepared -- which is what every selection, wheel, and animation event pays.
settleAllocations :: AppState -> IO Int64
settleAllocations state = do
  -- Two settles first: the first notices the sessions and measures every
  -- column against them, the second finds that measurement current. What is
  -- measured is a third, which has nothing left to do but ask whether the
  -- measurement still holds.
  settled <- evaluate (settleAt 0 (settleAt 0 state))
  _ <- evaluate (measurementSize settled)
  allocationsDuring (evaluate (measurementSize (settleAt 0 settled)))

-- | Everything a settle decides, forced. 'AppState' holds channels and
-- mutable cells and so cannot be forced whole; this is the part a settle
-- writes, and reading it is what makes the measurement above the settle's own
-- work rather than a thunk's.
measurementSize :: AppState -> Int
measurementSize state =
  state.appLayoutEpoch
    + sum
      [ window.windowTotal
          + window.windowLeading
          + window.windowShownCount
          + window.windowAdmittedCount
          + window.windowTop
          + Vector.length window.windowItems
          + Vector.sum window.windowTops
          + Vector.sum window.windowHeights
          + Vector.sum window.windowItemRows
        | window <- Map.elems state.appColumnWindows
      ]

frameAllocations :: AppState -> IO Int64
frameAllocations state = do
  -- A first frame, discarded: it forces whatever in the board itself was still
  -- a thunk, so what the second one allocates is the frame's own work.
  _ <- evaluate (force (frameCells frameHeight state))
  allocationsDuring (evaluate (force (frameCells frameHeight state)))

-- | A measured dashboard with the filter panel up and its figures worked out,
-- which is the frame this bound is about.
panelState :: Int -> IO AppState
panelState count = do
  state <- unmeasuredState count
  pure (settleFacetCounts (settleAt 0 (focusFilterPanel state)))

-- | The moves the selection regressions walk: down through the column, back
-- up, and past both ends.
movements :: [Int]
movements = [1, 1, 1, 5, 40, -3, -1, 500, -500, 1, -1]

-- | Bytes a run of selection moves allocates.
movementAllocations :: AppState -> IO Int64
movementAllocations state = do
  _ <- evaluate (movedRows state)
  allocationsDuring (evaluate (movedRows state))

movedRows :: AppState -> Int
movedRows state = sum [selectedRow current Issues | current <- scanl (flip moveSelectionBy) state movements]

-- | Bytes selecting each end of a column allocates.
boundaryAllocations :: AppState -> IO Int64
boundaryAllocations state = do
  _ <- evaluate (boundaryRows state)
  allocationsDuring (evaluate (boundaryRows state))

boundaryRows :: AppState -> Int
boundaryRows state = sum [maybe 0 id (rows Vector.!? index) | index <- [0, Vector.length rows - 1]]
  where
    rows = selectableRowsIn state Issues

-- | Bytes @action@ allocates, exactly.
--
-- The per-thread allocation counter rather than the runtime's own total: that
-- total moves only when a nursery block is retired, so work of a few hundred
-- bytes reads as either nothing or four megabytes depending on where that
-- boundary happens to fall, which is not a measurement.
allocationsDuring :: IO value -> IO Int64
allocationsDuring action = do
  opening <- getAllocationCounter
  _ <- action
  closing <- getAllocationCounter
  pure (opening - closing)

-- | The cells every badge takes, whatever its phase or glyph set.
badgeCellWidth :: Int
badgeCellWidth = 2

-- | The epic every one of these columns opens with.
epicNumber :: Int
epicNumber = 700

-- | A column of @count@ entries: an epic with three children, then standalone
-- cards whose titles, labels, and bodies wrap to different numbers of rows, so
-- the measurement has variable heights to get right rather than a uniform one
-- it could have guessed.
columnEntries :: Int -> [ColumnEntry]
columnEntries count =
  [fixtureTrackedEntry epicNumber [] number | number <- [1 .. min count 3]]
    <> [varyingEntry number | number <- [4 .. count]]

varyingEntry :: Int -> ColumnEntry
varyingEntry number =
  Standalone
    ( IssueItem
        (baseIssue number [])
          { issueTitle = Text.replicate (1 + number `mod` 4) ("Card " <> showText number <> " title words "),
            issueBody = Text.replicate (1 + number `mod` 3) bodySentence,
            issueLabels = take (number `mod` 4) sampleLabels
          }
    )

bodySentence :: Text
bodySentence = "Body text long enough to wrap across the interior of a card. "

sampleLabels :: [Label]
sampleLabels = [Label "ui" "5319e7", Label "bug" "d73a4a", Label "code-health" "1d76db"]
