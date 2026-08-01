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
    newAgentSession,
    nextSessionKey,
    noSessionInputCaps,
    priorTickGeneration,
    removeSessionInputCharacter,
    renderPhaseGlyph,
    sessionInputEvent,
    sessionInputHelp,
    sessionInputLimit,
    sessionsNeedingArm,
    setSessionActivity,
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
import Kanban.UI.Keys (HelpEntry (..), chord)
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
  | SessionInputBackspace
  | SessionInputInsert Char
  | SessionInputSubmit
  | SessionInputCycle
  | SessionInputInterrupt
  | -- | A digit key resolved to a 0-based choice index, for a kind that
    -- offers numbered choices at all.
    SessionInputChoice Int
  deriving stock (Eq, Show)

-- | Which of the optional bindings a kind adds to the shared table.
data SessionInputCaps = SessionInputCaps
  { -- | Ctrl-J / Ctrl-K as extra transcript scrolling.
    sessionCapsScrollChords :: Bool,
    -- | @1@..@9@ answer a pending numbered question or approval instead of
    -- typing a digit.
    sessionCapsChoiceDigits :: Bool,
    -- | Ctrl-X as a second interrupt binding beside Ctrl-C.
    sessionCapsCancelChord :: Bool
  }
  deriving stock (Eq, Show)

noSessionInputCaps :: SessionInputCaps
noSessionInputCaps = SessionInputCaps False False False

-- | The help overlay's rows for the two bindings above that §7 lists. They
-- live here, beside 'sessionInputEvent', because that is where the keys
-- themselves are decided: the overlay renders these rather than keeping a
-- second copy of the same facts. The rest of the shared table — backspace,
-- the arrows, printable characters, and the capability-gated chords — is
-- ordinary text entry that §7 does not enumerate.
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
      (Just "Interrupt the current turn in an open live-agent overlay — a resumable session then accepts user guidance; a canonical review stage's process is killed instead, landing the session in its interrupted terminal state, and restarts fresh via `r`")
  ]

sessionInputEvent :: SessionInputCaps -> Vty.Event -> Maybe SessionInputEvent
sessionInputEvent caps event = case event of
  Vty.EvKey (Vty.KChar '\t') [] -> Just SessionInputCycle
  Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl] -> Just SessionInputInterrupt
  Vty.EvKey (Vty.KChar 'x') [Vty.MCtrl]
    | caps.sessionCapsCancelChord -> Just SessionInputInterrupt
  Vty.EvKey Vty.KBS [] -> Just SessionInputBackspace
  Vty.EvKey Vty.KEnter [] -> Just SessionInputSubmit
  Vty.EvKey (Vty.KChar character) []
    | caps.sessionCapsChoiceDigits, character >= '1', character <= '9' ->
        Just (SessionInputChoice (fromEnum character - fromEnum '1'))
    | isPrint character -> Just (SessionInputInsert character)
  _ -> SessionInputScroll <$> transcriptScrollKey caps.sessionCapsScrollChords event

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
