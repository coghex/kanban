{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

module Kanban.PullRequestFlow
  ( PullRequestAction (..),
    PullRequestFlowEvent (..),
    PullRequestOrigin (..),
    PullRequestVerdict (..),
    actionForLabels,
    agentForAction,
    originFromBody,
    pullRequestArguments,
    pullRequestVerdictForLabels,
    runPullRequestFlow,
  )
where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, try, uninterruptibleMask_)
import Control.Monad (void)
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import GHC.Generics (Generic)
import Kanban.Domain (Repository (..), WorkflowConfig (..))
import Kanban.Process (ManagedProcess, managedProcess)
import Kanban.Solve (AgentEvent (..), ResumeProvenance (..), SolveOutcome (..), SolverBrand (..), parseSolveOutputLine, resumeProvenanceHeader)
import Kanban.Transcript (SessionLog, closeSessionLog, logMessage, logRawLine, openSessionLog, sessionLogPath)
import System.Directory (findExecutable)
import System.Exit (ExitCode (..))
import System.IO (BufferMode (..), Handle, hIsEOF, hSetBuffering)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (CreatePipe, NoStream), createProcess, proc, waitForProcess)

data PullRequestOrigin = PullRequestCodex | PullRequestClaude
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data PullRequestAction = PullRequestReview | PullRequestRevision | PullRequestRereview
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data PullRequestFlowEvent
  = PullRequestProcessStarted Int PullRequestAction SolverBrand ManagedProcess
  | PullRequestProcessSpawning Int Bool
  | PullRequestLogOpened Int FilePath
  | PullRequestSessionIdentified Int Text
  | PullRequestFlowOutput Int AgentEvent
  | PullRequestFlowDiagnostic Int Text
  | PullRequestProcessFinished Int SolveOutcome

originFromBody :: Text -> Either Text PullRequestOrigin
originFromBody body
  | codexCount == 1 && claudeCount == 0 && codexMarker `Text.isSuffixOf` stripped = Right PullRequestCodex
  | claudeCount == 1 && codexCount == 0 && claudeMarker `Text.isSuffixOf` stripped = Right PullRequestClaude
  | codexCount > 0 && claudeCount > 0 = Left "PR body contains both pr-origin markers"
  | codexCount > 1 || claudeCount > 1 = Left "PR body contains a duplicate pr-origin marker"
  | codexCount == 1 || claudeCount == 1 = Left "PR origin marker must be the final non-whitespace content"
  | otherwise = Left "PR body has no valid pr-origin marker"
  where
    codexMarker = "<!-- pr-origin:codex -->"
    claudeMarker = "<!-- pr-origin:claude -->"
    codexCount = occurrenceCount codexMarker body
    claudeCount = occurrenceCount claudeMarker body
    stripped = Text.stripEnd body

occurrenceCount :: Text -> Text -> Int
occurrenceCount needle haystack = max 0 (length (Text.splitOn needle haystack) - 1)

actionForLabels :: WorkflowConfig -> [Text] -> PullRequestAction
actionForLabels config labels
  | has "reviewed:revised" = PullRequestRereview
  | has config.changesRequestedLabel = PullRequestRevision
  | otherwise = PullRequestReview
  where
    folded = map Text.toCaseFold labels
    has value = Text.toCaseFold value `elem` folded

-- | The canonical verdict a revised PR currently carries, derived directly
-- from its labels rather than from a Kanban-created @reviewed:revised@
-- handoff: @pr-revise@ invokes the canonical rereview itself, so the fresh
-- verdict lands as @reviewed:approve@ or @reviewed:changes@ once it publishes.
data PullRequestVerdict = PullRequestVerdictApproved | PullRequestVerdictChangesRequested | PullRequestVerdictPending
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

pullRequestVerdictForLabels :: WorkflowConfig -> [Text] -> PullRequestVerdict
pullRequestVerdictForLabels config labels
  | has config.approvalLabel = PullRequestVerdictApproved
  | has config.changesRequestedLabel = PullRequestVerdictChangesRequested
  | otherwise = PullRequestVerdictPending
  where
    folded = map Text.toCaseFold labels
    has value = Text.toCaseFold value `elem` folded

