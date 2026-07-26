-- | The single @managed agent processes@ group, composed from its two ordered
-- halves so that neither module approaches the size this split exists to
-- avoid. The group, its nesting, its example names and their order are
-- unchanged.
module Spec.Agent.ManagedProcess (spec) where

import qualified Spec.Agent.ManagedProcess.Deadline as Deadline
import qualified Spec.Agent.ManagedProcess.Lifecycle as Lifecycle
import Test.Hspec (Spec, describe)

spec :: Spec
spec = describe "managed agent processes" $ do
  Lifecycle.examples
  Deadline.examples
