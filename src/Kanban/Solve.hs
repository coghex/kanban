module Kanban.Solve
  ( AgentEvent (..),
    ResumeProvenance (..),
    SolveEvent (..),
    SolveOutcome (..),
    SolveWorkflow (..),
    SolverBrand (..),
    StreamEvent (..),
    UnknownAggregator,
    UnknownStreamCategory (..),
    UnknownStreamKey (..),
    agentOutcome,
    brandForProvider,
    codexSolverModel,
    claudeSolverModel,
    codexReviewerModel,
    claudeReviewerModel,
    emitStreamEvent,
    maxUnknownNoticeLength,
    maxUnknownTypeLength,
    newUnknownAggregator,
    parseSolveOutputLine,
    providerForBrand,
    renderAgentEvent,
    resumeProvenanceHeader,
    runSolve,
    runSolveWith,
    sealUnknownAggregates,
    solveArguments,
    solveAssignment,
    solveOutcome,
    solverLabel,
    unknownNoticeSamples,
  )
where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, finally, try, uninterruptibleMask_)
import Control.Monad (void)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Kanban.Domain (Repository (..), WorkflowConfig (..))
import Kanban.Models
  ( Assignment (..),
    AssignmentUnavailable,
    ModelRoster,
    ProviderName (..),
    RecordedAssignment,
    RoleName (..),
    assignmentFor,
    recordAssignment,
  )
import Kanban.Process (managedProcess)
import Kanban.Solve.Event
  ( AgentEvent (..),
    ResumeProvenance (..),
    SolveEvent (..),
    SolveOutcome (..),
    SolveWorkflow (..),
    SolverBrand (..),
    StreamEvent (..),
    UnknownStreamCategory (..),
    UnknownStreamKey (..),
    agentOutcome,
    claudeReviewerModel,
    claudeSolverModel,
    codexReviewerModel,
    codexSolverModel,
    renderAgentEvent,
    solveOutcome,
    solverLabel,
  )
import Kanban.Solve.Parse (parseSolveOutputLine)
import Kanban.Solve.Unknown
  ( UnknownAggregator,
    emitStreamEvent,
    maxUnknownNoticeLength,
    maxUnknownTypeLength,
    newUnknownAggregator,
    sealUnknownAggregates,
    unknownNoticeSamples,
  )
import Kanban.StreamReader (handleReadLine, onStreamAbandoned, runStreamReaderWith)
import Kanban.Transcript (SessionLog, closeSessionLog, logMessage, logRawLine, openSessionLog, sessionLogPath)
import System.Directory (findExecutable)
import System.IO (BufferMode (..), Handle, hSetBuffering)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (CreatePipe, NoStream),
    createProcess,
    cwd,
    proc,
    std_err,
    std_out,
    waitForProcess,
  )

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

-- | The roster cell a solve invocation runs on. The single declaration of
-- solve's @(role, provider)@ selection, shared by the UI boundary that
-- refuses on it and by the launch that records it, so the two can never
-- disagree about which cell this run was checked against.
--
-- The provider comes back with the cell rather than being left for a caller
-- to recompute: the record this becomes outlives the roster it was read
-- from, and a resume replays it without consulting either again.
solveAssignment :: ModelRoster -> SolverBrand -> Either AssignmentUnavailable RecordedAssignment
solveAssignment roster brand =
  recordAssignment provider <$> assignmentFor roster SolveRole provider
  where
    provider = providerForBrand brand

runSolve :: Repository -> Int -> SolveWorkflow -> SolverBrand -> Maybe FilePath -> WorkflowConfig -> Assignment -> Maybe Text -> Maybe FilePath -> ResumeProvenance -> Text -> UnknownAggregator -> (SolveEvent -> IO ()) -> IO ()
runSolve = runSolveWith (const handleReadLine)

