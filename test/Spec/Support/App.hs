-- | A dashboard state the pure UI transitions can be driven against, with
-- no terminal, network, or GitHub account.
--
-- Every field is a quiet default: no sessions, no workers, nothing in
-- flight. A test names only what it is about by updating the record, which
-- keeps each one readable and keeps a new 'AppState' field from rewriting
-- every test that ever built one.
module Spec.Support.App
  ( testAppState,
    withSolveSession,
    withPullRequestSession,
    withReviewSession,
    testSolveSession,
    testPullRequestSession,
    testReviewSession
  )
where

import Brick.BChan (newBChan)
import Data.IORef (newIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (utc)
import Kanban.Domain
import Kanban.ApprovalService
  ( ApprovalActivity (..),
    ApprovalState (..),
    ApprovalStatus (..),
    ApprovalUnavailable (..),
  )
import Kanban.Drainer (DrainerActivity (..), DrainerState (..), DrainerStatus (..))
import Kanban.Filter (defaultFilterCriteria)
import Kanban.GitHub (newHistoryTraversal)
import Kanban.Models (defaultRoster)
import Kanban.PullRequestFlow (PullRequestAction (..), PullRequestOrigin (..))
import Kanban.Review (ReviewStage (..))
import Kanban.Settings (defaultSettings)
import Kanban.Solve (ResumeProvenance (..), SolveWorkflow (..), SolverBrand (..))
import Kanban.UI.SessionCore (newAgentSession)
import Kanban.UI.Types
  ( AgentSession (..),
    AppState (..),
    ChatTranscript (..),
    CompletedHistoryStatus (..),
    IncidentSelection (..),
    ProcessSelection (..),
    PullRequestDetail (..),
    PullRequestReviewSession,
    ReviewBackend (..),
    ReviewDetail (..),
    ReviewPhase (..),
    ReviewSession,
    SolveDetail (..),
    SolvePhase (..),
    SolveSession,
  )
import Spec.Support.Board (inertRefreshCoordinator)
import Spec.Support.Fixtures (epoch, testOptions, testResolvedConfig)

testAppState :: Board -> IO AppState
testAppState board = do
  eventChannel <- newBChan 16
  refreshCoordinator <- inertRefreshCoordinator
  historyTraversal <- newHistoryTraversal
  approvalEpoch <- newIORef 0
  pure
    AppState
      { appRepository = Repository "/tmp/example-project" "example" "project",
        appBoard = board,
        -- The default criteria admit the open board unchanged, which is what
        -- lets a test that only cares about drawing or dispatch name one
        -- board. A test about the criteria themselves builds both sides with
        -- 'Kanban.UI.Filter.refreshVisibleBoard'.
        appVisibleBoard = board,
        appFilterCriteria = defaultFilterCriteria,
        appFilterPanel = Nothing,
        appUsage = Map.empty,
        appUsageFreshness = Map.empty,
        appSelectedColumn = Issues,
        appSelectedRows = Map.fromList [(column, 0) | column <- [minBound .. maxBound]],
        appEnsureSelectionVisible = False,
        appExpandedTrackers = Set.empty,
        appSearch = Nothing,
        appSidebarVisible = True,
        appSettings = defaultSettings,
        -- The pure compiled value, not a load: a test state must not read
        -- the developer's real XDG configuration.
        appModelRoster = Right defaultRoster,
        appLogRoot = "/tmp/example-project/logs",
        appProcessSelection = ProcessSelection Nothing 0,
        appIncidentSelection = IncidentSelection Nothing 0,
        appOverlay = Nothing,
        appNotice = Nothing,
        appBoardFreshness = Fresh epoch,
        appOpenSnapshot = Nothing,
        appLastSuccessfulFetch = Just epoch,
        appOpenGeneration = 0,
        appHistoryTraversal = historyTraversal,
        appCompletedHistory = Nothing,
        appCompletedGeneration = 0,
        appCompletedProgress = emptyCompletedProgress,
        -- Nothing is in flight, so no criteria set is blocked on a traversal:
        -- a test about the completed blocker says so by naming this field.
        appCompletedStatus = CompletedHistoryCurrent,
        appDrainerController = Left "no drainer in tests",
        appDrainerStatus = DrainerStatus DrainerOff "off" DrainerServiceStopped Nothing,
        appDrainerIncidents = Just [],
        appDrainerBusy = False,
        appApprovalController = Left (ApprovalUndiscoverable "no issue approval service in tests"),
        appApprovalStatus = ApprovalStatus ApprovalOff "off" ApprovalServiceStopped Nothing Nothing,
        appApprovalIncidents = Just [],
        appApprovalBusy = False,
        appApprovalTransition = 0,
        appApprovalEpoch = approvalEpoch,
        appApprovalResult = Nothing,
        appDirectMergePending = Nothing,
        appDirectMergeResult = Nothing,
        appBoardRefreshQueued = False,
        appRefreshCoordinator = refreshCoordinator,
        appQuitPending = False,
        appReviewBackend = ReviewBackendStopped,
        appReviewSessions = Map.empty,
        appSolveSessions = Map.empty,
        appSolveProcesses = Map.empty,
        appCanonicalReviewProcesses = Map.empty,
        appPullRequestReviewSessions = Map.empty,
        appPullRequestProcesses = Map.empty,
        appWorkers = Map.empty,
        appWorkerMonitors = Set.empty,
        appEventChannel = eventChannel,
        appNow = epoch,
        appTimeZone = utc,
        appOptions = testOptions,
        appConfig = testResolvedConfig
      }

withSolveSession :: Issue -> SolvePhase -> AppState -> AppState
withSolveSession issue phase state =
  state
    { appSolveSessions =
        Map.insert issue.issueNumber (testSolveSession issue phase) state.appSolveSessions
    }

withPullRequestSession :: PullRequest -> SolvePhase -> AppState -> AppState
withPullRequestSession pullRequest phase state =
  state
    { appPullRequestReviewSessions =
        Map.insert
          pullRequest.pullRequestNumber
          (testPullRequestSession pullRequest phase)
          state.appPullRequestReviewSessions
    }

withReviewSession :: Issue -> ReviewPhase -> AppState -> AppState
withReviewSession issue phase state =
  state
    { appReviewSessions =
        Map.insert issue.issueNumber (testReviewSession issue phase) state.appReviewSessions
    }

testSolveSession :: Issue -> SolvePhase -> SolveSession
testSolveSession issue phase =
  (newAgentSession 0 phase "solve activity" (Just epoch) emptyTranscript detail) {sessionTickGeneration = 0}
  where
    detail =
      SolveDetail
        { solveSessionIssue = issue,
          solveSessionWorkflow = SolveOnly,
          solveSessionBrand = ClaudeSolver,
          solveSessionId = Nothing,
          solveSessionAutoProgress = Nothing,
          solveSessionResumeProvenance = ResumeAnswer,
          solveSessionAssignment = Nothing
        }

testPullRequestSession :: PullRequest -> SolvePhase -> PullRequestReviewSession
testPullRequestSession pullRequest phase =
  (newAgentSession 0 phase "pr activity" (Just epoch) emptyTranscript detail) {sessionTickGeneration = 0}
  where
    detail =
      PullRequestDetail
        { pullRequestSessionPullRequest = pullRequest,
          pullRequestSessionOrigin = PullRequestClaude,
          pullRequestSessionAction = PullRequestReview,
          pullRequestSessionLaunchedForUpdatedAt = epoch,
          pullRequestSessionBrand = CodexSolver,
          pullRequestSessionId = Nothing,
          pullRequestSessionResumeProvenance = ResumeAnswer,
          pullRequestSessionAssignment = Nothing
        }

testReviewSession :: Issue -> ReviewPhase -> ReviewSession
testReviewSession issue phase =
  (newAgentSession 0 phase "review activity" Nothing emptyTranscript detail) {sessionTickGeneration = 0}
  where
    detail =
      ReviewDetail
        { reviewSessionIssue = issue,
          reviewSessionStage = InitialReview,
          reviewSessionThreadId = Nothing,
          reviewSessionTurnId = Nothing,
          reviewSessionPending = Nothing,
          reviewSessionUndelivered = []
        }

emptyTranscript :: ChatTranscript
emptyTranscript = ChatTranscript "" "" ""
