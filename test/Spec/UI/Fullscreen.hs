-- | The @f@ fullscreen toggle (issue #543): its lifecycle, its geometry, and
-- what a fullscreen box does to the panels inside it.
--
-- Nothing here needs a terminal or an @EventM@. The lifecycle rule is
-- 'settleOverlayFullscreen', which is the total decision @handleEvent@ applies
-- after every event, and each transition below hands it the very overlay pair
-- the real arm writes -- 'applyIncidentsAction' for the incidents jump,
-- and 'refreshOverlay' for reconciliation --
-- rather than a hand-written pair that could agree with the rule by accident.
-- The geometry is measured off real frames drawn through
-- 'Kanban.UI.drawApplication', because the height a fullscreen box stops at is
-- the footer's actual rendered height and nothing else can answer that.
module Spec.UI.Fullscreen (spec) where

import Data.Foldable (for_)
import Data.Text (Text)
import qualified Data.Text
import Kanban.Domain
import Kanban.Models (OperatingMode (..))
import Kanban.UI (drawApplication)
import Kanban.UI.Events
  ( IncidentsAction (..),
    OverlayExtent (..),
    OverlayMouseAction (..),
    applyIncidentsAction,
    incidentsAction,
    overlayMouseAction,
  )
import Kanban.UI.Keys (BindingScope (..), BoardAction (..), boardAction)
import Kanban.UI.Overlay
  ( InteriorExtent (..),
    OverlayGeometry (..),
    fullscreenSideMargin,
    overlayGeometryFor,
    windowedOverlayBox,
  )
import Kanban.UI.Selection (refreshOverlay)
import Brick (BrickEvent (..), Location (..))
import Kanban.UI.State (settleOverlayFullscreen, toggleOverlayFullscreen)
import Kanban.UI.Theme (themeFor)
import Kanban.UI.Types
import Kanban.UI.Util (noticeCleared, noticeSet)
import Kanban.Drainer (DrainerIncident (..))
import qualified Graphics.Vty as Vty
import Spec.Support.App (testAppState)
import Spec.Support.Fixtures
  ( baseIssue,
    fixtureBoard,
    fixtureStandaloneEntry,
    showText,
  )
import Spec.Support.Render (frameRowText, renderFrameCells)
import Test.Hspec

spec :: Spec
spec = do
  describe "the fullscreen flag's lifecycle" $ do
    -- Requirement 1 and D-5: the flag belongs to the overlay that is open,
    -- and every overlay opens windowed.
    it "opens every overlay windowed, whatever the board was left holding" $ do
      state <- boardState
      state.appOverlayFullscreen `shouldBe` False
      for_ everyOverlay $ \overlay ->
        (name overlay, (settleOverlayFullscreen Nothing (opened overlay state) {appOverlayFullscreen = True}).appOverlayFullscreen)
          `shouldBe` (name overlay, False)

    it "toggles every open overlay" $ do
      state <- boardState
      for_ everyOverlay $ \overlay -> do
        let toggled = toggleOverlayFullscreen (opened overlay state)
        (name overlay, toggled.appOverlayFullscreen) `shouldBe` (name overlay, True)
        -- A second press puts the overlay back.
        (name overlay, (toggleOverlayFullscreen toggled).appOverlayFullscreen) `shouldBe` (name overlay, False)

    it "does nothing at all with no overlay open" $ do
      state <- boardState
      (toggleOverlayFullscreen state).appOverlayFullscreen `shouldBe` False

    -- Activating a row leaves the panel without going through 'closeOverlay',
    -- so the reset has to come from the settle that compares the overlay
    -- before and after rather than from the close.
    it "resets when activating a row closes the incidents panel" $ do
      panel <- incidentsPanelOverDrainerIncident
      let fullscreenPanel = toggleOverlayFullscreen panel
          activated = applyIncidentsAction ActivateSelectedIncident fullscreenPanel
      fullscreenPanel.appOverlayFullscreen `shouldBe` True
      activated.appOverlay `shouldBe` Nothing
      (settleOverlayFullscreen fullscreenPanel.appOverlay activated).appOverlayFullscreen `shouldBe` False

    it "resets when the overlay closes" $ do
      panel <- incidentsPanelOverDrainerIncident
      let fullscreenPanel = toggleOverlayFullscreen panel
          closed = applyIncidentsAction CloseIncidentsPanel fullscreenPanel
      closed.appOverlay `shouldBe` Nothing
      (settleOverlayFullscreen fullscreenPanel.appOverlay closed).appOverlayFullscreen `shouldBe` False

    -- And reconciliation, which re-points a details overlay at the same
    -- card's newer record on every completed generation.
    it "survives a refresh that re-points the same overlay" $ do
      state <- boardState
      let showing = (opened (DetailsOverlay detailsItem) state) {appOverlayFullscreen = True}
          (refreshed, _) = refreshOverlay state.appVisibleBoard showing.appOverlay
          reconciled = showing {appOverlay = refreshed}
      refreshed `shouldSatisfy` maybe False ((== DetailsSurface) . overlaySurface)
      (settleOverlayFullscreen showing.appOverlay reconciled).appOverlayFullscreen `shouldBe` True

    -- ...and closes when the same refresh finds the card gone, which is the
    -- one reconciliation outcome that is a close rather than a re-point.
    it "resets when a refresh closes the overlay under the user" $ do
      state <- boardState
      let showing = (opened (DetailsOverlay detailsItem) state) {appOverlayFullscreen = True}
          (refreshed, _) = refreshOverlay (fixtureBoard []) showing.appOverlay
          reconciled = showing {appOverlay = refreshed}
      refreshed `shouldBe` Nothing
      (settleOverlayFullscreen showing.appOverlay reconciled).appOverlayFullscreen `shouldBe` False

    -- The rule reads the surface rather than the overlay value, and a
    -- replacement by a *different* surface resets whichever pair it is given.
    it "resets on every replacement by a different surface" $ do
      state <- boardState
      for_ [(from, to) | from <- everyOverlay, to <- everyOverlay] $ \(from, to) -> do
        let moved = (opened to state) {appOverlayFullscreen = True}
            settled = settleOverlayFullscreen (Just from) moved
        (name from <> " → " <> name to, settled.appOverlayFullscreen)
          `shouldBe` (name from <> " → " <> name to, overlaySurface from == overlaySurface to)

  describe "fullscreen geometry" $ do
    -- Requirement 4. Asserted over every overlay and a range of terminals
    -- that includes several smaller than the windowed boxes, because that is
    -- where a naive `terminal - reserved` would hand a panel a box smaller
    -- than the one it has when the key is never pressed.
    it "never hands an overlay a smaller box than its windowed one" $
      for_ [(overlay, width, height, reserved) | overlay <- everyOverlay, width <- terminalWidths, height <- terminalHeights, reserved <- reservedRows] $
        \(overlay, width, height, reserved) -> do
          let windowed = overlayGeometryFor DualMode overlay False width height reserved
              full = overlayGeometryFor DualMode overlay True width height reserved
              label = (name overlay, width, height, reserved)
          (label, full.overlayGeometryWidth >= windowed.overlayGeometryWidth) `shouldBe` (label, True)
          (label, full.overlayGeometryHeight >= windowed.overlayGeometryHeight) `shouldBe` (label, True)

    it "keeps the windowed box exactly what it has always been" $
      for_ everyOverlay $ \overlay -> do
        let windowed = overlayGeometryFor DualMode overlay False 200 48 4
        (name overlay, (windowed.overlayGeometryWidth, windowed.overlayGeometryHeight))
          `shouldBe` (name overlay, windowedOverlayBox DualMode overlay)
        (name overlay, windowed.overlayGeometryInterior) `shouldBe` (name overlay, BoundedInterior)

    it "spans the terminal less one column of frame on each side when it fits" $ do
      let full = overlayGeometryFor DualMode HelpOverlay True 200 48 4
      full.overlayGeometryWidth `shouldBe` 200 - 2 * fullscreenSideMargin
      full.overlayGeometryHeight `shouldBe` 48 - 4
      full.overlayGeometryInterior `shouldBe` GreedyInterior

  -- Requirement 3, and the correction that made the reservation the notice's
  -- *rendered* height rather than one row: the footer wraps its notice with
  -- 'txtWrap', so how far up the box must stop is a fact about this terminal
  -- and this notice together. Measured off the real frame the dashboard
  -- draws, which is the only thing that cannot disagree with itself.
  describe "the rows a fullscreen box leaves the base frame" $ do
    let terminalHeight = 40
        terminalWidth = 120
        wrappingNotice = Data.Text.unwords (replicate 60 "wrap")

    it "stops above the footer, whatever height the notice gives it" $ do
      state <- boardState
      let frames notice =
            fullscreenFrame terminalWidth terminalHeight (maybe noticeCleared noticeSet notice (opened (DetailsOverlay detailsItem) state))
          noticeRowsIn frame = length (filter (Data.Text.isInfixOf "wrap") frame)
          bare = frames Nothing
          oneLine = frames (Just "one line")
          wrapped = frames (Just wrappingNotice)

      -- The hint row is what D-10 promises stays readable, and it is intact
      -- in all three.
      for_ ([("bare", bare), ("one line", oneLine), ("wrapped", wrapped)] :: [(String, [Text])]) $ \(label, frame) ->
        (label, any (Data.Text.isInfixOf "f fullscreen") frame) `shouldBe` (label, True)

      -- Two rows of footer (the hint and the freshness line) and the frame's
      -- own bottom border, with no notice at all.
      boxRows bare `shouldBe` terminalHeight - 3
      -- One more row for a notice that fits on one.
      boxRows oneLine `shouldBe` terminalHeight - 4
      -- The wrapped notice really did wrap, so the assertion below is about
      -- something, and the box gave back exactly the rows it took.
      noticeRowsIn wrapped `shouldSatisfy` (> 1)
      boxRows wrapped `shouldBe` terminalHeight - (3 + noticeRowsIn wrapped)

    it "leaves the frame's own columns showing on both sides" $ do
      state <- boardState
      let frame = fullscreenFrame terminalWidth terminalHeight (opened (DetailsOverlay detailsItem) state)
          boxRow = filter ((> 1) . Data.Text.length) (take (boxRows frame) frame)
      boxRow `shouldSatisfy` all ((`elem` outerFrameGlyphs) . (`Data.Text.index` 0))
      boxRow `shouldSatisfy` all ((`elem` outerFrameGlyphs) . Data.Text.last)

  -- Requirement 5: the growth has to reach the thing each panel scrolls, or a
  -- fullscreen frame is a bigger border around the same nineteen rows.
  describe "what a fullscreen box gives its interior" $ do
    it "shows more of the incident list" $ do
      state <- longListState
      let showing = opened IncidentsOverlay state
          visible frame = length (filter (Data.Text.isInfixOf "PR #") frame)
          windowed = visible (windowedFrame 200 48 showing)
          full = visible (fullscreenFrame 200 48 showing)
      full `shouldSatisfy` (> windowed)

  -- What section 7 says a fullscreen overlay's ways out are, held against what
  -- each overlay's decoder actually answers. Withdrawing the outside click is
  -- the whole of what fullscreen changes here, so an exit named in the
  -- documentation and absent from the code -- or the reverse -- is a
  -- contradiction this group exists to catch.
  describe "the ways out of an overlay, which fullscreen leaves alone" $ do
    it "closes each overlay on Esc, through that overlay's own decoder" $ do
      boardAction DetailsScope escape `shouldBe` Just DismissOrClose
      boardAction HelpScope escape `shouldBe` Just DismissOrClose
      incidentsAction (Just IncidentsOverlay) (VtyEvent escape) `shouldBe` Just CloseIncidentsPanel

    -- `q` is not a general overlay close and never was: in an overlay it is
    -- either the dashboard's own quit or nothing at all. Pinned here because
    -- the fullscreen documentation has to name the exits that exist rather
    -- than a uniform set.
    it "answers q only where section 7 already gave it a meaning" $ do
      boardAction DetailsScope (key 'q') `shouldBe` Just QuitDashboard
      boardAction HelpScope (key 'q') `shouldBe` Just QuitDashboard
      incidentsAction (Just IncidentsOverlay) (VtyEvent (key 'q')) `shouldBe` Just IgnoreIncidentsEvent

    -- The same for the right click, which the help overlay's mouse rows and
    -- section 7's mouse policy both describe: it closes the overlays that
    -- route through the shared policy, at either extent, and the incidents
    -- panel answers it with nothing in either.
    it "closes on a right click only through the shared mouse policy" $
      for_ bothExtents $ \(extentLabel, extent) -> do
        (extentLabel, overlayMouseAction extent DetailsPanel (MouseDown DetailsPanel Vty.BRight [] origin))
          `shouldBe` (extentLabel, Just OverlayMouseClose)
        (extentLabel, incidentsAction (Just IncidentsOverlay) (MouseDown IncidentsPanel Vty.BRight [] origin))
          `shouldBe` (extentLabel, Just IgnoreIncidentsEvent)

  -- @f@ is answered by one arm shared by every overlay, so the thing worth
  -- pinning is that the table reaches it from the scope that arm resolves in,
  -- and that no overlay needs a decoder of its own to be resized.
  describe "which decoder answers f" $
    it "resolves f to the fullscreen toggle in the scope every overlay shares" $
      boardAction OverlayScope (key 'f') `shouldBe` Just ToggleFullscreen

-- | Both extents, labelled, for the assertions that must hold in each.
bothExtents :: [(String, OverlayExtent)]
bothExtents = [("windowed", WindowedOverlay), ("fullscreen", FullscreenOverlay)]

escape :: Vty.Event
escape = Vty.EvKey Vty.KEsc []

key :: Char -> Vty.Event
key character = Vty.EvKey (Vty.KChar character) []

origin :: Location
origin = Location (0, 0)

-- | The three overlays, one of each surface, so a decision total in
-- 'OverlaySurface' is exercised at every arm.
everyOverlay :: [Overlay]
everyOverlay =
  [ HelpOverlay,
    IncidentsOverlay,
    DetailsOverlay (IssueItem (baseIssue 10 []))
  ]

name :: Overlay -> String
name = show . overlaySurface

opened :: Overlay -> AppState -> AppState
opened overlay state = state {appOverlay = Just overlay}

-- | Terminals both larger and smaller than every windowed box, so the
-- never-shrink rule is asked where it can actually fail.
terminalWidths :: [Int]
terminalWidths = [20, 36, 44, 70, 101, 164, 200]

terminalHeights :: [Int]
terminalHeights = [6, 12, 31, 33, 36, 48, 64]

reservedRows :: [Int]
reservedRows = [0, 3, 4, 7]

-- | The board fixture every case here starts from.
boardState :: IO AppState
boardState = testAppState (fixtureBoard [(Issues, [fixtureStandaloneEntry fixtureIssueNumber])])

-- | The card 'boardState' puts on the board, which is what a details overlay
-- there is open for and what a refresh looks back up by id.
detailsItem :: BoardItem
detailsItem = IssueItem (baseIssue fixtureIssueNumber [])

fixtureIssueNumber :: Int
fixtureIssueNumber = 10

-- | The incidents panel open over a board whose drainer has reported one
-- incident, so Enter on its first row activates that row -- the transition
-- that leaves the panel without passing through 'closeOverlay'.
incidentsPanelOverDrainerIncident :: IO AppState
incidentsPanelOverDrainerIncident = do
  state <- boardState
  pure (applyIncidentsAction OpenIncidentsPanel state {appDrainerIncidents = Just [conflictIncident 10]})

-- | The outer frame's own border glyphs, which is what a fullscreen box has
-- to leave showing on each side. Both spellings, because the theme draws a
-- double border and the corner rows draw the box's own.
outerFrameGlyphs :: String
outerFrameGlyphs = "║╔╗╚╝═"

-- | One frame of the whole dashboard, exactly as 'drawApplication' layers it.
frameAt :: Int -> Int -> AppState -> [Text]
frameAt width height state =
  map frameRowText (renderFrameCells (themeFor state.appOptions) (width, height) (drawApplication state))

windowedFrame :: Int -> Int -> AppState -> [Text]
windowedFrame width height state = frameAt width height state {appOverlayFullscreen = False}

fullscreenFrame :: Int -> Int -> AppState -> [Text]
fullscreenFrame width height state = frameAt width height state {appOverlayFullscreen = True}

-- | How many rows a fullscreen box occupies, read off the frame: it is
-- anchored to the top, so its rows are the leading ones whose second column
-- is one of the box's own border glyphs rather than the space the footer and
-- the frame's bottom edge leave there.
boxRows :: [Text] -> Int
boxRows = length . takeWhile boxRow
  where
    boxRow row = Data.Text.length row > 1 && Data.Text.index row 1 `elem` ("┏┃┗" :: String)

-- | A board carrying more drainer incidents than the panel can show at once,
-- so the list is clipped windowed and less clipped fullscreen.
longListState :: IO AppState
longListState = do
  state <- boardState
  pure state {appDrainerIncidents = Just [conflictIncident number | number <- [200 .. 240]]}

conflictIncident :: Int -> DrainerIncident
conflictIncident number =
  DrainerIncident
    { incidentId = "incident-conflict-" <> showText number,
      incidentKind = "merge-conflict",
      incidentSummary = Just ("PR #" <> showText number <> " has a merge conflict in README."),
      incidentPullRequest = Just number,
      incidentLastPullRequest = Nothing,
      incidentActivity = Nothing,
      incidentError = Nothing
    }
