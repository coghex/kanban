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

import Data.List (nub, sort)
import Data.Maybe (isNothing)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import qualified Graphics.Vty as Vty
import Kanban.Domain (BoardItem (..), Issue (..), PullRequest (..))
import Kanban.Models (OperatingMode (..), ProviderName (..), noAgentModeMessage)
import Kanban.Review (ReviewStage (..))
import Kanban.Solve (SolveWorkflow (..))
import Kanban.UI.Board (boardFooterHintLine, boardHintLine, filterFooterHintLine, footerHintLine, overlayHintChips, searchFooterHintLine)
import Kanban.UI.Filter (toggleFilterPanel)
import Kanban.UI.Keys
import Kanban.UI.Overlay (drawOverlay, helpLines, mouseHelpEntries)
import Kanban.UI.Search (openSearch)
import Kanban.UI.Session (incidentsFooterHints, processesFooterHints)
import Kanban.UI.Settings (settingsFooterHints)
import Kanban.UI.Solve (solveChooserFooterHints)
import Kanban.UI.Theme (themeFor)
import Kanban.UI.Types
  ( AgentSession (..),
    AppState (..),
    Overlay (..),
    ReviewDetail (..),
    ReviewPhase (..),
    SessionMode (..),
    SolvePhase (..),
  )