agentForAction :: PullRequestOrigin -> PullRequestAction -> SolverBrand
agentForAction PullRequestCodex PullRequestRevision = CodexSolver
agentForAction PullRequestClaude PullRequestRevision = ClaudeSolver
agentForAction PullRequestCodex _ = ClaudeSolver
agentForAction PullRequestClaude _ = CodexSolver

runPullRequestFlow :: Repository -> Int -> PullRequestOrigin -> PullRequestAction -> Maybe FilePath -> WorkflowConfig -> Maybe Text -> Maybe FilePath -> ResumeProvenance -> Text -> (PullRequestFlowEvent -> IO ()) -> IO ()
runPullRequestFlow repository pullRequestNumber origin action configPath config existingSession existingLogPath provenance userMessage eventSink = do
  let brand = agentForAction origin action
      executableName = if brand == CodexSolver then "codex" else "claude"
  logResult <- openSessionLog repository ("pr-" <> actionName action <> if brand == CodexSolver then "-codex" else "-claude") pullRequestNumber existingLogPath
  sessionLog <- case logResult of
    Left message -> eventSink (PullRequestFlowDiagnostic pullRequestNumber message) >> pure Nothing
    Right value -> do
      eventSink (PullRequestLogOpened pullRequestNumber value.sessionLogPath)
      logMessage value "invocation-started" (actionName action)
      pure (Just value)
  executable <- findExecutable executableName
  case executable of
    Nothing -> closeWithOutcome sessionLog (SolveFailed (Text.pack executableName <> " was not found on PATH"))
    Just executablePath -> do
      -- Masked from before the process is even spawned through its
      -- registration, so a deadline's cancellation can never land in the
      -- gap between a successful 'createProcess' and the event that
      -- reaches 'rememberProvider' — the only way the caller ever learns
      -- about (and can track or kill) this provider. Masking only after
      -- 'createProcess' returned left exactly that gap open.
      --
      -- 'PullRequestProcessSpawning' brackets the spawn attempt itself
      -- (True before 'createProcess', False on every path that concludes
      -- without a live registration) — see 'Kanban.Solve.runSolve' for why
      -- a deadline watchdog racing this exact mask needs this to tell "no
      -- provider was ever spawned" apart from "one was just spawned but
      -- has not been recorded yet".
      started <- uninterruptibleMask_ $ do
        eventSink (PullRequestProcessSpawning pullRequestNumber True)
        result <- try (createProcess (processSpec executablePath brand)) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
        case result of
          Right (Nothing, Just _, Just _, processHandle) -> do
            (managed, groupLeaderProblem) <- managedProcess processHandle
            mapM_ (\problem -> eventSink (PullRequestFlowDiagnostic pullRequestNumber ("process group leadership: " <> problem))) groupLeaderProblem
            eventSink (PullRequestProcessStarted pullRequestNumber action brand managed)
          _ -> eventSink (PullRequestProcessSpawning pullRequestNumber False)
        pure result
      case started of
        Left exception -> closeWithOutcome sessionLog (SolveFailed ("Could not start PR agent: " <> exceptionText exception))
        Right (Nothing, Just outputHandle, Just errorHandle, processHandle) -> do
          hSetBuffering outputHandle LineBuffering
          hSetBuffering errorHandle LineBuffering
          sessionRef <- newIORef existingSession
          lastMessageRef <- newIORef ""
          diagnosticsDone <- newEmptyMVar
          void . forkIO $ streamDiagnostics sessionLog errorHandle eventSink pullRequestNumber >> putMVar diagnosticsDone ()
          streamOutput sessionLog outputHandle sessionRef lastMessageRef eventSink pullRequestNumber
          exitCode <- waitForProcess processHandle
          takeMVar diagnosticsDone
          lastMessage <- readIORef lastMessageRef
          closeWithOutcome sessionLog (flowOutcome exitCode lastMessage)
        Right _ -> closeWithOutcome sessionLog (SolveFailed "PR agent did not provide stdout and stderr pipes")
  where
    repositoryRoot = repository.repositoryRoot
    closeWithOutcome sessionLog outcome = do
      mapM_ (\value -> logMessage value "invocation-finished" (Text.pack (show outcome)) >> closeSessionLog value) sessionLog
      eventSink (PullRequestProcessFinished pullRequestNumber outcome)
    processSpec executablePath brand =
      (proc executablePath (pullRequestArguments pullRequestNumber origin action brand configPath config existingSession provenance userMessage))
        { cwd = Just repositoryRoot,
          std_in = NoStream,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }

