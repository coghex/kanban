-- | The single @managed agent processes@ group, composed from its two ordered
-- halves so that neither module approaches the size this split exists to
-- avoid. The group, its ordering and its example names are unchanged; the
-- deadline half now sits in a nested @deadline watchdog@ group so it can be
-- selected on its own. Nothing else in the tree exposed a module boundary,
-- and these examples are the ones a load-sensitivity check has to be able to
-- run repeatedly by themselves:
--
-- > cabal run kanban-test -- --match "/managed agent processes/deadline watchdog/"
module Spec.Agent.ManagedProcess (spec) where

import qualified Spec.Agent.ManagedProcess.Deadline as Deadline
import qualified Spec.Agent.ManagedProcess.Lifecycle as Lifecycle
import Test.Hspec (Spec, describe)

spec :: Spec
spec = describe "managed agent processes" $ do
  Lifecycle.examples
  describe "deadline watchdog" Deadline.examples
