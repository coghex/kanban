module Kanban.UI.Reconcile
  ( appendWarnings,
    applyBoardRefresh,
    applyClaudeRefresh,
    applyCodexRefresh,
    reconcileReviewSessions,
    unverifiedRefreshNotice,
  )
where


import Brick
import Control.Monad.IO.Class (liftIO)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Cache
  ( writeUsageCache
  )
import Kanban.CLI (Options (..))
import Kanban.Config (ResolvedConfig (..) )
import Kanban.Domain
import Kanban.GitHub (GhCleanupFailure (..), GhCleanupGuard (..), GitHubResult (..) )
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.Review
  ( ReviewStage (..)
    )
import Kanban.Solve
  ( ResumeProvenance (..),
    SolveWorkflow (..)
    )
import Kanban.Text (sanitizeText)
import Kanban.Workflow (deriveBoard )
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.SessionCore
import Kanban.UI.State
import Kanban.UI.AutoSolve
import Kanban.UI.Selection
import Kanban.UI.SessionEvents
import Kanban.UI.Refresh
import Kanban.UI.Solve
import Kanban.UI.PullRequest
import Kanban.UI.Worker

applyBoardRefresh :: BoardRefreshOutcome -> EventM Name AppState ()
applyBoardRefresh outcome = do
  before <- get
  modify $ \state -> case outcome of
    -- Once the unconfirmed group is on disk, 'fetchGitHubSnapshot'
    -- re-verifies it before spawning anything, so a later refresh -- in this
    -- process or in one started after a restart -- cannot overlap it, and the
    -- board is free to sit in an ordinary failure state that self-heals as
    -- soon as the group is confirmed gone. Without that record the in-memory
    -- refusal is all that is left, so 'appBoardFreshness' stays 'Loading' and
    -- 'startBoardRefresh' keeps turning further fetches away.
    BoardRefreshUnverified failure
      | GuardRecorded <- failure.ghCleanupGuard ->
          state
            { appBoardFreshness = failureFreshness state (unverifiedProviderError failure),
              appNotice = Just (unverifiedRefreshNotice failure)
            }
      | otherwise -> state {appNotice = Just (unverifiedRefreshNotice failure)}
    BoardRefreshCompleted (Left providerError) ->
      state
        { appBoardFreshness = failureFreshness state providerError,
          appNotice = Just (renderProviderError providerError)
        }
    BoardRefreshCompleted (Right githubResult) ->
      let snapshot = githubResult.githubSnapshot
          refreshedBoard = deriveBoard state.appConfig.resolvedWorkflow snapshot
          (selectedColumn, selectedRows) = preserveSelection state refreshedBoard
          (refreshedOverlay, overlayNotice) = refreshOverlay refreshedBoard state.appOverlay
          refreshedReviewSessions = reconcileReviewSessions state.appConfig.resolvedWorkflow snapshot.snapshotIssues state.appReviewSessions
          refreshedPullRequestSessions = reconcilePullRequestSessions snapshot.snapshotPullRequests state.appPullRequestReviewSessions
          successNotice = refreshSuccessNotice snapshot githubResult.githubWarnings
       in state
            { appBoard = refreshedBoard,
              appSelectedColumn = selectedColumn,
              appSelectedRows = selectedRows,
              appOverlay = refreshedOverlay,
              appReviewSessions = refreshedReviewSessions,
              appPullRequestReviewSessions = refreshedPullRequestSessions,
              appBoardFreshness = Fresh snapshot.snapshotFetchedAt,
              appLastSuccessfulFetch = Just snapshot.snapshotFetchedAt,
              appIssuesTruncated = snapshot.snapshotIssuesTruncated,
              appPullRequestsTruncated = snapshot.snapshotPullRequestsTruncated,
              appNotice = Just (maybe successNotice (<> (" · " <> successNotice)) overlayNotice)
            }
  -- Applied over whichever notice the outcome above produced, so a merge that
  -- landed is still reported once the refresh it required has published --
  -- above all a merge whose post-merge work then failed, which this is the
  -- only place the user is ever told about.
  modify
    ( \state ->
        let outstanding = outstandingDirectMergeReport before.appNotice before.appDirectMergeResult
            (composed, carried) = directMergeNoticeFor outstanding (fromMaybe "" state.appNotice)
         in state
              { appNotice = if isJust outstanding then Just composed else state.appNotice,
                appDirectMergeResult = directMergeReportAfterRefresh before.appBoardRefreshQueued carried
              }
    )
  startPendingWorkerMonitors
  case outcome of
    BoardRefreshCompleted (Right githubResult) -> advanceAutoSolves githubResult.githubSnapshot
    _ -> pure ()
  startQueuedBoardRefresh

