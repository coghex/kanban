module Kanban.UI.Reconcile
  ( appendWarnings,
    applyBoardHistory,
    applyBoardRefresh,
    applyClaudeRefresh,
    applyCodexRefresh,
    boardRefreshOutcomeApplied,
    commitRefreshedUsage,
    currentCompletedGeneration,
    currentOpenGeneration,
    failureFreshness,
    reconcilePullRequestSessions,
    reconcileReviewSessions,
    refreshSuccessNotice,
    unverifiedRefreshNotice,
    usageRefreshApplied,
  )
where


import Brick
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime)
import Kanban.Cache
  ( commitUsageSnapshots,
    usageCommitNotes,
    writeCompletedCache
  )
import Kanban.CLI (Options (..))
import Kanban.Config (ResolvedConfig (..) )
import Kanban.Domain
import Kanban.GitHub (GhCleanupFailure (..), GhCleanupGuard (..), GitHubResult (..), HistoryOutcome (..) )
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.Review
  ( ReviewStage (..)
    )
import Kanban.Solve
  ( SolveWorkflow (..)
    )
import Kanban.Text (sanitizeText)
import Kanban.Workflow (deriveBoard )
import Kanban.UI.Filter (refreshVisibleBoard)
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.SessionCore
import Kanban.UI.State
import Kanban.UI.AutoSolve
import Kanban.UI.Search
import Kanban.UI.Selection
import Kanban.UI.SessionEvents
import Kanban.UI.Refresh
import Kanban.UI.Solve
import Kanban.UI.PullRequest
import Kanban.UI.Worker

-- | Applies one open generation's outcome, or drops it.
--
-- An outcome older than the newest generation this board has seen start is
-- discarded whole: not applied partially, not merged, not allowed to move the
-- freshness. The board it would have replaced belongs to the generation that
-- superseded it, and a superseded answer arriving late is one nobody is
-- waiting for (§15). Everything below therefore runs only for the current
-- generation, which is what makes a publication atomic as well as ordered —
-- selection, overlay, sessions, and notice all move together or not at all.
applyBoardRefresh :: OpenGeneration -> BoardRefreshOutcome -> EventM Name AppState ()
applyBoardRefresh generation outcome = do
  current <- get
  when (currentOpenGeneration current.appOpenGeneration generation) (applyCurrentBoardRefresh outcome)

-- | Whether an outcome arriving under @arriving@ is still the answer the
-- board is waiting for, given that @newest@ is the newest generation it has
-- seen start.
--
-- The whole of requirement 9's ordering rule, as one total decision the arm
-- above only projects. It is @>=@ rather than @==@ deliberately: a request
-- that expired without ever starting is answered under an identity no
-- 'BoardRefreshStarted' announced, and that answer is owed to the caller just
-- as much as a fetched one.
currentOpenGeneration :: OpenGeneration -> OpenGeneration -> Bool
currentOpenGeneration newest arriving = arriving >= newest

applyCurrentBoardRefresh :: BoardRefreshOutcome -> EventM Name AppState ()
applyCurrentBoardRefresh outcome = do
  before <- get
  -- Which result was selected before the refresh, so a live query can be
  -- re-run against the new board and still keep that card selected. Read
  -- here because the refresh below replaces the board it was read off.
  let searchAnchor = ((.searchColumn) <$> before.appSearch) >>= selectedAnchorIn before
  modify (boardRefreshOutcomeApplied outcome)
  finishCurrentBoardRefresh before searchAnchor outcome

