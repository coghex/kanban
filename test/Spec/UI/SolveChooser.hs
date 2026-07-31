-- | Reusing an attached solve session the chooser is still offering.
module Spec.UI.SolveChooser (spec) where

import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Kanban.Solve (ResumeProvenance (..), SolveWorkflow (..), SolverBrand (..))
import Kanban.UI.Session (reusableSolveSession)
import Kanban.UI.SessionCore (newAgentSession)
import Kanban.UI.Types (AgentSession (..), ChatTranscript (..), SolveDetail (..), SolvePhase (..), SolveSession)
import Spec.Support.Fixtures (baseIssue, epoch)
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
                  solveSessionResumeProvenance = ResumeAnswer
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

    it "still replaces a finished session belonging to a different workflow" $ do
      reusableSolveSession AutoSolve 40 (sessionsWith (sessionFor SolveOnly SolveFinished)) `shouldBe` Nothing
      reusableSolveSession AutoSolve 40 (sessionsWith (sessionFor AutoSolve SolveFinished))
        `shouldBe` Just (sessionFor AutoSolve SolveFinished)
