-- | The per-provider adapter record every agent-session spawn now goes
-- through (MODEL-12).
--
-- The four flow modules used to construct their own provider processes, so
-- the mapping from brand to executable was written four times and could be
-- written a fifth. What replaces them is a compiled record per provider, and
-- what is proved here is the record itself rather than the spawn sites that
-- read it: the roster's provider set and the adapter table are the same set,
-- a lookup answers with the record that names the provider it was asked for,
-- and each of the three agent-session process shapes comes back byte-for-byte
-- as the flow module that used to build it did.
--
-- The embedded review is the one asymmetric field. Codex carries the
-- app-server backend that "Kanban.Review" relocated; Claude carries
-- 'Nothing' until MODEL-13, and the refusal that absence produces is pinned
-- beside it so the slot cannot quietly become a fallback.
--
-- What a spawn site does with the record — resolving the executable,
-- masking the spawn, registering the managed process — is covered where it
-- always was, in "Spec.Agent.Solve", "Spec.Agent.PullRequestFlow", and
-- "Spec.Agent.Roster". Nothing moved here.
module Spec.Agent.Adapter (spec) where

import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Text (Text)
import Kanban.Domain (defaultWorkflowConfig)
import Kanban.Models (ProviderName (..), allProviders, defaultRoster)
import Kanban.Review
  ( EmbeddedReviewBackend (..),
    claudeTool,
    embeddedReviewProvider,
    missingEmbeddedReviewMessage,
  )
import Kanban.Solve
  ( ProcessRequest (..),
    ProviderAdapter (..),
    SolverBrand (..),
    adapterFor,
    adapterForBrand,
  )
import System.Process (CmdSpec (..), CreateProcess (..), StdStream (..))
import Test.Hspec

-- | One invocation's worth of caller-supplied inputs. Deliberately not a
-- real argv: what the adapter owns is the shape the argv is handed under,
-- and a fixture that could be mistaken for a provider's own vocabulary would
-- make an argv regression look like an adapter regression.
request :: ProcessRequest
request =
  ProcessRequest
    { requestExecutable = "/opt/bin/agent",
      requestArguments = ["--first", "second"],
      requestWorkingDirectory = "/tmp/worktree"
    }

-- | The fields a spawn site depends on, read off a built spec. Gathered into
-- one tuple so a single 'shouldBe' reports every difference at once rather
-- than stopping at the first field that moved.
shape :: CreateProcess -> (CmdSpec, Maybe FilePath, StdStream, StdStream, StdStream, Bool)
shape spec' =
  ( spec'.cmdspec,
    spec'.cwd,
    spec'.std_in,
    spec'.std_out,
    spec'.std_err,
    spec'.create_group
  )

toolNames :: [Value] -> [Maybe Text]
toolNames = map name
  where
    name (Object fields) = case KeyMap.lookup (Key.fromString "name") fields of
      Just (String value) -> Just value
      _ -> Nothing
    name _ = Nothing

spec :: Spec
spec = do
  describe "the adapter table" $ do
    it "holds exactly one record per roster provider, each naming itself" $
      map (adapterProvider . adapterFor) allProviders `shouldBe` allProviders

    it "maps each provider to the executable that provider's sessions spawn" $
      map (adapterExecutable . adapterFor) allProviders `shouldBe` ["codex", "claude"]

    it "is reached from a solver brand through the same table" $
      map (adapterProvider . adapterForBrand) [CodexSolver, ClaudeSolver]
        `shouldBe` [CodexProvider, ClaudeProvider]

  describe "the agent-session process shapes" $ do
    it "gives a solve the streamed, group-leading, stdin-closed shape both brands had" $
      map (\provider -> shape ((adapterFor provider).adapterSolveProcess request)) allProviders
        `shouldBe` replicate
          (length allProviders)
          ( RawCommand "/opt/bin/agent" ["--first", "second"],
            Just "/tmp/worktree",
            NoStream,
            CreatePipe,
            CreatePipe,
            True
          )

    it "gives a pull-request action the same shape its own flow module built" $
      map (\provider -> shape ((adapterFor provider).adapterPullRequestProcess request)) allProviders
        `shouldBe` map (\provider -> shape ((adapterFor provider).adapterSolveProcess request)) allProviders

    it "gives the one-shot revision an open stdin to write its prompt to" $
      map (\provider -> shape ((adapterFor provider).adapterRevisionProcess request)) allProviders
        `shouldBe` replicate
          (length allProviders)
          ( RawCommand "/opt/bin/agent" ["--first", "second"],
            Just "/tmp/worktree",
            CreatePipe,
            CreatePipe,
            CreatePipe,
            True
          )

  describe "the embedded issue-review backend" $ do
    it "still runs on Codex, which is the only provider carrying one" $ do
      embeddedReviewProvider `shouldBe` CodexProvider
      map (fmap (.backendLabel) . adapterEmbeddedReview . adapterFor) allProviders
        `shouldBe` [Just "codex app-server", Nothing]

    it "starts the app-server exactly as Kanban.Review used to" $
      fmap (\backend -> shape (backend.backendProcess "/tmp/worktree")) ((adapterFor CodexProvider).adapterEmbeddedReview)
        `shouldBe` Just
          ( RawCommand "codex" ["app-server", "--listen", "stdio://"],
            Just "/tmp/worktree",
            CreatePipe,
            CreatePipe,
            CreatePipe,
            True
          )

    it "refuses by name for a provider Kanban ships no backend for" $
      missingEmbeddedReviewMessage ClaudeProvider
        `shouldBe` "Kanban has no embedded issue-review backend for provider \"claude\""

  describe "the dynamic tools a review registers" $ do
    it "registers Codex's three in the order the thread is given them" $
      toolNames ((adapterFor CodexProvider).adapterReviewTools defaultRoster defaultWorkflowConfig)
        `shouldBe` [Just "kanban_prompt_user", Just "kanban_run_claude", Just "kanban_github_issue"]

    it "builds the revision tool from the roster it is handed" $
      (adapterFor CodexProvider).adapterReviewTools defaultRoster defaultWorkflowConfig !! 1
        `shouldBe` claudeTool defaultRoster

    it "registers none for a provider whose backend is absent" $
      (adapterFor ClaudeProvider).adapterReviewTools defaultRoster defaultWorkflowConfig
        `shouldBe` []
