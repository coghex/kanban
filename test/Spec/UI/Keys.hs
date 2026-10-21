-- | The keybinding table and the three things that used to restate it.
--
-- Before "Kanban.UI.Keys" existed, @docs\/design.md@ §7, the footer hint
-- line, the help overlay, and the key arms of 'Kanban.UI.Events.handleEvent'
-- were four hand-maintained copies of the same facts, and they had drifted:
-- the footer was missing @g@, @G@, @Esc@, @Ctrl-L@, and @m@, and the help
-- overlay was missing @?@ — its own binding. This group is what stops that
-- happening again, so none of it may assert against a second hand-copied
-- list: everything is either checked against §7 itself or projected from the
-- table and checked for round trip.
module Spec.UI.Keys (spec) where

import Data.Foldable (for_)
import Data.List (nub, sort)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import qualified Graphics.Vty as Vty
import Kanban.Domain (BoardColumn (..), BoardItem (..), Issue (..))
import Kanban.UI.Board (BoardMarks (..), boardFooterHintLine, boardHintLine, defaultBoardMarks, filterFooterHintLine, footerHintLine, overlayHintChips, searchFooterHintLine)
import Kanban.UI.Filter (toggleFilterPanel)
import Kanban.UI.Keys
import Kanban.UI.Overlay (drawOverlay, helpLines, mouseHelpEntries)
import Kanban.UI.Search (openSearch)
import Kanban.UI.Theme (themeFor)
import Kanban.UI.Types (AppState (..), Overlay (..))
import Kanban.UI.Util (shownNotice)
import Spec.Support.App (testAppState)
import Spec.Support.Dashboard (DashboardRun (..), ScriptStep (..), quitStep, runDashboardScript)
import Spec.Support.Fixtures (baseIssue, fixtureBoard, fixtureStandaloneEntry, testOptions)
import Spec.Support.Render (renderWidgetLines)
import Test.Hspec

