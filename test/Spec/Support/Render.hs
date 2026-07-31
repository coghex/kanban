-- | Rendering a widget to cells, and the line, card and details projections
-- built on it.
module Spec.Support.Render
  ( FrameCell (..),
    renderFrameCells,
    frameRowText,
    renderDetails,
    renderDetailsAt,
    detailsHeadings,
    detailsRows,
    detailsText,
    renderCard,
    renderWidgetLines,
    cardInterior,
    cardBorderColumns
  )
where

import Brick (AttrMap, Widget, hLimit)
import Brick.Main (renderWidget)
import Data.List (dropWhileEnd)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text
import qualified Data.Text.Lazy as LazyText
import Data.Time (addUTCTime, utc)
import qualified Data.Vector as Vector
import qualified Graphics.Vty.Attributes as Vty
import Graphics.Vty.PictureToSpans (displayOpsForPic)
import Graphics.Vty.Span (SpanOp (..))
import Kanban.CLI (Options (..))
import Kanban.Domain
import Kanban.UI (CardEnv (..), DetailsEnv (..), Name (..), drawCardFrame, drawDetails, themeFor)
import Spec.Support.Fixtures (detailsFixtureUpdatedAt, epoch, testOptions, testResolvedConfig)

-- | Draw the details overlay at the width the real overlay gives its content
-- and read it back as plain text.
renderDetails :: Board -> BoardItem -> [Text]
renderDetails = renderDetailsAt 84

renderDetailsAt :: Int -> Board -> BoardItem -> [Text]
renderDetailsAt width board item = renderWidgetLines (themeFor testOptions) width (hLimit width (drawDetails environment item))
  where
    environment =
      DetailsEnv
        { detailsConfig = testResolvedConfig,
          detailsBoard = board,
          -- Three hours after the fixtures were updated, so the relative age
          -- is computed from this redraw rather than stored with the item.
          detailsNow = addUTCTime (3 * 3600) detailsFixtureUpdatedAt,
          detailsTimeZone = utc
        }

-- | Every heading the overlay can draw, so a section can be read back as the
-- rows between its own heading and the next one.
detailsHeadings :: [Text]
detailsHeadings =
  [ "Metadata",
    "Assignees",
    "Author",
    "Branches",
    "Linked issues",
    "Linked pull requests",
    "Mergeability",
    "Checks",
    "Timestamps",
    "Tracker",
    "Tracker warnings",
    "Body",
    "URL"
  ]

-- | The rows of one overlay section.
detailsRows :: [Text] -> Text -> [Text]
detailsRows rendered heading =
  map Data.Text.strip (takeWhile (`notElem` detailsHeadings) (drop 1 (dropWhile (/= heading) rendered)))

-- | A section's rows rejoined into the single logical line they wrapped from.
detailsText :: [Text] -> Text -> Maybe Text
detailsText rendered heading = case detailsRows rendered heading of
  [] -> Nothing
  rows -> Just (Data.Text.unwords rows)

-- | Draw one card at a fixed width and read the frame back as plain text, the
-- way a terminal would show it.
renderCard :: Options -> Bool -> ColumnEntry -> Int -> [Text]
renderCard options selected entry width =
  renderWidgetLines (themeFor options) width (hLimit width (drawCardFrame environment selected entry))
  where
    environment =
      CardEnv
        { cardOptions = options,
          cardConfig = testResolvedConfig,
          cardNow = epoch,
          cardSolveSessions = Map.empty
        }

-- | One cell of a rendered frame: the character drawn there and the Vty
-- attribute it was drawn with. Text alone cannot answer a color question --
-- the §10 split border is a color contract on glyphs that are identical
-- either way -- so the attribute travels with the character rather than
-- being dropped at the span boundary.
data FrameCell = FrameCell
  { frameCellCharacter :: Char,
    frameCellAttribute :: Vty.Attr
  }
  deriving stock (Eq, Show)

-- | Render @layers@ (topmost first, as 'Kanban.UI.drawApplication' returns
-- them) into exactly the rows and cells a terminal of @region@ would show.
--
-- The rows are always the region's full height and are never trimmed here:
-- a golden frame has to record what the whole viewport held, including the
-- part a caller might otherwise mistake for absent content.
renderFrameCells :: AttrMap -> (Int, Int) -> [Widget Name] -> [[FrameCell]]
renderFrameCells theme region layers =
  map rowCells (Vector.toList (displayOpsForPic picture region))
  where
    picture = renderWidget (Just theme) layers region
    rowCells = concatMap spanCells . Vector.toList
    spanCells (TextSpan attribute _ _ value) =
      [FrameCell character attribute | character <- LazyText.unpack value]
    spanCells (Skip columns) = replicate columns blank
    spanCells (RowEnd columns) = replicate columns blank
    blank = FrameCell ' ' Vty.defAttr

frameRowText :: [FrameCell] -> Text
frameRowText = Data.Text.pack . map frameCellCharacter

renderWidgetLines :: AttrMap -> Int -> Widget Name -> [Text]
renderWidgetLines theme width widget =
  dropWhileEnd Data.Text.null (map (Data.Text.stripEnd . frameRowText) (renderFrameCells theme (width, 80) [widget]))

-- | The interior of a card frame: every row between the top and bottom
-- borders, with the side borders stripped.
cardInterior :: [Text] -> [Text]
cardInterior rendered = map (Data.Text.dropEnd 1 . Data.Text.drop 1) (drop 1 (dropLast rendered))
  where
    dropLast [] = []
    dropLast rows = take (length rows - 1) rows

-- | The frame's left and right border columns, top to bottom. Equal-length
-- runs of edge glyphs are what proves the frame matches the content height.
cardBorderColumns :: [Text] -> ([Text], [Text])
cardBorderColumns rendered = (map (Data.Text.take 1) rendered, map (Data.Text.takeEnd 1) rendered)
