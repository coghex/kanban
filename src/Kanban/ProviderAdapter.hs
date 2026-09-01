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
    ReviewLaunch (..),
    ReviewProcessShape (..),
    ReviewProtocol (..),
    ReviewToolServerLaunch (..),
    adapterFor,
    adapterForBrand,
    brandForProvider,
    claudeReviewArguments,
    providerForBrand,
  )
where

import Data.Aeson (Value, encode)
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Domain (WorkflowConfig)
import Kanban.Models (Assignment (..), ModelRoster, ProviderName (..))
import Kanban.Review.Prompts (claudeTool, finalOutputSchema, githubTool, githubToolName, questionTool, questionToolName)
import Kanban.ReviewToolServer (mcpToolAllowance, reviewToolServerConfig)
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

-- | Which channel a backend's provider process is spoken over.
--
-- Deliberately a property of the /protocol/ rather than of the provider.
-- Two things about an embedded review differ between the two channels and
-- nothing else does: whether starting a connection completes a handshake
-- before anything may be sent, and how one line of the provider's output is
-- read. The client dispatches on this rather than on 'backendProvider', so
-- a third backend that speaks either channel needs no arm of its own.
data ReviewProtocol
  = -- | @codex app-server@'s JSON-RPC exchange: an @initialize@ \/
    -- @initialized@ handshake, then @thread\/start@ and @turn\/start@
    -- requests correlated by id, and typed notifications back.
    AppServerProtocol
  | -- | The @claude@ CLI's stream-json channel (D-15): no handshake, a turn
    -- opens by writing one user message, and the provider answers with the
    -- JSON records it streams until its result line closes the turn.
    StreamJsonProtocol
  deriving stock (Eq, Show)

-- | How a launch names the re-entered MCP server that will serve this
-- session's Kanban tools (D-15): the exact executable to re-enter — the
-- currently running one, resolved by the client through
-- 'System.Environment.getExecutablePath' exactly as "Kanban.Worker" resolves
-- its supervisor, never a @kanban@ found on PATH — and the directory of the
-- FIFO endpoint the client created for this one review thread.
data ReviewToolServerLaunch = ReviewToolServerLaunch
  { toolServerExecutable :: FilePath,
    toolServerEndpoint :: FilePath
  }
  deriving stock (Eq, Show)

-- | What one embedded-review process is started for: the repository it runs
-- in, the @issue_review@ cell resolved for the provider whose backend is
-- starting it, and the tool re-entry the client prepared for it.
--
-- The assignment travels here because a provider's model and effort are not
-- always wire parameters. Codex carries its own in @thread\/start@ and
-- @turn\/start@ and so ignores this field entirely; @claude@ takes both as
-- launch flags (D-15), so its argv cannot be built without them. Handing
-- the resolved cell to the backend is what keeps that difference inside the
-- record rather than making the client ask which provider it is starting.
--
-- The tool server travels here for the same reason. Codex's tools are
-- @thread\/start@ parameters and it ignores this field; @claude@'s are
-- served over a stdio MCP re-entry whose configuration is argv, so its
-- launch cannot be built without one. The client supplies it for every
-- backend whose channel declares no inline tools — 'StreamJsonProtocol' —
-- and 'Nothing' is only what the backends that never read the field are
-- handed.
data ReviewLaunch = ReviewLaunch
  { launchRepositoryRoot :: FilePath,
    launchAssignment :: Assignment,
    launchToolServer :: Maybe ReviewToolServerLaunch
  }
  deriving stock (Eq, Show)

-- | How one provider's embedded issue-review backend is started.
--
-- The backend names its own process rather than being handed one, because
-- unlike the three agent-session processes it resolves no executable first:
-- @codex@ and @claude@ go to 'proc' directly and 'System.Process' does the
-- PATH lookup, which is the resolution timing this extraction had to
-- preserve.
--
-- 'backendProvider' is the identity the event seam carries. A protocol
-- warning is raised by generic client code that has no provider of its own,
-- and a consumer that rendered every one of them under a compiled-in brand
-- would tell an operator the wrong program had misbehaved.
data EmbeddedReviewBackend = EmbeddedReviewBackend
  { backendLabel :: Text,
    backendProvider :: ProviderName,
    backendProcess :: ReviewLaunch -> CreateProcess,
    backendProcessShape :: ReviewProcessShape,
    backendProtocol :: ReviewProtocol
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
    -- order the backend is given them. One declaration site whatever the
    -- channel: Codex's travel inline as @thread\/start@'s @dynamicTools@,
    -- and Claude's are the same declarations translated onto the MCP
    -- re-entry's @tools\/list@ (D-15), so the served schemas — the label
    -- vocabulary above all — cannot drift from what is declared here.
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
      adapterEmbeddedReview = Just claudeEmbeddedReview,
      -- The question tool and the GitHub tool, in the Codex thread's own
      -- order, and deliberately not the nested revision tool: a Claude
      -- review thread is already Claude and revises inline, exactly as a
      -- Codex-only install's thread does (D-14 as amended).
      adapterReviewTools = \_ config -> [questionTool, githubTool config]
    }

