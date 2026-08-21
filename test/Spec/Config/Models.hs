-- | The model roster: compiled defaults, the tracked example, the TOML
-- round trip, the D-3 validation matrix — one asserted arm per cause — and
-- the XDG file the roster loads from and saves to.
module Spec.Config.Models (spec) where

import qualified Data.ByteString.Char8 as ByteString
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Kanban.Models
  ( Assignment (..),
    ModelRoster (..),
    ProviderCatalog (..),
    ProviderName (..),
    RoleName (..),
    RosterDefect (..),
    RosterFailure (..),
    RosterLoadError (..),
    allProviders,
    allRoles,
    decodeRoster,
    defaultRoster,
    encodeRoster,
    loadModelRoster,
    roleApplicability,
    rosterErrorMessage,
    rosterPath,
    saveModelRoster,
  )
import Spec.Support.Env (permissionsOf, withEnvironmentValue, withTemporaryCacheRoot)
import System.Directory (createDirectory, createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)
import System.Posix.Files (createNamedPipe, createSymbolicLink)
import Test.Hspec

spec :: Spec
spec = do
  describe "compiled defaults" $ do
    it "load both providers, in order, with the exact catalogs" $ do
      defaultRoster.rosterAgents `shouldBe` [CodexProvider, ClaudeProvider]
      Map.lookup CodexProvider defaultRoster.rosterProviders
        `shouldBe` Just
          (ProviderCatalog ["gpt-5.4", "gpt-5.5", "gpt-5.6-terra", "gpt-5.6-sol"] ["minimal", "low", "medium", "high", "xhigh"])
      Map.lookup ClaudeProvider defaultRoster.rosterProviders
        `shouldBe` Just
          (ProviderCatalog ["claude-sonnet-5", "claude-opus-5", "claude-fable-5"] ["low", "medium", "high", "xhigh"])

    -- Each cell asserted on its own rather than only through the
    -- defaults-equal-example invariant, so a mistake made identically in
    -- both artifacts still fails here.
    it "value all thirteen applicable cells with today's wire literals" $ do
      Map.size defaultRoster.rosterAssignments `shouldBe` 13
      let cell role provider = Map.lookup (role, provider) defaultRoster.rosterAssignments
          expectations =
            [ (SolveRole, CodexProvider, Assignment "gpt-5.4" "high" "gpt-5.4 high"),
              (SolveRole, ClaudeProvider, Assignment "claude-sonnet-5" "high" "Sonnet 5 high"),
              (PrReviewRole, CodexProvider, Assignment "gpt-5.6-terra" "xhigh" "GPT-5.6-Terra xhigh"),
              (PrReviewRole, ClaudeProvider, Assignment "claude-opus-5" "xhigh" "Opus 5 xhigh"),
              (PrReviseRole, CodexProvider, Assignment "gpt-5.4" "high" "gpt-5.4 high"),
              (PrReviseRole, ClaudeProvider, Assignment "claude-sonnet-5" "xhigh" "Sonnet 5 xhigh"),
              (IssueReviewRole, CodexProvider, Assignment "gpt-5.4" "high" "gpt-5.4 high"),
              (IssueReviewRole, ClaudeProvider, Assignment "claude-opus-5" "xhigh" "Opus 5 xhigh"),
              (IssueReviseRole, ClaudeProvider, Assignment "claude-sonnet-5" "high" "Sonnet 5 high"),
              (IssueGateRole, CodexProvider, Assignment "gpt-5.6-sol" "xhigh" "GPT-5.6-Sol xhigh"),
              (IssueGateRole, ClaudeProvider, Assignment "claude-opus-5" "xhigh" "Opus 5 xhigh"),
              (DrainRereviewRole, CodexProvider, Assignment "gpt-5.6-terra" "medium" "GPT-5.6-Terra medium"),
              (DrainRereviewRole, ClaudeProvider, Assignment "claude-opus-5" "medium" "Opus 5 medium")
            ]
      mapM_
        (\(role, provider, assignment) -> cell role provider `shouldBe` Just assignment)
        expectations

    it "keep issue_revise Claude-only, with no Codex cell to consult" $ do
      roleApplicability IssueReviseRole `shouldBe` [ClaudeProvider]
      Map.member (IssueReviseRole, CodexProvider) defaultRoster.rosterAssignments `shouldBe` False
      mapM_
        (\role -> roleApplicability role `shouldBe` allProviders)
        (filter (/= IssueReviseRole) allRoles)

  describe "the tracked example" $ do
    it "decodes to exactly the compiled defaults" $ do
      contents <- TextIO.readFile "models.toml.example"
      decodeRoster contents `shouldBe` Right defaultRoster

    -- The one absence in the schema that is a default rather than a defect:
    -- dropping the agents line from a complete file still loads both
    -- providers (D-10).
    it "still decodes to the defaults with its agents line removed" $ do
      contents <- TextIO.readFile "models.toml.example"
      let withoutAgents = Text.unlines (filter (not . Text.isPrefixOf "agents") (Text.lines contents))
      decodeRoster withoutAgents `shouldBe` Right defaultRoster

  describe "the round trip" $ do
    it "is identity for the defaults" $
      decodeRoster (encodeRoster defaultRoster) `shouldBe` Right defaultRoster

    it "is identity for an edited roster" $ do
      let edited =
            defaultRoster
              { rosterAssignments =
                  Map.insert
                    (SolveRole, CodexProvider)
                    (Assignment "gpt-5.6-sol" "minimal" "GPT-5.6-Sol minimal")
                    defaultRoster.rosterAssignments
              }
      decodeRoster (encodeRoster edited) `shouldBe` Right edited

    it "is identity for a single-agent roster" $
      decodeRoster (encodeRoster singleClaudeRoster) `shouldBe` Right singleClaudeRoster

    it "is identity for an empty agents list, the no-agent headroom" $ do
      let noAgents = defaultRoster {rosterAgents = []}
      decodeRoster (encodeRoster noAgents) `shouldBe` Right noAgents

  describe "validation" $ do
    it "rejects a model absent from its provider's list" $
      decodeRoster (encodeRoster (withSolveCodex (\cell -> cell {assignmentModel = "gpt-9"})))
        `shouldBe` Left (RosterInvalid [UnknownModel SolveRole CodexProvider "gpt-9"])

    it "rejects an effort outside its provider's vocabulary" $
      decodeRoster (encodeRoster (withSolveCodex (\cell -> cell {assignmentEffort = "ultra"})))
        `shouldBe` Left (RosterInvalid [UnknownEffort SolveRole CodexProvider "ultra"])

    it "rejects a missing assignment for a loaded provider the role applies to" $ do
      let missing = defaultRoster {rosterAssignments = Map.delete (SolveRole, CodexProvider) defaultRoster.rosterAssignments}
      decodeRoster (encodeRoster missing)
        `shouldBe` Left (RosterInvalid [MissingAssignment SolveRole CodexProvider])

    it "rejects an assignment for a provider the role cannot run on" $ do
      let inapplicable =
            defaultRoster
              { rosterAssignments =
                  Map.insert
                    (IssueReviseRole, CodexProvider)
                    (Assignment "gpt-5.4" "high" "gpt-5.4 high")
                    defaultRoster.rosterAssignments
              }
      decodeRoster (encodeRoster inapplicable)
        `shouldBe` Left (RosterInvalid [InapplicableAssignment IssueReviseRole CodexProvider])

    it "rejects an agents entry naming an undeclared provider" $ do
      let undeclared = defaultRoster {rosterProviders = Map.delete CodexProvider defaultRoster.rosterProviders}
      decodeRoster (encodeRoster undeclared) `shouldSatisfy` hasDefect (UndeclaredAgent "codex")

    it "rejects a repeated agents entry: the list is set-valued" $ do
      let repeated = defaultRoster {rosterAgents = [CodexProvider, ClaudeProvider, CodexProvider]}
      decodeRoster (encodeRoster repeated)
        `shouldBe` Left (RosterInvalid [DuplicateEntry "agents" "codex"])

    it "accepts a single-agent roster carrying only that provider" $
      decodeRoster (encodeRoster singleClaudeRoster) `shouldBe` Right singleClaudeRoster

    it "rejects an assignment for a known provider the file never declares" $ do
      let strayCodex =
            singleClaudeRoster
              { rosterAssignments =
                  Map.insert
                    (SolveRole, CodexProvider)
                    (Assignment "gpt-5.4" "high" "gpt-5.4 high")
                    singleClaudeRoster.rosterAssignments
              }
      decodeRoster (encodeRoster strayCodex)
        `shouldBe` Left (RosterInvalid [UndeclaredAssignmentProvider SolveRole CodexProvider])

    -- A present file is a complete roster (D-3 as reviewed): a version line
    -- alone is not a sparse patch over the defaults.
    it "rejects an empty version-1 file rather than patching the defaults" $ do
      let result = decodeRoster "schema_version = 1\n"
      result `shouldSatisfy` hasDefect (UndeclaredAgent "codex")
      result `shouldSatisfy` hasDefect (UndeclaredAgent "claude")
      result `shouldSatisfy` hasDefect (MissingAssignment SolveRole CodexProvider)

    it "rejects an unknown role key instead of skipping it" $
      decodeRoster (minimalPreamble <> cellTable "roles.pr_reveiw.codex")
        `shouldBe` Left (RosterInvalid [UnknownRoleKey "roles.pr_reveiw"])

    it "rejects an unknown provider key under a role" $
      decodeRoster (minimalPreamble <> cellTable "roles.pr_review.gemini")
        `shouldBe` Left (RosterInvalid [UnknownProviderKey "roles.pr_review.gemini"])

    it "rejects an unknown provider declaration" $
      decodeRoster (minimalPreamble <> "[providers.gemini]\nmodels = [\"g-1\"]\nefforts = [\"low\"]\n")
        `shouldBe` Left (RosterInvalid [UnknownProviderKey "providers.gemini"])

    -- The review's own example: a misspelled `agent` key must not be
    -- ignored merely because the absent `agents` key has a default.
    it "rejects an unknown top-level key" $
      decodeRoster "schema_version = 1\nagents = []\nagent = [\"codex\"]\n"
        `shouldBe` Left (RosterInvalid [UnknownKey "agent"])

    it "rejects an unknown key inside a provider table" $
      decodeRoster (minimalPreamble <> "executable = \"codex\"\n")
        `shouldBe` Left (RosterInvalid [UnknownKey "providers.codex.executable"])

    it "rejects an unknown key inside an assignment" $
      decodeRoster (minimalPreamble <> cellTable "roles.pr_review.codex" <> "note = \"x\"\n")
        `shouldBe` Left (RosterInvalid [UnknownKey "roles.pr_review.codex.note"])

    it "rejects an assignment missing one of its three fields" $ do
      let withoutDisplay =
            Text.unlines
              [ "[roles.pr_review.codex]",
                "model = \"gpt-5.4\"",
                "effort = \"high\""
              ]
      decodeRoster (minimalPreamble <> withoutDisplay)
        `shouldBe` Left (RosterInvalid [MissingKey "roles.pr_review.codex.display"])

    it "rejects an agents value that is not an array of strings" $
      decodeRoster "schema_version = 1\nagents = \"codex\"\n"
        `shouldBe` Left (RosterInvalid [InvalidValue "agents" "must be an array of provider-name strings"])

    it "rejects an empty models list" $
      decodeRoster "schema_version = 1\nagents = []\n[providers.codex]\nmodels = []\nefforts = [\"high\"]\n"
        `shouldBe` Left (RosterInvalid [InvalidValue "providers.codex.models" "must be a non-empty array of model IDs"])

    it "rejects a repeated models entry" $
      decodeRoster "schema_version = 1\nagents = []\n[providers.codex]\nmodels = [\"gpt-5.4\", \"gpt-5.4\"]\nefforts = [\"high\"]\n"
        `shouldBe` Left (RosterInvalid [DuplicateEntry "providers.codex.models" "gpt-5.4"])

    it "rejects a missing schema version" $
      decodeRoster "agents = []\n" `shouldBe` Left (RosterInvalid [MissingKey "schema_version"])

    it "rejects a schema version that is not an integer" $
      decodeRoster "schema_version = \"1\"\n"
        `shouldBe` Left (RosterInvalid [InvalidValue "schema_version" "must be an integer"])

    -- A foreign version is judged on the version alone: the payload beside
    -- it belongs to another schema and gets no further verdicts.
    it "rejects a foreign schema version without validating its payload" $
      decodeRoster "schema_version = 2\nagent = [\"nonsense\"]\n"
        `shouldBe` Left (RosterForeignVersion 2)

    it "rejects text that is not TOML" $
      decodeRoster "[" `shouldSatisfy` \result -> case result of
        Left (RosterUnparseable _) -> True
        _ -> False

  describe "the roster file" $ do
    it "is silently the compiled defaults when absent" $
      withRosterEnvironment $ \_ ->
        loadModelRoster `shouldReturn` Right defaultRoster

    it "saves atomically under the XDG configuration root at 0600 and loads back" $
      withRosterEnvironment $ \configRoot -> do
        saveModelRoster singleClaudeRoster `shouldReturn` Right ()
        path <- rosterPath
        path `shouldBe` configRoot </> "kanban" </> "models.toml"
        permissionsOf path `shouldReturn` 0o600
        loadModelRoster `shouldReturn` Right singleClaudeRoster

    it "reports a present defective file as a typed error naming the path" $
      withRosterEnvironment $ \_ -> do
        path <- writeRosterFile "schema_version = 1\nagents = \"codex\"\n"
        loadModelRoster
          `shouldReturn` Left
            (RosterLoadError path (RosterInvalid [InvalidValue "agents" "must be an array of provider-name strings"]))

    it "reports a foreign-version file as a typed error, never silent defaults" $
      withRosterEnvironment $ \_ -> do
        path <- writeRosterFile "schema_version = 99\n"
        loadModelRoster `shouldReturn` Left (RosterLoadError path (RosterForeignVersion 99))

    it "reports unparseable bytes with a message naming the file" $
      withRosterEnvironment $ \_ -> do
        path <- writeRosterFile "not toml ["
        result <- loadModelRoster
        case result of
          Left loadError -> do
            loadError.rosterErrorPath `shouldBe` path
            loadError.rosterErrorFailure `shouldSatisfy` \failure -> case failure of
              RosterUnparseable _ -> True
              _ -> False
            rosterErrorMessage loadError `shouldSatisfy` Text.isInfixOf (Text.pack path)
          Right _ -> expectationFailure "an unparseable file must not load"

    it "reports bytes that are not UTF-8 as unparseable" $
      withRosterEnvironment $ \_ -> do
        path <- writeRosterFile "schema_version = 1\n\xff\xfe"
        result <- loadModelRoster
        result `shouldSatisfy` \answer -> case answer of
          Left (RosterLoadError errorPath (RosterUnparseable _)) -> errorPath == path
          _ -> False

    -- The absent-versus-unusable split (D-3): only a path with nothing at
    -- all behind it is absent. A directory or a dangling link is present
    -- and broken, and must refuse rather than quietly load the defaults.
    it "treats a directory at the path as unreadable, not absent" $
      withRosterEnvironment $ \_ -> do
        path <- rosterPath
        createDirectoryIfMissing True (takeDirectory path)
        createDirectory path
        result <- loadModelRoster
        result `shouldSatisfy` \answer -> case answer of
          Left (RosterLoadError errorPath (RosterUnreadable _)) -> errorPath == path
          _ -> False

    it "treats a dangling symbolic link at the path as unreadable, not absent" $
      withRosterEnvironment $ \configRoot -> do
        path <- rosterPath
        createDirectoryIfMissing True (takeDirectory path)
        createSymbolicLink (configRoot </> "nowhere") path
        result <- loadModelRoster
        result `shouldSatisfy` \answer -> case answer of
          Left (RosterLoadError errorPath (RosterUnreadable _)) -> errorPath == path
          _ -> False

    -- Refused before any open: a FIFO blocks its reader until a writer
    -- connects, so probing it by reading would hang startup rather than
    -- produce the typed refusal.
    it "treats a FIFO at the path as unreadable, without opening it" $
      withRosterEnvironment $ \_ -> do
        path <- rosterPath
        createDirectoryIfMissing True (takeDirectory path)
        createNamedPipe path 0o600
        result <- loadModelRoster
        result `shouldSatisfy` \answer -> case answer of
          Left (RosterLoadError errorPath (RosterUnreadable _)) -> errorPath == path
          _ -> False

    it "still loads a symbolic link that resolves to a regular file" $
      withRosterEnvironment $ \configRoot -> do
        path <- rosterPath
        createDirectoryIfMissing True (takeDirectory path)
        let target = configRoot </> "real-models.toml"
        TextIO.writeFile target (encodeRoster singleClaudeRoster)
        createSymbolicLink target path
        loadModelRoster `shouldReturn` Right singleClaudeRoster

