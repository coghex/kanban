module Kanban.UI.State
  ( agentActivity,
    appendAgentTranscript,
    appendReviewTranscript,
    appendSolveTranscript,
    boundedAppend,
    closeOverlay,
    findReviewSessionByThread,
    forceTerminalRepaint,
    modifyPullRequestSession,
    modifyReviewSession,
    modifyReviewSessionByThread,
    modifySolveSession,
    plainTranscript,
    reviewInputLimit,
    setNotice,
    setPullRequestActivity,
    setSolveActivity,
    transcriptFor,
  )
where


import Brick
import Control.Monad.IO.Class (liftIO)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe )
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime )
import qualified Graphics.Vty as Vty
import Kanban.Solve
  ( AgentEvent (..),
    renderAgentEvent
    )
import Kanban.Settings
  ( ChatVerbosity (..)
    )
import Kanban.Text (sanitizeText)
import Kanban.UI.Types
import Kanban.UI.Util

setNotice :: Text -> EventM Name AppState ()
setNotice message = modify (\state -> state {appNotice = Just message})

-- | Repaint the terminal from scratch, with no network request. 'Vty.refresh'
-- resets vty's assumed screen state and re-emits the current picture in full,
-- so output another process scribbled over the display is overwritten instead
-- of being preserved by the usual diffing update; 'invalidateCache' drops
-- brick's render cache so the redraw after this event is rebuilt too.
forceTerminalRepaint :: EventM Name AppState ()
forceTerminalRepaint = do
  invalidateCache
  vty <- getVtyHandle
  liftIO (Vty.refresh vty)
  setNotice "Terminal repainted"

closeOverlay :: EventM Name AppState ()
closeOverlay = modify (\state -> state {appOverlay = Nothing, appNotice = Nothing})

modifyReviewSession :: Int -> (ReviewSession -> ReviewSession) -> EventM Name AppState ()
modifyReviewSession issueNumber update =
  modify (\state -> state {appReviewSessions = Map.adjust update issueNumber state.appReviewSessions})

modifyReviewSessionByThread :: Text -> (ReviewSession -> ReviewSession) -> EventM Name AppState ()
modifyReviewSessionByThread threadId update = modify $ \state ->
  case findReviewSessionByThread threadId state of
    Nothing -> state
    Just (issueNumber, _) -> state {appReviewSessions = Map.adjust update issueNumber state.appReviewSessions}

findReviewSessionByThread :: Text -> AppState -> Maybe (Int, ReviewSession)
findReviewSessionByThread threadId state =
  safeIndex 0
    [ (issueNumber, session)
      | (issueNumber, session) <- Map.toList state.appReviewSessions,
        session.reviewSessionThreadId == Just threadId
    ]

plainTranscript :: Text -> ChatTranscript
plainTranscript value = ChatTranscript value value value

transcriptFor :: ChatVerbosity -> ChatTranscript -> Text
transcriptFor CompactChat = (.compactTranscript)
transcriptFor StandardChat = (.standardTranscript)
transcriptFor FullChat = (.fullTranscript)

appendReviewTranscript :: ChatTranscript -> Text -> ChatTranscript
appendReviewTranscript transcript addition =
  ChatTranscript
    { compactTranscript = boundedAppend transcript.compactTranscript addition,
      standardTranscript = boundedAppend transcript.standardTranscript addition,
      fullTranscript = boundedAppend transcript.fullTranscript addition
    }

reviewInputLimit :: Int
reviewInputLimit = 4000

reviewTranscriptLimit :: Int
reviewTranscriptLimit = 50000

modifySolveSession :: Int -> (SolveSession -> SolveSession) -> EventM Name AppState ()
modifySolveSession issueNumber update =
  modify (\state -> state {appSolveSessions = Map.adjust update issueNumber state.appSolveSessions})

appendSolveTranscript :: ChatTranscript -> Text -> ChatTranscript
appendSolveTranscript = appendReviewTranscript

appendAgentTranscript :: AgentEvent -> ChatTranscript -> ChatTranscript
appendAgentTranscript agentEvent transcript =
  ChatTranscript
    { compactTranscript = appendRendered CompactChat transcript.compactTranscript,
      standardTranscript = appendRendered StandardChat transcript.standardTranscript,
      fullTranscript = appendRendered FullChat transcript.fullTranscript
    }
  where
    appendRendered verbosity value = case renderAgentEvent verbosity agentEvent of
      Nothing -> value
      Just rendered -> boundedAppend value (sanitizeText rendered <> "\n")

agentActivity :: AgentEvent -> Text
agentActivity agentEvent = case agentEvent.agentEventKind of
  "reasoning" -> "thinking"
  "command" -> "running " <> activitySummary "[command] " agentEvent.agentEventSummary
  "tool" -> Text.take 80 agentEvent.agentEventSummary
  "tool-result" -> "processing tool result"
  "file" -> "changing files"
  "plan" -> "updating plan"
  "message" -> "responding"
  "error" -> "error"
  _ -> "running"

activitySummary :: Text -> Text -> Text
activitySummary prefix summary =
  Text.take 120
    . Text.unwords
    . Text.words
    . sanitizeText
    $ fromMaybe summary (Text.stripPrefix prefix summary)

setSolveActivity :: UTCTime -> Text -> SolveSession -> SolveSession
setSolveActivity now activity session =
  session {solveSessionActivity = activity, solveSessionActivityStartedAt = now}

setPullRequestActivity :: UTCTime -> Text -> PullRequestReviewSession -> PullRequestReviewSession
setPullRequestActivity now activity session =
  session {pullRequestSessionActivity = activity, pullRequestSessionActivityStartedAt = now}

boundedAppend :: Text -> Text -> Text
boundedAppend transcript addition = Text.takeEnd reviewTranscriptLimit (transcript <> addition)

modifyPullRequestSession :: Int -> (PullRequestReviewSession -> PullRequestReviewSession) -> EventM Name AppState ()
modifyPullRequestSession number update = modify (\state -> state {appPullRequestReviewSessions = Map.adjust update number state.appPullRequestReviewSessions})