spec :: Spec
spec = describe "keybinding table" $ do
  describe "dispatch" $ do
    it "resolves every declared key to its own action, in every scope it declares" $
      sequence_
        [ boardAction scope (bindingEvent pressed) `shouldBe` Just candidate.bindingAction
          | candidate <- boardBindings,
            scope <- candidate.bindingScopes,
            pressed <- candidate.bindingKeys
        ]

    it "resolves every alias of a binding identically" $
      sequence_
        [ map (\pressed -> boardAction scope (bindingEvent pressed)) candidate.bindingKeys
            `shouldBe` map (const (Just candidate.bindingAction)) candidate.bindingKeys
          | candidate <- boardBindings,
            scope <- candidate.bindingScopes,
            length candidate.bindingKeys > 1
        ]

    it "never lets two bindings claim the same key in the same scope" $
      let claimed = [(scope, pressed) | b <- boardBindings, scope <- b.bindingScopes, pressed <- b.bindingKeys]
       in length (nub claimed) `shouldBe` length claimed

    it "resolves nothing in a scope a binding does not declare" $
      sequence_
        [ boardAction scope (bindingEvent pressed) `shouldBe` Nothing
          | candidate <- boardBindings,
            scope <- [minBound .. maxBound],
            scope `notElem` candidate.bindingScopes,
            pressed <- candidate.bindingKeys,
            all (notElem pressed . (.bindingKeys)) (scopeBindings scope)
        ]

    it "does not match a declared key carrying a modifier it did not declare" $
      sequence_
        [ boardAction scope (bindingEvent modified) `shouldBe` Nothing
          | candidate <- boardBindings,
            scope <- candidate.bindingScopes,
            pressed <- candidate.bindingKeys,
            extra <- [[Vty.MCtrl], [Vty.MMeta], [Vty.MAlt], [Vty.MCtrl, Vty.MShift]],
            let modified = chord pressed.bindingKeyKey extra,
            modified /= pressed,
            all (notElem modified . (.bindingKeys)) (scopeBindings scope)
        ]

    it "keeps a modified key distinct from its unmodified self" $ do
      boardAction BoardScope (Vty.EvKey (Vty.KChar 'l') []) `shouldBe` Just NextColumn
      boardAction BoardScope (Vty.EvKey (Vty.KChar 'l') [Vty.MCtrl]) `shouldBe` Just RepaintTerminal

    it "leaves an unbound base event unhandled" $
      sequence_
        [ boardAction scope event `shouldBe` Nothing
          | scope <- [minBound .. maxBound],
            event <-
              [ Vty.EvKey (Vty.KChar 'z') [],
                Vty.EvKey (Vty.KChar 'Q') [],
                Vty.EvKey (Vty.KFun 1) [],
                Vty.EvKey Vty.KBS [],
                Vty.EvKey (Vty.KChar '\t') [],
                Vty.EvResize 80 24
              ]
        ]

    -- The overlay scopes were a strict subset of the board's until issue
    -- #543: `f` is the first binding that exists /only/ while an overlay is
    -- open, so it is the one action in each of the three overlay scopes that
    -- the board scope does not carry, and the board keeps exactly everything
    -- else. Spelled as the enumerated lists rather than as a subset
    -- predicate, because a subset check would pass a second overlay-only
    -- binding added by accident.
    it "keeps the overlay scopes to the board's bindings, plus the one that is overlay-only" $ do
      map (.bindingAction) (scopeBindings DetailsScope)
        `shouldBe` [OpenCardPage, ToggleFullscreen, DismissOrClose, QuitDashboard]
      map (.bindingAction) (scopeBindings HelpScope) `shouldBe` [ToggleFullscreen, DismissOrClose, QuitDashboard]
      map (.bindingAction) (scopeBindings OverlayScope) `shouldBe` [ToggleFullscreen]
      map (.bindingAction) (scopeBindings BoardScope)
        `shouldBe` filter (/= ToggleFullscreen) (map (.bindingAction) boardBindings)

    -- Requirement 2: with no overlay open the key does what it does today,
    -- which is nothing at all.
    it "leaves f meaningless on the board itself" $ do
      boardAction BoardScope (Vty.EvKey (Vty.KChar 'f') []) `shouldBe` Nothing
      boardAction DetailsScope (Vty.EvKey (Vty.KChar 'f') []) `shouldBe` Just ToggleFullscreen
      boardAction HelpScope (Vty.EvKey (Vty.KChar 'f') []) `shouldBe` Just ToggleFullscreen
      boardAction OverlayScope (Vty.EvKey (Vty.KChar 'f') []) `shouldBe` Just ToggleFullscreen

  describe "footer projection" $ do
    it "carries one chip per base-board binding, and nothing else" $
      Text.splitOn "  " footerHintLine `shouldBe` map footerHint (scopeBindings BoardScope)

    it "leaves no hint chip that no binding backs" $
      sequence_
        [ (chip, chip `elem` map footerHint boardBindings) `shouldBe` (chip, True)
          | chip <- Text.splitOn "  " footerHintLine
        ]

    -- Issue #664. The excerpt chip is the one label on the line that is not
    -- constant, and both of its spellings are "Kanban.UI.Keys"' own rather
    -- than a second copy kept beside the footer.
    it "respells the excerpt chip from the board's own state, leaving the rest of the line alone" $ do
      let brief = boardFooterHintLine defaultBoardMarks {marksExcerptsVisible = False}
      excerptFooterHint True `shouldBe` footerHint (binding ToggleExcerpts)
      excerptFooterHint False `shouldNotBe` excerptFooterHint True
      Text.splitOn "  " footerHintLine `shouldSatisfy` elem (excerptFooterHint True)
      Text.splitOn "  " brief `shouldSatisfy` elem (excerptFooterHint False)
      length (Text.splitOn "  " brief) `shouldBe` length (Text.splitOn "  " footerHintLine)
      filter (`notElem` Text.splitOn "  " footerHintLine) (Text.splitOn "  " brief)
        `shouldBe` [excerptFooterHint False]

    it "includes the entries the hand-written line had dropped" $
      sequence_
        [ (label, label `elem` Text.splitOn "  " footerHintLine) `shouldBe` (label, True)
          | label <- ["g first", "G last", "esc close", "Ctrl-L repaint"]
        ]

    -- Issue #525. The row along the bottom of the screen used to name the
    -- board's keys whatever overlay was open over it, so it advertised keys
    -- that were not live and named none of the ones that were. Every route
    -- below is asked for its whole row, and the expected side is built from
    -- the declaration sites themselves rather than from the routing in
    -- "Kanban.UI.Board", so a route wired to the wrong list still fails.
    it "shows an open overlay the chips that overlay's own declaration produces" $ do
      base <- overlayBaseState
      sequence_
        [ (name, Text.splitOn "  " (boardHintLine state)) `shouldBe` (name, declared)
          | (name, _, state, declared) <- overlayFooterCases base
        ]

    it "leaves no overlay hint chip that no declaration backs" $ do
      base <- overlayBaseState
      sequence_
        [ (name, chip, chip `elem` declared) `shouldBe` (name, chip, True)
          | (name, _, state, declared) <- overlayFooterCases base,
            chip <- Text.splitOn "  " (boardHintLine state)
        ]

    it "draws every chip the open overlay declares" $ do
      base <- overlayBaseState
      sequence_
        [ (name, chip, chip `elem` Text.splitOn "  " (boardHintLine state)) `shouldBe` (name, chip, True)
          | (name, _, state, declared) <- overlayFooterCases base,
            chip <- declared
        ]

    it "replaces the board's own line rather than leaving it on screen" $ do
      base <- overlayBaseState
      sequence_
        [ (name, boardHintLine state == footerHintLine) `shouldBe` (name, False)
          | (name, _, state, _) <- overlayFooterCases base
        ]

    -- Nothing clears a focused filter box or a live search when an overlay
    -- opens over them, so both states can still be populated underneath one.
    -- The keys reaching the keyboard are the overlay's either way.
    it "lets an open overlay outrank a filter box or a search underneath it" $ do
      base <- overlayBaseState
      let latentFilter = toggleFilterPanel base
          latentSearch = openSearch base
      -- Each surface really does hold the row with no overlay open, which is
      -- what makes the two assertions below about precedence rather than
      -- about an empty state.
      boardHintLine latentFilter `shouldBe` filterFooterHintLine
      boardHintLine latentSearch `shouldBe` searchFooterHintLine
      sequence_
        [ (name, boardHintLine (withOverlay HelpOverlay state))
            `shouldBe` (name, footerHintRow (map footerHint (scopeBindings HelpScope)))
          | (name, state) <- [("filter panel" :: String, latentFilter), ("search box", latentSearch)]
        ]

  -- Issue #525 requirement 4: the overlays that drew a hint line inside their
  -- own box no longer do, now that the base footer names their keys. Rendered
  -- rather than read off the source, and asked of every overlay.
  describe "overlay hint relocation" $ do
    it "accounts for every overlay the dashboard can open" $ do
      base <- overlayBaseState
      nub [overlayRoute overlay | (_, overlay, _, _) <- overlayFooterCases base]
        `shouldMatchList` ["help", "details"]

    it "draws no overlay's hint chips inside its own box" $ do
      base <- overlayBaseState
      -- Each box really draws, so a frame that rendered nothing cannot pass
      -- the absence assertion below by having nothing in it to find.
      sequence_
        [ (name, length (overlayBoxLines state overlay) > 4) `shouldBe` (name, True)
          | (name, overlay, state, _) <- overlayFooterCases base
        ]
      sequence_
        [ (name, chip, any (chip `Text.isInfixOf`) (overlayBoxLines state overlay))
            `shouldBe` (name, chip, False)
          | (name, overlay, state, _) <- overlayFooterCases base,
            chip <- overlayHintChips overlay
        ]

  -- §7 gives `h`, `l`, Left, and Right a different meaning while a search is
  -- open: the letters are text and the arrows move the search. The base line
  -- states the opposite pairing — `h`/Left is one chip, `l`/Right another —
  -- so a search showing it would state both wrongly, and this is the group
  -- that holds the two lines apart.
  describe "search presentation" $ do
    it "names the arrows for the transfer and the letters for the query" $
      sequence_
        [ (fragment, fragment `Text.isInfixOf` searchFooterHintLine) `shouldBe` (fragment, True)
          | fragment <- ["h/l", "type", "←/→ move search", "↑/↓ select", "s/esc close"]
        ]

    it "reuses no chip of the board's own column movement" $
      sequence_
        [ (chip, chip `Text.isInfixOf` searchFooterHintLine) `shouldBe` (chip, False)
          | chip <- map (footerHint . binding) [PreviousColumn, NextColumn]
        ]

    it "leaves the board's line saying what it always said" $
      sequence_
        [ (chip, chip `Text.isInfixOf` footerHintLine) `shouldBe` (chip, True)
          | chip <- map (footerHint . binding) [PreviousColumn, NextColumn]
        ]

    it "describes the transfer in the help overlay too, on the search binding's own row" $ do
      let row = rowOf (bindingHelpEntry (binding OpenSearch))
      sequence_
        [ (fragment, fragment `Text.isInfixOf` row) `shouldBe` (fragment, True)
          | fragment <- ["h/l type into the query", "Left/Right move the search"]
        ]
      sequence_
        [ (fragment, any (Text.isInfixOf fragment) helpLines) `shouldBe` (fragment, True)
          | fragment <- ["h/l type into the query", "Left/Right move the search"]
        ]

  describe "help projection" $ do
    it "renders exactly one row per declared entry, in declaration order" $
      helpLines `shouldBe` helpRows (map bindingHelpEntry boardBindings <> mouseHelpEntries)

    it "leaves no key-hint row that no binding backs" $
      sequence_
        [ (row, any ((== row) . rowOf) declaredEntries) `shouldBe` (row, True)
          | row <- helpLines
        ]

    it "gives every base-board binding a row of its own" $
      length helpLines `shouldBe` length boardBindings + length mouseHelpEntries

    it "keeps the rows no binding backs to mouse prose" $
      sequence_
        [ (entry.helpEntryKeys, entry.helpEntryGesture) `shouldBe` ([], entry.helpEntryGesture)
          | entry <- mouseHelpEntries
        ]

    it "names the help overlay's own binding, which the hand-written list omitted" $
      sequence_
        [ (name, any (Text.isInfixOf name) helpLines) `shouldBe` (name, True)
          | name <- ["this help overlay", "close overlay or dismiss a notice"]
        ]

    it "ends every row with its own description, all starting at one column" $ do
      let gutters = [Text.length row - Text.length entry.helpEntryDescription | (entry, row) <- zip declaredEntries helpLines]
      sequence_
        [ (row, Text.isSuffixOf entry.helpEntryDescription row) `shouldBe` (row, True)
          | (entry, row) <- zip declaredEntries helpLines
        ]
      nub gutters `shouldBe` take 1 gutters

  -- The keys the agent screens and the service controls used. They are
  -- unbound, not repurposed: no scope resolves one to an action, and the
  -- dashboard's own event handler does nothing with one on the base board
  -- beyond the per-event maintenance every event gets. Two of them stay live
  -- where a surface owns the keyboard — a live search types them and the
  -- filter panel's @d@ restores the defaults — which the examples after these
  -- hold apart from the board's table.
  describe "the unbound agent and service keys" $ do
    it "resolves none of them to an action in any scope" $
      sequence_
        [ (scope, character, boardAction scope (Vty.EvKey (Vty.KChar character) []))
            `shouldBe` (scope, character, Nothing)
          | scope <- [minBound .. maxBound],
            character <- removedKeys
        ]

    it "claims none of them in the table at all" $
      sequence_
        [ (character, [candidate.bindingAction | candidate <- boardBindings, pressed <- candidate.bindingKeys, pressed == chord (Vty.KChar character) []])
            `shouldBe` (character, [])
          | character <- removedKeys
        ]

    it "leaves the base board unchanged when one is pressed with no overlay open" $ do
      base <- testAppState (fixtureBoard [(Issues, [fixtureStandaloneEntry 10])])
      baseline <- runDashboardScript (120, 40) id base [quitStep]
      for_ removedKeys $ \character -> do
        pressed <- runDashboardScript (120, 40) id base [Press (Vty.EvKey (Vty.KChar character) []), quitStep]
        (character, quietFacts pressed.runState) `shouldBe` (character, quietFacts baseline.runState)
        pressed.runState.appOverlay `shouldBe` Nothing

  describe "docs/design.md §7" $ do
    it "states exactly the keys and actions the table declares" $ do
      documented <- documentedBindings
      sort documented `shouldBe` sort declaredBindings

    it "lists exactly as many bindings as the table declares" $ do
      documented <- documentedBindings
      length documented `shouldBe` length boardBindings

    it "leaves no row of its table unaccounted for on either side" $ do
      documented <- documentedBindings
      let documentedOnly = filter (`notElem` declaredBindings) documented
          declaredOnly = filter (`notElem` documented) declaredBindings
      (documentedOnly, declaredOnly) `shouldBe` ([], [])

