module Kanban.UI.State
  ( agentActivity,
    appendAgentTranscript,
    closeOverlay,
    findReviewSessionByThread,
    forceTerminalRepaint,
    modifyReviewSessionByThread,
    noticeSet,
    plainTranscript,
    setNotice,
    transcriptFor,
  )
where


import Brick
import Control.Monad.IO.Class (liftIO)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe )
import Data.Text (Text)
import qualified Data.Text as Text
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
import Kanban.UI.SessionCore
import Kanban.UI.Util

setNotice :: Text -> EventM Name AppState ()
setNotice message = modify (noticeSet message)

-- | The whole of what showing a notice does to the state: one field, and
-- nothing else.
--
-- Split out from 'setNotice' rather than written twice, so a pure transition
-- that has to leave the same mark -- a refused board press, a refused right
-- click -- makes exactly the mark the 'EventM' arm makes, and the suite can
-- take that transition without brick.
noticeSet :: Text -> AppState -> AppState
noticeSet message state = state {appNotice = Just message}

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

-- | Review protocol events are addressed by the app-server's thread id
-- rather than by issue number, which is the one session lookup the shared
-- key-addressed helpers in 'Kanban.UI.SessionEvents' cannot express.
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
        session.sessionDetail.reviewSessionThreadId == Just threadId
    ]

plainTranscript :: Text -> ChatTranscript
plainTranscript value = ChatTranscript value value value

transcriptFor :: ChatVerbosity -> ChatTranscript -> Text
transcriptFor CompactChat = (.compactTranscript)
transcriptFor StandardChat = (.standardTranscript)
transcriptFor FullChat = (.fullTranscript)

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
