-- | The bound on what one board frame costs (issue #640).
--
-- A column used to build every card it held on every frame, so a repository
-- with thousands of open items paid for all of them on every key press, every
-- mouse event, and every refresh. It now builds the cards its viewport can
-- reach and holds every stretch it skipped open with a blank run of exactly
-- the height those cards would have taken.
--
-- Three things have to hold for that to be a fix rather than a trade, and each
-- is asserted here against the production frame rather than against a helper
-- written for the test:
--
--   * every item is measured at the rows it actually draws at, since the
--     blank runs are built from those heights and a wrong one moves
--     everything below it;
--   * the frame a measured column draws is byte-identical, attributes
--     included, to the frame the whole column draws, wherever the viewport is
--     and whatever the selection is; and
--   * what a frame costs stops growing with the column.
module Spec.UI.ColumnWindow (spec) where

import Brick (hLimit, txt, (<=>))
import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.List (isSubsequenceOf)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (addUTCTime)
import Data.Word (Word64)
import GHC.Stats (RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Kanban.CLI (Options (..))
import Kanban.Domain
import Kanban.Layout (responsiveColumnWidths)
import Kanban.UI (drawApplication)
import Kanban.UI.Board
  ( ColumnPiece (..),
    columnBody,
    columnBodyItems,
    columnItemHeight,
    columnScrollStep,
    columnWindowFor,
    drawColumnItem,
    refreshColumnWindows,
  )
import Kanban.UI.Events (BoardMouseAction (..), boardMousePress)
import Kanban.UI.Filter (refreshVisibleBoard)
import Kanban.UI.Search (columnCountText, columnItemsIn, entriesFor, expandedTrackersFor)
import Kanban.UI.Theme (themeFor)
import Kanban.UI.Types
import Kanban.UI.Util (allColumns, showText)
import Spec.Support.App (testAppState, withSolveSession)
import Spec.Support.Fixtures (baseIssue, epoch, fixtureBoard, fixtureTrackedEntry, testOptions)
import Spec.Support.Render (FrameCell, renderFrameCells, renderWidgetLines)
import Test.Hspec

spec :: Spec
spec = describe "board frame cost" $ do
  describe "measuring an item" $
    forM_ [("box glyphs", testOptions), ("ascii glyphs", testOptions {optionAscii = True})] $ \(label, options) ->
      it ("measures every item at the rows it draws at, in " <> label) $ do
        state <- (\value -> value {appOptions = options}) <$> measuredState 40 0
        let items = allItems state
        items `shouldSatisfy` ((> 10) . length)
        map (columnItemHeight state issuesWidth) items `shouldBe` map (renderedHeight state) items

    -- A collapsed epic draws a header and no children, and a badge takes a
    -- cell from the width the card beneath it wraps at. Both change what an
    -- item measures to, so both are measured the way they are drawn.
  describe "measuring an item beside live work" $ do
    it "measures a collapsed epic's header" $ do
      state <- (\value -> value {appExpandedTrackers = Set.empty}) <$> measuredState 40 0
      let items = allItems state
      map (columnItemHeight state issuesWidth) items `shouldBe` map (renderedHeight state) items

    it "measures a card a solve badge has narrowed" $ do
      state <- withSolveSession (baseIssue 7 []) SolveRunning <$> measuredState 40 0
      let items = allItems state
      map (columnItemHeight state issuesWidth) items `shouldBe` map (renderedHeight state) items

  describe "what a frame builds" $ do
    it "builds every card of a column nothing has measured" $ do
      state <- unmeasuredState 400
      length (columnBodyItems state Issues issuesWidth) `shouldBe` length (allItems state)

    it "builds the viewport's worth of a measured column, whatever the column holds" $ do
      small <- measuredState 100 0
      large <- measuredState 5000 0
      length (columnBodyItems small Issues issuesWidth)
        `shouldBe` length (columnBodyItems large Issues issuesWidth)
      length (columnBodyItems large Issues issuesWidth) `shouldSatisfy` (< frameHeight)

    it "builds the viewport's worth wherever in the column the viewport is" $
      forM_ [0, 500, 5000, 40000] $ \top -> do
        state <- measuredState 5000 top
        length (columnBodyItems state Issues issuesWidth) `shouldSatisfy` (< frameHeight)

    it "builds exactly the items the whole column would draw, in the order it would draw them" $ do
      -- Their rows and entries are what @CardTarget@ and @EpicTarget@ dispatch
      -- through, so a frame that drew a different item at a row would act on a
      -- different card than the one under the pointer.
      state <- measuredState 300 200
      let built = columnBodyItems state Issues issuesWidth
      built `shouldSatisfy` (not . null)
      built `shouldSatisfy` (`isSubsequenceOf` allItems state)

    it "reaches the selection and the viewport separately when they are far apart" $ do
      -- The selection sits at the top and the viewport two hundred rows down,
      -- so one range covering both would be the whole column between them.
      state <- measuredState 300 200
      let runs = drawnRuns (columnBody state Issues issuesWidth)
      length runs `shouldBe` 2

    it "lays a body out at exactly the rows the whole column takes" $ do
      state <- measuredState 300 200
      window <- windowOf state
      let pieces = columnBody state Issues issuesWidth
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
      frameCells state `shouldBe` frameCells state {appColumnWindows = Map.empty}

    it "draws what the whole column draws with every epic collapsed" $ do
      state <- (\value -> value {appExpandedTrackers = Set.empty}) <$> selectedState 800 400 0
      frameCells state `shouldBe` frameCells state {appColumnWindows = Map.empty}

    it "draws what the whole column draws after the column shrank under the viewport" $ do
      -- The viewport is most of the way down eight hundred cards when the
      -- board comes back holding twenty. Nothing measured describes that
      -- column any more, and the frame says so by laying it out itself.
      tall <- selectedState 800 400 4000
      short <- unmeasuredState 20
      let shrunk =
            tall
              { appBoard = short.appBoard,
                appVisibleBoard = short.appVisibleBoard,
                appBoardEpoch = tall.appBoardEpoch + 1
              }
      columnWindowFor shrunk Issues issuesWidth `shouldSatisfy` (not . measurementHeld)
      frameCells shrunk `shouldBe` frameCells shrunk {appColumnWindows = Map.empty}

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

    it "drops one taken before an epic was collapsed" $ do
      state <- measuredState 200 0
      columnWindowFor state {appExpandedTrackers = Set.empty} Issues issuesWidth
        `shouldSatisfy` (not . measurementHeld)

    it "drops one taken before a badge appeared beside a card" $ do
      state <- measuredState 200 0
      columnWindowFor (withSolveSession (baseIssue 4 []) SolveRunning state) Issues issuesWidth
        `shouldSatisfy` (not . measurementHeld)

    it "drops one whose earliest relative age has since changed wording" $ do
      state <- measuredState 200 0
      window <- windowOf state
      window.windowDeadline `shouldBe` Just (addUTCTime 60 epoch)
      columnWindowFor state {appNow = addUTCTime 60 state.appNow} Issues issuesWidth
        `shouldSatisfy` (not . measurementHeld)

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

  describe "what a frame costs" $
    it "stops growing with the column a measurement covers, and grows with one it does not" $ do
      enabled <- getRTSStatsEnabled
      if not enabled
        then expectationFailure "the suite must run with RTS statistics enabled for this bound to be measurable"
        else do
          measuredGrowth <- costGrowth measuredState
          wholeGrowth <- costGrowth (\count _ -> unmeasuredState count)
          -- The baseline is the same production frame with nothing measured,
          -- which is what the board did before this: fifty times the cards
          -- allocate about forty-six times as much (2.2 GiB against 48 MiB on
          -- the machine this was written on). Measured, both frames allocate
          -- about four megabytes.
          wholeGrowth `shouldSatisfy` (> 10)
          measuredGrowth `shouldSatisfy` (< 3)
          wholeGrowth / measuredGrowth `shouldSatisfy` (> 10)

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

-- | The same dashboard, with the geometry brick would have reported for it
-- after the frame before this one: the column's width, the rows its viewport
-- showed, and the offset it ended at.
--
-- The rows are the whole frame's height rather than the viewport's, which is
-- always fewer. A measurement can only widen what a frame draws for real, so
-- an over-generous height keeps every bound here honest and keeps this fixture
-- from restating the board's own vertical composition.
measuredState :: Int -> Int -> IO AppState
measuredState count top = do
  state <- unmeasuredState count
  pure (refreshColumnWindows [(column, Just (issuesWidth, frameHeight, top)) | column <- allColumns] state)

-- | A measured dashboard with @row@ selected and waiting to be revealed.
selectedState :: Int -> Int -> Int -> IO AppState
selectedState count row top = do
  state <- measuredState count top
  pure state {appSelectedRows = Map.insert Issues row state.appSelectedRows}

-- | A measured dashboard with a live query narrowing Issues.
searchedState :: Int -> Text -> IO AppState
searchedState count query = do
  state <- unmeasuredState count
  let searching = state {appSearch = Just (ColumnSearch Issues query)}
  pure (refreshColumnWindows [(column, Just (issuesWidth, frameHeight, 0)) | column <- allColumns] searching)

-- | The measured frame and the whole-column frame, cell for cell.
framesAgree :: Int -> Int -> Int -> Expectation
framesAgree count row top = do
  state <- selectedState count row top
  columnBodyItems state Issues issuesWidth `shouldSatisfy` ((< length (allItems state)) . length)
  frameCells state `shouldBe` frameCells state {appColumnWindows = Map.empty}

-- | The whole frame as cells, characters and attributes together: §10's split
-- border is a color contract on glyphs that are identical either way, so a
-- comparison that dropped the attribute would not be a comparison of frames.
frameCells :: AppState -> [[FrameCell]]
frameCells state =
  renderFrameCells (themeFor state.appOptions) (frameWidth, frameHeight) (drawApplication state)

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

-- | How much more a frame of a five-thousand-card column costs than one of a
-- hundred-card column, in bytes the production frame allocates with every cell
-- forced.
--
-- Allocation rather than elapsed time, deliberately: this suite already
-- carries one timing-sensitive example that flakes under load, and what is
-- being told apart here is a factor of fifty against a factor of one.
costGrowth :: (Int -> Int -> IO AppState) -> IO Double
costGrowth build = do
  small <- build 100 0 >>= frameAllocations
  large <- build 5000 0 >>= frameAllocations
  pure (fromIntegral large / fromIntegral (max 1 small))

frameAllocations :: AppState -> IO Word64
frameAllocations state = do
  -- A first frame, discarded: it forces whatever in the board itself was still
  -- a thunk, so what the second one allocates is the frame's own work.
  _ <- evaluate (frameCost state)
  opening <- getRTSStats
  measured <- evaluate (frameCost state)
  closing <- getRTSStats
  _ <- evaluate measured
  pure (closing.allocated_bytes - opening.allocated_bytes)

-- | The whole frame, every cell forced.
frameCost :: AppState -> Int
frameCost state = sum (map length (frameCells state))

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

-- | The runs of items a body builds, split by the blank runs between them.
drawnRuns :: [ColumnPiece] -> [[ColumnItem]]
drawnRuns pieces = filter (not . null) (foldr collect [[]] pieces)
  where
    collect (ColumnBlank _) runs = [] : runs
    collect (ColumnDrawn item) (run : rest) = (item : run) : rest
    collect (ColumnDrawn item) [] = [[item]]