-- | What one open outcome does to the state: the board, the freshness, and
-- the notice reporting it. Pure, and exported, so the suite can take the
-- publication the startup carry composes over through the very transition
-- the event runs.
boardRefreshOutcomeApplied :: BoardRefreshOutcome -> AppState -> AppState
boardRefreshOutcomeApplied outcome state = case outcome of
    -- Once the unconfirmed group is on disk, 'fetchGitHubSnapshot'
    -- re-verifies it before spawning anything, so a later refresh -- in this
    -- process or in one started after a restart -- cannot overlap it, and the
    -- board is free to sit in an ordinary failure state that self-heals as
    -- soon as the group is confirmed gone. Without that record the in-memory
    -- refusal is all that is left, so 'appBoardFreshness' stays 'Loading' and
    -- 'startBoardRefresh' keeps turning further fetches away.
    BoardRefreshUnverified failure
      | GuardRecorded <- failure.ghCleanupGuard ->
          noticeSet
            (unverifiedRefreshNotice failure)
            state {appBoardFreshness = failureFreshness state.appLastSuccessfulFetch (unverifiedProviderError failure)}
      | otherwise -> noticeSet (unverifiedRefreshNotice failure) state
    BoardRefreshCompleted (Left providerError) ->
      noticeSet
        (renderProviderError providerError)
        state {appBoardFreshness = failureFreshness state.appLastSuccessfulFetch providerError}
    BoardRefreshCompleted (Right githubResult) ->
      let snapshot = githubResult.githubSnapshot
          -- The datasets first, then the view they admit: the completed
          -- history is reconciled against this generation before the criteria
          -- are applied, so a reopened item is never briefly admitted as
          -- history and as live work at once.
          --
          -- This generation published second, so it answers for every item it
          -- lists: one GitHub has just reported open leaves the completed set
          -- rather than standing in both. The open board is derived from the
          -- snapshot untouched, which is what keeps a reopened item from
          -- waiting for the next completed generation before it can appear as
          -- open work.
          refreshed =
            refreshVisibleBoard
              state
                { appBoard = deriveBoard state.appConfig.resolvedWorkflow snapshot,
                  appOpenSnapshot = Just snapshot,
                  appCompletedHistory = historyWithoutOpen snapshot <$> state.appCompletedHistory
                }
          -- Both are decided against what the criteria admit, because both
          -- resolve a row the user is looking at: the selection is an index
          -- into the visible view, and a details overlay held open on a card
          -- that view still shows must not be closed as absent.
          (selectedColumn, selectedRows) = preserveSelection state refreshed.appVisibleBoard
          (refreshedOverlay, overlayNotice) = refreshOverlay refreshed.appVisibleBoard state.appOverlay
          refreshedReviewSessions = reconcileReviewSessions state.appConfig.resolvedWorkflow snapshot.snapshotIssues state.appReviewSessions
          refreshedPullRequestSessions = reconcilePullRequestSessions snapshot.snapshotPullRequests state.appPullRequestReviewSessions
          successNotice = refreshSuccessNotice snapshot githubResult.githubWarnings
       in noticeSet
            (maybe successNotice (<> (" · " <> successNotice)) overlayNotice)
            refreshed
              { appSelectedColumn = selectedColumn,
                appSelectedRows = selectedRows,
                appOverlay = refreshedOverlay,
                appReviewSessions = refreshedReviewSessions,
                appPullRequestReviewSessions = refreshedPullRequestSessions,
                appBoardFreshness = Fresh snapshot.snapshotFetchedAt,
                appLastSuccessfulFetch = Just snapshot.snapshotFetchedAt
              }

finishCurrentBoardRefresh :: AppState -> Maybe SearchAnchor -> BoardRefreshOutcome -> EventM Name AppState ()
finishCurrentBoardRefresh before searchAnchor outcome = do
  -- The query is re-run against the new board by 'entriesFor' itself; what
  -- needs deciding is where the selection lands in the result. The target
  -- column stays both the searched and the selected one whatever the refresh
  -- did to the item, because the generic 'preserveSelection' above is allowed
  -- to move columns and this phase's search cannot follow it. A no-op with no
  -- search open, and a no-op after a failed refresh, which changes no board.
  modify (reseatSearch searchAnchor)
  -- Applied over whichever notice the outcome above produced, so a merge that
  -- landed is still reported once the refresh it required has published --
  -- above all a merge whose post-merge work then failed, which this is the
  -- only place the user is ever told about.
  modify (directMergeCarryApplied before)
  -- And the startup diagnostics, riding the line the outcome just replaced:
  -- the first publication composes them onto its own settled notice for the
  -- ordinary ten seconds and retires the carry ('startupReportApplied').
  modify (startupReportApplied before)
  startPendingWorkerMonitors
  case outcome of
    BoardRefreshCompleted (Right githubResult) -> advanceAutoSolves githubResult.githubSnapshot
    _ -> pure ()
  startQueuedBoardRefresh

-- | Applies one completed generation's outcome, or drops it.
--
-- The generation check is the same rule the open path uses and for the same
-- reason, with one difference: a completed identity is claimed by the board
-- itself, synchronously, before the job that answers under it is queued. So
-- the newest identity is never behind an arriving one, and anything other than
-- an exact match is an outcome for a generation some later request already
-- superseded — which requirement 4 keeps out of both the in-memory history and
-- the cache.
applyBoardHistory :: CompletedGeneration -> HistoryOutcome -> EventM Name AppState ()
applyBoardHistory generation outcome = do
  current <- get
  when (currentCompletedGeneration current.appCompletedGeneration generation) $ case outcome of
    -- A page answering is also how a paused traversal reports that it has
    -- resumed: nothing else marks the end of a pause, and the status has to
    -- stop saying paused when the work starts again.
    HistoryProgressed progress ->
      modify (\state -> state {appCompletedProgress = progress, appCompletedStatus = CompletedHistoryLoading})
    -- The last complete history is deliberately untouched. A generation that
    -- failed proves nothing about the one that succeeded before it, and with
    -- no complete generation behind it the history is simply absent (§15) --
    -- which is the whole difference between a stale history and a failed one.
    HistoryFailed providerError ->
      modify (\state -> state {appCompletedStatus = completedFailureStatus state (renderProviderErrorMessage providerError)})
    HistoryCompleted history -> publishCompletedHistory history

