-- | The settings overlay's own model: the roster rows it draws, the total
-- input its keys and mouse decode to, and the pure transition each one earns
-- (@docs\/model_settings_design.md@, MODEL-5).
--
-- Two layers, deliberately. 'settingsInput' answers a total 'SettingsInput'
-- for every event the overlay can receive, and 'settingsOutcome' decides what
-- that input amounts to without performing any of it: a new focused cell, a
-- viewport scroll, a /proposed/ roster the shell must persist, whether that
-- write earns the @issue_gate@ caution, or a refusal naming why nothing was
-- written. Nothing here writes a file, because a value the operator can see
-- but that never reached disk would vanish at the next restart — so the
-- 'EventM' shell calls 'Kanban.Models.saveModelRoster' and hands the result
-- back to 'applyRosterWrite', which is the only thing that moves
-- 'appModelRoster'. Focus movement, clicks, and the wheel need no write at
-- all and are decided entirely here.
--
-- Row order follows the schema rather than the assignment map: roles in
-- 'allRoles' order, providers in the loaded roster's own @agents@ file order,
-- and a row only where 'Kanban.Models.assignmentFor' resolves the cell. A
-- 'Data.Map.Strict.toList' over the assignments would impose compiled key
-- order instead and quietly reorder a custom @agents@ list.
module Kanban.UI.Settings
  ( -- * The rows the overlay draws
    RosterRow (..),
    rosterRows,
    settingsRosterRows,
    rosterRowCell,
    rosterRowText,
    resolvedSettingsFocus,

    -- * The interaction
    SettingsInput (..),
    SettingsOutcome (..),
    RosterWrite (..),
    settingsInput,
    settingsOutcome,

    -- * What the shell applies
    applyRosterWrite,
    openSettings,

    -- * The wording the screen and its notices share
    issueGateCaution,
    noProvidersMessage,
    operatingModeLine,
    rosterRecoveryHint,
    settingsFooterHints,
  )
where

import Brick (BrickEvent (..))
import Data.List (elemIndex)
import qualified Data.Map.Strict as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Graphics.Vty as Vty
import Kanban.Models
  ( Assignment (..),
    ModelRoster (..),
    OperatingMode,
    ProviderCatalog (..),
    ProviderName (..),
    RoleName (..),
    RosterLoadError,
    allRoles,
    assignmentFor,
    defaultRoster,
    operatingModeLabel,
    providerKey,
    roleKey,
  )
import Kanban.Settings (ChatVerbosity (..))
import Kanban.UI.Keys (BoardAction (..), binding, footerHint)
import Kanban.UI.Types
import Kanban.UI.Util (noticeCleared, noticeSet)

-- | One @(role, provider)@ assignment as the screen shows it.
--
-- 'rosterRowIsDefault' compares the /complete/ 'Assignment' — model, effort,
-- and display — against the compiled default, so a cell carrying a hand-written
-- display label reads as overridden even when its wire values match. That is
-- the honest answer: the display is what every other surface names the
-- assignment by.
data RosterRow = RosterRow
  { rosterRowRole :: RoleName,
    rosterRowProvider :: ProviderName,
    rosterRowAssignment :: Assignment,
    rosterRowIsDefault :: Bool
  }
  deriving stock (Eq, Show)

-- | The rows a loaded roster draws, role-major with providers in the file's
-- own @agents@ order.
--
-- Resolution goes through 'assignmentFor' rather than a map traversal, so a
-- provider the file does not load, a role that cannot run on it, and a cell
-- the roster simply does not carry all drop out together — and none of them
-- is ever filled in from the compiled defaults.
rosterRows :: ModelRoster -> [RosterRow]
rosterRows roster =
  [ RosterRow role provider assignment (compiledAssignment role provider == Just assignment)
  | role <- allRoles,
    provider <- roster.rosterAgents,
    Right assignment <- [assignmentFor roster role provider]
  ]

-- | The rows for the startup load as it stands. An unusable roster draws no
-- rows at all: what replaces them is its defect, not a fabricated default set.
settingsRosterRows :: Either RosterLoadError ModelRoster -> [RosterRow]
settingsRosterRows = either (const []) rosterRows

rosterRowCell :: RosterRow -> (RoleName, ProviderName)
rosterRowCell row = (row.rosterRowRole, row.rosterRowProvider)

