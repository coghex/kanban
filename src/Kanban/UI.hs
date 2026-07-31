-- | The dashboard's composition root: it builds the initial state from the
-- cache, assembles the Brick 'App', and runs it.
--
-- Everything it composes lives in @Kanban.UI.*@ — 'Kanban.UI.Types' for the
-- state, 'Kanban.UI.Board' and 'Kanban.UI.Overlay' for drawing,
-- 'Kanban.UI.Events' for dispatch, and the session, worker, refresh, and
-- autosolve modules underneath them.
module Kanban.UI
  ( drawApplication,
    runDashboard,
  )
where


import Brick
import Brick.BChan (BChan, newBChan, writeBChan)
import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forever, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime, getCurrentTimeZone )
import qualified Graphics.Vty as Vty
import Kanban.Cache
  ( CacheLoad (..),
    UsageCacheLoad (..),
    loadRepositoryCache,
    loadUsageCache
    )
import Kanban.CLI (Options (..))
import Kanban.Config (LimitsConfig (..), ResolvedConfig (..) )
import Kanban.Domain
import Kanban.Drainer
  ( DrainerActivity (..),
    DrainerController,
    DrainerState (..),
    DrainerStatus (..),
    discoverDrainerController,
    queryDrainerStatus
    )
import Kanban.GitHub (snapshotWarnings)
import Kanban.Process (killManagedProcess, managedProcessStopsWithDashboard)
import Kanban.Review
  ( stopReviewClient
  )
import Kanban.Settings
  ( loadSettings
    )
import Kanban.Transcript (transcriptRoot)
import Kanban.Workflow (deriveBoard )
import Kanban.Worker
  ( discoverWorkers
    )
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.Theme
import Kanban.UI.Board
import Kanban.UI.Overlay
import Kanban.UI.Refresh
import Kanban.UI.PullRequest
import Kanban.UI.Reconcile
import Kanban.UI.Events

runDashboard :: Options -> ResolvedConfig -> Repository -> IO ()
runDashboard options config repository = do
  now <- getCurrentTime
  timeZone <- getCurrentTimeZone
  cacheLoad <-
    if cacheEnabled options config
      then loadRepositoryCache repository
      else pure CacheAbsent
  usageCacheLoad <-
    if cacheEnabled options config
      then loadUsageCache
      else pure UsageCacheAbsent
  drainerController <- discoverDrainerController repository
  (initialSettings, settingsNotice) <- loadSettings
  logRoot <- transcriptRoot repository
  eventChannel <- newBChan 256
  let (initialBoard, initialFreshness, initialFetchedAt, issuesTruncated, pullRequestsTruncated, initialNotice) = initialBoardState config.resolvedWorkflow config.resolvedLimits now cacheLoad
      (initialUsage, initialUsageFreshness, usageNotice) = initialUsageState usageCacheLoad
  let initialState =
        AppState
          { appRepository = repository,
            appBoard = initialBoard,
            appUsage = initialUsage,
            appUsageFreshness = initialUsageFreshness,
            appSelectedColumn = Issues,
            appSelectedRows = Map.fromList [(column, 0) | column <- allColumns],
            appEnsureSelectionVisible = True,
            appExpandedTrackers = Set.empty,
            appSidebarVisible = True,
            appSettings = initialSettings,
            appLogRoot = logRoot,
            appProcessSelection = ProcessSelection Nothing 0,
            appIncidentSelection = IncidentSelection Nothing 0,
            appOverlay = Nothing,
            appNotice = Just (initialNotice <> maybe "" (" · " <>) usageNotice <> maybe "" (" · " <>) settingsNotice),
            appBoardFreshness = initialFreshness,
            appLastSuccessfulFetch = initialFetchedAt,
            appIssuesTruncated = issuesTruncated,
            appPullRequestsTruncated = pullRequestsTruncated,
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
            appNow = now,
            appTimeZone = timeZone,
            appOptions = options,
            appConfig = config
          }
  (finalState, finalVty) <- customMainWithDefaultVty (Just eventChannel) application initialState
  case finalState.appReviewBackend of
    ReviewBackendReady client -> stopReviewClient client
    _ -> pure ()
  mapM_ killManagedProcess (filter managedProcessStopsWithDashboard (Map.elems finalState.appSolveProcesses))
  mapM_ killManagedProcess (Map.elems finalState.appCanonicalReviewProcesses)
  mapM_ killManagedProcess (filter managedProcessStopsWithDashboard (Map.elems finalState.appPullRequestProcesses))
  Vty.shutdown finalVty

initialBoardState :: WorkflowConfig -> LimitsConfig -> UTCTime -> CacheLoad -> (Board, Freshness, Maybe UTCTime, Bool, Bool, Text)
initialBoardState workflowConfig limits now cacheLoad = case cacheLoad of
  CacheLoaded snapshot ->
    ( deriveBoard workflowConfig snapshot,
      Fresh snapshot.snapshotFetchedAt,
      Just snapshot.snapshotFetchedAt,
      snapshot.snapshotIssuesTruncated,
      snapshot.snapshotPullRequestsTruncated,
      appendWarnings "Cached GitHub snapshot loaded · press u to update" (snapshotWarnings limits workflowConfig snapshot)
    )
  CacheAbsent ->
    ( deriveBoard workflowConfig (RepoSnapshot [] [] now False False),
      NotLoaded,
      Nothing,
      False,
      False,
      "No cached GitHub snapshot · press u to update"
    )
  CacheInvalid warning ->
    ( deriveBoard workflowConfig (RepoSnapshot [] [] now False False),
      NotLoaded,
      Nothing,
      False,
      False,
      warning <> " · press u to update"
    )

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
  threadDelay drainerRefreshIntervalMicros

drainerRefreshIntervalMicros :: Int
drainerRefreshIntervalMicros = 10 * 1000 * 1000
