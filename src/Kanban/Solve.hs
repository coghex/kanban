{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

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
    admitStreamEvent,
    agentOutcome,
    codexSolverModel,
    claudeSolverModel,
    codexReviewerModel,
    claudeReviewerModel,
    flushUnknownAggregates,
    maxUnknownNoticeLength,
    maxUnknownTypeLength,
    newUnknownAggregator,
    parseSolveOutputLine,
    renderAgentEvent,
    resumeProvenanceHeader,
    runSolve,
    runSolveWith,
    solveArguments,
    solveOutcome,
    solverLabel,
    unknownNoticeSamples,
  )
where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, finally, try, uninterruptibleMask_)
import Control.Monad (void)
import Data.Aeson (FromJSON, ToJSON, Value (..), eitherDecodeStrict', encode)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Foldable (toList)
import GHC.Generics (Generic)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Kanban.Domain (Repository (..), WorkflowConfig (..))
import Kanban.Process (ManagedProcess, managedProcess)
import Kanban.Settings (ChatVerbosity (..))
import Kanban.StreamReader (handleReadLine, onStreamAbandoned, runStreamReaderWith)
import Kanban.Text (excerpt)
import Kanban.Transcript (SessionLog, closeSessionLog, logMessage, logRawLine, openSessionLog, sessionLogPath)
import System.Directory (findExecutable)
import System.Exit (ExitCode (..))
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

data SolverBrand = CodexSolver | ClaudeSolver
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data SolveWorkflow = SolveOnly | AutoSolve
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Why a resumed agent session is being fed this message, so the resume
-- prompt can state the true provenance instead of always framing it as a
-- user answer. 'ResumeAutomatedChangesRequested' covers Kanban's own
-- reviewed:changes handoff (e.g. 'resumeAutoSolveRevision'), not a message
-- typed by a person.
data ResumeProvenance = ResumeAnswer | ResumeInterruptGuidance | ResumeAutomatedChangesRequested
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data SolveOutcome
  = SolveCompleted
  | SolveNeedsInput Text
  | SolveFailed Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data SolveEvent
  = SolveProcessStarted Int SolverBrand ManagedProcess
  | SolveProcessSpawning Int Bool
  | SolveLogOpened Int FilePath
  | SolveSessionIdentified Int Text
  | SolveOutput Int AgentEvent
  | SolveDiagnostic Int Text
  | SolveProcessFinished Int SolveOutcome

data ParsedSolveOutput = ParsedSolveOutput
  { parsedSessionId :: Maybe Text,
    parsedMessages :: [StreamEvent]
  }
  deriving stock (Eq, Show)

data AgentEvent = AgentEvent
  { agentEventKind :: Text,
    agentEventSummary :: Text,
    agentEventDetail :: Text,
    agentEventOutcomeText :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A parsed agent event paired with the identity of the unknown-payload
-- fallback that produced it, if any. The identity rides alongside
-- 'AgentEvent' rather than inside it deliberately: aggregation is decided in
-- the stream loops and never reaches a worker-journal envelope, so journals
-- written before this bounding existed keep decoding exactly as they did.
data StreamEvent = StreamEvent
  { streamEventUnknown :: Maybe UnknownStreamKey,
    streamEventAgent :: AgentEvent
  }
  deriving stock (Eq, Show)

-- | Which of the parser's three unrecognized-payload fallbacks produced a
-- notice. It is part of the aggregation key so a top-level event, a Codex
-- item, and a Claude content block that happen to share a type string are
-- still counted apart.
data UnknownStreamCategory = UnknownTopLevel | UnknownCodexItem | UnknownClaudeContent
  deriving stock (Eq, Ord, Show)

-- | The identity repeated unknown payloads collapse under: the fallback's
-- category plus the payload's usable literal-string @type@, or 'Nothing'
-- when that type is missing, not a JSON string, or blank once normalized.
-- The /full/ type text is kept rather than the truncated display label, so
-- two long distinct types that share a bounded prefix never merge into one
-- another's count.
data UnknownStreamKey = UnknownStreamKey UnknownStreamCategory (Maybe Text)
  deriving stock (Eq, Ord, Show)

-- | The deterministic ceiling on an entire unknown-payload notice — category
-- tag, type label, separator, and bounded detail together, not just the
-- detail. A provider that starts emitting a chatty unrecognized event type
-- therefore costs a fixed number of characters per occurrence in the worker
-- journal and replayed transcript instead of its whole payload.
maxUnknownNoticeLength :: Int
maxUnknownNoticeLength = 200

-- | The short fixed width an unknown payload's type label is normalized and
-- truncated to before the detail is appended, so a pathological type string
-- cannot by itself consume the whole notice budget.
maxUnknownTypeLength :: Int
maxUnknownTypeLength = 48

-- | How many occurrences of one unknown key are reported individually before
-- the remainder only accumulate a count, redeemed as a single aggregate
-- summary when the invocation ends. Keeping a few samples preserves the
-- payload variation worth seeing; suppressing the rest is what makes a
-- chatty type cost O(1) per invocation instead of O(n).
unknownNoticeSamples :: Int
unknownNoticeSamples = 3

-- | The stable label a payload with no usable @type@ is reported and
-- aggregated under, so such payloads still produce a deterministic bounded
-- notice rather than being dropped or falling back to their raw JSON.
unknownTypePlaceholder :: Text
unknownTypePlaceholder = "unknown"

-- | Invocation-local aggregation state. Its lifetime is exactly one provider
-- invocation and its worker journal: nothing is carried across a resume, and
-- no entry is ever rewritten, which is what keeps this compatible with the
-- append-only journal.
newtype UnknownAggregator = UnknownAggregator (IORef (Map UnknownStreamKey Int))

newUnknownAggregator :: IO UnknownAggregator
newUnknownAggregator = UnknownAggregator <$> newIORef Map.empty

-- | Admits one parsed event into an invocation's output. Recognized events
-- always pass through. An unknown notice passes through for its key's first
-- 'unknownNoticeSamples' occurrences and is suppressed afterwards, its count
-- accumulating for 'flushUnknownAggregates'.
admitStreamEvent :: UnknownAggregator -> StreamEvent -> IO (Maybe AgentEvent)
admitStreamEvent _ (StreamEvent Nothing agentEvent) = pure (Just agentEvent)
admitStreamEvent (UnknownAggregator counts) (StreamEvent (Just key) agentEvent) = do
  seen <- atomicModifyIORef' counts (\tally -> let total = Map.findWithDefault 0 key tally + 1 in (Map.insert key total tally, total))
  pure (if seen <= unknownNoticeSamples then Just agentEvent else Nothing)

-- | The one aggregate summary each key with suppressed occurrences
-- contributes, reporting that key's total occurrence count. Callers emit
-- these before the invocation's terminal event, because replay stops at the
-- terminal journal envelope and would never reach a later summary. The state
-- is cleared as it is read so a repeated flush cannot double-report.
flushUnknownAggregates :: UnknownAggregator -> IO [AgentEvent]
flushUnknownAggregates (UnknownAggregator counts) = do
  tally <- atomicModifyIORef' counts (\existing -> (Map.empty, existing))
  pure
    [ AgentEvent "event" (unknownAggregateNotice key total) "" Nothing
      | (key, total) <- Map.toAscList tally,
        total > unknownNoticeSamples
    ]

codexSolverModel :: Text
codexSolverModel = "gpt-5.4 high"

claudeSolverModel :: Text
claudeSolverModel = "Sonnet 5 high"

codexReviewerModel :: Text
codexReviewerModel = "GPT-5.6-Terra xhigh"

claudeReviewerModel :: Text
claudeReviewerModel = "Opus 5 xhigh"

solverLabel :: SolverBrand -> Text
solverLabel CodexSolver = "codex · " <> codexSolverModel
solverLabel ClaudeSolver = "claude · " <> claudeSolverModel

runSolve :: Repository -> Int -> SolveWorkflow -> SolverBrand -> Maybe FilePath -> WorkflowConfig -> Maybe Text -> Maybe FilePath -> ResumeProvenance -> Text -> (SolveEvent -> IO ()) -> IO ()
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
runSolveWith :: (Text -> Handle -> IO (Either IOException (Maybe ByteString.ByteString))) -> Repository -> Int -> SolveWorkflow -> SolverBrand -> Maybe FilePath -> WorkflowConfig -> Maybe Text -> Maybe FilePath -> ResumeProvenance -> Text -> (SolveEvent -> IO ()) -> IO ()
runSolveWith readLineFor repository issueNumber workflow brand configPath config existingSession existingLogPath provenance userMessage eventSink = do
  -- One aggregator per invocation, flushed by 'closeWithOutcome' on every
  -- terminal path (normal EOF, needs-input handoff, failure, abandonment,
  -- cancellation), so a chatty unknown type's tail is always redeemed as a
  -- single counted summary and never carried into another invocation.
  aggregator <- newUnknownAggregator
  logResult <- openSessionLog repository (workflowLogName workflow <> "-" <> solverName brand) issueNumber existingLogPath
  sessionLog <- case logResult of
    Left message -> eventSink (SolveDiagnostic issueNumber message) >> pure Nothing
    Right value -> do
      eventSink (SolveLogOpened issueNumber value.sessionLogPath)
      logMessage value "invocation-started" (solverLabel brand <> " · " <> workflowLogName workflow)
      pure (Just value)
  executable <- findExecutable executableName
  case executable of
    Nothing -> finishWithoutProcess aggregator sessionLog (SolveFailed (Text.pack executableName <> " was not found on PATH"))
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
        Left exception -> finishWithoutProcess aggregator sessionLog (SolveFailed ("Could not start " <> Text.pack executableName <> ": " <> exceptionText exception))
        Right (Nothing, Just outputHandle, Just errorHandle, processHandle) -> do
          hSetBuffering outputHandle LineBuffering
          hSetBuffering errorHandle LineBuffering
          managedResult <- readIORef managedRef
          case managedResult of
            Nothing -> finishWithoutProcess aggregator sessionLog (SolveFailed "internal error: provider process was not registered as managed")
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
              closeWithOutcome aggregator sessionLog outcome
        Right _ -> finishWithoutProcess aggregator sessionLog (SolveFailed (Text.pack executableName <> " did not provide stdout and stderr pipes"))
  where
    -- Before the terminal event, never after: replay stops at the terminal
    -- journal envelope, so a summary emitted later would be written but
    -- never replayed.
    flushAggregates aggregator = flushUnknownAggregates aggregator >>= mapM_ (eventSink . SolveOutput issueNumber)
    repositoryRoot = repository.repositoryRoot
    executableName = case brand of
      CodexSolver -> "codex"
      ClaudeSolver -> "claude"
    solverName CodexSolver = "codex"
    solverName ClaudeSolver = "claude"
    finishWithoutProcess aggregator sessionLog outcome = closeWithOutcome aggregator sessionLog outcome
    closeWithOutcome aggregator sessionLog outcome = do
      flushAggregates aggregator
      mapM_ (\value -> logMessage value "invocation-finished" (Text.pack (show outcome)) >> closeSessionLog value) sessionLog
      eventSink (SolveProcessFinished issueNumber outcome)
    processSpec executablePath =
      (proc executablePath (solveArguments issueNumber workflow brand configPath repository config existingSession provenance userMessage))
        { cwd = Just repositoryRoot,
          std_out = CreatePipe,
          std_err = CreatePipe,
          std_in = NoStream,
          create_group = True
        }

solveArguments :: Int -> SolveWorkflow -> SolverBrand -> Maybe FilePath -> Repository -> WorkflowConfig -> Maybe Text -> ResumeProvenance -> Text -> [String]
solveArguments issueNumber workflow CodexSolver configPath repository config existingSession provenance userMessage =
  case existingSession of
    Nothing ->
      [ "exec",
        "--model",
        "gpt-5.4",
        "--config",
        "model_reasoning_effort=\"high\"",
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
        "gpt-5.4",
        "--config",
        "model_reasoning_effort=\"high\"",
        "--config",
        "model_reasoning_summary=\"detailed\"",
        "--config",
        "approval_policy=\"never\"",
        "--dangerously-bypass-approvals-and-sandbox",
        "--json",
        Text.unpack sessionId,
        Text.unpack (resumeSolvePrompt config workflow CodexSolver provenance userMessage)
      ]
solveArguments issueNumber workflow ClaudeSolver configPath repository config existingSession provenance userMessage =
  [ "--print",
    "--model",
    "claude-sonnet-5",
    "--effort",
    "high",
    "--permission-mode",
    "bypassPermissions",
    "--output-format",
    "stream-json",
    "--verbose"
  ]
    <> maybe [] (\sessionId -> ["--resume", Text.unpack sessionId]) existingSession
    <> [Text.unpack (if existingSession == Nothing then initialSolvePrompt issueNumber workflow ClaudeSolver configPath repository else resumeSolvePrompt config workflow ClaudeSolver provenance userMessage)]

initialSolvePrompt :: Int -> SolveWorkflow -> SolverBrand -> Maybe FilePath -> Repository -> Text
initialSolvePrompt issueNumber workflow brand configPath repository =
  Text.unlines
    ( [ "Run the " <> workflowName workflow brand <> " workflow for GitHub issue #" <> Text.pack (show issueNumber) <> " in this repository.",
        "You are the canonical " <> solverLabel brand <> " solver selected explicitly by the user.",
        workflowContract,
        interruptedWorktreeRecovery,
        "Do not run issue-review, issue-rereview, or --review/--rereview against approve-issues.py, its legacy ~/work/approve-issues.py symlink, or the installed tools/approve_issues.py backend, from this solve session. Kanban's r workflow owns that gate. Run only the required read-only v2 gate check; if it is not approved, stop with KANBAN_NEEDS_INPUT: This issue needs canonical review; press r on the issue, then retry."
      ]
        <> configLines
        <> [ "Interaction contract: if a product choice, ambiguity, credentials problem, or other user decision blocks safe progress, do not guess and do not continue. End your response with exactly one line in the form KANBAN_NEEDS_INPUT: <one concrete question>. Kanban will resume this same session with the answer.",
             completionContract
           ]
    )
  where
    -- Explicit --repo always accompanies the gate check, not only when a
    -- custom --config is set: Kanban's own resolved repository (which may
    -- come from an explicit --repo override, e.g. reviewing upstream from a
    -- fork checkout) must never be silently re-derived by the gate check
    -- from the checkout's configured remote instead.
    configLines =
      [ "Pass --repo " <> repository.repositoryOwner <> "/" <> repository.repositoryName <> " to the read-only v2 gate check so it resolves the same repository as this dashboard."
      ]
        <> case configPath of
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

resumeSolvePrompt :: WorkflowConfig -> SolveWorkflow -> SolverBrand -> ResumeProvenance -> Text -> Text
resumeSolvePrompt config workflow brand provenance answer =
  Text.unlines
    [ resumeProvenanceHeader config provenance,
      Text.strip answer,
      "Continue the same " <> workflowName workflow brand <> " workflow from its current state. Apply the same interaction contract: stop with KANBAN_NEEDS_INPUT: <question> rather than guessing if another user decision is required."
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

parseSolveOutputLine :: ByteString.ByteString -> Either Text (Maybe Text, [StreamEvent])
parseSolveOutputLine bytes = do
  value <- case eitherDecodeStrict' bytes of
    Left message -> Left (Text.pack message)
    Right decoded -> Right decoded
  let parsed = parseSolveValue value
  pure (parsed.parsedSessionId, parsed.parsedMessages)

parseSolveValue :: Value -> ParsedSolveOutput
parseSolveValue value = case fieldString "type" value of
  Just "thread.started" -> ParsedSolveOutput (fieldText "thread_id" value) []
  Just "system" -> ParsedSolveOutput (fieldText "session_id" value) []
  Just "item.completed" -> ParsedSolveOutput Nothing (maybe [] parseCodexItem (fieldValue "item" value))
  Just "assistant" -> ParsedSolveOutput Nothing (maybe [] parseClaudeMessage (fieldValue "message" value))
  Just "user" -> ParsedSolveOutput Nothing (maybe [] parseClaudeMessage (fieldValue "message" value))
  Just "result" ->
    let resultText = fieldText "result" value
        usage = maybe "" (("usage: " <>) . compactValue) (fieldValue "usage" value)
     in ParsedSolveOutput (fieldText "session_id" value) (maybe [] (\message -> [recognized (agentMessage message usage)]) resultText)
  Just "turn.completed" -> ParsedSolveOutput Nothing (maybe [] (\usage -> [recognized (AgentEvent "usage" "[usage] turn complete" (compactValue usage) Nothing)]) (fieldValue "usage" value))
  Just "error" -> ParsedSolveOutput Nothing [errorOrUnknown UnknownTopLevel value]
  _ -> ParsedSolveOutput Nothing [unknownStreamEvent UnknownTopLevel value]

parseCodexItem :: Value -> [StreamEvent]
parseCodexItem item = case fieldString "type" item of
  Just "agent_message" -> maybe [] (\message -> [recognized (agentMessage message "")]) (fieldText "text" item)
  Just "reasoning" ->
    let reasoning = firstText [fieldValue "summary" item, fieldValue "text" item, fieldValue "content" item]
     in maybe [] (\message -> [recognized (AgentEvent "reasoning" "[reasoning]" message Nothing)]) reasoning
  Just "command_execution" ->
    let command = fromMaybe "" (fieldText "command" item)
        status = maybe "" (" · " <>) (fieldText "status" item)
        output = fromMaybe "" (firstText [fieldValue "aggregated_output" item, fieldValue "output" item])
     in [recognized (AgentEvent "command" ("[command] " <> command <> status) output Nothing) | not (Text.null command)]
  Just "file_change" -> [recognized (AgentEvent "file" "[files] changes applied" (compactValue item) Nothing)]
  Just "mcp_tool_call" -> toolEvent item
  Just "web_search" -> [recognized (AgentEvent "tool" "[web search] " (compactValue item) Nothing)]
  Just "todo_list" -> [recognized (AgentEvent "plan" "[plan] updated" (compactValue item) Nothing)]
  Just "error" -> [errorOrUnknown UnknownCodexItem item]
  _ -> [unknownStreamEvent UnknownCodexItem item]

parseClaudeMessage :: Value -> [StreamEvent]
parseClaudeMessage message = maybe [] (concatMap parseClaudeContent . valueList) (fieldValue "content" message)

parseClaudeContent :: Value -> [StreamEvent]
parseClaudeContent content = case fieldString "type" content of
  Just "text" -> maybe [] (\message -> [recognized (agentMessage message "")]) (fieldText "text" content)
  Just "thinking" -> maybe [] (\message -> [recognized (AgentEvent "reasoning" "[reasoning]" message Nothing)]) (firstText [fieldValue "thinking" content, fieldValue "text" content])
  Just "tool_use" -> toolEvent content
  Just "tool_result" ->
    let result = fromMaybe (compactValue content) (firstText [fieldValue "content" content, fieldValue "result" content])
     in [recognized (AgentEvent "tool-result" "[tool result]" result Nothing)]
  _ -> [unknownStreamEvent UnknownClaudeContent content]

-- | A recognized event, carrying no aggregation identity: it is emitted
-- as-is however often it repeats.
recognized :: AgentEvent -> StreamEvent
recognized = StreamEvent Nothing

-- | A recognized @error@ payload. Its full literal-string @message@ survives
-- verbatim — the one deliberate exemption from the notice bound. A payload
-- whose @message@ is missing, blank, or any non-string JSON is /not/
-- exempt: it degrades to the same bounded, aggregatable notice as any other
-- unrecognized payload instead of embedding its whole raw JSON. The check is
-- deliberately stricter than 'fieldText', which would also coerce an array,
-- object, number, or boolean into a "message".
errorOrUnknown :: UnknownStreamCategory -> Value -> StreamEvent
errorOrUnknown category value = case fieldString "message" value >>= nonEmptyText of
  Just message -> recognized (errorEvent message)
  Nothing -> unknownStreamEvent category value

-- | The bounded one-line notice an unrecognized payload contributes, tagged
-- with the identity repeated occurrences collapse under.
unknownStreamEvent :: UnknownStreamCategory -> Value -> StreamEvent
unknownStreamEvent category value =
  let key = unknownStreamKey category value
   in StreamEvent (Just key) (AgentEvent "event" (unknownNotice key value) "" Nothing)

-- | The aggregation identity of an unrecognized payload. Only a literal JSON
-- string is a usable type; everything else — missing, non-string, or blank
-- once normalized — shares the one stable placeholder key.
unknownStreamKey :: UnknownStreamCategory -> Value -> UnknownStreamKey
unknownStreamKey category value = UnknownStreamKey category usableType
  where
    usableType = case fieldString "type" value of
      Just typeText | not (Text.null (excerpt typeText)) -> Just typeText
      _ -> Nothing

-- | The whole notice for one occurrence: category tag, bounded type label,
-- and a bounded compact rendering of the payload, all on one line and
-- together within 'maxUnknownNoticeLength'. The detail lives in the summary
-- rather than 'agentEventDetail' so even the Full chat rendering — which
-- would otherwise put the detail on its own indented lines — stays one line.
unknownNotice :: UnknownStreamKey -> Value -> Text
unknownNotice key value =
  let prefix = unknownNoticePrefix key
      budget = maxUnknownNoticeLength - Text.length prefix - 1
      detail = if budget <= 0 then "" else elide budget (excerpt (boundedCompactValue budget value))
   in elide maxUnknownNoticeLength (if Text.null detail then prefix else prefix <> " " <> detail)

-- | The single summary a key with suppressed occurrences leaves behind,
-- reporting how many times it occurred in total.
unknownAggregateNotice :: UnknownStreamKey -> Int -> Text
unknownAggregateNotice key total = elide maxUnknownNoticeLength (unknownNoticePrefix key <> " ×" <> Text.pack (show total))

-- | The category tag and normalized, bounded type label shared by a key's
-- per-occurrence notices and its aggregate summary.
unknownNoticePrefix :: UnknownStreamKey -> Text
unknownNoticePrefix (UnknownStreamKey category usableType) = categoryTag category <> label
  where
    label = maybe unknownTypePlaceholder (elide maxUnknownTypeLength . excerpt) usableType

categoryTag :: UnknownStreamCategory -> Text
categoryTag UnknownTopLevel = "[event] "
categoryTag UnknownCodexItem = "[item] "
categoryTag UnknownClaudeContent = "[content] "

-- | Truncates to at most @limit@ characters, marking any loss with a single
-- ellipsis so a bounded notice never reads as a complete payload. The length
-- probe drops at most @limit@ characters rather than measuring the whole
-- value, so an oversized input is never fully traversed.
elide :: Int -> Text -> Text
elide limit value
  | limit <= 0 = ""
  | Text.null (Text.drop limit value) = value
  | otherwise = Text.take (limit - 1) value <> "…"

-- | A compact JSON rendering truncated to at least @limit@ characters
-- without ever materializing the whole encoded value: 'encode' yields a lazy
-- 'LazyByteString.ByteString', so taking a bounded byte prefix forces only
-- the chunks that prefix needs. Four bytes is UTF-8's maximum per character,
-- so the prefix always carries @limit@ characters when the value has them,
-- and 'lenientDecode' absorbs the partial character the cut may leave.
boundedCompactValue :: Int -> Value -> Text
boundedCompactValue limit =
  TextEncoding.decodeUtf8With lenientDecode
    . LazyByteString.toStrict
    . LazyByteString.take (fromIntegral (4 * max 0 limit + 4))
    . encode

toolEvent :: Value -> [StreamEvent]
toolEvent value =
  let name = fromMaybe "tool" (fieldText "name" value <|> fieldText "tool" value)
      inputValue = fieldValue "input" value <|> fieldValue "arguments" value
      input = fromMaybe "" (compactValue <$> inputValue)
      command = inputValue >>= fieldText "command"
      status = maybe "" (" · " <>) (fieldText "status" value)
   in case command of
        Just commandText
          | Text.toCaseFold name `elem` ["bash", "shell"] ->
              [recognized (AgentEvent "command" ("[command] " <> commandText <> status) input Nothing)]
        _ -> [recognized (AgentEvent "tool" ("[tool] " <> name <> status) input Nothing)]

agentMessage :: Text -> Text -> AgentEvent
agentMessage message detail = AgentEvent "message" message detail (Just message)

errorEvent :: Text -> AgentEvent
errorEvent message = AgentEvent "error" ("[error] " <> message) "" (Just message)

renderAgentEvent :: ChatVerbosity -> AgentEvent -> Maybe Text
renderAgentEvent verbosity event
  | verbosity == CompactChat && event.agentEventKind `elem` ["reasoning", "usage", "event", "plan", "file", "tool-result"] = Nothing
  | verbosity == StandardChat && event.agentEventKind `elem` ["usage", "event"] = Nothing
  | otherwise = Just (event.agentEventSummary <> renderedDetail)
  where
    detail = Text.strip event.agentEventDetail
    renderedDetail
      | Text.null detail = ""
      | verbosity == CompactChat = ""
      | verbosity == StandardChat = "\n  " <> Text.replace "\n" "\n  " (Text.take 2000 detail)
      | otherwise = "\n  " <> Text.replace "\n" "\n  " detail

fieldValue :: Text -> Value -> Maybe Value
fieldValue key (Object values) = KeyMap.lookup (Key.fromText key) values
fieldValue _ _ = Nothing

fieldText :: Text -> Value -> Maybe Text
fieldText key value = fieldValue key value >>= valueText

-- | The literal JSON string at @key@, with none of 'fieldText' \'s coercion
-- of arrays, objects, numbers, and booleans — the strict reading the
-- unknown-payload contract needs, where "the payload had no textual type" and
-- "the payload had a type-shaped object" must not be confused.
--
-- Every @type@ discriminator reads through this, not 'fieldText'. Coercion
-- there would let a non-string type reach a /recognized/ branch and escape
-- the bound entirely: @{"type":["error"],"message":…}@ would forward an
-- arbitrarily large message, and @{"type":["tool_result"]}@ would fall back
-- to the whole raw payload. A non-string type is an unrecognized payload,
-- and must be bounded as one.
fieldString :: Text -> Value -> Maybe Text
fieldString key value = case fieldValue key value of
  Just (String text) -> Just text
  _ -> Nothing

valueText :: Value -> Maybe Text
valueText (String value) = Just value
valueText (Array values) = nonEmptyText (Text.intercalate "\n" (mapMaybe valueText (toList values)))
valueText (Object values) =
  firstText
    [ KeyMap.lookup "text" values,
      KeyMap.lookup "content" values,
      KeyMap.lookup "output" values,
      KeyMap.lookup "summary" values
    ]
valueText value@(Number _) = Just (compactValue value)
valueText (Bool value) = Just (if value then "true" else "false")
valueText Null = Nothing

firstText :: [Maybe Value] -> Maybe Text
firstText = foldr (\candidate fallback -> (candidate >>= valueText) <|> fallback) Nothing

valueList :: Value -> [Value]
valueList (Array values) = toList values
valueList value = [value]

nonEmptyText :: Text -> Maybe Text
nonEmptyText value | Text.null (Text.strip value) = Nothing
nonEmptyText value = Just value

compactValue :: Value -> Text
compactValue = TextEncoding.decodeUtf8With lenientDecode . LazyByteString.toStrict . encode

(<|>) :: Maybe value -> Maybe value -> Maybe value
Just value <|> _ = Just value
Nothing <|> fallback = fallback

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
      mapM_ (\streamEvent -> admitStreamEvent aggregator streamEvent >>= mapM_ (emitMessage lastMessageRef eventSink issueNumber)) messages

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

-- | The one outcome classifier both agent workflows use, so the solve and
-- PR flows can no longer disagree about what a terminal message means. A
-- valid stop-and-ask handoff outranks the exit status: an agent that printed
-- its question and then exited nonzero (a CLI quirk, a cleanup failure after
-- the ask) has still followed the protocol, and needs-input is always more
-- useful to the user than a bare failure that buries the question in error
-- text. Without a handoff the exit status decides, and each workflow passes
-- its own @agentLabel@ so the failure diagnostic keeps its existing wording.
agentOutcome :: Text -> ExitCode -> Text -> SolveOutcome
agentOutcome agentLabel exitCode lastMessage = case needsInputQuestion lastMessage of
  Just question -> SolveNeedsInput question
  Nothing -> case exitCode of
    ExitSuccess -> SolveCompleted
    ExitFailure code ->
      SolveFailed
        ( agentLabel
            <> " exited with status "
            <> Text.pack (show code)
            <> if Text.null (Text.strip lastMessage) then "" else ": " <> Text.take 1000 (Text.strip lastMessage)
        )

solveOutcome :: ExitCode -> Text -> SolveOutcome
solveOutcome = agentOutcome "Solver"

-- | The question from a stop-and-ask handoff, if the agent's final message
-- really carries one. The marker must /begin/ a line (leading whitespace
-- allowed) and be followed by a non-empty question. Anchoring is what makes
-- this trustworthy: the workflow prompts themselves instruct the agent to
-- "stop with exactly KANBAN_NEEDS_INPUT: <question>", so a completion
-- summary that merely quotes that contract mid-sentence would otherwise turn
-- a finished run into a phantom question nobody asked — the card goes orange
-- and autosolve stalls waiting for an answer. When several lines qualify the
-- last one wins, so a resumed session's newest ask is the one that reaches
-- the user.
needsInputQuestion :: Text -> Maybe Text
needsInputQuestion message = case mapMaybe handoffQuestion (Text.lines message) of
  [] -> Nothing
  questions -> Just (last questions)

-- | The question a single line hands off, or 'Nothing' when the line is not
-- an anchored marker line or leaves the question empty.
handoffQuestion :: Text -> Maybe Text
handoffQuestion line = do
  remainder <- Text.stripPrefix needsInputMarker (Text.stripStart line)
  let question = Text.strip remainder
  if Text.null question then Nothing else Just question

needsInputMarker :: Text
needsInputMarker = "KANBAN_NEEDS_INPUT:"

decodeBytes :: ByteString.ByteString -> Text
decodeBytes = Text.strip . TextEncoding.decodeUtf8With lenientDecode

exceptionText :: IOException -> Text
exceptionText = Text.pack . show