-- | What the board reports when a refresh's @gh@ process group could not be
-- confirmed gone. It names the cause and then what will happen next, which
-- differs by whether the group was durably recorded: a recorded group is
-- re-checked by the next refresh and clears itself once it is gone, while an
-- unrecorded one leaves this dashboard unable to refresh at all. Restarting
-- is never offered as a fix — a restart drops the in-memory guard, and only
-- the recorded case has anything left to stop a new @gh@ overlapping the old.
unverifiedRefreshNotice :: GhCleanupFailure -> Text
unverifiedRefreshNotice failure =
  "GitHub refresh timed out and its gh process could not be confirmed stopped ("
    <> failure.ghCleanupMessage
    <> "); "
    <> case failure.ghCleanupGuard of
      GuardRecorded -> "the next refresh re-checks it and will proceed once it is gone"
      GuardInMemoryOnly -> "this dashboard will not refresh again, and a restart cannot know to hold back -- check for a stray gh process first"

-- | The unverified cleanup rendered as a provider error, purely so
-- 'failureFreshness' can age the board the same way every other failed
-- refresh does.
unverifiedProviderError :: GhCleanupFailure -> ProviderError
unverifiedProviderError failure = ProviderError RequestFailed (unverifiedRefreshNotice failure)

reconcilePullRequestSessions :: [PullRequest] -> Map Int PullRequestReviewSession -> Map Int PullRequestReviewSession
reconcilePullRequestSessions pullRequests = Map.mapWithKey reconcile
  where
    pullRequestsByNumber = Map.fromList [(pullRequest.pullRequestNumber, pullRequest) | pullRequest <- pullRequests]
    reconcile number session = case Map.lookup number pullRequestsByNumber of
      Nothing -> session
      Just pullRequest -> withSessionDetail (\detail -> detail {pullRequestSessionPullRequest = pullRequest}) session

reconcileReviewSessions :: WorkflowConfig -> [Issue] -> Map Int ReviewSession -> Map Int ReviewSession
reconcileReviewSessions config issues = Map.mapWithKey reconcile
  where
    issuesByNumber = Map.fromList [(issue.issueNumber, issue) | issue <- issues]
    reconcile issueNumber session = case Map.lookup issueNumber issuesByNumber of
      Nothing -> session
      Just issue ->
        (withSessionDetail (\detail -> detail {reviewSessionIssue = issue}) session)
          {sessionPhase = reconciledPhase issue session}
    reconciledPhase issue session
      | issueHasLabel config.approvalLabel issue = ReviewFinished
      | issueHasLabel "reviewed:revised" issue
          && session.sessionPhase == ReviewFailed
          && session.sessionDetail.reviewSessionStage == IssueRevision =
          ReviewRevised
      | issueHasLabel config.changesRequestedLabel issue && session.sessionPhase == ReviewFailed = ReviewNeedsChanges
      | otherwise = session.sessionPhase

issueHasLabel :: Text -> Issue -> Bool
issueHasLabel labelName issue =
  any ((== Text.toCaseFold labelName) . Text.toCaseFold . (.labelName)) issue.issueLabels

applyCodexRefresh :: Either ProviderError UsageSnapshot -> EventM Name AppState ()
applyCodexRefresh = applyUsageRefresh Codex "Codex"

applyClaudeRefresh :: Either ProviderError UsageSnapshot -> EventM Name AppState ()
applyClaudeRefresh = applyUsageRefresh Claude "Claude"

applyUsageRefresh :: UsageProvider -> Text -> Either ProviderError UsageSnapshot -> EventM Name AppState ()
applyUsageRefresh provider displayName result = case result of
  Left providerError ->
    modify
      ( \state ->
          state
            { appUsageFreshness = Map.insert provider (usageFailureFreshness provider state providerError) state.appUsageFreshness,
              appNotice = Just (displayName <> " usage refresh failed: " <> renderProviderErrorMessage providerError)
            }
      )
  Right snapshot -> do
    state <- get
    let snapshots = Map.insert provider snapshot state.appUsage
    cacheWarning <-
      if cacheEnabled state.appOptions state.appConfig
        then either Just (const Nothing) <$> liftIO (writeUsageCache snapshots)
        else pure Nothing
    modify
      ( \current ->
          current
            { appUsage = snapshots,
              appUsageFreshness = Map.insert provider (Fresh snapshot.usageFetchedAt) current.appUsageFreshness,
              appNotice = Just (displayName <> " usage refreshed" <> maybe "" (" · " <>) cacheWarning)
            }
      )

