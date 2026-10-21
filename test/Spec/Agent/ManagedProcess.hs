-- | The @managed agent processes@ group: signal delivery to a managed process
-- and its group, the process census and verified group kill behind it, and the
-- unknown-event aggregator's seal.
--
-- Handed out through 'lifecycleSpec' so the group keeps the lane
-- "Spec.Support.Lanes" assigns it; the examples are those that exercise only
-- "Kanban.Process" and "Kanban.Solve"'s aggregator.
module Spec.Agent.ManagedProcess (lifecycleSpec) where

import qualified Spec.Agent.ManagedProcess.Lifecycle as Lifecycle
import Test.Hspec (Spec, describe)

lifecycleSpec :: Spec
lifecycleSpec = describe "managed agent processes" Lifecycle.examples
