-- | What the suite refuses to start with, and that the suite's own assignment
-- is not one of those things.
--
-- Every other group here tests Kanban. This one tests the harness that runs
-- them, and it is the only group handed the roster rather than composed into
-- it: 'spec' takes @Main@'s @suiteGroups@ and @suiteColocations@ as arguments
-- because a check that read a copy of them would pass while the real
-- assignment was wrong, which is the failure it exists to catch. Nothing here
-- mutates either — every assignment an example refuses is built from scratch
-- below, so no real group moves even transiently.
--
-- The refusals are worth a test each because none of them can fail visibly on
-- its own: a suite that never starts reports nothing, so the only evidence
-- that a refusal still works is an assignment deliberately built to earn it.
module Spec.Suite.Assignment (spec) where

import Data.List (isInfixOf)
import Data.Maybe (fromMaybe)
import Spec.Support.Lanes
  ( Colocation (..),
    Lane (..),
    SuiteGroup (..),
    allLanes,
    assignmentDiagnostic,
    countExamples,
    laneName,
  )
import Test.Hspec

spec :: [SuiteGroup] -> [Colocation] -> Spec
spec groups colocations = describe "the suite's lane assignment" $ do
  describe "the assignment this suite actually runs" $ do
    it "is accepted" $
      assignmentDiagnostic groups colocations `shouldBe` Nothing

    it "declares the one measured pair, and holds both of its groups in one lane" $ do
      map (\held -> (colocationFirst held, colocationSecond held)) colocations
        `shouldBe` [("Spec.Agent.Usage", "Spec.Repository.Lease")]
      [ suiteGroupLane group
        | group <- groups,
          suiteGroupName group `elem` ["Spec.Agent.Usage", "Spec.Repository.Lease"]
        ]
        `shouldBe` [UsageLane, UsageLane]

    it "keeps the measurement in the reason a refusal would print" $
      concatMap colocationReason colocations
        `shouldContainAll` ["one full run in six", "four in seven"]

  describe "a co-location the assignment separates" $ do
    it "is refused, naming both groups, both lanes and the reason" $ do
      let printed = diagnosticFor (separated syntheticGroups)
      printed `shouldContainAll` ["\"held-first\"", "\"held-second\"", syntheticReason]
      printed `shouldContainAll` [laneName UsageLane, laneName PingLane]
      printed `shouldSatisfy` isInfixOf "must run in the same lane"

    it "is accepted while the two share a lane, so the refusal is the separation" $
      assignmentDiagnostic syntheticGroups syntheticColocations `shouldBe` Nothing

  describe "a co-location naming a group the assignment does not hold exactly once" $ do
    it "is refused rather than enforcing nothing, naming the endpoint and the reason" $ do
      let printed = diagnosticFor (rename "held-second" "held-second-renamed" syntheticGroups)
      printed `shouldContainAll` ["\"held-first\"", "\"held-second\"", syntheticReason]
      printed `shouldSatisfy` isInfixOf "\"held-second\" is not a group of this suite"

    it "still says which declaration an ambiguous endpoint disarmed, not only what made it ambiguous" $ do
      let printed = diagnosticFor (rename "filler-usage" "held-second" syntheticGroups)
      printed `shouldSatisfy` isInfixOf "suite groups share a name"
      printed `shouldContainAll` ["\"held-first\"", "\"held-second\"", syntheticReason]
      printed `shouldSatisfy` isInfixOf "\"held-second\" names 2 groups of this suite, not one"

  describe "the refusals the co-location check did not replace" $ do
    it "refuses two groups sharing a name" $
      diagnosticFor (rename "filler-ping" "filler-deadline" syntheticGroups)
        `shouldContainAll` ["suite groups share a name", "filler-deadline"]

    it "refuses a lane holding no groups" $
      diagnosticFor (filter ((/= DeadlineLane) . suiteGroupLane) syntheticGroups)
        `shouldSatisfy` isInfixOf ("lane " <> laneName DeadlineLane <> " has no groups")

    it "refuses an example marked parallelizable" $ do
      counted <- countExamples (parallel (it "would run beside another" True))
      case counted of
        Left refusal -> refusal `shouldSatisfy` isInfixOf "marked parallelizable"
        Right count -> expectationFailure ("accepted a parallelizable tree of " <> show count)

    it "counts the examples of a tree it accepts" $ do
      counted <- countExamples (describe "a group" (it "one" True >> it "another" True))
      counted `shouldBe` Right 2

-- | A whole assignment of its own: one filler group per lane so no lane is
-- empty, plus the two groups a synthetic co-location holds together. Every
-- name is distinct and no example is marked parallelizable, so the only
-- refusal an example below can provoke is the one it builds.
syntheticGroups :: [SuiteGroup]
syntheticGroups =
  [SuiteGroup ("filler-" <> laneName lane) lane (pure ()) | lane <- allLanes]
    <> [ SuiteGroup "held-first" UsageLane (pure ()),
         SuiteGroup "held-second" UsageLane (pure ())
       ]

syntheticColocations :: [Colocation]
syntheticColocations =
  [ Colocation
      { colocationFirst = "held-first",
        colocationSecond = "held-second",
        colocationReason = syntheticReason
      }
  ]

-- | Distinctive enough that finding it in a refusal proves the declaration's
-- own reason was carried through, rather than some other wording that happens
-- to read like one.
syntheticReason :: String
syntheticReason = "they were measured interfering when they overlapped"

-- | Moves the second held group into a lane of its own, which is the mistake
-- the co-location check exists to refuse.
separated :: [SuiteGroup] -> [SuiteGroup]
separated = map move
  where
    move group
      | suiteGroupName group == "held-second" = group {suiteGroupLane = PingLane}
      | otherwise = group

rename :: String -> String -> [SuiteGroup] -> [SuiteGroup]
rename from to = map apply
  where
    apply group
      | suiteGroupName group == from = group {suiteGroupName = to}
      | otherwise = group

-- | What the runner would print on being handed this assignment and the
-- synthetic declaration — the whole diagnostic, so an example cannot pass on
-- text a reader of a real refusal would never see.
diagnosticFor :: [SuiteGroup] -> String
diagnosticFor assignment =
  fromMaybe
    "the assignment was accepted"
    (assignmentDiagnostic assignment syntheticColocations)

shouldContainAll :: String -> [String] -> Expectation
shouldContainAll subject fragments =
  filter (not . (`isInfixOf` subject)) fragments `shouldBe` []
