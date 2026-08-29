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
    settleOverlayFullscreen,
    toggleOverlayFullscreen,
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

-- | Hide whatever overlay is open.
--
-- Deliberately does not touch 'appOverlayFullscreen'. Closing clears it, but
-- that is 'settleOverlayFullscreen''s rule and it holds for every other site
-- that puts an overlay away or replaces it without coming through here;
-- restating it here would leave the close path guarded twice and its half of
-- that rule untested. Nothing renders between this and the settle, which
-- brick runs at the end of the same event.
closeOverlay :: EventM Name AppState ()
closeOverlay = modify (\state -> state {appOverlay = Nothing, appNotice = Nothing})

-- | The whole of what @f@ does: one flag, on the overlay that is open and
-- honors the toggle.
--
-- A refusal rather than a notice when it does not. The solve chooser is the
-- one overlay that keeps its windowed box, and it says so by staying the size
-- it is; the footer never names @f@ for it, so there is nothing for a message
-- to correct.
toggleOverlayFullscreen :: AppState -> AppState
toggleOverlayFullscreen state
  | maybe False overlayHonorsFullscreen state.appOverlay =
      state {appOverlayFullscreen = not state.appOverlayFullscreen}
  | otherwise = state

-- | What one event leaves the fullscreen flag holding, given the overlay that
-- was open before it.
--
-- The single seam the reset rule lives at. @appOverlay@ is assigned from
-- thirty sites and only one of them is 'closeOverlay', so clearing the flag
-- beside each assignment would be a rule with thirty chances to be forgotten
-- -- the incidents panel's Enter, which replaces the panel with a live
-- session without closing anything, is exactly the transition that would be.
-- Deciding it here from the before-and-after pair instead makes every one of
-- those sites reset by construction.
--
-- Preserved only while the same /surface/ stays open. That is what keeps
-- @Tab@ session cycling and a refresh that re-points the same overlay
-- fullscreen while a genuinely different overlay -- or no overlay at all --
-- comes back windowed.
settleOverlayFullscreen :: Maybe Overlay -> AppState -> AppState
settleOverlayFullscreen before state
  | surviving = state
  | otherwise = state {appOverlayFullscreen = False}
  where
    surviving = case (before, state.appOverlay) of
      (Just opened, Just still) -> overlaySurface opened == overlaySurface still
      _ -> False

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
