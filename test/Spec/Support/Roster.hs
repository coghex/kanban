-- | Model-roster fixtures and cell resolution for the spawn-site specs.
--
-- Two things live here so no spec has to reinvent them. 'cellOf' is how an
-- argv expectation names a roster cell instead of a literal: the default
-- cells are pinned verbatim by "Spec.Config.Models", so a spec reading
-- through this proves argv derives from the cell without restating the wire
-- value a second time. The rosters below are the shapes the spawn boundaries
-- must behave differently on — one whose every consulted cell differs from
-- the default, and the reduced-provider rosters 'Kanban.Models.validateRoster'
-- accepts and today's brand routing can still miss.
module Spec.Support.Roster
  ( cellOf,
    rerosteredDefaults,
    claudeOnlyRoster,
    codexOnlyRoster,
    noAgentRoster,
  )
where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Models
  ( Assignment (..),
    AssignmentUnavailable,
    ModelRoster (..),
    ProviderCatalog (..),
    ProviderName (..),
    assignmentUnavailableMessage,
    defaultRoster,
  )

-- | The cell a spec's expectation is written against. A fixture that cannot
-- supply it is a broken fixture, so this fails loudly rather than standing
-- in a default — which is the very substitution the code under test is
-- forbidden to make.
--
-- Polymorphic in what the resolver hands back: 'Kanban.Models.assignmentFor'
-- yields the bare cell, while the task-routing resolvers yield the recorded
-- assignment that carries the provider with it.
cellOf :: Either AssignmentUnavailable cell -> cell
cellOf =
  either
    (error . Text.unpack . ("fixture roster cannot supply the cell under test: " <>) . assignmentUnavailableMessage)
    id

-- | A valid roster whose every cell names the /next/ model and effort its
-- provider declares, so no assertion against it can pass on a compiled
-- default. Built by rotation rather than by naming values, so a later slice
-- that adds a model to a catalog cannot quietly make a cell equal the
-- default again, and every rotated value is still inside its catalog and
-- therefore still valid.
rerosteredDefaults :: ModelRoster
rerosteredDefaults =
  defaultRoster
    { rosterAssignments = Map.mapWithKey rotate defaultRoster.rosterAssignments
    }
  where
    rotate (_, provider) assignment = case Map.lookup provider defaultRoster.rosterProviders of
      Nothing -> assignment
      Just catalog ->
        assignment
          { assignmentModel = successorIn catalog.catalogModels assignment.assignmentModel,
            assignmentEffort = successorIn catalog.catalogEfforts assignment.assignmentEffort
          }

-- | The entry after @value@, wrapping at the end. Identity for a list that
-- does not carry the value or carries nothing else, which a validated roster
-- never produces.
successorIn :: [Text] -> Text -> Text
successorIn entries value = case break (== value) entries of
  (_, _ : next : _) -> next
  (first : _, _ : []) -> first
  _ -> value

-- | Claude loaded, Codex absent: valid ("Spec.Config.Models" proves it), and
-- every Codex-routed spawn must refuse against it.
claudeOnlyRoster :: ModelRoster
claudeOnlyRoster = restrictedTo ClaudeProvider

-- | The mirror image, which is what a Claude-routed review meets on a
-- Codex-only install.
codexOnlyRoster :: ModelRoster
codexOnlyRoster = restrictedTo CodexProvider

-- | The zero-agent roster the schema also accepts, which no routing can
-- satisfy.
noAgentRoster :: ModelRoster
noAgentRoster =
  ModelRoster
    { rosterAgents = [],
      rosterProviders = defaultRoster.rosterProviders,
      rosterAssignments = Map.empty
    }

restrictedTo :: ProviderName -> ModelRoster
restrictedTo provider =
  ModelRoster
    { rosterAgents = [provider],
      rosterProviders = Map.filterWithKey (\declared _ -> declared == provider) defaultRoster.rosterProviders,
      rosterAssignments = Map.filterWithKey (\(_, assigned) _ -> assigned == provider) defaultRoster.rosterAssignments
    }
