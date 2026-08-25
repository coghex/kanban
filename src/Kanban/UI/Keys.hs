-- | The one place a base-board key binding is declared.
--
-- @docs\/design.md@ §7 is the keyboard contract, and it used to be
-- transcribed three times over: once into the footer hint line, once into the
-- help overlay, and once into the key arms of 'Kanban.UI.Events.handleEvent'.
-- Nothing checked the three against each other, so they drifted — a kill
-- notice named @k@ for the @x@ binding, the footer omitted @g@, @G@, @Esc@,
-- @Ctrl-L@, and @m@, and the help overlay omitted @?@ itself.
--
-- Every one of those facts now has a single definition site: 'binding' maps
-- each 'BoardAction' to its keys, scopes, footer label, and help
-- description. Dispatch consults 'boardAction', the footer projects
-- 'footerHint', the help overlay projects 'bindingHelpEntry', and a notice
-- that has to name a shortcut asks 'actionKeyText' rather than spelling the
-- key out again.
--
-- A binding is a /physical/ key: the Vty key together with the exact
-- modifier set that must be present, so @l@ and @Ctrl-L@ are different
-- bindings rather than the same one with a modifier ignored. It is also
-- /scoped/: @q@ quits from the board, the help overlay, and a card's details
-- overlay, while @j@ moves the board selection and means something else
-- entirely inside an overlay that scrolls.
--
-- Configurable bindings are still deferred (§20). This table is where they
-- would be read into.
module Kanban.UI.Keys
  ( -- * Physical keys
    BindingKey (..),
    chord,
    bindingEvent,
    eventBindingKey,

    -- * The table
    BindingScope (..),
    BoardAction (..),
    KeyBinding (..),
    binding,
    boardBindings,
    boardAction,
    scopeBindings,

    -- * Projections
    HelpEntry (..),
    bindingHelpEntry,
    gestureHelpEntry,
    helpRows,
    footerHint,
    footerKeyText,
    helpKeyText,
    actionKeyText,
  )
where

import Data.Char (toUpper)
import Data.List (find, nub, sort)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Graphics.Vty as Vty

-- | One physical key press: the Vty key and the exact set of modifiers that
-- has to be held with it. Build one with 'chord', which normalizes the
-- modifier list so a comparison can never depend on the order Vty happens to
-- report modifiers in.
data BindingKey = BindingKey
  { bindingKeyKey :: Vty.Key,
    bindingKeyModifiers :: [Vty.Modifier]
  }
  deriving stock (Eq, Ord, Show)

-- | A physical key with its modifiers normalized.
chord :: Vty.Key -> [Vty.Modifier] -> BindingKey
chord key modifiers = BindingKey key (sort (nub modifiers))

-- | The Vty event a physical key arrives as.
bindingEvent :: BindingKey -> Vty.Event
bindingEvent pressed = Vty.EvKey pressed.bindingKeyKey pressed.bindingKeyModifiers

-- | The physical key a Vty event names, if it is a key press at all.
eventBindingKey :: Vty.Event -> Maybe BindingKey
eventBindingKey (Vty.EvKey key modifiers) = Just (chord key modifiers)
eventBindingKey _ = Nothing

-- | Where a binding is live. The dashboard's other overlays — settings, the
-- process inspector, the incidents panel, and the three live-agent overlays —
-- consume their own input before dispatch reaches this table, so they are
-- deliberately absent: an overlay that answers a key itself is not a scope
-- the base board can be dispatched in.
data BindingScope
  = -- | The board itself, with no overlay open.
    BoardScope
  | -- | A card's details overlay, which repeats the actions that operate on
    -- the card it is showing.
    DetailsScope
  | -- | The help overlay.
    HelpScope
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Every base-board action, in the order §7's table lists them — which is
-- also the order the footer and the help overlay render them in, since both
-- project from 'boardBindings'.
data BoardAction
  = NextCard
  | PreviousCard
  | KillWorking
  | PreviousColumn
  | NextColumn
  | FirstItem
  | LastItem
  | OpenSearch
  | ShowFilter
  | ToggleEpic
  | ShowDetails
  | DismissOrClose
  | ReviewSelection
  | SolveSelection
  | AutoSolveSelection
  | ShowProcesses
  | ShowIncidents
  | RefreshAll
  | ToggleApproval
  | ToggleDrainer
  | MergeDoneCard
  | ToggleSidebar
  | ShowSettings
  | ShowHelp
  | RepaintTerminal
  | QuitDashboard
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Everything the dashboard knows about one binding.
data KeyBinding = KeyBinding
  { -- | What the binding does.
    bindingAction :: BoardAction,
    -- | Every physical key that reaches 'bindingAction', in display order.
    -- The first is the one a notice names.
    bindingKeys :: [BindingKey],
    -- | Every scope the binding is live in.
    bindingScopes :: [BindingScope],
    -- | A mouse gesture that does the same thing, named beside the keys in
    -- the help overlay exactly as §7's key column carries it.
    bindingGesture :: Maybe Text,
    -- | The footer hint line's short label.
    bindingLabel :: Text,
    -- | The help overlay's longer description.
    bindingDescription :: Text,
    -- | The action §7's table states for this binding, verbatim. §7 is the
    -- contract and this is the copy a test holds it to, so an edit to
    -- either without the other fails the suite.
    bindingContract :: Text
  }
  deriving stock (Eq, Show)

