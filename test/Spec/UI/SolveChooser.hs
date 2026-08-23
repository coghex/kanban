-- | Reusing an attached solve session the chooser is still offering.
module Spec.UI.SolveChooser (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Text
import Data.Maybe (isJust)
import Kanban.Solve (ResumeProvenance (..), SolveWorkflow (..), SolverBrand (..))
import Kanban.UI.Session (reusableSolveSession)
import Kanban.UI.SessionCore (newAgentSession)
import Kanban.UI.Solve (SolveStartDecision (..), solveStartDecision)
import Kanban.UI.Types (AgentSession (..), AppState (..), ChatTranscript (..), SolveDetail (..), SolvePhase (..), SolveSession)
import Spec.Support.App (testAppState)
import Spec.Support.Fixtures (baseIssue, epoch, fixtureBoard)
import Spec.Support.Roster (claudeOnlyRoster)
import Test.Hspec

spec :: Spec
spec = do
  describe "solve launch against a session attached while the chooser sits open" $ do
    -- 'startIssueSolve' and 'openIssueSolveChooser' both run in brick's
    -- 'EventM', which no unit test here can drive; this covers
    -- 'reusableSolveSession', the single predicate they now share. A 'Just'
    -- answer is precisely what routes a chooser digit into
    -- 'openExistingSolveOverlay' -- select 'SolveOverlay', present the
    -- transcript, return -- instead of the 'Map.insert' plus
    -- 'launchSolveInvocation' that would replace the session.
    let sessionFor :: SolveWorkflow -> SolvePhase -> SolveSession
        sessionFor workflow phase =
          ( newAgentSession
              0
              phase
              "reattaching persistent worker"
              (Just epoch)
              (ChatTranscript "recovered" "" "")
              SolveDetail
                { solveSessionIssue = baseIssue 40 [],
                  solveSessionWorkflow = workflow,
                  solveSessionBrand = CodexSolver,
                  solveSessionId = Just "recovered-worker-session",
                  solveSessionAutoProgress = Nothing,
                  solveSessionResumeProvenance = ResumeAnswer,
                  solveSessionAssignment = Nothing
                }
          )
            {sessionLogPath = Just "/tmp/recovered.jsonl"}
        sessionsWith session = Map.fromList [(40, session)]

    it "reuses a session that persistent-worker discovery attached after the chooser opened" $ do
      -- The chooser opened because nothing was attached yet...
      reusableSolveSession AutoSolve 40 Map.empty `shouldBe` Nothing
      -- ...then 'ensureWorkerSession' inserted the recovered session, and the
      -- digit that follows must return that very object, untouched: its
      -- transcript, log path, and worker session id are what the live worker's
      -- events still target.
      let recovered = sessionFor SolveOnly SolveStarting
      reusableSolveSession AutoSolve 40 (sessionsWith recovered) `shouldBe` Just recovered
      reusableSolveSession SolveOnly 40 (sessionsWith recovered) `shouldBe` Just recovered

    it "reuses any still-running session, whichever workflow was requested" $
      mapM_
        (\phase -> reusableSolveSession AutoSolve 40 (sessionsWith (sessionFor SolveOnly phase)) `shouldSatisfy` isJust)
        [SolveStarting, SolveRunning, SolveAttention, SolveOrphanedPhase]

    -- The other half of the same digit's decision, and the reason the model
    -- roster is consulted before any session exists: a refusal that let
    -- 'startFreshIssueSolve' insert a session first would be reopened by the
    -- predicate above on the next press, so the operator could never pick the
    -- brand the roster does load.
    it "refuses a solver the roster cannot supply, and still offers the one it can" $ do
      state <- testAppState (fixtureBoard [])
      let issue = baseIssue 40 []
          rostered = state {appModelRoster = Right claudeOnlyRoster}
          decisionFor brand = solveStartDecision rostered issue SolveOnly brand
      case decisionFor CodexSolver of
        SolveStartRefused notice -> notice `shouldSatisfy` Data.Text.isInfixOf "codex"
        other -> expectationFailure ("expected a refusal for the unloaded provider, got " <> show other)
      -- No session was created by that refusal, so the very next press is a
      -- fresh choice rather than a reopened one.
      reusableSolveSession SolveOnly 40 rostered.appSolveSessions `shouldBe` Nothing
      decisionFor ClaudeSolver `shouldBe` SolveStartFresh

    it "still replaces a finished session belonging to a different workflow" $ do
      reusableSolveSession AutoSolve 40 (sessionsWith (sessionFor SolveOnly SolveFinished)) `shouldBe` Nothing
      reusableSolveSession AutoSolve 40 (sessionsWith (sessionFor AutoSolve SolveFinished))
        `shouldBe` Just (sessionFor AutoSolve SolveFinished)