-- | A valid roster loading Claude alone: claude declared, the seven cells
-- Claude-applicable roles need, and no Codex anywhere.
singleClaudeRoster :: ModelRoster
singleClaudeRoster =
  ModelRoster
    { rosterAgents = [ClaudeProvider],
      rosterProviders = Map.filterWithKey (\provider _ -> provider == ClaudeProvider) defaultRoster.rosterProviders,
      rosterAssignments = Map.filterWithKey (\(_, provider) _ -> provider == ClaudeProvider) defaultRoster.rosterAssignments
    }

withSolveCodex :: (Assignment -> Assignment) -> ModelRoster
withSolveCodex adjust =
  defaultRoster {rosterAssignments = Map.adjust adjust (SolveRole, CodexProvider) defaultRoster.rosterAssignments}

hasDefect :: RosterDefect -> Either RosterFailure ModelRoster -> Bool
hasDefect defect result = case result of
  Left (RosterInvalid defects) -> defect `elem` defects
  _ -> False

-- | A version-1 file loading nothing, declaring one one-model provider for
-- the arms below to reference.
minimalPreamble :: Text
minimalPreamble =
  Text.unlines
    [ "schema_version = 1",
      "agents = []",
      "",
      "[providers.codex]",
      "models = [\"gpt-5.4\"]",
      "efforts = [\"high\"]"
    ]

-- | One well-formed assignment table under the given section header.
cellTable :: Text -> Text
cellTable section =
  Text.unlines
    [ "[" <> section <> "]",
      "model = \"gpt-5.4\"",
      "effort = \"high\"",
      "display = \"gpt-5.4 high\""
    ]

withRosterEnvironment :: (FilePath -> IO result) -> IO result
withRosterEnvironment action =
  withTemporaryCacheRoot $ \configRoot ->
    withEnvironmentValue "XDG_CONFIG_HOME" configRoot (action configRoot)

writeRosterFile :: String -> IO FilePath
writeRosterFile contents = do
  path <- rosterPath
  createDirectoryIfMissing True (takeDirectory path)
  ByteString.writeFile path (ByteString.pack contents)
  pure path