-- | Where a failed completed generation leaves the status: 'stale' over a
-- complete history that still stands, and 'failed' when there is none to fall
-- back to. Nothing partial is ever a fallback, so the presence of a history at
-- all is the whole test (§15).
completedFailureStatus :: AppState -> Text -> CompletedHistoryStatus
completedFailureStatus state reason
  | isJust state.appCompletedHistory = CompletedHistoryStale reason
  | otherwise = CompletedHistoryFailed reason

-- | Whether an outcome arriving under @arriving@ still answers the generation
-- the board is waiting for, given that @newest@ is the newest identity it has
-- claimed.
currentCompletedGeneration :: CompletedGeneration -> CompletedGeneration -> Bool
currentCompletedGeneration newest arriving = arriving == newest

-- | Publishes a whole completed generation: to disk when caching is on, to
-- memory always, and to the open board when the two sets overlap.
--
-- Publishing in memory does not wait on the cache. The cache is an
-- optimisation the user may switch off entirely, so a write that fails leaves
-- the generation that succeeded in memory and says what went wrong, rather
-- than discarding a complete history over a file (§16).
publishCompletedHistory :: CompletedHistory -> EventM Name AppState ()
publishCompletedHistory history = do
  state <- get
  cacheWarning <-
    if cacheEnabled state.appOptions state.appConfig
      then either Just (const Nothing) <$> liftIO (writeCompletedCache state.appRepository history)
      else pure Nothing
  publishBoardData $ \current ->
    -- This generation published second, so an open card it proves settled is
    -- stale and leaves the open set (§15). With no overlap the reconciled
    -- snapshot is the one already stored and the open board is never
    -- re-derived at all.
    let reconciledSnapshot = openWithoutHistory history <$> current.appOpenSnapshot
     in current
          { appCompletedHistory = Just history,
            appCompletedStatus = CompletedHistoryCurrent,
            appCompletedProgress = completedHistoryProgress history,
            appOpenSnapshot = reconciledSnapshot,
            appBoard = case reconciledSnapshot of
              Just reconciled
                | Just reconciled /= current.appOpenSnapshot ->
                    deriveBoard current.appConfig.resolvedWorkflow reconciled
              _ -> current.appBoard
          }
  mapM_ (modify . noticeSetOverStartupReport . ("Completed history cached with a warning · " <>)) cacheWarning

-- | What a published generation reports as its progress: complete, with the
-- totals read off the history itself rather than off the pages that built it.
completedHistoryProgress :: CompletedHistory -> CompletedProgress
completedHistoryProgress history =
  CompletedProgress
    { completedIssuesLoaded = issues,
      completedIssuesTotal = Just issues,
      completedPullRequestsLoaded = pullRequests,
      completedPullRequestsTotal = Just pullRequests
    }
  where
    issues = length history.historyIssues
    pullRequests = length history.historyPullRequests

-- | Applies a change to the board's datasets, recomputes the view the filter
-- criteria admit, and re-seats everything that indexes that view — but only
-- when the view actually moved.
--
-- The guard is what keeps a completed publication invisible under the default
-- criteria. Reconciling unconditionally would reach the identical answer in
-- the overwhelmingly common case, and would also re-run selection, search, and
-- overlay reconciliation every time a background generation published —
-- behavior a hidden history must not have.
publishBoardData :: (AppState -> AppState) -> EventM Name AppState ()
publishBoardData change = do
  before <- get
  put (refreshVisibleBoard (change before))
  after <- get
  when (after.appVisibleBoard /= before.appVisibleBoard) $ do
    let searchAnchor = ((.searchColumn) <$> before.appSearch) >>= selectedAnchorIn before
    modify $ \state ->
      let (selectedColumn, selectedRows) = preserveSelection before state.appVisibleBoard
          (reconciledOverlay, overlayNotice) = refreshOverlay state.appVisibleBoard state.appOverlay
       in -- The notice only when an overlay actually closed under the user.
          -- Nothing else about a completed publication is worth the notice
          -- line: reporting the history itself is the footer's own compact
          -- status, which outlives every press that clears a notice.
          maybe id noticeSet overlayNotice $
            state
              { appSelectedColumn = selectedColumn,
                appSelectedRows = selectedRows,
                appOverlay = reconciledOverlay
              }
    modify (reseatSearch searchAnchor)

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
          noticeSetOverStartupReport
            (displayName <> " usage refresh failed: " <> renderProviderErrorMessage providerError)
            state {appUsageFreshness = Map.insert provider (usageFailureFreshness provider state providerError) state.appUsageFreshness}
      )
  Right snapshot -> do
    state <- get
    cacheNotes <- liftIO (commitRefreshedUsage (cacheEnabled state.appOptions state.appConfig) provider snapshot)
    modify (usageRefreshApplied provider displayName cacheNotes snapshot)