-- | The table. Total in 'BoardAction', so an action cannot be added without
-- its keys, scopes, and both pieces of user-visible text being decided in the
-- same place.
binding :: BoardAction -> KeyBinding
binding action = case action of
  NextCard ->
    KeyBinding action [key 'j', plain Vty.KDown] [BoardScope] Nothing "next" "next card"
      "Select next visible card or collapsed epic"
  PreviousCard ->
    KeyBinding action [key 'k', plain Vty.KUp] [BoardScope] Nothing "previous" "previous card"
      "Select previous visible card or collapsed epic"
  KillWorking ->
    KeyBinding action [key 'x'] [BoardScope, DetailsScope] Nothing "kill" "kill selected working process tree"
      "Kill the selected working issue/PR process group and its child processes"
  PreviousColumn ->
    KeyBinding action [key 'h', plain Vty.KLeft] [BoardScope] Nothing "prev column" "previous column"
      "Select previous column"
  NextColumn ->
    KeyBinding action [key 'l', plain Vty.KRight] [BoardScope] Nothing "next column" "next column"
      "Select next column"
  FirstItem ->
    KeyBinding action [key 'g'] [BoardScope] Nothing "first" "first visible item in the column"
      "Select first visible item in the column"
  LastItem ->
    KeyBinding action [key 'G'] [BoardScope] Nothing "last" "last visible item in the column"
      "Select last visible item in the column"
  -- Only the key that opens search is a binding. Everything typed into an
  -- open box is decoded by "Kanban.UI.Search" ahead of this table, because a
  -- printable key there is text rather than a shortcut.
  OpenSearch ->
    KeyBinding action [key 's'] [BoardScope] Nothing "search" "search a column; h/l type into the query, Left/Right move the search"
      "Open the card search on the Issues column; printable keys including h and l filter it, Left and Right move it to another column, F focuses the filter panel, and Esc or s closes it"
  -- Only the key that shows the panel is a binding. Everything typed into a
  -- focused panel is decoded by "Kanban.UI.Filter" ahead of this table,
  -- because `d` there restores the defaults rather than toggling the drainer.
  ShowFilter ->
    KeyBinding action [key 'F'] [BoardScope] Nothing "filter" "filter cards; j/k move, Left/Right change group, space toggles, d defaults"
      "Show or hide the card filter panel; j/k or Up/Down move between boxes, Left/Right between groups, Space toggles the focused box, d restores the defaults, s focuses the card search, and F or Esc hides the panel leaving the criteria unchanged"
  ToggleEpic ->
    KeyBinding action [key 'e'] [BoardScope] Nothing "epic" "expand / collapse focused epic"
      "Expand or collapse the focused epic"
  ShowDetails ->
    KeyBinding action [plain Vty.KEnter] [BoardScope] Nothing "details" "details"
      "Open the selected card's details overlay"
  DismissOrClose ->
    KeyBinding action [plain Vty.KEsc] [BoardScope, DetailsScope, HelpScope] Nothing "close" "close overlay or dismiss a notice"
      "Close an overlay or dismiss a transient error"
  ReviewSelection ->
    KeyBinding action [key 'r'] [BoardScope, DetailsScope] Nothing "review/revise" "review/revise/repair selected issue or PR"
      "Start or reopen the selected issue's review session, or the selected PR's review, rereview, revise, or repair session; a no-op on a collapsed or childless epic header"
  SolveSelection ->
    KeyBinding action [key 'S'] [BoardScope, DetailsScope] Nothing "solve" "solve selected issue (choose model brand)"
      "Choose Codex or Claude and start/reopen an issue solve through PR creation"
  AutoSolveSelection ->
    KeyBinding action [key 'A'] [BoardScope, DetailsScope] Nothing "autosolve" "autosolve selected issue (choose model brand)"
      "Choose Codex or Claude and start/reopen the full autosolve review loop"
  ShowProcesses ->
    KeyBinding action [key 'p'] [BoardScope] Nothing "processes" "processes and agent sessions"
      "Open the process/session inspector; Enter opens a session and `x` kills its live process tree"
  ShowIncidents ->
    KeyBinding action [key 'i'] [BoardScope] Nothing "attention" "everything needing attention; Enter goes to its work"
      "Open the incidents panel listing everything needing attention; Enter goes to that work"
  RefreshAll ->
    KeyBinding action [key 'u'] [BoardScope] (Just "click") "update" "update board and both usage providers"
      "Update GitHub board data and both usage providers"
  -- Lowercase, because uppercase `A` is autosolve and the two are unrelated.
  -- A live search still types this letter into its query: `searchInput`
  -- decodes a printable key ahead of this table, exactly as it does for the
  -- other lowercase bindings.
  ToggleApproval ->
    KeyBinding action [key 'a'] [BoardScope] (Just "click") "approvals" "start or stop issue approval service"
      "Start or stop the service-managed issue approval service"
  ToggleDrainer ->
    KeyBinding action [key 'd'] [BoardScope] (Just "click") "drainer" "start or stop PR drainer"
      "Start or stop the service-managed PR drainer"
  MergeDoneCard ->
    KeyBinding action [key 'm'] [BoardScope, DetailsScope] Nothing "merge" "merge the selected approved PR in Done"
      "Merge the selected approved pull request in Done through the PR drainer's own single-pull-request path"
  ToggleSidebar ->
    KeyBinding action [key 'c'] [BoardScope] Nothing "sidebar" "collapse / expand sidebar"
      "Collapse or expand the usage sidebar"
  ShowSettings ->
    KeyBinding action [key 'o'] [BoardScope] Nothing "options" "settings"
      "Open settings: `1`/`2`/`3` select chat-output verbosity; `j`/`k` or Up/Down select a roster assignment; `h`/`l` or Left/Right cycle its model; `[`/`]` cycle its effort; `d` resets the selected assignment, or repairs an unusable roster with defaults; click selects, the wheel scrolls, and Esc closes"
  ShowHelp ->
    KeyBinding action [key '?'] [BoardScope] Nothing "help" "this help overlay"
      "Open a help overlay listing all bindings"
  RepaintTerminal ->
    KeyBinding action [chord (Vty.KChar 'l') [Vty.MCtrl]] [BoardScope] Nothing "repaint" "repaint"
      "Force a terminal repaint without a network request"
  QuitDashboard ->
    KeyBinding action [key 'q', chord (Vty.KChar 'c') [Vty.MCtrl]] [BoardScope, DetailsScope, HelpScope] Nothing "quit" "quit"
      "Quit and restore the terminal"
  where
    key character = chord (Vty.KChar character) []
    plain named = chord named []

