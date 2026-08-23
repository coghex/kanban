module Kanban.UI.PullRequest
  ( applyDirectMerge,
    applyDrainerStatus,
    applyDrainerToggle,
    applyPullRequestFlowEvent,
    drainerErrorStatus,
    drainerTogglePress,
    failPullRequestLaunch,
    interruptPullRequestSession,
    mergeItemDoneCard,
    mergeSelectedDoneCard,
    modifyAutoSolveForPullRequest,
    pullRequestStartRefusal,
    runDrainerToggleHandoff,
    startPullRequestReview,
    startPullRequestReviewWithVisibility,
    submitPullRequestInput,
    toggleDrainer,
  )
where


import Brick
import Brick.BChan (BChan, writeBChan)
import Control.Concurrent (forkIO)
import Control.Monad (void, when)
import Control.Monad.IO.Class (liftIO)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.CLI (Options (..))
import Kanban.Config (ResolvedConfig (..) )
import Kanban.Domain
import Kanban.Drainer
  ( DirectMergeDecision (..),
    DirectMergeEffect (..),
    DirectMergeOutcome,
    DrainerActivity (..),
    DrainerController,
    DrainerIncident (..),
    DrainerObservation (..),
    DrainerState (..),
    DrainerStatus (..),
    DrainerToggle (..),
    directMergeDecision,
    directMergeEffect,
    drainerToggle,
    resolveSinglePullRequestDrainer,
    runDirectMerge,
    setDrainerRunning
  )
import Kanban.Models (RecordedAssignment)
import Kanban.Preflight
  ( PreflightAction (..)
    )
import Kanban.Process (interruptManagedProcess )
import Kanban.PullRequestFlow
  ( PullRequestAction (..),
    PullRequestFlowEvent (..),
    PullRequestOrigin (..),
    agentForAction,
    directPullRequestAction,
    labelPullRequestAction,
    originFromBody,
    pullRequestAssignment
    )
import Kanban.Solve
  ( ResumeProvenance (..),
    SolveOutcome (..),
    SolverBrand (..)
    )
import Kanban.Text (sanitizeText)
import Kanban.Worker
  ( WorkerParent (..),
    launchPullRequestWorker,
    pendingTerminationDiagnosticPrefix
    )
import Kanban.UI.Filter (readOnlyHistoryRefusal, readOnlyHistoryRefusalFor)
import Kanban.UI.Keys (BoardAction (..), actionKeyText)
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.SessionCore
import Kanban.UI.State
import Kanban.UI.Transcript
import Kanban.UI.Selection
import Kanban.UI.Session
import Kanban.UI.SessionEvents
import Kanban.UI.Refresh
import Kanban.UI.Solve

-- | The user's own @r@ on a pull request, which is the only dispatch that
-- derives repair: a Done card whose status is a problem needs its own code
-- worked on rather than another review round.
startPullRequestReview :: PullRequest -> EventM Name AppState ()
startPullRequestReview = startPullRequestReviewWithOptions directPullRequestAction True False

-- | Autosolve's internal PR sessions, which stay on the label-derived
-- review/revise progression they have always driven: a problem status on the
-- pull request it is looping over must not silently become a repair launch.
startPullRequestReviewWithVisibility :: Bool -> PullRequest -> EventM Name AppState ()
startPullRequestReviewWithVisibility showOverlay = startPullRequestReviewWithOptions labelPullRequestAction showOverlay False

-- | The roster refusal a press must answer /before/ a session is created, for
-- the reason 'Kanban.UI.Solve.solveStartDecision' documents: a session left
-- behind by a refusal is one 'pullRequestSessionReusable' hands back to the
-- next press instead of retrying. The launch boundary asks again, because
-- that is the boundary a process actually crosses.
pullRequestStartRefusal :: AppState -> PullRequestOrigin -> PullRequestAction -> Maybe Text
pullRequestStartRefusal state origin action =
  case resolvedRosterCellFor (\roster -> pullRequestAssignment roster origin action) state.appModelRoster of
    Left message -> Just (pullRequestActionText action <> " did not start: " <> message)
    Right _ -> Nothing

