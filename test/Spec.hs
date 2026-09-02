-- | The Haskell test suite's entry point. Every group lives in a per-subsystem
-- module under @test/Spec@; this module composes them and says, for each one,
-- which /lane/ it runs in.
--
-- A lane is a suite process of its own — see "Spec.Support.Lanes" for what
-- that buys and what it costs. What matters here is that the lane is a
-- property of the group rather than of the runner: a group cannot be added
-- without deciding what it may overlap with, and the groups inside one lane
-- still run one at a time, in the order they appear below, which is the order
-- their @describe@ blocks have always run in.
--
-- Not every one of those decisions is free: 'suiteColocations' names the
-- groups held to another group's lane, and why. One group here is unlike the
-- rest for that reason. "Spec.Suite.Assignment" is handed the roster and those
-- declarations rather than composed blind into them, so the assignment this
-- module states is checked by the suite it composes.
module Main (main) where

import qualified Spec.Action.AutoSolve as ActionAutoSolve
import qualified Spec.Action.Registry as ActionRegistry
import qualified Spec.Agent.Adapter as Adapter
import qualified Spec.Agent.Capture as Capture
import qualified Spec.Agent.Compatibility as Compatibility
import qualified Spec.ApprovalService as ApprovalService
import qualified Spec.Agent.IssueReviewer as IssueReviewer
import qualified Spec.Agent.ManagedProcess as ManagedProcess
import qualified Spec.Agent.Ping as Ping
import qualified Spec.Agent.Preflight as Preflight
import qualified Spec.Agent.ClaudeReview as ClaudeReview
import qualified Spec.Agent.Protocol as Protocol
import qualified Spec.Agent.PullRequestFlow as PullRequestFlow
import qualified Spec.Agent.Roster as AgentRoster
import qualified Spec.Agent.Solve as Solve
import qualified Spec.Agent.Supervision as Supervision
import qualified Spec.Agent.ToolReentry as ToolReentry
import qualified Spec.Agent.Transcript as Transcript
import qualified Spec.Agent.Usage as Usage
import qualified Spec.Agent.UsageMode as UsageMode
import qualified Spec.Board.Tracker as Tracker
import qualified Spec.Board.Workflow as Workflow
import qualified Spec.Config.Consumers as ConfigConsumers
import qualified Spec.Config.Loading as ConfigLoading
import qualified Spec.Config.Models as Models
import qualified Spec.Config.Settings as Settings
import qualified Spec.Design.Witnesses as DesignWitnesses
import qualified Spec.Drainer as Drainer
import qualified Spec.GitHub.BoardRefresh as BoardRefresh
import qualified Spec.GitHub.Decoding as GitHubDecoding
import qualified Spec.GitHub.History as GitHubHistory
import qualified Spec.GitHub.PullRequestStatus as PullRequestStatus
import qualified Spec.GitHub.RefreshCoordinator as RefreshCoordinator
import qualified Spec.ManagedPaths as ManagedPaths
import qualified Spec.Mission as Mission
import qualified Spec.OperatingMode as OperatingMode
import qualified Spec.Repository.Authority as RepositoryAuthority
import qualified Spec.Repository.Identity as RepositoryIdentity
import qualified Spec.Repository.Lease as RepositoryLease
import qualified Spec.Repository.State as RepositoryState
import Spec.Support.Lanes
  ( Colocation (..),
    Lane (..),
    SuiteGroup (..),
    runSuiteInLanes,
  )
import Spec.Support.LeaseProbes (leaseProbeVariable, runLeaseProbe)
import Spec.Support.MissionProbes (missionProbeVariable, runMissionProbe)
import Spec.Support.Locale (localeProbeVariable, runLocaleProbe)
import Spec.Support.UsageWriters (runUsageWriter, usageWriterVariable)
import qualified Spec.Suite.Assignment as Assignment
import qualified Spec.UI.AutoSolve as AutoSolve
import qualified Spec.UI.Cards as Cards
import qualified Spec.UI.CompletedHistory as CompletedHistory
import qualified Spec.UI.Filter as Filter
import qualified Spec.UI.FilterPanel as FilterPanel
import qualified Spec.UI.Notice as Notice
import qualified Spec.UI.Fullscreen as Fullscreen
import qualified Spec.UI.Golden as Golden
import qualified Spec.UI.Incidents as Incidents
import qualified Spec.UI.Keys as Keys
import qualified Spec.UI.Layout as Layout
import qualified Spec.UI.OpenData as OpenData
import qualified Spec.UI.ReviewSession as ReviewSession
import qualified Spec.UI.Search as Search
import qualified Spec.UI.SessionCore as SessionCore
import qualified Spec.UI.Settings as UISettings
import qualified Spec.UI.SolveChooser as SolveChooser
import qualified Spec.UI.Text as UIText
import qualified Spec.UI.Usage as UIUsage
import Kanban.ReviewToolServer (serveReviewTools)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitWith)
import System.IO (stdin, stdout)