usageFailureFreshness :: UsageProvider -> AppState -> ProviderError -> Freshness
usageFailureFreshness provider state providerError = case Map.lookup provider state.appUsage of
  Just snapshot -> Stale snapshot.usageFetchedAt providerError.providerErrorMessage
  Nothing -> case providerError.providerErrorKind of
    UnsupportedVersion -> Unsupported providerError.providerErrorMessage
    _ -> Unavailable providerError.providerErrorMessage

failureFreshness :: AppState -> ProviderError -> Freshness
failureFreshness state providerError = case state.appLastSuccessfulFetch of
  Just fetchedAt -> Stale fetchedAt providerError.providerErrorMessage
  Nothing -> Unavailable providerError.providerErrorMessage

renderProviderError :: ProviderError -> Text
renderProviderError providerError =
  "GitHub refresh failed: " <> renderProviderErrorMessage providerError

renderProviderErrorMessage :: ProviderError -> Text
renderProviderErrorMessage providerError =
  kind <> ": " <> providerError.providerErrorMessage
  where
    kind = case providerError.providerErrorKind of
      AuthenticationRequired -> "AUTH REQUIRED"
      ExecutableMissing -> "NOT INSTALLED"
      UnsupportedVersion -> "UNSUPPORTED VERSION"
      RequestTimedOut -> "TIMED OUT"
      InvalidResponse -> "INVALID RESPONSE"
      RequestFailed -> "REQUEST ERROR"

refreshSuccessNotice :: RepoSnapshot -> [Text] -> Text
refreshSuccessNotice snapshot warnings =
  "GitHub refreshed · "
    <> countedSource "issue" (length snapshot.snapshotIssues) snapshot.snapshotIssuesTruncated
    <> " · "
    <> countedSource "PR" (length snapshot.snapshotPullRequests) snapshot.snapshotPullRequestsTruncated
    <> case warnings of
      [] -> ""
      values -> " · " <> Text.intercalate " · " values

appendWarnings :: Text -> [Text] -> Text
appendWarnings message [] = message
appendWarnings message warnings = message <> " · " <> Text.intercalate " · " warnings

-- | Adapt the pure autosolve engine to the dashboard: gather what this
-- refresh saw, run the decision it produces, and render the notices. Every
-- stage and round decision belongs to 'Kanban.UI.AutoSolve'; nothing below
-- re-derives one, so the two cannot drift apart.
advanceAutoSolves :: RepoSnapshot -> EventM Name AppState ()
advanceAutoSolves snapshot = do
  sessions <- Map.toList . (.appSolveSessions) <$> get
  mapM_ (uncurry (advanceAutoSolve snapshot)) sessions

advanceAutoSolve :: RepoSnapshot -> Int -> SolveSession -> EventM Name AppState ()
advanceAutoSolve snapshot issueNumber session = case session.sessionDetail.solveSessionAutoProgress of
  Nothing -> pure ()
  Just progress -> do
    state <- get
    let observation = autoSolveObservation state snapshot issueNumber session progress
    runAutoSolveDecision snapshot issueNumber session (decideAutoSolve observation progress)

autoSolveObservation :: AppState -> RepoSnapshot -> Int -> SolveSession -> AutoSolveProgress -> AutoSolveObservation
autoSolveObservation state snapshot issueNumber session progress =
  AutoSolveObservation
    { autoSolveIssueNumber = issueNumber,
      autoSolveWorkflowConfig = state.appConfig.resolvedWorkflow,
      autoSolveSolverBrand = session.sessionDetail.solveSessionBrand,
      autoSolveSolverSession = session.sessionDetail.solveSessionId,
      autoSolveSolverRunning = Map.member issueNumber state.appSolveProcesses,
      autoSolveSnapshotPullRequests = snapshot.snapshotPullRequests,
      autoSolveReviewPhase =
        (.sessionPhase)
          <$> (progress.autoSolvePullRequest >>= (`Map.lookup` state.appPullRequestReviewSessions))
    }

