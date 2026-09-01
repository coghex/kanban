-- | The @f@ fullscreen toggle (issue #543): its lifecycle, its geometry, and
-- what a fullscreen box does to the panels inside it.
--
-- Nothing here needs a terminal or an @EventM@. The lifecycle rule is
-- 'settleOverlayFullscreen', which is the total decision @handleEvent@ applies
-- after every event, and each transition below hands it the very overlay pair
-- the real arm writes -- 'applyIncidentsAction' for the incidents jump,
-- 'refreshOverlay' for reconciliation, and @sessionOpsOverlay@ for @Tab@ --
-- rather than a hand-written pair that could agree with the rule by accident.
-- The geometry is measured off real frames drawn through
-- 'Kanban.UI.drawApplication', because the height a fullscreen box stops at is
-- the footer's actual rendered height and nothing else can answer that.
module Spec.UI.Fullscreen (spec) where

import Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text
import Kanban.Domain
import Kanban.Models (OperatingMode (..), defaultRoster, roleKey)
import Kanban.Solve (SolveWorkflow (..))
import Kanban.UI (drawApplication)
import Kanban.UI.Events
  ( IncidentsAction (..),
    OverlayExtent (..),
    OverlayMouseAction (..),
    applyIncidentsAction,
    incidentsAction,
    overlayMouseAction,
    sharedFullscreenKey,
  )
import Kanban.UI.Keys (BindingScope (..), BoardAction (..), boardAction)
import Kanban.UI.Overlay
  ( InteriorExtent (..),
    OverlayGeometry (..),
    fullscreenSideMargin,
    overlayGeometryFor,
    settingsRosterHeight,
    windowedOverlayBox,
  )
import Kanban.UI.Settings (RosterRow (..), SettingsInput (..), settingsInput, settingsRosterRows)
import Kanban.UI.Selection (refreshOverlay)
import Brick (BrickEvent (..), Location (..))
import Kanban.UI.SessionCore
  ( SessionFocus (..),
    SessionInputEvent (..),
    noSessionInputCaps,
    sessionInputEvent,
    sessionModeAfter,
  )
import Kanban.UI.SessionEvents (SessionOps (..), solveSessionOps)
import Kanban.UI.State (settleOverlayFullscreen, toggleOverlayFullscreen)
import Kanban.UI.Theme (themeFor)
import Kanban.UI.Types
import Kanban.UI.Util (noticeCleared, noticeSet)
import Kanban.Drainer (DrainerIncident (..))
import qualified Graphics.Vty as Vty
import Spec.Support.App (testAppState, withPullRequestSession, withReviewSession, withSolveSession)
import Spec.Support.Fixtures
  ( baseIssue,
    basePullRequest,
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

    it "toggles the open overlay, and refuses the one overlay that keeps its box" $ do
      state <- boardState
      for_ everyOverlay $ \overlay -> do
        let toggled = toggleOverlayFullscreen (opened overlay state)
        (name overlay, toggled.appOverlayFullscreen)
          `shouldBe` (name overlay, overlayHonorsFullscreen overlay)
        -- A second press puts an honoring overlay back, and still does
        -- nothing at all to the chooser.
        (name overlay, (toggleOverlayFullscreen toggled).appOverlayFullscreen) `shouldBe` (name overlay, False)

    it "does nothing at all with no overlay open" $ do
      state <- boardState
      (toggleOverlayFullscreen state).appOverlayFullscreen `shouldBe` False

    -- Requirement 1's hard case, and the acceptance's named spec: the
    -- incidents panel's Enter opens a live session *without* closing the
    -- panel first, so the second overlay must come back windowed even though
    -- nothing went through 'closeOverlay'.
    it "resets when the incidents panel jumps straight into a live session" $ do
      panel <- incidentsPanelOverSolveSession
      let fullscreenPanel = toggleOverlayFullscreen panel
          activated = applyIncidentsAction ActivateSelectedIncident fullscreenPanel
      fullscreenPanel.appOverlayFullscreen `shouldBe` True
      -- The jump really did replace the panel with another surface, which is
      -- what makes the assertion below about anything.
      fmap overlaySurface activated.appOverlay `shouldBe` Just SolveSurface
      (settleOverlayFullscreen fullscreenPanel.appOverlay activated).appOverlayFullscreen `shouldBe` False

    it "resets when the overlay closes" $ do
      panel <- incidentsPanelOverSolveSession
      let fullscreenPanel = toggleOverlayFullscreen panel
          closed = applyIncidentsAction CloseIncidentsPanel fullscreenPanel
      closed.appOverlay `shouldBe` Nothing
      (settleOverlayFullscreen fullscreenPanel.appOverlay closed).appOverlayFullscreen `shouldBe` False

    -- The other half of D-5, which the authoritative review made explicit:
    -- Tab moves a session overlay from one session of the same kind to the
    -- next, and that is the same surface rather than a new one.
    it "survives Tab cycling to the next session of the same kind" $ do
      state <- boardState
      let cycling =
            (withSolveSession (baseIssue 41 []) SolveRunning (withSolveSession (baseIssue 40 []) SolveRunning state))
              { appOverlay = Just (solveSessionOps.sessionOpsOverlay 40),
                appOverlayFullscreen = True
              }
          cycled = cycling {appOverlay = Just (solveSessionOps.sessionOpsOverlay 41)}
      cycled.appOverlay `shouldNotBe` cycling.appOverlay
      (settleOverlayFullscreen cycling.appOverlay cycled).appOverlayFullscreen `shouldBe` True

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

    -- Requirement 6 and D-4: the chooser is the one overlay the flag cannot
    -- move, whatever the terminal is.
    it "leaves the solve chooser its windowed box even with the flag set" $
      for_ [(width, height) | width <- terminalWidths, height <- terminalHeights] $ \(width, height) -> do
        let chooser = SolveChooser SolveOnly (baseIssue 10 [])
            full = overlayGeometryFor DualMode chooser True width height 4
        ((width, height), (full.overlayGeometryWidth, full.overlayGeometryHeight))
          `shouldBe` ((width, height), windowedOverlayBox DualMode chooser)
        ((width, height), full.overlayGeometryInterior) `shouldBe` ((width, height), BoundedInterior)

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
    it "shows more of a long transcript in each of the three session overlays" $ do
      state <- boardState
      for_ transcriptOverlays $ \(label, overlay, populate) -> do
        let showing = opened overlay (populate state)
            visible frame = length (filter (Data.Text.isInfixOf transcriptMarker) frame)
            windowed = visible (windowedFrame 200 48 showing)
            full = visible (fullscreenFrame 200 48 showing)
        (label, full > windowed) `shouldBe` (label, True)

    it "shows more of the process and incident lists" $ do
      state <- longListState
      for_ ([("processes", ProcessesOverlay, "solve #"), ("incidents", IncidentsOverlay, "PR #")] :: [(String, Overlay, Text)]) $
        \(label, overlay, marker) -> do
          let showing = opened overlay state
              visible frame = length (filter (Data.Text.isInfixOf marker) frame)
              windowed = visible (windowedFrame 200 48 showing)
              full = visible (fullscreenFrame 200 48 showing)
          (label, full > windowed) `shouldBe` (label, True)

    -- The roster is the one interior whose windowed bound is not measured
    -- against 32 at all, and the one requirement 5 says must keep scrolling.
    it "shows more roster rows, and never draws one past the panel's border" $ do
      state <- boardState
      let showing = opened SettingsOverlay state
          drawn frame = length (filter (\row -> any (`Data.Text.isInfixOf` row) rosterRoleNames) frame)
          windowed = windowedFrame 200 48 showing
          full = fullscreenFrame 200 48 showing
      -- Windowed, the panel shows its bounded ten of the compiled thirteen:
      -- the viewport is what holds the other three back, and that is the
      -- mechanism requirement 5 says must survive.
      compiledRosterRows `shouldSatisfy` (> settingsRosterHeight)
      drawn windowed `shouldBe` settingsRosterHeight
      -- Fullscreen it shows more of them, because the growth reached the
      -- roster rather than opening a gap under it.
      drawn full `shouldSatisfy` (> drawn windowed)
      drawn full `shouldSatisfy` (<= compiledRosterRows)
      -- And at neither extent is a row drawn past the panel's border: the
      -- box still closes below the last roster row rather than the roster
      -- running through it.
      for_ ([("windowed", windowed), ("fullscreen", full)] :: [(String, [Text])]) $ \(label, frame) ->
        (label, closesBelowRoster frame) `shouldBe` (label, True)

  -- What section 7 says a fullscreen overlay's ways out are, held against what
  -- each overlay's decoder actually answers. Withdrawing the outside click is
  -- the whole of what fullscreen changes here, so an exit named in the
  -- documentation and absent from the code -- or the reverse -- is a
  -- contradiction this group exists to catch. The process inspector's keys are
  -- arms of @handleEvent@ with no pure decoder to ask, so its row is the one
  -- this cannot reach; @Esc@ closing it is the arm directly above the
  -- settings one in 'Kanban.UI.Events.dispatchEvent'.
  describe "the ways out of an overlay, which fullscreen leaves alone" $ do
    it "closes each overlay on Esc, through that overlay's own decoder" $ do
      boardAction DetailsScope escape `shouldBe` Just DismissOrClose
      boardAction HelpScope escape `shouldBe` Just DismissOrClose
      settingsInput (VtyEvent escape) `shouldBe` SettingsCloseOverlay
      incidentsAction (Just IncidentsOverlay) (VtyEvent escape) `shouldBe` Just CloseIncidentsPanel
      sessionInputEvent (SessionFocus noSessionInputCaps SessionNormal True) escape `shouldBe` Just SessionInputClose

    -- `q` is not a general overlay close and never was: section 7 gives it to
    -- a live-agent overlay's normal mode, and everywhere else in an overlay it
    -- is either the dashboard's own quit or nothing at all. Pinned here
    -- because the fullscreen documentation has to name the exits that exist
    -- rather than a uniform set.
    it "answers q only where section 7 already gave it a meaning" $ do
      boardAction DetailsScope (key 'q') `shouldBe` Just QuitDashboard
      boardAction HelpScope (key 'q') `shouldBe` Just QuitDashboard
      sessionInputEvent (SessionFocus noSessionInputCaps SessionNormal True) (key 'q') `shouldBe` Just SessionInputClose
      settingsInput (VtyEvent (key 'q')) `shouldBe` SettingsIgnoreEvent
      incidentsAction (Just IncidentsOverlay) (VtyEvent (key 'q')) `shouldBe` Just IgnoreIncidentsEvent

    -- The same for the right click, which the help overlay's mouse rows and
    -- section 7's mouse policy both describe: it closes the four overlays that
    -- route through the shared policy, at either extent, and the settings and
    -- incident panels answer it with nothing in either.
    it "closes on a right click only through the shared mouse policy" $
      for_ bothExtents $ \(extentLabel, extent) -> do
        (extentLabel, overlayMouseAction extent DetailsPanel (MouseDown DetailsPanel Vty.BRight [] origin))
          `shouldBe` (extentLabel, Just OverlayMouseClose)
        (extentLabel, settingsInput (MouseDown SettingsPanel Vty.BRight [] origin))
          `shouldBe` (extentLabel, SettingsIgnoreEvent)
        (extentLabel, incidentsAction (Just IncidentsOverlay) (MouseDown IncidentsPanel Vty.BRight [] origin))
          `shouldBe` (extentLabel, Just IgnoreIncidentsEvent)

  -- Two decoders answer @f@ -- the shared arm ahead of the non-modal overlays,
  -- and each live-agent overlay's own modal table -- so the thing worth
  -- pinning is that every overlay that honors the toggle is reached by exactly
  -- one of them. An overlay in neither could never be resized; one in both
  -- would have the shared arm swallow the letter before insert mode could
  -- type it.
  describe "which decoder answers f" $
    it "routes every overlay that honors the toggle to exactly one of the two" $
      for_ everyOverlay $ \overlay -> do
        let shared = sharedFullscreenKey overlay
            modal = overlaySurface overlay `elem` [ReviewSurface, SolveSurface, PullRequestReviewSurface]
        (name overlay, shared || modal) `shouldBe` (name overlay, overlayHonorsFullscreen overlay)
        (name overlay, shared && modal) `shouldBe` (name overlay, False)

  -- Requirement 6's other half and the modal decoder's share of requirement
  -- 2: inside a live-agent overlay the letter is a command in normal mode and
  -- an ordinary character in insert.
  describe "f inside a live-agent overlay" $ do
    let press = Vty.EvKey (Vty.KChar 'f') []
        sessionIn mode live = SessionFocus noSessionInputCaps mode live

    it "is a normal-mode command" $
      sessionInputEvent (sessionIn SessionNormal True) press `shouldBe` Just SessionInputFullscreen

    it "is a character typed into the draft in insert mode" $
      sessionInputEvent (sessionIn SessionInsert True) press `shouldBe` Just (SessionInputInsert 'f')

    -- A session with nothing left to read what it types is pinned to normal
    -- however its stored mode reads, so the key still resizes the overlay
    -- there rather than being swallowed as text nothing will collect.
    it "is a command on a settled session, whatever mode it was left in" $
      for_ [SessionNormal, SessionInsert] $ \mode ->
        (show mode, sessionInputEvent (sessionIn mode False) press) `shouldBe` (show mode, Just SessionInputFullscreen)

    it "leaves the session's own mode exactly where it was" $
      for_ [SessionNormal, SessionInsert] $ \mode ->
        (show mode, sessionModeAfter SessionInputFullscreen mode) `shouldBe` (show mode, mode)

-- | Both extents, labelled, for the assertions that must hold in each.
bothExtents :: [(String, OverlayExtent)]
bothExtents = [("windowed", WindowedOverlay), ("fullscreen", FullscreenOverlay)]

escape :: Vty.Event
escape = Vty.EvKey Vty.KEsc []

key :: Char -> Vty.Event
key character = Vty.EvKey (Vty.KChar character) []

origin :: Location
origin = Location (0, 0)

-- | The nine overlays, one of each surface, so a decision total in
-- 'OverlaySurface' is exercised at every arm.
everyOverlay :: [Overlay]
everyOverlay =
  [ HelpOverlay,
    SettingsOverlay,
    ProcessesOverlay,
    IncidentsOverlay,
    DetailsOverlay (IssueItem (baseIssue 10 [])),
    ReviewOverlay 10,
    SolveChooser SolveOnly (baseIssue 10 []),
    SolveOverlay 10,
    PullRequestReviewOverlay 42
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

-- | The incidents panel open over a board that has a live solve session, so
-- Enter on its first row activates that session — the transition requirement
-- 1 names, and the one that never passes through 'closeOverlay'.
incidentsPanelOverSolveSession :: IO AppState
incidentsPanelOverSolveSession = do
  state <- boardState
  pure (applyIncidentsAction OpenIncidentsPanel (withSolveSession (baseIssue 10 []) SolveFailedPhase state))

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

-- | A marker every transcript line carries, so the rows a transcript viewport
-- is actually showing can be counted apart from the chrome around it.
transcriptMarker :: Text
transcriptMarker = "transcript-line-"

longTranscript :: ChatTranscript
longTranscript = ChatTranscript body body body
  where
    body = Data.Text.unlines [transcriptMarker <> showText line | line <- [1 .. 200 :: Int]]

transcriptOverlays :: [(String, Overlay, AppState -> AppState)]
transcriptOverlays =
  [ ("solve", SolveOverlay 10, withTranscript (\sessions state -> state {appSolveSessions = sessions}) (.appSolveSessions) 10 . withSolveSession (baseIssue 10 []) SolveRunning),
    ("pull request review", PullRequestReviewOverlay 42, withPullRequestTranscript),
    ("issue review", ReviewOverlay 10, withReviewTranscript)
  ]

-- | Put 'longTranscript' on a session that is already in the map, leaving
-- everything else about it alone.
withTranscript ::
  (Map.Map Int (AgentSession phase detail) -> AppState -> AppState) ->
  (AppState -> Map.Map Int (AgentSession phase detail)) ->
  Int ->
  AppState ->
  AppState
withTranscript set get sessionKey state =
  set (Map.adjust (\session -> session {sessionTranscript = longTranscript}) sessionKey (get state)) state

withPullRequestTranscript :: AppState -> AppState
withPullRequestTranscript state =
  withTranscript
    (\sessions current -> current {appPullRequestReviewSessions = sessions})
    (.appPullRequestReviewSessions)
    42
    (withPullRequestSession (basePullRequest 42 [] False []) SolveRunning state)

withReviewTranscript :: AppState -> AppState
withReviewTranscript state =
  withTranscript
    (\sessions current -> current {appReviewSessions = sessions})
    (.appReviewSessions)
    10
    (withReviewSession (baseIssue 10 []) ReviewRunning state)

-- | A board carrying more solve sessions and more drainer incidents than
-- either panel can show at once, so both are clipped windowed and less
-- clipped fullscreen.
longListState :: IO AppState
longListState = do
  state <- boardState
  pure
    (foldr (\number current -> withSolveSession (baseIssue number []) SolveRunning current) state [100 .. 140])
      { appDrainerIncidents = Just [conflictIncident number | number <- [200 .. 240]]
      }

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

-- | Every roster row the compiled default declares, which is the whole list
-- the settings panel has to fit: 'RoleName' and 'ProviderName' are closed
-- enums, so there is no bigger roster to build.
compiledRosterRows :: Int
compiledRosterRows = length (settingsRosterRows (Right defaultRoster))

-- | The role column each roster row opens with, which is how a roster row is
-- told apart from the verbosity radio above it.
rosterRoleNames :: [Text]
rosterRoleNames = map (roleKey . (.rosterRowRole)) (settingsRosterRows (Right defaultRoster))

-- | Whether the panel's own bottom border is still drawn below the last
-- roster row, which is what "scrolls rather than renders past its border"
-- amounts to on a frame.
closesBelowRoster :: [Text] -> Bool
closesBelowRoster frame = case [index | (index, row) <- zip [0 :: Int ..] frame, isRosterRow row] of
  [] -> False
  indices -> any (Data.Text.isInfixOf "┗") (drop (maximum indices + 1) frame)
  where
    isRosterRow row = any (`Data.Text.isInfixOf` row) rosterRoleNames
