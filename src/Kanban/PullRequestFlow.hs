{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

module Kanban.PullRequestFlow
  ( PullRequestAction (..),
    PullRequestFlowEvent (..),
    PullRequestOrigin (..),
    PullRequestVerdict (..),
    actionForLabels,
    agentForAction,
    authoredOnOwnBrand,
    directPullRequestAction,
    expectedPullRequestOrigin,
    flowOutcome,
    labelPullRequestAction,
    originFromBody,
    pullRequestArguments,
    pullRequestAssignment,
    pullRequestRole,
    pullRequestVerdictEvidence,
    recordedPullRequestBrand,
    pullRequestVerdictForLabels,
    runPullRequestFlow,
    runPullRequestFlowWith,
    solveReviewerAssignment,
  )
where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, finally, try, uninterruptibleMask_)
import Control.Monad (void)
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import GHC.Generics (Generic)
import Kanban.Domain (BoardColumn (..), Label (..), PullRequest (..), Repository (..), WorkflowConfig (..))
import Kanban.Models
  ( Assignment (..),
    AssignmentUnavailable,
    ModelRoster,
    OperatingMode,
    RecordedAssignment (..),
    RoleName (..),
    assignmentFor,
    operatingModeFor,
    recordAssignment,
    soleAgent,
  )
import Kanban.Process (ManagedProcess, managedProcess)
import Kanban.ProviderAdapter (ProcessRequest (..), ProviderAdapter (..), adapterForBrand, brandForProvider, providerForBrand)
import Kanban.Solve (AgentEvent (..), ResumeProvenance (..), SolveOutcome (..), SolverBrand (..), UnknownAggregator, agentOutcome, emitStreamEvent, parseSolveOutputLine, resumeProvenanceHeader, sealUnknownAggregates)
import Kanban.StreamReader (handleReadLine, onStreamAbandoned, runStreamReaderWith)
import Kanban.Transcript (SessionLog, closeSessionLog, logMessage, logRawLine, openSessionLog, sessionLogPath)
import Kanban.Workflow (CardStatus (..), classifyPullRequest, pullRequestStatus)
import System.Directory (findExecutable)
import System.Exit (ExitCode (..))
import System.IO (BufferMode (..), Handle, hSetBuffering)
import System.Process (ProcessHandle, createProcess, waitForProcess)

data PullRequestOrigin = PullRequestCodex | PullRequestClaude
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data PullRequestAction = PullRequestReview | PullRequestRevision | PullRequestRereview | PullRequestRepair
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

-- | The label-derived action alone. This is what Kanban's own automated
-- progressions use: autosolve drives its pull request through review and
-- revise itself, and must keep doing exactly that rather than turning into a
-- repair launch merely because the pull request reports a problem status.
labelPullRequestAction :: WorkflowConfig -> PullRequest -> PullRequestAction
labelPullRequestAction config pullRequest =
  actionForLabels config (map (.labelName) pullRequest.pullRequestLabels)

-- | The action the user's own @r@ selects for a pull request:
-- 'labelPullRequestAction', except for a card that is both in Done and
-- reporting a problem, which repairs its own code instead.
--
-- Both halves are required. 'pullRequestStatus' also reports a merge
-- conflict, failed checks, or a red blocking label for a draft or unapproved
-- pull request, and 'classifyPullRequest' keeps those in Reviewing, where
-- review, rereview, and revise still apply. Equally, Done membership alone
-- means nothing here: an approved card with a clean status keeps whatever
-- action its labels derive — which includes revision, e.g. under
-- 'ApprovalByReview' with the configured changes-requested label still on it
-- and 'SeverityAmber' keeping that label out of problem status.
directPullRequestAction :: WorkflowConfig -> PullRequest -> PullRequestAction
directPullRequestAction config pullRequest
  | classifyPullRequest config pullRequest == Done,
    StatusProblem _ <- pullRequestStatus config pullRequest =
      PullRequestRepair
  | otherwise = labelPullRequestAction config pullRequest

