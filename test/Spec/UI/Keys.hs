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
import Kanban.UI.Board (footerHintLine)
import Kanban.UI.Keys
import Kanban.UI.Overlay (helpLines, mouseHelpEntries)
import Kanban.UI.SessionCore (noSessionInputCaps, sessionInputEvent, sessionInputHelp)
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

  describe "session overlay bindings" $
    it "declares only keys its own decoder answers" $
      sequence_
        [ (helpEntryDescription entry, fmap (const ()) (sessionInputEvent noSessionInputCaps (bindingEvent pressed)))
            `shouldBe` (helpEntryDescription entry, Just ())
          | entry <- sessionInputHelp,
            pressed <- entry.helpEntryKeys
        ]

  describe "docs/design.md §7" $ do
    it "lists exactly the keys the table declares, grouped the same way" $ do
      documented <- documentedKeys
      sort documented `shouldBe` sort declaredKeys

    it "lists exactly as many bindings as the table declares" $ do
      documented <- documentedKeys
      length documented `shouldBe` length boardBindings + length sessionInputHelp

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

-- | Every key name the table declares, one list per binding.
declaredKeys :: [[Text]]
declaredKeys =
  map (map singleKeyName . (.bindingKeys)) boardBindings
    <> map (map singleKeyName . (.helpEntryKeys)) sessionInputHelp

singleKeyName :: BindingKey -> Text
singleKeyName pressed = helpKeyText [pressed]

-- | Every key name §7's table documents, one list per row. Parsed rather than
-- restated: a second hand-copied inventory here would recreate the drift this
-- module exists to catch.
documentedKeys :: IO [[Text]]
documentedKeys = do
  contents <- TextIO.readFile "docs/design.md"
  pure (map keyCell (bindingRows (Text.lines contents)))
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

    keyCell =
      filter (/= "click")
        . map (Text.strip . Text.filter (/= '`'))
        . Text.splitOn "/"
        . Text.replace " or " "/"
        . firstCell
