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
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (utc)
import Kanban.Domain
import Kanban.Drainer (DrainerActivity (..), DrainerState (..), DrainerStatus (..))
import Kanban.PullRequestFlow (PullRequestAction (..), PullRequestOrigin (..))
import Kanban.Review (ReviewStage (..))
import Kanban.Settings (defaultSettings)
import Kanban.Solve (ResumeProvenance (..), SolveWorkflow (..), SolverBrand (..))
import Kanban.UI.Types
  ( AppState (..),
    ChatTranscript (..),
    IncidentSelection (..),
    ProcessSelection (..),
    PullRequestReviewSession (..),
    ReviewBackend (..),
    ReviewPhase (..),
    ReviewSession (..),
    SolvePhase (..),
    SolveSession (..),
  )
import Spec.Support.Fixtures (epoch, testOptions, testResolvedConfig)

testAppState :: Board -> IO AppState
testAppState board = do
  eventChannel <- newBChan 16
  pure
    AppState
      { appRepository = Repository "/tmp/example-project" "example" "project",
        appBoard = board,
        appUsage = Map.empty,
        appUsageFreshness = Map.empty,
        appSelectedColumn = Issues,
        appSelectedRows = Map.fromList [(column, 0) | column <- [minBound .. maxBound]],
        appEnsureSelectionVisible = False,
        appExpandedTrackers = Set.empty,
        appSidebarVisible = True,
        appSettings = defaultSettings,
        appLogRoot = "/tmp/example-project/logs",
        appProcessSelection = ProcessSelection Nothing 0,
        appIncidentSelection = IncidentSelection Nothing 0,
        appOverlay = Nothing,
        appNotice = Nothing,
        appBoardFreshness = Fresh epoch,
        appLastSuccessfulFetch = Just epoch,
        appIssuesTruncated = False,
        appPullRequestsTruncated = False,
        appDrainerController = Left "no drainer in tests",
        appDrainerStatus = DrainerStatus DrainerOff "off" DrainerServiceStopped Nothing,
        appDrainerIncidents = Just [],
        appDrainerBusy = False,
        appDirectMergePending = Nothing,
        appDirectMergeResult = Nothing,
        appBoardRefreshQueued = False,
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
  SolveSession
    { solveSessionIssue = issue,
      solveSessionWorkflow = SolveOnly,
      solveSessionBrand = ClaudeSolver,
      solveSessionId = Nothing,
      solveSessionPhase = phase,
      solveSessionActivity = "solve activity",
      solveSessionActivityStartedAt = epoch,
      solveSessionLogPath = Nothing,
      solveSessionTranscript = emptyTranscript,
      solveSessionInput = "",
      solveSessionSpinnerFrame = 0,
      solveSessionAutoProgress = Nothing,
      solveSessionResumeProvenance = ResumeAnswer,
      solveSessionFollowing = True
    }

testPullRequestSession :: PullRequest -> SolvePhase -> PullRequestReviewSession
testPullRequestSession pullRequest phase =
  PullRequestReviewSession
    { pullRequestSessionPullRequest = pullRequest,
      pullRequestSessionOrigin = PullRequestClaude,
      pullRequestSessionAction = PullRequestReview,
      pullRequestSessionLaunchedForUpdatedAt = epoch,
      pullRequestSessionBrand = CodexSolver,
      pullRequestSessionId = Nothing,
      pullRequestSessionPhase = phase,
      pullRequestSessionActivity = "pr activity",
      pullRequestSessionActivityStartedAt = epoch,
      pullRequestSessionLogPath = Nothing,
      pullRequestSessionTranscript = emptyTranscript,
      pullRequestSessionInput = "",
      pullRequestSessionSpinnerFrame = 0,
      pullRequestSessionResumeProvenance = ResumeAnswer,
      pullRequestSessionFollowing = True
    }

testReviewSession :: Issue -> ReviewPhase -> ReviewSession
testReviewSession issue phase =
  ReviewSession
    { reviewSessionIssue = issue,
      reviewSessionStage = InitialReview,
      reviewSessionThreadId = Nothing,
      reviewSessionTurnId = Nothing,
      reviewSessionPhase = phase,
      reviewSessionActivity = "review activity",
      reviewSessionTranscript = emptyTranscript,
      reviewSessionPending = Nothing,
      reviewSessionInput = "",
      reviewSessionUndelivered = [],
      reviewSessionSpinnerFrame = 0,
      reviewSessionTickGeneration = 0,
      reviewSessionTickArmed = False,
      reviewSessionFollowing = True
    }

emptyTranscript :: ChatTranscript
emptyTranscript = ChatTranscript "" "" ""
