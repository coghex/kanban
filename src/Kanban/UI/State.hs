module Kanban.UI.State
  ( closeOverlay,
    forceTerminalRepaint,
    setNotice,
    setNoticeFor,
    settleNoticeExpiry,
    settleOverlayFullscreen,
    toggleCardExcerpts,
    toggleOverlayFullscreen,
  )
where


import Brick
import Brick.BChan (writeBChan)
import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Graphics.Vty as Vty
import Kanban.UI.Notice
import Kanban.UI.Types
import Kanban.UI.Util

setNotice :: Text -> EventM Name AppState ()
setNotice message = modify (noticeSet message)

-- | 'setNotice' for a message that explicitly reports the named tracked
-- operation as still running ('Kanban.UI.Util.noticeSetFor').
setNoticeFor :: NoticeActivity -> Text -> EventM Name AppState ()
setNoticeFor activity message = modify (noticeSetFor activity message)

-- | Settle the notice line against what the event that just ran left behind,
-- and arm the one-shot timer a newly settled instance needs: ten seconds
-- after an instance's deadline is first armed, a 'NoticeExpired' tick
-- carrying its identity arrives on the event channel, redrawing the footer
-- even when nothing else happens in the meantime (issue #590 requirement 3).
--
-- @before@ is the notice state the event started from. An armed pair the
-- event left untouched keeps the timer it already has; only a pair this
-- settle created — a new instance, or an active notice whose operation just
-- ended — forks a thread, so an idle stream of events never stacks timers.
settleNoticeExpiry :: NoticeState -> EventM Name AppState ()
settleNoticeExpiry before = do
  modify settleNoticeLifecycle
  after <- get
  case noticeExpiryToArm before after.appNotice of
    Nothing -> pure ()
    Just armedInstance ->
      void . liftIO . forkIO $ do
        threadDelay noticeExpiryDelayMicros
        writeBChan after.appEventChannel (NoticeExpired armedInstance)

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
closeOverlay = modify (\state -> noticeCleared state {appOverlay = Nothing})

-- | The whole of what @f@ does: one flag, on the overlay that is open.
--
-- With no overlay open the key does nothing.
toggleOverlayFullscreen :: AppState -> AppState
toggleOverlayFullscreen state
  | isJust state.appOverlay =
      state {appOverlayFullscreen = not state.appOverlayFullscreen}
  | otherwise = state

-- | The whole of what @v@ does: one flag, and the request to keep the
-- selection on screen through the reflow it causes (issue #664).
--
-- Local and immediate by construction. Nothing here reaches GitHub, the
-- snapshot cache, the configuration, the settings file, or the board's
-- freshness: the flag is process-lifetime presentation state, exactly as the
-- filter criteria beside it are. Every column measurement taken under the old
-- budget is dropped by the settle after this event, because
-- 'Kanban.UI.Board.layoutInputs' reads the same flag
-- ('Kanban.UI.Board.cardExcerptLimit') and 'appLayoutEpoch' moves with it.
--
-- The reveal is the half that needs saying. The selection is a row index and
-- this moves none of them, so identity survives on its own; what does not is
-- /visibility/, because every card above the selected one changes height. The
-- flag is what makes the next frame ask brick to scroll it back into the
-- viewport, and it is set in both directions -- growing the cards above can
-- push the selection past the bottom, and shrinking them can leave a viewport
-- offset that is now past the end of the column.
toggleCardExcerpts :: AppState -> AppState
toggleCardExcerpts state =
  state
    { appExcerptsVisible = not state.appExcerptsVisible,
      appEnsureSelectionVisible = True
    }

-- | What one event leaves the fullscreen flag holding, given the overlay that
-- was open before it.
--
-- The single seam the reset rule lives at. @appOverlay@ is assigned from
-- many sites and only one of them is 'closeOverlay', so clearing the flag
-- beside each assignment would be a rule with many chances to be forgotten.
-- Deciding it here from the before-and-after pair instead makes every one of
-- those sites reset by construction.
--
-- Preserved only while the same /surface/ stays open. That is what keeps a
-- refresh that re-points the same overlay fullscreen while a genuinely
-- different overlay -- or no overlay at all -- comes back windowed.
settleOverlayFullscreen :: Maybe Overlay -> AppState -> AppState
settleOverlayFullscreen before state
  | surviving = state
  | otherwise = state {appOverlayFullscreen = False}
  where
    surviving = case (before, state.appOverlay) of
      (Just opened, Just still) -> overlaySurface opened == overlaySurface still
      _ -> False