-- | Ordinarily the suite. Four markers divert it instead, and each names a
-- condition that cannot be established from inside an already-started test
-- process: 'localeProbeVariable' makes this the C-locale child a single test
-- re-ran the binary as (see "Spec.Support.Locale" for why the locale is fixed
-- before @main@ runs), 'usageWriterVariable' makes it one of the independent
-- processes contending over the usage cache (see "Spec.Support.UsageWriters"
-- for why a thread would not do), 'leaseProbeVariable' makes it one of the
-- independent processes contending for a repository's lease (see
-- "Spec.Support.LeaseProbes" for why a thread would not merely be weaker but
-- would prove the opposite), and 'missionProbeVariable' makes it one of the
-- independent processes acting on a mission store (see
-- "Spec.Support.MissionProbes" for the two things a thread cannot stage there:
-- a reader sharing nothing with the writer, and a lease holder there is
-- something to kill).
--
-- All four are asked about before the suite and deliberately so: a lane
-- carries its own marker in the environment its children inherit, and a child
-- started from inside a lane must run its probe rather than that lane a second
-- time. No marker reaches a child of a probe, so this cannot recurse.
main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    -- The re-entered review tool server, exactly as @kanban --review-tools@
    -- serves it. A fifth diversion, and the one that is argv rather than
    -- environment because that is how the mechanism under test hands it
    -- over: "Spec.Agent.ToolReentry"'s fake @claude@ spawns whatever
    -- executable its recorded @--mcp-config@ names, that executable is this
    -- suite's own binary ('System.Environment.getExecutablePath', the same
    -- re-entry a real install performs), and so the served process runs the
    -- real 'serveReviewTools' rather than a fixture restating it. Checked
    -- ahead of the probe markers: the spawned server inherits whatever
    -- environment the suite's own machinery is carrying.
    ["--review-tools", endpointDirectory] -> exitWith =<< serveReviewTools stdin stdout endpointDirectory
    _ -> do
      localeProbe <- lookupEnv localeProbeVariable
      usageWriter <- lookupEnv usageWriterVariable
      leaseProbe <- lookupEnv leaseProbeVariable
      missionProbe <- lookupEnv missionProbeVariable
      case (localeProbe, usageWriter, leaseProbe, missionProbe) of
        (Just probeRoot, _, _, _) -> runLocaleProbe probeRoot
        (Nothing, Just planPath, _, _) -> runUsageWriter planPath
        (Nothing, Nothing, Just planPath, _) -> runLeaseProbe planPath
        (Nothing, Nothing, Nothing, Just planPath) -> runMissionProbe planPath
        (Nothing, Nothing, Nothing, Nothing) -> runSuiteInLanes suiteGroups suiteColocations