-- | What one provider's successful refresh does to the state, split from the
-- cache commit above it so the suite can take the transition — the snapshot,
-- the freshness, and the notice it produces, composed onto the startup line
-- while that is still carrying its diagnostics — without touching a cache
-- file.
usageRefreshApplied :: UsageProvider -> Text -> [Text] -> UsageSnapshot -> AppState -> AppState
usageRefreshApplied provider displayName cacheNotes snapshot state =
  noticeSetOverStartupReport
    (displayName <> " usage refreshed" <> Text.concat (map (" · " <>) cacheNotes))
    state
      { appUsage = Map.insert provider snapshot state.appUsage,
        appUsageFreshness = Map.insert provider (Fresh snapshot.usageFetchedAt) state.appUsageFreshness
      }

-- | Everything a provider refresh does to the snapshot cache, outside
-- 'EventM'.
--
-- The dashboard holds a usage map for the whole process lifetime, seeded once
-- at launch, so the entry it carries for the provider that did /not/ just
-- refresh is as old as the session. Writing that map back is how a refresh in
-- another process was reverted (issue #477), so only the provider that
-- actually refreshed is handed over and the merge happens against what is
-- committed at that moment. That is also why the in-process map above is
-- updated separately: it is what the sidebar draws, not what the file holds.
--
-- It is a plain 'IO' seam rather than two lines inline because it is the arm's
-- entire contact with the cache, and no test here can drive an 'EventM'. There
-- is no whole-map usage writer left in "Kanban.Cache" for the arm to reach
-- instead.
commitRefreshedUsage :: Bool -> UsageProvider -> UsageSnapshot -> IO [Text]
commitRefreshedUsage cacheOn provider snapshot
  | not cacheOn = pure []
  | otherwise = usageCommitNotes <$> commitUsageSnapshots (Map.singleton provider snapshot)

usageFailureFreshness :: UsageProvider -> AppState -> ProviderError -> Freshness
usageFailureFreshness provider state providerError = case Map.lookup provider state.appUsage of
  Just snapshot -> Stale snapshot.usageFetchedAt providerError.providerErrorMessage
  Nothing -> case providerError.providerErrorKind of
    UnsupportedVersion -> Unsupported providerError.providerErrorMessage
    _ -> Unavailable providerError.providerErrorMessage

-- | Where a failed board refresh leaves the freshness: 'Stale' over the last
-- complete generation, or 'Unavailable' when none has ever published.
--
-- The classified rendering is what is stored rather than the bare message,
-- because 'Unavailable' is now read back and shown: §7's centered
-- @OPEN DATA UNAVAILABLE@ panel is the whole of what a failed first load
-- displays, so the reason it carries has to name the kind — @AUTH REQUIRED@,
-- @TIMED OUT@, @RATE LIMITED@ — exactly as the notice line does.
failureFreshness :: Maybe UTCTime -> ProviderError -> Freshness
failureFreshness lastSuccessfulFetch providerError = case lastSuccessfulFetch of
  Just fetchedAt -> Stale fetchedAt (renderProviderErrorMessage providerError)
  Nothing -> Unavailable (renderProviderErrorMessage providerError)

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
      RateLimited -> "RATE LIMITED"
      RequestFailed -> "REQUEST ERROR"

refreshSuccessNotice :: RepoSnapshot -> [Text] -> Text
refreshSuccessNotice snapshot warnings =
  "GitHub refreshed · "
    <> countedSource "issue" (length snapshot.snapshotIssues)
    <> " · "
    <> countedSource "PR" (length snapshot.snapshotPullRequests)
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
    -- The turn itself is declared once, beside the decision that asks for it
    -- ('Kanban.UI.AutoSolve.autoSolveRevisionTurn'), and the plain-IO action
    -- registry starts the same one: the session to resume, the provenance,
    -- and the prompt are one construction rather than this adapter's and the
    -- registry's.
    let revision =
          autoSolveRevisionTurn
            state.appConfig.resolvedWorkflow
            state.appOptions.optionConfig
            state.appRepository
            session.sessionDetail.solveSessionBrand
            session.sessionDetail.solveSessionId
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
      ( \turn ->
          launchSolveInvocation
            issueNumber
            AutoSolve
            session.sessionDetail.solveSessionBrand
            (Just turn.autoSolveRevisionSession)
            turn.autoSolveRevisionProvenance
            turn.autoSolveRevisionMessage
      )
      revision
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