-- | One row's line, in fixed columns so the marker column lines up.
--
-- Not padded to the panel's width and not truncated here: the panel measures
-- its own interior at render time and elides there, because a user-supplied
-- model ID in @models.toml@ can be longer than anything this module knows.
rosterRowText :: RosterRow -> Text
rosterRowText row =
  Text.justifyLeft 15 ' ' (roleKey row.rosterRowRole)
    <> Text.justifyLeft 8 ' ' (providerKey row.rosterRowProvider)
    <> Text.justifyLeft 33 ' ' (row.rosterRowAssignment.assignmentModel <> " · " <> row.rosterRowAssignment.assignmentEffort)
    <> (if row.rosterRowIsDefault then "default" else "override")

-- | The focused cell, resolved against the rows actually drawn.
--
-- Total in both arguments: an unusable roster and a valid zero-agent one both
-- have no focused row at all, and a remembered cell the roster no longer
-- carries falls back to the first row rather than focusing nothing.
resolvedSettingsFocus ::
  Either RosterLoadError ModelRoster ->
  Maybe (RoleName, ProviderName) ->
  Maybe (RoleName, ProviderName)
resolvedSettingsFocus roster requested = case requested of
  Just cell | cell `elem` cells -> Just cell
  _ -> listToMaybe cells
  where
    cells = map rosterRowCell (settingsRosterRows roster)

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

-- | What one event means to the open settings overlay.
--
-- Total rather than a 'Maybe': while this overlay is up it answers every
-- event it receives, and 'SettingsIgnoreEvent' is that answer for the ones it
-- has no meaning for. A key given a meaning here cannot reach the screen
-- without 'settingsOutcome' deciding what it does.
data SettingsInput
  = -- | One row down or up the list, clamped at both ends.
    SettingsMoveRow Int
  | -- | The wheel: the same clamped movement, and the viewport with it.
    SettingsScrollRows Int
  | -- | A left click on a drawn row, named by the cell it was drawn for.
    SettingsFocusRow RoleName ProviderName
  | -- | The previous or next model in this provider's declared order.
    SettingsCycleModel Int
  | -- | The previous or next effort in this provider's declared vocabulary.
    SettingsCycleEffort Int
  | -- | Restore the focused cell's compiled default, or repair an unusable
    -- roster with the complete compiled defaults.
    SettingsResetAssignment
  | SettingsChooseVerbosity ChatVerbosity
  | SettingsCloseOverlay
  | SettingsIgnoreEvent
  deriving stock (Eq, Show)

-- | The overlay's key and mouse policy.
--
-- @1@, @2@, and @3@ are decoded before anything roster-shaped, so the chat
-- verbosity radio keeps working whichever row is focused. A wheel resolves to
-- a scroll wherever it lands: the rows are clickable, so a wheel over one is
-- reported against the row rather than against the panel around it.
settingsInput :: BrickEvent Name AppEvent -> SettingsInput
settingsInput event = case event of
  VtyEvent (Vty.EvKey key modifiers)
    | any (`elem` modifiers) [Vty.MCtrl, Vty.MMeta, Vty.MAlt] -> SettingsIgnoreEvent
    | otherwise -> case key of
        Vty.KChar '1' -> SettingsChooseVerbosity CompactChat
        Vty.KChar '2' -> SettingsChooseVerbosity StandardChat
        Vty.KChar '3' -> SettingsChooseVerbosity FullChat
        Vty.KChar 'j' -> SettingsMoveRow 1
        Vty.KChar 'k' -> SettingsMoveRow (-1)
        Vty.KDown -> SettingsMoveRow 1
        Vty.KUp -> SettingsMoveRow (-1)
        Vty.KChar 'h' -> SettingsCycleModel (-1)
        Vty.KChar 'l' -> SettingsCycleModel 1
        Vty.KLeft -> SettingsCycleModel (-1)
        Vty.KRight -> SettingsCycleModel 1
        Vty.KChar '[' -> SettingsCycleEffort (-1)
        Vty.KChar ']' -> SettingsCycleEffort 1
        Vty.KChar 'd' -> SettingsResetAssignment
        Vty.KEsc -> SettingsCloseOverlay
        _ -> SettingsIgnoreEvent
  MouseDown target Vty.BScrollUp _ _
    | overSettings target -> SettingsScrollRows (-settingsWheelRows)
  MouseDown target Vty.BScrollDown _ _
    | overSettings target -> SettingsScrollRows settingsWheelRows
  MouseDown (SettingsRosterTarget role provider) Vty.BLeft _ _ -> SettingsFocusRow role provider
  _ -> SettingsIgnoreEvent

