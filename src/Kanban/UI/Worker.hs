module Kanban.UI.Worker
  ( applyWorkerProtocolEvent,
    attachDiscoveredWorker,
    orphanMessage,
    recoveredAutoSolveParentSession,
    recoveredPullRequestSession,
    recoveredSolveSession,
    registerWorker,
    startPendingWorkerMonitors,
  )
where


import Brick
import Brick.BChan (writeBChan)
import Control.Concurrent (forkIO )
import Control.Monad (void, when)
import Control.Monad.IO.Class (liftIO)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Domain
import Kanban.Models (ModelRoster, RecordedAssignment, RosterLoadError)
import Kanban.Process (managedProcessGroup )
import Kanban.PullRequestFlow
  ( PullRequestFlowEvent (..),
    agentForAction
    )
import Kanban.Solve
  ( ResumeProvenance (..),
    SolveEvent (..),
    SolveOutcome (..),
    SolveWorkflow (..),
    solveAssignment
  )
import Kanban.Worker
  ( ProcessIdentity,
    PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerDescriptor (..),
    WorkerEvent (..),
    WorkerParent (..),
    WorkerSpec (..),
    WorkerTask (..),
    acknowledgeSupersededWorkers,
    monitorWorker
    )
import Kanban.UI.Keys (BoardAction (..), actionKeyText)
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.SessionCore
import Kanban.UI.State
import Kanban.UI.AutoSolve
import Kanban.UI.Transcript
import Kanban.UI.Solve
import Kanban.UI.PullRequest

registerWorker :: WorkerDescriptor -> EventM Name AppState ()
registerWorker descriptor = do
  modify
    ( \state ->
        state
          { appWorkers =
              Map.insert descriptor.workerDescriptorSpec.workerId descriptor state.appWorkers
          }
    )
  void . liftIO . forkIO $ acknowledgeSupersededWorkers descriptor
  tryStartWorkerMonitor descriptor

applyWorkerProtocolEvent :: WorkerDescriptor -> WorkerEvent -> EventM Name AppState ()
applyWorkerProtocolEvent descriptor workerEvent = do
  ensureWorkerSession descriptor
  case descriptor.workerDescriptorSpec.workerTask of
    SolveWorkerTaskKind task -> case workerEvent of
      WorkerProviderStarted processId ->
        suppressIfResolvedSolve
          task.solveWorkerIssueNumber
          (applySolveEvent (SolveProcessStarted task.solveWorkerIssueNumber task.solveWorkerBrand (managedProcessGroup (fromIntegral processId))))
      WorkerProviderSpawning _ -> pure ()
      WorkerLogOpened path -> applySolveEvent (SolveLogOpened task.solveWorkerIssueNumber path)
      WorkerSessionIdentified sessionId -> applySolveEvent (SolveSessionIdentified task.solveWorkerIssueNumber sessionId)
      WorkerAgentOutput output ->
        suppressIfResolvedSolve task.solveWorkerIssueNumber (applySolveEvent (SolveOutput task.solveWorkerIssueNumber output))
      WorkerDiagnostic message ->
        suppressIfResolvedSolve task.solveWorkerIssueNumber (applySolveEvent (SolveDiagnostic task.solveWorkerIssueNumber message))
      WorkerOrphansDetected outcome processes -> applySolveOrphans task.solveWorkerIssueNumber outcome processes
      WorkerFinished outcome -> applySolveEvent (SolveProcessFinished task.solveWorkerIssueNumber outcome)
    PullRequestWorkerTaskKind task ->
      let brand = agentForAction task.pullRequestWorkerOrigin task.pullRequestWorkerAction
       in case workerEvent of
            WorkerProviderStarted processId ->
              suppressIfResolvedPullRequest
                task.pullRequestWorkerNumber
                (applyPullRequestFlowEvent (PullRequestProcessStarted task.pullRequestWorkerNumber task.pullRequestWorkerAction brand (managedProcessGroup (fromIntegral processId))))
            WorkerProviderSpawning _ -> pure ()
            WorkerLogOpened path -> applyPullRequestFlowEvent (PullRequestLogOpened task.pullRequestWorkerNumber path)
            WorkerSessionIdentified sessionId -> applyPullRequestFlowEvent (PullRequestSessionIdentified task.pullRequestWorkerNumber sessionId)
            WorkerAgentOutput output ->
              suppressIfResolvedPullRequest task.pullRequestWorkerNumber (applyPullRequestFlowEvent (PullRequestFlowOutput task.pullRequestWorkerNumber output))
            WorkerDiagnostic message ->
              suppressIfResolvedPullRequest task.pullRequestWorkerNumber (applyPullRequestFlowEvent (PullRequestFlowDiagnostic task.pullRequestWorkerNumber message))
            WorkerOrphansDetected outcome processes -> applyPullRequestOrphans task.pullRequestWorkerNumber outcome processes
            WorkerFinished outcome -> applyPullRequestFlowEvent (PullRequestProcessFinished task.pullRequestWorkerNumber outcome)
  case workerEvent of
    WorkerFinished _ -> do
      modify
        ( \state ->
            state
              { appWorkers = Map.delete descriptor.workerDescriptorSpec.workerId state.appWorkers,
                appWorkerMonitors = Set.delete descriptor.workerDescriptorSpec.workerId state.appWorkerMonitors
              }
        )
    _ -> pure ()

