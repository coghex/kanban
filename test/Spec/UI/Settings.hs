-- | The settings overlay's roster editor (MODEL-5): the rows it draws, the
-- keys and mouse it decodes, and what each one does to the roster.
--
-- Everything here runs without a terminal, a file, or a provider. That is the
-- whole point of the two-layer shape "Kanban.UI.Settings" is built in: the
-- decoder and the transition are pure, so the interactions this screen has to
-- get right — clamping, wrapping, truthful displays, refusing to write, and
-- rolling a failed write back — are exercised as values rather than through a
-- live dashboard. What the layer cannot decide for itself, the ordering of the
-- save against the in-memory commit, is proved end to end in
-- "Spec.Agent.Roster".
module Spec.UI.Settings (spec) where

import Brick (BrickEvent (..), Location (..))
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text
import qualified Graphics.Vty as Vty
import Kanban.Models
  ( Assignment (..),
    ModelRoster (..),
    ProviderCatalog (..),
    ProviderName (..),
    RoleName (..),
    RosterDefect (..),
    RosterFailure (..),
    RosterLoadError (..),
    OperatingMode (..),
    allRoles,
    defaultRoster,
    operatingModeFor,
    rosterErrorMessage,
  )
import Kanban.Settings (ChatVerbosity (..))
import Kanban.UI.Overlay (drawOverlay)
import Kanban.UI.Settings
import Kanban.UI.Theme (themeFor)
import Kanban.UI.Types (AppEvent, AppState (..), Name (..), Overlay (..), withModelRoster)
import Kanban.UI.Util (shownNotice)
import Spec.Support.App (testAppState)
import Spec.Support.Fixtures (fixtureBoard, testOptions)
import Spec.Support.Render (renderWidgetLines)
import Spec.Support.Roster (noAgentRoster)
import Test.Hspec

