-- | The one place Kanban knows how to build a provider's agent-session
-- processes.
--
-- Before MODEL-12 the four flow modules each constructed their own:
-- "Kanban.Solve" and "Kanban.PullRequestFlow" mapped a 'SolverBrand' to an
-- executable name inline, "Kanban.Review" applied 'proc' to a literal
-- @codex@, and "Kanban.Review.Tools" resolved a literal @claude@. Four
-- spellings of the same mapping is how a fifth spawn site comes to disagree
-- with the other four, so the mapping is stated once here and every flow
-- module reads it back off 'adapterFor'.
--
-- The module sits above "Kanban.Models" and the domain and brand types and
-- below the flow modules that consume it: 'Kanban.Models' stays a pure
-- schema and data module with no process vocabulary of its own, and no
-- existing dependency direction inverts. It is an internal seam under
-- @other-modules@; the helpers it took over from "Kanban.Solve" are still
-- exported from that facade.
--
-- What varies per provider is the record's fields, not the code around
-- them. That is deliberate: the external provider plugin system this arc
-- ends in populates the same record from a manifest at load time instead of
-- compiling it in, and a record whose values were reached through a @case@
-- on 'ProviderName' could not be populated that way at all.
--
-- Three launchers stay outside this interface by decision (D-13) and are
-- unchanged: "Kanban.Ping" is modelless, and "Kanban.Codex" and
-- "Kanban.Claude" are usage probes that read account status. So is
-- "Kanban.Preflight.Environment", the readiness probe that runs
-- @\<provider\> --version@ before any session starts. None of the four is an
-- agent session and none consumes a roster value.
module Kanban.ProviderAdapter
  ( EmbeddedReviewBackend (..),
    ProcessRequest (..),
    ProviderAdapter (..),
    ReviewProcessShape (..),
    adapterFor,
    adapterForBrand,
    brandForProvider,
    providerForBrand,
  )
where

import Data.Aeson (Value)
import Data.Text (Text)
import Kanban.Domain (WorkflowConfig)
import Kanban.Models (ModelRoster, ProviderName (..))
import Kanban.Review.Prompts (claudeTool, githubTool, questionTool)
import Kanban.Solve.Event (SolverBrand (..))
import System.Process
  ( CreateProcess (..),
    StdStream (CreatePipe, NoStream),
    proc,
  )

-- | What a spawn site supplies that is not the provider's own: the
-- executable path it resolved, the argv it built for this invocation, and
-- the directory the process runs in.
--
-- Argv stays the caller's because it is the /invocation's/ vocabulary rather
-- than the provider's — 'Kanban.Solve.solveArguments' and
-- 'Kanban.PullRequestFlow.pullRequestArguments' already dispatch on brand
-- and are pinned by tests that must not move. What the adapter owns is the
-- executable that argv is handed to and the stream, working-directory, and
-- process-group shape it is handed under.
data ProcessRequest = ProcessRequest
  { requestExecutable :: FilePath,
    requestArguments :: [String],
    requestWorkingDirectory :: FilePath
  }
  deriving stock (Eq, Show)

-- | How many provider processes a backend's review threads occupy.
--
-- @codex app-server@ multiplexes every thread onto one process, so a client
-- on it holds one connection for its whole life. A @claude@ process is a
-- single conversation (D-15), so a backend built on it needs one connection
-- per review thread. The client reads this to decide whether starting a
-- review reuses the connection it has or spawns another, and whether one
-- connection ending is the whole client ending or just that thread's.
data ReviewProcessShape
  = -- | One process serves every review thread.
    SharedProcess
  | -- | Each review thread gets a process of its own.
    ProcessPerThread
  deriving stock (Eq, Show)

-- | How one provider's embedded issue-review backend is started.
--
-- Only Codex has one. Claude's is 'Nothing' until MODEL-13 fills it, which
-- reproduces today's Codex-only behavior exactly: nothing in this slice
-- routes the embedded review to Claude, so no install's behavior moves.
--
-- The backend names its own process rather than being handed one, because
-- unlike the three agent-session processes it resolves no executable first:
-- @codex@ goes to 'proc' directly and 'System.Process' does the PATH lookup,
-- which is the resolution timing this extraction had to preserve.
data EmbeddedReviewBackend = EmbeddedReviewBackend
  { backendLabel :: Text,
    backendProcess :: FilePath -> CreateProcess,
    backendProcessShape :: ReviewProcessShape
  }