codexEmbeddedReview :: EmbeddedReviewBackend
codexEmbeddedReview =
  EmbeddedReviewBackend
    { backendLabel = "codex app-server",
      backendProvider = CodexProvider,
      backendProcessShape = SharedProcess,
      backendProtocol = AppServerProtocol,
      backendProcess = \launch ->
        (proc "codex" ["app-server", "--listen", "stdio://"])
          { cwd = Just launch.launchRepositoryRoot,
            std_in = CreatePipe,
            std_out = CreatePipe,
            std_err = CreatePipe,
            create_group = True
          }
    }

-- | Claude's embedded review: one @claude@ CLI process per review thread,
-- driven over the stream-json channel (D-15).
--
-- Shaped exactly like 'codexEmbeddedReview' where the two can be — the
-- repository root is the working directory, all three standard streams are
-- pipes because this channel writes to stdin as well as reading both others,
-- and the process leads its own group so a cancellation reaches its
-- children. What differs is what the record exists to express: the argv,
-- which is built from the resolved assignment; the process shape, because a
-- CLI process is one conversation; and the protocol, because the CLI streams
-- as soon as it starts.
claudeEmbeddedReview :: EmbeddedReviewBackend
claudeEmbeddedReview =
  EmbeddedReviewBackend
    { backendLabel = "claude stream-json session",
      backendProvider = ClaudeProvider,
      backendProcessShape = ProcessPerThread,
      backendProtocol = StreamJsonProtocol,
      backendProcess = \launch ->
        (proc "claude" (claudeReviewArguments launch.launchAssignment launch.launchToolServer))
          { cwd = Just launch.launchRepositoryRoot,
            std_in = CreatePipe,
            std_out = CreatePipe,
            std_err = CreatePipe,
            create_group = True
          }
    }

-- | The argv one embedded review session runs under, probed against CLI
-- 2.1.251 (D-15) and rechecked on 2.1.252.
--
-- Five groups, none of them optional:
--
-- * the channel — @-p@ with both @stream-json@ formats, and @--verbose@,
--   without which the CLI refuses the streamed output format outright;
-- * the transcript — @--include-partial-messages@, which is what makes the
--   text and thinking deltas the review panel renders appear at all;
-- * the verdict — @--json-schema@ carrying the same schema Codex passes as
--   @turn\/start@'s @outputSchema@, so one contract produces one
--   'Kanban.Review.Types.ReviewResult' on either backend;
-- * the isolation — @--strict-mcp-config@ and an empty @--tools@, because a
--   bare @claude -p@ loads the operator's own MCP servers and fires their
--   @SessionStart@ hook. An embedded review must not inherit the machine's
--   Claude Code configuration, and this launch is the only thing that stops
--   it;
-- * the tools — @--mcp-config@ naming Kanban's own re-entry as the one
--   server @--strict-mcp-config@ then holds the session to, and
--   @--allowedTools@ naming that server's two tools so the noninteractive
--   session may call them without a permission prompt nothing can answer
--   (D-15). The allowance is spelled from the same tool-name constants the
--   declarations are built from, and a test holds the two lists together.
--
-- @--model@ and @--effort@ close the list because they are the only part of
-- it the operator's roster moves.
claudeReviewArguments :: Assignment -> Maybe ReviewToolServerLaunch -> [String]
claudeReviewArguments assignment toolServer =
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
    ""
  ]
    <> foldMap reviewToolServerArguments toolServer
    <> [ "--model",
         Text.unpack assignment.assignmentModel,
         "--effort",
         Text.unpack assignment.assignmentEffort
       ]

-- | The launch's tool group: the MCP configuration for Kanban's re-entered
-- server, and the permission allowance for exactly the two tools it serves.
reviewToolServerArguments :: ReviewToolServerLaunch -> [String]
reviewToolServerArguments toolServer =
  [ "--mcp-config",
    LazyByteString.unpack (encode (reviewToolServerConfig toolServer.toolServerExecutable toolServer.toolServerEndpoint)),
    "--allowedTools",
    Text.unpack (Text.intercalate "," (map mcpToolAllowance [questionToolName, githubToolName]))
  ]

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