spec :: Spec
spec = describe "the settings overlay's model roster" $ do
  describe "the rows it draws" $ do
    it "draws the compiled roster's thirteen applicable cells, role-major" $
      map rosterRowCell (rosterRows defaultRoster)
        `shouldBe` [ (SolveRole, CodexProvider),
                     (SolveRole, ClaudeProvider),
                     (PrReviewRole, CodexProvider),
                     (PrReviewRole, ClaudeProvider),
                     (PrReviseRole, CodexProvider),
                     (PrReviseRole, ClaudeProvider),
                     (IssueReviewRole, CodexProvider),
                     (IssueReviewRole, ClaudeProvider),
                     (IssueReviseRole, ClaudeProvider),
                     (IssueGateRole, CodexProvider),
                     (IssueGateRole, ClaudeProvider),
                     (DrainRereviewRole, CodexProvider),
                     (DrainRereviewRole, ClaudeProvider)
                   ]

    -- The file's own order, not the compiled one: a map traversal over the
    -- assignments would sort by the 'ProviderName' constructors and silently
    -- reorder an operator's `agents` list.
    it "keeps a custom agents order inside every role" $
      map rosterRowCell (rosterRows reversedAgentsRoster)
        `shouldBe` [ (SolveRole, ClaudeProvider),
                     (SolveRole, CodexProvider),
                     (PrReviewRole, ClaudeProvider),
                     (PrReviewRole, CodexProvider),
                     (PrReviseRole, ClaudeProvider),
                     (PrReviseRole, CodexProvider),
                     (IssueReviewRole, ClaudeProvider),
                     (IssueReviewRole, CodexProvider),
                     (IssueReviseRole, ClaudeProvider),
                     (IssueGateRole, ClaudeProvider),
                     (IssueGateRole, CodexProvider),
                     (DrainRereviewRole, ClaudeProvider),
                     (DrainRereviewRole, CodexProvider)
                   ]

    it "marks a row default only when the whole assignment matches, display included" $ do
      map (.rosterRowIsDefault) (rosterRows defaultRoster) `shouldBe` replicate 13 True
      map (.rosterRowIsDefault) (rosterRows relabelledRoster)
        `shouldBe` (False : replicate 12 True)

    it "draws no row for a valid zero-agent roster, and manufactures no default" $ do
      rosterRows noAgentRoster `shouldBe` []
      resolvedSettingsFocus (Right noAgentRoster) Nothing `shouldBe` Nothing

    it "draws no row for an unusable roster" $ do
      settingsRosterRows (Left unusableRoster) `shouldBe` []
      resolvedSettingsFocus (Left unusableRoster) (Just (SolveRole, CodexProvider)) `shouldBe` Nothing

    it "opens focused on the first row, and on nothing when there is none" $ do
      opened <- openSettings <$> testAppState (fixtureBoard [])
      opened.appOverlay `shouldBe` Just SettingsOverlay
      opened.appSettingsFocus `shouldBe` Just (SolveRole, CodexProvider)
      empty <- openSettings . withRoster (Right noAgentRoster) <$> testAppState (fixtureBoard [])
      empty.appSettingsFocus `shouldBe` Nothing
      broken <- openSettings . withRoster (Left unusableRoster) <$> testAppState (fixtureBoard [])
      broken.appSettingsFocus `shouldBe` Nothing

    -- The horizontal companion to the viewport: provider catalogs are
    -- user-supplied text, so a long model ID must be cut at the panel's
    -- interior rather than wrapped onto a second row or cropped in silence.
    it "elides a row too long for the panel instead of wrapping or overflowing it" $ do
      state <- withRoster (Right longModelRoster) <$> testAppState (fixtureBoard [])
      let rows = rosterSectionOf state
      -- One row per assignment: a wrapped row would show up as an extra line
      -- here, and a cropped one as a line wider than the panel's interior.
      length rows `shouldBe` length allRoles
      rows `shouldSatisfy` all (Data.Text.isInfixOf "…")
      map Data.Text.length rows `shouldSatisfy` all (<= settingsInteriorWidth)
      Data.Text.unwords rows `shouldSatisfy` (not . Data.Text.isInfixOf longModel)

    it "replaces the rows of an unusable roster with its defect and what d would do to the file" $ do
      state <- withRoster (Left unusableRoster) <$> testAppState (fixtureBoard [])
      let section = Data.Text.unwords (rosterSectionOf state)
      -- The whole defect, reassembled from however the panel wrapped it.
      Data.Text.words unusableRosterMessage `shouldSatisfy` all (`elem` Data.Text.words section)
      section `shouldSatisfy` Data.Text.isInfixOf "Press d to replace the file's contents"
      section `shouldSatisfy` Data.Text.isInfixOf "is not kept"
      -- And no fabricated rows beside it: not one compiled model is named.
      section `shouldSatisfy` (not . Data.Text.isInfixOf "gpt-5.4")
      section `shouldSatisfy` (not . Data.Text.isInfixOf "claude-")

  -- Requirement 5 of #486: the mode is shown here and set nowhere here. The
  -- line is read off the drawn panel rather than off 'operatingModeLine', so
  -- a line the overlay stopped drawing — or drew from a mode the roster does
  -- not derive — fails rather than passing on the wording alone.
  describe "the operating-mode line" $ do
    it "names the mode the roster in force derives, once per mode" $ do
      board <- testAppState (fixtureBoard [])
      let modeLineOf = filter (Data.Text.isPrefixOf "Operating mode:") . interiorOf
      modeLineOf (withRoster defaults board) `shouldBe` [operatingModeLine DualMode]
      modeLineOf (withRoster (Right claudeOnly) board) `shouldBe` [operatingModeLine (SingleAgentMode ClaudeProvider)]
      modeLineOf (withRoster (Right noAgentRoster) board) `shouldBe` [operatingModeLine NoAgentMode]
      -- A file that will not load derives no-agent too, and still shows its
      -- defect below the line rather than instead of it.
      modeLineOf (withRoster (Left unusableRoster) board) `shouldBe` [operatingModeLine NoAgentMode]

    it "names the mode and where it is set, inside the panel's interior" $ do
      map operatingModeLine [DualMode, SingleAgentMode CodexProvider, NoAgentMode]
        `shouldBe` [ "Operating mode: dual · set by agents in models.toml",
                     "Operating mode: single-agent · set by agents in models.toml",
                     "Operating mode: no-agent · set by agents in models.toml"
                   ]
      -- Every label fits unwrapped, which is what keeps it one row.
      map (Data.Text.length . operatingModeLine) [DualMode, SingleAgentMode CodexProvider, SingleAgentMode ClaudeProvider, NoAgentMode]
        `shouldSatisfy` all (<= settingsInteriorWidth)

    -- The screen shows it and offers no key for it: `agents` is a file edit
    -- (D-10), so no input this panel decodes can move the mode.
    it "offers no input that changes it" $ do
      let recovery = outcome SettingsResetAssignment (Left unusableRoster) Nothing
      map (\input -> fmap (.rosterAgents) (writtenRoster (outcome input defaults (Just (SolveRole, CodexProvider)))))
        [SettingsCycleModel 1, SettingsCycleModel (-1), SettingsCycleEffort 1, SettingsCycleEffort (-1)]
        `shouldSatisfy` all (`elem` [Nothing, Just defaultRoster.rosterAgents])
      -- The one write that does move the loaded set is the recovery, and it
      -- moves it to the compiled defaults, which is dual.
      fmap (operatingModeFor) (writtenRoster recovery) `shouldBe` Just DualMode

  describe "the keys it decodes" $ do
    it "moves a row on j, k, and the arrows" $ do
      map decoded [key (Vty.KChar 'j'), key Vty.KDown] `shouldBe` [SettingsMoveRow 1, SettingsMoveRow 1]
      map decoded [key (Vty.KChar 'k'), key Vty.KUp] `shouldBe` [SettingsMoveRow (-1), SettingsMoveRow (-1)]

    it "cycles a model on h, l, and the horizontal arrows, and an effort on the brackets" $ do
      map decoded [key (Vty.KChar 'h'), key Vty.KLeft] `shouldBe` [SettingsCycleModel (-1), SettingsCycleModel (-1)]
      map decoded [key (Vty.KChar 'l'), key Vty.KRight] `shouldBe` [SettingsCycleModel 1, SettingsCycleModel 1]
      map decoded [key (Vty.KChar '['), key (Vty.KChar ']')] `shouldBe` [SettingsCycleEffort (-1), SettingsCycleEffort 1]

    it "keeps the chat-verbosity digits, d, and Esc" $
      map decoded [key (Vty.KChar '1'), key (Vty.KChar '2'), key (Vty.KChar '3'), key (Vty.KChar 'd'), key Vty.KEsc]
        `shouldBe` [ SettingsChooseVerbosity CompactChat,
                     SettingsChooseVerbosity StandardChat,
                     SettingsChooseVerbosity FullChat,
                     SettingsResetAssignment,
                     SettingsCloseOverlay
                   ]

    it "ignores a modified chord and anything else it has no meaning for" $ do
      decoded (VtyEvent (Vty.EvKey (Vty.KChar 'l') [Vty.MCtrl])) `shouldBe` SettingsIgnoreEvent
      decoded (key (Vty.KChar 'z')) `shouldBe` SettingsIgnoreEvent
      decoded (key Vty.KEnter) `shouldBe` SettingsIgnoreEvent

    it "reads a wheel anywhere over the overlay as a scroll, and a left click as its own cell" $ do
      decoded (wheel Vty.BScrollDown SettingsPanel) `shouldBe` SettingsScrollRows 3
      decoded (wheel Vty.BScrollUp SettingsPanel) `shouldBe` SettingsScrollRows (-3)
      decoded (wheel Vty.BScrollDown SettingsViewport) `shouldBe` SettingsScrollRows 3
      -- A wheel over a clickable row is reported against the row, not the panel.
      decoded (wheel Vty.BScrollDown (SettingsRosterTarget PrReviewRole ClaudeProvider)) `shouldBe` SettingsScrollRows 3
      decoded (press (SettingsRosterTarget PrReviewRole ClaudeProvider))
        `shouldBe` SettingsFocusRow PrReviewRole ClaudeProvider
      -- The board behind the overlay keeps its own extents; a wheel out
      -- there is not this panel's to answer.
      decoded (wheel Vty.BScrollDown BoardViewport) `shouldBe` SettingsIgnoreEvent
      decoded (press BoardViewport) `shouldBe` SettingsIgnoreEvent

  describe "moving between rows" $ do
    it "clamps at both ends rather than wrapping" $ do
      outcome (SettingsMoveRow (-1)) defaults (Just (SolveRole, CodexProvider))
        `shouldBe` SettingsRefocused (Just (SolveRole, CodexProvider)) 0
      outcome (SettingsMoveRow 1) defaults (Just (DrainRereviewRole, ClaudeProvider))
        `shouldBe` SettingsRefocused (Just (DrainRereviewRole, ClaudeProvider)) 0
      outcome (SettingsMoveRow 1) defaults (Just (SolveRole, CodexProvider))
        `shouldBe` SettingsRefocused (Just (SolveRole, ClaudeProvider)) 0

    it "moves focus three rows and scrolls the viewport by the same three" $ do
      outcome (SettingsScrollRows 3) defaults (Just (SolveRole, CodexProvider))
        `shouldBe` SettingsRefocused (Just (PrReviewRole, ClaudeProvider)) 3
      outcome (SettingsScrollRows (-3)) defaults (Just (PrReviewRole, ClaudeProvider))
        `shouldBe` SettingsRefocused (Just (SolveRole, CodexProvider)) (-3)
      -- Clamped like the keys, and still scrolling: the list end is not a
      -- reason to leave the viewport where it was.
      outcome (SettingsScrollRows 3) defaults (Just (DrainRereviewRole, CodexProvider))
        `shouldBe` SettingsRefocused (Just (DrainRereviewRole, ClaudeProvider)) 3

    it "focuses exactly the clicked cell, and writes nothing" $ do
      outcome (SettingsFocusRow IssueGateRole ClaudeProvider) defaults (Just (SolveRole, CodexProvider))
        `shouldBe` SettingsRefocused (Just (IssueGateRole, ClaudeProvider)) 0
      -- A cell no row was drawn for: applicable, but this roster does not
      -- load it.
      outcome (SettingsFocusRow SolveRole CodexProvider) (Right claudeOnly) (Just (SolveRole, ClaudeProvider))
        `shouldBe` SettingsUnchanged

  describe "cycling a value" $ do
    it "wraps through the provider's declared model order in both directions" $ do
      cycledModel (SettingsCycleModel 1) (SolveRole, ClaudeProvider) `shouldBe` Just "claude-opus-5"
      cycledModel (SettingsCycleModel (-1)) (SolveRole, ClaudeProvider) `shouldBe` Just "claude-fable-5-1"
      cycledModel (SettingsCycleModel (-1)) (SolveRole, CodexProvider) `shouldBe` Just "gpt-6-astra"
      cycledModel (SettingsCycleModel 1) (IssueGateRole, CodexProvider) `shouldBe` Just "gpt-5.4"

    it "wraps through the declared effort vocabulary in both directions" $ do
      cycledEffort (SettingsCycleEffort 1) (SolveRole, CodexProvider) `shouldBe` Just "xhigh"
      cycledEffort (SettingsCycleEffort (-1)) (SolveRole, CodexProvider) `shouldBe` Just "medium"
      cycledEffort (SettingsCycleEffort 1) (IssueGateRole, ClaudeProvider) `shouldBe` Just "low"

    it "names the wire model and effort in the display, replacing a curated label" $
      editedAssignment (SettingsCycleModel 1) defaults (SolveRole, ClaudeProvider)
        `shouldBe` Just (Assignment "claude-opus-5" "high" "claude-opus-5 high")

    -- The other direction of the same rule: back on the compiled pair, the
    -- curated label and the default marker both return.
    it "restores the complete compiled assignment when the pair matches it again" $ do
      let edited = proposed (SettingsCycleModel 1) defaults (SolveRole, ClaudeProvider)
      editedAssignment (SettingsCycleModel (-1)) (Right edited) (SolveRole, ClaudeProvider)
        `shouldBe` Just (Assignment "claude-sonnet-5" "high" "Sonnet 5 high")
      proposed (SettingsCycleModel (-1)) (Right edited) (SolveRole, ClaudeProvider) `shouldBe` defaultRoster

    it "writes nothing when the catalog has nowhere else to cycle to" $ do
      outcome (SettingsCycleModel 1) (Right singleValueRoster) (Just (SolveRole, ClaudeProvider))
        `shouldBe` SettingsUnchanged
      outcome (SettingsCycleEffort 1) (Right singleValueRoster) (Just (SolveRole, ClaudeProvider))
        `shouldBe` SettingsUnchanged

    it "writes nothing at all when no row is focused" $ do
      outcome (SettingsCycleModel 1) (Right noAgentRoster) Nothing `shouldBe` SettingsUnchanged
      outcome (SettingsCycleEffort 1) (Left unusableRoster) Nothing `shouldBe` SettingsUnchanged

  describe "resetting" $ do
    it "restores only the focused cell, leaving agents, catalogs and every other assignment alone" $ do
      let edited = editedRoster
          restored = proposed SettingsResetAssignment (Right edited) (SolveRole, ClaudeProvider)
      restored `shouldBe` defaultRoster
      restored.rosterAgents `shouldBe` edited.rosterAgents
      restored.rosterProviders `shouldBe` edited.rosterProviders
      Map.keys (Map.filter id (Map.intersectionWith (/=) restored.rosterAssignments edited.rosterAssignments))
        `shouldBe` [(SolveRole, ClaudeProvider)]

    it "refuses without writing when the catalog no longer declares the compiled default" $
      case outcome SettingsResetAssignment (Right narrowedCodexRoster) (Just (SolveRole, CodexProvider)) of
        SettingsRefused message -> do
          message `shouldSatisfy` Data.Text.isInfixOf "solve.codex"
          message `shouldSatisfy` Data.Text.isInfixOf "model gpt-5.4"
        other -> expectationFailure ("expected a refusal and got " <> show other)

    it "writes nothing for a cell already at its compiled default" $
      outcome SettingsResetAssignment defaults (Just (SolveRole, CodexProvider)) `shouldBe` SettingsUnchanged

    it "writes nothing for a valid zero-agent roster, which has no focused assignment" $
      outcome SettingsResetAssignment (Right noAgentRoster) Nothing `shouldBe` SettingsUnchanged

    it "recovers an unusable roster with the complete compiled defaults, focused on its first row" $
      outcome SettingsResetAssignment (Left unusableRoster) Nothing
        `shouldBe` SettingsRosterWrite (RosterWrite defaultRoster (Just (SolveRole, CodexProvider)) True)

  describe "committing a write" $ do
    it "moves the roster and the focus only once the save succeeded" $ do
      state <- openSettings <$> testAppState (fixtureBoard [])
      let write = RosterWrite editedRoster (Just (SolveRole, ClaudeProvider)) False
          saved = applyRosterWrite (Right ()) write state
      saved.appModelRoster `shouldBe` Right editedRoster
      saved.appSettingsFocus `shouldBe` Just (SolveRole, ClaudeProvider)
      shownNotice saved `shouldBe` Nothing

    it "leaves the roster, the focus and every displayed assignment untouched on a failed save" $ do
      state <- openSettings <$> testAppState (fixtureBoard [])
      let write = RosterWrite editedRoster (Just (IssueGateRole, CodexProvider)) True
          failed = applyRosterWrite (Left "model roster write failed: disk full") write state
      failed.appModelRoster `shouldBe` state.appModelRoster
      failed.appSettingsFocus `shouldBe` state.appSettingsFocus
      settingsRosterRows failed.appModelRoster `shouldBe` settingsRosterRows state.appModelRoster
      -- The diagnostic, and only the diagnostic: nothing was changed, so
      -- there is nothing to caution about.
      shownNotice failed `shouldBe` Just "model roster write failed: disk full"

  describe "the issue_gate caution" $ do
    it "fires for an issue_gate edit and for the whole-roster recovery" $ do
      cautionFor (SettingsCycleModel 1) defaults (IssueGateRole, CodexProvider) `shouldBe` Just True
      cautionFor (SettingsCycleEffort 1) defaults (IssueGateRole, ClaudeProvider) `shouldBe` Just True
      cautionFor SettingsResetAssignment (Right editedGateRoster) (IssueGateRole, CodexProvider) `shouldBe` Just True
      case outcome SettingsResetAssignment (Left unusableRoster) Nothing of
        SettingsRosterWrite write -> write.rosterWriteCaution `shouldBe` True
        other -> expectationFailure ("expected the recovery write and got " <> show other)

    it "stays silent for every other reviewer role" $
      map (\role -> cautionFor (SettingsCycleModel 1) defaults (role, CodexProvider)) [PrReviewRole, IssueReviewRole, DrainRereviewRole, SolveRole, PrReviseRole]
        `shouldBe` replicate 5 (Just False)

    it "says only that approvals may go stale, and names both exceptions" $ do
      state <- openSettings <$> testAppState (fixtureBoard [])
      let cautioned = applyRosterWrite (Right ()) (RosterWrite editedGateRoster (Just (IssueGateRole, CodexProvider)) True) state
      shownNotice cautioned `shouldBe` Just issueGateCaution
      issueGateCaution
        `shouldBe` "Changing `issue_gate` may make existing issue approvals stale; reconciliation can request rereview. \
                   \Environment overrides or accepted historical reviewer routes may keep some approvals current."

