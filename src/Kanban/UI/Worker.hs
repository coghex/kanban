module Kanban.UI.Worker
  ( applyWorkerProtocolEvent,
    attachDiscoveredWorker,
    recoveredAutoSolveParentSession,
    recoveredPullRequestSession,
    recoveredReviewSession,
    recoveredSolveSession,
    registerWorker,
    startPendingWorkerMonitors,
    workerSessionEnsured,
  )
where


import Brick
import Brick.BChan (writeBChan)
import Control.Concurrent (forkIO )
import Control.Monad (void, when)
import Control.Monad.IO.Class (liftIO)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import Kanban.Domain
import Kanban.Models (ModelRoster, RecordedAssignment, RosterLoadError, loadedOperatingMode)
import Kanban.Process (managedProcessGroup )
import Kanban.PullRequestFlow
  ( PullRequestFlowEvent (..),
    recordedPullRequestBrand
    )
import Kanban.Solve
  ( ResumeProvenance (..),
    SolveEvent (..),
    SolveOutcome (..),
    SolveWorkflow (..),
    solveAssignment
  )
import Kanban.Worker
  ( IssueActionWorkerTask (..),
    ProcessIdentity,
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
import Kanban.UI.Session (orphanMessage)
import Kanban.UI.SessionCore
import Kanban.UI.State
import Kanban.UI.AutoSolve
import Kanban.UI.Transcript
import Kanban.UI.Solve
import Kanban.UI.PullRequest
import Kanban.UI.Review
  ( applyCanonicalIssueReview,
    applyIssueActionFinished,
    applyIssueActionOrphans,
    applyReviewDiagnostic,
    applyReviewEvent,
    applyReviewInput,
  )

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
  mode <- (.appOperatingMode) <$> get
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
      -- A solve worker journals none of the three review kinds.
      WorkerReviewEvent _ -> pure ()
      WorkerReviewInput _ _ -> pure ()
      WorkerCanonicalReviewFinished _ _ -> pure ()
    PullRequestWorkerTaskKind task ->
      -- This worker is already running, so its brand is the one its own
      -- specification recorded rather than one resolved live: a mode change
      -- between the launch and this event must not relabel the process that
      -- is still going. Only a specification predating the record falls
      -- through to live routing.
      let brand =
            recordedPullRequestBrand
              mode
              descriptor.workerDescriptorSpec.workerAssignment
              task.pullRequestWorkerOrigin
              task.pullRequestWorkerAction
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
            -- A pull-request worker journals none of the three review kinds.
            WorkerReviewEvent _ -> pure ()
            WorkerReviewInput _ _ -> pure ()
            WorkerCanonicalReviewFinished _ _ -> pure ()
    -- One durable issue action, replayed into the overlay it belongs to.
    --
    -- Every arm hands the journaled record straight to the same handler a
    -- live event has always reached. That is what makes requirement 4 true by
    -- construction rather than by a second rendering kept in step by hand: a
    -- dashboard that never closed and one that reattached an hour later run
    -- the same transitions over the same events, so they arrive at the same
    -- bounded transcript suffix, the same pending interaction, the same
    -- activity, and the same follow state.
    IssueActionWorkerTaskKind task -> case workerEvent of
      WorkerReviewEvent reviewEvent -> applyReviewEvent task.issueActionIssueNumber reviewEvent
      WorkerReviewInput display rejected -> applyReviewInput task.issueActionIssueNumber display rejected
      WorkerCanonicalReviewFinished stage result ->
        applyCanonicalIssueReview task.issueActionIssueNumber stage result
      WorkerDiagnostic message -> applyReviewDiagnostic task.issueActionIssueNumber message
      WorkerOrphansDetected outcome processes ->
        applyIssueActionOrphans task.issueActionIssueNumber outcome processes
      WorkerFinished outcome -> applyIssueActionFinished task.issueActionIssueNumber outcome
      -- The identifiers a child records travel on its state file, which the
      -- overlay reads directly; nothing in the transcript changes for them.
      WorkerProviderStarted _ -> pure ()
      WorkerProviderSpawning _ -> pure ()
      WorkerLogOpened _ -> pure ()
      WorkerSessionIdentified _ -> pure ()
      WorkerAgentOutput _ -> pure ()
    -- The host itself renders no session: it is the container its children's
    -- sessions run inside, and its own journal carries only what belongs to
    -- no child.
    IssueHostWorkerTaskKind _ -> pure ()
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
        IssueActionWorkerTaskKind task -> Map.member task.issueActionIssueNumber state.appReviewSessions
        -- The host has no session to wait for, and its journal still has to
        -- be read: a client that could not start reports it there, and a
        -- child waiting on that host would otherwise wait silently.
        IssueHostWorkerTaskKind _ -> True
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
ensureWorkerSession = modify . workerSessionEnsured

-- | What attaching one discovered worker does to the state: the recovered
-- session its item supports, or the absent-item refusal. Pure, and exported,
-- so the suite can take a discovery arriving before the first board
-- publication through the very transition the event runs — the refusal is
-- composed over an outstanding startup line rather than allowed to replace
-- it, because worker discovery is forked at startup and its answer routinely
-- lands while the startup fetch is still running.
workerSessionEnsured :: WorkerDescriptor -> AppState -> AppState
workerSessionEnsured descriptor state = case descriptor.workerDescriptorSpec.workerTask of
  SolveWorkerTaskKind task
    | Map.member task.solveWorkerIssueNumber state.appSolveSessions -> state
    | Just issue <- issueFromBoard state.appBoard task.solveWorkerIssueNumber ->
        state
          { appSolveSessions =
              Map.insert
                task.solveWorkerIssueNumber
                (recoveredSolveSession state descriptor.workerDescriptorSpec.workerAssignment descriptor issue task)
                state.appSolveSessions
          }
    | otherwise -> noticeSetOverStartupReport ("Persistent worker for issue #" <> showText task.solveWorkerIssueNumber <> " is running, but the issue is absent from the cached board; press " <> actionKeyText RefreshAll <> " to refresh") state
  PullRequestWorkerTaskKind task ->
    recoveredAutoSolveEnsured descriptor task (sessionEnsured state)
    where
      sessionEnsured current
        | Map.member task.pullRequestWorkerNumber current.appPullRequestReviewSessions = current
        | otherwise = case pullRequestFromBoard current.appBoard task.pullRequestWorkerNumber of
            Nothing -> noticeSetOverStartupReport ("Persistent worker for PR #" <> showText task.pullRequestWorkerNumber <> " is running, but the PR is absent from the cached board; press " <> actionKeyText RefreshAll <> " to refresh") current
            Just pullRequest ->
              current
                { appPullRequestReviewSessions =
                    Map.insert
                      task.pullRequestWorkerNumber
                      (recoveredPullRequestSession current.appModelRoster (priorTickGeneration task.pullRequestWorkerNumber current.appPullRequestReviewSessions) descriptor pullRequest task)
                      current.appPullRequestReviewSessions
                }
  IssueActionWorkerTaskKind task
    | Map.member task.issueActionIssueNumber state.appReviewSessions -> state
    | Just issue <- issueFromBoard state.appBoard task.issueActionIssueNumber ->
        state
          { appReviewSessions =
              Map.insert
                task.issueActionIssueNumber
                (recoveredReviewSession state descriptor issue task)
                state.appReviewSessions
          }
    | otherwise -> noticeSetOverStartupReport ("An issue action for #" <> showText task.issueActionIssueNumber <> " is running, but the issue is absent from the cached board; press " <> actionKeyText RefreshAll <> " to refresh") state
  -- The host renders nothing of its own. Its children each get the session
  -- above, and a host row appears in the processes overlay through
  -- 'Kanban.UI.Session.agentSessionEntries' rather than through a session.
  IssueHostWorkerTaskKind _ -> state

-- | A review session restored from a running issue action.
--
-- Empty of transcript on purpose, and that is the whole trick: every line the
-- action has ever produced is in its durable journal, and the monitor started
-- for it replays that journal from byte zero through
-- 'Kanban.UI.Review.applyReviewEvent'. So the reconstruction is the live
-- dashboard's own transitions run again over the same events, which is what
-- makes the bounded transcript suffix, the pending interaction, the activity,
-- and the follow state come out identical to what a dashboard that never
-- closed is showing (requirement 4) — rather than a second rendering that has
-- to be kept in step with the first by hand.
recoveredReviewSession :: AppState -> WorkerDescriptor -> Issue -> IssueActionWorkerTask -> ReviewSession
recoveredReviewSession state descriptor issue task =
  newAgentSession
    (priorTickGeneration task.issueActionIssueNumber state.appReviewSessions)
    ReviewStarting
    "replaying issue action"
    (Just descriptor.workerDescriptorSpec.workerCreatedAt)
    (plainTranscript "")
    ReviewDetail
      { reviewSessionIssue = issue,
        reviewSessionStage = task.issueActionStage,
        reviewSessionThreadId = Nothing,
        reviewSessionTurnId = Nothing,
        reviewSessionPending = Nothing,
        reviewSessionUndelivered = [],
        reviewSessionRestored = Nothing
      }

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
  -- See 'applyWorkerProtocolEvent': a recovered worker replays what it
  -- recorded, and the live mode answers only for a legacy specification that
  -- recorded nothing.
  let brand =
        recordedPullRequestBrand
          (loadedOperatingMode rosterResult)
          descriptor.workerDescriptorSpec.workerAssignment
          task.pullRequestWorkerOrigin
          task.pullRequestWorkerAction
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

recoveredAutoSolveEnsured :: WorkerDescriptor -> PullRequestWorkerTask -> AppState -> AppState
recoveredAutoSolveEnsured descriptor task state = case descriptor.workerDescriptorSpec.workerParent of
  Nothing -> state
  Just parent
    | Map.member parent.workerParentIssueNumber state.appSolveSessions -> state
    | otherwise -> case issueFromBoard state.appBoard parent.workerParentIssueNumber of
        Nothing -> state
        Just issue ->
          state
            { appSolveSessions =
                Map.insert
                  parent.workerParentIssueNumber
                  (recoveredAutoSolveParentSession state descriptor issue parent task)
                  state.appSolveSessions
            }

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