-- | The canonical verdict a revised PR currently carries, derived directly
-- from its labels rather than from a Kanban-created @reviewed:revised@
-- handoff: @pr-revise@ invokes the canonical rereview itself, so the fresh
-- verdict lands as @reviewed:approve@ or @reviewed:changes@ once it publishes.
data PullRequestVerdict = PullRequestVerdictApproved | PullRequestVerdictChangesRequested | PullRequestVerdictPending
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

pullRequestVerdictForLabels :: WorkflowConfig -> [Text] -> PullRequestVerdict
pullRequestVerdictForLabels config labels
  | carriesLabel config labels config.approvalLabel = PullRequestVerdictApproved
  | carriesLabel config labels config.changesRequestedLabel = PullRequestVerdictChangesRequested
  | otherwise = PullRequestVerdictPending

-- | The canonical verdict a pull request /unambiguously/ carries, or why it
-- carries none.
--
-- 'pullRequestVerdictForLabels' prefers approval when both labels are somehow
-- present, which is the right answer for a badge and the wrong one for
-- evidence: a pull request carrying both has had two contradictory verdicts
-- published on it and nothing about it is settled. The canonical coordinator
-- switches exactly one label, so this state means something went wrong rather
-- than that the pull request was approved.
--
-- Every caller about to /act/ on a verdict asks this instead — to complete an
-- autosolve run, or to report a registry action's terminal result — because
-- conflicting evidence must never be promoted to success.
pullRequestVerdictEvidence :: WorkflowConfig -> [Text] -> Either Text PullRequestVerdict
pullRequestVerdictEvidence config labels
  | carriesLabel config labels config.approvalLabel && carriesLabel config labels config.changesRequestedLabel =
      Left "carries both the approval and changes-requested labels, so its canonical verdict is contradictory"
  | otherwise = Right (pullRequestVerdictForLabels config labels)

-- | Whether a label set carries one configured label, folded as GitHub
-- compares them.
carriesLabel :: WorkflowConfig -> [Text] -> Text -> Bool
carriesLabel _ labels value = Text.toCaseFold value `elem` map Text.toCaseFold labels

-- | Whether an action works on the pull request's own code and therefore
-- runs on its origin brand, handing its verdict off to exactly one nested
-- canonical rereview (agent-workflow-contract §2.2, §2.7). Review and
-- rereview are that canonical gate themselves.
--
-- The split alone, not the brands: which side of it an action is on is a
-- property of the action, while which brand each side actually spawns is
-- 'agentForAction''s answer and moves with the operating mode. In dual mode
-- the nested rereview is the opposite brand and the gate is the opposite
-- brand; in single-agent both are the one loaded provider.
authoredOnOwnBrand :: PullRequestAction -> Bool
authoredOnOwnBrand action = action `elem` [PullRequestRevision, PullRequestRepair]

-- | The brand one pull-request action runs on.
--
-- In dual mode this is the cross-brand routing 'crossBrandAgentForAction'
-- below spells out: the origin marker decides, and the action decides which
-- side of it. In single-agent mode the marker decides nothing — there is one
-- loaded provider and every action runs on it, whatever the pull request was
-- authored by and including a pull request whose origin is unknown or
-- external (D-8, agent-workflow-contract §2.2). The markers are still written
-- in that mode (D-12); it is the routing that stops reading them, not the
-- solve that stops stamping them.
--
-- No-agent mode answers as dual does. It routes nothing, because
-- 'Kanban.UI.Keys.availableIn' refuses the bindings that would reach here and
-- 'pullRequestAssignment' below finds no cell for either brand, so the value
-- this returns is never spawned on.
agentForAction :: OperatingMode -> PullRequestOrigin -> PullRequestAction -> SolverBrand
agentForAction mode origin action = case soleAgent mode of
  Just provider -> brandForProvider provider
  Nothing -> crossBrandAgentForAction origin action

