-- | The model roster: which model and effort every agent role runs on, per
-- provider (@docs/model_settings_design.md@, MODEL-1).
--
-- Two layers, deliberately provider-generic. /Providers/ declare what
-- exists — an ordered model list and an effort vocabulary per brand — and
-- /roles/ name the pipeline steps, assigning each (role, provider) pair a
-- model, an effort, and a display label. How a provider turns an assignment
-- into argv stays a compiled adapter per brand, so argv shape never enters
-- this file's schema. Each role also carries a compiled /applicability/ —
-- which providers it can run on at all (D-14) — which is code structure
-- rather than configuration and therefore lives beside the role registry
-- here, never in the file.
--
-- The compiled 'defaultRoster' must equal the tracked @models.toml.example@
-- (a test holds the two together), and the user's roster is a TUI-owned
-- @models.toml@ under the XDG configuration root (D-4). Failure semantics
-- follow D-3: an absent file is silently the defaults — the fresh-install
-- path — while a present file that is unreadable, unparseable,
-- foreign-versioned, or invalid is a typed 'RosterLoadError' naming the file
-- and the defect. That error is a value later slices refuse agent spawns
-- with; nothing here falls back to the defaults, because an operator who
-- edited the file to change a model must never have an agent quietly run on
-- the old one. A present file is likewise a complete roster rather than a
-- sparse patch over the defaults: every loaded provider a role applies to
-- must resolve from the file itself.
--
-- The Haskell spawn sites consume it through 'assignmentFor', the one
-- accessor a caller resolves a cell with: the roster is read at startup and
-- retained (see 'Kanban.UI.Types.AppState'), each agent-starting path unwraps
-- that result and resolves the cell its routing selected, and a roster that
-- cannot supply the cell refuses the spawn instead of falling back. The
-- settings overlay edits it in place ("Kanban.UI.Settings"), always through
-- 'saveModelRoster' and only moving what the dashboard holds once that write
-- succeeded, so what a later spawn resolves is always something on disk. What a launch resolves becomes a 'RecordedAssignment' it persists,
-- and every later launch continuing that same provider session replays the
-- record rather than resolving again (D-7). The Python and plugin spawn
-- sites migrate in a later slice of epic #412.
module Kanban.Models
  ( ProviderName (..),
    RoleName (..),
    ProviderCatalog (..),
    Assignment (..),
    RecordedAssignment (..),
    ModelRoster (..),
    OperatingMode (..),
    RosterDefect (..),
    RosterFailure (..),
    RosterLoadError (..),
    AssignmentUnavailable (..),
    allProviders,
    allRoles,
    roleApplicability,
    providerKey,
    parseProviderKey,
    roleKey,
    parseRoleKey,
    rosterSchemaVersion,
    defaultRoster,
    decodeRoster,
    encodeRoster,
    rosterPath,
    loadModelRoster,
    saveModelRoster,
    assignmentFor,
    operatingModeFor,
    loadedOperatingMode,
    operatingModeLabel,
    agentsLoaded,
    recordAssignment,
    recordedAssignmentCell,
    rosterDefectMessage,
    rosterFailureMessage,
    rosterErrorMessage,
    assignmentUnavailableMessage,
    noAgentModeMessage,
    unavailableAssignmentDisplay,
  )
where

import Control.Exception (IOException, bracketOnError, try)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:))
import qualified Data.ByteString as ByteString
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import Kanban.Paths (createPrivateDirectory)
import System.Directory (XdgDirectory (XdgConfig), getXdgDirectory, removeFile, renameFile)
import System.FilePath ((</>), takeDirectory, takeFileName)
import System.IO (Handle, hClose, openBinaryTempFile)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (getFileStatus, getSymbolicLinkStatus, isRegularFile, setFileMode)
import qualified Toml
import Toml (Table' (..), Value' (..))
import Toml.Schema ((.=), table)

--------------------------------------------------------------------------------
-- The compiled registries

-- | The providers this build carries an adapter for. The file's provider
-- tables are open-keyed for the future plugin arc, but a key outside this
-- registry is a validation error today: an assignment can only ever run
-- through a compiled adapter.
data ProviderName = CodexProvider | ClaudeProvider
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The pipeline steps the binary knows. @issue_review@ (the embedded review
-- thread) and @issue_gate@ (the canonical @approve_issues.py@ reviewers) stay
-- distinct on purpose (D-5): today they genuinely run different models, and
-- preserving the true matrix is what keeps the defaults behavior-identical.
data RoleName
  = SolveRole
  | PrReviewRole
  | PrReviseRole
  | IssueReviewRole
  | IssueReviseRole
  | IssueGateRole
  | DrainRereviewRole
  deriving stock (Eq, Ord, Show, Enum, Bounded)

allProviders :: [ProviderName]
allProviders = [minBound .. maxBound]

allRoles :: [RoleName]
allRoles = [minBound .. maxBound]

-- | Which providers a role can run on at all (D-14). @issue_revise@ names
-- the authenticated-Claude revision tool — a Codex-only install revises
-- inside the review thread itself — so it is Claude-only by construction;
-- every other role applies to both brands. Validation demands an assignment
-- only for loaded providers a role applies to, and refuses one for a
-- provider outside this list.
roleApplicability :: RoleName -> [ProviderName]
roleApplicability IssueReviseRole = [ClaudeProvider]
roleApplicability _ = allProviders