-- | As 'runSolve', but reads stdout/stderr via an injected primitive instead
-- of always wrapping the real 'Handle' with 'handleReadLine' — the seam a
-- test uses to deterministically drive a still-live provider through the
-- shared reader's abandonment path (bounded retries exhausted, provider
-- killed, terminal outcome forced to a failure) without depending on a real
-- OS-level read failure, which a live pipe cannot be made to produce
-- deterministically without corrupting the reading side out from under it.
-- The primitive is given the stream tag ("stdout"/"stderr") alongside the
-- handle so a test can target one stream's abandonment path without racing
-- the other's.
runSolveWith :: (Text -> Handle -> IO (Either IOException (Maybe ByteString.ByteString))) -> Repository -> Int -> SolveWorkflow -> SolverBrand -> Maybe FilePath -> WorkflowConfig -> Assignment -> Maybe Text -> Maybe FilePath -> ResumeProvenance -> Text -> UnknownAggregator -> (SolveEvent -> IO ()) -> IO ()
runSolveWith readLineFor repository issueNumber workflow brand configPath config assignment existingSession existingLogPath provenance userMessage aggregator eventSink = do
  logResult <- openSessionLog repository (workflowLogName workflow <> "-" <> solverName brand) issueNumber existingLogPath
  sessionLog <- case logResult of
    Left message -> eventSink (SolveDiagnostic issueNumber message) >> pure Nothing
    Right value -> do
      eventSink (SolveLogOpened issueNumber value.sessionLogPath)
      logMessage value "invocation-started" (solverLabel brand <> " · " <> workflowLogName workflow)
      pure (Just value)
  executable <- findExecutable executableName
  case executable of
    Nothing -> finishWithoutProcess sessionLog (SolveFailed (Text.pack executableName <> " was not found on PATH"))
    Just executablePath -> do
      -- Masked from before the process is even spawned through its
      -- registration, so a deadline's cancellation can never land in the
      -- gap between a successful 'createProcess' and the event that
      -- reaches 'rememberProvider' — the only way the caller ever learns
      -- about (and can track or kill) this provider. Masking only after
      -- 'createProcess' returned left exactly that gap open.
      --
      -- 'SolveProcessSpawning' brackets the spawn attempt itself (True
      -- before 'createProcess', False on every path that concludes without
      -- a live registration): a deadline watchdog racing this exact mask
      -- cannot otherwise tell "no provider was ever spawned" (safe to
      -- treat as vacuously verified) apart from "one was just spawned but
      -- has not been recorded yet" (a live, unrecorded process that must
      -- not be treated as vacuously verified) — both look identical from
      -- outside as long as the caller's own provider reference is still
      -- unset.
      managedRef <- newIORef Nothing
      started <- uninterruptibleMask_ $ do
        eventSink (SolveProcessSpawning issueNumber True)
        result <- try (createProcess (processSpec executablePath)) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
        case result of
          Right (Nothing, Just _, Just _, processHandle) -> do
            (managed, groupLeaderProblem) <- managedProcess processHandle
            writeIORef managedRef (Just managed)
            mapM_ (\problem -> eventSink (SolveDiagnostic issueNumber ("process group leadership: " <> problem))) groupLeaderProblem
            eventSink (SolveProcessStarted issueNumber brand managed)
          _ -> eventSink (SolveProcessSpawning issueNumber False)
        pure result
      case started of
        Left exception -> finishWithoutProcess sessionLog (SolveFailed ("Could not start " <> Text.pack executableName <> ": " <> exceptionText exception))
        Right (Nothing, Just outputHandle, Just errorHandle, processHandle) -> do
          hSetBuffering outputHandle LineBuffering
          hSetBuffering errorHandle LineBuffering
          managedResult <- readIORef managedRef
          case managedResult of
            Nothing -> finishWithoutProcess sessionLog (SolveFailed "internal error: provider process was not registered as managed")
            Just managed -> do
              sessionRef <- newIORef existingSession
              lastMessageRef <- newIORef ""
              abandonReasonRef <- newIORef Nothing
              diagnosticsDone <- newEmptyMVar
              let abandon = onStreamAbandoned (eventSink . SolveDiagnostic issueNumber) managed abandonReasonRef
              void . forkIO $
                void (runStreamReaderWith (readLineFor "stderr" errorHandle) "stderr" (stderrOnLine sessionLog eventSink issueNumber) abandon)
                  `finally` putMVar diagnosticsDone ()
              _ <- runStreamReaderWith (readLineFor "stdout" outputHandle) "stdout" (stdoutOnLine sessionLog aggregator sessionRef lastMessageRef eventSink issueNumber) abandon
              exitCode <- waitForProcess processHandle
              takeMVar diagnosticsDone
              lastMessage <- readIORef lastMessageRef
              abandonReason <- readIORef abandonReasonRef
              let outcome = maybe (solveOutcome exitCode lastMessage) SolveFailed abandonReason
              closeWithOutcome sessionLog outcome
        Right _ -> finishWithoutProcess sessionLog (SolveFailed (Text.pack executableName <> " did not provide stdout and stderr pipes"))
  where
    -- Before this invocation's terminal event, never after: replay stops at
    -- the terminal journal envelope, so a summary emitted later would be
    -- written but never replayed. A supervisor that cancels this invocation
    -- outright owns the same aggregator and seals it before its own terminal
    -- envelope; sealing is one-shot and writes under its own lock, so
    -- whichever side gets there first is the only one that reports, and the
    -- other cannot terminalize until that reporting is complete.
    flushAggregates = sealUnknownAggregates aggregator (eventSink . SolveOutput issueNumber)
    repositoryRoot = repository.repositoryRoot
    executableName = case brand of
      CodexSolver -> "codex"
      ClaudeSolver -> "claude"
    solverName CodexSolver = "codex"
    solverName ClaudeSolver = "claude"
    finishWithoutProcess sessionLog outcome = closeWithOutcome sessionLog outcome
    closeWithOutcome sessionLog outcome = do
      flushAggregates
      mapM_ (\value -> logMessage value "invocation-finished" (Text.pack (show outcome)) >> closeSessionLog value) sessionLog
      eventSink (SolveProcessFinished issueNumber outcome)
    processSpec executablePath =
      (proc executablePath (solveArguments issueNumber workflow brand configPath repository config assignment existingSession provenance userMessage))
        { cwd = Just repositoryRoot,
          std_out = CreatePipe,
          std_err = CreatePipe,
          std_in = NoStream,
          create_group = True
        }