-- | The dual-mode half of 'agentForAction': an action on the pull request's
-- own code runs on its origin brand, and the canonical gate runs on the
-- opposite one. Unchanged, and separated out so the mode-aware routing above
-- has one thing to fall back to rather than four arms to interleave.
crossBrandAgentForAction :: PullRequestOrigin -> PullRequestAction -> SolverBrand
crossBrandAgentForAction PullRequestCodex action | authoredOnOwnBrand action = CodexSolver
crossBrandAgentForAction PullRequestClaude action | authoredOnOwnBrand action = ClaudeSolver
crossBrandAgentForAction PullRequestCodex _ = ClaudeSolver
crossBrandAgentForAction PullRequestClaude _ = CodexSolver

-- | The brand a pull-request worker that already exists is running on.
--
-- The recorded assignment wins whenever there is one, for the reason
-- @docs\/design.md@ gives for replaying a cell rather than resolving it: the
-- launch that started this worker refused or allowed itself against a
-- specific provider, and a @models.toml@ edited since — including one that
-- moved the install between modes — must not change what a running process is
-- reported as. Live routing is only the answer for a specification written
-- before the record existed.
recordedPullRequestBrand :: OperatingMode -> Maybe RecordedAssignment -> PullRequestOrigin -> PullRequestAction -> SolverBrand
recordedPullRequestBrand mode recorded origin action =
  maybe (agentForAction mode origin action) (brandForProvider . (.recordedAssignmentProvider)) recorded

-- | An action that edits the pull request's own code is authored work and
-- takes the author-side role; review and rereview are the canonical gate and
-- take the reviewer's. The one declaration of that split, replacing the four
-- literal-returning selection functions this slice removed.
pullRequestRole :: PullRequestAction -> RoleName
pullRequestRole action
  | authoredOnOwnBrand action = PrReviseRole
  | otherwise = PrReviewRole

-- | The roster cell a pull-request invocation runs on, from the brand
-- 'agentForAction' already routes it to. Shared by the UI boundary that
-- refuses on it and by the launch that records it, and — like
-- 'Kanban.Solve.solveAssignment' — it hands back the provider it resolved
-- through, because the record outlives the routing that selected it.
pullRequestAssignment :: ModelRoster -> PullRequestOrigin -> PullRequestAction -> Either AssignmentUnavailable RecordedAssignment
pullRequestAssignment roster origin action =
  recordAssignment provider <$> assignmentFor roster (pullRequestRole action) provider
  where
    -- The mode comes off the same roster the cell is looked up in rather than
    -- being threaded in beside it, so the routing and the lookup can never be
    -- asked of two different rosters. That is the same 'operatingModeFor' the
    -- dashboard's own 'Kanban.UI.Types.appOperatingMode' is built from.
    provider = providerForBrand (agentForAction (operatingModeFor roster) origin action)

-- | The origin marker the pull request a solve of this brand opens will
-- carry, and therefore the routing every later action on it takes.
--
-- Declared here rather than beside the autosolve loop that reads it: it is
-- the same origin-to-brand routing 'agentForAction' inverts, and a second
-- copy is how the reviewer a session /names/ could come to disagree with the
-- reviewer it later spawns.
expectedPullRequestOrigin :: SolverBrand -> PullRequestOrigin
expectedPullRequestOrigin CodexSolver = PullRequestCodex
expectedPullRequestOrigin ClaudeSolver = PullRequestClaude

-- | The cell an autosolve run's review step will resolve: the opposite
-- brand's @pr_review@ assignment, reached through 'expectedPullRequestOrigin'
-- and 'pullRequestAssignment' rather than by naming the other brand here.
--
-- Resolved live wherever it is shown. The reviewer has no worker of its own
-- yet -- it is the assignment a review this run has not started would take --
-- so there is nothing recorded to replay, and a roster edited between the
-- solve and its review is honestly reflected by the line changing with it.
solveReviewerAssignment :: ModelRoster -> SolverBrand -> Either AssignmentUnavailable RecordedAssignment
solveReviewerAssignment roster brand =
  pullRequestAssignment roster (expectedPullRequestOrigin brand) PullRequestReview