-- | Every group, its lane, and its established order.
--
-- The lane column is a packing decision taken from measurement, except where
-- 'suiteColocations' below holds a group to another group's lane for safety.
-- Serially the suite spends 397 of its 399 seconds inside fifteen groups that
-- are waiting on a real deadline, so those fifteen are spread across the five
-- lanes until no lane holds much more than a fifth of them, and the eleven
-- hundred examples whose cost is computing — under two seconds between them —
-- ride along wherever there is room. The seconds beside each group below are
-- what it cost on its own, from
--
-- > cabal run kanban-test -- --print-slow-items=2000
--
-- which is how to check the packing again after a group's cost moves. Those
-- measurements predate "Spec.Repository.Lease", whose 1.7 seconds are small
-- enough to ride along anywhere on cost alone; it sits in @UsageLane@ for the
-- reason 'suiteColocations' states rather than for its cost.
suiteGroups :: [SuiteGroup]
suiteGroups =
  [ SuiteGroup "Spec.Agent.ManagedProcess.Lifecycle" LifecycleLane ManagedProcess.lifecycleSpec, -- 53.8s
    SuiteGroup "Spec.Agent.ManagedProcess.Deadline" DeadlineLane ManagedProcess.deadlineSpec, -- 63.1s
    SuiteGroup "Spec.Agent.Supervision" SupervisionLane Supervision.spec, -- 72.6s
    SuiteGroup "Spec.Agent.Protocol" LifecycleLane Protocol.spec, -- 8.5s
    -- Beside "Spec.Agent.Supervision" rather than spread for cost: it
    -- spawns a fake provider per example and sleeps inside several of them,
    -- and that lane holds the subprocess-deadline assertions its churn would
    -- be measured against. Groups in one lane are serialised, so the two
    -- cannot overlap at all — the same reasoning 'suiteColocations' records
    -- for the pair it names, at a cost of about 22 of this lane's seconds.
    SuiteGroup "Spec.Agent.ClaudeReview" SupervisionLane ClaudeReview.spec, -- 21.9s
    SuiteGroup "Spec.Agent.ToolReentry" LifecycleLane ToolReentry.spec,
    SuiteGroup "Spec.Agent.Solve" LifecycleLane Solve.spec, -- 2.8s
    SuiteGroup "Spec.Agent.Adapter" LifecycleLane Adapter.spec,
    SuiteGroup "Spec.Config.Settings" PingLane Settings.spec,
    SuiteGroup "Spec.Config.Models" PingLane Models.spec,
    SuiteGroup "Spec.Agent.Transcript" PingLane Transcript.spec,
    SuiteGroup "Spec.Agent.PullRequestFlow" PingLane PullRequestFlow.spec, -- 1.9s
    SuiteGroup "Spec.Agent.Roster" LifecycleLane AgentRoster.spec,
    SuiteGroup "Spec.Agent.Compatibility" PingLane Compatibility.spec,
    SuiteGroup "Spec.UI.ReviewSession" PingLane ReviewSession.spec,
    SuiteGroup "Spec.UI.SessionCore" PingLane SessionCore.spec,
    SuiteGroup "Spec.Repository.Identity" PingLane RepositoryIdentity.spec,
    SuiteGroup "Spec.Repository.Authority" PingLane RepositoryAuthority.spec,
    SuiteGroup "Spec.UI.Text" PingLane UIText.spec,
    SuiteGroup "Spec.Board.Workflow" PingLane Workflow.spec,
    SuiteGroup "Spec.Board.Tracker" PingLane Tracker.spec,
    SuiteGroup "Spec.GitHub.Decoding" PingLane GitHubDecoding.spec,
    SuiteGroup "Spec.GitHub.BoardRefresh" UsageLane BoardRefresh.spec, -- 38.7s
    SuiteGroup "Spec.GitHub.RefreshCoordinator" PingLane RefreshCoordinator.spec, -- 8.6s
    SuiteGroup "Spec.GitHub.History" DeadlineLane GitHubHistory.spec, -- 7.9s
    SuiteGroup "Spec.Agent.Capture" LifecycleLane Capture.spec, -- 10.5s
    SuiteGroup "Spec.UI.SolveChooser" PingLane SolveChooser.spec,
    SuiteGroup "Spec.Agent.Usage" UsageLane Usage.spec, -- 45.7s
    SuiteGroup "Spec.Repository.Lease" UsageLane RepositoryLease.spec, -- 1.7s
    -- Beside the other group that starts suite processes of its own, and for
    -- the same reason 'suiteColocations' records for the pair it names: the
    -- assertions in @UsageLane@ about a swept process being gone are measured
    -- against this lane's churn, and groups in one lane are serialised so
    -- neither can overlap the other. Its own cost is small enough to ride
    -- along anywhere.
    SuiteGroup "Spec.Mission" UsageLane Mission.spec,
    SuiteGroup "Spec.Agent.UsageMode" PingLane UsageMode.spec, -- 3.6s
    SuiteGroup "Spec.Agent.IssueReviewer" PingLane IssueReviewer.spec,
    SuiteGroup "Spec.Drainer" PingLane Drainer.spec, -- 17.6s
    SuiteGroup "Spec.ManagedPaths" PingLane ManagedPaths.spec,
    SuiteGroup "Spec.OperatingMode" PingLane OperatingMode.spec,
    SuiteGroup "Spec.ApprovalService" DeadlineLane ApprovalService.spec, -- 8.9s
    SuiteGroup "Spec.Repository.State" PingLane RepositoryState.spec,
    SuiteGroup "Spec.GitHub.PullRequestStatus" PingLane PullRequestStatus.spec,
    SuiteGroup "Spec.Config.Consumers" PingLane ConfigConsumers.spec,
    SuiteGroup "Spec.UI.Cards" PingLane Cards.spec,
    SuiteGroup "Spec.UI.AutoSolve" PingLane AutoSolve.spec,
    -- Beside the preflight group rather than spread for cost: its dispatch
    -- examples install fake providers on a temporary PATH and let a launch
    -- write its specification, which is the same machinery that lane already
    -- serialises.
    SuiteGroup "Spec.Action.Registry" SupervisionLane ActionRegistry.spec,
    SuiteGroup "Spec.Action.AutoSolve" PingLane ActionAutoSolve.spec,
    SuiteGroup "Spec.Config.Loading" PingLane ConfigLoading.spec,
    SuiteGroup "Spec.UI.Layout" PingLane Layout.spec,
    SuiteGroup "Spec.UI.OpenData" PingLane OpenData.spec,
    SuiteGroup "Spec.UI.CompletedHistory" PingLane CompletedHistory.spec,
    SuiteGroup "Spec.UI.Filter" PingLane Filter.spec,
    SuiteGroup "Spec.UI.FilterPanel" PingLane FilterPanel.spec,
    SuiteGroup "Spec.UI.Fullscreen" PingLane Fullscreen.spec,
    SuiteGroup "Spec.UI.Notice" PingLane Notice.spec,
    SuiteGroup "Spec.UI.Golden" PingLane Golden.spec,
    SuiteGroup "Spec.UI.Incidents" PingLane Incidents.spec,
    SuiteGroup "Spec.UI.Usage" PingLane UIUsage.spec,
    SuiteGroup "Spec.UI.Keys" PingLane Keys.spec,
    SuiteGroup "Spec.UI.Settings" PingLane UISettings.spec,
    SuiteGroup "Spec.Design.Witnesses" UsageLane DesignWitnesses.spec,
    SuiteGroup "Spec.UI.Search" PingLane Search.spec,
    SuiteGroup "Spec.Agent.Ping" PingLane Ping.spec, -- 46.1s
    SuiteGroup "Spec.Agent.Preflight" SupervisionLane Preflight.spec, -- 5.8s
    SuiteGroup "Spec.Suite.Assignment" PingLane (Assignment.spec suiteGroups suiteColocations)
  ]

-- | The pairs of groups above that this assignment is not free to separate.
--
-- Each entry is the only statement of its pair anywhere: the lane comment
-- above and "Spec.Support.Lanes" both point here rather than repeat it, and
-- @Spec.Support.Lanes.checkAssignment@ refuses to start the suite if an
-- assignment separates a pair or stops resolving one of its names. Adding a
-- group is still a cost decision; moving a group named here is not, and that
-- is enforced now rather than remembered.
--
-- The reason below is printed verbatim by that refusal, so it carries the
-- measurement rather than a pointer to it.
suiteColocations :: [Colocation]
suiteColocations =
  [ Colocation
      { colocationFirst = "Spec.Agent.Usage",
        colocationSecond = "Spec.Repository.Lease",
        colocationReason =
          "Spec.Repository.Lease starts suite processes of its own, and Spec.Agent.Usage \
          \asserts that a process it swept is gone by the time a call returned. Run in \
          \different lanes the two overlap, and doing so raised the rate at which those \
          \sweeps were observed late from roughly one full run in six to four in seven. \
          \In one lane they are serialised and cannot overlap at all. Separating them \
          \again needs that measurement repeated, not a cheaper packing."
      }
  ]
