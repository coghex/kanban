module Kanban.UI.Transcript
  ( TranscriptGeometry (..),
    TranscriptSession (..),
    appendToPullRequestSession,
    appendToReviewSession,
    appendToSolveSession,
    displayedTranscript,
    followAfterScroll,
    followAfterTurnStarted,
    presentTranscriptTail,
    scrollTranscript,
    tailDisplayedTranscript,
    tailReviewThread,
    tailTranscript,
    transcriptScrollKey,
    transcriptShouldTail,
  )
where


import Brick
import Control.Monad (when)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Graphics.Vty as Vty
import Kanban.UI.Types
import Kanban.UI.State

-- | Which transcript an output event or a scroll gesture belongs to.
-- The review, solve, and PR overlays each render every session of their
-- kind through one shared viewport, so it is the session identity -- not
-- merely the overlay kind -- that decides whether an event may move what
-- is on screen (issue #39).
data TranscriptSession
  = SolveTranscript Int
  | PullRequestTranscript Int
  | ReviewTranscript Int
  deriving stock (Eq, Show)

transcriptViewport :: TranscriptSession -> Name
transcriptViewport (SolveTranscript _) = SolveViewport
transcriptViewport (PullRequestTranscript _) = PullRequestReviewViewport
transcriptViewport (ReviewTranscript _) = ReviewViewport

-- | The transcript an overlay puts on screen, if it shows one at all.
displayedTranscript :: Maybe Overlay -> Maybe TranscriptSession
displayedTranscript (Just (SolveOverlay issueNumber)) = Just (SolveTranscript issueNumber)
displayedTranscript (Just (PullRequestReviewOverlay number)) = Just (PullRequestTranscript number)
displayedTranscript (Just (ReviewOverlay issueNumber)) = Just (ReviewTranscript issueNumber)
displayedTranscript _ = Nothing

-- | Whether a transcript-growing event may move its viewport to the live
-- tail. issue #39: only when that exact session is the one currently
-- displayed -- a hidden overlay or a background review tab must issue no
-- viewport operation at all -- and only while that session still follows
-- the tail rather than sitting where the user scrolled it.
transcriptShouldTail :: Maybe Overlay -> TranscriptSession -> Bool -> Bool
transcriptShouldTail overlay session following =
  following && displayedTranscript overlay == Just session

-- | A transcript viewport's geometry as of the last render: how far down
-- it is scrolled, how tall it is, and how tall its content is.
data TranscriptGeometry = TranscriptGeometry
  { transcriptTop :: Int,
    transcriptHeight :: Int,
    transcriptContentHeight :: Int
  }
  deriving stock (Eq, Show)

-- | The follow state a relative scroll of 'amount' leaves behind. Mirrors
-- brick's own clamping of a viewport's top offset so the answer matches
-- what the next render actually shows: reaching the bottom re-engages the
-- live tail, and any other landing spot -- including a downward gesture
-- that stops short of the bottom, which output arriving while disengaged
-- keeps pushing further away -- leaves it disengaged. Content shorter than
-- the viewport is always at its bottom. With no geometry the viewport has
-- never been rendered and the scroll cannot take effect, so the current
-- state stands.
followAfterScroll :: Bool -> Maybe TranscriptGeometry -> Int -> Bool
followAfterScroll following Nothing _ = following
followAfterScroll _ (Just geometry) amount =
  clampedTop + geometry.transcriptHeight >= geometry.transcriptContentHeight
  where
    clampedTop = max 0 (min bottomTop (geometry.transcriptTop + amount))
    bottomTop = max 0 (geometry.transcriptContentHeight - geometry.transcriptHeight)

-- | The follow state a 'ReviewTurnStarted' notification leaves behind. A
-- genuinely new turn re-engages the live tail, but the backend can repeat
-- the notification for the turn already running -- an answered question is
-- followed by a matching one -- and that must not be mistaken for a new
-- turn and used to discard a deliberate scrollback.
followAfterTurnStarted :: Bool -> Maybe Text -> Text -> Bool
followAfterTurnStarted following currentTurnId startedTurnId =
  following || currentTurnId /= Just startedTurnId

-- | The relative transcript scroll a key press asks for, if any.
-- 'reviewChords' enables the review overlay's additional Ctrl-J/Ctrl-K
-- bindings, which the solve and PR overlays do not offer. Pure so every
-- binding that can change follow state is unit-testable without an
-- 'EventM' harness; the wheel equivalents come from 'overlayMouseAction'.
transcriptScrollKey :: Bool -> Vty.Event -> Maybe Int
transcriptScrollKey _ (Vty.EvKey Vty.KDown []) = Just 1
transcriptScrollKey _ (Vty.EvKey Vty.KUp []) = Just (-1)
transcriptScrollKey True (Vty.EvKey (Vty.KChar 'j') [Vty.MCtrl]) = Just 1
transcriptScrollKey True (Vty.EvKey (Vty.KChar 'k') [Vty.MCtrl]) = Just (-1)
transcriptScrollKey _ _ = Nothing

transcriptFollowing :: AppState -> TranscriptSession -> Bool
transcriptFollowing state = \case
  SolveTranscript issueNumber -> maybe False (.solveSessionFollowing) (Map.lookup issueNumber state.appSolveSessions)
  PullRequestTranscript number -> maybe False (.pullRequestSessionFollowing) (Map.lookup number state.appPullRequestReviewSessions)
  ReviewTranscript issueNumber -> maybe False (.reviewSessionFollowing) (Map.lookup issueNumber state.appReviewSessions)

setTranscriptFollowing :: TranscriptSession -> Bool -> AppState -> AppState
setTranscriptFollowing session following state = case session of
  SolveTranscript issueNumber ->
    state {appSolveSessions = Map.adjust (\current -> current {solveSessionFollowing = following}) issueNumber state.appSolveSessions}
  PullRequestTranscript number ->
    state {appPullRequestReviewSessions = Map.adjust (\current -> current {pullRequestSessionFollowing = following}) number state.appPullRequestReviewSessions}
  ReviewTranscript issueNumber ->
    state {appReviewSessions = Map.adjust (\current -> current {reviewSessionFollowing = following}) issueNumber state.appReviewSessions}

-- | Move a transcript to the live tail, but only when 'transcriptShouldTail'
-- allows it. Every transcript-growing event routes through here, so a
-- hidden overlay or a background session issues no scroll at all.
tailTranscript :: TranscriptSession -> EventM Name AppState ()
tailTranscript session = do
  state <- get
  when (transcriptShouldTail state.appOverlay session (transcriptFollowing state session)) $
    vScrollToEnd (viewportScroll (transcriptViewport session))

-- | Tail the review transcript belonging to the session that owns this
-- thread rather than whichever review tab happens to be focused: review
-- events are addressed by thread id while the overlay selects a session by
-- issue number, so a background session's output must not move the
-- displayed one.
tailReviewThread :: Text -> EventM Name AppState ()
tailReviewThread threadId = do
  state <- get
  mapM_ (tailTranscript . ReviewTranscript . fst) (findReviewSessionByThread threadId state)

-- | Scroll a transcript by a relative amount and re-derive its follow
-- state from where that scroll actually lands.
scrollTranscript :: TranscriptSession -> Int -> EventM Name AppState ()
scrollTranscript session amount = do
  let name = transcriptViewport session
  geometry <- fmap viewportGeometry <$> lookupViewport name
  vScrollBy (viewportScroll name) amount
  modify (\state -> setTranscriptFollowing session (followAfterScroll (transcriptFollowing state session) geometry amount) state)

viewportGeometry :: Viewport -> TranscriptGeometry
viewportGeometry viewportState =
  TranscriptGeometry
    { transcriptTop = _vpTop viewportState,
      transcriptHeight = snd (_vpSize viewportState),
      transcriptContentHeight = snd (_vpContentSize viewportState)
    }

-- | Engage follow and jump to the live tail of whichever transcript the
-- overlay now shows. Called wherever a transcript session becomes visible
-- -- opened from the board or the processes list, or selected by the
-- review overlay's Tab -- because the shared viewport would otherwise
-- present the newly shown session at the previous one's scroll position.
presentTranscriptTail :: EventM Name AppState ()
presentTranscriptTail = do
  overlay <- (.appOverlay) <$> get
  case displayedTranscript overlay of
    Nothing -> pure ()
    Just session -> do
      modify (setTranscriptFollowing session True)
      vScrollToEnd (viewportScroll (transcriptViewport session))

-- | Update a session and move its transcript to the new tail under the
-- same gate streamed output uses. A completion result, an interrupt
-- notice, a killed marker, or an echoed answer grows the transcript
-- exactly as an output delta does, so a following visible session must not
-- be left sitting above it; routing every transcript-growing path through
-- these keeps that from having to be remembered per call site.
appendToSolveSession :: Int -> (SolveSession -> SolveSession) -> EventM Name AppState ()
appendToSolveSession issueNumber update = do
  modifySolveSession issueNumber update
  tailTranscript (SolveTranscript issueNumber)

appendToPullRequestSession :: Int -> (PullRequestReviewSession -> PullRequestReviewSession) -> EventM Name AppState ()
appendToPullRequestSession number update = do
  modifyPullRequestSession number update
  tailTranscript (PullRequestTranscript number)

appendToReviewSession :: Int -> (ReviewSession -> ReviewSession) -> EventM Name AppState ()
appendToReviewSession issueNumber update = do
  modifyReviewSession issueNumber update
  tailTranscript (ReviewTranscript issueNumber)

-- | Tail whichever transcript is on screen, for updates that grow many
-- sessions at once -- a backend disconnect marks every live review session
-- -- and so have no single session to key off. The displayed one is the
-- only viewport that could need moving anyway.
tailDisplayedTranscript :: EventM Name AppState ()
tailDisplayedTranscript = do
  overlay <- (.appOverlay) <$> get
  mapM_ tailTranscript (displayedTranscript overlay)