-- | The startup load as the compiled defaults, which is what an install with
-- no @models.toml@ has.
defaults :: Either RosterLoadError ModelRoster
defaults = Right defaultRoster

outcome :: SettingsInput -> Either RosterLoadError ModelRoster -> Maybe (RoleName, ProviderName) -> SettingsOutcome
outcome = settingsOutcome

decoded :: BrickEvent Name AppEvent -> SettingsInput
decoded = settingsInput

key :: Vty.Key -> BrickEvent Name AppEvent
key pressed = VtyEvent (Vty.EvKey pressed [])

wheel :: Vty.Button -> Name -> BrickEvent Name AppEvent
wheel button target = MouseDown target button [] (Location (0, 0))

press :: Name -> BrickEvent Name AppEvent
press target = MouseDown target Vty.BLeft [] (Location (0, 0))

-- | The roster an outcome would write, or 'Nothing' when it writes none.
writtenRoster :: SettingsOutcome -> Maybe ModelRoster
writtenRoster settingsResult = case settingsResult of
  SettingsRosterWrite write -> Just write.rosterWriteRoster
  _ -> Nothing

-- | The roster this write proposes. Anything but a write is a failure of the
-- expectation rather than a value to carry on with.
proposed :: SettingsInput -> Either RosterLoadError ModelRoster -> (RoleName, ProviderName) -> ModelRoster
proposed input roster cell = case settingsOutcome input roster (Just cell) of
  SettingsRosterWrite write -> write.rosterWriteRoster
  other -> error ("expected a roster write and got " <> show other)