-- | The provider argv for one solve invocation.
--
-- Takes the resolved 'Assignment' rather than the roster it came from: the
-- caller has already established that the cell exists (see 'solveAssignment'
-- and the refusals in "Kanban.UI.Solve" and "Kanban.Worker"), so this stays
-- total and gains no failure return of its own. Under an absent
-- @models.toml@ the compiled defaults make every argument below
-- byte-identical to the literals this replaced.
solveArguments :: Int -> SolveWorkflow -> SolverBrand -> Maybe FilePath -> Repository -> WorkflowConfig -> Assignment -> Maybe Text -> ResumeProvenance -> Text -> [String]
solveArguments issueNumber workflow CodexSolver configPath repository config assignment existingSession provenance userMessage =
  case existingSession of
    Nothing ->
      [ "exec",
        "--model",
        Text.unpack assignment.assignmentModel,
        "--config",
        codexEffortOption assignment,
        "--config",
        "model_reasoning_summary=\"detailed\"",
        "--dangerously-bypass-approvals-and-sandbox",
        "--json",
        Text.unpack (initialSolvePrompt issueNumber workflow CodexSolver configPath repository)
      ]
    Just sessionId ->
      [ "exec",
        "resume",
        "--model",
        Text.unpack assignment.assignmentModel,
        "--config",
        codexEffortOption assignment,
        "--config",
        "model_reasoning_summary=\"detailed\"",
        "--config",
        "approval_policy=\"never\"",
        "--dangerously-bypass-approvals-and-sandbox",
        "--json",
        Text.unpack sessionId,
        Text.unpack (resumeSolvePrompt config workflow CodexSolver repository provenance userMessage)
      ]
solveArguments issueNumber workflow ClaudeSolver configPath repository config assignment existingSession provenance userMessage =
  [ "--print",
    "--model",
    Text.unpack assignment.assignmentModel,
    "--effort",
    Text.unpack assignment.assignmentEffort,
    "--permission-mode",
    "bypassPermissions",
    "--output-format",
    "stream-json",
    "--verbose"
  ]
    <> maybe [] (\sessionId -> ["--resume", Text.unpack sessionId]) existingSession
    <> [Text.unpack (if existingSession == Nothing then initialSolvePrompt issueNumber workflow ClaudeSolver configPath repository else resumeSolvePrompt config workflow ClaudeSolver repository provenance userMessage)]

-- | Codex takes its effort as a @-c@ style override rather than a flag, so
-- the assignment's effort is quoted into the same @model_reasoning_effort@
-- key both spawn sites already used.
codexEffortOption :: Assignment -> String
codexEffortOption assignment = Text.unpack ("model_reasoning_effort=\"" <> assignment.assignmentEffort <> "\"")