-- | Whether a press landed on this overlay at all: the panel, the viewport
-- inside it, or one of the rows. The board behind is still drawn and its
-- extents are still registered, so a wheel out there is somebody else's — and
-- while this overlay is up, nobody's.
overSettings :: Name -> Bool
overSettings SettingsPanel = True
overSettings SettingsViewport = True
overSettings (SettingsRosterTarget _ _) = True
overSettings _ = False

-- | How far one wheel notch moves the list, matching every other overlay.
settingsWheelRows :: Int
settingsWheelRows = 3

-- ---------------------------------------------------------------------------
-- Outcome
-- ---------------------------------------------------------------------------

-- | A roster the shell must persist before the screen may show it, together
-- with what a successful save earns.
data RosterWrite = RosterWrite
  { rosterWriteRoster :: ModelRoster,
    -- | The row focused after a successful save. The edited cell for an
    -- ordinary edit; the first row of the compiled defaults for a recovery,
    -- which had no focused row to keep.
    rosterWriteFocus :: Maybe (RoleName, ProviderName),
    -- | Whether this write changed what the canonical issue gate runs on.
    rosterWriteCaution :: Bool
  }
  deriving stock (Eq, Show)

-- | What one 'SettingsInput' amounts to, decided without touching the file.
data SettingsOutcome
  = -- | Nothing happens, and in particular nothing is written.
    SettingsUnchanged
  | SettingsClosed
  | -- | The focused cell after the input, and how far to scroll the viewport
    -- with it — zero for everything but the wheel.
    SettingsRefocused (Maybe (RoleName, ProviderName)) Int
  | SettingsVerbosityChosen ChatVerbosity
  | SettingsRosterWrite RosterWrite
  | -- | Refused before any write, with the diagnostic that says why.
    SettingsRefused Text
  deriving stock (Eq, Show)

-- | The whole transition, over the startup load and the remembered focus.
--
-- Total in 'SettingsInput': a new input cannot be decoded above without an arm
-- here deciding what it does.
settingsOutcome ::
  SettingsInput ->
  Either RosterLoadError ModelRoster ->
  Maybe (RoleName, ProviderName) ->
  SettingsOutcome
settingsOutcome input roster requested = case input of
  SettingsIgnoreEvent -> SettingsUnchanged
  SettingsCloseOverlay -> SettingsClosed
  SettingsChooseVerbosity verbosity -> SettingsVerbosityChosen verbosity
  SettingsMoveRow amount -> SettingsRefocused (movedFocus amount) 0
  SettingsScrollRows amount -> SettingsRefocused (movedFocus amount) amount
  SettingsFocusRow role provider
    | (role, provider) `elem` cells -> SettingsRefocused (Just (role, provider)) 0
    | otherwise -> SettingsUnchanged
  SettingsCycleModel delta -> cycled (\catalog assignment -> (cycleIn catalog.catalogModels delta assignment.assignmentModel, assignment.assignmentEffort))
  SettingsCycleEffort delta -> cycled (\catalog assignment -> (assignment.assignmentModel, cycleIn catalog.catalogEfforts delta assignment.assignmentEffort))
  SettingsResetAssignment -> reset
  where
    cells = map rosterRowCell (settingsRosterRows roster)
    focus = resolvedSettingsFocus roster requested

    movedFocus amount = do
      cell <- focus
      index <- elemIndex cell cells
      indexed (max 0 (min (length cells - 1) (index + amount)))

    indexed index = case drop index cells of
      cell : _ -> Just cell
      [] -> Nothing

    -- An edit is only ever the focused cell of a loaded roster. Both halves
    -- of the cell are looked up rather than assumed: a roster built in
    -- process can be missing either, and inventing one would be exactly the
    -- compiled-default substitution D-3 forbids.
    cycled retune = case (roster, focus) of
      (Right current, Just cell@(role, provider)) ->
        case (Map.lookup provider current.rosterProviders, Map.lookup cell current.rosterAssignments) of
          (Just catalog, Just assignment)
            | (model, effort) <- retune catalog assignment,
              (model, effort) /= (assignment.assignmentModel, assignment.assignmentEffort) ->
                writing current cell (tunedAssignment role provider model effort) role
          _ -> SettingsUnchanged
      _ -> SettingsUnchanged

    reset = case roster of
      -- The one recovery: an unusable file has no focused cell to reset, so
      -- @d@ replaces the whole roster. Every compiled @issue_gate@ cell is
      -- established by that write, which is why it cautions like an edit to
      -- one.
      Left _ ->
        SettingsRosterWrite
          RosterWrite
            { rosterWriteRoster = defaultRoster,
              rosterWriteFocus = listToMaybe (map rosterRowCell (rosterRows defaultRoster)),
              rosterWriteCaution = True
            }
      Right current -> case focus of
        Nothing -> SettingsUnchanged
        Just cell@(role, provider) ->
          case (compiledAssignment role provider, Map.lookup provider current.rosterProviders, Map.lookup cell current.rosterAssignments) of
            (Just compiled, Just catalog, Just assignment)
              | not (null (undeclared compiled catalog)) ->
                  SettingsRefused (undeclaredDefaultMessage role provider compiled catalog)
              | compiled == assignment -> SettingsUnchanged
              | otherwise -> writing current cell compiled role
            _ -> SettingsUnchanged

    writing current cell assignment role =
      SettingsRosterWrite
        RosterWrite
          { rosterWriteRoster = current {rosterAssignments = Map.insert cell assignment current.rosterAssignments},
            rosterWriteFocus = Just cell,
            rosterWriteCaution = role == IssueGateRole
          }