editedAssignment :: SettingsInput -> Either RosterLoadError ModelRoster -> (RoleName, ProviderName) -> Maybe Assignment
editedAssignment input roster cell = Map.lookup cell (proposed input roster cell).rosterAssignments

cycledModel :: SettingsInput -> (RoleName, ProviderName) -> Maybe Text
cycledModel input cell = (.assignmentModel) <$> editedAssignment input defaults cell

cycledEffort :: SettingsInput -> (RoleName, ProviderName) -> Maybe Text
cycledEffort input cell = (.assignmentEffort) <$> editedAssignment input defaults cell

-- | Whether the write this input earns would caution, or 'Nothing' if it
-- earns no write at all.
cautionFor :: SettingsInput -> Either RosterLoadError ModelRoster -> (RoleName, ProviderName) -> Maybe Bool
cautionFor input roster cell = case settingsOutcome input roster (Just cell) of
  SettingsRosterWrite write -> Just write.rosterWriteCaution
  _ -> Nothing

-- | Show the overlay over another roster. Through
-- 'Kanban.UI.Types.withModelRoster', so the retained operating mode is the
-- one this roster derives rather than the fixture's compiled dual.
withRoster :: Either RosterLoadError ModelRoster -> AppState -> AppState
withRoster roster = openSettings . withModelRoster roster