runAutoSolveDecision :: RepoSnapshot -> Int -> SolveSession -> AutoSolveDecision -> EventM Name AppState ()
runAutoSolveDecision snapshot issueNumber session decision = case decision of
  AutoSolveWait -> pure ()
  AutoSolveWaitingOn activity ->
    modifySolveSession issueNumber (\current -> current {sessionActivity = activity})
  AutoSolveStartReview number -> startAutoSolveReview snapshot number
  AutoSolveOpenReview number progress -> do
    appendToSolveSession
      issueNumber
      ( \current ->
          (withAutoSolveProgress progress current)
            { sessionPhase = SolveRunning,
              sessionActivity = "reviewing PR #" <> showText number,
              sessionTranscript =
                appendTranscript
                  current.sessionTranscript
                  ("\n[kanban] Discovered PR #" <> showText number <> "; starting review round " <> showText progress.autoSolveReviewRound <> ".\n")
            }
      )
    startAutoSolveReview snapshot number
    setNotice ("Autosolve #" <> showText issueNumber <> " discovered PR #" <> showText number <> " and started review")
  AutoSolveRevise number progress -> do
    state <- get
    let prompt =
          autoSolveRevisionPrompt
            state.appConfig.resolvedWorkflow
            state.appOptions.optionConfig
            state.appRepository
            session.sessionDetail.solveSessionBrand
            number
            progress.autoSolveReviewRound
    appendToSolveSession
      issueNumber
      ( \current ->
          (withAutoSolveProgress progress current)
            { sessionPhase = SolveStarting,
              sessionActivity = "resuming solver for requested changes",
              sessionTranscript =
                appendTranscript
                  current.sessionTranscript
                  ("\n[kanban] Review requested changes on PR #" <> showText number <> "; resuming the original solver.\n")
            }
      )
    mapM_
      (\sessionId -> launchSolveInvocation issueNumber AutoSolve session.sessionDetail.solveSessionBrand (Just sessionId) ResumeAutomatedChangesRequested prompt)
      session.sessionDetail.solveSessionId
    setNotice ("Autosolve #" <> showText issueNumber <> " resumed its original solver for PR #" <> showText number)
  AutoSolveApprove number -> do
    appendToSolveSession
      issueNumber
      ( \current ->
          (mapAutoSolveProgress autoSolveCompleted current)
            { sessionPhase = SolveFinished,
              sessionActivity = "approved PR #" <> showText number,
              sessionTranscript =
                appendTranscript
                  current.sessionTranscript
                  ("\n[kanban] PR #" <> showText number <> " approved; autosolve complete.\n")
            }
      )
    setNotice ("Autosolve #" <> showText issueNumber <> " completed: PR #" <> showText number <> " is approved")
  AutoSolveHalted haltKind reason -> do
    appendToSolveSession
      issueNumber
      ( \current ->
          (mapAutoSolveProgress autoSolveStopped current)
            { sessionPhase = haltPhase haltKind,
              sessionActivity = reason,
              sessionTranscript =
                appendTranscript
                  current.sessionTranscript
                  ("\n[kanban] Autosolve " <> haltWord haltKind <> ": " <> sanitizeText reason <> "\n")
            }
      )
    setNotice ("Autosolve #" <> showText issueNumber <> " " <> haltWord haltKind <> ": " <> sanitizeText reason)
  where
    haltPhase AutoSolveHaltStopped = SolveAttention
    haltPhase AutoSolveHaltFailed = SolveFailedPhase
    haltWord AutoSolveHaltStopped = "stopped"
    haltWord AutoSolveHaltFailed = "failed"
    withAutoSolveProgress progress = withSessionDetail (\detail -> detail {solveSessionAutoProgress = Just progress})
    mapAutoSolveProgress advance = withSessionDetail (\detail -> detail {solveSessionAutoProgress = advance <$> detail.solveSessionAutoProgress})

-- | Autosolve's own review launch. It stays on the label-derived route, and
-- never the user's direct @r@ dispatch, so a problem status on the pull
-- request this loop is reviewing cannot turn an internal review round into a
-- repair launch.
startAutoSolveReview :: RepoSnapshot -> Int -> EventM Name AppState ()
startAutoSolveReview snapshot number =
  mapM_ (startPullRequestReviewWithVisibility False) (findSnapshotPullRequest snapshot number)
