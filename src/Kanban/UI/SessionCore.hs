-- | The behavior every agent session shares, written once.
--
-- 'Kanban.UI.Types.AgentSession' is the record; this module is what acts on
-- it. Solve, pull-request, and review sessions used to carry three
-- hand-maintained copies of each of these — status glyphs, transcript
-- growth, input editing, the animation tick chain, the overlay's base key
-- table — and the copies had already drifted into filed bugs and lost
-- features (issue #51). Everything here is pure, so all three kinds are
-- exercisable against the same tables without a terminal or an 'EventM'
-- harness.
--
-- Only genuinely kind-specific decisions stay outside: which phases animate
-- (a review spinner is gated on its overlay being visible, a solve spinner
-- on its process being live), what a phase looks like and is called, and
-- what submitting, interrupting, or resuming actually does.
module Kanban.UI.SessionCore
  ( PhaseGlyph (..),
    SessionFocus (..),
    SessionInputCaps (..),
    SessionInputEvent (..),
    SessionTickArm (..),
    SessionTickFire (..),
    appendSessionTranscript,
    appendTranscript,
    boundedAppend,
    decideSessionTickArm,
    decideSessionTickFire,
    insertSessionInput,
    liveSessionMode,
    newAgentSession,
    nextSessionKey,
    noSessionInputCaps,
    priorTickGeneration,
    removeSessionInputCharacter,
    renderPhaseGlyph,
    sessionFooterHints,
    sessionHalfPage,
    sessionInputEvent,
    sessionInputHelp,
    sessionInputLimit,
    sessionModeAfter,
    sessionsNeedingArm,
    setSessionActivity,
    setSessionMode,
    spinnerGlyph,
    transcriptScrollKey,
  )
where

import Data.Char (isPrint)
import Data.List (findIndex, sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime)
import qualified Graphics.Vty as Vty
import Kanban.UI.Keys (BoardAction (..), HelpEntry (..), binding, chord, footerHint)
import Kanban.UI.Types
import Kanban.UI.Util (safeIndex)

-- | A session in its opening state: one description of what a fresh core
-- looks like, whatever kind is being opened.
--
-- 'priorTickGeneration' is what a replaced session for the same key last
-- reached, or 0 when there was none. A tick that session already queued can
-- still be delivered after this replacement is in place and eligible, so the
-- generation must already be past whatever that tick carries /at
-- construction time/, not only from this session's own eventual first arm
-- (issue #30 round-3 review, now applied to every kind).
newAgentSession ::
  Int ->
  phase ->
  Text ->
  Maybe UTCTime ->
  ChatTranscript ->
  detail ->
  AgentSession phase detail
newAgentSession priorGeneration phase activity startedAt transcript detail =
  AgentSession
    { sessionPhase = phase,
      sessionActivity = activity,
      sessionActivityStartedAt = startedAt,
      sessionLogPath = Nothing,
      sessionTranscript = transcript,
      sessionInput = "",
      sessionMode = SessionNormal,
      sessionSpinnerFrame = 0,
      sessionTickGeneration = priorGeneration + 1,
      sessionTickArmed = False,
      sessionFollowing = True,
      sessionDetail = detail
    }

priorTickGeneration :: Int -> Map Int (AgentSession phase detail) -> Int
priorTickGeneration key sessions = maybe 0 (.sessionTickGeneration) (Map.lookup key sessions)

-- | The longest message a session's one-line input holds, for every kind.
sessionInputLimit :: Int
sessionInputLimit = 4000

-- | The longest transcript a session retains, for every kind.
sessionTranscriptLimit :: Int
sessionTranscriptLimit = 50000

boundedAppend :: Text -> Text -> Text
boundedAppend transcript addition = Text.takeEnd sessionTranscriptLimit (transcript <> addition)

-- | Append the same text to every verbosity of a transcript, bounded.
appendTranscript :: ChatTranscript -> Text -> ChatTranscript
appendTranscript transcript addition =
  ChatTranscript
    { compactTranscript = boundedAppend transcript.compactTranscript addition,
      standardTranscript = boundedAppend transcript.standardTranscript addition,
      fullTranscript = boundedAppend transcript.fullTranscript addition
    }

appendSessionTranscript :: Text -> AgentSession phase detail -> AgentSession phase detail
appendSessionTranscript addition session =
  session {sessionTranscript = appendTranscript session.sessionTranscript addition}

-- | Replace the activity line and restart its elapsed timer.
setSessionActivity :: UTCTime -> Text -> AgentSession phase detail -> AgentSession phase detail
setSessionActivity now activity session =
  session {sessionActivity = activity, sessionActivityStartedAt = Just now}

insertSessionInput :: Char -> AgentSession phase detail -> AgentSession phase detail
insertSessionInput character session =
  session {sessionInput = Text.take sessionInputLimit (session.sessionInput <> Text.singleton character)}

removeSessionInputCharacter :: AgentSession phase detail -> AgentSession phase detail
removeSessionInputCharacter session = session {sessionInput = Text.dropEnd 1 session.sessionInput}

-- | Move one session between modes, leaving its draft, transcript, and
-- undelivered queue exactly where they are. Every mode change goes through
-- here -- the key presses that stage 'SessionInsert' and 'SessionNormal', and
-- the numbered-choice prompt that forces a session back to normal -- so no
-- call site has to remember that switching modes is /only/ a mode change.
setSessionMode :: SessionMode -> AgentSession phase detail -> AgentSession phase detail
setSessionMode mode session = session {sessionMode = mode}

-- | How one phase renders as a badge: the running spinner, or a fixed pair
-- of glyphs, unicode first and its ASCII-mode substitute second. Keeping the
-- appearance separate from the rendering is what leaves each kind free to
-- say a finished workflow is a neutral diamond or a ready checkmark while
-- one implementation draws them all.
data PhaseGlyph
  = PhaseSpinner
  | PhaseGlyphs Text Text
  deriving stock (Eq, Show)

renderPhaseGlyph :: Bool -> (phase -> PhaseGlyph) -> AgentSession phase detail -> Text
renderPhaseGlyph useAscii appearance session = case appearance session.sessionPhase of
  PhaseSpinner
    | useAscii -> "* "
    | otherwise -> spinnerGlyph session.sessionSpinnerFrame <> " "
  PhaseGlyphs unicode ascii
    | useAscii -> ascii
    | otherwise -> unicode

spinnerGlyph :: Int -> Text
spinnerGlyph frame = spinnerFrames !! (frame `mod` length spinnerFrames)
  where
    spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

-- | Result of asking whether a trigger — an answered question or approval, a
-- turn notification, a process starting, or the session's overlay reopening
-- — should arm a new tick chain.
data SessionTickArm
  = ArmSessionTick Int
  | SessionTickAlreadyArmed
  | SessionTickNotEligible
  deriving stock (Eq, Show)

-- | issue #30: every trigger used to call the tick scheduler
-- unconditionally, so a fast answer/approval and the backend's matching turn
-- notification each armed their own independent chain for the same turn.
-- This coalesces repeated triggers: a chain already armed for the current
-- generation absorbs the request instead of spawning a second one, so at
-- most one chain is ever live per session. issue #51 puts solve and
-- pull-request sessions, which had no generation at all, under the same
-- rule.
decideSessionTickArm :: Bool -> Bool -> Int -> SessionTickArm
decideSessionTickArm eligible armed currentGeneration
  | not eligible = SessionTickNotEligible
  | armed = SessionTickAlreadyArmed
  | otherwise = ArmSessionTick (currentGeneration + 1)

-- | Result of a fired animation tick checked against its session's current
-- generation and eligibility.
data SessionTickFire
  = SessionTickStale
  | SessionTickReschedule
  | SessionTickExpire
  deriving stock (Eq, Show)

-- | issue #30: a tick only advances the frame and reschedules itself when it
-- still carries its session's current generation — a tick from a superseded
-- chain (one the session has since moved past) is dropped silently instead
-- of rearming alongside whatever chain replaced it. This is the fix for the
-- verified fast-resume race: a tick scheduled before a question/approval can
-- arrive after a fast answer restores the running phase, and
-- generation-matching alone would let it rearm alongside the chain the
-- answer itself coalesced onto — so a match reschedules the /same/ chain
-- rather than proving a second one is safe to keep.
decideSessionTickFire :: Int -> Int -> Bool -> SessionTickFire
decideSessionTickFire sessionGeneration tickGeneration eligible
  | sessionGeneration /= tickGeneration = SessionTickStale
  | eligible = SessionTickReschedule
  | otherwise = SessionTickExpire

-- | Which sessions are eligible to animate right now but not currently
-- armed — e.g. because their chain expired while their overlay was hidden,
-- or was never armed for a session that only just became visible by having a
-- different tab focused.
sessionsNeedingArm :: (Int -> AgentSession phase detail -> Bool) -> Map Int (AgentSession phase detail) -> [Int]
sessionsNeedingArm eligible sessions =
  [ key
    | (key, session) <- Map.toList sessions,
      eligible key session,
      not session.sessionTickArmed
  ]

-- | The session @Tab@ moves to, in ascending numeric order with wraparound,
-- or 'Nothing' when there is nowhere else to go: a single session, an empty
-- set, or a current key the set no longer holds. Returning 'Nothing' for a
-- singleton is what makes @Tab@ a genuine no-op there rather than a
-- re-open that would discard a notice and jump the transcript to its tail.
nextSessionKey :: Int -> [Int] -> Maybe Int
nextSessionKey current keys = do
  index <- findIndex (== current) ordered
  next <- safeIndex ((index + 1) `mod` length ordered) ordered
  if next == current then Nothing else Just next
  where
    ordered = sort keys

-- | What one key press does to a session overlay, before anything about that
-- particular kind is consulted. Every overlay answers the same table; the
-- kinds differ only in which optional bindings they offer ('SessionInputCaps')
-- and in what carrying the action out means.
data SessionInputEvent
  = SessionInputScroll Int
  | -- | @g@ and @G@: the whole transcript, not a relative amount, so follow
    -- state is re-derived from the end the view actually lands on rather
    -- than from a guess at how far away it was.
    SessionInputScrollTop
  | SessionInputScrollBottom
  | SessionInputBackspace
  | SessionInputInsert Char
  | SessionInputSubmit
  | SessionInputCycle
  | SessionInputInterrupt
  | -- | @i@: start editing the draft.
    SessionInputEnterInsert
  | -- | @Esc@ from insert: stop editing, keeping the draft.
    SessionInputLeaveInsert
  | -- | @f@ from normal: grow the overlay to fullscreen, or put it back. In
    -- insert mode the same letter is text, which is why this is decoded here
    -- with the rest of the modal table rather than in the shared arm the
    -- non-modal overlays answer it from.
    SessionInputFullscreen
  | -- | @q@ or @Esc@ from normal: hide the overlay. Never the application's
    -- own quit, which is what the board's @q@ still means.
    SessionInputClose
  | -- | A digit key resolved to a 0-based choice index, for a kind that
    -- offers numbered choices at all.
    SessionInputChoice Int
  deriving stock (Eq, Show)

-- | Which of the optional bindings a kind adds to the shared table.
data SessionInputCaps = SessionInputCaps
  { -- | @1@..@9@ answer a pending numbered question or approval instead of
    -- typing a digit.
    sessionCapsChoiceDigits :: Bool,
    -- | Ctrl-X as a second interrupt binding beside Ctrl-C.
    sessionCapsCancelChord :: Bool
  }
  deriving stock (Eq, Show)

noSessionInputCaps :: SessionInputCaps
noSessionInputCaps = SessionInputCaps False False

-- | Everything the shared decoder needs to know about the one session a key
-- press is landing on. The caps are the kind's, the other two are the
-- session's own, which is what makes the mode travel with the session rather
-- than with the overlay showing it.
data SessionFocus = SessionFocus
  { sessionFocusCaps :: SessionInputCaps,
    sessionFocusMode :: SessionMode,
    -- | Whether anything is still left to read text typed into this session.
    -- False for every phase and stage with no reader behind it, which is what
    -- pins such a session to normal mode and makes @i@ a no-op on it.
    sessionFocusLiveInput :: Bool
  }
  deriving stock (Eq, Show)

-- | The mode a session actually behaves and draws in, which is its own mode
-- only while something is still there to read what it types. Deriving it
-- rather than trusting the stored field is what keeps a phase settling
-- underneath an insert-mode session from stranding it: the transition that
-- ends the session's input does not have to remember to reset a mode, and a
-- session it forgot could otherwise swallow @q@, @j@, and @k@ forever.
liveSessionMode :: Bool -> SessionMode -> SessionMode
liveSessionMode True mode = mode
liveSessionMode False _ = SessionNormal

-- | The footer chips a live-agent overlay declares, which have to describe
-- the mode the focused session is actually in: in normal mode Enter sends
-- nothing and a printable key is a command, and a row that said otherwise
-- would name keys for a mode the user is not in. @sendLabel@ is the kind's
-- own word for what Enter does with the draft, which is why it is a
-- parameter rather than a fourth line here.
--
-- Declared beside 'sessionInputEvent' because that is what answers these
-- keys, and derived from the same 'SessionFocus' that decoder is handed: a
-- session with nothing left to read what it types shows the normal-mode set
-- whatever its stored mode holds, and so does an overlay whose session the
-- map no longer has ('Kanban.UI.SessionEvents.sessionFocusFor' reads an
-- absent session as settled). Nothing here is a second opinion about the
-- mode.
--
-- Deliberately not the whole input table. Printable keys, Backspace, the
-- review overlay's choice digits, and Ctrl-X are ordinary text entry and
-- capability-gated extras that 'sessionInputHelp' does not enumerate either;
-- the row names the shortcuts, and the help overlay behind @?@ stays the
-- complete list.
sessionFooterHints :: Text -> SessionFocus -> [Text]
sessionFooterHints sendLabel focus = case liveSessionMode focus.sessionFocusLiveInput focus.sessionFocusMode of
  SessionInsert ->
    [ "Esc normal",
      "Tab next session",
      "Ctrl-C interrupt",
      "Enter " <> sendLabel,
      "arrows/wheel scroll"
    ]
  SessionNormal
    | focus.sessionFocusLiveInput ->
        [ "Esc/q hide",
          fullscreenChip,
          "i insert",
          "Tab next session",
          "Ctrl-C interrupt",
          "j/k g/G Ctrl-D/U scroll"
        ]
    | otherwise ->
        [ "Esc/q hide",
          fullscreenChip,
          "Tab next session",
          "Ctrl-C interrupt",
          "j/k g/G Ctrl-D/U scroll"
        ]

-- | The fullscreen chip, taken from the binding rather than written out
-- again: @f@ is declared once in "Kanban.UI.Keys" and every surface that
-- names it -- this row, the two scoped footers, and the help overlay --
-- projects that one declaration. Normal mode only, because insert mode types
-- the letter into the draft.
fullscreenChip :: Text
fullscreenChip = footerHint (binding ToggleFullscreen)

-- | How far Ctrl-D and Ctrl-U move a transcript. Vim's half page is half the
-- window; a session transcript's viewport is a fixed 17-19 rows inside the
-- overlay, so one constant covers all three kinds.
sessionHalfPage :: Int
sessionHalfPage = 16

-- | The help overlay's rows for the bindings above that §7 lists. They live
-- here, beside 'sessionInputEvent', because that is where the keys themselves
-- are decided: the overlay renders these rather than keeping a second copy of
-- the same facts. What is deliberately /not/ here is the rest of insert mode
-- — backspace, the arrows, printable characters, and the capability-gated
-- chords — which is ordinary text entry that §7 does not enumerate.
--
-- Ctrl-C is not the single promise its old help row made. A resumable
-- session takes guidance afterwards, but a canonical review stage's process
-- is killed outright and lands in an interrupted terminal state that only a
-- fresh @r@ leaves — see 'Kanban.UI.Review.cancelReviewSession' and §7. The
-- row has to say so, or it tells a reader to type guidance into a session
-- that will never accept it.
sessionInputHelp :: [HelpEntry]
sessionInputHelp =
  [ HelpEntry
      [chord (Vty.KChar '\t') []]
      Nothing
      "next session in an open solve/PR/review overlay"
      (Just "In an open solve, PR, or review overlay, show the next in-memory session of that kind"),
    HelpEntry
      [chord (Vty.KChar 'c') [Vty.MCtrl]]
      Nothing
      "interrupt agent turn; guidance resumes it, r restarts canonical review"
      (Just "Interrupt the current turn in an open live-agent overlay — a resumable session then accepts user guidance; a canonical review stage's process is killed instead, landing the session in its interrupted terminal state, and restarts fresh via `r`"),
    HelpEntry
      [chord (Vty.KChar 'i') []]
      Nothing
      "session overlay: type into the draft (insert mode)"
      (Just "In an open live-agent overlay, put the focused session into insert mode, where printable keys and Backspace edit its draft; a no-op on a session with nothing left to read what it types"),
    HelpEntry
      [chord (Vty.KChar 'j') [], chord (Vty.KChar 'k') []]
      Nothing
      "session overlay normal mode: scroll transcript one line"
      (Just "In an open live-agent overlay's normal mode, scroll the focused session's transcript down or up one line"),
    HelpEntry
      [chord (Vty.KChar 'g') [], chord (Vty.KChar 'G') []]
      Nothing
      "session overlay normal mode: transcript beginning / live tail"
      (Just "In an open live-agent overlay's normal mode, jump the focused session's transcript to its beginning or back to its live tail"),
    HelpEntry
      [chord (Vty.KChar 'd') [Vty.MCtrl], chord (Vty.KChar 'u') [Vty.MCtrl]]
      Nothing
      "session overlay normal mode: scroll transcript sixteen lines"
      (Just "In an open live-agent overlay's normal mode, scroll the focused session's transcript down or up sixteen lines"),
    HelpEntry
      [chord (Vty.KChar 'q') []]
      Nothing
      "session overlay normal mode: hide the overlay"
      (Just "In an open live-agent overlay's normal mode, hide the overlay without interrupting its work and without quitting the dashboard")
  ]

-- | What one key press means in an open session overlay.
--
-- The table is modal (docs\/design.md section 7). A few bindings are outside
-- the modes entirely because they are about the /session/ rather than about
-- its draft: @Tab@, the interrupt chords, @Esc@, and @Enter@. Everything else
-- splits — in insert a printable character is text, in normal it is a
-- command.
sessionInputEvent :: SessionFocus -> Vty.Event -> Maybe SessionInputEvent
sessionInputEvent focus event = case event of
  Vty.EvKey (Vty.KChar '\t') [] -> Just SessionInputCycle
  Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl] -> Just SessionInputInterrupt
  Vty.EvKey (Vty.KChar 'x') [Vty.MCtrl]
    | caps.sessionCapsCancelChord -> Just SessionInputInterrupt
  -- Esc stages rather than chaining: it leaves insert, and from normal it
  -- hides the overlay. It never reaches the application's guarded quit, which
  -- is the board's own Esc and q.
  Vty.EvKey Vty.KEsc []
    | mode == SessionInsert -> Just SessionInputLeaveInsert
    | otherwise -> Just SessionInputClose
  -- Enter sends whatever the draft holds and drops the session back to
  -- normal. Declined outright where nothing is left to read it, so a settled
  -- session cannot take a follow-up.
  Vty.EvKey Vty.KEnter []
    | focus.sessionFocusLiveInput -> Just SessionInputSubmit
  _ -> case mode of
    SessionInsert -> insertModeEvent
    SessionNormal -> normalModeEvent
  where
    caps = focus.sessionFocusCaps
    mode = liveSessionMode focus.sessionFocusLiveInput focus.sessionFocusMode

    insertModeEvent = case event of
      Vty.EvKey Vty.KBS [] -> Just SessionInputBackspace
      Vty.EvKey (Vty.KChar character) []
        | isPrint character -> Just (SessionInputInsert character)
      _ -> SessionInputScroll <$> transcriptScrollKey event

    normalModeEvent = case event of
      Vty.EvKey (Vty.KChar 'i') []
        | focus.sessionFocusLiveInput -> Just SessionInputEnterInsert
      Vty.EvKey (Vty.KChar 'q') [] -> Just SessionInputClose
      Vty.EvKey (Vty.KChar 'f') [] -> Just SessionInputFullscreen
      Vty.EvKey (Vty.KChar 'j') [] -> Just (SessionInputScroll 1)
      Vty.EvKey (Vty.KChar 'k') [] -> Just (SessionInputScroll (-1))
      Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl] -> Just (SessionInputScroll sessionHalfPage)
      Vty.EvKey (Vty.KChar 'u') [Vty.MCtrl] -> Just (SessionInputScroll (-sessionHalfPage))
      Vty.EvKey (Vty.KChar 'g') [] -> Just SessionInputScrollTop
      Vty.EvKey (Vty.KChar 'G') [] -> Just SessionInputScrollBottom
      Vty.EvKey (Vty.KChar character) []
        | caps.sessionCapsChoiceDigits, character >= '1', character <= '9' ->
            Just (SessionInputChoice (fromEnum character - fromEnum '1'))
      _ -> SessionInputScroll <$> transcriptScrollKey event

