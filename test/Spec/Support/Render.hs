-- | Rendering a widget to lines, and the card and details projections built on it.
module Spec.Support.Render
  ( renderDetails,
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

renderWidgetLines :: AttrMap -> Int -> Widget Name -> [Text]
renderWidgetLines theme width widget =
  dropWhileEnd Data.Text.null (map rowText (Vector.toList (displayOpsForPic picture region)))
  where
    region = (width, 80)
    picture = renderWidget (Just theme) [widget] region
    rowText = Data.Text.stripEnd . foldMap spanText . Vector.toList
    spanText (TextSpan _ _ _ value) = LazyText.toStrict value
    spanText (Skip columns) = Data.Text.replicate columns " "
    spanText (RowEnd columns) = Data.Text.replicate columns " "

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