initialSolvePrompt :: Int -> SolveWorkflow -> SolverBrand -> Maybe FilePath -> Repository -> Text
initialSolvePrompt issueNumber workflow brand configPath repository =
  Text.unlines
    ( [ "Run the " <> workflowName workflow brand <> " workflow for GitHub issue #" <> Text.pack (show issueNumber) <> " in this repository.",
        "You are the canonical " <> solverLabel brand <> " solver selected explicitly by the user.",
        workflowContract,
        interruptedWorktreeRecovery,
        "Do not run issue-review, issue-rereview, or --review/--rereview against approve-issues.py, its legacy ~/work/approve-issues.py symlink, or the installed tools/approve_issues.py backend, from this solve session. Kanban's r workflow owns that gate. Run only the required read-only v2 gate check; if it is not approved, stop with KANBAN_NEEDS_INPUT: This issue needs canonical review; press r on the issue, then retry."
      ]
        <> repositoryLines
        <> configLines
        <> [ "Interaction contract: if a product choice, ambiguity, credentials problem, or other user decision blocks safe progress, do not guess and do not continue. End your response with exactly one line in the form KANBAN_NEEDS_INPUT: <one concrete question>. Kanban will resume this same session with the answer.",
             completionContract
           ]
    )
  where
    -- Kanban's own resolved repository scopes the WHOLE run, not only the
    -- readiness gate, and accompanies it always rather than only when a
    -- custom --config or an explicit --repo override is set: the identity may
    -- equally come from a configured remote_name naming upstream from a fork
    -- checkout, and either way an operation that re-derived it from the
    -- checkout would read the specification of, or mutate, issue #N of a
    -- different repository than the one this dashboard gated and displays.
    repositoryLines =
      [ "Target GitHub repository: " <> repositorySlug <> ". Kanban resolved that identity and it scopes every GitHub issue and pull-request operation of this run; never re-derive it from the checkout.",
        "Pass --repo " <> repositorySlug <> " to the read-only v2 gate check so it resolves the same repository as this dashboard.",
        "Pass --repo " <> repositorySlug <> " to the vendored trusted-comment helper so the effective specification comes from that same repository.",
        "Pass -R " <> repositorySlug <> " to every gh issue and pull-request command of this run: issue selection, the issue claim and its release, the open-pull-request collision search, and pull-request creation.",
        "Name the worktree directory with that identity, $WORKTREES_ROOT/" <> repositorySlug <> "/issue-" <> Text.pack (show issueNumber) <> "-<slug>; `git worktree list` remains the sole collision and recovery source, so a worktree already registered under an earlier path still resolves.",
        "The implementation branch still pushes to the worked checkout's own remote, and the worktree still branches from that checkout's origin/<default-branch>. When that remote is a different repository, open the pull request in " <> repositorySlug <> " with an explicit cross-repository head (--head <push-owner>:<branch>); if GitHub cannot open that pull request, stop and report the pushed branch rather than opening one in the push remote's repository.",
        "If that identity cannot be established or preserved, stop and report before the first issue mutation (the claim, gh issue edit ... --add-assignee @me); falling back to the checkout's own repository is never the repair."
      ]
    repositorySlug = repository.repositoryOwner <> "/" <> repository.repositoryName
    configLines =
      case configPath of
        Nothing -> []
        Just path ->
          [ "Pass --config " <> Text.pack path <> " to the read-only v2 gate check so it resolves the same configured workflow labels and remote as this dashboard."
          ]
    workflowContract = case workflow of
      SolveOnly -> "Preserve the existing solve contract: readiness gate, interrupted-worktree recovery, effective specification from issue comments, targeted validation, commit/push, and PR creation. Stop after opening the PR; do not review or merge it."
      AutoSolve -> "Preserve the existing solve contract: readiness gate, interrupted-worktree recovery, effective specification from issue comments, targeted validation, commit/push, and PR creation. Stop immediately after opening the PR; do not start a reviewer, revise the PR, or merge it. Kanban owns the bounded review/fix loop."
    interruptedWorktreeRecovery =
      "Before creating a worktree, inspect `git worktree list` for an existing worktree for issue #" <> Text.pack (show issueNumber) <> ". An existing same-issue worktree means a prior solve was interrupted; it is recovery work, not a collision. Enter that worktree, identify its upstream/default base, inspect `git status`, committed progress relative to that base, and both staged and unstaged diffs. Preserve and validate useful existing work, then continue the solve in that worktree. Do not discard, reset, or overwrite unfinished changes merely to start clean. Only create a new sibling worktree when no same-issue worktree exists."
    completionContract = case workflow of
      SolveOnly -> "When no input is needed, continue autonomously until the solve workflow opens its PR. Summarize the issue claim, worktree/branch, validation, and PR URL in the final response."
      AutoSolve -> "When no input is needed, continue autonomously until the solve workflow opens its PR. Summarize the issue claim, worktree/branch, validation, and PR URL in the final response so Kanban can discover the PR and start review."

workflowName :: SolveWorkflow -> SolverBrand -> Text
workflowName SolveOnly CodexSolver = "$solve"
workflowName SolveOnly ClaudeSolver = "/solve"
workflowName AutoSolve CodexSolver = "$solve"
workflowName AutoSolve ClaudeSolver = "/solve"

workflowLogName :: SolveWorkflow -> Text
workflowLogName SolveOnly = "solve"
workflowLogName AutoSolve = "autosolve"