import Kanban.UI.SessionCore (SessionFocus (..), SessionInputEvent (..), noSessionInputCaps, sessionFooterHints, sessionInputEvent, sessionInputHelp)
import Spec.Support.App (testAppState, testPullRequestSession, testReviewSession, testSolveSession)
import Spec.Support.Fixtures (baseIssue, basePullRequest, fixtureBoard, testOptions)
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
        `shouldBe` [KillWorking, ToggleFullscreen, DismissOrClose, ReviewSelection, SolveSelection, AutoSolveSelection, MergeDoneCard, QuitDashboard]
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

    it "includes the entries the hand-written line had dropped" $
      sequence_
        [ (label, label `elem` Text.splitOn "  " footerHintLine) `shouldBe` (label, True)
          | label <- ["g first", "G last", "esc close", "m merge", "Ctrl-L repaint"]
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

  -- Issue #525 requirement 4: the seven overlays that drew a hint line inside
  -- their own box no longer do, now that the base footer names their keys.
  -- Rendered rather than read off the source, and asked of all seven -- the
  -- processes, incidents, and PR review overlays have no golden frame of
  -- their own, so nothing else here would notice one coming back.
  describe "overlay hint relocation" $ do
    it "accounts for every overlay the dashboard can open" $ do
      base <- overlayBaseState
      nub [overlayRoute overlay | (_, overlay, _, _) <- overlayFooterCases base]
        `shouldMatchList` [ "help",
                            "details",
                            "settings",
                            "processes",
                            "incidents",
                            "solve chooser",
                            "solve",
                            "pull request review",
                            "issue review"
                          ]

    it "draws no overlay's hint chips inside its own box" $ do
      base <- overlayBaseState
      -- Each box really draws, so a frame that rendered nothing cannot pass
      -- the absence assertion below by having nothing in it to find.
      sequence_
        [ (name, length (overlayBoxLines state overlay) > 4) `shouldBe` (name, True)
          | (name, overlay, state, _) <- overlayFooterCases base,
            drewItsOwnHint overlay
        ]
      sequence_
        [ (name, chip, any (chip `Text.isInfixOf`) (overlayBoxLines state overlay))
            `shouldBe` (name, chip, False)
          | (name, overlay, state, _) <- overlayFooterCases base,
            drewItsOwnHint overlay,
            chip <- overlayHintChips state overlay
        ]

    -- The negative control. The details and help overlays never drew a hint
    -- line, so they are the two the assertion above must skip, and naming
    -- them keeps a predicate that skipped everything from passing it.
    it "skips exactly the two overlays that never drew one" $ do
      base <- overlayBaseState
      nub [overlayRoute overlay | (_, overlay, _, _) <- overlayFooterCases base, not (drewItsOwnHint overlay)]
        `shouldMatchList` ["help", "details"]

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
        [ (fragment, any (Text.isInfixOf fragment) (helpLines DualMode)) `shouldBe` (fragment, True)
          | fragment <- ["h/l type into the query", "Left/Right move the search"]
        ]

  describe "help projection" $ do
    it "renders exactly one row per declared entry, in declaration order" $
      helpLines DualMode `shouldBe` helpRows (map bindingHelpEntry boardBindings <> sessionInputHelp <> mouseHelpEntries)

    it "leaves no key-hint row that no binding backs" $
      sequence_
        [ (row, any ((== row) . rowOf) declaredEntries) `shouldBe` (row, True)
          | row <- helpLines DualMode
        ]

    it "gives every base-board and session binding a row of its own" $
      length (helpLines DualMode) `shouldBe` length boardBindings + length sessionInputHelp + length mouseHelpEntries

    it "keeps the rows no binding backs to mouse prose" $
      sequence_
        [ (entry.helpEntryKeys, entry.helpEntryGesture) `shouldBe` ([], entry.helpEntryGesture)
          | entry <- mouseHelpEntries
        ]

    it "names the help overlay's own binding, which the hand-written list omitted" $
      sequence_
        [ (name, any (Text.isInfixOf name) (helpLines DualMode)) `shouldBe` (name, True)
          | name <- ["this help overlay", "close overlay or dismiss a notice"]
        ]

    it "ends every row with its own description, all starting at one column" $ do
      let gutters = [Text.length row - Text.length entry.helpEntryDescription | (entry, row) <- zip declaredEntries (helpLines DualMode)]
      sequence_
        [ (row, Text.isSuffixOf entry.helpEntryDescription row) `shouldBe` (row, True)
          | (entry, row) <- zip declaredEntries (helpLines DualMode)
        ]
      nub gutters `shouldBe` take 1 gutters

  describe "session overlay bindings" $ do
    -- Every documented session key is answered from the mode §7 documents it
    -- in, with the caps of the kind that offers the fewest optional bindings:
    -- a row the decoder only honours for the review overlay would be a help
    -- entry the solve and PR overlays cannot back.
    it "declares only keys its own decoder answers" $
      sequence_
        [ (helpEntryDescription entry, fmap (const ()) (sessionInputEvent normalFocus (bindingEvent pressed)))
            `shouldBe` (helpEntryDescription entry, Just ())
          | entry <- sessionInputHelp,
            pressed <- entry.helpEntryKeys
        ]

    -- The mode split is the point of the rows, so the normal-mode ones must
    -- not also answer from insert -- otherwise `q` would close an overlay
    -- mid-word and `j` would refuse to type.
    it "keeps the normal-mode rows out of insert mode" $
      sequence_
        [ (helpEntryDescription entry, sessionInputEvent insertFocus (bindingEvent pressed))
            `shouldBe` (helpEntryDescription entry, Just (SessionInputInsert character))
          | entry <- sessionInputHelp,
            pressed <- entry.helpEntryKeys,
            Vty.KChar character <- [pressed.bindingKeyKey],
            null pressed.bindingKeyModifiers,
            character /= '\t'
        ]

  -- Issue #521, narrowed by issue #546. A board whose roster loads no
  -- provider starts nothing, so the four bindings that start agent work come
  -- off the footer and out of the help overlay instead of being advertised
  -- and then refused. `x` and `p` are not among them: they inspect and
  -- terminate work that is already running, which such a board inherits from
  -- worker discovery. Both surfaces project from 'modeBoardBindings', which
  -- is why one group covers them, and every expectation below is built from
  -- the table rather than from a second copy of the line -- the same rule the
  -- rest of this module keeps.
  describe "operating mode" $ do
    it "hides exactly the four bindings §7's paragraph names, and no others" $ do
      filter requiresLoadedAgent (map (.bindingAction) boardBindings) `shouldBe` agentBindings
      map (.bindingAction) (modeBoardBindings NoAgentMode)
        `shouldBe` filter (`notElem` agentBindings) (map (.bindingAction) boardBindings)

    -- Issue #546 requirement 1, stated as a positive rather than left to the
    -- negative control below: the two keys that reach already-running work
    -- are on the no-agent board's footer line and in its help overlay, and
    -- neither is refused. Where on the line they sit is that control's
    -- question, since it compares the whole line against the table's order.
    it "keeps the inspector and the kill key on both surfaces, and refuses neither" $ do
      sequence_
        [ (action, footerHint (binding action) `elem` Text.splitOn "  " noAgentFooterHintLine)
            `shouldBe` (action, True)
          | action <- recoveryBindings
        ]
      sequence_
        [ (action, any (Text.isInfixOf (binding action).bindingDescription) (helpLines NoAgentMode))
            `shouldBe` (action, True)
          | action <- recoveryBindings
        ]
      sequence_
        [ (action, agentSurfaceRefusal NoAgentMode action) `shouldBe` (action, Nothing)
          | action <- recoveryBindings
        ]

    it "leaves dual and single-agent mode the whole table, in the order it has today" $
      sequence_
        [ (name, map (.bindingAction) (modeBoardBindings mode))
            `shouldBe` (name, map (.bindingAction) boardBindings)
          | (name, mode) <- loadedModes
        ]

    -- Visible and refused are one decision read two ways, so the two sets are
    -- compared against each other in all three modes rather than each being
    -- checked against its own list.
    it "refuses exactly what it hides, in every mode" $
      sequence_
        [ (show mode, action, isNothing (agentSurfaceRefusal mode action))
            `shouldBe` (show mode, action, action `elem` map (.bindingAction) (modeBoardBindings mode))
          | mode <- NoAgentMode : map snd loadedModes,
            action <- map (.bindingAction) boardBindings
        ]

    it "says the roster's own words when it refuses" $
      sequence_
        [ (action, agentSurfaceRefusal NoAgentMode action) `shouldBe` (action, Just noAgentModeMessage)
          | action <- agentBindings
        ]

    it "drops each hidden binding's chip from the no-agent footer line" $
      sequence_
        [ (chip, chip `elem` Text.splitOn "  " noAgentFooterHintLine) `shouldBe` (chip, False)
          | chip <- map (footerHint . binding) agentBindings
        ]

    -- The negative control. Without it a projection that hid every chip would
    -- pass the assertion above by leaving nothing on the line at all.
    it "keeps every chip it does not hide, in the order it had" $
      Text.splitOn "  " noAgentFooterHintLine
        `shouldBe` map footerHint (filter (not . requiresLoadedAgent . (.bindingAction)) (scopeBindings BoardScope))

    it "leaves the footer line itself alone in dual and single-agent mode" $
      sequence_
        [ (name, boardFooterHintLine mode False) `shouldBe` (name, footerHintLine)
          | (name, mode) <- loadedModes
        ]

    -- `r`, `S`, and `A` are live from a card's details overlay too, and its
    -- footer is the same projection, so it hides them for the same reason.
    -- `x` is the fourth binding that footer carries and it stays, which is
    -- the half of requirement 1 this scope owns.
    it "hides the three a card's details overlay also carries, and keeps x" $ do
      map (.bindingAction) (modeScopeBindings NoAgentMode DetailsScope)
        `shouldBe` [KillWorking, ToggleFullscreen, DismissOrClose, MergeDoneCard, QuitDashboard]
      sequence_
        [ (name, map (.bindingAction) (modeScopeBindings mode DetailsScope))
            `shouldBe` (name, map (.bindingAction) (scopeBindings DetailsScope))
          | (name, mode) <- loadedModes
        ]

    it "drops each hidden binding's row from the no-agent help overlay" $
      sequence_
        [ (description, any (Text.isInfixOf description) (helpLines NoAgentMode))
            `shouldBe` (description, False)
          | description <- map ((.bindingDescription) . binding) agentBindings
        ]

    -- The help overlay's other two blocks are not the mode's to hide: the
    -- session rows belong to a live-agent overlay's own decoder and the mouse
    -- rows are prose about a policy no binding covers.
    it "keeps every row it does not hide, including the session and mouse blocks" $ do
      length (helpLines NoAgentMode)
        `shouldBe` length boardBindings
          - length agentBindings
          + length sessionInputHelp
          + length mouseHelpEntries
      sequence_
        [ (row, any ((== row) . rowOf) declaredEntries) `shouldBe` (row, True)
          | row <- helpLines NoAgentMode
        ]
      sequence_
        [ (entry.helpEntryDescription, any (Text.isInfixOf entry.helpEntryDescription) (helpLines NoAgentMode))
            `shouldBe` (entry.helpEntryDescription, True)
          | entry <- sessionInputHelp <> mouseHelpEntries
        ]

    it "leaves the help overlay itself alone in dual and single-agent mode" $
      sequence_
        [ (name, helpLines mode) `shouldBe` (name, helpLines DualMode)
          | (name, mode) <- loadedModes
        ]

  describe "docs/design.md §7" $ do
    it "states exactly the keys and actions the table declares" $ do
      documented <- documentedBindings
      sort documented `shouldBe` sort declaredBindings

    it "lists exactly as many bindings as the table declares" $ do
      documented <- documentedBindings
      length documented `shouldBe` length boardBindings + length sessionInputHelp

    it "leaves no row of its table unaccounted for on either side" $ do
      documented <- documentedBindings
      let documentedOnly = filter (`notElem` declaredBindings) documented
          declaredOnly = filter (`notElem` documented) declaredBindings
      (documentedOnly, declaredOnly) `shouldBe` ([], [])

-- | Every mode that loads a provider, which hide nothing at all. Named
-- rather than written inline so a failure says which one moved.
--
-- Both singletons, not one standing in for the other: issue #589 gives
-- 'SingleAgentMode' the provider it loads, and key visibility is the one
-- surface that decision deliberately does not move
-- ("Kanban.UI.Keys" -- which brand a role runs on is decided at the spawn
-- boundary, not on the footer). Listing each is what holds that.
loadedModes :: [(String, OperatingMode)]
loadedModes =
  [ ("dual", DualMode),
    ("single-agent codex", SingleAgentMode CodexProvider),
    ("single-agent claude", SingleAgentMode ClaudeProvider)
  ]

-- | The four bindings a no-agent board is left without -- issue #521's six,
-- less the two issue #546 gave back -- written out rather than filtered from
-- 'requiresLoadedAgent', so a binding that quietly joined or left that
-- predicate fails this module instead of moving the expectation with it.
agentBindings :: [BoardAction]
agentBindings =
  [ ReviewSelection,
    SolveSelection,
    AutoSolveSelection,
    ToggleApproval
  ]

-- | The two the same issue put back, which the assertions below pair with
-- 'agentBindings' so that hiding either of them again fails here rather than
-- only in a golden frame.
recoveryBindings :: [BoardAction]
recoveryBindings = [KillWorking, ShowProcesses]

-- | The board's footer line with no provider loaded and nothing filtering.
noAgentFooterHintLine :: Text
noAgentFooterHintLine = boardFooterHintLine NoAgentMode False

-- | The two modes a session key is decoded in, with no optional binding
-- enabled and something still there to read what the session types.
normalFocus, insertFocus :: SessionFocus
normalFocus = SessionFocus noSessionInputCaps SessionNormal True
insertFocus = SessionFocus noSessionInputCaps SessionInsert True

-- | Every help row the overlay is allowed to show, from the definitions that
-- back them rather than from a copy of the overlay's own output.
declaredEntries :: [HelpEntry]
declaredEntries = map bindingHelpEntry boardBindings <> sessionInputHelp <> mouseHelpEntries

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
    | entry <- map bindingHelpEntry boardBindings <> sessionInputHelp,
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

-- | A dashboard with nothing open and no session in flight, which every
-- overlay case below starts from.
overlayBaseState :: IO AppState
overlayBaseState = testAppState (fixtureBoard [])

overlayIssue :: Issue
overlayIssue = baseIssue 901 []

overlayPullRequest :: PullRequest
overlayPullRequest = basePullRequest 823 [901] False []

withOverlay :: Overlay -> AppState -> AppState
withOverlay overlay state = state {appOverlay = Just overlay}

-- | Every distinct overlay route the footer answers: what to call it, the
-- overlay itself, a state with it open, and the chips its own declaration
-- site produces for that state.
--
-- Total over the routes rather than over 'Overlay' -- which carries payloads
-- and so cannot be enumerated -- with 'overlayRoute' holding the inventory
-- to nine. The three live-agent overlays appear more than once because the
-- row follows the focused session's /effective/ mode, and the cases that
-- pin that are the ones where the stored mode and the effective one differ.
overlayFooterCases :: AppState -> [(String, Overlay, AppState, [Text])]
overlayFooterCases base =
  [ opened "help" HelpOverlay (map footerHint (scopeBindings HelpScope)),
    opened "details" (DetailsOverlay (IssueItem overlayIssue)) (map footerHint (scopeBindings DetailsScope)),
    opened "settings" SettingsOverlay settingsFooterHints,
    opened "processes" ProcessesOverlay processesFooterHints,
    opened "incidents" IncidentsOverlay incidentsFooterHints,
    opened "solve chooser" (SolveChooser SolveOnly overlayIssue) solveChooserFooterHints,
    solveCase "solve waiting for an answer" SolveAttention SessionNormal (focusOf SessionNormal True),
    solveCase "solve in insert mode" SolveAttention SessionInsert (focusOf SessionInsert True),
    solveCase "solve still running" SolveRunning SessionNormal (focusOf SessionNormal False),
    -- The stored mode says insert and nothing is left to read what it types,
    -- which is the state 'liveSessionMode' exists to pin to normal.
    solveCase "solve left in insert mode with no reader" SolveRunning SessionInsert (focusOf SessionNormal False),
    -- An overlay whose session the map no longer holds still answers Esc and
    -- q, so the row has to name them rather than go blank.
    ( "solve whose session is gone",
      SolveOverlay (overlayIssue.issueNumber + 1),
      withOverlay (SolveOverlay (overlayIssue.issueNumber + 1)) base,
      sessionFooterHints "answer" (focusOf SessionNormal False)
    ),
    pullRequestCase "pull request review in insert mode" SolveAttention SessionInsert (focusOf SessionInsert True),
    pullRequestCase "pull request review still running" SolveRunning SessionNormal (focusOf SessionNormal False),
    reviewCase "issue review revision in insert mode" IssueRevision ReviewRunning SessionInsert (focusOf SessionInsert True),
    reviewCase "issue review revision in normal mode" IssueRevision ReviewRunning SessionNormal (focusOf SessionNormal True),
    -- A canonical stage runs a subprocess and never reads typed text, so the
    -- row is the no-input one however the session was left.
    reviewCase "canonical issue review" InitialReview ReviewRunning SessionInsert (focusOf SessionNormal False)
  ]
  where
    opened name overlay declared = (name, overlay, withOverlay overlay base, declared)

    focusOf mode liveInput = SessionFocus noSessionInputCaps mode liveInput

    solveCase name phase mode sessionFocus =
      ( name,
        SolveOverlay overlayIssue.issueNumber,
        (withOverlay (SolveOverlay overlayIssue.issueNumber) base)
          { appSolveSessions =
              Map.singleton overlayIssue.issueNumber ((testSolveSession overlayIssue phase) {sessionMode = mode})
          },
        sessionFooterHints "answer" sessionFocus
      )

    pullRequestCase name phase mode sessionFocus =
      ( name,
        PullRequestReviewOverlay overlayPullRequest.pullRequestNumber,
        (withOverlay (PullRequestReviewOverlay overlayPullRequest.pullRequestNumber) base)
          { appPullRequestReviewSessions =
              Map.singleton
                overlayPullRequest.pullRequestNumber
                ((testPullRequestSession overlayPullRequest phase) {sessionMode = mode})
          },
        sessionFooterHints "answer" sessionFocus
      )

    reviewCase name reviewStage phase mode sessionFocus =
      ( name,
        ReviewOverlay overlayIssue.issueNumber,
        (withOverlay (ReviewOverlay overlayIssue.issueNumber) base)
          { appReviewSessions = Map.singleton overlayIssue.issueNumber staged
          },
        sessionFooterHints "send" sessionFocus
      )
      where
        session = (testReviewSession overlayIssue phase) {sessionMode = mode}
        staged = session {sessionDetail = session.sessionDetail {reviewSessionStage = reviewStage}}

-- | What to call one overlay's footer route. Total in 'Overlay', so a new
-- overlay cannot be added without deciding what its row says and adding a
-- case above.
overlayRoute :: Overlay -> String
overlayRoute = \case
  HelpOverlay -> "help"
  DetailsOverlay _ -> "details"
  SettingsOverlay -> "settings"
  ProcessesOverlay -> "processes"
  IncidentsOverlay -> "incidents"
  SolveChooser _ _ -> "solve chooser"
  SolveOverlay _ -> "solve"
  PullRequestReviewOverlay _ -> "pull request review"
  ReviewOverlay _ -> "issue review"

-- | Whether this overlay used to draw a hint line inside its own box. Total
-- for the same reason 'overlayRoute' is.
drewItsOwnHint :: Overlay -> Bool
drewItsOwnHint = \case
  HelpOverlay -> False
  DetailsOverlay _ -> False
  SettingsOverlay -> True
  ProcessesOverlay -> True
  IncidentsOverlay -> True
  SolveChooser _ _ -> True
  SolveOverlay _ -> True
  PullRequestReviewOverlay _ -> True
  ReviewOverlay _ -> True

-- | One overlay drawn through the real 'drawOverlay', so what is asserted
-- absent is absent from the box a user actually sees rather than from the
-- source that builds it.
overlayBoxLines :: AppState -> Overlay -> [Text]
overlayBoxLines state overlay = renderWidgetLines (themeFor testOptions) 120 (drawOverlay state overlay)
