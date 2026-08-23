-- | The dashboard's composition root: it builds the initial state, assembles
-- the Brick 'App', and runs it.
--
-- The board it starts with is empty and shows §7's centered loading panel,
-- not a persisted one. Open cards are live-only (§13): nothing is read from
-- the repository cache here, and there is no state in which the dashboard
-- renders a card that the current process did not fetch.
--
-- Everything it composes lives in @Kanban.UI.*@ — 'Kanban.UI.Types' for the
-- state, 'Kanban.UI.Board' and 'Kanban.UI.Overlay' for drawing,
-- 'Kanban.UI.Events' for dispatch, and the session, worker, refresh, and
-- autosolve modules underneath them.
module Kanban.UI
  ( drawApplication,
    initialCompletedHistory,
    loadStartupCaches,
    runDashboard,
    startupBoard,
    startupNotice,
  )
where


import Brick
import Brick.BChan (BChan, newBChan, writeBChan)
import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forever, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (newIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime, getCurrentTimeZone )
import qualified Graphics.Vty as Vty
import Kanban.ApprovalService
  ( ApprovalActivity (..),
    ApprovalState (..),
    ApprovalStatus (..),
    approvalUnavailableStatus,
    discoverApprovalController,
  )
import Kanban.Cache
  ( CompletedCacheLoad (..),
    UsageCacheLoad (..),
    loadCompletedCache,
    loadUsageCache
    )
import Kanban.CLI (Options (..))
import Kanban.Config (ResolvedConfig (..) )
import Kanban.Domain
import Kanban.Drainer
  ( DrainerActivity (..),
    DrainerController,
    DrainerState (..),
    DrainerStatus (..),
    discoverDrainerController,
    queryDrainerStatus
    )
import Kanban.GitHub (newHistoryTraversal)
import Kanban.Process (killManagedProcess, managedProcessStopsWithDashboard)
import Kanban.Review
  ( stopReviewClient
  )
import Kanban.Models (loadModelRoster)
import Kanban.Settings
  ( loadSettings
    )
import Kanban.Transcript (transcriptRoot)
import Kanban.Workflow (deriveBoard )
import Kanban.Worker
  ( discoverWorkers
    )
import Kanban.Filter (defaultFilterCriteria)
import Kanban.UI.Filter (refreshVisibleBoard)
import Kanban.UI.Keys (BoardAction (..), actionKeyText)
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.Theme
import Kanban.UI.Board
import Kanban.UI.Overlay
import Kanban.UI.Refresh
import Kanban.UI.PullRequest
import Kanban.UI.Events
import Kanban.UI.Approval (monitorApprovalService)