-- | Every help row the overlay is allowed to show, from the definitions that
-- back them rather than from a copy of the overlay's own output.
declaredEntries :: [HelpEntry]
declaredEntries = map bindingHelpEntry boardBindings <> mouseHelpEntries

-- | One entry rendered the way the overlay renders it, so a row can be
-- matched back to the definition that produced it.
rowOf :: HelpEntry -> Text
rowOf entry = case helpRows (entry : declaredEntries) of
  row : _ -> row
  [] -> ""

-- | Every binding the table declares, as the pair §7 states it in: the key
-- names, and the action. The short footer label and help description are
-- deliberately not that wording — §7 is prose and they are a cheat sheet — so
-- what a binding claims §7 says is the field compared here.
declaredBindings :: [([Text], Text)]
declaredBindings =
  [ (map singleKeyName entry.helpEntryKeys <> maybe [] pure entry.helpEntryGesture, contract)
    | entry <- map bindingHelpEntry boardBindings,
      Just contract <- [entry.helpEntryContract]
  ]

singleKeyName :: BindingKey -> Text
singleKeyName pressed = helpKeyText [pressed]

-- | Every binding §7's table documents, one pair per row, both columns.
-- Parsed rather than restated: a second hand-copied inventory here would
-- recreate the drift this module exists to catch.
documentedBindings :: IO [([Text], Text)]
documentedBindings = do
  contents <- TextIO.readFile "docs/design.md"
  pure [(keyCell row, actionCell row) | row <- bindingRows (Text.lines contents)]
  where
    bindingRows =
      filter isBindingRow
        . takeWhile (not . Text.isPrefixOf "## 8.")
        . drop 1
        . dropWhile (not . Text.isPrefixOf "## 7. Keyboard interaction")

    isBindingRow line =
      Text.isPrefixOf "|" line
        && firstCell line /= "Key"
        && not (Text.all (== '-') (firstCell line))

    firstCell line = case Text.splitOn "|" line of
      _ : cell : _ -> Text.strip cell
      _ -> ""

    actionCell line = case Text.splitOn "|" line of
      _ : _ : cell : _ -> Text.strip cell
      _ -> ""

    keyCell =
      map (Text.strip . Text.filter (/= '`'))
        . Text.splitOn "/"
        . Text.replace " or " "/"
        . firstCell

