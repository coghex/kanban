-- The subject here is exactly the bindings this pragma silences: the five
-- values @v1.0.0.0@ exposed from "Kanban.Solve", retained as deprecated
-- compatibility shims (issue #482, requirement 10). Held in a module of their
-- own so the warning stays live everywhere else -- an accidental use in the
-- roster spec beside this one, where the surfaces that must /not/ read them
-- are proved, still fails the build.
{-# OPTIONS_GHC -Wno-deprecations #-}

-- | The released 'Kanban.Solve' API values MODEL-3 could not remove.
--
-- Two things are proved. They are still there and still answer what they
-- always answered, so an external caller compiled against @v1.0.0.0@ is
-- unaffected. And they are derived from 'Kanban.Models.defaultRoster' rather
-- than from literals of their own, which is what keeps the acceptance sweep
-- over @src\/@ meaningful: a shim that restated its value would satisfy the
-- release contract while quietly reintroducing the duplicate.
--
-- What they are /not/ is proved next door: every surface in
-- "Spec.Agent.Roster" moves with the operator's roster, while these do not.
module Spec.Agent.Compatibility (spec) where

import qualified Data.Text
import Kanban.Models
  ( Assignment (..),
    ProviderName (..),
    RoleName (..),
    assignmentFor,
    defaultRoster,
  )
import Kanban.Solve
  ( SolverBrand (..),
    claudeReviewerModel,
    claudeSolverModel,
    codexReviewerModel,
    codexSolverModel,
    solverLabel,
  )
import Kanban.UI.Overlay (solveChooserDisplay)
import Spec.Support.Roster (cellOf, distinctDisplays)
import Test.Hspec

spec :: Spec
spec =
  describe "the released Kanban.Solve compatibility values" $ do
    it "still answer the compiled defaults, read out of the roster rather than restated" $ do
      [codexSolverModel, claudeSolverModel, codexReviewerModel, claudeReviewerModel]
        `shouldBe` [ displayOf SolveRole CodexProvider,
                     displayOf SolveRole ClaudeProvider,
                     displayOf PrReviewRole CodexProvider,
                     displayOf PrReviewRole ClaudeProvider
                   ]
      map solverLabel [CodexSolver, ClaudeSolver]
        `shouldBe` ["codex · gpt-5.4 high", "claude · Sonnet 5 high"]

    -- The whole point of retaining them as shims: a surface answers from the
    -- roster in force, and these answer from the compiled default, so on any
    -- roster that moved a display the two must disagree.
    it "are not what a surface reads: a moved roster moves the surface and not the shim" $
      solveChooserDisplay (Right distinctDisplays) CodexSolver `shouldNotBe` codexSolverModel

displayOf :: RoleName -> ProviderName -> Data.Text.Text
displayOf role provider = (cellOf (assignmentFor defaultRoster role provider)).assignmentDisplay
