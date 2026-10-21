module Kanban.UI.Overlay
  ( InteriorExtent (..),
    OverlayGeometry (..),
    drawOverlay,
    fullscreenOverlayBox,
    fullscreenSideMargin,
    helpLines,
    mouseHelpEntries,
    overlayGeometryFor,
    windowedOverlayBox,
  )
where


import Brick
import Brick.Widgets.Border (borderWithLabel)
import Brick.Widgets.Center (centerLayer, hCenterLayer)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.UI.Keys
  ( HelpEntry (..),
    bindingHelpEntry,
    gestureHelpEntry,
    helpRows,
    boardBindings,
  )
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.Theme
import Kanban.UI.Details
import Kanban.UI.Board

-- | How the one scrolling interior each panel has is sized inside the box it
-- is drawn in, which is the whole of what fullscreen means to a panel.
data InteriorExtent
  = -- | A windowed box: the interior keeps the fixed number of rows that
    -- panel has always bounded its content to. Those numbers were chosen
    -- against the 32-row windowed box and are still exactly right for it.
    BoundedInterior
  | -- | A fullscreen box: the interior takes every row the chrome around it
    -- leaves. That is what makes a taller box show more of its content, rather
    -- than the same fixed number of rows with a gap underneath.
    GreedyInterior
  deriving stock (Eq, Show)

-- | The box an overlay is drawn at, and how its interior fills it.
data OverlayGeometry = OverlayGeometry
  { overlayGeometryWidth :: Int,
    overlayGeometryHeight :: Int,
    overlayGeometryInterior :: InteriorExtent
  }
  deriving stock (Eq, Show)

-- | The columns of application frame a fullscreen box leaves showing on each
-- side, so the box covers the board and the usage sidebar without becoming
-- the whole terminal (@docs\/overlay_focus_fullscreen_design.md@ D-10).
fullscreenSideMargin :: Int
fullscreenSideMargin = 1

-- | The box an overlay draws in when it is windowed, which is the size it has
-- always had.
windowedOverlayBox :: Overlay -> (Int, Int)
windowedOverlayBox overlay = (overlayWidth, overlayHeight)
  where
    -- The rows the help overlay is about to draw, which is what both of its
    -- dimensions are measured from. Taken once here rather than twice below.
    rows = helpLines
    overlayWidth = case overlay of
      -- Wide enough for the list it draws, for the same reason its height is:
      -- a description added to the table has to widen the box rather than be
      -- silently cut off inside it. A terminal narrower than this still clips
      -- the overlay, which is the overlay system's existing policy.
      HelpOverlay -> maximum (1 : map Text.length rows) + 4
      _ -> 88
    overlayHeight = case overlay of
      -- Tall enough for the list it draws, so a binding added to the table
      -- cannot silently push a row past the border: the two rows 'padAll'
      -- adds and the two the border takes are the whole difference.
      HelpOverlay -> length rows + 4
      _ -> 32

-- | The box a fullscreen overlay draws in.
--
-- The terminal width less one column of frame on each side, and the height
-- from the top of the frame down to whatever the base keeps below it —
-- @reservedRows@, the footer and the frame's bottom edge — so the hint row
-- naming the keys of the surface that has the keyboard stays fully visible
-- under the box.
--
-- Never smaller than the windowed box. On a terminal narrower or shorter than
-- one of the panels, the fullscreen dimension falls back to the windowed one
-- and the overlay is clipped exactly as it already is there: making the box
-- /smaller/ than the size it has when the key was never pressed would be a
-- new failure mode rather than a bigger view.
fullscreenOverlayBox :: Int -> Int -> Int -> (Int, Int) -> (Int, Int)
fullscreenOverlayBox terminalWidth terminalHeight reservedRows (windowedWidth, windowedHeight) =
  ( max windowedWidth (terminalWidth - 2 * fullscreenSideMargin),
    max windowedHeight (terminalHeight - reservedRows)
  )

-- | The geometry one overlay is drawn at: its windowed box, or the fullscreen
-- one when the flag is set.
overlayGeometryFor :: Overlay -> Bool -> Int -> Int -> Int -> OverlayGeometry
overlayGeometryFor overlay fullscreen terminalWidth terminalHeight reservedRows
  | fullscreen =
      uncurry OverlayGeometry (fullscreenOverlayBox terminalWidth terminalHeight reservedRows windowed) GreedyInterior
  | otherwise = uncurry OverlayGeometry windowed BoundedInterior
  where
    windowed = windowedOverlayBox overlay