-- | The assignment an edited model\/effort pair earns, display included.
--
-- Cycling back onto the compiled default's exact pair restores the /complete/
-- compiled assignment, curated display and all, which is also what makes the
-- row read as default again. Anything else names what argv actually carries:
-- a curated label kept over an edited pair would have every surface that
-- displays this assignment naming a model the provider is not running on.
-- Authoring a custom label stays a file edit.
tunedAssignment :: RoleName -> ProviderName -> Text -> Text -> Assignment
tunedAssignment role provider model effort = case compiledAssignment role provider of
  Just compiled
    | compiled.assignmentModel == model,
      compiled.assignmentEffort == effort ->
        compiled
  _ -> Assignment model effort (model <> " " <> effort)

-- | The next value after @value@, wrapping at both ends. Identity for a value
-- the list does not carry, which a validated roster never produces.
cycleIn :: [Text] -> Int -> Text -> Text
cycleIn values delta value = case elemIndex value values of
  Nothing -> value
  Just index -> case drop ((index + delta) `mod` length values) values of
    next : _ -> next
    [] -> value

-- | The compiled default for a cell, or 'Nothing' where no build has one.
compiledAssignment :: RoleName -> ProviderName -> Maybe Assignment
compiledAssignment role provider = Map.lookup (role, provider) defaultRoster.rosterAssignments

-- | Which halves of a compiled default the provider's own catalog does not
-- declare. Empty when the default can be restored as it stands.
undeclared :: Assignment -> ProviderCatalog -> [Text]
undeclared compiled catalog =
  ["model " <> compiled.assignmentModel | compiled.assignmentModel `notElem` catalog.catalogModels]
    <> ["effort " <> compiled.assignmentEffort | compiled.assignmentEffort `notElem` catalog.catalogEfforts]

-- | Why a reset wrote nothing: the catalog the operator edited no longer
-- declares what the compiled default names, so restoring it would produce a
-- roster the loader refuses.
undeclaredDefaultMessage :: RoleName -> ProviderName -> Assignment -> ProviderCatalog -> Text
undeclaredDefaultMessage role provider compiled catalog =
  "model roster cannot restore "
    <> roleKey role
    <> "."
    <> providerKey provider
    <> ": provider "
    <> providerKey provider
    <> " declares no "
    <> Text.intercalate " and no " (undeclared compiled catalog)
    <> ", so the compiled default "
    <> compiled.assignmentModel
    <> " "
    <> compiled.assignmentEffort
    <> " cannot be written; declare it in models.toml first"

