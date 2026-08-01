{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | The vocabulary describing a solve invocation's lifecycle, identity, and
-- terminal outcome: the events 'Kanban.Solve' emits, the events a provider's
-- stream decodes into, and how both are classified or rendered for the chat
-- pane. Separated from "Kanban.Solve.Parse" (which turns raw provider JSON
-- into these types) and "Kanban.Solve.Unknown" (which bounds and aggregates
-- the unrecognized-payload case) because this module owns what the types
-- mean, not how one is produced or counted.
module Kanban.Solve.Event
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
    codexSolverModel,
    claudeSolverModel,
    codexReviewerModel,
    claudeReviewerModel,
    renderAgentEvent,
    solveOutcome,
    solverLabel,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import Kanban.Process (ManagedProcess)
import Kanban.Settings (ChatVerbosity (..))
import System.Exit (ExitCode (..))

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
