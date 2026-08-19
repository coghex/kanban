-- | The single @managed agent processes@ group, in its two ordered halves so
-- that neither module approaches the size this split exists to avoid. The
-- group, its ordering and its example names are unchanged; the deadline half
-- sits in a nested @deadline watchdog@ group so it can be selected on its own.
-- Nothing else in the tree exposed a module boundary, and these examples are
-- the ones a load-sensitivity check has to be able to run repeatedly by
-- themselves:
--
-- > cabal run kanban-test -- --match "/managed agent processes/deadline watchdog/"
--
-- The halves are handed out separately rather than composed here because they
-- are the suite's two most expensive groups and run in lanes of their own —
-- see "Spec.Support.Lanes". Composing them back together would still produce
-- exactly the tree above.
module Spec.Agent.ManagedProcess (lifecycleSpec, deadlineSpec) where

import qualified Spec.Agent.ManagedProcess.Deadline as Deadline
import qualified Spec.Agent.ManagedProcess.Lifecycle as Lifecycle
import Test.Hspec (Spec, describe)

lifecycleSpec :: Spec
lifecycleSpec = describe "managed agent processes" Lifecycle.examples

deadlineSpec :: Spec
deadlineSpec = describe "managed agent processes" (describe "deadline watchdog" Deadline.examples)