-- | The resumed prompt restates the resolved repository rather than relying on
-- the initial prompt still being in the session's context: a session resumed
-- after truncation owns the rest of the run — the remaining claim release and
-- every pull-request operation — and would otherwise silently fall back to
-- deriving an identity from the checkout, which is exactly the divergence the
-- initial prompt exists to prevent.
resumeSolvePrompt :: WorkflowConfig -> SolveWorkflow -> SolverBrand -> Repository -> ResumeProvenance -> Text -> Text
resumeSolvePrompt config workflow brand repository provenance answer =
  Text.unlines
    [ resumeProvenanceHeader config provenance,
      Text.strip answer,
      "Continue the same " <> workflowName workflow brand <> " workflow from its current state. Apply the same interaction contract: stop with KANBAN_NEEDS_INPUT: <question> rather than guessing if another user decision is required.",
      "Target GitHub repository: " <> repository.repositoryOwner <> "/" <> repository.repositoryName <> ". It still scopes every remaining GitHub issue and pull-request operation of this run — pass --repo to the gate check and the trusted-comment helper and -R to every gh command — and is never re-derived from the checkout."
    ]

-- | The opening line for a resumed prompt, distinguishing a real user answer
-- to 'KANBAN_NEEDS_INPUT' from user interrupt guidance and from an automated
-- workflow handoff, so the resumed agent does not misattribute an automated
-- message as an authoritative user decision. Shared by 'resumeSolvePrompt'
-- and 'Kanban.PullRequestFlow.resumePrompt', so the configured
-- changes-requested label is threaded through both call sites.
resumeProvenanceHeader :: WorkflowConfig -> ResumeProvenance -> Text
resumeProvenanceHeader _ ResumeAnswer = "The user answered the Kanban workflow question:"
resumeProvenanceHeader _ ResumeInterruptGuidance = "The user interrupted with corrective guidance:"
resumeProvenanceHeader config ResumeAutomatedChangesRequested =
  "Kanban is resuming this session because the PR received "
    <> config.changesRequestedLabel
    <> ", not because of a user message. The following automated handoff directs you to the canonical review blockers; it is not the blocker text itself:"

-- | Per-line handler for the stdout reader: raw-line session logging,
-- session-id capture, and agent-message forwarding, unchanged from before
-- this module's reader loop was unified in "Kanban.StreamReader".
stdoutOnLine :: Maybe SessionLog -> UnknownAggregator -> IORef (Maybe Text) -> IORef Text -> (SolveEvent -> IO ()) -> Int -> ByteString.ByteString -> IO ()
stdoutOnLine sessionLog aggregator sessionRef lastMessageRef eventSink issueNumber line = do
  mapM_ (\value -> logRawLine value "stdout" line) sessionLog
  case parseSolveOutputLine line of
    Left _ ->
      let plain = decodeBytes line
       in if Text.null plain then pure () else eventSink (SolveDiagnostic issueNumber plain)
    Right (sessionId, messages) -> do
      case sessionId of
        Nothing -> pure ()
        Just value -> do
          writeIORef sessionRef (Just value)
          eventSink (SolveSessionIdentified issueNumber value)
      mapM_ (emitStreamEvent aggregator (emitMessage lastMessageRef eventSink issueNumber)) messages

emitMessage :: IORef Text -> (SolveEvent -> IO ()) -> Int -> AgentEvent -> IO ()
emitMessage lastMessageRef eventSink issueNumber agentEvent
  | Text.null (Text.strip agentEvent.agentEventSummary) = pure ()
  | otherwise = do
      mapM_ (\message -> atomicModifyIORef' lastMessageRef (const (message, ()))) agentEvent.agentEventOutcomeText
      eventSink (SolveOutput issueNumber agentEvent)

-- | Per-line handler for the stderr reader: raw-line session logging and
-- diagnostic forwarding, unchanged from before this module's reader loop
-- was unified in "Kanban.StreamReader".
stderrOnLine :: Maybe SessionLog -> (SolveEvent -> IO ()) -> Int -> ByteString.ByteString -> IO ()
stderrOnLine sessionLog eventSink issueNumber line
  | ByteString.null line = pure ()
  | otherwise = do
      mapM_ (\value -> logRawLine value "stderr" line) sessionLog
      eventSink (SolveDiagnostic issueNumber (decodeBytes line))

decodeBytes :: ByteString.ByteString -> Text
decodeBytes = Text.strip . TextEncoding.decodeUtf8With lenientDecode

exceptionText :: IOException -> Text
exceptionText = Text.pack . show