-- | The overlay's interior rows, drawn through the same composition the
-- dashboard hands Brick rather than by calling the roster's own drawing
-- function directly, so what these read is the panel the operator sees.
interiorOf :: AppState -> [Text]
interiorOf state =
  map (Data.Text.strip . Data.Text.filter (/= '┃'))
    (renderWidgetLines (themeFor testOptions) (settingsInteriorWidth + 4) (drawOverlay state SettingsOverlay))

-- | Just the roster rows: everything the panel drew between its heading and
-- the end of the section, with the viewport's unused rows and the read-only
-- operating-mode line dropped.
--
-- The mode line sits inside this section and is not one of its rows, so a
-- count or an elision assertion here would otherwise read it as an
-- assignment.
--
-- The section ends at the panel's own bottom border rather than at a rule:
-- the rule that used to close it separated the roster from the overlay's own
-- footer hint, and that hint is the base footer's row now (issue #525), so
-- the roster is the last thing the box draws.
rosterSectionOf :: AppState -> [Text]
rosterSectionOf state =
  filter (\row -> not (Data.Text.null row) && not (isModeLine row))
    (takeWhile (not . isSectionEnd) (drop 1 (dropWhile (/= "Agent models") (interiorOf state))))
  where
    isSectionEnd row = not (Data.Text.null row) && Data.Text.all (`elem` ("━┗┛" :: String)) row
    isModeLine = Data.Text.isPrefixOf "Operating mode:"