runDashboard :: Options -> ResolvedConfig -> Repository -> IO ()
runDashboard options config repository = do
  now <- getCurrentTime
  timeZone <- getCurrentTimeZone
  (usageCacheLoad, completedCacheLoad) <- loadStartupCaches options config repository
  drainerController <- discoverDrainerController repository
  approvalController <- discoverApprovalController repository
  approvalEpoch <- newIORef 0
  (initialSettings, settingsNotice) <- loadSettings
  -- Loaded once beside the resolved configuration and retained as-is. The
  -- agent-starting paths resolve their cell from the Right (MODEL-2) and
  -- refuse on the Left, which is why an unusable file must stay an error
  -- here rather than collapse into the compiled defaults (D-3). It stays a
  -- startup-only load: a resume replays what its session already recorded
  -- (MODEL-7) rather than rereading anything.
  modelRoster <- loadModelRoster
  logRoot <- transcriptRoot repository
  eventChannel <- newBChan 256
  historyTraversal <- newHistoryTraversal
  -- One coordinator per repository for the dashboard's lifetime, started
  -- before any refresh can be asked for. Every board-refresh entry point --
  -- startup, `u`, and the refreshes a finished review, solve, or
  -- pull-request action requires -- converges on 'startBoardRefresh' or
  -- 'requireBoardRefresh', so routing those two through it routes all of
  -- them (§15).
  refreshCoordinator <- newBoardRefreshCoordinator config repository historyTraversal eventChannel
  let (initialUsage, initialUsageFreshness, usageNotice) = initialUsageState usageCacheLoad
      (initialHistory, historyNotice) = initialCompletedHistory completedCacheLoad
  let initialState =
        AppState
          { appRepository = repository,
            appBoard = startupBoard config.resolvedWorkflow now,
            -- Set here so the record is complete, and settled by the
            -- 'refreshVisibleBoard' below, which is what admits a seeded
            -- history under criteria that ask for one.
            appVisibleBoard = startupBoard config.resolvedWorkflow now,
            -- Criteria are process-lifetime state: every launch starts at the
            -- defaults, and nothing restores a previous session's.
            appFilterCriteria = defaultFilterCriteria,
            -- Hidden at every launch. It is an editor for the criteria above,
            -- not part of them, so nothing about a previous session restores
            -- it either.
            appFilterPanel = Nothing,
            appUsage = initialUsage,
            appUsageFreshness = initialUsageFreshness,
            appSelectedColumn = Issues,
            appSelectedRows = Map.fromList [(column, 0) | column <- allColumns],
            appEnsureSelectionVisible = True,
            appExpandedTrackers = Set.empty,
            -- Search is presentation state, so a restart always starts with
            -- no query and the complete board.
            appSearch = Nothing,
            appSidebarVisible = True,
            appSettings = initialSettings,
            appModelRoster = modelRoster,
            -- Presentation state: the settings overlay seats this on its
            -- first roster row when it opens, and no launch restores a
            -- previous session's.
            appSettingsFocus = Nothing,
            appLogRoot = logRoot,
            appProcessSelection = ProcessSelection Nothing 0,
            appIncidentSelection = IncidentSelection Nothing 0,
            appOverlay = Nothing,
            appNotice =
              Just
                ( startupNotice
                    <> maybe "" (" · " <>) usageNotice
                    <> maybe "" (" · " <>) historyNotice
                    <> maybe "" (" · " <>) settingsNotice
                ),
            -- Nothing has been fetched and nothing was restored, which is
            -- exactly what §7's loading panel stands for. 'startApplication'
            -- moves this to 'Loading' the moment the startup refresh is
            -- requested; the panel is the same either way.
            appBoardFreshness = NotLoaded,
            appOpenSnapshot = Nothing,
            appLastSuccessfulFetch = Nothing,
            appOpenGeneration = 0,
            appHistoryTraversal = historyTraversal,
            -- A cached generation seeds the history without waiting for
            -- GitHub. It is complete by construction — nothing partial is ever
            -- written — so it is the history until the first live generation
            -- of this process replaces it.
            appCompletedHistory = initialHistory,
            appCompletedGeneration = 0,
            appCompletedProgress = emptyCompletedProgress,
            -- A seeded cache is complete by construction, so it is current
            -- until this process's own traversal claims a generation --
            -- which 'startApplication' does immediately, moving this to
            -- 'CompletedHistoryLoading' before the user can act on it.
            appCompletedStatus =
              case initialHistory of
                Just _ -> CompletedHistoryCurrent
                Nothing -> CompletedHistoryLoading,
            appDrainerController = drainerController,
            appDrainerStatus =
              case drainerController of
                -- Not 'DrainerServiceStarting': nothing has reported a state
                -- yet, and an action that may only run against a settled
                -- "off" must not read "no answer so far" as one.
                Right _ -> DrainerStatus DrainerStarting "checking…" DrainerServiceUnknown Nothing
                Left message -> drainerErrorStatus message,
            -- Nothing has been observed yet, and a failed discovery never
            -- will be: both must read as an unanswered source rather than as
            -- a drainer with no open incidents.
            appDrainerIncidents = Nothing,
            appDrainerBusy = False,
            appApprovalController = approvalController,
            appApprovalStatus =
              case approvalController of
                -- Not 'ApprovalServiceStopped': nothing has reported a state
                -- yet, and an interlock that may only permit work against a
                -- settled service must not read "no answer so far" as one.
                Right _ ->
                  ApprovalStatus ApprovalStarting "checking…" ApprovalServiceUnknown Nothing Nothing
                Left unavailable -> approvalUnavailableStatus unavailable,
            -- Nothing has been observed yet, and a failed discovery never
            -- will be: both read as an unanswered source rather than as a
            -- service with no open incidents.
            appApprovalIncidents = Nothing,
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
            appNow = now,
            appTimeZone = timeZone,
            appOptions = options,
            appConfig = config
          }
  (finalState, finalVty) <-
    customMainWithDefaultVty (Just eventChannel) application (refreshVisibleBoard initialState)
  case finalState.appReviewBackend of
    ReviewBackendReady client -> stopReviewClient client
    _ -> pure ()
  mapM_ killManagedProcess (filter managedProcessStopsWithDashboard (Map.elems finalState.appSolveProcesses))
  mapM_ killManagedProcess (Map.elems finalState.appCanonicalReviewProcesses)
  mapM_ killManagedProcess (filter managedProcessStopsWithDashboard (Map.elems finalState.appPullRequestProcesses))
  Vty.shutdown finalVty

-- | The whole of what the dashboard reads from the durable caches before it
-- draws anything: the usage cache and the completed history, and nothing else.
--
-- It is a seam rather than two inline lines because "startup consults no
-- /open/ snapshot" is a property worth asserting rather than reading off
-- 'runDashboard'. Completed history is the one thing that may be restored from
-- disk (§13, §16): every open card on screen was fetched by the process
-- showing it, and a snapshot an earlier release left behind is not loaded, not
-- decoded, not rewritten, and not removed — the version gate turns it away
-- without opening its payload.
--
-- @--no-cache@ and @cache = false@ suppress both reads together, which is what
-- makes them suppress the completed cache's write too: nothing seeded means
-- nothing to compare, and the write is guarded by the same predicate.
loadStartupCaches :: Options -> ResolvedConfig -> Repository -> IO (UsageCacheLoad, CompletedCacheLoad)
loadStartupCaches options config repository
  | cacheEnabled options config = (,) <$> loadUsageCache <*> loadCompletedCache repository
  | otherwise = pure (UsageCacheAbsent, CompletedCacheAbsent)