-- | Everything Kanban needs to construct one provider's agent-session
-- processes. Selecting a provider is 'adapterFor' and nothing else.
data ProviderAdapter = ProviderAdapter
  { adapterProvider :: ProviderName,
    -- | The executable name this provider maps to, as a spawn site passes it
    -- to @findExecutable@ and as a refusal names it on PATH.
    adapterExecutable :: String,
    -- | The streamed session a solve runs as.
    adapterSolveProcess :: ProcessRequest -> CreateProcess,
    -- | The streamed session a pull-request action runs as.
    adapterPullRequestProcess :: ProcessRequest -> CreateProcess,
    -- | The one-shot call a revision agent runs as. Stated for both
    -- providers because the record is what a load-time manifest would
    -- populate, not because both are invoked: today only Claude's is, by
    -- @kanban_run_claude@.
    adapterRevisionProcess :: ProcessRequest -> CreateProcess,
    -- | How this provider's embedded issue review is started, or 'Nothing'
    -- where Kanban ships no backend for it.
    adapterEmbeddedReview :: Maybe EmbeddedReviewBackend,
    -- | The dynamic tools this provider's embedded review registers, in the
    -- order the backend is given them. Empty for a provider with no backend:
    -- there is no thread to register them on.
    adapterReviewTools :: ModelRoster -> WorkflowConfig -> [Value]
  }

-- | The compiled adapter for a provider.
adapterFor :: ProviderName -> ProviderAdapter
adapterFor CodexProvider = codexAdapter
adapterFor ClaudeProvider = claudeAdapter

-- | 'adapterFor' reached through the brand a spawn site already holds.
adapterForBrand :: SolverBrand -> ProviderAdapter
adapterForBrand = adapterFor . providerForBrand

-- | Which provider's compiled adapter a solver brand runs through. The one
-- mapping between the two vocabularies: 'SolverBrand' names the executable
-- this layer spawns, 'ProviderName' names the roster table it reads.
providerForBrand :: SolverBrand -> ProviderName
providerForBrand CodexSolver = CodexProvider
providerForBrand ClaudeSolver = ClaudeProvider

-- | 'providerForBrand' read the other way, which is what a replayed launch
-- needs: a recorded assignment names the provider it was resolved for, and
-- the supervisor has to reach the executable that provider's adapter spawns
-- without re-deriving it from the task's own routing (D-7).
brandForProvider :: ProviderName -> SolverBrand
brandForProvider CodexProvider = CodexSolver
brandForProvider ClaudeProvider = ClaudeSolver

codexAdapter :: ProviderAdapter
codexAdapter =
  ProviderAdapter
    { adapterProvider = CodexProvider,
      adapterExecutable = "codex",
      adapterSolveProcess = agentSessionProcess,
      adapterPullRequestProcess = agentSessionProcess,
      adapterRevisionProcess = oneShotProcess,
      adapterEmbeddedReview = Just codexEmbeddedReview,
      adapterReviewTools = \roster config -> [questionTool, claudeTool roster, githubTool config]
    }

claudeAdapter :: ProviderAdapter
claudeAdapter =
  ProviderAdapter
    { adapterProvider = ClaudeProvider,
      adapterExecutable = "claude",
      adapterSolveProcess = agentSessionProcess,
      adapterPullRequestProcess = agentSessionProcess,
      adapterRevisionProcess = oneShotProcess,
      adapterEmbeddedReview = Nothing,
      adapterReviewTools = \_ _ -> []
    }

codexEmbeddedReview :: EmbeddedReviewBackend
codexEmbeddedReview =
  EmbeddedReviewBackend
    { backendLabel = "codex app-server",
      backendProcessShape = SharedProcess,
      backendProcess = \repositoryRoot ->
        (proc "codex" ["app-server", "--listen", "stdio://"])
          { cwd = Just repositoryRoot,
            std_in = CreatePipe,
            std_out = CreatePipe,
            std_err = CreatePipe,
            create_group = True
          }
    }

-- | A long-running agent session: stdout and stderr are read as they arrive,
-- stdin is closed so a provider that prompted would fail rather than block,
-- and the process leads its own group so a cancellation reaches its
-- children.
agentSessionProcess :: ProcessRequest -> CreateProcess
agentSessionProcess request =
  (proc request.requestExecutable request.requestArguments)
    { cwd = Just request.requestWorkingDirectory,
      std_in = NoStream,
      std_out = CreatePipe,
      std_err = CreatePipe,
      create_group = True
    }

-- | A one-shot call whose prompt is written to stdin and whose output is
-- captured whole, rather than streamed.
oneShotProcess :: ProcessRequest -> CreateProcess
oneShotProcess request =
  (proc request.requestExecutable request.requestArguments)
    { cwd = Just request.requestWorkingDirectory,
      std_in = CreatePipe,
      std_out = CreatePipe,
      std_err = CreatePipe,
      create_group = True
    }