providerKey :: ProviderName -> Text
providerKey CodexProvider = "codex"
providerKey ClaudeProvider = "claude"

parseProviderKey :: Text -> Maybe ProviderName
parseProviderKey key = lookup key [(providerKey provider, provider) | provider <- allProviders]

roleKey :: RoleName -> Text
roleKey SolveRole = "solve"
roleKey PrReviewRole = "pr_review"
roleKey PrReviseRole = "pr_revise"
roleKey IssueReviewRole = "issue_review"
roleKey IssueReviseRole = "issue_revise"
roleKey IssueGateRole = "issue_gate"
roleKey DrainRereviewRole = "drain_rereview"

parseRoleKey :: Text -> Maybe RoleName
parseRoleKey key = lookup key [(roleKey role, role) | role <- allRoles]

--------------------------------------------------------------------------------
-- The roster value

-- | One provider's declarations: the model IDs the operator considers
-- available and the effort vocabulary its CLI accepts. Both lists keep their
-- file order — the settings screen cycles through them in this order.
data ProviderCatalog = ProviderCatalog
  { catalogModels :: [Text],
    catalogEfforts :: [Text]
  }
  deriving stock (Eq, Show)

-- | One (role, provider) cell: the wire model and effort, and the label
-- every surface that names this assignment displays.
data Assignment = Assignment
  { assignmentModel :: Text,
    assignmentEffort :: Text,
    assignmentDisplay :: Text
  }
  deriving stock (Eq, Show)

-- | The roster cell a launch resolved, together with the provider it
-- resolved through, in the shape a durable record carries (D-7).
--
-- The provider travels with the cell rather than being recomputed from the
-- task beside it. A resumed launch replays this record instead of resolving
-- anything, so the record is the only thing that still knows which compiled
-- adapter these values were read for; a supervisor that re-derived the
-- provider from today's routing could pair one brand's model with the
-- other's executable.
data RecordedAssignment = RecordedAssignment
  { recordedAssignmentProvider :: ProviderName,
    recordedAssignmentModel :: Text,
    recordedAssignmentEffort :: Text,
    recordedAssignmentDisplay :: Text
  }
  deriving stock (Eq, Show)

-- | The provider's own file key is what the durable record spells, so the
-- wire vocabulary the roster file and the worker specification use is one
-- vocabulary rather than two that have to be kept in step.
instance ToJSON RecordedAssignment where
  toJSON recorded =
    -- Spelled as explicit pairs rather than with aeson's @.=@: this module
    -- also imports @Toml.Schema@'s operator of that name.
    object
      [ ("provider", toJSON (providerKey recorded.recordedAssignmentProvider)),
        ("model", toJSON recorded.recordedAssignmentModel),
        ("effort", toJSON recorded.recordedAssignmentEffort),
        ("display", toJSON recorded.recordedAssignmentDisplay)
      ]

instance FromJSON RecordedAssignment where
  parseJSON = withObject "RecordedAssignment" $ \value -> do
    provider <- value .: "provider"
    RecordedAssignment
      <$> maybe (fail ("unknown provider " <> show provider)) pure (parseProviderKey provider)
      <*> value .: "model"
      <*> value .: "effort"
      <*> value .: "display"

recordAssignment :: ProviderName -> Assignment -> RecordedAssignment
recordAssignment provider assignment =
  RecordedAssignment
    { recordedAssignmentProvider = provider,
      recordedAssignmentModel = assignment.assignmentModel,
      recordedAssignmentEffort = assignment.assignmentEffort,
      recordedAssignmentDisplay = assignment.assignmentDisplay
    }

-- | The cell an adapter builds argv from, projected back out of the record.
recordedAssignmentCell :: RecordedAssignment -> Assignment
recordedAssignmentCell recorded =
  Assignment
    { assignmentModel = recorded.recordedAssignmentModel,
      assignmentEffort = recorded.recordedAssignmentEffort,
      assignmentDisplay = recorded.recordedAssignmentDisplay
    }

-- | A complete roster. 'rosterAgents' is the loaded provider set (D-10) —
-- and therefore the 'OperatingMode' below — kept in file order; validation
-- enforces its set semantics by refusing a repeated entry. Only this list
-- changes what is loaded: editing a provider table never does.
data ModelRoster = ModelRoster
  { rosterAgents :: [ProviderName],
    rosterProviders :: Map ProviderName ProviderCatalog,
    rosterAssignments :: Map (RoleName, ProviderName) Assignment
  }
  deriving stock (Eq, Show)

-- | The operating mode, derived from the loaded provider set and never set
-- (D-8). Two providers is dual, one is single-agent, zero is no-agent, and
-- there is no fourth state: an unusable @models.toml@ derives 'NoAgentMode'
-- through 'loadedOperatingMode' rather than leaving the mode undefined.
--
-- Counted rather than matched pair by pair, so a third compiled provider
-- widens dual instead of falling through to a mode it does not mean.
--
-- Which single provider is loaded is deliberately not carried here. Both
-- singleton sets are one mode, and a consumer that needs the brand reads
-- 'rosterAgents' from the roster it already holds.
data OperatingMode
  = -- | Two or more providers: today's cross-brand pipeline, unchanged.
    DualMode
  | -- | Exactly one provider: every role resolves through that brand.
    SingleAgentMode
  | -- | No provider at all: a board-only Kanban that spawns nothing.
    NoAgentMode
  deriving stock (Eq, Show)