applySolveOrphans :: Int -> SolveOutcome -> [ProcessIdentity] -> EventM Name AppState ()
applySolveOrphans issueNumber outcome processes = do
  let count = showText (length processes)
      message = orphanMessage outcome count "the solver"
  now <- (.appNow) <$> get
  modify
    ( \state ->
        state
          { appSolveProcesses = Map.delete issueNumber state.appSolveProcesses,
            appSolveSessions =
              Map.adjust
                ( setSessionActivity now message
                    . ( \session ->
                          session
                            { sessionPhase = SolveOrphanedPhase,
                              sessionTranscript = appendTranscript session.sessionTranscript ("\n[orphaned] " <> message <> "\n")
                            }
                      )
                )
                issueNumber
                state.appSolveSessions
          }
    )
  tailTranscript (SolveTranscript issueNumber)
  setNotice ("Solve #" <> showText issueNumber <> " is orphaned; press " <> actionKeyText ShowProcesses <> " to inspect it or " <> actionKeyText KillWorking <> " to kill it")

applyPullRequestOrphans :: Int -> SolveOutcome -> [ProcessIdentity] -> EventM Name AppState ()
applyPullRequestOrphans number outcome processes = do
  let count = showText (length processes)
      message = orphanMessage outcome count "the PR agent"
  now <- (.appNow) <$> get
  modify
    ( \state ->
        state
          { appPullRequestProcesses = Map.delete number state.appPullRequestProcesses,
            appPullRequestReviewSessions =
              Map.adjust
                ( setSessionActivity now message
                    . ( \session ->
                          session
                            { sessionPhase = SolveOrphanedPhase,
                              sessionTranscript = appendTranscript session.sessionTranscript ("\n[orphaned] " <> message <> "\n")
                            }
                      )
                )
                number
                state.appPullRequestReviewSessions
          }
    )
  tailTranscript (PullRequestTranscript number)
  modifyAutoSolveForPullRequest number (\session -> session {sessionActivity = "PR agent left orphaned subprocesses; press " <> actionKeyText ShowProcesses})
  setNotice ("PR workflow #" <> showText number <> " is orphaned; press " <> actionKeyText ShowProcesses <> " to inspect it or " <> actionKeyText KillWorking <> " to kill it")

-- | The orphan-pending activity text for a still-unverified outcome: a
-- deadline that left survivors behind reads distinctly from ordinary
-- subprocesses surviving a solver/PR agent that ran to completion.
orphanMessage :: SolveOutcome -> Text -> Text -> Text
orphanMessage outcome count subject
  | isDeadlineOutcome outcome = "deadline exceeded; " <> count <> " subprocesses survived termination; press " <> actionKeyText KillWorking <> " to terminate the orphaned process tree"
  | otherwise = count <> " subprocesses survived " <> subject <> "; press " <> actionKeyText KillWorking <> " to terminate the orphaned process tree"

attachDiscoveredWorker :: WorkerDescriptor -> EventM Name AppState ()
attachDiscoveredWorker descriptor = do
  state <- get
  let identifier = descriptor.workerDescriptorSpec.workerId
  if Map.member identifier state.appWorkers
    then pure ()
    else registerWorker descriptor

tryStartWorkerMonitor :: WorkerDescriptor -> EventM Name AppState ()
tryStartWorkerMonitor descriptor = do
  ensureWorkerSession descriptor
  state <- get
  let identifier = descriptor.workerDescriptorSpec.workerId
      alreadyMonitoring = identifier `Set.member` state.appWorkerMonitors
      sessionReady = case descriptor.workerDescriptorSpec.workerTask of
        SolveWorkerTaskKind task -> Map.member task.solveWorkerIssueNumber state.appSolveSessions
        PullRequestWorkerTaskKind task -> Map.member task.pullRequestWorkerNumber state.appPullRequestReviewSessions
  when (sessionReady && not alreadyMonitoring) $ do
    modify (\current -> current {appWorkerMonitors = Set.insert identifier current.appWorkerMonitors})
    eventChannel <- (.appEventChannel) <$> get
    void . liftIO . forkIO $
      monitorWorker descriptor (\_ _ event -> writeBChan eventChannel (WorkerProtocolEvent descriptor event))

