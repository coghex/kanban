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
-- beside it so the slot cannot quietly become a fallback. Its process shape
-- is pinned there too: how many provider processes a backend's review
-- threads occupy is what MODEL-14 made the client read rather than assume,
-- and Codex's answer must not drift while it is the only backend shipped.
--
-- What a spawn site does with the record — resolving the executable,
-- masking the spawn, registering the managed process — is covered where it
-- always was, in "Spec.Agent.Solve", "Spec.Agent.PullRequestFlow", and
-- "Spec.Agent.Roster". Nothing moved here.
module Spec.Agent.Adapter (spec) where

import Data.Aeson (Value (..), encode)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Domain (defaultWorkflowConfig)
import Kanban.Models (Assignment (..), ProviderName (..), RoleName (..), allProviders, assignmentFor, defaultRoster)
import Kanban.Review
  ( EmbeddedReviewBackend (..),
    ReviewLaunch (..),
    ReviewProcessShape (..),
    ReviewProtocol (..),
    claudeReviewArguments,
    claudeTool,
    embeddedReviewProvider,
    finalOutputSchema,
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

-- | The @issue_review@ cell each backend's launch is handed. Read out of the
-- roster rather than written here, so a default that moves moves with it.
reviewCell :: Assignment
reviewCell = cellFor CodexProvider

claudeReviewCell :: Assignment
claudeReviewCell = cellFor ClaudeProvider

cellFor :: ProviderName -> Assignment
cellFor provider = case assignmentFor defaultRoster IssueReviewRole provider of
  Right assignment -> assignment
  Left unavailable -> error ("the default roster has no issue_review cell: " <> show unavailable)

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
    -- Requirement 9: Claude now carries a backend, and yet nothing routes to
    -- it. Both halves are asserted together, because the second is the whole
    -- promise this slice makes about an install's behavior and the first is
    -- what would otherwise quietly break it.
    it "carries one for each provider while still running every install's review on Codex" $ do
      embeddedReviewProvider `shouldBe` CodexProvider
      map (fmap (.backendLabel) . adapterEmbeddedReview . adapterFor) allProviders
        `shouldBe` [Just "codex app-server", Just "claude stream-json session"]
      map (fmap (.backendProvider) . adapterEmbeddedReview . adapterFor) allProviders
        `shouldBe` [Just CodexProvider, Just ClaudeProvider]

    it "starts the app-server exactly as Kanban.Review used to" $
      fmap (\backend -> shape (backend.backendProcess (ReviewLaunch "/tmp/worktree" reviewCell))) ((adapterFor CodexProvider).adapterEmbeddedReview)
        `shouldBe` Just
          ( RawCommand "codex" ["app-server", "--listen", "stdio://"],
            Just "/tmp/worktree",
            CreatePipe,
            CreatePipe,
            CreatePipe,
            True
          )

    -- Requirement 2: the launch carries the resolved assignment, and Codex
    -- ignores it. Its model and effort travel in `thread/start` and
    -- `turn/start` instead, so a launch resolved from a different cell must
    -- produce byte-identical argv.
    it "leaves Codex's argv untouched by the assignment the launch carries" $
      let launchedWith assignment =
            fmap (\backend -> cmdspec (backend.backendProcess (ReviewLaunch "/tmp/worktree" assignment))) ((adapterFor CodexProvider).adapterEmbeddedReview)
       in launchedWith (Assignment "someone-elses-model" "none" "someone else")
            `shouldBe` launchedWith reviewCell

    -- Requirement 1 and the review's launch clause: the whole argv, because
    -- every flag in it is load-bearing and a partial assertion would let one
    -- of them be dropped. Requirement 3's other half is the process shape it
    -- is handed under, which is Codex's exactly.
    it "launches Claude on the CLI's stream-json channel, hermetically, on the roster's cell" $
      fmap (\backend -> shape (backend.backendProcess (ReviewLaunch "/tmp/worktree" claudeReviewCell))) ((adapterFor ClaudeProvider).adapterEmbeddedReview)
        `shouldBe` Just
          ( RawCommand
              "claude"
              [ "-p",
                "--verbose",
                "--input-format",
                "stream-json",
                "--output-format",
                "stream-json",
                "--include-partial-messages",
                "--json-schema",
                LazyByteString.unpack (encode finalOutputSchema),
                "--strict-mcp-config",
                "--tools",
                "",
                "--model",
                Text.unpack claudeReviewCell.assignmentModel,
                "--effort",
                Text.unpack claudeReviewCell.assignmentEffort
              ],
            Just "/tmp/worktree",
            CreatePipe,
            CreatePipe,
            CreatePipe,
            True
          )

    it "carries the roster's own model and effort rather than a compiled pair" $
      dropWhile (/= "--model") (claudeReviewArguments (Assignment "rerostered-model" "rerostered-effort" "rerostered"))
        `shouldBe` ["--model", "rerostered-model", "--effort", "rerostered-effort"]

    -- MODEL-14: the client reads this to decide whether starting a review
    -- reuses the connection it has or spawns another, and whether one
    -- connection ending is the whole client ending. Codex multiplexes every
    -- review thread onto one @app-server@; a @claude@ process is a single
    -- conversation (D-15), so its backend takes one per review thread.
    it "declares how many processes each backend's review threads occupy" $
      map (fmap (.backendProcessShape) . adapterEmbeddedReview . adapterFor) allProviders
        `shouldBe` [Just SharedProcess, Just ProcessPerThread]

    -- Requirement 3: the client performs a handshake for a backend that
    -- needs one and none for a backend that does not, and it reads that off
    -- the backend rather than off the provider.
    it "declares which channel each backend is spoken over" $
      map (fmap (.backendProtocol) . adapterEmbeddedReview . adapterFor) allProviders
        `shouldBe` [Just AppServerProtocol, Just StreamJsonProtocol]

    -- Both compiled providers now carry a backend, so nothing an install can
    -- route to reaches this refusal. It stays because 'adapterEmbeddedReview'
    -- is a field a provider may lack, and the launch that reads it must say
    -- so by name rather than silently doing nothing.
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

    -- Claude's are served over MCP rather than declared inline (D-15), which
    -- is MODEL-15's; until then its review thread registers nothing, so it
    -- produces no tool-call event of any kind.
    it "registers none for a provider whose backend declares none" $
      (adapterFor ClaudeProvider).adapterReviewTools defaultRoster defaultWorkflowConfig
        `shouldBe` []