-- | The mode a roster's own @agents@ list derives.
operatingModeFor :: ModelRoster -> OperatingMode
operatingModeFor roster = case length roster.rosterAgents of
  0 -> NoAgentMode
  1 -> SingleAgentMode
  _ -> DualMode

-- | The mode a startup load derives, which is the projection the dashboard
-- retains ('Kanban.UI.Types.appModelRoster').
--
-- A 'Left' is 'NoAgentMode': a file that will not load has no @agents@ list
-- to count, and giving that state one total value is what keeps every later
-- consumer to three cases. The defect is not erased by this — the roster
-- itself still holds the 'RosterLoadError' — so a consumer that must tell a
-- defect-derived no-agent from a declared one reads it there.
loadedOperatingMode :: Either RosterLoadError ModelRoster -> OperatingMode
loadedOperatingMode = either (const NoAgentMode) operatingModeFor

-- | Whether the mode has any provider loaded to reach at all.
--
-- The one spelling of that question, because more than one surface keys on
-- it and they must agree: the usage probes and the sidebar's provider blocks
-- ("Kanban.UI.Refresh", "Kanban.UI.Board"), the agent bindings' visibility
-- and refusal ('Kanban.UI.Keys.availableIn'), and the @--usage@ and @--ping@
-- run-and-exit modes ('Kanban.CLI.launchModeRefusal') all ask it here.
--
-- Total in 'OperatingMode' on purpose: a mode added to that type cannot reach
-- any of those surfaces without a decision about whether it has a provider.
agentsLoaded :: OperatingMode -> Bool
agentsLoaded mode = case mode of
  DualMode -> True
  SingleAgentMode -> True
  NoAgentMode -> False

-- | What the mode is called wherever one is shown, in the vocabulary
-- @models.toml.example@ and the design already use.
operatingModeLabel :: OperatingMode -> Text
operatingModeLabel mode = case mode of
  DualMode -> "dual"
  SingleAgentMode -> "single-agent"
  NoAgentMode -> "no-agent"

-- | The version 'encodeRoster' stamps on every file written and the only one
-- 'decodeRoster' accepts. Unlike the settings file, a foreign version is a
-- typed error rather than silent defaults: D-3 forbids an unusable roster
-- from quietly running agents on values the operator believes they replaced.
rosterSchemaVersion :: Integer
rosterSchemaVersion = 1

