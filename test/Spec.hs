-- | The Haskell test suite's entry point. Every group lives in a per-subsystem
-- module under @test/Spec@; this module composes them in the order their
-- @describe@ blocks have always run in, which is the order they appear below.
module Main (main) where

import qualified Spec.Agent.Capture as Capture
import qualified Spec.Agent.IssueReviewer as IssueReviewer
import qualified Spec.Agent.ManagedProcess as ManagedProcess
import qualified Spec.Agent.Ping as Ping
import qualified Spec.Agent.Preflight as Preflight
import qualified Spec.Agent.Protocol as Protocol
import qualified Spec.Agent.PullRequestFlow as PullRequestFlow
import qualified Spec.Agent.Solve as Solve
import qualified Spec.Agent.Supervision as Supervision
import qualified Spec.Agent.Transcript as Transcript
import qualified Spec.Agent.Usage as Usage
import qualified Spec.Agent.UsageMode as UsageMode
import qualified Spec.Board.Tracker as Tracker
import qualified Spec.Board.Workflow as Workflow
import qualified Spec.Config.Consumers as ConfigConsumers
import qualified Spec.Config.Loading as ConfigLoading
import qualified Spec.Config.Settings as Settings
import qualified Spec.Drainer as Drainer
import qualified Spec.GitHub.BoardRefresh as BoardRefresh
import qualified Spec.GitHub.Decoding as GitHubDecoding
import qualified Spec.GitHub.History as GitHubHistory
import qualified Spec.GitHub.PullRequestStatus as PullRequestStatus
import qualified Spec.GitHub.RefreshCoordinator as RefreshCoordinator
import qualified Spec.Repository.Identity as RepositoryIdentity
import qualified Spec.Repository.State as RepositoryState
import qualified Spec.UI.AutoSolve as AutoSolve
import qualified Spec.UI.Cards as Cards
import qualified Spec.UI.CompletedHistory as CompletedHistory
import qualified Spec.UI.Filter as Filter
import qualified Spec.UI.Golden as Golden
import qualified Spec.UI.Incidents as Incidents
import qualified Spec.UI.Keys as Keys
import qualified Spec.UI.Layout as Layout
import qualified Spec.UI.OpenData as OpenData
import qualified Spec.UI.ReviewSession as ReviewSession
import qualified Spec.UI.Search as Search
import qualified Spec.UI.SessionCore as SessionCore
import qualified Spec.UI.SolveChooser as SolveChooser
import qualified Spec.UI.Text as UIText
import Spec.Support.Locale (localeProbeVariable, runLocaleProbe)
import System.Environment (lookupEnv)
import Test.Hspec (Spec, hspec)

-- | Ordinarily the suite. When 'localeProbeVariable' is set this process is
-- the C-locale child a single test re-ran the binary as, and it runs that
-- probe instead — see "Spec.Support.Locale" for why the condition cannot be
-- established from inside an already-started test process.
main :: IO ()
main = lookupEnv localeProbeVariable >>= maybe (hspec suite) runLocaleProbe

-- | Every group, in its established order.
suite :: Spec
suite = do
  ManagedProcess.spec
  Supervision.spec
  Protocol.spec
  Solve.spec
  Settings.spec
  Transcript.spec
  PullRequestFlow.spec
  ReviewSession.spec
  SessionCore.spec
  RepositoryIdentity.spec
  UIText.spec
  Workflow.spec
  Tracker.spec
  GitHubDecoding.spec
  BoardRefresh.spec
  RefreshCoordinator.spec
  GitHubHistory.spec
  Capture.spec
  SolveChooser.spec
  Usage.spec
  UsageMode.spec
  IssueReviewer.spec
  Drainer.spec
  RepositoryState.spec
  PullRequestStatus.spec
  ConfigConsumers.spec
  Cards.spec
  AutoSolve.spec
  ConfigLoading.spec
  Layout.spec
  OpenData.spec
  CompletedHistory.spec
  Filter.spec
  Golden.spec
  Incidents.spec
  Keys.spec
  Search.spec
  Ping.spec
  Preflight.spec