-- | The board the dashboard starts with: no issues, no pull requests, nothing
-- restored. §7's loading panel is drawn over it until the first complete
-- generation publishes, so nothing here ever reaches the screen as a card.
startupBoard :: WorkflowConfig -> UTCTime -> Board
startupBoard workflowConfig now = deriveBoard workflowConfig (RepoSnapshot [] [] now)

-- | What the notice line says before the startup refresh has answered. There
-- is no cached snapshot to report on either way, so it names the one thing
-- that is true: open data is being fetched, and @u@ asks again.
startupNotice :: Text
startupNotice = "Loading open GitHub data · press " <> actionKeyText RefreshAll <> " to update"

-- | What a stored completed generation seeds the dashboard with, and what it
-- has to say for itself.
--
-- Only the invalid case speaks. An absent cache is the ordinary first run and
-- says nothing; a loaded one is history the user cannot yet see, since nothing
-- renders from it until FILT-5.
initialCompletedHistory :: CompletedCacheLoad -> (Maybe CompletedHistory, Maybe Text)
initialCompletedHistory cacheLoad = case cacheLoad of
  CompletedCacheAbsent -> (Nothing, Nothing)
  CompletedCacheLoaded history -> (Just history, Nothing)
  CompletedCacheInvalid warning -> (Nothing, Just warning)

initialUsageState :: UsageCacheLoad -> (Map UsageProvider UsageSnapshot, Map UsageProvider Freshness, Maybe Text)
initialUsageState cacheLoad = case cacheLoad of
  UsageCacheAbsent -> (Map.empty, defaultFreshness Map.empty, Nothing)
  UsageCacheLoaded snapshots -> (snapshots, defaultFreshness snapshots, Nothing)
  UsageCacheInvalid warning -> (Map.empty, defaultFreshness Map.empty, Just warning)
  where
    defaultFreshness :: Map UsageProvider UsageSnapshot -> Map UsageProvider Freshness
    defaultFreshness snapshots =
      Map.fromList
        [ (Codex, maybe NotLoaded (Fresh . (.usageFetchedAt)) (Map.lookup Codex snapshots)),
          (Claude, maybe NotLoaded (Fresh . (.usageFetchedAt)) (Map.lookup Claude snapshots))
        ]

application :: App AppState AppEvent Name
application =
  App
    { appDraw = drawApplication,
      appChooseCursor = neverShowCursor,
      appHandleEvent = handleEvent,
      appStartEvent = startApplication,
      appAttrMap = themeFor . (.appOptions)
    }

drawApplication :: AppState -> [Widget Name]
drawApplication state =
  case state.appOverlay of
    Nothing -> [drawBase state]
    Just overlay -> [drawOverlay state overlay, drawBase state]

startApplication :: EventM Name AppState ()
startApplication = do
  vty <- getVtyHandle
  liftIO (enableMouseIfSupported (Vty.outputIface vty))
  startAllRefreshes
  state <- get
  void . liftIO . forkIO $ discoverWorkers state.appRepository >>= writeBChan state.appEventChannel . WorkerDiscoveryFinished
  case state.appDrainerController of
    Left _ -> pure ()
    Right controller ->
      void
        . liftIO
        . forkIO
        $ monitorDrainer controller state.appEventChannel
  case state.appApprovalController of
    Left _ -> pure ()
    Right controller ->
      void
        . liftIO
        . forkIO
        $ monitorApprovalService
          state.appRepository
          controller
          serviceStatusIntervalMicros
          state.appApprovalEpoch
          state.appEventChannel

-- | Mouse reporting is an optional affordance on a dashboard that must stay
-- fully keyboard-operable (docs\/design.md §2), and vty exposes mode support
-- as a queryable capability precisely because setting an unsupported mode is
-- not guaranteed to be harmless. Asking first means a terminal without mouse
-- reporting simply starts with the mouse features inert, rather than risking
-- the whole startup over an affordance nothing depends on.
enableMouseIfSupported :: Vty.Output -> IO ()
enableMouseIfSupported output =
  when (Vty.supportsMode output Vty.Mouse) (Vty.setMode output Vty.Mouse True)

monitorDrainer :: DrainerController -> BChan AppEvent -> IO ()
monitorDrainer controller eventChannel = forever $ do
  queryDrainerStatus controller >>= writeBChan eventChannel . DrainerStatusRefreshed
  threadDelay serviceStatusIntervalMicros

-- | How often each managed service's status is read. One constant for both,
-- because the approval service is polled on the same cadence as the PR drainer
-- (requirement 4) and two constants would be two cadences the moment one was
-- edited.
serviceStatusIntervalMicros :: Int
serviceStatusIntervalMicros = 10 * 1000 * 1000