startPendingWorkerMonitors :: EventM Name AppState ()
startPendingWorkerMonitors = do
  descriptors <- Map.elems . (.appWorkers) <$> get
  mapM_ tryStartWorkerMonitor descriptors

ensureWorkerSession :: WorkerDescriptor -> EventM Name AppState ()
ensureWorkerSession descriptor = do
  state <- get
  case descriptor.workerDescriptorSpec.workerTask of
    SolveWorkerTaskKind task
      | Map.member task.solveWorkerIssueNumber state.appSolveSessions -> pure ()
      | Just issue <- issueFromBoard state.appBoard task.solveWorkerIssueNumber ->
          modify
            ( \current ->
                current
                  { appSolveSessions =
                      Map.insert
                        task.solveWorkerIssueNumber
                        (recoveredSolveSession current descriptor.workerDescriptorSpec.workerAssignment descriptor issue task)
                        current.appSolveSessions
                  }
            )
      | otherwise -> setNotice ("Persistent worker for issue #" <> showText task.solveWorkerIssueNumber <> " is running, but the issue is absent from the cached board; press " <> actionKeyText RefreshAll <> " to refresh")
    PullRequestWorkerTaskKind task -> do
      when (Map.notMember task.pullRequestWorkerNumber state.appPullRequestReviewSessions) $
        case pullRequestFromBoard state.appBoard task.pullRequestWorkerNumber of
          Nothing -> setNotice ("Persistent worker for PR #" <> showText task.pullRequestWorkerNumber <> " is running, but the PR is absent from the cached board; press " <> actionKeyText RefreshAll <> " to refresh")
          Just pullRequest ->
            modify
              ( \current ->
                  current
                    { appPullRequestReviewSessions =
                        Map.insert
                          task.pullRequestWorkerNumber
                          (recoveredPullRequestSession state.appModelRoster (priorTickGeneration task.pullRequestWorkerNumber state.appPullRequestReviewSessions) descriptor pullRequest task)
                          current.appPullRequestReviewSessions
                    }
              )
      ensureRecoveredAutoSolve descriptor task

-- | A solve session restored from a running worker.
--
-- The recorded assignment is a /parameter/ rather than something read out of
-- the descriptor here, because one caller's descriptor is not the solver's:
-- 'recoveredAutoSolveParentSession' restores the solver's session from the
-- pull-request worker's descriptor, whose assignment is the reviewer's. A
-- builder that reached into the descriptor for it would put the reviewer's
-- agent in the solver's transcript, and overriding the detail afterwards
-- cannot take it back out of the text already written.
recoveredSolveSession :: AppState -> Maybe RecordedAssignment -> WorkerDescriptor -> Issue -> SolveWorkerTask -> SolveSession
recoveredSolveSession state assignment descriptor issue task =
  ( newAgentSession
      (priorTickGeneration task.solveWorkerIssueNumber state.appSolveSessions)
      SolveStarting
      "reattaching persistent worker"
      (Just descriptor.workerDescriptorSpec.workerCreatedAt)
      ( plainTranscript
          ( "reattached persistent "
              <> Text.toLower (workflowTitle task.solveWorkerWorkflow)
              <> " worker\nsolver: "
              <> agentSessionLabelFor
                task.solveWorkerBrand
                assignment
                (`solveAssignment` task.solveWorkerBrand)
                state.appModelRoster
              <> "\n\n"
          )
      )
      SolveDetail
        { solveSessionIssue = issue,
          solveSessionWorkflow = task.solveWorkerWorkflow,
          solveSessionBrand = task.solveWorkerBrand,
          solveSessionId = descriptor.workerDescriptorSpec.workerExistingSession,
          solveSessionAutoProgress =
            recoveredAutoSolveProgress
              task.solveWorkerWorkflow
              descriptor.workerDescriptorSpec.workerParent
              (boardPullRequestNumbers state.appBoard)
              descriptor.workerDescriptorSpec.workerCreatedAt,
          solveSessionResumeProvenance = ResumeAnswer,
          -- The recovered session's assignment is whatever the worker that
          -- is still running recorded, so answering its question replays
          -- that rather than resolving against a roster this process may
          -- have loaded differently. 'Nothing' is a specification written
          -- before the field existed, and the first resume resolves once.
          -- One field, set from the parameter the transcript above was built
          -- from, so the two cannot name different agents.
          solveSessionAssignment = assignment
        }
  )
    {sessionLogPath = descriptor.workerDescriptorSpec.workerExistingLogPath}

