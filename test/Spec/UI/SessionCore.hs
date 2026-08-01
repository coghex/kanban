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
  ( pullRequestPhaseGlyphFor,
    reviewPhaseGlyphFor,
    solvePhaseGlyphFor,
  )
import Kanban.UI.Overlay (drawOverlay)
import Kanban.UI.SessionCore
  ( SessionInputCaps (..),
    SessionInputEvent (..),
    SessionTickArm (..),
    SessionTickFire (..),
    decideSessionTickArm,
    decideSessionTickFire,
    insertSessionInput,
    nextSessionKey,
    removeSessionInputCharacter,
    sessionInputEvent,
    sessionInputLimit,
  )
import Kanban.UI.SessionEvents
  ( SessionOps (..),
    pullRequestSessionOps,
    reviewSessionOps,
    reviewTickEligible,
    solveSessionOps,
    solveTickEligible,
  )
import Kanban.UI.Theme (themeFor)
import Kanban.UI.Transcript (TranscriptSession (..))
import Kanban.UI.Types
  ( AgentSession (..),
    Overlay (..),
    ReviewPhase (..),
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

    it "leaves each session's own draft alone, so switching tabs preserves it" $ do
      -- Drafts are per-session state, so cycling — which only changes which
      -- session is displayed — cannot touch them.
      let drafted = (testSolveSession (baseIssue 7 []) SolveRunning) {sessionInput = "half typed"}
          other = testSolveSession (baseIssue 12 []) SolveRunning
          sessions = Map.fromList [(7 :: Int, drafted), (12, other)]
      fmap (.sessionInput) (Map.lookup 7 sessions) `shouldBe` Just ("half typed" :: Text)
      fmap (.sessionInput) (Map.lookup 12 sessions) `shouldBe` Just ("" :: Text)

  describe "shared session overlay key table" $ do
    -- The three overlays each had their own near-identical case table; the
    -- differences between them are now exactly 'SessionInputCaps', so the
    -- same events are run through all three below.
    let solveCaps = solveSessionOps.sessionOpsCaps
        pullRequestCaps = pullRequestSessionOps.sessionOpsCaps
        reviewCaps = reviewSessionOps.sessionOpsCaps
        allCaps = [("solve" :: Text, solveCaps), ("pull request", pullRequestCaps), ("review", reviewCaps)]
        forEveryKind check = mapM_ (\(label, caps) -> (label, check caps) `shouldBe` (label, True)) allCaps

    it "gives every kind Tab, Enter, Ctrl-C, backspace, and printable insertion" $ do
      forEveryKind (\caps -> sessionInputEvent caps (Vty.EvKey (Vty.KChar '\t') []) == Just SessionInputCycle)
      forEveryKind (\caps -> sessionInputEvent caps (Vty.EvKey Vty.KEnter []) == Just SessionInputSubmit)
      forEveryKind (\caps -> sessionInputEvent caps (Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl]) == Just SessionInputInterrupt)
      forEveryKind (\caps -> sessionInputEvent caps (Vty.EvKey Vty.KBS []) == Just SessionInputBackspace)
      forEveryKind (\caps -> sessionInputEvent caps (Vty.EvKey (Vty.KChar 'z') []) == Just (SessionInputInsert 'z'))

    it "gives every kind the arrow scroll bindings" $ do
      forEveryKind (\caps -> sessionInputEvent caps (Vty.EvKey Vty.KDown []) == Just (SessionInputScroll 1))
      forEveryKind (\caps -> sessionInputEvent caps (Vty.EvKey Vty.KUp []) == Just (SessionInputScroll (-1)))

    it "keeps the review overlay's extra bindings to the review overlay" $ do
      -- Ctrl-J/Ctrl-K scrolling, numbered choices, and Ctrl-X as a second
      -- interrupt are review's alone, exactly as before.
      (solveCaps, pullRequestCaps) `shouldBe` (SessionInputCaps False False False, SessionInputCaps False False False)
      reviewCaps `shouldBe` SessionInputCaps True True True
      sessionInputEvent reviewCaps (Vty.EvKey (Vty.KChar 'j') [Vty.MCtrl]) `shouldBe` Just (SessionInputScroll 1)
      sessionInputEvent reviewCaps (Vty.EvKey (Vty.KChar 'k') [Vty.MCtrl]) `shouldBe` Just (SessionInputScroll (-1))
      sessionInputEvent solveCaps (Vty.EvKey (Vty.KChar 'j') [Vty.MCtrl]) `shouldBe` Nothing
      sessionInputEvent pullRequestCaps (Vty.EvKey (Vty.KChar 'k') [Vty.MCtrl]) `shouldBe` Nothing
      sessionInputEvent reviewCaps (Vty.EvKey (Vty.KChar 'x') [Vty.MCtrl]) `shouldBe` Just SessionInputInterrupt
      sessionInputEvent solveCaps (Vty.EvKey (Vty.KChar 'x') [Vty.MCtrl]) `shouldBe` Nothing

    it "routes a digit to the pending choice only where choices exist, and types it elsewhere" $ do
      sessionInputEvent reviewCaps (Vty.EvKey (Vty.KChar '3') []) `shouldBe` Just (SessionInputChoice 2)
      sessionInputEvent solveCaps (Vty.EvKey (Vty.KChar '3') []) `shouldBe` Just (SessionInputInsert '3')
      sessionInputEvent pullRequestCaps (Vty.EvKey (Vty.KChar '3') []) `shouldBe` Just (SessionInputInsert '3')
      -- '0' is not a choice digit even in the review overlay.
      sessionInputEvent reviewCaps (Vty.EvKey (Vty.KChar '0') []) `shouldBe` Just (SessionInputInsert '0')

    it "ignores keys none of the overlays bind" $
      forEveryKind (\caps -> sessionInputEvent caps (Vty.EvKey (Vty.KFun 5) []) == Nothing)

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
    -- 'drawOverlay' the dashboard uses, so both the strip and the footer hint
    -- have to survive the overlay's fixed height rather than be clipped off
    -- the bottom of it.
    let overlayRows state overlay = renderWidgetLines (themeFor testOptions) 100 (drawOverlay state overlay)
        rowMentioningBoth first second rows =
          [row | row <- rows, first `Text.isInfixOf` row, second `Text.isInfixOf` row]

    it "lists every in-memory solve session, and offers Tab, in the solve overlay" $ do
      state <-
        withSolveSession (baseIssue 7 []) SolveRunning
          . withSolveSession (baseIssue 12 []) SolveRunning
          <$> testAppState emptyBoard
      let rows = overlayRows state (SolveOverlay 7)
      rowMentioningBoth "#7" "#12" rows `shouldNotBe` []
      filter (Text.isInfixOf "Tab next session") rows `shouldNotBe` []

    it "lists every in-memory PR session, and offers Tab, in the PR overlay" $ do
      -- issue #51's headline regression: the PR overlay had neither.
      state <-
        withPullRequestSession (basePullRequest 7 [] False []) SolveRunning
          . withPullRequestSession (basePullRequest 12 [] False []) SolveRunning
          <$> testAppState emptyBoard
      let rows = overlayRows state (PullRequestReviewOverlay 7)
      rowMentioningBoth "#7" "#12" rows `shouldNotBe` []
      filter (Text.isInfixOf "Tab next session") rows `shouldNotBe` []

    it "keeps the review overlay's own strip and hint unchanged" $ do
      state <-
        withReviewSession (baseIssue 7 []) ReviewRunning
          . withReviewSession (baseIssue 12 []) ReviewRunning
          <$> testAppState emptyBoard
      let rows = overlayRows state (ReviewOverlay 7)
      rowMentioningBoth "#7" "#12" rows `shouldNotBe` []
      filter (Text.isInfixOf "Tab next session") rows `shouldNotBe` []

    it "still draws every overlay's footer, so the added strip clipped nothing off" $ do
      -- A solve session waiting for input is the tallest layout: phase line,
      -- activity, reviewer, log path, transcript, prompt, and footer.
      state <-
        withSolveSession (baseIssue 7 []) SolveAttention
          <$> testAppState emptyBoard
      let rows = overlayRows state (SolveOverlay 7)
      filter (Text.isInfixOf "arrows/wheel scroll") rows `shouldNotBe` []
