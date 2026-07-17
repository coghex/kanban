{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

module Kanban.Solve
  ( AgentEvent (..),
    SolveEvent (..),
    SolveOutcome (..),
    SolveWorkflow (..),
    SolverBrand (..),
    codexSolverModel,
    claudeSolverModel,
    codexReviewerModel,
    claudeReviewerModel,
    parseSolveOutputLine,
    renderAgentEvent,
    runSolve,
    solveArguments,
    solverLabel,
  )
where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, try)
import Control.Monad (void)
import Data.Aeson (FromJSON, ToJSON, Value (..), eitherDecodeStrict', encode)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Foldable (toList)
import GHC.Generics (Generic)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Kanban.Domain (Repository (..))
import Kanban.Process (ManagedProcess, managedProcess)
import Kanban.Settings (ChatVerbosity (..))
import Kanban.Transcript (SessionLog, closeSessionLog, logMessage, logRawLine, openSessionLog, sessionLogPath)
import System.Directory (findExecutable)
import System.Exit (ExitCode (..))
import System.IO (BufferMode (..), Handle, hIsEOF, hSetBuffering)
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

data SolveOutcome
  = SolveCompleted
  | SolveNeedsInput Text
  | SolveFailed Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data SolveEvent
  = SolveProcessStarted Int SolverBrand ManagedProcess
  | SolveLogOpened Int FilePath
  | SolveSessionIdentified Int Text
  | SolveOutput Int AgentEvent
  | SolveDiagnostic Int Text
  | SolveProcessFinished Int SolveOutcome

data ParsedSolveOutput = ParsedSolveOutput
  { parsedSessionId :: Maybe Text,
    parsedMessages :: [AgentEvent]
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

codexSolverModel :: Text
codexSolverModel = "gpt-5.4 high"

claudeSolverModel :: Text
claudeSolverModel = "Sonnet 5 high"

codexReviewerModel :: Text
codexReviewerModel = "GPT-5.6-Terra xhigh"

claudeReviewerModel :: Text
claudeReviewerModel = "Opus 4.8 xhigh"

solverLabel :: SolverBrand -> Text
solverLabel CodexSolver = "codex · " <> codexSolverModel
solverLabel ClaudeSolver = "claude · " <> claudeSolverModel

runSolve :: Repository -> Int -> SolveWorkflow -> SolverBrand -> Maybe Text -> Maybe FilePath -> Text -> (SolveEvent -> IO ()) -> IO ()
runSolve repository issueNumber workflow brand existingSession existingLogPath userMessage eventSink = do
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
      started <- try (createProcess (processSpec executablePath)) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
      case started of
        Left exception -> finishWithoutProcess sessionLog (SolveFailed ("Could not start " <> Text.pack executableName <> ": " <> exceptionText exception))
        Right (Nothing, Just outputHandle, Just errorHandle, processHandle) -> do
          eventSink (SolveProcessStarted issueNumber brand (managedProcess processHandle))
          hSetBuffering outputHandle LineBuffering
          hSetBuffering errorHandle LineBuffering
          sessionRef <- newIORef existingSession
          lastMessageRef <- newIORef ""
          diagnosticsDone <- newEmptyMVar
          void . forkIO $ streamDiagnostics sessionLog errorHandle eventSink issueNumber >> putMVar diagnosticsDone ()
          streamOutput sessionLog outputHandle sessionRef lastMessageRef eventSink issueNumber
          exitCode <- waitForProcess processHandle
          takeMVar diagnosticsDone
          lastMessage <- readIORef lastMessageRef
          let outcome = solveOutcome exitCode lastMessage
          closeWithOutcome sessionLog outcome
        Right _ -> finishWithoutProcess sessionLog (SolveFailed (Text.pack executableName <> " did not provide stdout and stderr pipes"))
  where
    repositoryRoot = repository.repositoryRoot
    executableName = case brand of
      CodexSolver -> "codex"
      ClaudeSolver -> "claude"
    solverName CodexSolver = "codex"
    solverName ClaudeSolver = "claude"
    finishWithoutProcess sessionLog outcome = closeWithOutcome sessionLog outcome
    closeWithOutcome sessionLog outcome = do
      mapM_ (\value -> logMessage value "invocation-finished" (Text.pack (show outcome)) >> closeSessionLog value) sessionLog
      eventSink (SolveProcessFinished issueNumber outcome)
    processSpec executablePath =
      (proc executablePath (solveArguments issueNumber workflow brand existingSession userMessage))
        { cwd = Just repositoryRoot,
          std_out = CreatePipe,
          std_err = CreatePipe,
          std_in = NoStream,
          create_group = True
        }

solveArguments :: Int -> SolveWorkflow -> SolverBrand -> Maybe Text -> Text -> [String]
solveArguments issueNumber workflow CodexSolver existingSession userMessage =
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
        Text.unpack (initialSolvePrompt issueNumber workflow CodexSolver)
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
        Text.unpack (resumeSolvePrompt workflow CodexSolver userMessage)
      ]
solveArguments issueNumber workflow ClaudeSolver existingSession userMessage =
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
    <> [Text.unpack (if existingSession == Nothing then initialSolvePrompt issueNumber workflow ClaudeSolver else resumeSolvePrompt workflow ClaudeSolver userMessage)]

initialSolvePrompt :: Int -> SolveWorkflow -> SolverBrand -> Text
initialSolvePrompt issueNumber workflow brand =
  Text.unlines
    [ "Run the " <> workflowName workflow brand <> " workflow for GitHub issue #" <> Text.pack (show issueNumber) <> " in this repository.",
      "You are the canonical " <> solverLabel brand <> " solver selected explicitly by the user.",
      workflowContract,
      interruptedWorktreeRecovery,
      "Do not run issue-review, issue-rereview, approve-issues.py --review, or approve-issues.py --rereview from this solve session. Kanban's r workflow owns that gate. Run only the required read-only v2 gate check; if it is not approved, stop with KANBAN_NEEDS_INPUT: This issue needs canonical review; press r on the issue, then retry.",
      "Interaction contract: if a product choice, ambiguity, credentials problem, or other user decision blocks safe progress, do not guess and do not continue. End your response with exactly one line in the form KANBAN_NEEDS_INPUT: <one concrete question>. Kanban will resume this same session with the answer.",
      completionContract
    ]
  where
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

resumeSolvePrompt :: SolveWorkflow -> SolverBrand -> Text -> Text
resumeSolvePrompt workflow brand answer =
  Text.unlines
    [ "The user answered the Kanban workflow question:",
      Text.strip answer,
      "Continue the same " <> workflowName workflow brand <> " workflow from its current state. Apply the same interaction contract: stop with KANBAN_NEEDS_INPUT: <question> rather than guessing if another user decision is required."
    ]

parseSolveOutputLine :: ByteString.ByteString -> Either Text (Maybe Text, [AgentEvent])
parseSolveOutputLine bytes = do
  value <- case eitherDecodeStrict' bytes of
    Left message -> Left (Text.pack message)
    Right decoded -> Right decoded
  let parsed = parseSolveValue value
  pure (parsed.parsedSessionId, parsed.parsedMessages)

parseSolveValue :: Value -> ParsedSolveOutput
parseSolveValue value = case fieldText "type" value of
  Just "thread.started" -> ParsedSolveOutput (fieldText "thread_id" value) []
  Just "system" -> ParsedSolveOutput (fieldText "session_id" value) []
  Just "item.completed" -> ParsedSolveOutput Nothing (maybe [] parseCodexItem (fieldValue "item" value))
  Just "assistant" -> ParsedSolveOutput Nothing (maybe [] parseClaudeMessage (fieldValue "message" value))
  Just "user" -> ParsedSolveOutput Nothing (maybe [] parseClaudeMessage (fieldValue "message" value))
  Just "result" ->
    let resultText = fieldText "result" value
        usage = maybe "" (("usage: " <>) . compactValue) (fieldValue "usage" value)
     in ParsedSolveOutput (fieldText "session_id" value) (maybe [] (\message -> [agentMessage message usage]) resultText)
  Just "turn.completed" -> ParsedSolveOutput Nothing (maybe [] (\usage -> [AgentEvent "usage" "[usage] turn complete" (compactValue usage) Nothing]) (fieldValue "usage" value))
  Just "error" -> ParsedSolveOutput Nothing [errorEvent (fromMaybe (compactValue value) (fieldText "message" value))]
  messageType -> ParsedSolveOutput Nothing [AgentEvent "event" ("[event] " <> fromMaybe "unknown" messageType) (compactValue value) Nothing]

parseCodexItem :: Value -> [AgentEvent]
parseCodexItem item = case fieldText "type" item of
  Just "agent_message" -> maybe [] (\message -> [agentMessage message ""]) (fieldText "text" item)
  Just "reasoning" ->
    let reasoning = firstText [fieldValue "summary" item, fieldValue "text" item, fieldValue "content" item]
     in maybe [] (\message -> [AgentEvent "reasoning" "[reasoning]" message Nothing]) reasoning
  Just "command_execution" ->
    let command = fromMaybe "" (fieldText "command" item)
        status = maybe "" (" · " <>) (fieldText "status" item)
        output = fromMaybe "" (firstText [fieldValue "aggregated_output" item, fieldValue "output" item])
     in [AgentEvent "command" ("[command] " <> command <> status) output Nothing | not (Text.null command)]
  Just "file_change" -> [AgentEvent "file" "[files] changes applied" (compactValue item) Nothing]
  Just "mcp_tool_call" -> toolEvent item
  Just "web_search" -> [AgentEvent "tool" "[web search] " (compactValue item) Nothing]
  Just "todo_list" -> [AgentEvent "plan" "[plan] updated" (compactValue item) Nothing]
  Just "error" -> maybe [] (pure . errorEvent) (fieldText "message" item)
  itemType -> [AgentEvent "event" ("[item] " <> fromMaybe "unknown" itemType) (compactValue item) Nothing]

parseClaudeMessage :: Value -> [AgentEvent]
parseClaudeMessage message = maybe [] (concatMap parseClaudeContent . valueList) (fieldValue "content" message)

parseClaudeContent :: Value -> [AgentEvent]
parseClaudeContent content = case fieldText "type" content of
  Just "text" -> maybe [] (\message -> [agentMessage message ""]) (fieldText "text" content)
  Just "thinking" -> maybe [] (\message -> [AgentEvent "reasoning" "[reasoning]" message Nothing]) (firstText [fieldValue "thinking" content, fieldValue "text" content])
  Just "tool_use" -> toolEvent content
  Just "tool_result" ->
    let result = fromMaybe (compactValue content) (firstText [fieldValue "content" content, fieldValue "result" content])
     in [AgentEvent "tool-result" "[tool result]" result Nothing]
  contentType -> [AgentEvent "event" ("[content] " <> fromMaybe "unknown" contentType) (compactValue content) Nothing]

toolEvent :: Value -> [AgentEvent]
toolEvent value =
  let name = fromMaybe "tool" (fieldText "name" value <|> fieldText "tool" value)
      inputValue = fieldValue "input" value <|> fieldValue "arguments" value
      input = fromMaybe "" (compactValue <$> inputValue)
      command = inputValue >>= fieldText "command"
      status = maybe "" (" · " <>) (fieldText "status" value)
   in case command of
        Just commandText
          | Text.toCaseFold name `elem` ["bash", "shell"] ->
              [AgentEvent "command" ("[command] " <> commandText <> status) input Nothing]
        _ -> [AgentEvent "tool" ("[tool] " <> name <> status) input Nothing]

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

streamOutput :: Maybe SessionLog -> Handle -> IORef (Maybe Text) -> IORef Text -> (SolveEvent -> IO ()) -> Int -> IO ()
streamOutput sessionLog handle sessionRef lastMessageRef eventSink issueNumber = do
  eof <- hIsEOF handle
  if eof
    then pure ()
    else do
      lineResult <- try (ByteStringChar8.hGetLine handle) :: IO (Either IOException ByteString.ByteString)
      case lineResult of
        Left exception -> eventSink (SolveDiagnostic issueNumber ("Could not read solver output: " <> exceptionText exception))
        Right line -> do
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
              mapM_ (emitMessage lastMessageRef eventSink issueNumber) messages
          streamOutput sessionLog handle sessionRef lastMessageRef eventSink issueNumber

emitMessage :: IORef Text -> (SolveEvent -> IO ()) -> Int -> AgentEvent -> IO ()
emitMessage lastMessageRef eventSink issueNumber agentEvent
  | Text.null (Text.strip agentEvent.agentEventSummary) = pure ()
  | otherwise = do
      mapM_ (\message -> atomicModifyIORef' lastMessageRef (const (message, ()))) agentEvent.agentEventOutcomeText
      eventSink (SolveOutput issueNumber agentEvent)

streamDiagnostics :: Maybe SessionLog -> Handle -> (SolveEvent -> IO ()) -> Int -> IO ()
streamDiagnostics sessionLog handle eventSink issueNumber = do
  eof <- hIsEOF handle
  if eof
    then pure ()
    else do
      lineResult <- try (ByteStringChar8.hGetLine handle) :: IO (Either IOException ByteString.ByteString)
      case lineResult of
        Left _ -> pure ()
        Right line
          | ByteString.null line -> pure ()
          | otherwise -> do
              mapM_ (\value -> logRawLine value "stderr" line) sessionLog
              eventSink (SolveDiagnostic issueNumber (decodeBytes line))
      streamDiagnostics sessionLog handle eventSink issueNumber

solveOutcome :: ExitCode -> Text -> SolveOutcome
solveOutcome ExitSuccess lastMessage = case needsInputQuestion lastMessage of
  Just question -> SolveNeedsInput question
  Nothing -> SolveCompleted
solveOutcome (ExitFailure code) lastMessage =
  SolveFailed
    ( "Solver exited with status "
        <> Text.pack (show code)
        <> if Text.null (Text.strip lastMessage) then "" else ": " <> Text.take 1000 (Text.strip lastMessage)
    )

needsInputQuestion :: Text -> Maybe Text
needsInputQuestion message =
  case Text.breakOnEnd needsInputMarker message of
    (prefix, question)
      | Text.null prefix || Text.null (Text.strip question) -> Nothing
      | otherwise -> Just (Text.strip (Text.takeWhile (/= '\n') question))

needsInputMarker :: Text
needsInputMarker = "KANBAN_NEEDS_INPUT:"

decodeBytes :: ByteString.ByteString -> Text
decodeBytes = Text.strip . TextEncoding.decodeUtf8With lenientDecode

exceptionText :: IOException -> Text
exceptionText = Text.pack . show