startPullRequestReviewWithOptions :: (WorkflowConfig -> PullRequest -> PullRequestAction) -> Bool -> Bool -> PullRequest -> EventM Name AppState ()
startPullRequestReviewWithOptions selectAction showOverlay forceFresh pullRequest = case originFromBody pullRequest.pullRequestBody of
  Left message -> setNotice message
  Right origin -> do
    state <- get
    let action = selectAction state.appConfig.resolvedWorkflow pullRequest
    case Map.lookup pullRequest.pullRequestNumber state.appPullRequestReviewSessions of
      Just session
        | pullRequestSessionReusable forceFresh (solvePhaseActive session.sessionPhase) session.sessionDetail.pullRequestSessionAction action session.sessionDetail.pullRequestSessionLaunchedForUpdatedAt pullRequest.pullRequestUpdatedAt ->
            when showOverlay $ do
              modify (\current -> current {appOverlay = Just (PullRequestReviewOverlay pullRequest.pullRequestNumber), appNotice = Nothing})
              presentTranscriptTail
      _ | Just notice <- pullRequestStartRefusal state origin action -> setNotice notice
      _ -> do
        let brand = agentForAction origin action
            session =
              newAgentSession
                (priorTickGeneration pullRequest.pullRequestNumber state.appPullRequestReviewSessions)
                SolveStarting
                "starting"
                (Just state.appNow)
                (plainTranscript ("action: " <> pullRequestActionText action <> "\nagent: " <> pullRequestAgentLabel action brand <> "\n\n"))
                PullRequestDetail
                  { pullRequestSessionPullRequest = pullRequest,
                    pullRequestSessionOrigin = origin,
                    pullRequestSessionAction = action,
                    pullRequestSessionLaunchedForUpdatedAt = pullRequest.pullRequestUpdatedAt,
                    pullRequestSessionBrand = brand,
                    pullRequestSessionId = Nothing,
                    pullRequestSessionResumeProvenance = ResumeAnswer,
                    -- A fresh press is never a replay; see
                    -- 'Kanban.UI.Solve.startFreshIssueSolve'.
                    pullRequestSessionAssignment = Nothing
                  }
        modify
          ( \current ->
              current
                { appPullRequestReviewSessions = Map.insert pullRequest.pullRequestNumber session current.appPullRequestReviewSessions,
                  appOverlay = if showOverlay then Just (PullRequestReviewOverlay pullRequest.pullRequestNumber) else current.appOverlay,
                  appNotice = if showOverlay then Nothing else current.appNotice
                }
          )
        when showOverlay presentTranscriptTail
        launchPullRequestFlow pullRequest.pullRequestNumber origin action brand Nothing ResumeAnswer ""

-- | The one place a pull-request worker is spawned, from a fresh review,
-- revision, rereview or repair and from a resumed answer alike. The
-- read-only-history refusal is re-asked here for the reason it is re-asked at
-- 'Kanban.UI.Solve.launchSolveInvocation': this is the boundary a process
-- actually crosses.
launchPullRequestFlow :: Int -> PullRequestOrigin -> PullRequestAction -> SolverBrand -> Maybe Text -> ResumeProvenance -> Text -> EventM Name AppState ()
launchPullRequestFlow number origin action brand existingSession provenance input = do
  refusal <- flip readOnlyHistoryRefusalFor (PullRequestId number) <$> get
  case refusal of
    Just notice -> setNotice notice
    Nothing -> launchLivePullRequestFlow number origin action brand existingSession provenance input

-- | The roster refusal sits here for the reason the read-only-history one
-- does: this is the boundary a process crosses. Autosolve's own review and
-- rereview rounds come through 'launchPullRequestFlow' above, so they refuse
-- on the same terms without an arm of their own.
launchLivePullRequestFlow :: Int -> PullRequestOrigin -> PullRequestAction -> SolverBrand -> Maybe Text -> ResumeProvenance -> Text -> EventM Name AppState ()
launchLivePullRequestFlow number origin action brand existingSession provenance input = do
  state <- get
  let recorded = Map.lookup number state.appPullRequestReviewSessions >>= (.sessionDetail.pullRequestSessionAssignment)
  case launchAssignment recorded (\roster -> pullRequestAssignment roster origin action) state.appModelRoster of
    Left message -> liftIO (failPullRequestLaunch state.appEventChannel number message)
    Right assignment -> do
      modifyPullRequestSession number (withSessionDetail (\detail -> detail {pullRequestSessionAssignment = Just assignment}))
      launchAssignedPullRequestFlow assignment number origin action brand existingSession provenance input

