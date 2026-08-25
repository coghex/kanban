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
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import qualified Graphics.Vty as Vty
import Kanban.UI.Board (footerHintLine, searchFooterHintLine)
import Kanban.UI.Keys
import Kanban.UI.Overlay (helpLines, mouseHelpEntries)
import Kanban.UI.Types (SessionMode (..))
import Kanban.UI.SessionCore (SessionFocus (..), SessionInputEvent (..), noSessionInputCaps, sessionInputEvent, sessionInputHelp)
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

    it "keeps the overlay-scoped bindings a strict subset of the board's" $ do
      map (.bindingAction) (scopeBindings DetailsScope)
        `shouldBe` [KillWorking, DismissOrClose, ReviewSelection, SolveSelection, AutoSolveSelection, MergeDoneCard, QuitDashboard]
      map (.bindingAction) (scopeBindings HelpScope) `shouldBe` [DismissOrClose, QuitDashboard]
      map (.bindingAction) (scopeBindings BoardScope) `shouldBe` map (.bindingAction) boardBindings

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
      helpLines `shouldBe` helpRows (map bindingHelpEntry boardBindings <> sessionInputHelp <> mouseHelpEntries)

    it "leaves no key-hint row that no binding backs" $
      sequence_
        [ (row, any ((== row) . rowOf) declaredEntries) `shouldBe` (row, True)
          | row <- helpLines
        ]

    it "gives every base-board and session binding a row of its own" $
      length helpLines `shouldBe` length boardBindings + length sessionInputHelp + length mouseHelpEntries

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
