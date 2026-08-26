-- | The session core all three agent-session kinds now share (issue #51).
--
-- Solve, pull-request, and review sessions used to carry their own copies of
-- these tables, and the copies had drifted into the bugs #29, #30 and #39
-- were filed for and into the lost PR-overlay @Tab@. Every group below runs
-- the /same/ table against all three kinds, so a future divergence has to
-- fail here rather than be discovered in use.
module Spec.UI.SessionCore (spec) where

import Data.List (nub)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Graphics.Vty as Vty
import Kanban.Domain (Board (..))
import Kanban.UI.Board
  ( boardHintLine,
    pullRequestPhaseGlyphFor,
    reviewPhaseGlyphFor,
    solvePhaseGlyphFor,
  )
import Kanban.UI.Overlay (drawOverlay)
import Kanban.UI.SessionCore
  ( SessionFocus (..),
    SessionInputCaps (..),
    SessionInputEvent (..),
    SessionTickArm (..),
    SessionTickFire (..),
    decideSessionTickArm,
    decideSessionTickFire,
    insertSessionInput,
    liveSessionMode,
    nextSessionKey,
    noSessionInputCaps,
    removeSessionInputCharacter,
    sessionHalfPage,
    sessionInputEvent,
    sessionInputLimit,
    sessionModeAfter,
    setSessionMode,
  )
import Kanban.UI.Session (reviewSessionInputLive, solveSessionInputLive, solveSessionMode)
import Kanban.UI.SessionEvents
  ( SessionOps (..),
    pullRequestSessionOps,
    reviewSessionOps,
    reviewTickEligible,
    sessionFocusFor,
    solveSessionOps,
    solveTickEligible,
  )
import Kanban.UI.Theme (themeFor)
import Kanban.UI.Transcript (TranscriptSession (..))
import Kanban.Review (ReviewStage (..))
import Kanban.UI.Types
  ( AgentSession (..),
    AppState (..),
    Overlay (..),
    ReviewPhase (..),
    SessionMode (..),
    SolvePhase (..),
  )
import Spec.Support.App
  ( testAppState,
    testPullRequestSession,
    testReviewSession,
    testSolveSession,
    withPullRequestSession,
    withReviewSession,
    withSolveSession,
  )
import Spec.Support.Fixtures (baseIssue, basePullRequest, testOptions)
import Spec.Support.Render (renderWidgetLines)
import Test.Hspec

-- | No cards at all: these frames are about the overlays, which read only
-- their own session maps.
emptyBoard :: Board
emptyBoard = Board Map.empty

-- | Every review phase, written out because 'ReviewPhase' is not an 'Enum'.
-- A phase added without being listed here leaves the canonical-stage sweep
-- below silently narrower than the claim it makes.
everyReviewPhase :: [ReviewPhase]
everyReviewPhase =
  [ ReviewStarting,
    ReviewRunning,
    ReviewWaiting,
    ReviewFinished,
    ReviewNeedsChanges,
    ReviewFailed,
    ReviewRevised,
    ReviewInterrupted
  ]

spec :: Spec
spec = do
  describe "shared session Tab cycling" $ do
    -- docs/design.md section 7 promises tabs over all in-memory sessions.
    -- Only the review overlay still had them: the PR overlay lost both the
    -- strip and the binding, and the solve overlay never grew either. All
    -- three now cycle through 'nextSessionKey'.
    it "moves to the next session in ascending numeric order" $ do
      nextSessionKey 7 [7, 12, 40] `shouldBe` Just 12
      nextSessionKey 12 [7, 12, 40] `shouldBe` Just 40

    it "reads the order from the keys themselves, not from how they arrived" $
      nextSessionKey 7 [40, 12, 7] `shouldBe` Just 12

    it "wraps from the last session back to the first" $
      nextSessionKey 40 [7, 12, 40] `shouldBe` Just 7

    it "is a no-op for a single session, so Tab cannot disturb what it shows" $ do
      -- Not merely "returns the same key": a 'Just' here would reopen the
      -- overlay, clearing the notice and jumping the transcript back to its
      -- tail even though nothing changed.
      nextSessionKey 7 [7] `shouldBe` Nothing

    it "is a no-op with nothing to cycle, or with a key the set no longer holds" $ do
      nextSessionKey 7 [] `shouldBe` Nothing
      nextSessionKey 99 [7, 12] `shouldBe` Nothing

    it "visits every session exactly once before returning to the start" $ do
      let keys = [3, 9, 21, 55]
          walk current 0 = [current]
          walk current remaining = current : maybe [] (\next -> walk next (remaining - 1 :: Int)) (nextSessionKey current keys)
          visited = walk 3 (length keys - 1)
      visited `shouldBe` [3, 9, 21, 55]
      nub visited `shouldBe` visited

    it "keeps every kind's overlay reachable from its own dictionary" $ do
      -- What 'cycleSession' opens once 'nextSessionKey' has chosen: the
      -- overlay of the same kind, never another's.
      solveSessionOps.sessionOpsOverlay 12 `shouldBe` SolveOverlay 12
      pullRequestSessionOps.sessionOpsOverlay 12 `shouldBe` PullRequestReviewOverlay 12
      reviewSessionOps.sessionOpsOverlay 12 `shouldBe` ReviewOverlay 12
      solveSessionOps.sessionOpsTranscript 12 `shouldBe` SolveTranscript 12
      pullRequestSessionOps.sessionOpsTranscript 12 `shouldBe` PullRequestTranscript 12
      reviewSessionOps.sessionOpsTranscript 12 `shouldBe` ReviewTranscript 12

    it "leaves each session's own draft and mode alone, so switching tabs preserves both" $ do
      -- Drafts and modes are per-session state, so cycling — which only
      -- changes which session is displayed — cannot touch them. issue #515
      -- makes the mode travel with the session for exactly this reason: Tab
      -- has to show the next session in whatever mode it was left in.
      let drafted =
            (testSolveSession (baseIssue 7 []) SolveRunning)
              {sessionInput = "half typed", sessionMode = SessionInsert}
          other = testSolveSession (baseIssue 12 []) SolveRunning
          sessions = Map.fromList [(7 :: Int, drafted), (12, other)]
      fmap (.sessionInput) (Map.lookup 7 sessions) `shouldBe` Just ("half typed" :: Text)
      fmap (.sessionInput) (Map.lookup 12 sessions) `shouldBe` Just ("" :: Text)
      fmap (.sessionMode) (Map.lookup 7 sessions) `shouldBe` Just SessionInsert
      fmap (.sessionMode) (Map.lookup 12 sessions) `shouldBe` Just SessionNormal
      -- Cycling reads the key set and nothing else, so neither session's own
      -- state is an input to where Tab goes.
      nextSessionKey 7 (Map.keys sessions) `shouldBe` Just 12
      sessionModeAfter SessionInputCycle SessionInsert `shouldBe` SessionInsert

  describe "shared session overlay key table" $ do
    -- The three overlays each had their own near-identical case table; the
    -- differences between them are now exactly 'SessionInputCaps', so the
    -- same events are run through all three below. Since issue #515 the table
    -- is also modal, so every kind is asked in both modes.
    let solveCaps = solveSessionOps.sessionOpsCaps
        pullRequestCaps = pullRequestSessionOps.sessionOpsCaps
        reviewCaps = reviewSessionOps.sessionOpsCaps
        allCaps = [("solve" :: Text, solveCaps), ("pull request", pullRequestCaps), ("review", reviewCaps)]
        normal caps = SessionFocus caps SessionNormal True
        insert caps = SessionFocus caps SessionInsert True
        forEveryKind check = mapM_ (\(label, caps) -> (label, check caps) `shouldBe` (label, True)) allCaps

    it "keeps Tab, Ctrl-C, and Enter outside the modes for every kind" $ do
      -- These are about the session rather than about its draft, so a mode
      -- cannot take them away.
      forEveryKind (\caps -> all (\mode -> sessionInputEvent (mode caps) (Vty.EvKey (Vty.KChar '\t') []) == Just SessionInputCycle) [normal, insert])
      forEveryKind (\caps -> all (\mode -> sessionInputEvent (mode caps) (Vty.EvKey Vty.KEnter []) == Just SessionInputSubmit) [normal, insert])
      forEveryKind (\caps -> all (\mode -> sessionInputEvent (mode caps) (Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl]) == Just SessionInputInterrupt) [normal, insert])

    it "edits the draft in insert mode for every kind" $ do
      forEveryKind (\caps -> sessionInputEvent (insert caps) (Vty.EvKey Vty.KBS []) == Just SessionInputBackspace)
      forEveryKind (\caps -> sessionInputEvent (insert caps) (Vty.EvKey (Vty.KChar 'z') []) == Just (SessionInputInsert 'z'))
      -- The letters normal mode claims are ordinary text here, which is the
      -- whole point of having two modes.
      forEveryKind
        ( \caps ->
            map (sessionInputEvent (insert caps) . (\character -> Vty.EvKey (Vty.KChar character) [])) "ijkgGq"
              == map (Just . SessionInputInsert) "ijkgGq"
        )

    it "gives every kind the arrow scroll bindings, in both modes" $ do
      -- An arrow is not text in either mode, so unlike j/k it never splits.
      forEveryKind (\caps -> all (\mode -> sessionInputEvent (mode caps) (Vty.EvKey Vty.KDown []) == Just (SessionInputScroll 1)) [normal, insert])
      forEveryKind (\caps -> all (\mode -> sessionInputEvent (mode caps) (Vty.EvKey Vty.KUp []) == Just (SessionInputScroll (-1))) [normal, insert])

    it "gives every kind the normal-mode transcript commands" $ do
      forEveryKind (\caps -> sessionInputEvent (normal caps) (Vty.EvKey (Vty.KChar 'j') []) == Just (SessionInputScroll 1))
      forEveryKind (\caps -> sessionInputEvent (normal caps) (Vty.EvKey (Vty.KChar 'k') []) == Just (SessionInputScroll (-1)))
      forEveryKind (\caps -> sessionInputEvent (normal caps) (Vty.EvKey (Vty.KChar 'd') [Vty.MCtrl]) == Just (SessionInputScroll sessionHalfPage))
      forEveryKind (\caps -> sessionInputEvent (normal caps) (Vty.EvKey (Vty.KChar 'u') [Vty.MCtrl]) == Just (SessionInputScroll (-sessionHalfPage)))
      forEveryKind (\caps -> sessionInputEvent (normal caps) (Vty.EvKey (Vty.KChar 'g') []) == Just SessionInputScrollTop)
      forEveryKind (\caps -> sessionInputEvent (normal caps) (Vty.EvKey (Vty.KChar 'G') []) == Just SessionInputScrollBottom)
      sessionHalfPage `shouldBe` 16

    it "stages Esc rather than chaining it" $ do
      -- Insert returns to normal; normal hides the overlay. Neither reaches
      -- the application's own quit, which is why 'SessionInputClose' is a
      -- distinct event rather than a board action.
      forEveryKind (\caps -> sessionInputEvent (insert caps) (Vty.EvKey Vty.KEsc []) == Just SessionInputLeaveInsert)
      forEveryKind (\caps -> sessionInputEvent (normal caps) (Vty.EvKey Vty.KEsc []) == Just SessionInputClose)

    it "makes q an overlay close in normal mode and a character in insert" $ do
      forEveryKind (\caps -> sessionInputEvent (normal caps) (Vty.EvKey (Vty.KChar 'q') []) == Just SessionInputClose)
      forEveryKind (\caps -> sessionInputEvent (insert caps) (Vty.EvKey (Vty.KChar 'q') []) == Just (SessionInputInsert 'q'))

    it "enters insert from normal with i, and never from insert" $ do
      forEveryKind (\caps -> sessionInputEvent (normal caps) (Vty.EvKey (Vty.KChar 'i') []) == Just SessionInputEnterInsert)
      forEveryKind (\caps -> sessionInputEvent (insert caps) (Vty.EvKey (Vty.KChar 'i') []) == Just (SessionInputInsert 'i'))

    it "keeps the review overlay's extra bindings to the review overlay" $ do
      -- Numbered choices and Ctrl-X as a second interrupt are review's alone.
      -- Ctrl-J/Ctrl-K and the capability that gated them are gone: plain j and
      -- k scroll every kind now (issue #515 requirement 8).
      (solveCaps, pullRequestCaps) `shouldBe` (SessionInputCaps False False, SessionInputCaps False False)
      reviewCaps `shouldBe` SessionInputCaps True True
      mapM_
        ( \(label, caps) ->
            (label, map (\mode -> sessionInputEvent (mode caps) (Vty.EvKey (Vty.KChar 'j') [Vty.MCtrl])) [normal, insert])
              `shouldBe` (label, [Nothing, Nothing])
        )
        allCaps
      mapM_
        ( \(label, caps) ->
            (label, map (\mode -> sessionInputEvent (mode caps) (Vty.EvKey (Vty.KChar 'k') [Vty.MCtrl])) [normal, insert])
              `shouldBe` (label, [Nothing, Nothing])
        )
        allCaps
      sessionInputEvent (normal reviewCaps) (Vty.EvKey (Vty.KChar 'x') [Vty.MCtrl]) `shouldBe` Just SessionInputInterrupt
      sessionInputEvent (insert reviewCaps) (Vty.EvKey (Vty.KChar 'x') [Vty.MCtrl]) `shouldBe` Just SessionInputInterrupt
      sessionInputEvent (normal solveCaps) (Vty.EvKey (Vty.KChar 'x') [Vty.MCtrl]) `shouldBe` Nothing

    it "routes a normal-mode digit to the pending choice only where choices exist" $ do
      sessionInputEvent (normal reviewCaps) (Vty.EvKey (Vty.KChar '3') []) `shouldBe` Just (SessionInputChoice 2)
      sessionInputEvent (normal solveCaps) (Vty.EvKey (Vty.KChar '3') []) `shouldBe` Nothing
      sessionInputEvent (normal pullRequestCaps) (Vty.EvKey (Vty.KChar '3') []) `shouldBe` Nothing
      -- '0' is not a choice digit even in the review overlay.
      sessionInputEvent (normal reviewCaps) (Vty.EvKey (Vty.KChar '0') []) `shouldBe` Nothing

    it "types every digit as literal text in insert mode, review included" $
      forEveryKind
        ( \caps ->
            map (sessionInputEvent (insert caps) . (\character -> Vty.EvKey (Vty.KChar character) [])) "0123456789"
              == map (Just . SessionInputInsert) "0123456789"
        )

    it "ignores keys none of the overlays bind, in either mode" $
      forEveryKind (\caps -> all (\mode -> sessionInputEvent (mode caps) (Vty.EvKey (Vty.KFun 5) []) == Nothing) [normal, insert])

  describe "session overlays with nothing left to read what they type" $ do
    -- issue #515 requirement 12. A settled session is pinned to normal mode
    -- however its own field reads, which is what keeps a phase settling
    -- underneath an insert-mode session from stranding it: its stored mode is
    -- never consulted again, so `q`, `j`, and Esc keep working.
    let settled mode = SessionFocus reviewSessionOps.sessionOpsCaps mode False
        bothModes = [SessionNormal, SessionInsert]

    it "derives the mode a settled session behaves and draws in" $ do
      map (liveSessionMode True) bothModes `shouldBe` bothModes
      map (liveSessionMode False) bothModes `shouldBe` [SessionNormal, SessionNormal]

    it "makes i a no-op on it, from either stored mode" $
      map (\mode -> sessionInputEvent (settled mode) (Vty.EvKey (Vty.KChar 'i') [])) bothModes
        `shouldBe` [Nothing, Nothing]

    it "takes no Enter follow-up on it" $
      map (\mode -> sessionInputEvent (settled mode) (Vty.EvKey Vty.KEnter [])) bothModes
        `shouldBe` [Nothing, Nothing]

    it "types nothing into it, even from a stored insert mode" $ do
      map (\mode -> sessionInputEvent (settled mode) (Vty.EvKey (Vty.KChar 'z') [])) bothModes
        `shouldBe` [Nothing, Nothing]
      map (\mode -> sessionInputEvent (settled mode) (Vty.EvKey Vty.KBS [])) bothModes
        `shouldBe` [Nothing, Nothing]

    it "keeps Tab, q, Esc, and every scroll key working on it" $ do
      let answers key = map (\mode -> sessionInputEvent (settled mode) key) bothModes
      answers (Vty.EvKey (Vty.KChar '\t') []) `shouldBe` [Just SessionInputCycle, Just SessionInputCycle]
      answers (Vty.EvKey (Vty.KChar 'q') []) `shouldBe` [Just SessionInputClose, Just SessionInputClose]
      answers (Vty.EvKey Vty.KEsc []) `shouldBe` [Just SessionInputClose, Just SessionInputClose]
      answers (Vty.EvKey (Vty.KChar 'j') []) `shouldBe` [Just (SessionInputScroll 1), Just (SessionInputScroll 1)]
      answers (Vty.EvKey (Vty.KChar 'k') []) `shouldBe` [Just (SessionInputScroll (-1)), Just (SessionInputScroll (-1))]
      answers (Vty.EvKey (Vty.KChar 'g') []) `shouldBe` [Just SessionInputScrollTop, Just SessionInputScrollTop]
      answers (Vty.EvKey (Vty.KChar 'G') []) `shouldBe` [Just SessionInputScrollBottom, Just SessionInputScrollBottom]
      answers (Vty.EvKey Vty.KDown []) `shouldBe` [Just (SessionInputScroll 1), Just (SessionInputScroll 1)]
      answers (Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl]) `shouldBe` [Just SessionInputInterrupt, Just SessionInputInterrupt]

    it "still answers a pending numbered choice on it" $
      -- An approval or question is exactly the state a canonical stage cannot
      -- reach, but a revision that settles while one is on screen still has
      -- digits worth answering with.
      map (\mode -> sessionInputEvent (settled mode) (Vty.EvKey (Vty.KChar '2') [])) bothModes
        `shouldBe` [Just (SessionInputChoice 1), Just (SessionInputChoice 1)]

  describe "a key press for a session the map no longer holds" $
    -- The overlay is drawing "session is no longer available" and Esc still
    -- has to close it. Before issue #515 that worked because Esc was
    -- short-circuited above the session table; now the table answers it, so
    -- the absent session has to reach the decoder as a settled one.
    it "still closes the overlay and scrolls, and offers no input" $ do
      state <- testAppState emptyBoard
      let absent = sessionFocusFor solveSessionOps 7 state
      Map.lookup 7 (solveSessionOps.sessionOpsSessions state) `shouldBe` Nothing
      sessionInputEvent absent (Vty.EvKey Vty.KEsc []) `shouldBe` Just SessionInputClose
      sessionInputEvent absent (Vty.EvKey (Vty.KChar 'q') []) `shouldBe` Just SessionInputClose
      sessionInputEvent absent (Vty.EvKey (Vty.KChar 'j') []) `shouldBe` Just (SessionInputScroll 1)
      sessionInputEvent absent (Vty.EvKey (Vty.KChar 'i') []) `shouldBe` Nothing
      sessionInputEvent absent (Vty.EvKey Vty.KEnter []) `shouldBe` Nothing

  describe "which sessions still read what they type" $ do
    -- The phase and stage halves of issue #515 requirement 12, asked of the
    -- predicates the overlays and the decoder both consult.
    it "gives a solve or PR session input only while it waits for it" $ do
      -- 'submitSolveInput' refuses every other phase and 'drawSolveInput'
      -- draws the line in this one alone, so insert mode anywhere else would
      -- edit a draft that is neither visible nor sendable. Unlike review,
      -- there is no undelivered queue behind these two to hold a mid-turn
      -- draft (PR #523 round 1).
      solveSessionInputLive SolveAttention `shouldBe` True
      map solveSessionInputLive [SolveStarting, SolveRunning, SolveInterrupting]
        `shouldBe` replicate 3 False
      map solveSessionInputLive [SolveFinished, SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase]
        `shouldBe` replicate 4 False

    it "pins a working solve session to normal mode whatever its stored mode" $ do
      -- The derived answer, which is what the overlay draws and the decoder
      -- reads; the stored field is never consulted on its own.
      let working = (testSolveSession (baseIssue 1 []) SolveRunning) {sessionMode = SessionInsert}
      solveSessionMode working `shouldBe` SessionNormal
      solveSessionMode working {sessionPhase = SolveAttention} `shouldBe` SessionInsert
      sessionInputEvent (SessionFocus noSessionInputCaps working.sessionMode (solveSessionInputLive working.sessionPhase)) (Vty.EvKey (Vty.KChar 'i') [])
        `shouldBe` Nothing

    it "gives a canonical review stage no input in any phase" $
      -- It runs approve_issues.py as a subprocess and carries no app-server
      -- thread, so there has never been anywhere for typed text to go.
      sequence_
        [ (stage, phase, reviewSessionInputLive stage phase) `shouldBe` (stage, phase, False)
          | stage <- [InitialReview, IssueRereview],
            phase <- everyReviewPhase
        ]

    it "keeps an app-server revision's input until it settles" $ do
      map (reviewSessionInputLive IssueRevision) [ReviewStarting, ReviewRunning, ReviewWaiting]
        `shouldBe` replicate 3 True
      map (reviewSessionInputLive IssueRevision) [ReviewFinished, ReviewNeedsChanges, ReviewFailed, ReviewRevised]
        `shouldBe` replicate 4 False

    it "keeps an interrupted revision resumable, unlike an interrupted canonical stage" $ do
      -- docs/design.md section 7 promises guidance after an interrupt, and
      -- 'reviewSessionReusable' reopens an interrupted revision rather than
      -- launching a fresh one. Only a canonical stage's interrupt is terminal.
      reviewSessionInputLive IssueRevision ReviewInterrupted `shouldBe` True
      map (`reviewSessionInputLive` ReviewInterrupted) [InitialReview, IssueRereview] `shouldBe` [False, False]

  describe "what a decoded session event does to the mode" $ do
    -- The mode is a projection of the whole table rather than a side effect
    -- remembered at three arms, so this is asked of every constructor.
    it "moves into insert on i and back out on Esc" $ do
      sessionModeAfter SessionInputEnterInsert SessionNormal `shouldBe` SessionInsert
      sessionModeAfter SessionInputEnterInsert SessionInsert `shouldBe` SessionInsert
      sessionModeAfter SessionInputLeaveInsert SessionInsert `shouldBe` SessionNormal
      sessionModeAfter SessionInputLeaveInsert SessionNormal `shouldBe` SessionNormal

    it "returns to normal on Enter, whatever the submission then does" $ do
      -- The mode is the keypress's, not the send's: a hook that refuses an
      -- empty draft or a disconnected backend must not leave the session in
      -- insert as if nothing had been pressed.
      sessionModeAfter SessionInputSubmit SessionInsert `shouldBe` SessionNormal
      sessionModeAfter SessionInputSubmit SessionNormal `shouldBe` SessionNormal

    it "leaves the mode alone for every other event" $
      sequence_
        [ (inputEvent, sessionModeAfter inputEvent mode) `shouldBe` (inputEvent, mode)
          | inputEvent <-
              [ SessionInputScroll 1,
                SessionInputScroll (-1),
                SessionInputScrollTop,
                SessionInputScrollBottom,
                SessionInputBackspace,
                SessionInputInsert 'z',
                SessionInputCycle,
                SessionInputInterrupt,
                SessionInputClose,
                SessionInputChoice 0
              ],
            mode <- [SessionNormal, SessionInsert]
        ]

    it "leaves the draft where it is on every mode change" $ do
      -- Leaving insert keeps what was typed; entering it does not clear the
      -- line either.
      let drafted = (testReviewSession (baseIssue 7 []) ReviewRunning) {sessionInput = "half typed"}
      (setSessionMode SessionInsert drafted).sessionInput `shouldBe` ("half typed" :: Text)
      (setSessionMode SessionNormal drafted {sessionMode = SessionInsert}).sessionInput `shouldBe` ("half typed" :: Text)
      (setSessionMode SessionNormal drafted).sessionTranscript `shouldBe` drafted.sessionTranscript

    it "opens every kind in normal mode" $ do
      (testSolveSession (baseIssue 1 []) SolveRunning).sessionMode `shouldBe` SessionNormal
      (testPullRequestSession (basePullRequest 2 [] False []) SolveRunning).sessionMode `shouldBe` SessionNormal
      (testReviewSession (baseIssue 3 []) ReviewRunning).sessionMode `shouldBe` SessionNormal

  describe "shared session input editing" $ do
    -- One bounded editor for all three kinds, where there were three.
    let overLimit = Text.replicate (sessionInputLimit + 10) "x"

    it "appends a printable character for every kind" $ do
      (insertSessionInput 'a' (testSolveSession (baseIssue 1 []) SolveRunning)).sessionInput `shouldBe` "a"
      (insertSessionInput 'a' (testPullRequestSession (basePullRequest 2 [] False []) SolveRunning)).sessionInput `shouldBe` "a"
      (insertSessionInput 'a' (testReviewSession (baseIssue 3 []) ReviewRunning)).sessionInput `shouldBe` "a"

    it "bounds every kind's input line at the same limit" $ do
      let solveFull = (testSolveSession (baseIssue 1 []) SolveRunning) {sessionInput = overLimit}
          pullRequestFull = (testPullRequestSession (basePullRequest 2 [] False []) SolveRunning) {sessionInput = overLimit}
          reviewFull = (testReviewSession (baseIssue 3 []) ReviewRunning) {sessionInput = overLimit}
      Text.length (insertSessionInput 'a' solveFull).sessionInput `shouldBe` sessionInputLimit
      Text.length (insertSessionInput 'a' pullRequestFull).sessionInput `shouldBe` sessionInputLimit
      Text.length (insertSessionInput 'a' reviewFull).sessionInput `shouldBe` sessionInputLimit

    it "removes the last character for every kind, and does nothing on an empty line" $ do
      let solve = testSolveSession (baseIssue 1 []) SolveRunning
          pullRequest = testPullRequestSession (basePullRequest 2 [] False []) SolveRunning
          review = testReviewSession (baseIssue 3 []) ReviewRunning
      [ (removeSessionInputCharacter solve {sessionInput = "abc"}).sessionInput,
        (removeSessionInputCharacter pullRequest {sessionInput = "abc"}).sessionInput,
        (removeSessionInputCharacter review {sessionInput = "abc"}).sessionInput
        ]
        `shouldBe` (["ab", "ab", "ab"] :: [Text])
      [ (removeSessionInputCharacter solve {sessionInput = ""}).sessionInput,
        (removeSessionInputCharacter pullRequest {sessionInput = ""}).sessionInput,
        (removeSessionInputCharacter review {sessionInput = ""}).sessionInput
        ]
        `shouldBe` (["", "", ""] :: [Text])

  describe "shared animation tick contract" $ do
    -- issue #30 gave review sessions a generation and an armed flag; solve
    -- and PR sessions had neither, so a resume that re-registered a process
    -- while an old tick was still in flight could leave two chains running.
    -- Both now answer the same decisions.
    it "animates a solve or PR session only while it is starting or running" $ do
      map solveTickEligible [SolveStarting, SolveRunning] `shouldBe` [True, True]
      map
        solveTickEligible
        [SolveInterrupting, SolveAttention, SolveFinished, SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase]
        `shouldBe` replicate 6 False

    it "keeps the solve and PR spinners running with no overlay open" $ do
      -- Their frames drive the board's own card badge and activity timer, so
      -- unlike review they must not be gated on overlay visibility.
      decideSessionTickArm (solveTickEligible SolveRunning) False 0 `shouldBe` ArmSessionTick 1
      decideSessionTickFire 1 1 (solveTickEligible SolveRunning) `shouldBe` SessionTickReschedule
      -- Review, whose ticks are the only thing driving its redraws, still is.
      decideSessionTickArm (reviewTickEligible False ReviewRunning) False 0 `shouldBe` SessionTickNotEligible

    it "coalesces repeated arm requests for a solve or PR session onto one chain" $ do
      decideSessionTickArm (solveTickEligible SolveRunning) True 4 `shouldBe` SessionTickAlreadyArmed
      decideSessionTickArm (solveTickEligible SolveStarting) True 4 `shouldBe` SessionTickAlreadyArmed

    it "drops a stale solve or PR tick instead of rescheduling it" $
      decideSessionTickFire 3 2 (solveTickEligible SolveRunning) `shouldBe` SessionTickStale

    it "expires and unarms a solve or PR chain once the session stops running" $
      mapM_
        (\phase -> decideSessionTickFire 1 1 (solveTickEligible phase) `shouldBe` SessionTickExpire)
        [SolveAttention, SolveFinished, SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase, SolveInterrupting]

    it "stops a replacement solve session colliding with the old one's queued tick" $ do
      -- 'startFreshIssueSolve' replaces a terminal session for the same
      -- issue while a tick it queued may still be in flight, which is the
      -- collision issue #30's round-3 review found for review sessions.
      -- 'newAgentSession' bumps past the prior generation at construction
      -- time for every kind, so the stale tick is dropped before the
      -- replacement has armed anything of its own.
      let staleGeneration = 4
          replacement = testSolveSession (baseIssue 1 []) SolveStarting
          replacementGeneration = (replacement {sessionTickGeneration = staleGeneration + 1}).sessionTickGeneration
      decideSessionTickFire replacementGeneration staleGeneration (solveTickEligible SolveStarting) `shouldBe` SessionTickStale
      decideSessionTickArm (solveTickEligible SolveStarting) False replacementGeneration
        `shouldBe` ArmSessionTick (replacementGeneration + 1)
      decideSessionTickFire (replacementGeneration + 1) staleGeneration (solveTickEligible SolveStarting)
        `shouldBe` SessionTickStale

  describe "shared phase badge rendering" $ do
    -- Three copies of the glyph table became one renderer over three
    -- appearance tables, so the spinner and ASCII-mode behavior can no
    -- longer differ by kind.
    let solveAt frame phase = solvePhaseGlyphFor False ((testSolveSession (baseIssue 1 []) phase) {sessionSpinnerFrame = frame})
        pullRequestAt frame phase =
          pullRequestPhaseGlyphFor False ((testPullRequestSession (basePullRequest 2 [] False []) phase) {sessionSpinnerFrame = frame})
        reviewAt frame phase = reviewPhaseGlyphFor False ((testReviewSession (baseIssue 3 []) phase) {sessionSpinnerFrame = frame})
        solveAscii phase = solvePhaseGlyphFor True (testSolveSession (baseIssue 1 []) phase)
        pullRequestAscii phase = pullRequestPhaseGlyphFor True (testPullRequestSession (basePullRequest 2 [] False []) phase)
        reviewAscii phase = reviewPhaseGlyphFor True (testReviewSession (baseIssue 3 []) phase)

    it "advances every kind's spinner with its frame while running" $ do
      solveAt 0 SolveRunning `shouldNotBe` solveAt 1 SolveRunning
      pullRequestAt 0 SolveStarting `shouldNotBe` pullRequestAt 1 SolveStarting
      reviewAt 0 ReviewRunning `shouldNotBe` reviewAt 1 ReviewRunning
      -- Ten frames, then the cycle repeats, for all three.
      solveAt 0 SolveRunning `shouldBe` solveAt 10 SolveRunning
      pullRequestAt 0 SolveRunning `shouldBe` pullRequestAt 10 SolveRunning
      reviewAt 0 ReviewRunning `shouldBe` reviewAt 10 ReviewRunning

    it "holds every kind's settled badge still whatever the frame" $ do
      solveAt 0 SolveFailedPhase `shouldBe` solveAt 7 SolveFailedPhase
      pullRequestAt 0 SolveFinished `shouldBe` pullRequestAt 7 SolveFinished
      reviewAt 0 ReviewWaiting `shouldBe` reviewAt 7 ReviewWaiting

    it "substitutes one ASCII spinner for every kind" $
      map solveAscii [SolveStarting, SolveRunning]
        <> map pullRequestAscii [SolveStarting, SolveRunning]
        <> map reviewAscii [ReviewStarting, ReviewRunning]
        `shouldBe` replicate 6 "* "

    it "keeps the one appearance the solve and PR badges deliberately disagree on" $ do
      -- A finished solve has nothing left to do; a finished PR review is
      -- ready. Every other arm of their shared table matches.
      solveAt 0 SolveFinished `shouldNotBe` pullRequestAt 0 SolveFinished
      mapM_
        (\phase -> solveAt 0 phase `shouldBe` pullRequestAt 0 phase)
        [SolveStarting, SolveRunning, SolveInterrupting, SolveAttention, SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase]
      mapM_
        (\phase -> solveAscii phase `shouldBe` pullRequestAscii phase)
        [SolveStarting, SolveRunning, SolveInterrupting, SolveAttention, SolveFinished, SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase]

    it "keeps the review badge's own waiting, revised, and interrupted states distinct" $ do
      let reviewBadges = map (reviewAt 0) [ReviewWaiting, ReviewFinished, ReviewNeedsChanges, ReviewFailed, ReviewRevised, ReviewInterrupted]
      nub reviewBadges `shouldBe` reviewBadges

  describe "session overlay tab strips" $ do
    -- docs/design.md section 7's "tabs for all in-memory sessions" was true
    -- of the review overlay alone. These draw each overlay through the same
    -- 'drawOverlay' the dashboard uses, so the strip has to survive the
    -- overlay's fixed height rather than be clipped off the bottom of it.
    --
    -- The hint that used to sit inside the box beneath the strip is the base
    -- footer's row now (issue #525), so it is asked of 'boardHintLine' with
    -- that overlay open rather than of the box.
    let overlayRows state overlay = renderWidgetLines (themeFor testOptions) 100 (drawOverlay state overlay)
        hintFor state overlay = boardHintLine state {appOverlay = Just overlay}
        rowMentioningBoth first second rows =
          [row | row <- rows, first `Text.isInfixOf` row, second `Text.isInfixOf` row]

    it "lists every in-memory solve session, and offers Tab, in the solve overlay" $ do
      state <-
        withSolveSession (baseIssue 7 []) SolveRunning
          . withSolveSession (baseIssue 12 []) SolveRunning
          <$> testAppState emptyBoard
      let rows = overlayRows state (SolveOverlay 7)
      rowMentioningBoth "#7" "#12" rows `shouldNotBe` []
      ("Tab next session" `Text.isInfixOf` hintFor state (SolveOverlay 7)) `shouldBe` True

    it "lists every in-memory PR session, and offers Tab, in the PR overlay" $ do
      -- issue #51's headline regression: the PR overlay had neither.
      state <-
        withPullRequestSession (basePullRequest 7 [] False []) SolveRunning
          . withPullRequestSession (basePullRequest 12 [] False []) SolveRunning
          <$> testAppState emptyBoard
      let rows = overlayRows state (PullRequestReviewOverlay 7)
      rowMentioningBoth "#7" "#12" rows `shouldNotBe` []
      ("Tab next session" `Text.isInfixOf` hintFor state (PullRequestReviewOverlay 7)) `shouldBe` True

    it "keeps the review overlay's own strip, and its hint on the footer" $ do
      state <-
        withReviewSession (baseIssue 7 []) ReviewRunning
          . withReviewSession (baseIssue 12 []) ReviewRunning
          <$> testAppState emptyBoard
      let rows = overlayRows state (ReviewOverlay 7)
      rowMentioningBoth "#7" "#12" rows `shouldNotBe` []
      ("Tab next session" `Text.isInfixOf` hintFor state (ReviewOverlay 7)) `shouldBe` True

    it "still draws the tallest overlay's input line, so the added strip clipped nothing off" $ do
      -- A solve session waiting for input is the tallest layout: phase line,
      -- activity, reviewer, log path, transcript, and the prompt that used to
      -- have the hint under it. The prompt is now what the box ends with, so
      -- it is what a clipped box would take, and the mode-dependent hint is
      -- asked of the footer beside it.
      state <-
        withSolveSession (baseIssue 7 []) SolveAttention
          <$> testAppState emptyBoard
      let inserting current =
            current
              { appSolveSessions = Map.adjust (setSessionMode SessionInsert) 7 current.appSolveSessions
              }
      filter (Text.isInfixOf "█") (overlayRows state (SolveOverlay 7)) `shouldNotBe` []
      filter (Text.isInfixOf "█") (overlayRows (inserting state) (SolveOverlay 7)) `shouldNotBe` []
      ("i insert" `Text.isInfixOf` hintFor state (SolveOverlay 7)) `shouldBe` True
      ("Enter answer" `Text.isInfixOf` hintFor (inserting state) (SolveOverlay 7)) `shouldBe` True

    it "shows the focused session's mode badge, and only its own" $ do
      -- The badge is per session, so cycling to a session left in insert has
      -- to bring that session's mode with it (issue #515 requirement 2).
      state <-
        withSolveSession (baseIssue 7 []) SolveAttention
          . withSolveSession (baseIssue 12 []) SolveAttention
          <$> testAppState emptyBoard
      let inserted =
            state
              { appSolveSessions = Map.adjust (setSessionMode SessionInsert) 12 state.appSolveSessions
              }
      filter (Text.isInfixOf "[N]") (overlayRows inserted (SolveOverlay 7)) `shouldNotBe` []
      filter (Text.isInfixOf "[I]") (overlayRows inserted (SolveOverlay 7)) `shouldBe` []
      filter (Text.isInfixOf "[I]") (overlayRows inserted (SolveOverlay 12)) `shouldNotBe` []

    it "pins a session with no reader to the normal badge whatever its stored mode" $ do
      -- Requirement 12: such a session sits permanently in normal mode, so a
      -- mode left behind by a phase that has since moved on cannot show. Both
      -- shapes: a resolved workflow, and one still running with no draft line
      -- and no submit path (PR #523 round 1).
      state <-
        withSolveSession (baseIssue 7 []) SolveFinished
          <$> testAppState emptyBoard
      running <-
        withSolveSession (baseIssue 9 []) SolveRunning
          <$> testAppState emptyBoard
      let stranded =
            state
              { appSolveSessions = Map.adjust (setSessionMode SessionInsert) 7 state.appSolveSessions
              }
          rows = overlayRows stranded (SolveOverlay 7)
          working = running {appSolveSessions = Map.adjust (setSessionMode SessionInsert) 9 running.appSolveSessions}
          workingRows = overlayRows working (SolveOverlay 9)
      filter (Text.isInfixOf "[N]") rows `shouldNotBe` []
      filter (Text.isInfixOf "[I]") rows `shouldBe` []
      filter (Text.isInfixOf "[N]") workingRows `shouldNotBe` []
      filter (Text.isInfixOf "[I]") workingRows `shouldBe` []
      -- And the footer's row drops the i neither of them can honour, while
      -- still naming the keys they do answer -- an empty row would satisfy
      -- the absence on its own.
      ("i insert" `Text.isInfixOf` hintFor stranded (SolveOverlay 7)) `shouldBe` False
      ("i insert" `Text.isInfixOf` hintFor working (SolveOverlay 9)) `shouldBe` False
      ("Esc/q hide" `Text.isInfixOf` hintFor stranded (SolveOverlay 7)) `shouldBe` True
      ("Esc/q hide" `Text.isInfixOf` hintFor working (SolveOverlay 9)) `shouldBe` True