-- | The cells the 68-wide panel leaves for a row: two border columns and the
-- one column of padding on each side.
settingsInteriorWidth :: Int
settingsInteriorWidth = 64

-- | The same compiled roster with its @agents@ list the other way round,
-- which is the file order a row must follow.
reversedAgentsRoster :: ModelRoster
reversedAgentsRoster = defaultRoster {rosterAgents = reverse defaultRoster.rosterAgents}

-- | A roster whose first cell differs from the compiled default in nothing
-- but its display label.
relabelledRoster :: ModelRoster
relabelledRoster =
  defaultRoster
    { rosterAssignments =
        Map.insert (SolveRole, CodexProvider) (Assignment "gpt-5.4" "high" "the usual") defaultRoster.rosterAssignments
    }

-- | One cell edited off its compiled default, as an edit through this screen
-- leaves it.
editedRoster :: ModelRoster
editedRoster =
  defaultRoster
    { rosterAssignments =
        Map.insert (SolveRole, ClaudeProvider) (Assignment "claude-opus-5" "high" "claude-opus-5 high") defaultRoster.rosterAssignments
    }

-- | The same, on the one cell the caution is about.
editedGateRoster :: ModelRoster
editedGateRoster =
  defaultRoster
    { rosterAssignments =
        Map.insert (IssueGateRole, CodexProvider) (Assignment "gpt-5.4" "xhigh" "gpt-5.4 xhigh") defaultRoster.rosterAssignments
    }

