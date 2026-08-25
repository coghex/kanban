-- | The dashboard side of the shared session core: one implementation of
-- session storage, animation ticks, @Tab@ cycling, and overlay input
-- dispatch, reached for each kind through a 'SessionOps' dictionary.
--
-- 'Kanban.UI.SessionCore' holds the decisions; this module runs them in
-- brick's 'EventM'. Everything a kind genuinely owns is a field of its
-- dictionary or a 'SessionInputHooks' callback — which map in 'AppState'
-- holds it, when its spinner should be running, what its overlay is, and
-- what submitting or interrupting means. Nothing else is written three
-- times (issue #51).
module Kanban.UI.SessionEvents
  ( SessionInputHooks (..),
    SessionOps (..),
    appendToPullRequestSession,
    appendToReviewSession,
    appendToSession,
    appendToSolveSession,
    armEligibleSessionTicks,
    armSessionTick,
    applySessionTick,
    cycleSession,
    handleSessionInputEvent,
    handleSessionOverlayEvent,
    modifyPullRequestSession,
    modifyReviewSession,
    modifySession,
    modifySolveSession,
    noSessionInputHooks,
    pullRequestSessionOps,
    reviewSessionOps,
    reviewTickEligible,
    sessionFocusFor,
    sessionKeys,
    solveSessionOps,
    solveTickEligible,
  )
where


import Brick
import Brick.BChan (writeBChan)
import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Kanban.Domain (ItemId (..))
import Kanban.UI.Types
import Kanban.UI.Filter (readOnlyHistoryRefusalFor)
import Kanban.UI.State (closeOverlay, setNotice)
import Kanban.UI.SessionCore
import Kanban.UI.Session
import Kanban.UI.Transcript

-- | Everything the shared machinery needs to reach one kind of session.
--
-- 'sessionOpsEligible' is the one decision that genuinely differs and so is
-- the one that stayed a hook: a review spinner may only run while its
-- overlay is on screen (docs\/design.md section 7), because ticks are the only
-- thing driving review redraws, while a solve or PR spinner also animates
-- the board's own card badge and activity timer and must keep running with
-- no overlay open at all.
data SessionOps phase detail = SessionOps
  { sessionOpsSessions :: AppState -> Map Int (AgentSession phase detail),
    sessionOpsSetSessions :: Map Int (AgentSession phase detail) -> AppState -> AppState,
    sessionOpsTranscript :: Int -> TranscriptSession,
    sessionOpsOverlay :: Int -> Overlay,
    sessionOpsTick :: Int -> Int -> AppEvent,
    sessionOpsEligible :: AppState -> Int -> AgentSession phase detail -> Bool,
    sessionOpsCaps :: SessionInputCaps,
    -- | Whether this session still has something behind it to read text typed
    -- into its draft. Per session rather than per kind, because it is the
    -- phase -- and, for review, the stage -- that decides it (issue #515).
    sessionOpsLiveInput :: AgentSession phase detail -> Bool
  }

solveSessionOps :: SessionOps SolvePhase SolveDetail
solveSessionOps =
  SessionOps
    { sessionOpsSessions = (.appSolveSessions),
      sessionOpsSetSessions = \sessions state -> state {appSolveSessions = sessions},
      sessionOpsTranscript = SolveTranscript,
      sessionOpsOverlay = SolveOverlay,
      sessionOpsTick = SolveAnimationTick,
      -- Unchanged from the pre-#51 solve tick: animate only while a solve
      -- process is actually registered for the issue, whatever is on screen.
      sessionOpsEligible = \state issueNumber session ->
        solveTickEligible session.sessionPhase && Map.member issueNumber state.appSolveProcesses,
      sessionOpsCaps = noSessionInputCaps,
      sessionOpsLiveInput = solveSessionInputLive . (.sessionPhase)
    }

pullRequestSessionOps :: SessionOps SolvePhase PullRequestDetail
pullRequestSessionOps =
  SessionOps
    { sessionOpsSessions = (.appPullRequestReviewSessions),
      sessionOpsSetSessions = \sessions state -> state {appPullRequestReviewSessions = sessions},
      sessionOpsTranscript = PullRequestTranscript,
      sessionOpsOverlay = PullRequestReviewOverlay,
      sessionOpsTick = PullRequestAnimationTick,
      -- Unchanged from the pre-#51 PR tick, which was driven by phase alone.
      sessionOpsEligible = \_ _ session -> solveTickEligible session.sessionPhase,
      sessionOpsCaps = noSessionInputCaps,
      sessionOpsLiveInput = solveSessionInputLive . (.sessionPhase)
    }

reviewSessionOps :: SessionOps ReviewPhase ReviewDetail
reviewSessionOps =
  SessionOps
    { sessionOpsSessions = (.appReviewSessions),
      sessionOpsSetSessions = \sessions state -> state {appReviewSessions = sessions},
      sessionOpsTranscript = ReviewTranscript,
      sessionOpsOverlay = ReviewOverlay,
      sessionOpsTick = ReviewAnimationTick,
      sessionOpsEligible = \state _ session ->
        reviewTickEligible (reviewOverlayVisible state.appOverlay) session.sessionPhase,
      sessionOpsCaps =
        SessionInputCaps
          { sessionCapsChoiceDigits = True,
            sessionCapsCancelChord = True
          },
      sessionOpsLiveInput = \session ->
        reviewSessionInputLive session.sessionDetail.reviewSessionStage session.sessionPhase
    }

-- | Whether a review session in this phase should be animating, given
-- whether the review overlay is on screen. A canonical stage holds
-- 'ReviewStarting' for the whole life of its process, so this one phase set
-- covers both a running canonical process and an in-progress app-server
-- turn.
reviewTickEligible :: Bool -> ReviewPhase -> Bool
reviewTickEligible overlayVisible phase = overlayVisible && phase `elem` [ReviewStarting, ReviewRunning]

-- | Whether a solve or PR session in this phase should be animating. Unlike
-- review, no overlay condition: these spinners also drive the board's own
-- card badge and activity timer, so they must keep running with no overlay
-- open at all. The solve dictionary additionally requires a registered
-- process, exactly as its pre-#51 tick did.
solveTickEligible :: SolvePhase -> Bool
solveTickEligible phase = phase `elem` [SolveStarting, SolveRunning]

sessionKeys :: SessionOps phase detail -> AppState -> [Int]
sessionKeys ops state = Map.keys (ops.sessionOpsSessions state)

modifySession :: SessionOps phase detail -> Int -> (AgentSession phase detail -> AgentSession phase detail) -> EventM Name AppState ()
modifySession ops key update =
  modify (\state -> ops.sessionOpsSetSessions (Map.adjust update key (ops.sessionOpsSessions state)) state)

-- | Update a session and move its transcript to the new tail under the same
-- gate streamed output uses. A completion result, an interrupt notice, a
-- killed marker, or an echoed answer grows the transcript exactly as an
-- output delta does, so a following visible session must not be left sitting
-- above it; routing every transcript-growing path through this keeps that
-- from having to be remembered per call site.
appendToSession :: SessionOps phase detail -> Int -> (AgentSession phase detail -> AgentSession phase detail) -> EventM Name AppState ()
appendToSession ops key update = do
  modifySession ops key update
  tailTranscript (ops.sessionOpsTranscript key)

-- The per-kind names below are the call sites' vocabulary, not second
-- implementations: each is the shared function above applied to its
-- dictionary.
modifySolveSession :: Int -> (SolveSession -> SolveSession) -> EventM Name AppState ()
modifySolveSession = modifySession solveSessionOps

modifyPullRequestSession :: Int -> (PullRequestReviewSession -> PullRequestReviewSession) -> EventM Name AppState ()
modifyPullRequestSession = modifySession pullRequestSessionOps

modifyReviewSession :: Int -> (ReviewSession -> ReviewSession) -> EventM Name AppState ()
modifyReviewSession = modifySession reviewSessionOps

appendToSolveSession :: Int -> (SolveSession -> SolveSession) -> EventM Name AppState ()
appendToSolveSession = appendToSession solveSessionOps

appendToPullRequestSession :: Int -> (PullRequestReviewSession -> PullRequestReviewSession) -> EventM Name AppState ()
appendToPullRequestSession = appendToSession pullRequestSessionOps

appendToReviewSession :: Int -> (ReviewSession -> ReviewSession) -> EventM Name AppState ()
appendToReviewSession = appendToSession reviewSessionOps

-- | The single entry point every trigger calls to (re)start animation for
-- one session. Coalesces via 'decideSessionTickArm', so repeated triggers
-- for the same running turn never arm more than one chain.
armSessionTick :: SessionOps phase detail -> Int -> EventM Name AppState ()
armSessionTick ops key = do
  state <- get
  case Map.lookup key (ops.sessionOpsSessions state) of
    Nothing -> pure ()
    Just session ->
      case decideSessionTickArm (ops.sessionOpsEligible state key session) session.sessionTickArmed session.sessionTickGeneration of
        ArmSessionTick generation -> do
          modifySession ops key (\current -> current {sessionTickGeneration = generation, sessionTickArmed = True})
          scheduleSessionTick ops key generation
        SessionTickAlreadyArmed -> pure ()
        SessionTickNotEligible -> pure ()

-- | Re-arm every session of this kind that is eligible to animate but not
-- currently ticking. A chain can expire (unarm) while the kind's overlay is
-- closed; simply reopening it -- on any tab, via any of the several paths
-- that can do so -- must resume every still-running session's spinner, not
-- only the one being focused, so this sweeps 'armSessionTick' across all of
-- them rather than requiring every overlay-opening call site to know which
-- sessions might need it.
armEligibleSessionTicks :: SessionOps phase detail -> EventM Name AppState ()
armEligibleSessionTicks ops = do
  state <- get
  mapM_ (armSessionTick ops) (sessionsNeedingArm (ops.sessionOpsEligible state) (ops.sessionOpsSessions state))

applySessionTick :: SessionOps phase detail -> Int -> Int -> EventM Name AppState ()
applySessionTick ops key generation = do
  state <- get
  case Map.lookup key (ops.sessionOpsSessions state) of
    Nothing -> pure ()
    Just session ->
      case decideSessionTickFire session.sessionTickGeneration generation (ops.sessionOpsEligible state key session) of
        SessionTickStale -> pure ()
        SessionTickReschedule -> do
          modifySession ops key (\current -> current {sessionSpinnerFrame = current.sessionSpinnerFrame + 1})
          scheduleSessionTick ops key generation
        SessionTickExpire -> modifySession ops key (\current -> current {sessionTickArmed = False})

-- | How often a live session's spinner advances, for every kind.
sessionAnimationIntervalMicros :: Int
sessionAnimationIntervalMicros = 100 * 1000

scheduleSessionTick :: SessionOps phase detail -> Int -> Int -> EventM Name AppState ()
scheduleSessionTick ops key generation = do
  eventChannel <- (.appEventChannel) <$> get
  void
    . liftIO
    . forkIO
    $ do
      threadDelay sessionAnimationIntervalMicros
      writeBChan eventChannel (ops.sessionOpsTick key generation)

-- | @Tab@: show the next session of this kind, in ascending numeric order
-- with wraparound. Each session keeps its own draft and transcript, so
-- switching preserves both; a kind holding one session has nowhere to go and
-- this does nothing at all (docs\/design.md section 7).
cycleSession :: SessionOps phase detail -> Int -> EventM Name AppState ()
cycleSession ops current = do
  state <- get
  case nextSessionKey current (sessionKeys ops state) of
    Nothing -> pure ()
    Just next -> do
      modify (\updated -> updated {appOverlay = Just (ops.sessionOpsOverlay next), appNotice = Nothing})
      presentTranscriptTail
      armEligibleSessionTicks ops

-- | What a kind does with the actions the shared table cannot decide for it:
-- what submitting the input line means, what interrupting the live turn
-- means, and -- for a kind that offers numbered choices -- what a digit
-- selects.
data SessionInputHooks = SessionInputHooks
  { sessionHookSubmit :: Int -> EventM Name AppState (),
    sessionHookInterrupt :: Int -> EventM Name AppState (),
    sessionHookChoice :: Int -> Int -> EventM Name AppState (),
    -- | The board work this kind's key names, so the shared table can ask
    -- whether it is still live before letting a press advance it.
    sessionHookSubject :: Int -> ItemId
  }

noSessionInputHooks :: SessionInputHooks
noSessionInputHooks =
  SessionInputHooks
    { sessionHookSubmit = \_ -> pure (),
      sessionHookInterrupt = \_ -> pure (),
      sessionHookChoice = \_ _ -> pure (),
      sessionHookSubject = IssueId
    }

-- | How the shared decoder sees one session of this kind: the kind's caps
-- and that session's own mode and input state. A key press arriving for a
-- session the map no longer holds still has to be answered -- the overlay is
-- drawing "no longer available" and @Esc@ or @q@ must close it -- so a
-- missing session reads as a settled one rather than as nothing at all.
sessionFocusFor :: SessionOps phase detail -> Int -> AppState -> SessionFocus
sessionFocusFor ops key state = case Map.lookup key (ops.sessionOpsSessions state) of
  Nothing -> SessionFocus ops.sessionOpsCaps SessionNormal False
  Just session -> SessionFocus ops.sessionOpsCaps session.sessionMode (ops.sessionOpsLiveInput session)

-- | The whole key table every session overlay answers, dispatched once.
handleSessionOverlayEvent ::
  SessionOps phase detail ->
  SessionInputHooks ->
  Int ->
  BrickEvent Name AppEvent ->
  EventM Name AppState ()
handleSessionOverlayEvent ops hooks key event = case event of
  VtyEvent vtyEvent -> do
    focus <- sessionFocusFor ops key <$> get
    mapM_ (handleSessionInputEvent ops hooks key) (sessionInputEvent focus vtyEvent)
  _ -> pure ()

handleSessionInputEvent ::
  SessionOps phase detail ->
  SessionInputHooks ->
  Int ->
  SessionInputEvent ->
  EventM Name AppState ()
handleSessionInputEvent ops hooks key inputEvent = do
  -- The mode is the keypress's own, and settled before anything the press
  -- goes on to do: §7 promises Enter leaves the session in normal mode, and a
  -- hook that refuses -- a settled card, a disconnected backend, an empty
  -- draft -- must not leave it in insert as if the press had not happened.
  modifySession ops key (\session -> setSessionMode (sessionModeAfter inputEvent session.sessionMode) session)
  case inputEvent of
    SessionInputScroll amount -> scrollTranscript (ops.sessionOpsTranscript key) amount
    SessionInputScrollTop -> scrollTranscriptToEnd TranscriptBeginning (ops.sessionOpsTranscript key)
    SessionInputScrollBottom -> scrollTranscriptToEnd TranscriptTail (ops.sessionOpsTranscript key)
    SessionInputBackspace -> modifySession ops key removeSessionInputCharacter
    SessionInputInsert character -> modifySession ops key (insertSessionInput character)
    -- Whatever the hook declines to send stays on the line under the hook's
    -- own existing behavior; only the mode has already moved.
    SessionInputSubmit -> whenWorkIsLive (hooks.sessionHookSubmit key)
    SessionInputCycle -> cycleSession ops key
    SessionInputInterrupt -> whenWorkIsLive (hooks.sessionHookInterrupt key)
    -- Both modes are entered by the write above, so these two arms have
    -- nothing left of their own to do.
    SessionInputEnterInsert -> pure ()
    SessionInputLeaveInsert -> pure ()
    -- Hiding the overlay, never the application's guarded quit: the work
    -- behind the session keeps running and `r` reopens it, exactly as Esc
    -- always did here.
    SessionInputClose -> closeOverlay
    SessionInputChoice choiceIndex -> whenWorkIsLive (hooks.sessionHookChoice key choiceIndex)
  where
    -- The launch and termination boundary for a session left open across a
    -- refresh. A session can sit on screen for as long as the user leaves the
    -- overlay up, so the answer it is about to resume with — or the Ctrl-C
    -- about to stop its turn — may be aimed at work that has since closed or
    -- merged. Asked here rather than in each kind's own hook so no overlay can
    -- act on settled history, and asked before the hook runs so nothing is
    -- appended to a transcript that will not be sent.
    --
    -- Interrupting is guarded alongside the rest because §8 refuses every
    -- termination boundary, not only the board's kill binding. A process still
    -- running against work that settled underneath it is stopped the way any
    -- other stray agent process is, rather than through a card that is now
    -- history.
    whenWorkIsLive action = do
      state <- get
      case readOnlyHistoryRefusalFor state (hooks.sessionHookSubject key) of
        Just notice -> setNotice notice
        Nothing -> action