-- | The whole table, in 'BoardAction' order.
boardBindings :: [KeyBinding]
boardBindings = map binding [minBound .. maxBound]

-- | The bindings live in one scope, in table order.
scopeBindings :: BindingScope -> [KeyBinding]
scopeBindings scope = filter (elem scope . (.bindingScopes)) boardBindings

-- | The action a key press means in a scope, or 'Nothing' when the table
-- claims nothing there and the press belongs to whatever comes next.
--
-- Callers must consult this only after the handlers that outrank the base
-- board — application events, an overlay's own input, and mouse dispatch —
-- have had their existing precedence.
boardAction :: BindingScope -> Vty.Event -> Maybe BoardAction
boardAction scope event = do
  pressed <- eventBindingKey event
  (.bindingAction) <$> find (claims pressed) boardBindings
  where
    claims pressed candidate =
      scope `elem` candidate.bindingScopes && pressed `elem` candidate.bindingKeys

-- | One row of the help overlay. Board bindings project into one; an overlay
-- that keeps its own input decoder supplies its rows from beside that
-- decoder, so the overlay never becomes a second definition site for a key.
-- A row with no keys at all is mouse prose.
data HelpEntry = HelpEntry
  { helpEntryKeys :: [BindingKey],
    helpEntryGesture :: Maybe Text,
    helpEntryDescription :: Text,
    -- | The row §7 documents this binding in, verbatim, or 'Nothing' for a
    -- row §7 does not carry at all. §7's wording is the contract and the
    -- description above is its cheat-sheet short form, so the two are
    -- deliberately not the same text; carrying the contract here is what
    -- lets a test compare §7's whole inventory — keys /and/ actions —
    -- against this table instead of only its keys.
    helpEntryContract :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | A binding's help row.
bindingHelpEntry :: KeyBinding -> HelpEntry
bindingHelpEntry candidate =
  HelpEntry
    candidate.bindingKeys
    candidate.bindingGesture
    candidate.bindingDescription
    (Just candidate.bindingContract)

-- | A help row for a mouse gesture that no key binding covers.
gestureHelpEntry :: Text -> Text -> HelpEntry
gestureHelpEntry gesture description = HelpEntry [] (Just gesture) description Nothing

-- | Render help rows with their key columns aligned against each other. The
-- width comes from the rows themselves, so a longer key name cannot silently
-- run into its description.
helpRows :: [HelpEntry] -> [Text]
helpRows entries = map row entries
  where
    column = maximum (1 : map (Text.length . helpEntryKeyText) entries)
    row entry =
      let keys = helpEntryKeyText entry
       in keys <> Text.replicate (column + 2 - Text.length keys) " " <> entry.helpEntryDescription

-- | A help row's key column: every key spelled out, then the mouse gesture
-- that shares the binding, if any.
helpEntryKeyText :: HelpEntry -> Text
helpEntryKeyText entry =
  Text.intercalate " / " (map helpKeyName entry.helpEntryKeys <> maybe [] pure entry.helpEntryGesture)

-- | A binding's chip on the footer hint line.
footerHint :: KeyBinding -> Text
footerHint candidate = footerKeyText candidate.bindingKeys <> " " <> candidate.bindingLabel

-- | How the footer names a set of keys: compact, with arrow glyphs, because
-- the hint line is a single row clipped at the terminal width.
footerKeyText :: [BindingKey] -> Text
footerKeyText = Text.intercalate "/" . map footerKeyName

-- | How the help overlay names a set of keys: spelled out, because the
-- overlay has the room and is the complete list.
helpKeyText :: [BindingKey] -> Text
helpKeyText = Text.intercalate " / " . map helpKeyName

-- | The key a notice names for an action: its first, spelled the way the
-- help overlay spells it.
actionKeyText :: BoardAction -> Text
actionKeyText = helpKeyText . take 1 . (.bindingKeys) . binding

footerKeyName :: BindingKey -> Text
footerKeyName pressed = modifierPrefix pressed <> case pressed.bindingKeyKey of
  Vty.KUp -> "↑"
  Vty.KDown -> "↓"
  Vty.KLeft -> "←"
  Vty.KRight -> "→"
  Vty.KEnter -> "enter"
  Vty.KEsc -> "esc"
  other -> plainKeyName pressed other

helpKeyName :: BindingKey -> Text
helpKeyName pressed = modifierPrefix pressed <> case pressed.bindingKeyKey of
  Vty.KUp -> "Up"
  Vty.KDown -> "Down"
  Vty.KLeft -> "Left"
  Vty.KRight -> "Right"
  Vty.KEnter -> "Enter"
  Vty.KEsc -> "Esc"
  other -> plainKeyName pressed other

-- | The part of a key's name the two styles agree on. A modified character
-- is upper-cased — @Ctrl-L@, not @Ctrl-l@ — while an unmodified one keeps
-- its case, which is the whole difference between @g@ and @G@. Keys the
-- table does not use fall back to their Vty name rather than being silently
-- rendered as something else.
plainKeyName :: BindingKey -> Vty.Key -> Text
plainKeyName pressed = \case
  Vty.KChar '\t' -> "Tab"
  Vty.KChar character
    | null pressed.bindingKeyModifiers -> Text.singleton character
    | otherwise -> Text.singleton (toUpper character)
  other -> Text.pack (show other)

modifierPrefix :: BindingKey -> Text
modifierPrefix pressed = Text.concat (map named pressed.bindingKeyModifiers)
  where
    named = \case
      Vty.MShift -> "Shift-"
      Vty.MCtrl -> "Ctrl-"
      Vty.MMeta -> "Meta-"
      Vty.MAlt -> "Alt-"