-- | The one geometry seam every layered overlay draws through.
--
-- Windowed, the box is centered over the board exactly as it always was.
-- Fullscreen, it is centered horizontally and anchored to the top of the
-- frame instead, because its height is measured down to the footer rather
-- than shared evenly above and below it: centering a box of that height would
-- put half the reserved rows above it and cover the footer with the other
-- half. Both placements are layer combinators, so what they do not cover
-- stays the board underneath.
drawOverlay :: AppState -> Overlay -> Widget Name
drawOverlay state overlay = Widget Greedy Greedy $ do
  context <- getContext
  let terminalWidth = availWidth context
      terminalHeight = availHeight context
      fullscreen = state.appOverlayFullscreen
  -- Only a fullscreen box has a height to measure against the footer, and the
  -- measurement renders the footer a second time, so a windowed frame does
  -- not pay for it.
  reservedRows <- if fullscreen then baseFooterRows state terminalWidth else pure 0
  let geometry = overlayGeometryFor overlay fullscreen terminalWidth terminalHeight reservedRows
  render (drawOverlayBox state overlay geometry)

-- | The box itself. Everything fullscreen changes about it is read back off
-- the geometry rather than passed alongside it, so the box cannot be placed
-- one way and sized the other.
drawOverlayBox :: AppState -> Overlay -> OverlayGeometry -> Widget Name
drawOverlayBox state overlay geometry =
  place
    . panelExtent
    . hLimit geometry.overlayGeometryWidth
    . vLimit geometry.overlayGeometryHeight
    . withBorderStyle (innerBorderStyle state)
    . borderWithLabel (withAttr headingAttr (txt overlayTitle))
    . padAll 1
    . fillBox
    $ case overlay of
      HelpOverlay -> drawHelp
      DetailsOverlay item -> viewport DetailsViewport Vertical (drawDetails (detailsEnv state) item)
  where
    interior = geometry.overlayGeometryInterior
    -- Windowed, the box is centered and 'vLimit' only caps it, so a panel
    -- whose rows are all fixed draws a border tight around them. Fullscreen
    -- the height is measured against the footer instead, so a box that
    -- stopped at its content would leave a strip of board between its bottom
    -- border and the hint row rather than running down to it.
    (place, fillBox) = case interior of
      BoundedInterior -> (centerLayer, id)
      GreedyInterior -> (hCenterLayer, padBottom Max)
    panelExtent = case overlay of
      HelpOverlay -> id
      DetailsOverlay _ -> clickable DetailsPanel
    overlayTitle = case overlay of
      HelpOverlay -> " HELP "
      DetailsOverlay item -> " " <> itemHeading item <> " "

drawHelp :: Widget Name
drawHelp = vBox (map txt helpLines)

-- | The complete binding list, in two blocks: every base-board binding in
-- §7's order, then the mouse.
--
-- Nothing here is a key hint this module wrote down. The board rows come from
-- the table in "Kanban.UI.Keys", so the overlay cannot claim a binding that
-- dispatch does not have — which is exactly how it came to omit @?@, its own
-- binding, before this list was derived.
--
helpLines :: [Text]
helpLines =
  helpRows (map bindingHelpEntry boardBindings <> mouseHelpEntries)

-- | The gestures no key covers, so no binding defines them. Mouse policy
-- lives in @Kanban.UI.Events@ rather than in a table, and this is prose about
-- it, not a key hint.
--
-- The two halves of the last row stopped meaning the same thing in issue
-- #543: a right click closes the panel at either extent, while the outside
-- click is exactly what a fullscreen box withdraws, so the row has to say
-- which one is which rather than name them together.
mouseHelpEntries :: [HelpEntry]
mouseHelpEntries =
  [ gestureHelpEntry "left click" "select card; click selected card for details",
    gestureHelpEntry "mouse wheel" "scroll column under pointer",
    gestureHelpEntry "right click" "close card details, windowed or fullscreen",
    gestureHelpEntry "outside click" "close card details, while it is windowed"
  ]