pullRequestArguments :: Int -> PullRequestOrigin -> PullRequestAction -> SolverBrand -> Maybe FilePath -> WorkflowConfig -> Maybe Text -> ResumeProvenance -> Text -> [String]
pullRequestArguments number origin action CodexSolver configPath config existingSession provenance userMessage = case existingSession of
  Nothing -> codexBase <> [Text.unpack (initialPrompt number origin action configPath config CodexSolver)]
  Just sessionId -> ["exec", "resume"] <> codexOptions <> [Text.unpack sessionId, Text.unpack (resumePrompt action provenance userMessage)]
  where
    codexBase = ["exec"] <> codexOptions
    codexOptions = ["--model", codexModel action, "--config", "model_reasoning_effort=\"" <> codexEffort action <> "\"", "--config", "model_reasoning_summary=\"detailed\"", "--dangerously-bypass-approvals-and-sandbox", "--json"]
pullRequestArguments number origin action ClaudeSolver configPath config existingSession provenance userMessage =
  ["--print", "--model", claudeModel action, "--effort", claudeEffort action, "--permission-mode", "bypassPermissions", "--output-format", "stream-json", "--verbose"]
    <> maybe [] (\sessionId -> ["--resume", Text.unpack sessionId]) existingSession
    <> [Text.unpack (if existingSession == Nothing then initialPrompt number origin action configPath config ClaudeSolver else resumePrompt action provenance userMessage)]

codexModel :: PullRequestAction -> String
codexModel PullRequestRevision = "gpt-5.4"
codexModel _ = "gpt-5.6-terra"

codexEffort :: PullRequestAction -> String
codexEffort PullRequestRevision = "high"
codexEffort _ = "xhigh"

claudeModel :: PullRequestAction -> String
claudeModel PullRequestRevision = "claude-sonnet-5"
claudeModel _ = "claude-opus-4-8"

claudeEffort :: PullRequestAction -> String
claudeEffort _ = "xhigh"

initialPrompt :: Int -> PullRequestOrigin -> PullRequestAction -> Maybe FilePath -> WorkflowConfig -> SolverBrand -> Text
initialPrompt number _origin action configPath config brand = Text.unlines (actionLines <> configLines <> interactionLines)
  where
    commandName name = if brand == CodexSolver then "$" <> name else "/" <> name
    configLines = case configPath of
      Nothing -> []
      Just path ->
        [ "Pass --config "
            <> Text.pack path
            <> " to "
            <> commandName "pr-review"
            <> ", "
            <> commandName "pr-rereview"
            <> ", or "
            <> commandName "pr-revise"
            <> " (whichever applies) so it resolves the same configured workflow labels as this dashboard."
        ]
    actionLines = case action of
      PullRequestReview ->
        [ "Run " <> commandName "pr-review" <> " for PR #" <> numberText <> ".",
          "Review only. Use the canonical opposite-brand workflow, publish its verdict, and never edit or merge the PR."
        ]
      PullRequestRereview ->
        [ "Run " <> commandName "pr-rereview" <> " for PR #" <> numberText <> ".",
          "Rereview the current head, publish the canonical verdict, and never edit or merge the PR. Remove reviewed:revised after successfully publishing the verdict."
        ]
      PullRequestRevision ->
        [ "Run " <> commandName "pr-revise" <> " for PR #" <> numberText <> ".",
          "Use the canonical revise-and-rereview workflow: act only on a current canonical CHANGES_REQUESTED verdict for this head, rerouting stale feedback through canonical rereview before editing; work only in a clean isolated worktree and never overwrite a concurrently updated head; after pushing, wait for required CI on the pushed head, then invoke exactly one canonical PR rereview.",
          "Never merge, and leave "
            <> config.approvalLabel
            <> ", "
            <> config.changesRequestedLabel
            <> ", and reviewed:revised to the canonical review coordinator."
        ]
    interactionLines =
      [ "If ambiguity, credentials, or a product decision blocks safe progress, stop with exactly KANBAN_NEEDS_INPUT: <one concrete question>. Do not guess.",
        "Finish with the PR number, action, head commit, checks, publication/push status, and next expected r action."
      ]
    numberText = Text.pack (show number)