-- | The mode one decoded event leaves its session in.
--
-- Total over 'SessionInputEvent' on purpose: the mode is a projection of the
-- whole table rather than a side effect remembered at three of its arms, so a
-- binding added later cannot be given a behavior without its mode being
-- decided in the same place. Only three arms move it — @i@ in, @Esc@ back
-- out, and @Enter@, which §7 makes return to normal on the keypress whether
-- or not the send that follows is accepted.
--
-- Nothing here touches the draft: leaving insert keeps what was typed, and
-- what a refused submission does with the line is the submitting hook's own
-- existing business.
sessionModeAfter :: SessionInputEvent -> SessionMode -> SessionMode
sessionModeAfter = \case
  SessionInputEnterInsert -> const SessionInsert
  SessionInputLeaveInsert -> const SessionNormal
  SessionInputSubmit -> const SessionNormal
  SessionInputScroll _ -> id
  SessionInputScrollTop -> id
  SessionInputScrollBottom -> id
  SessionInputBackspace -> id
  SessionInputInsert _ -> id
  -- Tab moves which session is shown; each keeps the mode it was left in, so
  -- the one being left behind keeps its own too.
  SessionInputCycle -> id
  SessionInputInterrupt -> id
  -- Fullscreen is the overlay's geometry, not the session's draft: growing
  -- the box leaves an insert-mode neighbour session exactly as it was, and
  -- the session this press landed on stays in normal, where the letter was a
  -- command in the first place.
  SessionInputFullscreen -> id
  SessionInputClose -> id
  SessionInputChoice _ -> id

-- | The relative transcript scroll a key press asks for, if any. The arrows
-- alone: they scroll in both modes, because an arrow is not text in either.
-- The review overlay's Ctrl-J\/Ctrl-K retired with the modes that replaced
-- them — plain @j@ and @k@ do that job for every kind now (issue #515).
-- Pure so every binding that can change follow state is unit-testable without
-- an 'EventM' harness; the wheel equivalents come from 'overlayMouseAction'.
transcriptScrollKey :: Vty.Event -> Maybe Int
transcriptScrollKey (Vty.EvKey Vty.KDown []) = Just 1
transcriptScrollKey (Vty.EvKey Vty.KUp []) = Just (-1)
transcriptScrollKey _ = Nothing