-- | The brand is an argument rather than 'agentForAction' applied here: the
-- supervisor spawns whichever provider its recorded assignment names, and
-- re-deriving one from the origin and action would let a replayed launch
-- pair a recorded model with the other brand's executable (D-7).
runPullRequestFlow :: Repository -> Int -> PullRequestOrigin -> PullRequestAction -> SolverBrand -> Maybe FilePath -> WorkflowConfig -> Assignment -> Maybe Text -> Maybe FilePath -> ResumeProvenance -> Text -> UnknownAggregator -> (PullRequestFlowEvent -> IO ()) -> IO ()
runPullRequestFlow = runPullRequestFlowWith (const handleReadLine)

-- | As 'runPullRequestFlow', but reads stdout/stderr via an injected
-- primitive instead of always wrapping the real 'Handle' with
-- 'handleReadLine' — see 'Kanban.Solve.runSolveWith' for why this seam
-- exists: it is what lets a test deterministically drive a still-live
-- provider through the shared reader's abandonment path. The primitive is
-- given the stream tag ("stdout"/"stderr") alongside the handle so a test
-- can target one stream's abandonment path without racing the other's.
runPullRequestFlowWith :: (Text -> Handle -> IO (Either IOException (Maybe ByteString.ByteString))) -> Repository -> Int -> PullRequestOrigin -> PullRequestAction -> SolverBrand -> Maybe FilePath -> WorkflowConfig -> Assignment -> Maybe Text -> Maybe FilePath -> ResumeProvenance -> Text -> UnknownAggregator -> (PullRequestFlowEvent -> IO ()) -> IO ()
runPullRequestFlowWith readLineFor repository pullRequestNumber origin action brand configPath config assignment existingSession existingLogPath provenance userMessage aggregator eventSink = do
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
      managedRef <- newIORef Nothing
      started <- uninterruptibleMask_ $ do
        eventSink (PullRequestProcessSpawning pullRequestNumber True)
        result <- try (createProcess (processSpec executablePath)) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
        case result of
          Right (Nothing, Just _, Just _, processHandle) -> do
            (managed, groupLeaderProblem) <- managedProcess processHandle
            writeIORef managedRef (Just managed)
            mapM_ (\problem -> eventSink (PullRequestFlowDiagnostic pullRequestNumber ("process group leadership: " <> problem))) groupLeaderProblem
            eventSink (PullRequestProcessStarted pullRequestNumber action brand managed)
          _ -> eventSink (PullRequestProcessSpawning pullRequestNumber False)
        pure result
      case started of
        Left exception -> closeWithOutcome sessionLog (SolveFailed ("Could not start PR agent: " <> exceptionText exception))
        Right (Nothing, Just outputHandle, Just errorHandle, processHandle) -> do
          hSetBuffering outputHandle LineBuffering
          hSetBuffering errorHandle LineBuffering
          managedResult <- readIORef managedRef
          case managedResult of
            Nothing -> closeWithOutcome sessionLog (SolveFailed "internal error: PR agent process was not registered as managed")
            Just managed -> do
              sessionRef <- newIORef existingSession
              lastMessageRef <- newIORef ""
              abandonReasonRef <- newIORef Nothing
              diagnosticsDone <- newEmptyMVar
              let abandon = onStreamAbandoned (eventSink . PullRequestFlowDiagnostic pullRequestNumber) managed abandonReasonRef
              void . forkIO $
                void (runStreamReaderWith (readLineFor "stderr" errorHandle) "stderr" (stderrOnLine sessionLog eventSink pullRequestNumber) abandon)
                  `finally` putMVar diagnosticsDone ()
              _ <- runStreamReaderWith (readLineFor "stdout" outputHandle) "stdout" (stdoutOnLine sessionLog aggregator sessionRef lastMessageRef eventSink pullRequestNumber) abandon
              exitCode <- waitForProcess processHandle
              takeMVar diagnosticsDone
              lastMessage <- readIORef lastMessageRef
              abandonReason <- readIORef abandonReasonRef
              let outcome = maybe (flowOutcome exitCode lastMessage) SolveFailed abandonReason
              closeWithOutcome sessionLog outcome
        Right _ -> closeWithOutcome sessionLog (SolveFailed "PR agent did not provide stdout and stderr pipes")
  where
    repositoryRoot = repository.repositoryRoot
    adapter = adapterForBrand brand
    executableName = adapter.adapterExecutable
    -- Before this invocation's terminal event, never after: replay stops at
    -- the terminal journal envelope. A supervisor cancelling this invocation
    -- shares the aggregator and seals it before its own terminal envelope;
    -- the seal is one-shot and writes under its own lock, so exactly one side
    -- reports and the other cannot terminalize until it has finished.
    closeWithOutcome sessionLog outcome = do
      sealUnknownAggregates aggregator (eventSink . PullRequestFlowOutput pullRequestNumber)
      mapM_ (\value -> logMessage value "invocation-finished" (Text.pack (show outcome)) >> closeSessionLog value) sessionLog
      eventSink (PullRequestProcessFinished pullRequestNumber outcome)
    processSpec executablePath =
      adapter.adapterPullRequestProcess
        ProcessRequest
          { requestExecutable = executablePath,
            requestArguments = pullRequestArguments pullRequestNumber origin action brand configPath repository config assignment existingSession provenance userMessage,
            requestWorkingDirectory = repositoryRoot
          }