resumePrompt :: PullRequestAction -> ResumeProvenance -> Text -> Text
resumePrompt action provenance answer = Text.unlines [resumeProvenanceHeader provenance, Text.strip answer, "Continue the same " <> actionName action <> " workflow. Stop with KANBAN_NEEDS_INPUT: <question> if another decision is required."]

actionName :: PullRequestAction -> Text
actionName PullRequestReview = "review"
actionName PullRequestRevision = "revision"
actionName PullRequestRereview = "rereview"

streamOutput :: Maybe SessionLog -> Handle -> IORef (Maybe Text) -> IORef Text -> (PullRequestFlowEvent -> IO ()) -> Int -> IO ()
streamOutput sessionLog handle sessionRef lastMessageRef eventSink number = do
  eof <- hIsEOF handle
  if eof then pure () else do
    lineResult <- try (ByteStringChar8.hGetLine handle) :: IO (Either IOException ByteString.ByteString)
    case lineResult of
      Left exception -> eventSink (PullRequestFlowDiagnostic number (exceptionText exception))
      Right line -> do
        mapM_ (\value -> logRawLine value "stdout" line) sessionLog
        case parseSolveOutputLine line of
          Left _ -> emitDiagnostic line
          Right (sessionId, messages) -> do
            case sessionId of
              Nothing -> pure ()
              Just value -> writeIORef sessionRef (Just value) >> eventSink (PullRequestSessionIdentified number value)
            mapM_ emitMessage messages
    streamOutput sessionLog handle sessionRef lastMessageRef eventSink number
  where
    emitMessage agentEvent
      | Text.null (Text.strip agentEvent.agentEventSummary) = pure ()
      | otherwise = do
          mapM_ (\message -> atomicModifyIORef' lastMessageRef (const (message, ()))) agentEvent.agentEventOutcomeText
          eventSink (PullRequestFlowOutput number agentEvent)
    emitDiagnostic line = let message = decodeBytes line in if Text.null message then pure () else eventSink (PullRequestFlowDiagnostic number message)

streamDiagnostics :: Maybe SessionLog -> Handle -> (PullRequestFlowEvent -> IO ()) -> Int -> IO ()
streamDiagnostics sessionLog handle eventSink number = do
  eof <- hIsEOF handle
  if eof then pure () else do
    result <- try (ByteStringChar8.hGetLine handle) :: IO (Either IOException ByteString.ByteString)
    case result of
      Right line | not (ByteString.null line) -> do
        mapM_ (\value -> logRawLine value "stderr" line) sessionLog
        eventSink (PullRequestFlowDiagnostic number (decodeBytes line))
      _ -> pure ()
    streamDiagnostics sessionLog handle eventSink number

flowOutcome :: ExitCode -> Text -> SolveOutcome
flowOutcome ExitSuccess message = case Text.breakOnEnd "KANBAN_NEEDS_INPUT:" message of
  (prefix, question) | not (Text.null prefix) && not (Text.null (Text.strip question)) -> SolveNeedsInput (Text.strip (Text.takeWhile (/= '\n') question))
  _ -> SolveCompleted
flowOutcome (ExitFailure code) message = SolveFailed ("PR agent exited with status " <> Text.pack (show code) <> if Text.null (Text.strip message) then "" else ": " <> Text.take 1000 (Text.strip message))

decodeBytes :: ByteString.ByteString -> Text
decodeBytes = Text.strip . TextEncoding.decodeUtf8With lenientDecode

exceptionText :: IOException -> Text
exceptionText = Text.pack . show