recoveredPullRequestSession :: Either RosterLoadError ModelRoster -> Int -> WorkerDescriptor -> PullRequest -> PullRequestWorkerTask -> PullRequestReviewSession
recoveredPullRequestSession rosterResult priorGeneration descriptor pullRequest task =
  let brand = agentForAction task.pullRequestWorkerOrigin task.pullRequestWorkerAction
   in ( newAgentSession
          priorGeneration
          SolveStarting
          "reattaching persistent worker"
          (Just descriptor.workerDescriptorSpec.workerCreatedAt)
          ( plainTranscript
              ( "reattached persistent PR "
                  <> pullRequestActionText task.pullRequestWorkerAction
                  <> " worker\nagent: "
                  <> pullRequestSessionLabel
                    descriptor.workerDescriptorSpec.workerAssignment
                    task.pullRequestWorkerOrigin
                    task.pullRequestWorkerAction
                    brand
                    rosterResult
                  <> "\n\n"
              )
          )
          PullRequestDetail
            { pullRequestSessionPullRequest = pullRequest,
              pullRequestSessionOrigin = task.pullRequestWorkerOrigin,
              pullRequestSessionAction = task.pullRequestWorkerAction,
              pullRequestSessionLaunchedForUpdatedAt = pullRequest.pullRequestUpdatedAt,
              pullRequestSessionBrand = brand,
              pullRequestSessionId = descriptor.workerDescriptorSpec.workerExistingSession,
              pullRequestSessionResumeProvenance = ResumeAnswer,
              -- See 'recoveredSolveSession'.
              pullRequestSessionAssignment = descriptor.workerDescriptorSpec.workerAssignment
            }
      )
        {sessionLogPath = descriptor.workerDescriptorSpec.workerExistingLogPath}

ensureRecoveredAutoSolve :: WorkerDescriptor -> PullRequestWorkerTask -> EventM Name AppState ()
ensureRecoveredAutoSolve descriptor task = case descriptor.workerDescriptorSpec.workerParent of
  Nothing -> pure ()
  Just parent -> do
    state <- get
    when (Map.notMember parent.workerParentIssueNumber state.appSolveSessions) $
      case issueFromBoard state.appBoard parent.workerParentIssueNumber of
        Nothing -> pure ()
        Just issue ->
          modify
            ( \current ->
                current
                  { appSolveSessions =
                      Map.insert
                        parent.workerParentIssueNumber
                        (recoveredAutoSolveParentSession state descriptor issue parent task)
                        current.appSolveSessions
                  }
            )

-- | The /solver's/ session an autosolve pull-request worker's reattach
-- restores beside the pull-request one.
--
-- The descriptor names the pull-request agent, so every value that
-- identifies the solver is taken from 'WorkerParent': the session id and the
-- log path override what 'recoveredSolveSession' read out of that
-- descriptor, while the brand and — this is the one a resume runs on — the
-- recorded model assignment are passed /in/ rather than overridden after the
-- fact. Leaving the assignment to the descriptor would hand the solver the
-- reviewer's cell, so a revision launched after a restart would replay the
-- wrong provider against the solver's own session id, and the session's
-- transcript would open by naming that reviewer as its solver.
--
-- Lifted out of 'ensureRecoveredAutoSolve' rather than left inline because
-- that arm runs in brick's 'EventM', which no unit test here can drive; this
-- is the whole of what it decides.
recoveredAutoSolveParentSession :: AppState -> WorkerDescriptor -> Issue -> WorkerParent -> PullRequestWorkerTask -> SolveSession
recoveredAutoSolveParentSession state descriptor issue parent task =
  withSessionDetail
    ( \detail ->
        detail
          { solveSessionId = parent.workerParentSolverSession,
            solveSessionAutoProgress = Just progress
          }
    )
    ( recoveredSolveSession
        state
        parent.workerParentSolverAssignment
        descriptor
        issue
        (SolveWorkerTask parent.workerParentIssueNumber AutoSolve parent.workerParentSolverBrand)
    )
      { sessionPhase = SolveRunning,
        sessionActivity = "PR agent is running",
        sessionLogPath = parent.workerParentSolverLogPath
      }
  where
    progress =
      AutoSolveProgress
        { autoSolveStage = AutoReviewing,
          autoSolvePullRequest = Just task.pullRequestWorkerNumber,
          autoSolveReviewRound = parent.workerParentReviewRound,
          autoSolveKnownPullRequests = parent.workerParentKnownPullRequests,
          autoSolveStartedAt = parent.workerParentStartedAt
        }
