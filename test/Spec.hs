-- | The Haskell test suite's entry point. Every example lives in a per-subsystem
-- module under @test\/Spec@; this composes their groups in the order they run.
module Main (main) where

import qualified Spec.Agent.ManagedProcess as ManagedProcess
import qualified Spec.Agent.Preflight as Preflight
import qualified Spec.Agent.Protocol as Protocol
import qualified Spec.Agent.ProviderUsage as ProviderUsage
import qualified Spec.Agent.PullRequestFlow as PullRequestFlow
import qualified Spec.Agent.ReviewProcess as ReviewProcess
import qualified Spec.Agent.ReviewReconciliation as ReviewReconciliation
import qualified Spec.Agent.Solve as Solve
import qualified Spec.Agent.SolveSessionReuse as SolveSessionReuse
import qualified Spec.Agent.Transcript as Transcript
import qualified Spec.Agent.WorkerDeadline as WorkerDeadline
import qualified Spec.Data.BoardRefresh as BoardRefresh
import qualified Spec.Data.Cache as Cache
import qualified Spec.Data.Config as Config
import qualified Spec.Data.GitHub as GitHub
import qualified Spec.Data.Repository as Repository
import qualified Spec.Data.Settings as Settings
import qualified Spec.Domain.Tracker as Tracker
import qualified Spec.Domain.Workflow as Workflow
import qualified Spec.Drainer as Drainer
import qualified Spec.Presentation.Cards as Cards
import qualified Spec.Presentation.Layout as Layout
import qualified Spec.Presentation.OverlayDispatch as OverlayDispatch
import qualified Spec.Presentation.ReviewOverlay as ReviewOverlay
import qualified Spec.Presentation.Text as Text
import qualified Spec.Presentation.TranscriptFollow as TranscriptFollow
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
  ManagedProcess.spec
  ReviewProcess.spec
  WorkerDeadline.spec
  Protocol.spec
  Solve.spec
  Settings.spec
  Transcript.spec
  PullRequestFlow.spec
  ReviewOverlay.spec
  ReviewReconciliation.spec
  OverlayDispatch.spec
  TranscriptFollow.spec
  Repository.spec
  Text.spec
  Workflow.spec
  Tracker.spec
  GitHub.spec
  BoardRefresh.spec
  SolveSessionReuse.spec
  ProviderUsage.spec
  Drainer.spec
  Cache.spec
  Cards.spec
  Config.spec
  Layout.spec
  Preflight.spec