-- | The provider argv for one pull-request invocation.
--
-- Takes the resolved 'Assignment' for the same reason 'solveArguments' does:
-- 'pullRequestAssignment' has already been consulted at the launch boundary,
-- so this stays total and no roster defect can reach it.
pullRequestArguments :: Int -> PullRequestOrigin -> PullRequestAction -> SolverBrand -> Maybe FilePath -> Repository -> WorkflowConfig -> Assignment -> Maybe Text -> ResumeProvenance -> Text -> [String]
pullRequestArguments number origin action CodexSolver configPath repository config assignment existingSession provenance userMessage = case existingSession of
  Nothing -> codexBase <> [Text.unpack (initialPrompt number origin action configPath repository config CodexSolver)]
  Just sessionId -> ["exec", "resume"] <> codexOptions <> [Text.unpack sessionId, Text.unpack (resumePrompt config action provenance userMessage)]
  where
    codexBase = ["exec"] <> codexOptions
    codexOptions =
      [ "--model",
        Text.unpack assignment.assignmentModel,
        "--config",
        Text.unpack ("model_reasoning_effort=\"" <> assignment.assignmentEffort <> "\""),
        "--config",
        "model_reasoning_summary=\"detailed\"",
        "--dangerously-bypass-approvals-and-sandbox",
        "--json"
      ]
pullRequestArguments number origin action ClaudeSolver configPath repository config assignment existingSession provenance userMessage =
  ["--print", "--model", Text.unpack assignment.assignmentModel, "--effort", Text.unpack assignment.assignmentEffort, "--permission-mode", "bypassPermissions", "--output-format", "stream-json", "--verbose"]
    <> maybe [] (\sessionId -> ["--resume", Text.unpack sessionId]) existingSession
    <> [Text.unpack (if existingSession == Nothing then initialPrompt number origin action configPath repository config ClaudeSolver else resumePrompt config action provenance userMessage)]