-- | The pull-request twin of 'Kanban.UI.Solve.failSolveLaunch', and for the
-- same reason: every caller has already inserted or reopened a session, so a
-- launch that never reached a provider has to settle that session rather than
-- only raise a notice. A session left in 'SolveStarting' is what
-- 'pullRequestSessionReusable' reads as live work and reopens instead of
-- starting a fresh review.
failPullRequestLaunch :: BChan AppEvent -> Int -> Text -> IO ()
failPullRequestLaunch eventChannel number message = do
  writeBChan eventChannel (PullRequestProtocolEvent (PullRequestFlowDiagnostic number message))
  writeBChan eventChannel (PullRequestProtocolEvent (PullRequestProcessFinished number (SolveFailed message)))

launchAssignedPullRequestFlow :: RecordedAssignment -> Int -> PullRequestOrigin -> PullRequestAction -> SolverBrand -> Maybe Text -> ResumeProvenance -> Text -> EventM Name AppState ()
launchAssignedPullRequestFlow assignment number origin action _brand existingSession provenance input = do
  state <- get
  let existingLogPath = Map.lookup number state.appPullRequestReviewSessions >>= (.sessionLogPath)
      parent = autoSolveWorkerParent state number
      eventChannel = state.appEventChannel
  void . liftIO . forkIO $ do
    blocked <- preflightBlocker state.appRepository (ActionPullRequestFlow origin action)
    case blocked of
      Just message -> failPullRequestLaunch eventChannel number message
      Nothing -> do
        launched <- launchPullRequestWorker assignment state.appRepository number origin action existingSession existingLogPath provenance input parent state.appOptions.optionConfig state.appConfig.resolvedWorkflow
        case launched of
          Left message -> failPullRequestLaunch eventChannel number message
          Right descriptor -> do
            writeBChan eventChannel (WorkerRegistered descriptor)

autoSolveWorkerParent :: AppState -> Int -> Maybe WorkerParent
autoSolveWorkerParent state pullRequestNumber =
  case
      [ WorkerParent
          { workerParentIssueNumber = issueNumber,
            workerParentReviewRound = progress.autoSolveReviewRound,
            workerParentSolverBrand = session.sessionDetail.solveSessionBrand,
            workerParentSolverSession = session.sessionDetail.solveSessionId,
            workerParentSolverLogPath = session.sessionLogPath,
            workerParentStartedAt = progress.autoSolveStartedAt,
            workerParentKnownPullRequests = progress.autoSolveKnownPullRequests,
            workerParentSolverAssignment = session.sessionDetail.solveSessionAssignment
          }
        | (issueNumber, session) <- Map.toList state.appSolveSessions,
          Just progress <- [session.sessionDetail.solveSessionAutoProgress],
          progress.autoSolvePullRequest == Just pullRequestNumber
      ] of
    parent : _ -> Just parent
    [] -> Nothing

submitPullRequestInput :: Int -> EventM Name AppState ()
submitPullRequestInput number = do
  state <- get
  case Map.lookup number state.appPullRequestReviewSessions of
    Just session
      | session.sessionPhase == SolveAttention,
        Just sessionId <- session.sessionDetail.pullRequestSessionId,
        not (Text.null (Text.strip session.sessionInput)) -> do
          let answer = Text.strip session.sessionInput
          appendToPullRequestSession number (\current -> current {sessionPhase = SolveStarting, sessionActivity = "resuming", sessionInput = "", sessionTranscript = appendTranscript current.sessionTranscript ("\nYou: " <> answer <> "\n")})
          modifyAutoSolveForPullRequest number
            (\current -> current {sessionPhase = SolveRunning, sessionActivity = "resuming PR review"})
          launchPullRequestFlow number session.sessionDetail.pullRequestSessionOrigin session.sessionDetail.pullRequestSessionAction session.sessionDetail.pullRequestSessionBrand (Just sessionId) session.sessionDetail.pullRequestSessionResumeProvenance answer
      | otherwise -> setNotice "This PR workflow is not waiting for a resumable answer"
    Nothing -> setNotice "PR workflow session is no longer available"