-- | A dashboard with nothing open, which every overlay case below starts from.
overlayBaseState :: IO AppState
overlayBaseState = testAppState (fixtureBoard [])

overlayIssue :: Issue
overlayIssue = baseIssue 901 []

withOverlay :: Overlay -> AppState -> AppState
withOverlay overlay state = state {appOverlay = Just overlay}

-- | Every distinct overlay route the footer answers: what to call it, the
-- overlay itself, a state with it open, and the chips its own declaration
-- site produces for that state.
--
-- Total over the routes rather than over 'Overlay' -- which carries payloads
-- and so cannot be enumerated -- with 'overlayRoute' holding the inventory
-- to two.
overlayFooterCases :: AppState -> [(String, Overlay, AppState, [Text])]
overlayFooterCases base =
  [ opened "help" HelpOverlay (map footerHint (scopeBindings HelpScope)),
    opened "details" (DetailsOverlay (IssueItem overlayIssue)) (map footerHint (scopeBindings DetailsScope))
  ]
  where
    opened name overlay declared = (name, overlay, withOverlay overlay base, declared)

-- | What to call one overlay's footer route. Total in 'Overlay', so a new
-- overlay cannot be added without deciding what its row says and adding a
-- case above.
overlayRoute :: Overlay -> String
overlayRoute = \case
  HelpOverlay -> "help"
  DetailsOverlay _ -> "details"

