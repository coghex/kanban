module Kanban.UI.Transcript
  ( TranscriptEnd (..),
    TranscriptGeometry (..),
    TranscriptSession (..),
    displayedTranscript,
    followAfterJump,
    followAfterScroll,
    followAfterTurnStarted,
    presentTranscriptTail,
    scrollTranscript,
    scrollTranscriptToEnd,
    tailDisplayedTranscript,
    tailReviewThread,
    tailTranscript,
    transcriptShouldTail,
  )
where


import Brick
import Control.Monad (when)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Kanban.Review (ReviewThreadId)
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

-- | Follow state lives in the shared session core, so these two only pick
-- the map the identity names; the decisions above and in
-- 'Kanban.UI.SessionCore' are what all three kinds actually share.
transcriptFollowing :: AppState -> TranscriptSession -> Bool
transcriptFollowing state = \case
  SolveTranscript issueNumber -> maybe False (.sessionFollowing) (Map.lookup issueNumber state.appSolveSessions)
  PullRequestTranscript number -> maybe False (.sessionFollowing) (Map.lookup number state.appPullRequestReviewSessions)
  ReviewTranscript issueNumber -> maybe False (.sessionFollowing) (Map.lookup issueNumber state.appReviewSessions)

setTranscriptFollowing :: TranscriptSession -> Bool -> AppState -> AppState
setTranscriptFollowing session following state = case session of
  SolveTranscript issueNumber ->
    state {appSolveSessions = Map.adjust (\current -> current {sessionFollowing = following}) issueNumber state.appSolveSessions}
  PullRequestTranscript number ->
    state {appPullRequestReviewSessions = Map.adjust (\current -> current {sessionFollowing = following}) number state.appPullRequestReviewSessions}
  ReviewTranscript issueNumber ->
    state {appReviewSessions = Map.adjust (\current -> current {sessionFollowing = following}) issueNumber state.appReviewSessions}

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
tailReviewThread :: ReviewThreadId -> EventM Name AppState ()
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

-- | Which end of a transcript a jump asks for: @g@ and @G@ (issue #515).
data TranscriptEnd
  = TranscriptBeginning
  | TranscriptTail
  deriving stock (Eq, Show)

-- | The follow state a jump to one end leaves behind, decided the way
-- 'followAfterScroll' decides a relative one but from the end rather than
-- from an offset.
--
-- The tail /is/ the live tail, so reaching it always re-engages following
-- whatever the geometry says. The beginning of a scrollable transcript is by
-- definition not its tail, so it always disengages; a transcript shorter than
-- its viewport is showing both ends at once and following stands. With no
-- geometry the viewport has never been rendered, and a never-rendered
-- transcript has nothing above its tail either.
followAfterJump :: TranscriptEnd -> Maybe TranscriptGeometry -> Bool
followAfterJump TranscriptTail _ = True
followAfterJump TranscriptBeginning geometry = not (any scrollableGeometry geometry)

-- | Jump a transcript to one end and re-derive its follow state from the end
-- it landed on, the counterpart to 'scrollTranscript' for a gesture that is
-- an absolute position rather than an amount.
scrollTranscriptToEnd :: TranscriptEnd -> TranscriptSession -> EventM Name AppState ()
scrollTranscriptToEnd end session = do
  let name = transcriptViewport session
  geometry <- fmap viewportGeometry <$> lookupViewport name
  case end of
    TranscriptBeginning -> vScrollToBeginning (viewportScroll name)
    TranscriptTail -> vScrollToEnd (viewportScroll name)
  modify (setTranscriptFollowing session (followAfterJump end geometry))

-- | Whether a rendered viewport has anywhere to scroll to at all.
scrollableGeometry :: TranscriptGeometry -> Bool
scrollableGeometry geometry = geometry.transcriptContentHeight > geometry.transcriptHeight

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

-- | Tail whichever transcript is on screen, for updates that grow many
-- sessions at once -- a backend disconnect marks every live review session
-- -- and so have no single session to key off. The displayed one is the
-- only viewport that could need moving anyway.
tailDisplayedTranscript :: EventM Name AppState ()
tailDisplayedTranscript = do
  overlay <- (.appOverlay) <$> get
  mapM_ tailTranscript (displayedTranscript overlay)