applyPullRequestFlowEvent :: PullRequestFlowEvent -> EventM Name AppState ()
applyPullRequestFlowEvent flowEvent = case flowEvent of
  PullRequestProcessSpawning _ _ -> pure ()
  PullRequestProcessStarted number _ _ process -> do
    modify
      ( \state ->
          state
            { appPullRequestProcesses = Map.insert number process state.appPullRequestProcesses,
              -- issue #39: see 'SolveProcessStarted'.
              appPullRequestReviewSessions = Map.adjust (setSessionActivity state.appNow "thinking" . (\session -> session {sessionPhase = SolveRunning, sessionFollowing = True})) number state.appPullRequestReviewSessions
            }
      )
    modifyAutoSolveForPullRequest number
      (\session -> session {sessionPhase = SolveRunning, sessionActivity = "PR agent is thinking"})
    armSessionTick pullRequestSessionOps number
  PullRequestLogOpened number path ->
    modifyPullRequestSession number (\session -> session {sessionLogPath = Just path})
  PullRequestSessionIdentified number sessionId ->
    modifyPullRequestSession number (withSessionDetail (\detail -> detail {pullRequestSessionId = Just sessionId}))
  PullRequestFlowOutput number output -> do
    now <- (.appNow) <$> get
    appendToPullRequestSession number
      (setSessionActivity now (agentActivity output) . (\session -> session {sessionTranscript = appendAgentTranscript output session.sessionTranscript}))
  PullRequestFlowDiagnostic number output -> do
    now <- (.appNow) <$> get
    appendOutput number ("[agent] " <> sanitizeText output <> "\n")
    -- This specific diagnostic means a user-requested kill could not be
    -- verified (see Kanban.Worker's pending-termination marker) and the
    -- worker is still alive and retrying: render it orphaned rather than
    -- running or optimistically "killed". Matched by text, not by the
    -- session's current phase, so a TUI restart that replays this same
    -- event from a fresh session (which never ran the "killed by user" UI
    -- transition) still renders it correctly.
    modifyPullRequestSession number
      ( setSessionActivity now "diagnostic output"
          . (\session -> session {sessionPhase = if pendingTerminationDiagnosticPrefix `Text.isInfixOf` output then SolveOrphanedPhase else session.sessionPhase})
      )
  PullRequestProcessFinished number outcome -> do
    state <- get
    let priorPhase = (.sessionPhase) <$> Map.lookup number state.appPullRequestReviewSessions
    modify
      ( \current ->
          current
            { appPullRequestProcesses = Map.delete number current.appPullRequestProcesses,
              appPullRequestReviewSessions = Map.adjust (finish priorPhase outcome) number current.appPullRequestReviewSessions
            }
      )
    tailTranscript (PullRequestTranscript number)
    case outcome of
      SolveNeedsInput _ ->
        modifyAutoSolveForPullRequest number
          (\session -> session {sessionPhase = SolveAttention, sessionActivity = "PR review needs input; press " <> actionKeyText ShowProcesses})
      SolveFailed message ->
        modifyAutoSolveForPullRequest number
          (\session -> session {sessionPhase = SolveFailedPhase, sessionActivity = agentFailureNotice "PR agent" message})
      SolveCompleted -> pure ()
    startBoardRefresh
  where
    appendOutput number output =
      appendToPullRequestSession number (\session -> session {sessionTranscript = appendTranscript session.sessionTranscript output})
    finish (Just SolveInterrupting) _ session =
      withResumeProvenance ResumeInterruptGuidance session {sessionPhase = SolveAttention, sessionActivity = "waiting for guidance", sessionTranscript = appendTranscript session.sessionTranscript "\n[interrupted] Type guidance and press Enter to resume this session.\n"}
    finish (Just SolveKilledPhase) _ session = session {sessionActivity = "killed"}
    finish _ SolveCompleted session = session {sessionPhase = SolveFinished, sessionActivity = "completed"}
    finish _ (SolveNeedsInput question) session =
      withResumeProvenance ResumeAnswer session {sessionPhase = SolveAttention, sessionActivity = "waiting for input", sessionTranscript = appendTranscript session.sessionTranscript ("\nQuestion: " <> sanitizeText question <> "\n")}
    finish _ (SolveFailed message) session = session {sessionPhase = SolveFailedPhase, sessionActivity = failureActivity message, sessionTranscript = appendTranscript session.sessionTranscript ("\n" <> sanitizeText message <> "\n")}
    withResumeProvenance provenance = withSessionDetail (\detail -> detail {pullRequestSessionResumeProvenance = provenance})

modifyAutoSolveForPullRequest :: Int -> (SolveSession -> SolveSession) -> EventM Name AppState ()
modifyAutoSolveForPullRequest pullRequestNumber update =
  modify
    ( \state ->
        state
          { appSolveSessions =
              Map.map
                ( \session ->
                    case session.sessionDetail.solveSessionAutoProgress of
                      Just progress
                        | progress.autoSolvePullRequest == Just pullRequestNumber,
                          progress.autoSolveStage == AutoReviewing -> update session
                      _ -> session
                )
                state.appSolveSessions
          }
    )

interruptPullRequestSession :: Int -> EventM Name AppState ()
interruptPullRequestSession number = do
  state <- get
  case (Map.lookup number state.appPullRequestReviewSessions, Map.lookup number state.appPullRequestProcesses) of
    (Just session, Just process)
      | session.sessionPhase `elem` [SolveStarting, SolveRunning], session.sessionDetail.pullRequestSessionId /= Nothing -> do
          appendToPullRequestSession number
            ( \current ->
                current
                  { sessionPhase = SolveInterrupting,
                    sessionActivity = "interrupting",
                    sessionTranscript = appendTranscript current.sessionTranscript "\n[interrupt requested]\n"
                  }
            )
          liftIO (interruptManagedProcess process)
          setNotice ("Interrupting PR workflow #" <> showText number <> "…")
      | session.sessionDetail.pullRequestSessionId == Nothing -> setNotice "Wait for the resumable session id before interrupting"
      | otherwise -> setNotice "This PR workflow has no live turn to interrupt"
    _ -> setNotice "This PR workflow has no live process to interrupt"

-- | What pressing the drainer toggle does to the dashboard, and the
-- controller work it hands off — which this deliberately does not run.
--
-- Splitting the two is what lets the press be exercised: every observable
-- effect of the toggle is the state this returns, so a test can take the
-- press without a controller subprocess ever being spawned, and dispatch has
-- no second copy of it to drift from.
drainerTogglePress :: AppState -> (AppState, Maybe (DrainerController, Bool))
drainerTogglePress state = case drainerToggle state.appDrainerBusy state.appDrainerStatus of
  DrainerToggleBusy notice -> (noticed notice, Nothing)
  decision -> case state.appDrainerController of
    Left message -> (noticed ("PR drainer control unavailable: " <> sanitizeText message), Nothing)
    Right controller ->
      let shouldRun = decision == StartDrainer
          transition =
            if shouldRun
              then DrainerStatus DrainerStarting "starting…" DrainerServiceStarting Nothing
              else DrainerStatus DrainerStopping "stopping…" DrainerServiceStopping Nothing
       in ( state
              { appDrainerStatus = transition,
                -- Mid-transition, the last poll's set describes a drainer
                -- that is being started or stopped underneath it.
                appDrainerIncidents = Nothing,
                appDrainerBusy = True,
                appNotice = Just (if shouldRun then "Starting PR drainer…" else "Stopping PR drainer…")
              },
            Just (controller, shouldRun)
          )
  where
    noticed notice = state {appNotice = Just notice}

toggleDrainer :: EventM Name AppState ()
toggleDrainer = do
  state <- get
  put (fst (drainerTogglePress state))
  runDrainerToggleHandoff state

-- | Start the controller work a press handed off, if it handed any off. Read
-- off the state the press was taken from, so the decision is made once.
runDrainerToggleHandoff :: AppState -> EventM Name AppState ()
runDrainerToggleHandoff state = case snd (drainerTogglePress state) of
  Nothing -> pure ()
  Just (controller, shouldRun) ->
    void
      . liftIO
      . forkIO
      $ setDrainerRunning controller shouldRun >>= writeBChan state.appEventChannel . DrainerToggleFinished

applyDrainerStatus :: Either Text DrainerObservation -> EventM Name AppState ()
applyDrainerStatus result = modify $ \state ->
  if state.appDrainerBusy
    then state
    else
      state
        { appDrainerStatus = observedStatusOr result,
          appDrainerIncidents = observedIncidentsOr result
        }

applyDrainerToggle :: Either Text DrainerObservation -> EventM Name AppState ()
applyDrainerToggle result = modify $ \state ->
  let status = observedStatusOr result
      notice = case result of
        Left message -> "PR drainer control failed: " <> sanitizeText message
        Right _ -> "PR drainer is " <> status.drainerDetail
   in state
        { appDrainerStatus = status,
          appDrainerIncidents = observedIncidentsOr result,
          appDrainerBusy = False,
          appNotice = Just notice
        }

observedStatusOr :: Either Text DrainerObservation -> DrainerStatus
observedStatusOr = either drainerErrorStatus (.observedStatus)

-- | A failed invocation observed no incidents at all, which is not the same
-- as observing none: the previous poll's set is dropped rather than left
-- standing as though it were still current.
observedIncidentsOr :: Either Text DrainerObservation -> Maybe [DrainerIncident]
observedIncidentsOr = either (const Nothing) (.observedIncidents)

-- | A controller that could not be discovered, run, or decoded leaves the
-- service's actual state unknown — never "off" — so nothing that may only act
-- against a settled stop can act on this.
drainerErrorStatus :: Text -> DrainerStatus
drainerErrorStatus message =
  DrainerStatus DrainerError (sanitizeText message) DrainerServiceUnknown Nothing

-- | @m@ on the board, which acts on the selected card.
mergeSelectedDoneCard :: EventM Name AppState ()
mergeSelectedDoneCard = get >>= mergeDoneCard . selectedItem

-- | @m@ on the details overlay, which acts on the card that overlay is for.
mergeItemDoneCard :: BoardItem -> EventM Name AppState ()
mergeItemDoneCard = mergeDoneCard . Just

-- | Merge one approved pull request by running the PR drainer's own
-- single-pull-request path. Kanban decides only whether to invoke it: every
-- gate re-read, the head check, the merge itself, and the branch, worktree
-- and linked-issue cleanup belong to that path and are not restated here.
--
-- The run is forked, so the interface keeps redrawing while it works, and
-- 'appDirectMergePending' is set before the fork so a second @m@ finds it and
-- refuses rather than starting a second process against the same repository.
-- | The selection is re-read against the newest completed generation before
-- 'directMergeDecision' is asked at all, because a details overlay can be
-- holding a pull request that merged since it opened. The decision refuses a
-- settled item on its own too, so a stale card cannot reach the drainer by
-- either door.
mergeDoneCard :: Maybe BoardItem -> EventM Name AppState ()
mergeDoneCard selection = do
  state <- get
  case selection >>= readOnlyHistoryRefusal state of
    Just notice -> setNotice (sanitizeText ("Not merging: " <> notice))
    Nothing -> runMergeDecision selection

runMergeDecision :: Maybe BoardItem -> EventM Name AppState ()
runMergeDecision selection = do
  state <- get
  case directMergeDecision state.appConfig.resolvedWorkflow state.appDirectMergePending state.appDrainerStatus selection of
    RefuseDirectMerge refusal -> setNotice (sanitizeText ("Not merging: " <> refusal))
    RunDirectMerge number -> do
      resolved <- liftIO (resolveSinglePullRequestDrainer (rightOrNothing state.appDrainerController))
      case resolved of
        Left message ->
          setNotice (sanitizeText ("Cannot merge PR #" <> showText number <> ": " <> message))
        Right scriptPath -> do
          modify
            ( \current ->
                current
                  { appDirectMergePending = Just number,
                    appNotice = Just ("Merging PR #" <> showText number <> " through the PR drainer…")
                  }
            )
          void
            . liftIO
            . forkIO
            $ runDirectMerge scriptPath state.appRepository state.appOptions.optionConfig number
              >>= writeBChan state.appEventChannel . DirectMergeFinished number

-- | Publish what one direct merge did. It touches the action's own notice and
-- pending flag and nothing else: 'appDrainerStatus' describes the launchd
-- service, which this ran instead of and did not change, and letting a merge
-- result write there would leave the sidebar reporting an action rather than
-- a service.
applyDirectMerge :: Int -> Either Text DirectMergeOutcome -> EventM Name AppState ()
applyDirectMerge number result = do
  let effect = directMergeEffect number result
  modify
    ( \state ->
        state
          { appDirectMergePending =
              if state.appDirectMergePending == Just number then Nothing else state.appDirectMergePending,
            appNotice = Just effect.directMergeNotice,
            -- Outstanding only when a refresh follows. A declined run reports
            -- itself and nothing overwrites it, and clearing here is also what
            -- retires the previous merge's result.
            appDirectMergeResult =
              if effect.directMergeRefreshesBoard
                then Just (DirectMergeReport effect.directMergeNotice effect.directMergeNotice)
                else Nothing
          }
    )
  when effect.directMergeRefreshesBoard requireBoardRefresh