-- | One overlay drawn through the real 'drawOverlay', so what is asserted
-- absent is absent from the box a user actually sees rather than from the
-- source that builds it.
overlayBoxLines :: AppState -> Overlay -> [Text]
overlayBoxLines state overlay = renderWidgetLines (themeFor testOptions) 120 (drawOverlay state overlay)

-- | The six keys the agent screens used: review, solve, autosolve, kill,
-- processes, and settings.
removedAgentKeys :: [Char]
removedAgentKeys = "rSAxpo"

-- | The four keys the service controls used: the incidents panel, the issue
-- approval service, the PR drainer, and the direct merge.
removedServiceKeys :: [Char]
removedServiceKeys = "iadm"

-- | Every key a board binding was removed from.
removedKeys :: [Char]
removedKeys = removedAgentKeys <> removedServiceKeys

-- | Everything an unbound key must leave alone on the base board: the overlay,
-- the notice, the selection, the search and filter surfaces, and the sidebar
-- and excerpt state a binding could have moved. The clock, the notice's expiry and the
-- layout epochs are per-event maintenance and are deliberately not compared.
quietFacts :: AppState -> (Maybe Overlay, Maybe Text, (Int, [(Int, Int)]), Bool, Bool, Bool, Bool)
quietFacts state =
  ( state.appOverlay,
    shownNotice state,
    (fromEnum state.appSelectedColumn, [(fromEnum column, row) | (column, row) <- Map.toList state.appSelectedRows]),
    state.appSearch == Nothing,
    state.appFilterPanel == Nothing,
    state.appSidebarVisible,
    state.appExcerptsVisible
  )