-- | The compiled defaults: today's wire values, cell for cell, from the
-- verified matrix in @docs/model_settings_design.md@. Thirteen applicable
-- cells, every one valued. Two are new in this arc (D-14) and consulted by
-- no dual-mode spawn until their slices land: @issue_review.claude@ (the
-- Claude embedded-review backend, MODEL-13) and @drain_rereview.claude@ (a
-- Claude-only install's drainer, MODEL-11).
defaultRoster :: ModelRoster
defaultRoster =
  ModelRoster
    { rosterAgents = [CodexProvider, ClaudeProvider],
      rosterProviders =
        Map.fromList
          [ ( CodexProvider,
              ProviderCatalog
                { catalogModels = ["gpt-5.4", "gpt-5.5", "gpt-5.6-terra", "gpt-5.6-sol"],
                  catalogEfforts = ["minimal", "low", "medium", "high", "xhigh"]
                }
            ),
            ( ClaudeProvider,
              ProviderCatalog
                { catalogModels = ["claude-sonnet-5", "claude-opus-5", "claude-fable-5"],
                  catalogEfforts = ["low", "medium", "high", "xhigh"]
                }
            )
          ],
      rosterAssignments =
        Map.fromList
          [ ((SolveRole, CodexProvider), Assignment "gpt-5.4" "high" "gpt-5.4 high"),
            ((SolveRole, ClaudeProvider), Assignment "claude-sonnet-5" "high" "Sonnet 5 high"),
            ((PrReviewRole, CodexProvider), Assignment "gpt-5.6-terra" "xhigh" "GPT-5.6-Terra xhigh"),
            ((PrReviewRole, ClaudeProvider), Assignment "claude-opus-5" "xhigh" "Opus 5 xhigh"),
            ((PrReviseRole, CodexProvider), Assignment "gpt-5.4" "high" "gpt-5.4 high"),
            ((PrReviseRole, ClaudeProvider), Assignment "claude-sonnet-5" "xhigh" "Sonnet 5 xhigh"),
            ((IssueReviewRole, CodexProvider), Assignment "gpt-5.4" "high" "gpt-5.4 high"),
            ((IssueReviewRole, ClaudeProvider), Assignment "claude-opus-5" "xhigh" "Opus 5 xhigh"),
            ((IssueReviseRole, ClaudeProvider), Assignment "claude-sonnet-5" "high" "Sonnet 5 high"),
            ((IssueGateRole, CodexProvider), Assignment "gpt-5.6-sol" "xhigh" "GPT-5.6-Sol xhigh"),
            ((IssueGateRole, ClaudeProvider), Assignment "claude-opus-5" "xhigh" "Opus 5 xhigh"),
            ((DrainRereviewRole, CodexProvider), Assignment "gpt-5.6-terra" "medium" "GPT-5.6-Terra medium"),
            ((DrainRereviewRole, ClaudeProvider), Assignment "claude-opus-5" "medium" "Opus 5 medium")
          ]
    }

--------------------------------------------------------------------------------
-- Failure vocabulary

-- | One defect in an otherwise well-formed version-1 file. Every constructor
-- names its subject — a dotted key path or the (role, provider) cell — so a
-- refusal message can point at the exact line the operator must repair.
-- Unknown keys are defects at every level rather than warnings: silently
-- skipping a misspelled @[roles.pr_reveiw.codex]@ is how an operator ships
-- the old model believing they changed it.
data RosterDefect
  = -- | A key the schema does not know, at any level, by dotted path.
    UnknownKey Text
  | -- | A required key that is absent, by dotted path.
    MissingKey Text
  | -- | A key whose value has the wrong shape; the second field states the
    -- requirement it failed.
    InvalidValue Text Text
  | -- | A list that repeats an entry, by dotted path and repeated entry.
    -- The @agents@ list is set-valued (D-10), and the catalogs feed
    -- settings-screen cycling where a repeat would be two rows for one model.
    DuplicateEntry Text Text
  | -- | A provider key outside the compiled registry, by dotted path.
    UnknownProviderKey Text
  | -- | A role key outside the compiled registry, by dotted path.
    UnknownRoleKey Text
  | -- | An @agents@ entry with no @[providers.X]@ declaration to load.
    UndeclaredAgent Text
  | -- | An assignment for a known provider the file never declares, so its
    -- model and effort have no catalog to validate against.
    UndeclaredAssignmentProvider RoleName ProviderName
  | -- | An assignment for a provider outside the role's compiled
    -- applicability (D-14) — a cell no build could ever consult.
    InapplicableAssignment RoleName ProviderName
  | -- | An assignment naming a model absent from its provider's list.
    UnknownModel RoleName ProviderName Text
  | -- | An assignment naming an effort outside its provider's vocabulary.
    UnknownEffort RoleName ProviderName Text
  | -- | No assignment for a loaded provider the role applies to. A present
    -- file is a complete roster, never a sparse patch over the defaults.
    MissingAssignment RoleName ProviderName
  deriving stock (Eq, Show)

-- | Why a present file yielded no roster.
data RosterFailure
  = -- | The path exists but is not a readable regular file: a directory, a
    -- FIFO or other special file, a dangling link, or a permission
    -- refusal — present-but-unusable, never silently the defaults.
    RosterUnreadable Text
  | -- | Not decodable as TOML (or not UTF-8), with the parser's message.
    RosterUnparseable Text
  | -- | A well-formed file written by another version of this schema. Its
    -- payload is not ours to judge, so no further validation runs.
    RosterForeignVersion Integer
  | -- | A version-1 file with one or more defects, in file walk order.
    RosterInvalid [RosterDefect]
  deriving stock (Eq, Show)

-- | A failure bound to the file it names, which is the value later slices
-- refuse agent spawns with.
data RosterLoadError = RosterLoadError
  { rosterErrorPath :: FilePath,
    rosterErrorFailure :: RosterFailure
  }
  deriving stock (Eq, Show)

-- | Why a @(role, provider)@ cell could not be resolved.
--
-- Distinct from 'RosterDefect' on purpose: a defect is a file the operator
-- must repair, while every constructor here describes a /valid/ roster that
-- simply does not cover what the caller's routing selected. 'validateRoster'
-- demands an assignment only for loaded providers a role applies to, so a
-- Claude-only or zero-agent roster is valid and yet has no cell for a Codex
-- spawn; that is a refusal to report, not a file to fix.
data AssignmentUnavailable
  = -- | The provider this run's routing selected is not in @agents@, so the
    -- file declares nothing for it to run on.
    UnloadedProvider RoleName ProviderName
  | -- | The role cannot run on that provider at all ('roleApplicability').
    InapplicableRole RoleName ProviderName
  | -- | Loaded and applicable, but the roster carries no assignment. A
    -- validated roster cannot reach this; an unvalidated value built in
    -- process can, and it must refuse rather than invent a default.
    UnassignedCell RoleName ProviderName
  deriving stock (Eq, Show)

-- | The one accessor a spawn site resolves a cell through.
--
-- Total, and deliberately the /only/ way out of 'rosterAssignments': a
-- partial lookup at each call site would let one of them recover with the
-- compiled default, which is exactly the silent-old-model path D-3 forbids.
-- Both preconditions are checked here rather than assumed, because a
-- validated roster guarantees a cell only for loaded providers a role
-- applies to, and nothing constrains today's brand routing to select one.
assignmentFor :: ModelRoster -> RoleName -> ProviderName -> Either AssignmentUnavailable Assignment
assignmentFor roster role provider
  | provider `notElem` roster.rosterAgents = Left (UnloadedProvider role provider)
  | provider `notElem` roleApplicability role = Left (InapplicableRole role provider)
  | otherwise =
      maybe (Left (UnassignedCell role provider)) Right (Map.lookup (role, provider) roster.rosterAssignments)

-- | What a surface shows where a model name would go when the roster
-- cannot supply the cell it needs.
--
-- Deliberately not a model: a surface that cannot resolve its assignment
-- must say so rather than name the compiled default, which is the same
-- silent-old-model path D-3 forbids at a spawn boundary. Held here, beside
-- 'assignmentUnavailableMessage', so the terminal widgets, the session
-- transcripts, and the review prose all spell one phrase.
unavailableAssignmentDisplay :: Text
unavailableAssignmentDisplay = "model roster unavailable"

-- | The refusal text every spawn boundary shares for an unavailable cell,
-- naming the cell the way 'rosterDefectMessage' names a defective one.
assignmentUnavailableMessage :: AssignmentUnavailable -> Text
assignmentUnavailableMessage unavailable = case unavailable of
  UnloadedProvider role provider ->
    "model roster does not load provider "
      <> quotedKey (providerKey provider)
      <> ", which this "
      <> quotedKey (roleKey role)
      <> " step runs on"
  InapplicableRole role provider ->
    "model roster role "
      <> quotedKey (roleKey role)
      <> " cannot run on provider "
      <> quotedKey (providerKey provider)
  UnassignedCell role provider ->
    "model roster has no "
      <> quotedKey ("roles." <> roleKey role <> "." <> providerKey provider)
      <> " assignment"
  where
    quotedKey text = "\"" <> text <> "\""

-- | The refusal every surface that needs a loaded provider shares while the
-- roster loads none, naming the mode and the key that selects it the way
-- 'Kanban.UI.Settings.operatingModeLine' already names them on screen.
--
-- One phrase rather than one per surface, for the same reason
-- 'assignmentUnavailableMessage' is one: the board's six agent bindings, the
-- board card's right click, and the @--usage@ and @--ping@ refusals all say
-- this, and an operator who meets it twice must not be told two things.
noAgentModeMessage :: Text
noAgentModeMessage =
  "model roster loads no provider, so this is "
    <> operatingModeLabel NoAgentMode
    <> " mode · set by agents in models.toml"

rosterDefectMessage :: RosterDefect -> Text
rosterDefectMessage defect = case defect of
  UnknownKey path -> quoted path <> " is not a key this schema knows"
  MissingKey path -> quoted path <> " is required and missing"
  InvalidValue path requirement -> quoted path <> " " <> requirement
  DuplicateEntry path entry -> quoted path <> " lists " <> quoted entry <> " more than once"
  UnknownProviderKey path -> quoted path <> " does not name a known provider"
  UnknownRoleKey path -> quoted path <> " does not name a known role"
  UndeclaredAgent agent -> "agents entry " <> quoted agent <> " has no [providers." <> agent <> "] declaration"
  UndeclaredAssignmentProvider role provider ->
    cellPath role provider <> " assigns a provider the file never declares"
  InapplicableAssignment role provider ->
    cellPath role provider <> " assigns a provider this role cannot run on"
  UnknownModel role provider model ->
    cellPath role provider <> " names model " <> quoted model <> ", which is not in that provider's models list"
  UnknownEffort role provider effort ->
    cellPath role provider <> " names effort " <> quoted effort <> ", which is not in that provider's efforts list"
  MissingAssignment role provider ->
    cellPath role provider <> " is required for a loaded provider this role applies to, and missing"
  where
    quoted text = "\"" <> text <> "\""
    cellPath role provider = "roles." <> roleKey role <> "." <> providerKey provider

rosterFailureMessage :: RosterFailure -> Text
rosterFailureMessage failure = case failure of
  RosterUnreadable message -> "could not be read: " <> message
  RosterUnparseable message -> "is not parseable TOML: " <> message
  RosterForeignVersion version ->
    "carries schema_version "
      <> Text.pack (show version)
      <> "; this build reads version "
      <> Text.pack (show rosterSchemaVersion)
  RosterInvalid defects -> "is invalid: " <> Text.intercalate "; " (map rosterDefectMessage defects)

-- | The one rendering every refusal surface shares, naming the file and the
-- defect as D-3 requires.
rosterErrorMessage :: RosterLoadError -> Text
rosterErrorMessage loadError =
  "model roster " <> Text.pack loadError.rosterErrorPath <> " " <> rosterFailureMessage loadError.rosterErrorFailure

--------------------------------------------------------------------------------
-- Decoding

-- | Decode and validate one file's text. The version gates everything: a
-- file that does not carry @schema_version = 1@ is judged on that alone.
decodeRoster :: Text -> Either RosterFailure ModelRoster
decodeRoster input = case Toml.parse input of
  Left syntaxError -> Left (RosterUnparseable (Text.pack syntaxError))
  Right topTable -> decodeRosterTable topTable

decodeRosterTable :: Table' Toml.Position -> Either RosterFailure ModelRoster
decodeRosterTable (MkTable topEntries) = do
  version <- case Map.lookup "schema_version" topEntries of
    Nothing -> Left (RosterInvalid [MissingKey "schema_version"])
    Just (_, Integer' _ number) -> Right number
    Just _ -> Left (RosterInvalid [InvalidValue "schema_version" "must be an integer"])
  if version /= rosterSchemaVersion
    then Left (RosterForeignVersion version)
    else do
      let unknownTopKeys =
            [ UnknownKey key
            | key <- Map.keys topEntries,
              key `notElem` ["schema_version", "agents", "providers", "roles"]
            ]
          (agentDefects, agents) = decodeAgents (Map.lookup "agents" topEntries)
          (providerDefects, providers) = decodeProviders (Map.lookup "providers" topEntries)
          (roleDefects, assignments, presentCells) = decodeRoles (Map.lookup "roles" topEntries)
          semanticDefects = validateRoster agents providers assignments presentCells
          defects = unknownTopKeys <> agentDefects <> providerDefects <> roleDefects <> semanticDefects
      case defects of
        [] ->
          Right
            ModelRoster
              { rosterAgents = loadedProviders agents,
                rosterProviders = providers,
                rosterAssignments = assignments
              }
        _ -> Left (RosterInvalid defects)

-- | The raw @agents@ entries, or 'Nothing' when the key is absent — which
-- silently means both providers (D-10), the one absence in this schema that
-- is a default rather than a defect.
decodeAgents :: Maybe (Toml.Position, Value' Toml.Position) -> ([RosterDefect], Maybe [Text])
decodeAgents entry = case entry of
  Nothing -> ([], Nothing)
  Just (_, List' _ items) ->
    let (defects, names) = foldr collect ([], []) items
        repeats = [DuplicateEntry "agents" name | name <- duplicatedEntries names]
     in (defects <> repeats, Just names)
    where
      collect item (defects, names) = case item of
        Text' _ name -> (defects, name : names)
        _ -> (InvalidValue "agents" "must be an array of provider-name strings" : defects, names)
  Just _ -> ([InvalidValue "agents" "must be an array of provider-name strings"], Just [])

-- | The effective loaded set: the declared order of the @agents@ list, or
-- both providers when the key is absent. Entries that name no known provider
-- are already defects; this projection is only consulted once there are none.
loadedProviders :: Maybe [Text] -> [ProviderName]
loadedProviders = maybe allProviders (mapMaybe parseProviderKey)

decodeProviders :: Maybe (Toml.Position, Value' Toml.Position) -> ([RosterDefect], Map ProviderName ProviderCatalog)
decodeProviders entry = case entry of
  Nothing -> ([], Map.empty)
  Just (_, Table' _ (MkTable providerEntries)) ->
    Map.foldrWithKey collect ([], Map.empty) providerEntries
    where
      collect key (_, value) (defects, catalogs) = case parseProviderKey key of
        Nothing -> (UnknownProviderKey ("providers." <> key) : defects, catalogs)
        Just provider ->
          let (catalogDefects, catalog) = decodeCatalog ("providers." <> key) value
           in (catalogDefects <> defects, Map.insert provider catalog catalogs)
  Just _ -> ([InvalidValue "providers" "must be a table of provider declarations"], Map.empty)

-- | One @[providers.X]@ table. A defective declaration still lands in the
-- map — the table exists, so the provider is declared, and treating it as
-- absent would cascade misleading undeclared-provider defects on top of the
-- real one.
decodeCatalog :: Text -> Value' Toml.Position -> ([RosterDefect], ProviderCatalog)
decodeCatalog path value = case value of
  Table' _ (MkTable catalogEntries) ->
    let unknownKeys =
          [ UnknownKey (path <> "." <> key)
          | key <- Map.keys catalogEntries,
            key `notElem` ["models", "efforts"]
          ]
        (modelDefects, models) = decodeNameList (path <> ".models") "model IDs" (Map.lookup "models" catalogEntries)
        (effortDefects, efforts) = decodeNameList (path <> ".efforts") "effort names" (Map.lookup "efforts" catalogEntries)
     in (unknownKeys <> modelDefects <> effortDefects, ProviderCatalog models efforts)
  _ -> ([InvalidValue path "must be a table declaring models and efforts"], ProviderCatalog [] [])

-- | A required, non-empty, repeat-free array of strings, in file order.
decodeNameList :: Text -> Text -> Maybe (Toml.Position, Value' Toml.Position) -> ([RosterDefect], [Text])
decodeNameList path what entry = case entry of
  Nothing -> ([MissingKey path], [])
  Just (_, List' _ items)
    | Just names <- traverse textItem items ->
        if null names
          then ([InvalidValue path ("must be a non-empty array of " <> what)], [])
          else ([DuplicateEntry path name | name <- duplicatedEntries names], names)
  Just _ -> ([InvalidValue path ("must be a non-empty array of " <> what)], [])
  where
    textItem item = case item of
      Text' _ name -> Just name
      _ -> Nothing

-- | The @[roles.*.*]@ grid: the complete assignments, plus every cell that
-- is present at all — including defective ones, which must not additionally
-- read as missing.
decodeRoles ::
  Maybe (Toml.Position, Value' Toml.Position) ->
  ([RosterDefect], Map (RoleName, ProviderName) Assignment, [(RoleName, ProviderName)])
decodeRoles entry = case entry of
  Nothing -> ([], Map.empty, [])
  Just (_, Table' _ (MkTable roleEntries)) ->
    Map.foldrWithKey collectRole ([], Map.empty, []) roleEntries
    where
      collectRole key (_, value) (defects, assignments, present) = case parseRoleKey key of
        Nothing -> (UnknownRoleKey ("roles." <> key) : defects, assignments, present)
        Just role ->
          let (roleDefects, roleAssignments, rolePresent) = decodeRoleTable role ("roles." <> key) value
           in (roleDefects <> defects, Map.union roleAssignments assignments, rolePresent <> present)
  Just _ -> ([InvalidValue "roles" "must be a table of role assignments"], Map.empty, [])

decodeRoleTable ::
  RoleName ->
  Text ->
  Value' Toml.Position ->
  ([RosterDefect], Map (RoleName, ProviderName) Assignment, [(RoleName, ProviderName)])
decodeRoleTable role path value = case value of
  Table' _ (MkTable providerEntries) ->
    Map.foldrWithKey collectProvider ([], Map.empty, []) providerEntries
    where
      collectProvider key (_, cell) (defects, assignments, present) = case parseProviderKey key of
        Nothing -> (UnknownProviderKey (path <> "." <> key) : defects, assignments, present)
        Just provider ->
          let (cellDefects, assignment) = decodeAssignment (path <> "." <> key) cell
              inserted = maybe assignments (\complete -> Map.insert (role, provider) complete assignments) assignment
           in (cellDefects <> defects, inserted, (role, provider) : present)
  _ -> ([InvalidValue path "must be a table of per-provider assignments"], Map.empty, [])

-- | One assignment table. A defective cell yields its defects and no
-- 'Assignment': the membership checks need all three fields, and the cell's
-- presence is what keeps it out of the missing-assignment sweep.
decodeAssignment :: Text -> Value' Toml.Position -> ([RosterDefect], Maybe Assignment)
decodeAssignment path value = case value of
  Table' _ (MkTable cellEntries) ->
    let unknownKeys =
          [ UnknownKey (path <> "." <> key)
          | key <- Map.keys cellEntries,
            key `notElem` ["model", "effort", "display"]
          ]
        (modelDefects, model) = requiredText (path <> ".model") (Map.lookup "model" cellEntries)
        (effortDefects, effort) = requiredText (path <> ".effort") (Map.lookup "effort" cellEntries)
        (displayDefects, display) = requiredText (path <> ".display") (Map.lookup "display" cellEntries)
        defects = unknownKeys <> modelDefects <> effortDefects <> displayDefects
     in (defects, Assignment <$> model <*> effort <*> display)
  _ -> ([InvalidValue path "must be a table assigning model, effort, and display"], Nothing)

requiredText :: Text -> Maybe (Toml.Position, Value' Toml.Position) -> ([RosterDefect], Maybe Text)
requiredText path entry = case entry of
  Nothing -> ([MissingKey path], Nothing)
  Just (_, Text' _ text) -> ([], Just text)
  Just _ -> ([InvalidValue path "must be a string"], Nothing)

-- | The cross-references a shape-valid file must still satisfy: every agent
-- declared, every assignment applicable and inside its provider's declared
-- catalog, and every loaded (role, provider) cell valued.
validateRoster ::
  Maybe [Text] ->
  Map ProviderName ProviderCatalog ->
  Map (RoleName, ProviderName) Assignment ->
  [(RoleName, ProviderName)] ->
  [RosterDefect]
validateRoster agents providers assignments presentCells =
  agentDefects <> cellDefects <> membershipDefects <> missingDefects
  where
    agentNames = fromMaybe (map providerKey allProviders) agents
    agentDefects =
      [ UndeclaredAgent name
      | name <- uniqueInOrder agentNames,
        maybe True (`Map.notMember` providers) (parseProviderKey name)
      ]
    cellDefects = concatMap checkCell presentCells
    checkCell (role, provider)
      | provider `notElem` roleApplicability role = [InapplicableAssignment role provider]
      | Map.notMember provider providers = [UndeclaredAssignmentProvider role provider]
      | otherwise = []
    membershipDefects = concatMap checkMembership (Map.toList assignments)
    checkMembership ((role, provider), assignment) = case Map.lookup provider providers of
      Just catalog
        | provider `elem` roleApplicability role ->
            [ UnknownModel role provider assignment.assignmentModel
            | assignment.assignmentModel `notElem` catalog.catalogModels
            ]
              <> [ UnknownEffort role provider assignment.assignmentEffort
                 | assignment.assignmentEffort `notElem` catalog.catalogEfforts
                 ]
      _ -> []
    missingDefects =
      [ MissingAssignment role provider
      | role <- allRoles,
        provider <- roleApplicability role,
        provider `elem` loadedProviders agents,
        (role, provider) `notElem` presentCells
      ]

duplicatedEntries :: [Text] -> [Text]
duplicatedEntries names =
  Map.keys (Map.filter (> (1 :: Int)) (Map.fromListWith (+) [(name, 1) | name <- names]))

uniqueInOrder :: [Text] -> [Text]
uniqueInOrder = go []
  where
    go _ [] = []
    go seen (name : rest)
      | name `elem` seen = go seen rest
      | otherwise = name : go (name : seen) rest

--------------------------------------------------------------------------------
-- Encoding

-- | Render a roster back to TOML. Decoding what this produces yields the
-- same roster — the round trip a test holds — and the @agents@ list is
-- always written out, so a roster that happened to equal the default set
-- survives re-reading unchanged.
encodeRoster :: ModelRoster -> Text
encodeRoster roster = Text.pack (show (Toml.prettyToml (rosterTable roster))) <> "\n"

rosterTable :: ModelRoster -> Toml.Table
rosterTable roster =
  table
    [ "schema_version" .= rosterSchemaVersion,
      "agents" .= map providerKey roster.rosterAgents,
      "providers"
        .= table
          [ providerKey provider .= catalogTable catalog
          | (provider, catalog) <- Map.toList roster.rosterProviders
          ],
      "roles" .= rolesTable roster.rosterAssignments
    ]

catalogTable :: ProviderCatalog -> Toml.Table
catalogTable catalog =
  table
    [ "models" .= catalog.catalogModels,
      "efforts" .= catalog.catalogEfforts
    ]

rolesTable :: Map (RoleName, ProviderName) Assignment -> Toml.Table
rolesTable assignments =
  table
    [ roleKey role
        .= table
          [ providerKey provider .= assignmentTable assignment
          | ((cellRole, provider), assignment) <- Map.toList assignments,
            cellRole == role
          ]
    | role <- allRoles,
      any (\(cellRole, _) -> cellRole == role) (Map.keys assignments)
    ]

assignmentTable :: Assignment -> Toml.Table
assignmentTable assignment =
  table
    [ "model" .= assignment.assignmentModel,
      "effort" .= assignment.assignmentEffort,
      "display" .= assignment.assignmentDisplay
    ]

--------------------------------------------------------------------------------
-- The file

-- | @models.toml@ under the XDG configuration root, beside @config.toml@
-- and @settings.json@ (D-4).
rosterPath :: IO FilePath
rosterPath = do
  configRoot <- getXdgDirectory XdgConfig "kanban"
  pure (configRoot </> "models.toml")

-- | Load the user roster, or the compiled defaults when no file exists.
--
-- Absence is judged by @lstat@ rather than a file-existence probe: a
-- dangling symbolic link or a directory at the path is present but
-- unusable, and D-3 requires that to be a typed refusal, never a silent
-- fall-through to the defaults an existence probe would produce. Once
-- something is present, the resolved target must additionally be a regular
-- file /before/ any open: opening is not a safe probe here, because a FIFO
-- blocks the reader until a writer connects, which would hang startup
-- rather than refuse. A symbolic link to a regular file resolves through
-- the same @stat@ and stays loadable.
loadModelRoster :: IO (Either RosterLoadError ModelRoster)
loadModelRoster = do
  path <- rosterPath
  let unreadable message = pure (Left (RosterLoadError path (RosterUnreadable message)))
  presence <- try @IOException (getSymbolicLinkStatus path)
  case presence of
    Left exception
      | isDoesNotExistError exception -> pure (Right defaultRoster)
      | otherwise -> unreadable (Text.pack (show exception))
    Right _ -> do
      resolved <- try @IOException (getFileStatus path)
      case resolved of
        Left exception -> unreadable (Text.pack (show exception))
        Right status
          | not (isRegularFile status) -> unreadable "not a regular file"
          | otherwise -> do
              readResult <- try @IOException (ByteString.readFile path)
              pure $ case readResult of
                Left exception -> Left (RosterLoadError path (RosterUnreadable (Text.pack (show exception))))
                Right bytes -> case Encoding.decodeUtf8' bytes of
                  Left unicodeError ->
                    Left (RosterLoadError path (RosterUnparseable ("not UTF-8: " <> Text.pack (show unicodeError))))
                  Right contents ->
                    either (Left . RosterLoadError path) Right (decodeRoster contents)

-- | Atomic save with the same private-directory, temporary-file, @0600@,
-- rename discipline 'Kanban.Settings.saveSettings' established.
saveModelRoster :: ModelRoster -> IO (Either Text ())
saveModelRoster roster = do
  path <- rosterPath
  let directory = takeDirectory path
  result <- try @IOException $ do
    createPrivateDirectory XdgConfig directory
    bracketOnError
      (openBinaryTempFile directory (takeFileName path <> ".tmp"))
      cleanup
      ( \(temporaryPath, handle) -> do
          ByteString.hPut handle (Encoding.encodeUtf8 (encodeRoster roster))
          hClose handle
          setFileMode temporaryPath 0o600
          renameFile temporaryPath path
          setFileMode path 0o600
      )
  pure $ case result of
    Left exception -> Left ("model roster write failed: " <> Text.pack (show exception))
    Right () -> Right ()

cleanup :: (FilePath, Handle) -> IO ()
cleanup (path, handle) = do
  _ <- try @IOException (hClose handle)
  _ <- try @IOException (removeFile path)
  pure ()