-- | A provider whose catalog declares one model and one effort, so cycling
-- either has nowhere to go.
singleValueRoster :: ModelRoster
singleValueRoster =
  ModelRoster
    { rosterAgents = [ClaudeProvider],
      rosterProviders = Map.singleton ClaudeProvider (ProviderCatalog ["claude-sonnet-5"] ["high"]),
      rosterAssignments =
        Map.fromList
          [ ((role, ClaudeProvider), Assignment "claude-sonnet-5" "high" "Sonnet 5 high")
          | role <- allRoles
          ]
    }

-- | An operator who narrowed the Codex catalog past the compiled default and
-- moved the assignment to something the narrowed list does declare. The file
-- is usable; the compiled default simply cannot be written back into it.
narrowedCodexRoster :: ModelRoster
narrowedCodexRoster =
  defaultRoster
    { rosterProviders =
        Map.insert
          CodexProvider
          (ProviderCatalog ["gpt-5.5", "gpt-5.6-terra", "gpt-5.6-sol"] ["medium", "high", "xhigh"])
          defaultRoster.rosterProviders,
      rosterAssignments =
        Map.insert (SolveRole, CodexProvider) (Assignment "gpt-5.5" "high" "gpt-5.5 high") defaultRoster.rosterAssignments
    }

-- | Claude loaded and Codex not, so a Codex cell is a cell no row was drawn
-- for.
claudeOnly :: ModelRoster
claudeOnly =
  ModelRoster
    { rosterAgents = [ClaudeProvider],
      rosterProviders = Map.filterWithKey (\provider _ -> provider == ClaudeProvider) defaultRoster.rosterProviders,
      rosterAssignments = Map.filterWithKey (\(_, provider) _ -> provider == ClaudeProvider) defaultRoster.rosterAssignments
    }

-- | A model ID longer than the panel is wide, which nothing but a file edit
-- can produce and nothing about the panel's width can prevent.
longModel :: Text
longModel = "claude-opus-5-with-a-preposterously-long-operator-authored-identifier"

longModelRoster :: ModelRoster
longModelRoster =
  ModelRoster
    { rosterAgents = [ClaudeProvider],
      rosterProviders = Map.singleton ClaudeProvider (ProviderCatalog [longModel] ["high"]),
      rosterAssignments =
        Map.fromList
          [ ((role, ClaudeProvider), Assignment longModel "high" (longModel <> " high"))
          | role <- allRoles
          ]
    }

unusableRoster :: RosterLoadError
unusableRoster =
  RosterLoadError
    "/fixture/home/.config/kanban/models.toml"
    (RosterInvalid [UnknownModel PrReviewRole CodexProvider "gpt-5.9"])

-- | The defect the panel shows in place of its rows, kept beside the fixture
-- that produces it so the frame and this suite cannot drift apart.
unusableRosterMessage :: Text
unusableRosterMessage = rosterErrorMessage unusableRoster
