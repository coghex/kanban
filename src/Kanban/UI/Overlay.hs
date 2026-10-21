module Kanban.UI.Overlay
  ( InteriorExtent (..),
    OverlayGeometry (..),
    drawIncidents,
    drawOverlay,
    fullscreenOverlayBox,
    fullscreenSideMargin,
    helpLines,
    interiorViewport,
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
import Kanban.CLI (Options (..))
import Kanban.Card (boundedLines, elide, wrappedLines)
import Kanban.Text (sanitizeText)
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
import Kanban.UI.Incidents
import Kanban.UI.Details
import Kanban.UI.Board

-- | How the one scrolling interior each panel has is sized inside the box it
-- is drawn in, which is the whole of what fullscreen means to a panel.
data InteriorExtent
  = -- | A windowed box: the interior keeps the fixed number of rows that
    -- panel has always bounded its list or transcript to. Those numbers were
    -- chosen against the 32-row windowed box and are still exactly right for
    -- it.
    BoundedInterior
  | -- | A fullscreen box: the interior takes every row the chrome around it
    -- leaves. That is what makes a taller box show more of the incident list,
    -- rather than the same fixed number of rows with a gap underneath — and it keeps the
    -- rows below the interior, a rule and an input line, pinned to the bottom
    -- of the box where they belong.
    GreedyInterior
  deriving stock (Eq, Show)

-- | One panel's scrolling interior at the extent the box is drawn at.
--
-- @windowed@ stays that panel's own decision about how much of a windowed box
-- it spends on the thing being scrolled rather than on the chrome around it;
-- fullscreen replaces the decision rather than adding to it, because the
-- chrome is what is fixed and the interior is what should absorb a change in
-- the box.
interiorViewport :: InteriorExtent -> Int -> Widget Name -> Widget Name
interiorViewport BoundedInterior windowed = vLimit windowed
interiorViewport GreedyInterior _ = id

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
      IncidentsOverlay -> 100
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
      IncidentsOverlay -> drawIncidents interior state
      DetailsOverlay item -> viewport DetailsViewport Vertical (drawDetails (detailsEnv state) item)
  where
    interior = geometry.overlayGeometryInterior
    -- Windowed, the box is centered and 'vLimit' only caps it, so a panel
    -- whose rows are all fixed draws a border tight around them -- which is
    -- how every incident box has always looked. Fullscreen the height is measured against the footer instead,
    -- so a box that stopped at its content would leave a strip of board
    -- between its bottom border and the hint row rather than running down to
    -- it.
    --
    -- 'GreedyInterior' already fills the box for every panel that has a
    -- scrolling interior at all. The fill covers the one that does not: the
    -- help overlay, whose rows are the whole panel.
    (place, fillBox) = case interior of
      BoundedInterior -> (centerLayer, id)
      GreedyInterior -> (hCenterLayer, padBottom Max)
    panelExtent = case overlay of
      HelpOverlay -> id
      IncidentsOverlay -> clickable IncidentsPanel
      DetailsOverlay _ -> clickable DetailsPanel
    overlayTitle = case overlay of
      HelpOverlay -> " HELP "
      IncidentsOverlay -> " NEEDS ATTENTION "
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

drawIncidents :: InteriorExtent -> AppState -> Widget Name
drawIncidents interior state =
  vBox
    [ withAttr (drainerSourceAttr source) (txtWrap (drainerSourceSummary source)),
      txt "",
      interiorViewport interior incidentsViewportHeight
        . viewport IncidentsViewport Vertical
        $ if null entries
          then withAttr dimAttr (txtWrap (emptyStateText source))
          else vBox (zipWith drawEntry [0 :: Int ..] entries)
    ]
  where
    entries = incidentEntries state
    source = drainerSourceState state.appDrainerStatus state.appDrainerIncidents
    selectedIndex = (resolveIncidentSelection entries state.appIncidentSelection).incidentSelectionRow
    glyph = if state.appOptions.optionAscii then "!" else "×"
    drawEntry index entry =
      let selected = index == selectedIndex
          attribute = if selected then selectedAttr else problemAttr
          line =
            glyph
              <> " "
              <> entry.incidentEntrySubject
              <> " · "
              <> entry.incidentEntryDetail
              <> " · "
              <> incidentSourceLabel entry.incidentEntrySource
          note = maybe [] (noteLines state) entry.incidentEntryNote
          widget =
            clickable
              (IncidentTarget entry.incidentEntryRef)
              (vBox (withAttr attribute (elidedLine line) : note))
       in if selected then visible widget else widget

-- | An entry's note as the continuation lines drawn under its row.
--
-- Wrapped rather than elided: the note exists because the text is worth
-- reading whole, and a row that has already spent the panel's width on its
-- subject and summary would elide it away before its first word. The
-- continuation is indented and marked so it reads as belonging to the row
-- above rather than as an entry of its own, and it is part of the same
-- clickable widget, so clicking it selects the incident it belongs to.
--
-- Bounded in height as well as width. A note is one incident's detail while
-- the panel's rows are shared, so it may take at most 'incidentNoteLines'.
-- What is dropped to fit is the /middle/: a drainer's recorded failure opens
-- by restating what failed and closes with the blocker, the remedy and the
-- paths to act on, so trimming the tail would keep only the part the row
-- already said. The first line and the last are kept, and the gap between
-- them is marked.
noteLines :: AppState -> Text -> [Widget Name]
noteLines state note = [withAttr dimAttr (Widget Fixed Fixed draw)]
  where
    marker = if state.appOptions.optionAscii then "-> " else "↳ "
    indent = "    "
    -- The marker sits on the first line only; later lines align under its
    -- text rather than repeating it.
    continuation = Text.replicate (Text.length marker) " "
    draw = do
      context <- getContext
      let body = max 1 (availWidth context - Text.length indent - Text.length marker)
          rows = keepEnds body (wrappedLines body note)
      render (vBox [txt (indent <> prefix <> row) | (prefix, row) <- zip (marker : repeat continuation) rows])
    keepEnds body rows
      | length rows <= incidentNoteLines = rows
      | otherwise = case rows of
          first : _ -> elide body first : drop (length rows - (incidentNoteLines - 1)) rows
          [] -> []

-- | How many continuation lines one note may take. A note belongs to a
-- single incident while the panel's height is shared, so three lines is the
-- whole allowance.
incidentNoteLines :: Int
incidentNoteLines = 3

-- | One row's text, elided to the width the panel actually gives it.
--
-- The panel is a fixed-width overlay, so a row longer than it is cropped by
-- the viewport. Cropping alone is silent: it takes the tail of the line away
-- with nothing to say it did, which reads as a row that simply ends there.
-- Measuring at render time instead keeps the §11 promise that an ellipsis
-- appears wherever text was dropped, and it is the width the panel really
-- has rather than a constant restated here.
--
-- Still exactly one row: 'boundedLines' at one line either returns the whole
-- line or its elided head, and an empty line yields no row rather than a
-- blank one.
elidedLine :: Text -> Widget Name
elidedLine line = Widget Fixed Fixed $ do
  context <- getContext
  render (txt (Text.concat (boundedLines (availWidth context) 1 line)))

-- | The overall "nothing needs attention" claim is only ever made from a
-- drainer observation that reported no incidents. With the source still
-- being checked or unavailable the panel has nothing else to speak for, so it
-- says only what is true of the drainer.
emptyStateText :: DrainerSourceState -> Text
emptyStateText source = case source of
  DrainerSourceReported _ -> "Nothing needs attention."
  DrainerSourceChecking -> "The PR drainer has not answered yet."
  DrainerSourceUnavailable _ -> "The PR drainer's open incidents are unavailable."

-- | Says which of the source's states produced the list above, so an empty
-- panel is never read as a verdict the drainer did not give. The detail is
-- the status's own, which is a remediation when the controller could not be
-- reached and simply names its state when the controller answered without
-- reporting a set at all — hence "open incidents unavailable" rather than a
-- bare "unavailable", which would contradict a drainer plainly reported on.
drainerSourceSummary :: DrainerSourceState -> Text
drainerSourceSummary source = case source of
  DrainerSourceReported incidents ->
    "PR drainer: "
      <> showText (length incidents)
      <> " open incident"
      <> (if length incidents == 1 then "" else "s")
  DrainerSourceChecking -> "PR drainer: checking for open incidents…"
  DrainerSourceUnavailable detail -> "PR drainer: open incidents unavailable · " <> sanitizeText detail

-- | The rows the incidents panel's bounded interior viewport is given inside a
-- /windowed/ box: its share of the 32 rows the box has, after the summary line
-- above it. 'interiorViewport' is what retires it in a box that is not that
-- shape.
incidentsViewportHeight :: Int
incidentsViewportHeight = 23