-- | The one thing that moves 'appModelRoster' after startup, and only on a
-- save that succeeded.
--
-- Through 'Kanban.UI.Types.withModelRoster', so the retained operating mode
-- moves with it. Only one write can change the loaded provider set at all —
-- @d@ replacing an unusable file with the compiled defaults, which takes a
-- no-agent dashboard to dual — because @agents@ is not editable from this
-- screen (D-10). That one is enough: a screen still naming no-agent over the
-- defaults it just wrote would be showing the file it replaced.
--
-- A failed write leaves the roster, the focused row, and therefore every
-- displayed assignment exactly as they were, and reports the diagnostic
-- 'Kanban.Models.saveModelRoster' returned: a screen showing a value that
-- never reached the file would be a process spawning on something that
-- disappears at the next restart. A successful write shows the caution when
-- it earned one, and otherwise clears the notice — including a caution left
-- over from an earlier edit, which the newer edit does not stand behind.
applyRosterWrite :: Either Text () -> RosterWrite -> AppState -> AppState
applyRosterWrite (Left message) _ state = noticeSet message state
applyRosterWrite (Right ()) write state =
  (if write.rosterWriteCaution then noticeSet issueGateCaution else noticeCleared)
    (withModelRoster (Right write.rosterWriteRoster) state) {appSettingsFocus = write.rosterWriteFocus}

-- | Show the settings overlay, focused on its first roster row.
openSettings :: AppState -> AppState
openSettings state =
  noticeCleared
    state
      { appOverlay = Just SettingsOverlay,
        appSettingsFocus = listToMaybe (map rosterRowCell (settingsRosterRows state.appModelRoster))
      }

-- ---------------------------------------------------------------------------
-- Wording
-- ---------------------------------------------------------------------------

-- | What a saved @issue_gate@ change means for work already approved.
--
-- Conservative on purpose, and unconditional: @tools/approve_issues.py@ gives
-- @APPROVE_ISSUES_*@ environment values precedence over the roster and accepts
-- a set of historical reviewer models, so a changed cell /may/ leave approvals
-- stale rather than certainly doing so. Nothing here recomputes that backend's
-- effective reviewer, and nothing here reconciles anything.
issueGateCaution :: Text
issueGateCaution =
  "Changing `issue_gate` may make existing issue approvals stale; reconciliation can request rereview. \
  \Environment overrides or accepted historical reviewer routes may keep some approvals current."

-- | The read-only line naming the operating mode the roster in force derives
-- (D-8).
--
-- Shown and never set, and it says where it is set instead: the mode follows
-- the @agents@ list, which is a deliberate file edit (D-10) and the one part
-- of the roster this screen does not offer a key for. Short enough for the
-- panel's 64-cell interior at every one of the three labels.
operatingModeLine :: OperatingMode -> Text
operatingModeLine mode = "Operating mode: " <> operatingModeLabel mode <> " · set by agents in models.toml"

-- | A valid roster that loads no provider at all. There is nothing to focus
-- and nothing to edit from this screen — @agents@ is a file edit — so the
-- panel says so rather than drawing compiled rows nothing would run on.
noProvidersMessage :: Text
noProvidersMessage = "No providers loaded"

-- | What @d@ does to an unusable roster, said before the key is pressed.
--
-- 'Kanban.Models.saveModelRoster' renames over the existing path and keeps no
-- backup, so a merely mistyped @models.toml@ — custom @agents@, catalogs, and
-- assignments included — is gone after one press.
rosterRecoveryHint :: Text
rosterRecoveryHint =
  "Press d to replace the file's contents with the compiled defaults. \
  \The current models.toml, including any custom agents, catalogs, and assignments, is not kept."

-- | The chips the base footer shows while this overlay is open, declared
-- here beside 'settingsInput' and 'settingsOutcome', which answer these keys.
--
-- A cheat sheet rather than the §7 contract, exactly as every other panel's
-- is: §7 documents these keys inside the @o@ row's description and gains no
-- rows of its own from them, so nothing here reaches 'helpLines' or the
-- inventory 'Spec.UI.Keys' holds §7 to.
settingsFooterHints :: [Text]
settingsFooterHints =
  [ "j/k rows",
    "h/l model",
    "[/] effort",
    "d reset",
    "1/2/3 chat",
    -- The one chip on this row that is not this overlay's own key. @f@ is
    -- declared in "Kanban.UI.Keys" and answered by the shared arm ahead of
    -- 'settingsInput', so the row projects that declaration rather than
    -- spelling the letter out a second time here.
    footerHint (binding ToggleFullscreen),
    "Esc close"
  ]