initialPrompt :: Int -> PullRequestOrigin -> PullRequestAction -> Maybe FilePath -> Repository -> WorkflowConfig -> SolverBrand -> Text
initialPrompt number _origin action configPath repository config brand = Text.unlines (actionLines <> configLines <> interactionLines)
  where
    commandName name = if brand == CodexSolver then "$" <> name else "/" <> name
    -- Explicit --repo always accompanies these commands, not only when a
    -- custom --config is set: Kanban's own resolved repository (which may
    -- come from an explicit --repo override, e.g. reviewing upstream from a
    -- fork checkout) must never be silently re-derived by the canonical
    -- coordinator from the checkout's configured remote instead.
    -- Repair invokes exactly one bundled coordinator, which takes the same
    -- --repo and --config options (agent-workflow-contract §2.7); the other
    -- three actions are still told the whole review family so the session can
    -- pick whichever its labels turn out to select.
    targetCommands = case action of
      PullRequestRepair -> commandName "repair"
      _ ->
        commandName "pr-review"
          <> ", "
          <> commandName "pr-rereview"
          <> ", or "
          <> commandName "pr-revise"
          <> " (whichever applies)"
    configLines =
      [ "Pass --repo "
          <> repository.repositoryOwner
          <> "/"
          <> repository.repositoryName
          <> " to "
          <> targetCommands
          <> " so it resolves the same repository as this dashboard."
      ]
        <> case configPath of
          Nothing -> []
          Just path ->
            [ "Pass --config "
                <> Text.pack path
                <> " to "
                <> targetCommands
                <> " so it resolves the same configured workflow labels as this dashboard."
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
      PullRequestRepair ->
        [ "Run " <> commandName "repair" <> " for PR #" <> numberText <> ".",
          "Use the canonical repair workflow: address the highest-priority blocking cause on this approved PR — merge conflict first, then a failed check, then a blocking label — on the pull request's own head branch, never overwriting a concurrently updated head; after a push that is verified to have advanced the head, invoke exactly one canonical PR rereview.",
          "Never merge, never remove a blocking label yourself, and leave "
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

resumePrompt :: WorkflowConfig -> PullRequestAction -> ResumeProvenance -> Text -> Text
resumePrompt config action provenance answer = Text.unlines [resumeProvenanceHeader config provenance, Text.strip answer, "Continue the same " <> actionName action <> " workflow. Stop with KANBAN_NEEDS_INPUT: <question> if another decision is required."]

actionName :: PullRequestAction -> Text
actionName PullRequestReview = "review"
actionName PullRequestRevision = "revision"
actionName PullRequestRereview = "rereview"
actionName PullRequestRepair = "repair"

-- | Per-line handler for the stdout reader: raw-line session logging,
-- session-id capture, and agent-message forwarding, unchanged from before
-- this module's reader loop was unified in "Kanban.StreamReader".
stdoutOnLine :: Maybe SessionLog -> UnknownAggregator -> IORef (Maybe Text) -> IORef Text -> (PullRequestFlowEvent -> IO ()) -> Int -> ByteString.ByteString -> IO ()
stdoutOnLine sessionLog aggregator sessionRef lastMessageRef eventSink number line = do
  mapM_ (\value -> logRawLine value "stdout" line) sessionLog
  case parseSolveOutputLine line of
    Left _ -> emitDiagnostic line
    Right (sessionId, messages) -> do
      case sessionId of
        Nothing -> pure ()
        Just value -> writeIORef sessionRef (Just value) >> eventSink (PullRequestSessionIdentified number value)
      mapM_ (emitStreamEvent aggregator emitMessage) messages
  where
    emitMessage agentEvent
      | Text.null (Text.strip agentEvent.agentEventSummary) = pure ()
      | otherwise = do
          mapM_ (\message -> atomicModifyIORef' lastMessageRef (const (message, ()))) agentEvent.agentEventOutcomeText
          eventSink (PullRequestFlowOutput number agentEvent)
    emitDiagnostic rawLine = let message = decodeBytes rawLine in if Text.null message then pure () else eventSink (PullRequestFlowDiagnostic number message)

-- | Per-line handler for the stderr reader: raw-line session logging and
-- diagnostic forwarding, unchanged from before this module's reader loop
-- was unified in "Kanban.StreamReader".
stderrOnLine :: Maybe SessionLog -> (PullRequestFlowEvent -> IO ()) -> Int -> ByteString.ByteString -> IO ()
stderrOnLine sessionLog eventSink number line
  | ByteString.null line = pure ()
  | otherwise = do
      mapM_ (\value -> logRawLine value "stderr" line) sessionLog
      eventSink (PullRequestFlowDiagnostic number (decodeBytes line))

-- | This flow's terminal-outcome classification. The marker anchoring and
-- exit-status precedence live in 'agentOutcome', shared with "Kanban.Solve"
-- so the two workflows cannot drift apart again; only the failure
-- diagnostic's agent label is this flow's own.
flowOutcome :: ExitCode -> Text -> SolveOutcome
flowOutcome = agentOutcome "PR agent"

decodeBytes :: ByteString.ByteString -> Text
decodeBytes = Text.strip . TextEncoding.decodeUtf8With lenientDecode

exceptionText :: IOException -> Text
exceptionText = Text.pack . show
