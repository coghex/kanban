module Kanban.UI
  ( PendingReviewInteraction (..),
    ReviewDigitAction (..),
    pullRequestSessionReusable,
    resolveReviewDigitAction,
    runDashboard,
  )
where

import Brick
import Brick.BChan (BChan, newBChan, writeBChan)
import Brick.Widgets.Border (borderWithLabel, hBorder, hBorderWithLabel, vBorder)
import Brick.Widgets.Border.Style (BorderStyle (..), ascii, unicode, unicodeBold)
import Brick.Widgets.Center (centerLayer)
import qualified Brick.Types as BrickTypes
import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forever, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.Char (isPrint)
import Data.List (find, findIndex, intersperse, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (TimeZone, UTCTime, addUTCTime, defaultTimeLocale, diffUTCTime, formatTime, getCurrentTime, getCurrentTimeZone, utcToZonedTime)
import qualified Graphics.Vty as Vty
import Kanban.Cache
  ( CacheLoad (..),
    UsageCacheLoad (..),
    loadRepositoryCache,
    loadUsageCache,
    writeRepositoryCache,
    writeUsageCache,
  )
import Kanban.CLI (BorderPolicy (..), ColorPolicy (..), Options (..))
import Kanban.Claude (fetchClaudeUsage)
import Kanban.Codex (fetchCodexUsage)
import Kanban.Domain
import Kanban.Drainer
  ( DrainerController,
    DrainerState (..),
    DrainerStatus (..),
    discoverDrainerController,
    drainerIsRunning,
    queryDrainerStatus,
    setDrainerRunning,
  )
import Kanban.GitHub (GitHubResult (..), fetchGitHubSnapshot, snapshotWarnings)
import Kanban.Layout (responsiveColumnWidths, responsiveOpenColumnWidths)
import Kanban.Process (ManagedProcess, interruptManagedProcess, killManagedProcess, managedProcessGroup, managedProcessStopsWithDashboard)
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.PullRequestFlow
  ( PullRequestAction (..),
    PullRequestFlowEvent (..),
    PullRequestOrigin (..),
    PullRequestVerdict (..),
    actionForLabels,
    agentForAction,
    originFromBody,
    pullRequestVerdictForLabels,
  )
import Kanban.Review
  ( CanonicalIssueReviewResult (..),
    ReviewAnswer (..),
    ReviewApproval (..),
    ReviewChoice (..),
    ReviewClient,
    ReviewEvent (..),
    ReviewOutputKind (..),
    ReviewQuestion (..),
    ReviewQuestionKind (..),
    ReviewRequestId,
    ReviewResult (..),
    ReviewStage (..),
    ReviewTurnOutcome (..),
    answerReviewQuestion,
    approveReviewAction,
    beginIssueReview,
    interruptReview,
    killReviewTools,
    reviewStageForLabels,
    renderCanonicalIssueReviewResult,
    runCanonicalIssueReview,
    renderReviewResult,
    sendReviewMessage,
    startReviewClient,
    stopReviewClient,
  )
import Kanban.Solve
  ( AgentEvent (..),
    SolveEvent (..),
    SolveOutcome (..),
    SolveWorkflow (..),
    SolverBrand (..),
    claudeReviewerModel,
    claudeSolverModel,
    codexReviewerModel,
    codexSolverModel,
    renderAgentEvent,
    solverLabel,
  )
import Kanban.Settings
  ( ChatVerbosity (..),
    Settings (..),
    loadSettings,
    saveSettings,
    verbosityDescription,
    verbosityLabel,
  )
import Kanban.Text (excerpt, sanitizeText)
import Kanban.Transcript (transcriptRoot)
import Kanban.Tracker (renderTrackerDiagnostic, trackerDiagnosticsForIssue)
import Kanban.Workflow (CardStatus (..), deriveBoard, entryItem, isApproved, isProblem, pullRequestStatus)
import Kanban.Worker
  ( ProcessIdentity,
    PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerDescriptor (..),
    WorkerEvent (..),
    WorkerId,
    WorkerParent (..),
    WorkerSpec (..),
    WorkerTask (..),
    acknowledgeSupersededWorkers,
    discoverWorkers,
    launchPullRequestWorker,
    launchSolveWorker,
    monitorWorker,
    pendingTerminationDiagnosticPrefix,
    terminateWorker,
  )
import System.Timeout (timeout)

data Name
  = BoardViewport
  | ColumnViewport BoardColumn
  | DetailsViewport
  | ReviewViewport
  | SolveViewport
  | PullRequestReviewViewport
  | ProcessesViewport
  | CardTarget BoardColumn Int
  | EpicTarget BoardColumn Int Int
  | DetailsPanel
  | ReviewPanel
  | SolvePanel
  | PullRequestReviewPanel
  | ProcessesPanel
  | ProcessTarget Int
  | DrainerButton
  deriving stock (Eq, Ord, Show)

data Overlay
  = HelpOverlay
  | SettingsOverlay
  | ProcessesOverlay
  | DetailsOverlay BoardItem
  | ReviewOverlay Int
  | SolveChooser SolveWorkflow Issue
  | SolveOverlay Int
  | PullRequestReviewOverlay Int
  deriving stock (Eq, Show)

data SolvePhase
  = SolveStarting
  | SolveRunning
  | SolveInterrupting
  | SolveAttention
  | SolveFinished
  | SolveFailedPhase
  | SolveKilledPhase
  | SolveOrphanedPhase
  deriving stock (Eq, Show)

data AutoSolveStage
  = AutoImplementing
  | AutoDiscoveringPullRequest
  | AutoReviewing
  | AutoRevising
  | AutoAwaitingRereview
  | AutoSolveComplete
  | AutoSolveStopped
  deriving stock (Eq, Show)

data AutoSolveProgress = AutoSolveProgress
  { autoSolveStage :: AutoSolveStage,
    autoSolvePullRequest :: Maybe Int,
    autoSolveReviewRound :: Int,
    autoSolveKnownPullRequests :: Set Int,
    autoSolveStartedAt :: UTCTime
  }
  deriving stock (Eq, Show)

data ChatTranscript = ChatTranscript
  { compactTranscript :: Text,
    standardTranscript :: Text,
    fullTranscript :: Text
  }
  deriving stock (Eq, Show)

data SolveSession = SolveSession
  { solveSessionIssue :: Issue,
    solveSessionWorkflow :: SolveWorkflow,
    solveSessionBrand :: SolverBrand,
    solveSessionId :: Maybe Text,
    solveSessionPhase :: SolvePhase,
    solveSessionActivity :: Text,
    solveSessionActivityStartedAt :: UTCTime,
    solveSessionLogPath :: Maybe FilePath,
    solveSessionTranscript :: ChatTranscript,
    solveSessionInput :: Text,
    solveSessionSpinnerFrame :: Int,
    solveSessionAutoProgress :: Maybe AutoSolveProgress
  }
  deriving stock (Eq, Show)

data PullRequestReviewSession = PullRequestReviewSession
  { pullRequestSessionPullRequest :: PullRequest,
    pullRequestSessionOrigin :: PullRequestOrigin,
    pullRequestSessionAction :: PullRequestAction,
    -- | The PR's @updatedAt@ when this action was launched, so a finished
    -- session with the same recomputed action (e.g. a second
    -- reviewed:changes verdict after pr-revise's own rereview) can be told
    -- apart from one still addressing the state it was launched for.
    pullRequestSessionLaunchedForUpdatedAt :: UTCTime,
    pullRequestSessionBrand :: SolverBrand,
    pullRequestSessionId :: Maybe Text,
    pullRequestSessionPhase :: SolvePhase,
    pullRequestSessionActivity :: Text,
    pullRequestSessionActivityStartedAt :: UTCTime,
    pullRequestSessionLogPath :: Maybe FilePath,
    pullRequestSessionTranscript :: ChatTranscript,
    pullRequestSessionInput :: Text,
    pullRequestSessionSpinnerFrame :: Int
  }
  deriving stock (Eq, Show)

data ReviewPhase
  = ReviewStarting
  | ReviewRunning
  | ReviewWaiting
  | ReviewFinished
  | ReviewNeedsChanges
  | ReviewFailed
  | ReviewInterrupted
  deriving stock (Eq, Show)

data PendingReviewInteraction
  = PendingReviewQuestion ReviewRequestId ReviewQuestion
  | PendingReviewApproval ReviewRequestId ReviewApproval
  deriving stock (Eq, Show)

data ReviewSession = ReviewSession
  { reviewSessionIssue :: Issue,
    reviewSessionStage :: ReviewStage,
    reviewSessionThreadId :: Maybe Text,
    reviewSessionTurnId :: Maybe Text,
    reviewSessionPhase :: ReviewPhase,
    reviewSessionActivity :: Text,
    reviewSessionTranscript :: ChatTranscript,
    reviewSessionPending :: Maybe PendingReviewInteraction,
    reviewSessionInput :: Text,
    reviewSessionSpinnerFrame :: Int
  }
  deriving stock (Eq, Show)

data ReviewBackend
  = ReviewBackendStopped
  | ReviewBackendStarting
  | ReviewBackendReady ReviewClient
  | ReviewBackendFailed Text

data AgentSessionRef
  = SolveAgent Int
  | PullRequestAgent Int
  | ReviewAgent Int
  | WorkerAgent WorkerId
  deriving stock (Eq, Show)

data AgentSessionEntry = AgentSessionEntry
  { agentSessionRef :: AgentSessionRef,
    agentSessionLabel :: Text,
    agentSessionProvider :: Text,
    agentSessionStatus :: Text,
    agentSessionActivity :: Text,
    agentSessionId :: Maybe Text,
    agentSessionLive :: Bool,
    agentSessionProblem :: Bool
  }
  deriving stock (Eq, Show)

data AppEvent
  = BoardRefreshFinished (Either ProviderError GitHubResult)
  | CodexRefreshFinished (Either ProviderError UsageSnapshot)
  | ClaudeRefreshFinished (Either ProviderError UsageSnapshot)
  | DrainerStatusRefreshed (Either Text DrainerStatus)
  | DrainerToggleFinished (Either Text DrainerStatus)
  | ReviewBackendStarted (Either Text ReviewClient)
  | ReviewProtocolEvent ReviewEvent
  | ReviewAnimationTick Text
  | SolveProtocolEvent SolveEvent
  | SolveAnimationTick Int
  | SolveBoardRefreshRequested
  | PullRequestProtocolEvent PullRequestFlowEvent
  | PullRequestAnimationTick Int
  | WorkerRegistered WorkerDescriptor
  | WorkerProtocolEvent WorkerDescriptor WorkerEvent
  | WorkerDiscoveryFinished [WorkerDescriptor]
  | CanonicalIssueReviewProcessStarted Int ManagedProcess
  | CanonicalIssueReviewFinished Int ReviewStage (Either Text CanonicalIssueReviewResult)

data AppState = AppState
  { appRepository :: Repository,
    appBoard :: Board,
    appUsage :: Map UsageProvider UsageSnapshot,
    appUsageFreshness :: Map UsageProvider Freshness,
    appSelectedColumn :: BoardColumn,
    appSelectedRows :: Map BoardColumn Int,
    appEnsureSelectionVisible :: Bool,
    appExpandedTrackers :: Set Int,
    appSidebarVisible :: Bool,
    appSettings :: Settings,
    appLogRoot :: FilePath,
    appProcessSelection :: Int,
    appOverlay :: Maybe Overlay,
    appNotice :: Maybe Text,
    appBoardFreshness :: Freshness,
    appLastSuccessfulFetch :: Maybe UTCTime,
    appIssuesTruncated :: Bool,
    appPullRequestsTruncated :: Bool,
    appDrainerController :: Either Text DrainerController,
    appDrainerStatus :: DrainerStatus,
    appDrainerBusy :: Bool,
    appReviewBackend :: ReviewBackend,
    appReviewSessions :: Map Int ReviewSession,
    appSolveSessions :: Map Int SolveSession,
    appSolveProcesses :: Map Int ManagedProcess,
    appCanonicalReviewProcesses :: Map Int ManagedProcess,
    appPullRequestReviewSessions :: Map Int PullRequestReviewSession,
    appPullRequestProcesses :: Map Int ManagedProcess,
    appWorkers :: Map WorkerId WorkerDescriptor,
    appWorkerMonitors :: Set WorkerId,
    appEventChannel :: BChan AppEvent,
    appNow :: UTCTime,
    appTimeZone :: TimeZone,
    appOptions :: Options
  }

runDashboard :: Options -> Repository -> IO ()
runDashboard options repository = do
  now <- getCurrentTime
  timeZone <- getCurrentTimeZone
  cacheLoad <-
    if options.optionNoCache
      then pure CacheAbsent
      else loadRepositoryCache repository
  usageCacheLoad <-
    if options.optionNoCache
      then pure UsageCacheAbsent
      else loadUsageCache
  drainerController <- discoverDrainerController repository
  (initialSettings, settingsNotice) <- loadSettings
  logRoot <- transcriptRoot repository
  eventChannel <- newBChan 256
  let (initialBoard, initialFreshness, initialFetchedAt, issuesTruncated, pullRequestsTruncated, initialNotice) = initialBoardState now cacheLoad
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
            appProcessSelection = 0,
            appOverlay = Nothing,
            appNotice = Just (initialNotice <> maybe "" (" · " <>) usageNotice <> maybe "" (" · " <>) settingsNotice),
            appBoardFreshness = initialFreshness,
            appLastSuccessfulFetch = initialFetchedAt,
            appIssuesTruncated = issuesTruncated,
            appPullRequestsTruncated = pullRequestsTruncated,
            appDrainerController = drainerController,
            appDrainerStatus =
              case drainerController of
                Right _ -> DrainerStatus DrainerStarting "checking…"
                Left message -> DrainerStatus DrainerError (sanitizeText message),
            appDrainerBusy = False,
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
            appOptions = options
          }
  (finalState, finalVty) <- customMainWithDefaultVty (Just eventChannel) application initialState
  case finalState.appReviewBackend of
    ReviewBackendReady client -> stopReviewClient client
    _ -> pure ()
  mapM_ killManagedProcess (filter managedProcessStopsWithDashboard (Map.elems finalState.appSolveProcesses))
  mapM_ killManagedProcess (Map.elems finalState.appCanonicalReviewProcesses)
  mapM_ killManagedProcess (filter managedProcessStopsWithDashboard (Map.elems finalState.appPullRequestProcesses))
  Vty.shutdown finalVty

initialBoardState :: UTCTime -> CacheLoad -> (Board, Freshness, Maybe UTCTime, Bool, Bool, Text)
initialBoardState now cacheLoad = case cacheLoad of
  CacheLoaded snapshot ->
    ( deriveBoard defaultWorkflowConfig snapshot,
      Fresh snapshot.snapshotFetchedAt,
      Just snapshot.snapshotFetchedAt,
      snapshot.snapshotIssuesTruncated,
      snapshot.snapshotPullRequestsTruncated,
      appendWarnings "Cached GitHub snapshot loaded · press u to update" (snapshotWarnings snapshot)
    )
  CacheAbsent ->
    ( deriveBoard defaultWorkflowConfig (RepoSnapshot [] [] now False False),
      NotLoaded,
      Nothing,
      False,
      False,
      "No cached GitHub snapshot · press u to update"
    )
  CacheInvalid warning ->
    ( deriveBoard defaultWorkflowConfig (RepoSnapshot [] [] now False False),
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

drawBase :: AppState -> Widget Name
drawBase state
  | usesOpenBorders state =
      withBorderStyle unicodeBold
        . vBox
        $ [hBorderWithLabel title, body, footer, hBorder]
  | otherwise = withBorderStyle (shellBorderStyle state) . borderWithLabel title $ body <=> footer
  where
    repository = state.appRepository
    title =
      withAttr titleAttr
        . txt
        $ " " <> repository.repositoryOwner <> "/" <> repository.repositoryName <> " "
    body
      | state.appSidebarVisible && usesOpenBorders state = hLimit 28 (drawUsage state) <+> str "  " <+> drawBoard state
      | state.appSidebarVisible = hLimit 28 (drawUsage state) <+> drawBoard state
      | otherwise = drawBoard state
    footer = drawFooter state

drawUsage :: AppState -> Widget Name
drawUsage state
  | usesOpenBorders state =
      withBorderStyle unicodeBold
        . vBox
        $ [ hBorderWithLabel (withAttr headingAttr (txt " USAGE ")),
            padLeftRight 1 usageContents,
            hBorder
          ]
  | otherwise =
      withBorderStyle (innerBorderStyle state)
        . borderWithLabel (withAttr headingAttr (txt " USAGE "))
        . padLeftRight 1
        $ usageContents
  where
    usageContents =
      vBox
        [ vBox [drawProvider state Codex, txt "", drawProvider state Claude],
          padTop Max (drawDrainerButton state)
        ]

drawDrainerButton :: AppState -> Widget Name
drawDrainerButton state =
  vBox
    [ clickable DrainerButton
        . withAttr (drainerStatusAttr status)
        . vBox
        $ [ txt "+--------------+",
            txt "| drain_prs.py |",
            txt "+--------------+"
          ],
      withAttr (drainerStatusAttr status) (txtWrap status.drainerDetail)
    ]
  where
    status = state.appDrainerStatus

drainerStatusAttr :: DrainerStatus -> AttrName
drainerStatusAttr status = case status.drainerState of
  DrainerOff -> neutralAttr
  DrainerOn -> readyAttr
  DrainerStarting -> pendingAttr
  DrainerStopping -> pendingAttr
  DrainerWarning -> pendingAttr
  DrainerError -> problemAttr

drawProvider :: AppState -> UsageProvider -> Widget Name
drawProvider state provider =
  vBox
    ( withAttr providerAttr (txt providerName)
        : case Map.lookup provider state.appUsage of
          Nothing -> [withAttr (usageStatusAttribute freshness) (txtWrap (usageStatusText provider freshness))]
          Just snapshot -> map (drawUsageWindow state) snapshot.usageWindows <> usageSnapshotStatus freshness
    )
  where
    freshness = Map.findWithDefault NotLoaded provider state.appUsageFreshness
    providerName = case provider of
      Codex -> "Codex"
      Claude -> "Claude"

usageSnapshotStatus :: Freshness -> [Widget Name]
usageSnapshotStatus Loading = [withAttr noticeAttr (txt "refreshing…")]
usageSnapshotStatus (Stale _ message) = [withAttr pendingAttr (txtWrap ("stale · " <> message))]
usageSnapshotStatus _ = []

usageStatusText :: UsageProvider -> Freshness -> Text
usageStatusText _ Loading = "refreshing…"
usageStatusText _ (Fresh _) = "loaded"
usageStatusText _ (Stale _ message) = "stale · " <> message
usageStatusText _ (Unavailable message) = message
usageStatusText _ (Unsupported message) = message
usageStatusText _ NotLoaded = "press u to refresh"

usageStatusAttribute :: Freshness -> AttrName
usageStatusAttribute Loading = noticeAttr
usageStatusAttribute (Stale _ _) = pendingAttr
usageStatusAttribute (Unavailable _) = problemAttr
usageStatusAttribute (Unsupported _) = dimAttr
usageStatusAttribute _ = dimAttr

drawUsageWindow :: AppState -> UsageWindow -> Widget Name
drawUsageWindow state usageWindow =
  vBox
    [ txt (padLabel usageWindow.usageWindowLabel <> " " <> usageBar state usageWindow.usagePercentLeft),
      withAttr dimAttr . txt $ "        " <> Text.pack (formatTime defaultTimeLocale "%a %H:%M" (utcToZonedTime state.appTimeZone usageWindow.usageResetsAt))
    ]

usageBar :: AppState -> Int -> Text
usageBar state percentage =
  left <> Text.replicate filled fullCharacter <> Text.replicate (10 - filled) emptyCharacter <> right <> " " <> Text.pack (show percentage) <> "%"
  where
    filled = max 0 (min 10 ((percentage + 5) `div` 10))
    (left, right, fullCharacter, emptyCharacter)
      | state.appOptions.optionAscii = ("[", "]", "#", ".")
      | otherwise = ("[", "]", "█", "░")

padLabel :: Text -> Text
padLabel value = value <> Text.replicate (max 0 (7 - Text.length value)) " "

drawBoard :: AppState -> Widget Name
drawBoard state =
  BrickTypes.Widget BrickTypes.Greedy BrickTypes.Greedy $ do
    context <- BrickTypes.getContext
    let availableWidth = BrickTypes.availWidth context
        columnWidths
          | usesOpenBorders state = responsiveOpenColumnWidths availableWidth
          | otherwise = responsiveColumnWidths availableWidth
    BrickTypes.render
      . viewport BoardViewport Horizontal
      $ if usesOpenBorders state
        then drawOpenBoard state columnWidths
        else
          withBorderStyle (innerBorderStyle state)
            . vBox
            $ [drawBoardTop state columnWidths, drawBoardColumns state columnWidths, drawBoardBottom state columnWidths]

drawOpenBoard :: AppState -> [Int] -> Widget Name
drawOpenBoard state columnWidths =
  withBorderStyle unicodeBold
    . vBox
    $ [ hBox (intersperse columnGutter (zipWith drawOpenHeader allColumns columnWidths)),
        hBox (intersperse columnGutter (zipWith (drawColumn state) columnWidths allColumns)),
        hBox (intersperse columnGutter (map (\columnWidth -> hLimit columnWidth hBorder) columnWidths))
      ]
  where
    columnGutter = str "  "
    drawOpenHeader column columnWidth =
      hLimit columnWidth
        . hBorderWithLabel
        . withAttr (columnHeadingAttr column)
        . txt
        $ " " <> columnName column <> "  " <> columnCountText state column <> " "

drawBoardTop :: AppState -> [Int] -> Widget Name
drawBoardTop state columnWidths =
  hBox
    ( txt (boardTopLeft state)
        : concatMap drawHeader (zip3 [0 :: Int ..] allColumns columnWidths)
    )
  where
    drawHeader (index, column, columnWidth) =
      [ hLimit columnWidth
          . hBorderWithLabel
          . withAttr (columnHeadingAttr column)
          . txt
          $ " " <> columnName column <> "  " <> columnCountText state column <> " ",
        txt (if index == length allColumns - 1 then boardTopRight state else boardTopJunction state)
      ]

drawBoardColumns :: AppState -> [Int] -> Widget Name
drawBoardColumns state columnWidths =
  hBox
    ( vBorder
        : concatMap drawBody (zip allColumns columnWidths)
    )
  where
    drawBody (column, columnWidth) = [drawColumn state columnWidth column, vBorder]

drawBoardBottom :: AppState -> [Int] -> Widget Name
drawBoardBottom state columnWidths =
  hBox
    ( txt (boardBottomLeft state)
        : concatMap drawSegment (zip [0 :: Int ..] columnWidths)
    )
  where
    drawSegment (index, columnWidth) =
      [ hLimit columnWidth hBorder,
        txt (if index == length allColumns - 1 then boardBottomRight state else boardBottomJunction state)
      ]

drawColumn :: AppState -> Int -> BoardColumn -> Widget Name
drawColumn state columnWidth column =
  columnVisibility
    . hLimit columnWidth
    . clickable (ColumnViewport column)
    . viewport (ColumnViewport column) Vertical
    . padTop (Pad 1)
    . vBox
    $ if null entries
      then [padAll 1 (withAttr dimAttr (txt "No items"))]
      else drawColumnEntries state column (zip [0 ..] entries)
  where
    entries = entriesFor state column
    columnVisibility = if state.appSelectedColumn == column then visible else id

drawColumnEntries :: AppState -> BoardColumn -> [(Int, ColumnEntry)] -> [Widget Name]
drawColumnEntries _ _ [] = []
drawColumnEntries state column indexedEntries@((row, entry) : _) = case entry of
  Tracked trackingContext _ ->
    let trackerNumber = primaryTrackerNumber trackingContext
        (groupEntries, remaining) = span ((== Just trackerNumber) . entryPrimaryTrackerNumber . snd) indexedEntries
        tracker = trackingContext.trackingPrimary.membershipTracker
        expanded = trackerNumber `Set.member` state.appExpandedTrackers
        children = if expanded then map (uncurry (drawCard state column)) groupEntries else []
     in drawTrackerHeader state column row tracker expanded : children <> drawColumnEntries state column remaining
  Standalone _ ->
    let (standaloneEntries, remaining) = span ((== Nothing) . entryPrimaryTrackerNumber . snd) indexedEntries
        header = padLeftRight 2 (withAttr dimAttr (txt "STANDALONE"))
     in header : map (uncurry (drawCard state column)) standaloneEntries <> drawColumnEntries state column remaining

boardTopLeft, boardTopRight, boardTopJunction :: AppState -> Text
boardBottomLeft, boardBottomRight, boardBottomJunction :: AppState -> Text
boardTopLeft state = structuralGlyph state "┏"
boardTopRight state = structuralGlyph state "┓"
boardTopJunction state = structuralGlyph state "┳"
boardBottomLeft state = structuralGlyph state "┗"
boardBottomRight state = structuralGlyph state "┛"
boardBottomJunction state = structuralGlyph state "┻"

structuralGlyph :: AppState -> Text -> Text
structuralGlyph state boxGlyph
  | state.appOptions.optionAscii = "+"
  | otherwise = boxGlyph

drawCard :: AppState -> BoardColumn -> Int -> ColumnEntry -> Widget Name
drawCard state column row entry =
  padLeftRight 1
    . padBottom (Pad 1)
    . clickable (CardTarget column row)
    $ visibility card
  where
    selected = state.appSelectedColumn == column && selectedRow state column == row
    visibility = if selected && state.appEnsureSelectionVisible then visible else id
    card =
      (if selected then withAttr selectedAttr (txt marker) else txt " ")
        <+> solveBadge state (entryItem entry)
        <+> reviewBadge state (entryItem entry)
        <+> branchPrefix state column row entry
        <+> drawCardFrame state selected entry (vBox (cardLines state selected entry))
    marker = if state.appOptions.optionAscii then ">" else "▌"

drawCardFrame :: AppState -> Bool -> ColumnEntry -> Widget Name -> Widget Name
drawCardFrame state selected entry contents =
  withBorderStyle (cardBorderStyle state)
    . vBox
    $ [ hBox [withAttr topBottomAttribute (txt topLeft), withAttr topBottomAttribute hBorder, withAttr statusAttribute (txt topRight)],
        hBox
          [ withAttr leftAttribute verticalEdge,
            withAttr interiorAttribute (vLimit middleHeight (padLeftRight 1 (padRight Max contents))),
            withAttr statusAttribute verticalEdge
          ],
        hBox [withAttr topBottomAttribute (txt bottomLeft), withAttr topBottomAttribute hBorder, withAttr statusAttribute (txt bottomRight)]
      ]
  where
    item = entryItem entry
    (topLeft, topRight, bottomLeft, bottomRight, vertical)
      | state.appOptions.optionAscii = ("+", "+", "+", "+", '|')
      | otherwise = ("╭", "╮", "╰", "╯", '│')
    statusAttribute = cardStatusAttribute state item
    topBottomAttribute = if selected then selectedAttr else statusAttribute
    leftAttribute = if selected then selectedAttr else statusAttribute
    interiorAttribute = if isApproved defaultWorkflowConfig item then approvedInteriorAttr else neutralAttr
    middleHeight = baseHeight + case entry of
      Standalone _ -> 0
      Tracked _ _ -> 1
    baseHeight = case item of
      IssueItem _ -> 7
      PullRequestItem _ -> 8
    verticalEdge = vBox (replicate middleHeight (str [vertical]))

cardLines :: AppState -> Bool -> ColumnEntry -> [Widget Name]
cardLines state selected entry =
  trackingLine
    <> [ withAttr (if selected then selectedTitleAttr else cardTitleAttr) (txtWrap (itemHeading item)),
    drawCardLabels state item,
    withAttr dimAttr (txtWrap (itemMetadata state item)),
    txtWrap (excerpt (itemBody item))
       ]
    <> statusLine
  where
    item = entryItem entry
    trackingLine = case entry of
      Standalone _ -> []
      Tracked context _ -> [drawTrackingLine context]
    statusLine = case item of
      IssueItem issue -> case trackerDiagnosticsForIssue defaultWorkflowConfig issue of
        [] -> []
        diagnostic : _ -> [withAttr pendingAttr (txtWrap ("TRACKER · " <> renderTrackerDiagnostic diagnostic))]
      PullRequestItem _ -> [withAttr (statusTextAttr item) (txt (itemStatusText item))]

drawTrackerHeader :: AppState -> BoardColumn -> Int -> Tracker -> Bool -> Widget Name
drawTrackerHeader state column row tracker expanded =
  visibility
    . clickable (EpicTarget column row tracker.trackerIssue.issueNumber)
    . padLeftRight 1
    . padTop (Pad 1)
    $ marker <+> solveBadge state (IssueItem tracker.trackerIssue) <+> reviewBadge state (IssueItem tracker.trackerIssue) <+> withAttr headerAttribute (txtWrap headerText)
  where
    selected = not expanded && state.appSelectedColumn == column && selectedRow state column == row
    visibility = if selected && state.appEnsureSelectionVisible then visible else id
    marker
      | selected = withAttr selectedAttr (txt (if state.appOptions.optionAscii then ">" else "▌"))
      | otherwise = txt " "
    headerAttribute
      | null tracker.trackerDiagnostics = trackerAttr
      | otherwise = pendingAttr
    disclosure
      | state.appOptions.optionAscii = if expanded then "v" else ">"
      | expanded = "▾"
      | otherwise = "▸"
    headerText =
      disclosure
        <> " #"
        <> showText tracker.trackerIssue.issueNumber
        <> "  "
        <> sanitizeText tracker.trackerIssue.issueTitle
        <> "  "
        <> showText tracker.trackerCompleted
        <> "/"
        <> showText tracker.trackerTotal
        <> " complete"
        <> if null tracker.trackerDiagnostics then "" else "  · !" <> showText (length tracker.trackerDiagnostics)

drawTrackingLine :: TrackingContext -> Widget Name
drawTrackingLine context =
  withAttr trackerAttr (txt (childKey <> " · tracker #" <> showText trackerNumber))
    <+> multiTracked
  where
    child = context.trackingPrimary.membershipChild
    childKey = case child.trackerChildImplementationKey of
      Just key -> key
      Nothing -> "step " <> showText (child.trackerChildChecklistOrder + 1)
    trackerNumber = context.trackingPrimary.membershipTracker.trackerIssue.issueNumber
    multiTracked
      | null context.trackingAdditional = emptyWidget
      | otherwise = withAttr pendingAttr (txt " · MULTI-TRACKED")

branchPrefix :: AppState -> BoardColumn -> Int -> ColumnEntry -> Widget Name
branchPrefix state column row entry = case entry of
  Standalone _ -> emptyWidget
  Tracked _ _ -> withAttr trackerAttr (txt branch)
  where
    branch
      | state.appOptions.optionAscii = if isLastInTracker then "`- " else "+- "
      | isLastInTracker = "└─ "
      | otherwise = "├─ "
    isLastInTracker = entryPrimaryTrackerNumber entry /= (entryPrimaryTrackerNumber =<< safeIndex (row + 1) (entriesFor state column))

entryPrimaryTrackerNumber :: ColumnEntry -> Maybe Int
entryPrimaryTrackerNumber (Standalone _) = Nothing
entryPrimaryTrackerNumber (Tracked context _) = Just (primaryTrackerNumber context)

primaryTrackerNumber :: TrackingContext -> Int
primaryTrackerNumber context = context.trackingPrimary.membershipTracker.trackerIssue.issueNumber

drawLabel :: AppState -> Label -> Widget Name
drawLabel _ label = withAttr (labelAttribute label.labelName) (txt (" " <> sanitizeText label.labelName <> " ")) <+> txt " "

drawCardLabels :: AppState -> BoardItem -> Widget Name
drawCardLabels state item = hBox (map (drawLabel state) visibleLabels <> overflowMarker)
  where
    labels = itemLabels item
    visibleLabels = take 4 labels
    hiddenLabels = max 0 (length labels - length visibleLabels) + itemLabelOverflow item
    overflowMarker
      | hiddenLabels > 0 = [withAttr pendingAttr (txt ("+" <> showText hiddenLabels))]
      | otherwise = []

itemHeading :: BoardItem -> Text
itemHeading (IssueItem issue) = "#" <> showText issue.issueNumber <> "  " <> sanitizeText issue.issueTitle
itemHeading (PullRequestItem pullRequest) =
  (if pullRequest.pullRequestDraft then "DRAFT " else "PR ")
    <> "#"
    <> showText pullRequest.pullRequestNumber
    <> "  "
    <> sanitizeText pullRequest.pullRequestTitle

itemBody :: BoardItem -> Text
itemBody (IssueItem issue) = issue.issueBody
itemBody (PullRequestItem pullRequest) = pullRequest.pullRequestBody

itemMetadata :: AppState -> BoardItem -> Text
itemMetadata state (IssueItem issue) = ownership <> " · updated " <> relativeAge state.appNow issue.issueUpdatedAt
  where
    ownership
      | null issue.issueAssignees && issue.issueAssigneeOverflow == 0 = "unassigned"
      | otherwise =
          Text.intercalate ", " ["@" <> assignee.assigneeLogin | assignee <- issue.issueAssignees]
            <> overflowText issue.issueAssigneeOverflow
itemMetadata state (PullRequestItem pullRequest) =
  linked <> pullRequest.pullRequestAuthor <> " → " <> pullRequest.pullRequestBase <> " · updated " <> relativeAge state.appNow pullRequest.pullRequestUpdatedAt
  where
    linked = case pullRequest.pullRequestLinkedIssues of
      []
        | pullRequest.pullRequestLinkedIssueOverflow > 0 -> "+" <> showText pullRequest.pullRequestLinkedIssueOverflow <> " linked · "
        | otherwise -> "UNLINKED · "
      numbers ->
        let visibleNumbers = take 2 numbers
            hiddenNumbers = max 0 (length numbers - length visibleNumbers) + pullRequest.pullRequestLinkedIssueOverflow
         in Text.intercalate "," (map (("#" <>) . showText) visibleNumbers) <> overflowText hiddenNumbers <> " · "

overflowText :: Int -> Text
overflowText count
  | count > 0 = " +" <> showText count
  | otherwise = ""

itemStatusText :: BoardItem -> Text
itemStatusText (IssueItem _) = ""
itemStatusText (PullRequestItem pullRequest) =
  checkText pullRequest.pullRequestChecks <> " · " <> mergeText pullRequest.pullRequestMergeState

checkText :: CheckSummary -> Text
checkText ChecksNone = "no CI"
checkText (ChecksPending passed total) = "◐ CI " <> showText passed <> "/" <> showText total
checkText (ChecksPassed total) = "✓ CI " <> showText total <> "/" <> showText total
checkText (ChecksFailed passed total) = "× CI " <> showText passed <> "/" <> showText total
checkText ChecksUnknown = "? CI unknown"

mergeText :: MergeState -> Text
mergeText MergeClean = "clean"
mergeText MergeBehind = "behind"
mergeText MergeBlocked = "blocked"
mergeText MergeProtected = "protected"
mergeText MergeConflicting = "merge conflict"
mergeText MergeUnstable = "unstable"
mergeText MergeUnknown = "calculating"

cardStatusAttribute :: AppState -> BoardItem -> AttrName
cardStatusAttribute state item
  | isProblem defaultWorkflowConfig item = problemAttr
  | Just solveAttribute <- solveCardAttribute state item = solveAttribute
  | itemHasAmberWarning item = pendingAttr
  | isApproved defaultWorkflowConfig item = approvedAttr
cardStatusAttribute _ (PullRequestItem pullRequest) = case pullRequestStatus defaultWorkflowConfig pullRequest of
  StatusPending _ -> pendingAttr
  StatusReady -> readyAttr
  StatusProblem _ -> problemAttr
  StatusNeutral -> neutralAttr
cardStatusAttribute _ _ = neutralAttr

solveCardAttribute :: AppState -> BoardItem -> Maybe AttrName
solveCardAttribute _ (PullRequestItem _) = Nothing
solveCardAttribute state (IssueItem issue) = solveSessionAttribute <$> Map.lookup issue.issueNumber state.appSolveSessions

statusTextAttr :: BoardItem -> AttrName
statusTextAttr item
  | isProblem defaultWorkflowConfig item = problemAttr
  | itemHasAmberWarning item = pendingAttr
statusTextAttr (PullRequestItem pullRequest) = case pullRequestStatus defaultWorkflowConfig pullRequest of
  StatusPending _ -> pendingAttr
  StatusReady -> readyAttr
  StatusProblem _ -> problemAttr
  StatusNeutral -> dimAttr
statusTextAttr _ = dimAttr

itemHasAmberWarning :: BoardItem -> Bool
itemHasAmberWarning (IssueItem issue) =
  issue.issueLabelOverflow > 0
    || issue.issueAssigneeOverflow > 0
    || not (null (trackerDiagnosticsForIssue defaultWorkflowConfig issue))
itemHasAmberWarning (PullRequestItem pullRequest) =
  pullRequest.pullRequestLabelOverflow > 0 || pullRequest.pullRequestLinkedIssueOverflow > 0

solveBadge :: AppState -> BoardItem -> Widget Name
solveBadge _ (PullRequestItem _) = emptyWidget
solveBadge state (IssueItem issue) = case Map.lookup issue.issueNumber state.appSolveSessions of
  Nothing -> emptyWidget
  Just session -> withAttr (solveSessionAttribute session) (txt (solvePhaseGlyph state session))

solvePhaseGlyph :: AppState -> SolveSession -> Text
solvePhaseGlyph state session
  | state.appOptions.optionAscii = case session.solveSessionPhase of
      SolveStarting -> "* "
      SolveRunning -> "* "
      SolveInterrupting -> "! "
      SolveAttention -> "! "
      SolveFinished -> "+ "
      SolveFailedPhase -> "x "
      SolveKilledPhase -> "x "
      SolveOrphanedPhase -> "x "
  | otherwise = case session.solveSessionPhase of
      SolveStarting -> spinnerGlyph session.solveSessionSpinnerFrame <> " "
      SolveRunning -> spinnerGlyph session.solveSessionSpinnerFrame <> " "
      SolveInterrupting -> "◆ "
      SolveAttention -> "◆ "
      SolveFinished -> "◇ "
      SolveFailedPhase -> "× "
      SolveKilledPhase -> "× "
      SolveOrphanedPhase -> "⚠ "

solveSessionAttribute :: SolveSession -> AttrName
solveSessionAttribute session = case session.solveSessionPhase of
  SolveAttention -> attentionAttr
  SolveInterrupting -> pendingAttr
  SolveFailedPhase -> problemAttr
  SolveKilledPhase -> problemAttr
  SolveOrphanedPhase -> problemAttr
  SolveFinished -> neutralAttr
  _
    | session.solveSessionWorkflow == AutoSolve -> activeAttr
    | otherwise -> neutralAttr

reviewBadge :: AppState -> BoardItem -> Widget Name
reviewBadge state (PullRequestItem pullRequest) = case Map.lookup pullRequest.pullRequestNumber state.appPullRequestReviewSessions of
  Nothing -> emptyWidget
  Just session -> withAttr (pullRequestSessionAttribute session) (txt (pullRequestSessionGlyph state session))
reviewBadge state (IssueItem issue) = case Map.lookup issue.issueNumber state.appReviewSessions of
  Nothing -> emptyWidget
  Just session -> withAttr (reviewPhaseAttribute session.reviewSessionPhase) (txt (reviewPhaseGlyph state session))

pullRequestSessionAttribute :: PullRequestReviewSession -> AttrName
pullRequestSessionAttribute session = case session.pullRequestSessionPhase of
  SolveAttention -> attentionAttr
  SolveInterrupting -> pendingAttr
  SolveFailedPhase -> problemAttr
  SolveKilledPhase -> problemAttr
  SolveOrphanedPhase -> problemAttr
  SolveFinished -> readyAttr
  _ -> reviewingAttr

pullRequestSessionGlyph :: AppState -> PullRequestReviewSession -> Text
pullRequestSessionGlyph state session
  | state.appOptions.optionAscii = case session.pullRequestSessionPhase of
      SolveStarting -> "* "
      SolveRunning -> "* "
      SolveInterrupting -> "! "
      SolveAttention -> "! "
      SolveFinished -> "+ "
      SolveFailedPhase -> "x "
      SolveKilledPhase -> "x "
      SolveOrphanedPhase -> "x "
  | otherwise = case session.pullRequestSessionPhase of
      SolveStarting -> spinnerGlyph session.pullRequestSessionSpinnerFrame <> " "
      SolveRunning -> spinnerGlyph session.pullRequestSessionSpinnerFrame <> " "
      SolveInterrupting -> "◆ "
      SolveAttention -> "◆ "
      SolveFinished -> "✓ "
      SolveFailedPhase -> "× "
      SolveKilledPhase -> "× "
      SolveOrphanedPhase -> "⚠ "

reviewPhaseGlyph :: AppState -> ReviewSession -> Text
reviewPhaseGlyph state session
  | state.appOptions.optionAscii = case session.reviewSessionPhase of
      ReviewStarting -> "* "
      ReviewRunning -> "* "
      ReviewWaiting -> "? "
      ReviewFinished -> "+ "
      ReviewNeedsChanges -> "! "
      ReviewFailed -> "! "
      ReviewInterrupted -> "- "
  | otherwise = case session.reviewSessionPhase of
      ReviewStarting -> spinnerGlyph session.reviewSessionSpinnerFrame <> " "
      ReviewRunning -> spinnerGlyph session.reviewSessionSpinnerFrame <> " "
      ReviewWaiting -> "? "
      ReviewFinished -> "✓ "
      ReviewNeedsChanges -> "! "
      ReviewFailed -> "× "
      ReviewInterrupted -> "· "

spinnerGlyph :: Int -> Text
spinnerGlyph frame = spinnerFrames !! (frame `mod` length spinnerFrames)
  where
    spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

drawLiveActivity :: AppState -> Bool -> Int -> UTCTime -> Text -> Widget Name
drawLiveActivity state isLive frame startedAt activity
  | not isLive = emptyWidget
  | otherwise =
      withAttr reviewingAttr
        . txtWrap
        $ activityGlyph <> " " <> activity <> " · " <> formatElapsed state.appNow startedAt
  where
    activityGlyph
      | state.appOptions.optionAscii = "*"
      | otherwise = spinnerGlyph frame

timedActivity :: UTCTime -> Bool -> UTCTime -> Text -> Text
timedActivity now isLive startedAt activity
  | isLive = activity <> " · " <> formatElapsed now startedAt
  | otherwise = activity

formatElapsed :: UTCTime -> UTCTime -> Text
formatElapsed now startedAt
  | seconds < 60 = showText seconds <> "s"
  | seconds < 3600 = showText (seconds `div` 60) <> "m " <> twoDigits (seconds `mod` 60) <> "s"
  | otherwise = showText (seconds `div` 3600) <> "h " <> twoDigits ((seconds `div` 60) `mod` 60) <> "m"
  where
    seconds = max 0 (floor (diffUTCTime now startedAt) :: Int)
    twoDigits value
      | value < 10 = "0" <> showText value
      | otherwise = showText value

reviewPhaseAttribute :: ReviewPhase -> AttrName
reviewPhaseAttribute phase = case phase of
  ReviewStarting -> trackerAttr
  ReviewRunning -> trackerAttr
  ReviewWaiting -> pendingAttr
  ReviewFinished -> readyAttr
  ReviewNeedsChanges -> pendingAttr
  ReviewFailed -> problemAttr
  ReviewInterrupted -> dimAttr

drawFooter :: AppState -> Widget Name
drawFooter state =
  padLeftRight 1
    . vBox
    $ [ withAttr footerAttr (txt "j/↓ next  k/↑ previous  x kill  h/l column  e epic  enter details  r review/revise  S solve  A autosolve  p processes  u update  d drainer  c sidebar  s settings  ? help  q quit"),
        withAttr dimAttr (txt (boardFreshnessText state)),
        maybe emptyWidget (withAttr noticeAttr . txtWrap) state.appNotice
      ]

boardFreshnessText :: AppState -> Text
boardFreshnessText state = "board: " <> case state.appBoardFreshness of
  NotLoaded -> "not loaded"
  Loading -> "refreshing…"
  Fresh fetchedAt -> "updated " <> relativeAge state.appNow fetchedAt
  Stale fetchedAt _ -> "stale · last updated " <> relativeAge state.appNow fetchedAt
  Unavailable _ -> "unavailable"
  Unsupported _ -> "unsupported"

drawOverlay :: AppState -> Overlay -> Widget Name
drawOverlay state overlay =
  centerLayer
    . panelExtent
    . hLimit overlayWidth
    . vLimit overlayHeight
    . withBorderStyle (innerBorderStyle state)
    . borderWithLabel (withAttr headingAttr (txt overlayTitle))
    . padAll 1
    $ case overlay of
      HelpOverlay -> drawHelp
      SettingsOverlay -> drawSettings state
      ProcessesOverlay -> drawProcesses state
      DetailsOverlay item -> viewport DetailsViewport Vertical (drawDetails state item)
      ReviewOverlay issueNumber -> drawReview state issueNumber
      SolveChooser _ issue -> drawSolveChooser issue
      SolveOverlay issueNumber -> drawSolve state issueNumber
      PullRequestReviewOverlay number -> drawPullRequestReview state number
  where
    overlayWidth = case overlay of
      SolveChooser _ _ -> 42
      SettingsOverlay -> 68
      ProcessesOverlay -> 100
      _ -> 88
    overlayHeight = case overlay of
      SolveChooser _ _ -> 10
      SettingsOverlay -> 19
      ProcessesOverlay -> 32
      _ -> 32
    panelExtent = case overlay of
      HelpOverlay -> id
      SettingsOverlay -> id
      ProcessesOverlay -> clickable ProcessesPanel
      DetailsOverlay _ -> clickable DetailsPanel
      ReviewOverlay _ -> clickable ReviewPanel
      SolveChooser _ _ -> id
      SolveOverlay _ -> clickable SolvePanel
      PullRequestReviewOverlay _ -> clickable PullRequestReviewPanel
    overlayTitle = case overlay of
      HelpOverlay -> " HELP "
      SettingsOverlay -> " SETTINGS "
      ProcessesOverlay -> " PROCESSES "
      DetailsOverlay item -> " " <> itemHeading item <> " "
      ReviewOverlay issueNumber -> " " <> reviewOverlayTitle state issueNumber <> " #" <> showText issueNumber <> " "
      SolveChooser workflow issue -> " " <> workflowTitle workflow <> " #" <> showText issue.issueNumber <> " "
      SolveOverlay issueNumber -> " SOLVE #" <> showText issueNumber <> " "
      PullRequestReviewOverlay number -> " PR #" <> showText number <> " REVIEW/REVISE "

reviewOverlayTitle :: AppState -> Int -> Text
reviewOverlayTitle state issueNumber = case (.reviewSessionStage) <$> Map.lookup issueNumber state.appReviewSessions of
  Just InitialReview -> "REVIEW"
  Just IssueRevision -> "REVISION"
  Just IssueRereview -> "REREVIEW"
  Nothing -> "REVIEW"

drawHelp :: Widget Name
drawHelp =
  vBox
    [ txt "j / Down    next card",
      txt "k / Up      previous card",
      txt "x           kill selected working process tree",
      txt "h / Left    previous column",
      txt "l / Right   next column",
      txt "g / G        first / last visible item",
      txt "e            expand / collapse focused epic",
      txt "Enter        details",
      txt "r            review/revise selected issue or PR",
      txt "S            solve selected issue (choose model brand)",
      txt "A            autosolve selected issue (choose model brand)",
      txt "u            update board and both usage providers",
      txt "d / click    start or stop PR drainer",
      txt "left click   select card; click selected card for details",
      txt "mouse wheel scroll column under pointer",
      txt "right/outside click closes card details",
      txt "c            collapse / expand sidebar",
      txt "s            settings",
      txt "p            processes and agent sessions",
      txt "Ctrl-L       repaint",
      txt "Esc          close overlay",
      txt "Ctrl-C       interrupt open agent turn, then type guidance",
      txt "q            quit"
    ]

drawSettings :: AppState -> Widget Name
drawSettings state =
  vBox
    [ withAttr cardTitleAttr (txt "Chat output verbosity"),
      txt "",
      drawChoice '1' CompactChat,
      txt "",
      drawChoice '2' StandardChat,
      txt "",
      drawChoice '3' FullChat,
      txt "",
      withAttr dimAttr (txtWrap "Full JSONL logs are always recorded at maximum provider verbosity; this setting changes only the on-screen transcript."),
      withAttr dimAttr (txtWrap ("Log directory: " <> Text.pack state.appLogRoot)),
      withAttr footerAttr (txt "1/2/3 select  Esc close")
    ]
  where
    selected = state.appSettings.settingsChatVerbosity
    drawChoice key verbosity =
      let attribute = if verbosity == selected then selectedAttr else neutralAttr
       in withAttr attribute (txt (Text.singleton key <> ") " <> verbosityLabel verbosity))
            <=> padLeft (Pad 3) (withAttr dimAttr (txtWrap (verbosityDescription verbosity)))

drawProcesses :: AppState -> Widget Name
drawProcesses state =
  vBox
    [ withAttr dimAttr (txt ("tracked sessions: " <> showText (length entries) <> " · live processes: " <> showText (length (filter (.agentSessionLive) entries)))),
      txt "",
      vLimit 23
        . viewport ProcessesViewport Vertical
        $ if null entries
          then withAttr dimAttr (txt "No agent sessions have been started.")
          else vBox (zipWith drawEntry [0 :: Int ..] entries),
      hBorder,
      withAttr footerAttr (txt "j/↓ next  k/↑ previous  Enter open session  x kill process tree  wheel scroll  Esc close")
    ]
  where
    entries = agentSessionEntries state
    selectedIndex = max 0 (min state.appProcessSelection (length entries - 1))
    drawEntry index entry =
      let selected = index == selectedIndex
          attribute
            | selected = selectedAttr
            | entry.agentSessionProblem = problemAttr
            | entry.agentSessionLive = reviewingAttr
            | otherwise = dimAttr
          glyph
            | state.appOptions.optionAscii = if entry.agentSessionLive then "*" else "-"
            | entry.agentSessionLive = "●"
            | entry.agentSessionProblem = "×"
            | otherwise = "○"
          sessionText = maybe "" (" · id " <>) entry.agentSessionId
          line =
            glyph
              <> " "
              <> entry.agentSessionLabel
              <> " · "
              <> entry.agentSessionProvider
              <> " · "
              <> entry.agentSessionStatus
              <> " · "
              <> entry.agentSessionActivity
              <> sessionText
          widget = clickable (ProcessTarget index) (withAttr attribute (txt line))
       in if selected then visible widget else widget

agentSessionEntries :: AppState -> [AgentSessionEntry]
agentSessionEntries state = sortOn sortKey (solveEntries <> pullRequestEntries <> reviewEntries <> unattachedWorkerEntries)
  where
    sortKey entry = (not entry.agentSessionLive, entry.agentSessionLabel)
    solveEntries =
      [ AgentSessionEntry
          { agentSessionRef = SolveAgent issueNumber,
            agentSessionLabel = Text.toLower (workflowTitle session.solveSessionWorkflow) <> " #" <> showText issueNumber,
            agentSessionProvider = solverLabel session.solveSessionBrand,
            agentSessionStatus = persistentProcessStatus state.appNow worker (solveProcessStatus session.solveSessionPhase),
            agentSessionActivity = timedActivity state.appNow isLive session.solveSessionActivityStartedAt session.solveSessionActivity,
            agentSessionId = shortSessionId <$> session.solveSessionId,
            agentSessionLive = isLive,
            agentSessionProblem = session.solveSessionPhase `elem` [SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase]
          }
        | (issueNumber, session) <- Map.toList state.appSolveSessions
        , let worker = solveWorkerFor state issueNumber
        , let isLive = Map.member issueNumber state.appSolveProcesses || worker /= Nothing
      ]
    pullRequestEntries =
      [ AgentSessionEntry
          { agentSessionRef = PullRequestAgent number,
            agentSessionLabel = "pr " <> pullRequestActionText session.pullRequestSessionAction <> " #" <> showText number,
            agentSessionProvider = pullRequestAgentLabel session.pullRequestSessionAction session.pullRequestSessionBrand,
            agentSessionStatus = persistentProcessStatus state.appNow worker (solveProcessStatus session.pullRequestSessionPhase),
            agentSessionActivity = timedActivity state.appNow isLive session.pullRequestSessionActivityStartedAt session.pullRequestSessionActivity,
            agentSessionId = shortSessionId <$> session.pullRequestSessionId,
            agentSessionLive = isLive,
            agentSessionProblem = session.pullRequestSessionPhase `elem` [SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase]
          }
        | (number, session) <- Map.toList state.appPullRequestReviewSessions
        , let worker = pullRequestWorkerFor state number
        , let isLive = Map.member number state.appPullRequestProcesses || worker /= Nothing
      ]
    reviewEntries =
      [ AgentSessionEntry
          { agentSessionRef = ReviewAgent issueNumber,
            agentSessionLabel = "issue " <> Text.toLower (reviewStageLabel session.reviewSessionStage) <> " #" <> showText issueNumber,
            agentSessionProvider = reviewProvider session.reviewSessionStage,
            agentSessionStatus = reviewProcessStatus session.reviewSessionPhase,
            agentSessionActivity = session.reviewSessionActivity,
            agentSessionId = shortSessionId <$> session.reviewSessionThreadId,
            agentSessionLive = Map.member issueNumber state.appCanonicalReviewProcesses || reviewSessionHasLiveTurn session,
            agentSessionProblem = session.reviewSessionPhase == ReviewFailed
          }
        | (issueNumber, session) <- Map.toList state.appReviewSessions
      ]
    unattachedWorkerEntries =
      [ AgentSessionEntry
          { agentSessionRef = WorkerAgent identifier,
            agentSessionLabel = workerTaskLabel descriptor.workerDescriptorSpec.workerTask,
            agentSessionProvider = workerTaskProvider descriptor.workerDescriptorSpec.workerTask,
            agentSessionStatus = persistentProcessStatus state.appNow (Just descriptor) "starting",
            agentSessionActivity = "waiting for board metadata",
            agentSessionId = Nothing,
            agentSessionLive = True,
            agentSessionProblem = False
          }
        | (identifier, descriptor) <- Map.toList state.appWorkers,
          not (workerHasSession descriptor)
      ]
    workerHasSession descriptor = case descriptor.workerDescriptorSpec.workerTask of
      SolveWorkerTaskKind task -> Map.member task.solveWorkerIssueNumber state.appSolveSessions
      PullRequestWorkerTaskKind task -> Map.member task.pullRequestWorkerNumber state.appPullRequestReviewSessions
    workerTaskLabel (SolveWorkerTaskKind task) = Text.toLower (workflowTitle task.solveWorkerWorkflow) <> " #" <> showText task.solveWorkerIssueNumber
    workerTaskLabel (PullRequestWorkerTaskKind task) = "pr " <> pullRequestActionText task.pullRequestWorkerAction <> " #" <> showText task.pullRequestWorkerNumber
    workerTaskProvider (SolveWorkerTaskKind task) = solverLabel task.solveWorkerBrand
    workerTaskProvider (PullRequestWorkerTaskKind task) = pullRequestAgentLabel task.pullRequestWorkerAction (agentForAction task.pullRequestWorkerOrigin task.pullRequestWorkerAction)
    reviewSessionHasLiveTurn session = session.reviewSessionPhase `elem` [ReviewStarting, ReviewRunning] && session.reviewSessionStage == IssueRevision

solveProcessStatus :: SolvePhase -> Text
solveProcessStatus SolveStarting = "starting"
solveProcessStatus SolveRunning = "running"
solveProcessStatus SolveInterrupting = "interrupting"
solveProcessStatus SolveAttention = "waiting for input"
solveProcessStatus SolveFinished = "finished"
solveProcessStatus SolveFailedPhase = "failed"
solveProcessStatus SolveKilledPhase = "killed"
solveProcessStatus SolveOrphanedPhase = "orphaned"

reviewProcessStatus :: ReviewPhase -> Text
reviewProcessStatus ReviewStarting = "starting"
reviewProcessStatus ReviewRunning = "running"
reviewProcessStatus ReviewWaiting = "waiting for input"
reviewProcessStatus ReviewFinished = "finished"
reviewProcessStatus ReviewNeedsChanges = "changes requested"
reviewProcessStatus ReviewFailed = "failed"
reviewProcessStatus ReviewInterrupted = "interrupted"

persistentProcessStatus :: UTCTime -> Maybe WorkerDescriptor -> Text -> Text
persistentProcessStatus _ Nothing status = status
persistentProcessStatus now (Just descriptor) status =
  status <> " · persistent · max " <> remainingText
  where
    spec = descriptor.workerDescriptorSpec
    elapsed = max 0 (floor (diffUTCTime now spec.workerCreatedAt) :: Int)
    remaining = max 0 (spec.workerMaxRuntimeSeconds - elapsed)
    remainingText
      | remaining >= 3600 = showText ((remaining + 3599) `div` 3600) <> "h"
      | remaining >= 60 = showText ((remaining + 59) `div` 60) <> "m"
      | otherwise = showText remaining <> "s"

reviewStageLabel :: ReviewStage -> Text
reviewStageLabel InitialReview = "review"
reviewStageLabel IssueRevision = "revision"
reviewStageLabel IssueRereview = "rereview"

reviewProvider :: ReviewStage -> Text
reviewProvider IssueRevision = "codex coordinator"
reviewProvider _ = "canonical reviewer"

shortSessionId :: Text -> Text
shortSessionId sessionId
  | Text.length sessionId <= 12 = sessionId
  | otherwise = Text.take 8 sessionId <> "…"

drawSolveChooser :: Issue -> Widget Name
drawSolveChooser issue =
  vBox
    [ withAttr cardTitleAttr (txtWrap (sanitizeText issue.issueTitle)),
      txt "",
      txt "1) codex",
      withAttr dimAttr (txt ("   " <> codexSolverModel)),
      txt "2) claude",
      withAttr dimAttr (txt ("   " <> claudeSolverModel)),
      txt "",
      withAttr footerAttr (txt "Esc cancel")
    ]

drawSolve :: AppState -> Int -> Widget Name
drawSolve state issueNumber = case Map.lookup issueNumber state.appSolveSessions of
  Nothing -> withAttr problemAttr (txt "Solve session is no longer available")
  Just session ->
    let transcript = transcriptFor state.appSettings.settingsChatVerbosity session.solveSessionTranscript
     in
    vBox
      [ withAttr (solveSessionAttribute session) (txt (solvePhaseLabel session)),
        drawLiveActivity state (Map.member issueNumber state.appSolveProcesses) session.solveSessionSpinnerFrame session.solveSessionActivityStartedAt session.solveSessionActivity,
        case session.solveSessionWorkflow of
          SolveOnly -> emptyWidget
          AutoSolve -> withAttr dimAttr (txt ("reviewer: " <> solveReviewerLabel session.solveSessionBrand)),
        txt "",
        maybe emptyWidget (withAttr dimAttr . txt . ("full log: " <>) . Text.pack) session.solveSessionLogPath,
        vLimit 20
          . clickable SolveViewport
          . viewport SolveViewport Vertical
          . padRight Max
          $ if Text.null transcript
            then withAttr dimAttr (txt "Waiting for solver output…")
            else txtWrap transcript,
        hBorder,
        drawSolveInput session,
        withAttr footerAttr (txt "Esc hide  Ctrl-C interrupt  Enter answer  arrows/wheel scroll")
      ]

solvePhaseLabel :: SolveSession -> Text
solvePhaseLabel session = case session.solveSessionPhase of
  SolveStarting -> "Starting " <> workflowTitle session.solveSessionWorkflow <> " with " <> solverLabel session.solveSessionBrand <> "…"
  SolveRunning -> solverLabel session.solveSessionBrand <> " is " <> workflowActivity session.solveSessionWorkflow
  SolveInterrupting -> "Interrupting the current solver turn…"
  SolveAttention -> "Needs your input"
  SolveFinished -> "Solve workflow finished"
  SolveFailedPhase -> "Solve workflow failed"
  SolveKilledPhase -> "Solve workflow killed"
  SolveOrphanedPhase -> "Solve workflow has orphaned subprocesses"

workflowTitle :: SolveWorkflow -> Text
workflowTitle SolveOnly = "SOLVE"
workflowTitle AutoSolve = "AUTOSOLVE"

workflowActivity :: SolveWorkflow -> Text
workflowActivity SolveOnly = "solving"
workflowActivity AutoSolve = "autosolving"

solveReviewerLabel :: SolverBrand -> Text
solveReviewerLabel CodexSolver = claudeReviewerModel
solveReviewerLabel ClaudeSolver = codexReviewerModel

drawSolveInput :: SolveSession -> Widget Name
drawSolveInput session
  | session.solveSessionPhase == SolveAttention,
    Just progress <- session.solveSessionAutoProgress,
    progress.autoSolveStage == AutoReviewing =
      padTop (Pad 1)
        . withAttr attentionAttr
        . txtWrap
        $ "The PR agent needs input. Press Enter to open that session, or use p processes."
drawSolveInput session
  | session.solveSessionPhase == SolveAttention =
      padTop (Pad 1)
        . withAttr attentionAttr
        . txtWrap
        $ "> " <> session.solveSessionInput <> "█"
  | otherwise = emptyWidget

drawPullRequestReview :: AppState -> Int -> Widget Name
drawPullRequestReview state number = case Map.lookup number state.appPullRequestReviewSessions of
  Nothing -> withAttr problemAttr (txt "PR review/revision session is no longer available")
  Just session ->
    let transcript = transcriptFor state.appSettings.settingsChatVerbosity session.pullRequestSessionTranscript
     in
    vBox
      [ withAttr (pullRequestSessionAttribute session) (txt (pullRequestPhaseLabel session)),
        drawLiveActivity state (Map.member number state.appPullRequestProcesses) session.pullRequestSessionSpinnerFrame session.pullRequestSessionActivityStartedAt session.pullRequestSessionActivity,
        withAttr dimAttr (txt ("agent: " <> pullRequestAgentLabel session.pullRequestSessionAction session.pullRequestSessionBrand)),
        maybe emptyWidget (withAttr dimAttr . txt . ("full log: " <>) . Text.pack) session.pullRequestSessionLogPath,
        txt "",
        vLimit 20 . clickable PullRequestReviewViewport . viewport PullRequestReviewViewport Vertical . padRight Max $
          if Text.null transcript then withAttr dimAttr (txt "Waiting for agent output…") else txtWrap transcript,
        hBorder,
        if session.pullRequestSessionPhase == SolveAttention
          then padTop (Pad 1) . withAttr attentionAttr . txtWrap $ "> " <> session.pullRequestSessionInput <> "█"
          else emptyWidget,
        withAttr footerAttr (txt "Esc hide  Ctrl-C interrupt  Enter answer  arrows/wheel scroll")
      ]

pullRequestPhaseLabel :: PullRequestReviewSession -> Text
pullRequestPhaseLabel session = case session.pullRequestSessionPhase of
  SolveStarting -> "Starting PR " <> pullRequestActionText session.pullRequestSessionAction <> "…"
  SolveRunning -> "PR " <> pullRequestActionText session.pullRequestSessionAction <> " in progress"
  SolveInterrupting -> "Interrupting the current PR agent turn…"
  SolveAttention -> "PR workflow needs your input"
  SolveFinished -> "PR " <> pullRequestActionText session.pullRequestSessionAction <> " finished"
  SolveFailedPhase -> "PR " <> pullRequestActionText session.pullRequestSessionAction <> " failed"
  SolveKilledPhase -> "PR " <> pullRequestActionText session.pullRequestSessionAction <> " killed"
  SolveOrphanedPhase -> "PR " <> pullRequestActionText session.pullRequestSessionAction <> " has orphaned subprocesses"

pullRequestActionText :: PullRequestAction -> Text
pullRequestActionText PullRequestReview = "review"
pullRequestActionText PullRequestRevision = "revision"
pullRequestActionText PullRequestRereview = "rereview"

pullRequestAgentLabel :: PullRequestAction -> SolverBrand -> Text
pullRequestAgentLabel PullRequestRevision brand = solverLabel brand
pullRequestAgentLabel _ CodexSolver = "codex · " <> codexReviewerModel
pullRequestAgentLabel _ ClaudeSolver = "claude · " <> claudeReviewerModel

drawReview :: AppState -> Int -> Widget Name
drawReview state issueNumber = case Map.lookup issueNumber state.appReviewSessions of
  Nothing -> withAttr problemAttr (txt "Review session is no longer available")
  Just session ->
    let transcript = transcriptFor state.appSettings.settingsChatVerbosity session.reviewSessionTranscript
     in
    vBox
      [ drawReviewTabs state issueNumber,
        txt "",
        withAttr (reviewPhaseAttribute session.reviewSessionPhase) (txt (reviewPhaseLabel session)),
        txt "",
        vLimit 17
          . clickable ReviewViewport
          . viewport ReviewViewport Vertical
          . padRight Max
          $ if Text.null transcript
            then withAttr dimAttr (txt "Waiting for Codex output…")
            else txtWrap transcript,
        hBorder,
        drawPendingInteraction session,
        drawReviewInput session,
        withAttr footerAttr (txt "Esc hide  Tab next session  Enter send  Ctrl-C interrupt  arrows/wheel scroll")
      ]

drawReviewTabs :: AppState -> Int -> Widget Name
drawReviewTabs state selectedIssue =
  hBox
    . intersperse (txt "  ")
    $ map drawTab (sortOn fst (Map.toList state.appReviewSessions))
  where
    drawTab (issueNumber, session) =
      withAttr
        (if issueNumber == selectedIssue then selectedAttr else reviewPhaseAttribute session.reviewSessionPhase)
        (txt ("#" <> showText issueNumber <> " " <> reviewPhaseGlyph state session))

reviewPhaseLabel :: ReviewSession -> Text
reviewPhaseLabel session = case session.reviewSessionPhase of
  ReviewStarting -> "Starting " <> stageActivity session.reviewSessionStage <> " session…"
  ReviewRunning -> stageActivity session.reviewSessionStage <> " in progress"
  ReviewWaiting -> "Waiting for your response"
  ReviewFinished -> case session.reviewSessionStage of
    IssueRevision -> "Specification amendment posted · Esc, then r for rereview"
    _ -> "Review completed"
  ReviewNeedsChanges -> case session.reviewSessionStage of
    IssueRevision -> "Specification revision remains blocked"
    _ -> "Review completed with changes requested"
  ReviewFailed -> stageActivity session.reviewSessionStage <> " failed"
  ReviewInterrupted -> stageActivity session.reviewSessionStage <> " interrupted"
  where
    stageActivity InitialReview = "review"
    stageActivity IssueRevision = "revision"
    stageActivity IssueRereview = "rereview"

drawPendingInteraction :: ReviewSession -> Widget Name
drawPendingInteraction session = case session.reviewSessionPending of
  Nothing -> emptyWidget
  Just (PendingReviewQuestion _ question) ->
    vBox
      ( [ withAttr pendingAttr (txtWrap question.reviewQuestionHeader),
          txtWrap question.reviewQuestionText
        ]
          <> zipWith drawChoice [1 :: Int ..] question.reviewQuestionChoices
          <> [withAttr dimAttr (txt "Press a choice number, or type a response when permitted.")]
      )
  Just (PendingReviewApproval _ approval) ->
    vBox
      [ withAttr pendingAttr (txt (if approval.reviewApprovalFileChange then "FILE CHANGE APPROVAL" else "COMMAND APPROVAL")),
        maybe emptyWidget txtWrap approval.reviewApprovalCommand,
        maybe emptyWidget (withAttr dimAttr . txtWrap) approval.reviewApprovalReason,
        txt "1  Allow this action once",
        txt "2  Allow similar actions for this review session",
        txt "3  Decline and return an error to the agent"
      ]
  where
    drawChoice index choice =
      txt (showText index <> "  " <> choice.reviewChoiceLabel)
        <+> if Text.null choice.reviewChoiceDescription
          then emptyWidget
          else withAttr dimAttr (txtWrap (" — " <> choice.reviewChoiceDescription))

drawReviewInput :: ReviewSession -> Widget Name
drawReviewInput session =
  padTop (Pad 1)
    . withAttr neutralAttr
    . txtWrap
    $ "> " <> session.reviewSessionInput <> "█"

drawDetails :: AppState -> BoardItem -> Widget Name
drawDetails state item =
  vBox
    ( [ withAttr cardTitleAttr (txtWrap (itemHeading item)),
        txt "",
        hBox (map drawLabelForDetails (itemLabels item) <> detailsOverflowMarker),
        txt "",
        withAttr headingAttr (txt "Metadata"),
        txtWrap (itemMetadata state item)
      ]
        <> trackingDetails
        <> trackerDiagnosticDetails
        <> [ txt "",
             withAttr headingAttr (txt "Body"),
             txtWrap (sanitizeText (itemBody item)),
             txt "",
             withAttr headingAttr (txt "URL"),
             withAttr linkAttr (txtWrap (itemUrl item))
           ]
    )
  where
    drawLabelForDetails label = withAttr (labelAttribute label.labelName) (txt (" " <> sanitizeText label.labelName <> " ")) <+> txt " "
    detailsOverflowMarker
      | itemLabelOverflow item > 0 = [withAttr pendingAttr (txt ("+" <> showText (itemLabelOverflow item) <> " labels omitted"))]
      | otherwise = []
    trackingDetails = case findEntry state.appBoard (itemId item) of
      Just (Tracked context _) -> drawTrackingDetails context
      _ -> []
    trackerDiagnosticDetails = case item of
      IssueItem issue -> drawTrackerDiagnosticDetails (trackerDiagnosticsForIssue defaultWorkflowConfig issue)
      PullRequestItem _ -> []

drawTrackerDiagnosticDetails :: [TrackerDiagnostic] -> [Widget Name]
drawTrackerDiagnosticDetails [] = []
drawTrackerDiagnosticDetails diagnostics =
  [txt "", withAttr pendingAttr (txt "Tracker warnings")]
    <> map (withAttr pendingAttr . txtWrap . ("• " <>) . renderTrackerDiagnostic) diagnostics

drawTrackingDetails :: TrackingContext -> [Widget Name]
drawTrackingDetails context =
  [ txt "",
    withAttr headingAttr (txt "Tracker"),
    drawMembership context.trackingPrimary
  ]
    <> map drawMembership context.trackingAdditional
    <> completionWarning
    <> multiTrackerWarning
    <> trackerWarnings
  where
    drawMembership membership =
      let tracker = membership.membershipTracker
          child = membership.membershipChild
          key = maybe ("step " <> showText (child.trackerChildChecklistOrder + 1)) id child.trackerChildImplementationKey
       in withAttr trackerAttr
            . txtWrap
            $ key
              <> " under #"
              <> showText tracker.trackerIssue.issueNumber
              <> " "
              <> sanitizeText tracker.trackerIssue.issueTitle
              <> " ("
              <> showText tracker.trackerCompleted
              <> "/"
              <> showText tracker.trackerTotal
              <> " complete)"
    completionWarning
      | context.trackingPrimary.membershipChild.trackerChildComplete =
          [withAttr pendingAttr (txtWrap "Checklist marks this still-open item complete")]
      | otherwise = []
    multiTrackerWarning
      | null context.trackingAdditional = []
      | otherwise = [withAttr pendingAttr (txtWrap "MULTI-TRACKED: memberships are listed in deterministic priority order")]
    trackerWarnings =
      concatMap
        (drawTrackerDiagnosticDetails . (.membershipTracker.trackerDiagnostics))
        (context.trackingPrimary : context.trackingAdditional)

relativeAge :: UTCTime -> UTCTime -> Text
relativeAge now thenTime
  | seconds < 60 = "now"
  | seconds < 3600 = showText (seconds `div` 60) <> "m ago"
  | seconds < 86400 = showText (seconds `div` 3600) <> "h ago"
  | otherwise = showText (seconds `div` 86400) <> "d ago"
  where
    seconds = max 0 (floor (diffUTCTime now thenTime) :: Int)

itemUrl :: BoardItem -> Text
itemUrl (IssueItem issue) = issue.issueUrl
itemUrl (PullRequestItem pullRequest) = pullRequest.pullRequestUrl

handleEvent :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleEvent event = do
  now <- liftIO getCurrentTime
  modify (\state -> state {appNow = now})
  state <- get
  case (state.appOverlay, event) of
    (_, AppEvent (BoardRefreshFinished result)) -> applyBoardRefresh result
    (_, AppEvent (CodexRefreshFinished result)) -> applyCodexRefresh result
    (_, AppEvent (ClaudeRefreshFinished result)) -> applyClaudeRefresh result
    (_, AppEvent (DrainerStatusRefreshed result)) -> applyDrainerStatus result
    (_, AppEvent (DrainerToggleFinished result)) -> applyDrainerToggle result
    (_, AppEvent (ReviewBackendStarted result)) -> applyReviewBackendStarted result
    (_, AppEvent (ReviewProtocolEvent reviewEvent)) -> applyReviewEvent reviewEvent
    (_, AppEvent (ReviewAnimationTick threadId)) -> applyReviewAnimationTick threadId
    (_, AppEvent (SolveProtocolEvent solveEvent)) -> applySolveEvent solveEvent
    (_, AppEvent (SolveAnimationTick issueNumber)) -> applySolveAnimationTick issueNumber
    (_, AppEvent SolveBoardRefreshRequested) -> startBoardRefresh
    (_, AppEvent (PullRequestProtocolEvent flowEvent)) -> applyPullRequestFlowEvent flowEvent
    (_, AppEvent (PullRequestAnimationTick number)) -> applyPullRequestAnimationTick number
    (_, AppEvent (WorkerRegistered descriptor)) -> registerWorker descriptor
    (_, AppEvent (WorkerProtocolEvent descriptor workerEvent)) -> applyWorkerProtocolEvent descriptor workerEvent
    (_, AppEvent (WorkerDiscoveryFinished descriptors)) -> mapM_ attachDiscoveredWorker descriptors
    (_, AppEvent (CanonicalIssueReviewProcessStarted issueNumber process)) -> do
      modify (\current -> current {appCanonicalReviewProcesses = Map.insert issueNumber process current.appCanonicalReviewProcesses})
      modifyReviewSession issueNumber (\session -> session {reviewSessionActivity = "reviewing issue"})
    (_, AppEvent (CanonicalIssueReviewFinished issueNumber stage result)) -> applyCanonicalIssueReview issueNumber stage result
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'q') [])) -> requestDashboardQuit
    (Just HelpOverlay, VtyEvent (Vty.EvKey (Vty.KChar 'q') [])) -> requestDashboardQuit
    (Just (DetailsOverlay _), VtyEvent (Vty.EvKey (Vty.KChar 'q') [])) -> requestDashboardQuit
    (Just SettingsOverlay, VtyEvent (Vty.EvKey (Vty.KChar '1') [])) -> chooseChatVerbosity CompactChat
    (Just SettingsOverlay, VtyEvent (Vty.EvKey (Vty.KChar '2') [])) -> chooseChatVerbosity StandardChat
    (Just SettingsOverlay, VtyEvent (Vty.EvKey (Vty.KChar '3') [])) -> chooseChatVerbosity FullChat
    (Just SettingsOverlay, VtyEvent (Vty.EvKey Vty.KEsc [])) -> closeOverlay
    (Just SettingsOverlay, _) -> pure ()
    (Just ProcessesOverlay, VtyEvent (Vty.EvKey Vty.KEsc [])) -> closeOverlay
    (Just ProcessesOverlay, VtyEvent (Vty.EvKey Vty.KDown [])) -> moveProcessSelection 1
    (Just ProcessesOverlay, VtyEvent (Vty.EvKey (Vty.KChar 'j') [])) -> moveProcessSelection 1
    (Just ProcessesOverlay, VtyEvent (Vty.EvKey Vty.KUp [])) -> moveProcessSelection (-1)
    (Just ProcessesOverlay, VtyEvent (Vty.EvKey (Vty.KChar 'k') [])) -> moveProcessSelection (-1)
    (Just ProcessesOverlay, VtyEvent (Vty.EvKey Vty.KEnter [])) -> openSelectedAgentSession
    (Just ProcessesOverlay, VtyEvent (Vty.EvKey (Vty.KChar 'x') [])) -> killSelectedAgentSession
    (Just ProcessesOverlay, MouseDown ProcessesPanel Vty.BScrollUp _ _) -> scrollProcesses (-3)
    (Just ProcessesOverlay, MouseDown ProcessesPanel Vty.BScrollDown _ _) -> scrollProcesses 3
    (Just ProcessesOverlay, MouseDown (ProcessTarget index) Vty.BLeft _ _) -> selectOrOpenAgentSession index
    (Just ProcessesOverlay, MouseDown ProcessesPanel _ _ _) -> pure ()
    (Just ProcessesOverlay, _) -> pure ()
    (Just (ReviewOverlay _), VtyEvent (Vty.EvKey Vty.KEsc [])) -> closeOverlay
    (Just (ReviewOverlay _), MouseDown ReviewPanel Vty.BRight _ _) -> closeOverlay
    (Just (ReviewOverlay _), MouseDown ReviewViewport Vty.BScrollUp _ _) -> scrollReview (-3)
    (Just (ReviewOverlay _), MouseDown ReviewViewport Vty.BScrollDown _ _) -> scrollReview 3
    (Just (ReviewOverlay _), MouseDown ReviewPanel Vty.BScrollUp _ _) -> scrollReview (-3)
    (Just (ReviewOverlay _), MouseDown ReviewPanel Vty.BScrollDown _ _) -> scrollReview 3
    (Just (ReviewOverlay _), MouseDown ReviewPanel _ _ _) -> pure ()
    (Just (ReviewOverlay _), VtyEvent (Vty.EvMouseDown _ _ Vty.BScrollUp _)) -> scrollReview (-3)
    (Just (ReviewOverlay _), VtyEvent (Vty.EvMouseDown _ _ Vty.BScrollDown _)) -> scrollReview 3
    (Just (ReviewOverlay _), MouseDown _ _ _ _) -> closeOverlay
    (Just (ReviewOverlay _), VtyEvent (Vty.EvMouseDown _ _ _ _)) -> closeOverlay
    (Just (ReviewOverlay issueNumber), reviewInputEvent) -> handleReviewOverlayEvent issueNumber reviewInputEvent
    (Just (SolveChooser workflow issue), VtyEvent (Vty.EvKey (Vty.KChar '1') [])) -> startIssueSolve issue workflow CodexSolver
    (Just (SolveChooser workflow issue), VtyEvent (Vty.EvKey (Vty.KChar '2') [])) -> startIssueSolve issue workflow ClaudeSolver
    (Just (SolveChooser _ _), VtyEvent (Vty.EvKey Vty.KEsc [])) -> closeOverlay
    (Just (SolveChooser _ _), _) -> pure ()
    (Just (SolveOverlay _), VtyEvent (Vty.EvKey Vty.KEsc [])) -> closeOverlay
    (Just (SolveOverlay issueNumber), VtyEvent (Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl])) -> interruptSolveSession issueNumber
    (Just (SolveOverlay _), MouseDown SolvePanel Vty.BRight _ _) -> closeOverlay
    (Just (SolveOverlay _), MouseDown SolveViewport Vty.BScrollUp _ _) -> scrollSolve (-3)
    (Just (SolveOverlay _), MouseDown SolveViewport Vty.BScrollDown _ _) -> scrollSolve 3
    (Just (SolveOverlay _), MouseDown SolvePanel Vty.BScrollUp _ _) -> scrollSolve (-3)
    (Just (SolveOverlay _), MouseDown SolvePanel Vty.BScrollDown _ _) -> scrollSolve 3
    (Just (SolveOverlay _), MouseDown SolvePanel _ _ _) -> pure ()
    (Just (SolveOverlay _), VtyEvent (Vty.EvMouseDown _ _ Vty.BScrollUp _)) -> scrollSolve (-3)
    (Just (SolveOverlay _), VtyEvent (Vty.EvMouseDown _ _ Vty.BScrollDown _)) -> scrollSolve 3
    (Just (SolveOverlay _), MouseDown _ _ _ _) -> closeOverlay
    (Just (SolveOverlay _), VtyEvent (Vty.EvMouseDown _ _ _ _)) -> closeOverlay
    (Just (SolveOverlay issueNumber), solveInputEvent) -> handleSolveOverlayEvent issueNumber solveInputEvent
    (Just (PullRequestReviewOverlay _), VtyEvent (Vty.EvKey Vty.KEsc [])) -> closeOverlay
    (Just (PullRequestReviewOverlay number), VtyEvent (Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl])) -> interruptPullRequestSession number
    (Just (PullRequestReviewOverlay _), MouseDown PullRequestReviewPanel Vty.BRight _ _) -> closeOverlay
    (Just (PullRequestReviewOverlay _), MouseDown PullRequestReviewViewport Vty.BScrollUp _ _) -> scrollPullRequestReview (-3)
    (Just (PullRequestReviewOverlay _), MouseDown PullRequestReviewViewport Vty.BScrollDown _ _) -> scrollPullRequestReview 3
    (Just (PullRequestReviewOverlay _), MouseDown PullRequestReviewPanel _ _ _) -> pure ()
    (Just (PullRequestReviewOverlay _), MouseDown _ _ _ _) -> closeOverlay
    (Just (PullRequestReviewOverlay number), inputEvent) -> handlePullRequestOverlayEvent number inputEvent
    (Just (DetailsOverlay item), VtyEvent (Vty.EvKey (Vty.KChar 'r') [])) -> startItemReview item
    (Just (DetailsOverlay item), VtyEvent (Vty.EvKey (Vty.KChar 'S') [])) -> openItemSolveChooser SolveOnly item
    (Just (DetailsOverlay item), VtyEvent (Vty.EvKey (Vty.KChar 'A') [])) -> openItemSolveChooser AutoSolve item
    (Just (DetailsOverlay item), VtyEvent (Vty.EvKey (Vty.KChar 'x') [])) -> killItemWorkingProcess item
    (Just (DetailsOverlay _), MouseDown DetailsPanel Vty.BRight _ _) -> closeOverlay
    (Just (DetailsOverlay _), MouseDown DetailsPanel _ _ _) -> pure ()
    (Just (DetailsOverlay _), MouseDown _ _ _ _) -> closeOverlay
    (Just (DetailsOverlay _), VtyEvent (Vty.EvMouseDown _ _ _ _)) -> closeOverlay
    (Just _, VtyEvent (Vty.EvKey Vty.KEsc [])) -> modify (\current -> current {appOverlay = Nothing, appNotice = Nothing})
    (Just _, VtyEvent (Vty.EvKey Vty.KDown [])) -> vScrollBy (viewportScroll DetailsViewport) 1
    (Just _, VtyEvent (Vty.EvKey (Vty.KChar 'j') [])) -> vScrollBy (viewportScroll DetailsViewport) 1
    (Just _, VtyEvent (Vty.EvKey Vty.KUp [])) -> vScrollBy (viewportScroll DetailsViewport) (-1)
    (Just _, VtyEvent (Vty.EvKey (Vty.KChar 'k') [])) -> vScrollBy (viewportScroll DetailsViewport) (-1)
    (Just _, _) -> pure ()
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar '?') [])) -> modify (\current -> current {appOverlay = Just HelpOverlay})
    (Nothing, VtyEvent (Vty.EvKey Vty.KEnter [])) -> openSelectedDetails
    (Nothing, VtyEvent (Vty.EvKey Vty.KDown [])) -> moveCard 1
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'j') [])) -> moveCard 1
    (Nothing, VtyEvent (Vty.EvKey Vty.KUp [])) -> moveCard (-1)
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'k') [])) -> moveCard (-1)
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'x') [])) -> killSelectedWorkingProcess
    (Nothing, VtyEvent (Vty.EvKey Vty.KLeft [])) -> moveColumn (-1)
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'h') [])) -> moveColumn (-1)
    (Nothing, VtyEvent (Vty.EvKey Vty.KRight [])) -> moveColumn 1
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'l') [])) -> moveColumn 1
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'g') [])) -> selectBoundary False
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'G') [])) -> selectBoundary True
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'e') [])) -> toggleSelectedTracker
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'c') [])) -> modify (\current -> current {appSidebarVisible = not current.appSidebarVisible})
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 's') [])) -> modify (\current -> current {appOverlay = Just SettingsOverlay, appNotice = Nothing})
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'p') [])) -> openProcesses
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'r') [])) -> startSelectedReview
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'S') [])) -> openSelectedSolveChooser SolveOnly
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'A') [])) -> openSelectedSolveChooser AutoSolve
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'u') [])) -> startAllRefreshes
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'd') [])) -> toggleDrainer
    (Nothing, MouseDown DrainerButton Vty.BLeft [] _) -> toggleDrainer
    (Nothing, MouseDown (EpicTarget column _ _) Vty.BScrollUp _ _) -> scrollColumn column (-3)
    (Nothing, MouseDown (EpicTarget column _ _) Vty.BScrollDown _ _) -> scrollColumn column 3
    (Nothing, MouseDown (EpicTarget column row trackerNumber) Vty.BLeft _ _) -> toggleTrackerFromClick column row trackerNumber
    (Nothing, MouseDown (CardTarget column row) Vty.BRight _ _) -> openRunningProcessOrSelect column row
    (Nothing, MouseDown (CardTarget column row) Vty.BLeft _ _) -> selectOrOpenCard column row
    (Nothing, MouseDown (CardTarget column _) Vty.BScrollUp _ _) -> scrollColumn column (-3)
    (Nothing, MouseDown (CardTarget column _) Vty.BScrollDown _ _) -> scrollColumn column 3
    (Nothing, MouseDown (ColumnViewport column) Vty.BScrollUp _ _) -> scrollColumn column (-3)
    (Nothing, MouseDown (ColumnViewport column) Vty.BScrollDown _ _) -> scrollColumn column 3
    (Nothing, VtyEvent (Vty.EvKey (Vty.KChar 'l') [Vty.MCtrl])) -> setNotice "Terminal repaint requested"
    _ -> pure ()

setNotice :: Text -> EventM Name AppState ()
setNotice message = modify (\state -> state {appNotice = Just message})

requestDashboardQuit :: EventM Name AppState ()
requestDashboardQuit = do
  state <- get
  let liveInteractiveReviews =
        [ issueNumber
          | (issueNumber, session) <- Map.toList state.appReviewSessions,
            reviewSessionHasLiveTurn session || Map.member issueNumber state.appCanonicalReviewProcesses
        ]
  if null liveInteractiveReviews
    then halt
    else
      modify
        ( \current ->
            current
              { appOverlay = Nothing,
                appNotice =
                  Just
                    ( "Finish or kill the non-persistent issue review"
                        <> (if length liveInteractiveReviews == 1 then " " else "s ")
                        <> Text.intercalate ", " (map (("#" <>) . showText) liveInteractiveReviews)
                        <> " before quitting; solve and PR workers may be safely left running"
                    )
              }
        )
  where
    reviewSessionHasLiveTurn session =
      session.reviewSessionPhase `elem` [ReviewStarting, ReviewRunning, ReviewWaiting]

closeOverlay :: EventM Name AppState ()
closeOverlay = modify (\state -> state {appOverlay = Nothing, appNotice = Nothing})

chooseChatVerbosity :: ChatVerbosity -> EventM Name AppState ()
chooseChatVerbosity verbosity = do
  state <- get
  let settings = state.appSettings {settingsChatVerbosity = verbosity}
  result <- liftIO (saveSettings settings)
  case result of
    Left message -> setNotice message
    Right () ->
      modify
        ( \current ->
            current
              { appSettings = settings,
                appNotice = Just ("Chat output set to " <> Text.toLower (verbosityLabel verbosity) <> " · full logs remain unchanged")
              }
        )

openProcesses :: EventM Name AppState ()
openProcesses = do
  state <- get
  let maximumIndex = max 0 (length (agentSessionEntries state) - 1)
  modify
    ( \current ->
        current
          { appOverlay = Just ProcessesOverlay,
            appProcessSelection = min current.appProcessSelection maximumIndex,
            appNotice = Nothing
          }
    )

moveProcessSelection :: Int -> EventM Name AppState ()
moveProcessSelection amount = do
  state <- get
  let maximumIndex = max 0 (length (agentSessionEntries state) - 1)
      nextIndex = max 0 (min maximumIndex (state.appProcessSelection + amount))
  modify (\current -> current {appProcessSelection = nextIndex})

scrollProcesses :: Int -> EventM Name AppState ()
scrollProcesses amount = do
  moveProcessSelection amount
  vScrollBy (viewportScroll ProcessesViewport) amount

selectOrOpenAgentSession :: Int -> EventM Name AppState ()
selectOrOpenAgentSession index = do
  selected <- (.appProcessSelection) <$> get
  if selected == index
    then openSelectedAgentSession
    else modify (\state -> state {appProcessSelection = index})

openSelectedAgentSession :: EventM Name AppState ()
openSelectedAgentSession = do
  state <- get
  case safeIndex state.appProcessSelection (agentSessionEntries state) of
    Nothing -> setNotice "No agent session is selected"
    Just entry -> case entry.agentSessionRef of
      SolveAgent issueNumber -> modify (\current -> current {appOverlay = Just (SolveOverlay issueNumber), appNotice = Nothing})
      PullRequestAgent number -> modify (\current -> current {appOverlay = Just (PullRequestReviewOverlay number), appNotice = Nothing})
      ReviewAgent issueNumber -> modify (\current -> current {appOverlay = Just (ReviewOverlay issueNumber), appNotice = Nothing})
      WorkerAgent _ -> setNotice "This persistent worker is waiting for its issue or PR metadata; press u to refresh the board"

killSelectedAgentSession :: EventM Name AppState ()
killSelectedAgentSession = do
  state <- get
  case safeIndex state.appProcessSelection (agentSessionEntries state) of
    Nothing -> setNotice "No agent session is selected"
    Just entry
      | not entry.agentSessionLive -> setNotice (entry.agentSessionLabel <> " has no live process to kill")
      | otherwise -> case entry.agentSessionRef of
          SolveAgent issueNumber -> killSolveAgent issueNumber
          PullRequestAgent number -> case Map.lookup number state.appPullRequestReviewSessions of
            Nothing -> setNotice "PR session is no longer available"
            Just session -> killItemWorkingProcess (PullRequestItem session.pullRequestSessionPullRequest)
          ReviewAgent issueNumber -> killReviewAgent issueNumber
          WorkerAgent identifier -> case Map.lookup identifier state.appWorkers of
            Nothing -> setNotice "Persistent worker is no longer available"
            Just descriptor -> do
              modify
                ( \current ->
                    current
                      { appWorkers = Map.delete identifier current.appWorkers,
                        appWorkerMonitors = Set.delete identifier current.appWorkerMonitors
                      }
                )
              void . liftIO . forkIO $ terminateWorker descriptor
              setNotice ("Killing " <> entry.agentSessionLabel <> " and its process tree…")

killSolveAgent :: Int -> EventM Name AppState ()
killSolveAgent issueNumber = do
  state <- get
  case (solveWorkerFor state issueNumber, Map.lookup issueNumber state.appSolveProcesses) of
    (Nothing, Nothing) -> setNotice ("Solve #" <> showText issueNumber <> " has no live process to kill")
    (worker, process) -> do
      modifySolveSession issueNumber
        ( \session ->
            session
              { solveSessionPhase = SolveKilledPhase,
                solveSessionActivity = "killing process tree",
                solveSessionTranscript = appendSolveTranscript session.solveSessionTranscript "\n[killed by user]\n"
              }
        )
      void . liftIO . forkIO $ case worker of
        Just descriptor -> terminateWorker descriptor
        Nothing -> mapM_ killManagedProcess process
      setNotice ("Killing solve #" <> showText issueNumber <> " and its process tree…")

killReviewAgent :: Int -> EventM Name AppState ()
killReviewAgent issueNumber = do
  state <- get
  let canonicalProcess = Map.lookup issueNumber state.appCanonicalReviewProcesses
      activeTurn = do
        session <- Map.lookup issueNumber state.appReviewSessions
        client <- case state.appReviewBackend of
          ReviewBackendReady value -> Just value
          _ -> Nothing
        threadId <- session.reviewSessionThreadId
        turnId <- session.reviewSessionTurnId
        if reviewSessionActive session then Just (client, threadId, turnId) else Nothing
  case (canonicalProcess, activeTurn) of
    (Nothing, Nothing) -> setNotice ("Issue review #" <> showText issueNumber <> " has no live process to kill")
    _ -> do
      modifyReviewSession issueNumber
        ( \session ->
            session
              { reviewSessionPhase = ReviewFailed,
                reviewSessionActivity = "killing process tree",
                reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript "\n[killed by user]\n"
              }
        )
      mapM_ (\process -> void . liftIO . forkIO $ killManagedProcess process) canonicalProcess
      case activeTurn of
        Nothing -> pure ()
        Just (client, threadId, turnId) -> do
          void . liftIO . forkIO $ killReviewTools client threadId
          void (liftIO (interruptReview client threadId turnId))
      setNotice ("Killing issue review #" <> showText issueNumber <> " and its process tree…")

killSelectedWorkingProcess :: EventM Name AppState ()
killSelectedWorkingProcess = do
  state <- get
  case selectedReviewItem state of
    Nothing -> setNotice "Select a working issue or PR before pressing k"
    Just item -> killItemWorkingProcess item

killItemWorkingProcess :: BoardItem -> EventM Name AppState ()
killItemWorkingProcess (PullRequestItem pullRequest) = do
  state <- get
  let number = pullRequest.pullRequestNumber
  case (pullRequestWorkerFor state number, Map.lookup number state.appPullRequestProcesses) of
    (Nothing, Nothing) -> setNotice ("PR #" <> showText number <> " has no live process to kill")
    (worker, process) -> do
      modifyPullRequestSession number
        ( \session ->
            session
              { pullRequestSessionPhase = SolveKilledPhase,
                pullRequestSessionActivity = "killing process tree",
                pullRequestSessionTranscript = appendSolveTranscript session.pullRequestSessionTranscript "\n[killed by user]\n"
              }
        )
      void . liftIO . forkIO $ case worker of
        Just descriptor -> terminateWorker descriptor
        Nothing -> mapM_ killManagedProcess process
      setNotice ("Killing PR workflow #" <> showText number <> " and its process tree…")
killItemWorkingProcess (IssueItem issue) = do
  state <- get
  let issueNumber = issue.issueNumber
      solveProcess = Map.lookup issueNumber state.appSolveProcesses
      solveWorker = solveWorkerFor state issueNumber
      canonicalProcess = Map.lookup issueNumber state.appCanonicalReviewProcesses
      reviewSession = Map.lookup issueNumber state.appReviewSessions
      activeReview = reviewSession >>= activeReviewTurn state
  case (solveWorker, solveProcess, canonicalProcess, activeReview) of
    (Nothing, Nothing, Nothing, Nothing) -> setNotice ("Issue #" <> showText issueNumber <> " has no live process to kill")
    _ -> do
      case (solveWorker, solveProcess) of
        (Nothing, Nothing) -> pure ()
        (worker, process) -> do
          modifySolveSession issueNumber
            ( \session ->
                session
                  { solveSessionPhase = SolveKilledPhase,
                    solveSessionActivity = "killing process tree",
                    solveSessionTranscript = appendSolveTranscript session.solveSessionTranscript "\n[killed by user]\n"
                  }
            )
          void . liftIO . forkIO $ case worker of
            Just descriptor -> terminateWorker descriptor
            Nothing -> mapM_ killManagedProcess process
      case canonicalProcess of
        Nothing -> pure ()
        Just process -> do
          modifyReviewSession issueNumber
            ( \session ->
                session
                  { reviewSessionPhase = ReviewFailed,
                    reviewSessionActivity = "killing process tree",
                    reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript "\n[killed by user]\n"
                  }
            )
          void . liftIO . forkIO $ killManagedProcess process
      reviewInterruption <- case activeReview of
        Nothing -> pure (Right ())
        Just (client, threadId, turnId) -> do
          void . liftIO . forkIO $ killReviewTools client threadId
          liftIO (interruptReview client threadId turnId)
      case reviewInterruption of
        Left message -> setNotice ("Process-tree kill started, but review interruption failed: " <> message)
        Right () -> setNotice ("Killing work for issue #" <> showText issueNumber <> " and its process tree…")
  where
    activeReviewTurn state session
      | reviewSessionActive session,
        ReviewBackendReady client <- state.appReviewBackend,
        Just threadId <- session.reviewSessionThreadId,
        Just turnId <- session.reviewSessionTurnId = Just (client, threadId, turnId)
      | otherwise = Nothing

scrollReview :: Int -> EventM Name AppState ()
scrollReview = vScrollBy (viewportScroll ReviewViewport)

scrollSolve :: Int -> EventM Name AppState ()
scrollSolve = vScrollBy (viewportScroll SolveViewport)

scrollPullRequestReview :: Int -> EventM Name AppState ()
scrollPullRequestReview = vScrollBy (viewportScroll PullRequestReviewViewport)

handlePullRequestOverlayEvent :: Int -> BrickEvent Name AppEvent -> EventM Name AppState ()
handlePullRequestOverlayEvent number event = case event of
  VtyEvent (Vty.EvKey Vty.KDown []) -> vScrollBy (viewportScroll PullRequestReviewViewport) 1
  VtyEvent (Vty.EvKey Vty.KUp []) -> vScrollBy (viewportScroll PullRequestReviewViewport) (-1)
  VtyEvent (Vty.EvKey Vty.KBS []) -> modifyPullRequestSession number (\session -> session {pullRequestSessionInput = Text.dropEnd 1 session.pullRequestSessionInput})
  VtyEvent (Vty.EvKey Vty.KEnter []) -> submitPullRequestInput number
  VtyEvent (Vty.EvKey (Vty.KChar character) [])
    | isPrint character -> modifyPullRequestSession number (\session -> session {pullRequestSessionInput = Text.take reviewInputLimit (session.pullRequestSessionInput <> Text.singleton character)})
  _ -> pure ()

handleSolveOverlayEvent :: Int -> BrickEvent Name AppEvent -> EventM Name AppState ()
handleSolveOverlayEvent issueNumber event = case event of
  VtyEvent (Vty.EvKey Vty.KDown []) -> vScrollBy (viewportScroll SolveViewport) 1
  VtyEvent (Vty.EvKey Vty.KUp []) -> vScrollBy (viewportScroll SolveViewport) (-1)
  VtyEvent (Vty.EvKey Vty.KBS []) -> modifySolveSession issueNumber (\session -> session {solveSessionInput = Text.dropEnd 1 session.solveSessionInput})
  VtyEvent (Vty.EvKey Vty.KEnter []) -> submitSolveInput issueNumber
  VtyEvent (Vty.EvKey (Vty.KChar character) [])
    | isPrint character ->
        modifySolveSession issueNumber
          (\session -> session {solveSessionInput = Text.take reviewInputLimit (session.solveSessionInput <> Text.singleton character)})
  _ -> pure ()

handleReviewOverlayEvent :: Int -> BrickEvent Name AppEvent -> EventM Name AppState ()
handleReviewOverlayEvent issueNumber event = case event of
  VtyEvent (Vty.EvKey (Vty.KChar '\t') []) -> cycleReviewSession issueNumber
  VtyEvent (Vty.EvKey Vty.KDown []) -> vScrollBy (viewportScroll ReviewViewport) 1
  VtyEvent (Vty.EvKey (Vty.KChar 'j') [Vty.MCtrl]) -> vScrollBy (viewportScroll ReviewViewport) 1
  VtyEvent (Vty.EvKey Vty.KUp []) -> vScrollBy (viewportScroll ReviewViewport) (-1)
  VtyEvent (Vty.EvKey (Vty.KChar 'k') [Vty.MCtrl]) -> vScrollBy (viewportScroll ReviewViewport) (-1)
  VtyEvent (Vty.EvKey (Vty.KChar 'x') [Vty.MCtrl]) -> cancelReviewSession issueNumber
  VtyEvent (Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl]) -> cancelReviewSession issueNumber
  VtyEvent (Vty.EvKey Vty.KBS []) -> modifyReviewSession issueNumber removeReviewInputCharacter
  VtyEvent (Vty.EvKey Vty.KEnter []) -> submitReviewInput issueNumber
  VtyEvent (Vty.EvKey (Vty.KChar character) [])
    | character >= '1' && character <= '9' -> chooseReviewOption issueNumber (fromEnum character - fromEnum '1')
    | isPrint character -> modifyReviewSession issueNumber (appendReviewInput character)
  _ -> pure ()

appendReviewInput :: Char -> ReviewSession -> ReviewSession
appendReviewInput character session =
  session {reviewSessionInput = Text.take reviewInputLimit (session.reviewSessionInput <> Text.singleton character)}

removeReviewInputCharacter :: ReviewSession -> ReviewSession
removeReviewInputCharacter session = session {reviewSessionInput = Text.dropEnd 1 session.reviewSessionInput}

-- | What a digit key '1'..'9' should do given the pending review
-- interaction (if any) and the 0-based choice index it encodes. Pulled out
-- of 'chooseReviewOption' so the dispatch rules are unit-testable without an
-- 'EventM' harness.
data ReviewDigitAction
  = ReviewDigitAppend
  | ReviewDigitSelectChoice ReviewRequestId ReviewChoice
  | ReviewDigitApprovalOnce ReviewRequestId
  | ReviewDigitApprovalSession ReviewRequestId
  | ReviewDigitApprovalDecline ReviewRequestId
  | ReviewDigitUnavailable Text
  deriving stock (Eq, Show)

resolveReviewDigitAction :: Maybe PendingReviewInteraction -> Int -> ReviewDigitAction
resolveReviewDigitAction pending choiceIndex = case pending of
  Just (PendingReviewQuestion requestId question)
    | question.reviewQuestionKind == QuestionText -> ReviewDigitAppend
    | otherwise -> case safeIndex choiceIndex question.reviewQuestionChoices of
        Just choice -> ReviewDigitSelectChoice requestId choice
        Nothing
          | question.reviewQuestionAllowOther -> ReviewDigitAppend
          | otherwise -> ReviewDigitUnavailable "That review choice is not available"
  Just (PendingReviewApproval requestId _approval) -> case choiceIndex of
    0 -> ReviewDigitApprovalOnce requestId
    1 -> ReviewDigitApprovalSession requestId
    2 -> ReviewDigitApprovalDecline requestId
    _ -> ReviewDigitUnavailable "That approval choice is not available"
  Nothing -> ReviewDigitAppend

chooseReviewOption :: Int -> Int -> EventM Name AppState ()
chooseReviewOption issueNumber choiceIndex = do
  state <- get
  let pending = Map.lookup issueNumber state.appReviewSessions >>= (.reviewSessionPending)
  case resolveReviewDigitAction pending choiceIndex of
    ReviewDigitAppend -> modifyReviewSession issueNumber (appendReviewInput (toEnum (fromEnum '1' + choiceIndex)))
    ReviewDigitSelectChoice requestId choice -> submitQuestionAnswer issueNumber requestId (ReviewAnswer [choice.reviewChoiceId] Nothing) choice.reviewChoiceLabel
    ReviewDigitApprovalOnce requestId -> submitApprovalAnswer issueNumber requestId True False "Allowed this action once"
    ReviewDigitApprovalSession requestId -> submitApprovalAnswer issueNumber requestId True True "Allowed similar actions for this review session"
    ReviewDigitApprovalDecline requestId -> submitApprovalAnswer issueNumber requestId False False "Declined this action"
    ReviewDigitUnavailable message -> setNotice message

submitReviewInput :: Int -> EventM Name AppState ()
submitReviewInput issueNumber = do
  state <- get
  case Map.lookup issueNumber state.appReviewSessions of
    Nothing -> setNotice "Review session is no longer available"
    Just session
      | Text.null (Text.strip session.reviewSessionInput) -> setNotice "Type a message or select one of the numbered choices"
      | otherwise -> case session.reviewSessionPending of
          Just (PendingReviewQuestion requestId question)
            | question.reviewQuestionKind == QuestionText || question.reviewQuestionAllowOther ->
                let answerText = Text.strip session.reviewSessionInput
                 in submitQuestionAnswer issueNumber requestId (ReviewAnswer [] (Just answerText)) answerText
            | otherwise -> setNotice "This question requires one of the numbered choices"
          Just (PendingReviewApproval _ _) -> setNotice "Use 1, 2, or 3 to answer the approval request"
          Nothing -> sendReviewFeedback issueNumber session

submitQuestionAnswer :: Int -> ReviewRequestId -> ReviewAnswer -> Text -> EventM Name AppState ()
submitQuestionAnswer issueNumber requestId answer displayAnswer = do
  state <- get
  case state.appReviewBackend of
    ReviewBackendReady client -> do
      result <- liftIO (answerReviewQuestion client requestId answer)
      case result of
        Left message -> setNotice message
        Right () ->
          modifyReviewSession issueNumber
            ( \session ->
                session
                  { reviewSessionPhase = ReviewRunning,
                    reviewSessionActivity = "thinking",
                    reviewSessionPending = Nothing,
                    reviewSessionInput = "",
                    reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript ("\nYou: " <> displayAnswer <> "\n")
                  }
            )
          >> scheduleReviewForIssue issueNumber
    _ -> setNotice "Codex app-server is not connected"

submitApprovalAnswer :: Int -> ReviewRequestId -> Bool -> Bool -> Text -> EventM Name AppState ()
submitApprovalAnswer issueNumber requestId accepted forSession displayAnswer = do
  state <- get
  case state.appReviewBackend of
    ReviewBackendReady client -> do
      result <- liftIO (approveReviewAction client requestId accepted forSession)
      case result of
        Left message -> setNotice message
        Right () ->
          modifyReviewSession issueNumber
            ( \session ->
                session
                  { reviewSessionPhase = ReviewRunning,
                    reviewSessionActivity = "thinking",
                    reviewSessionPending = Nothing,
                    reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript ("\n" <> displayAnswer <> "\n")
                  }
            )
          >> scheduleReviewForIssue issueNumber
    _ -> setNotice "Codex app-server is not connected"

sendReviewFeedback :: Int -> ReviewSession -> EventM Name AppState ()
sendReviewFeedback issueNumber session = do
  state <- get
  case (state.appReviewBackend, session.reviewSessionThreadId) of
    (ReviewBackendReady client, Just threadId) -> do
      let message = Text.strip session.reviewSessionInput
      result <- liftIO (sendReviewMessage client threadId session.reviewSessionTurnId message)
      case result of
        Left errorMessage -> setNotice errorMessage
        Right () -> do
          modifyReviewSession issueNumber
            ( \current ->
                current
                  { reviewSessionInput = "",
                    reviewSessionPhase = ReviewRunning,
                    reviewSessionActivity = "thinking",
                    reviewSessionTranscript = appendReviewTranscript current.reviewSessionTranscript ("\nYou: " <> message <> "\n")
                  }
            )
    _ -> setNotice "The review session has not connected yet"

scheduleReviewForIssue :: Int -> EventM Name AppState ()
scheduleReviewForIssue issueNumber = do
  state <- get
  case Map.lookup issueNumber state.appReviewSessions >>= (.reviewSessionThreadId) of
    Just threadId -> scheduleReviewTick threadId
    Nothing -> pure ()

cancelReviewSession :: Int -> EventM Name AppState ()
cancelReviewSession issueNumber = do
  state <- get
  case Map.lookup issueNumber state.appReviewSessions of
    Just session -> case (state.appReviewBackend, session.reviewSessionThreadId, session.reviewSessionTurnId) of
      (ReviewBackendReady client, Just threadId, Just turnId) -> do
        void . liftIO . forkIO $ killReviewTools client threadId
        result <- liftIO (interruptReview client threadId turnId)
        case result of
          Left message -> setNotice message
          Right () -> setNotice ("Interrupting review #" <> showText issueNumber <> "; type guidance when the turn stops")
      _ -> setNotice "This review has no active turn to cancel"
    Nothing -> setNotice "Review session is no longer available"

cycleReviewSession :: Int -> EventM Name AppState ()
cycleReviewSession currentIssue = modify $ \state ->
  let issueNumbers = map fst (sortOn fst (Map.toList state.appReviewSessions))
      currentIndex = fromMaybe 0 (findIndex (== currentIssue) issueNumbers)
      nextIssue = safeIndex ((currentIndex + 1) `mod` max 1 (length issueNumbers)) issueNumbers
   in case nextIssue of
        Nothing -> state
        Just issueNumber -> state {appOverlay = Just (ReviewOverlay issueNumber), appNotice = Nothing}

modifyReviewSession :: Int -> (ReviewSession -> ReviewSession) -> EventM Name AppState ()
modifyReviewSession issueNumber update =
  modify (\state -> state {appReviewSessions = Map.adjust update issueNumber state.appReviewSessions})

modifyReviewSessionByThread :: Text -> (ReviewSession -> ReviewSession) -> EventM Name AppState ()
modifyReviewSessionByThread threadId update = modify $ \state ->
  case findReviewSessionByThread threadId state of
    Nothing -> state
    Just (issueNumber, _) -> state {appReviewSessions = Map.adjust update issueNumber state.appReviewSessions}

findReviewSessionByThread :: Text -> AppState -> Maybe (Int, ReviewSession)
findReviewSessionByThread threadId state =
  safeIndex 0
    [ (issueNumber, session)
      | (issueNumber, session) <- Map.toList state.appReviewSessions,
        session.reviewSessionThreadId == Just threadId
    ]

plainTranscript :: Text -> ChatTranscript
plainTranscript value = ChatTranscript value value value

transcriptFor :: ChatVerbosity -> ChatTranscript -> Text
transcriptFor CompactChat = (.compactTranscript)
transcriptFor StandardChat = (.standardTranscript)
transcriptFor FullChat = (.fullTranscript)

appendReviewTranscript :: ChatTranscript -> Text -> ChatTranscript
appendReviewTranscript transcript addition =
  ChatTranscript
    { compactTranscript = boundedAppend transcript.compactTranscript addition,
      standardTranscript = boundedAppend transcript.standardTranscript addition,
      fullTranscript = boundedAppend transcript.fullTranscript addition
    }

appendReviewOutput :: ReviewOutputKind -> Text -> ChatTranscript -> ChatTranscript
appendReviewOutput outputKind addition transcript =
  ChatTranscript
    { compactTranscript = appendWhen (showReviewOutput CompactChat outputKind) transcript.compactTranscript,
      standardTranscript = appendWhen (showReviewOutput StandardChat outputKind) transcript.standardTranscript,
      fullTranscript = appendWhen (showReviewOutput FullChat outputKind) transcript.fullTranscript
    }
  where
    appendWhen True value = boundedAppend value addition
    appendWhen False value = value

reviewOutputPrefix :: ReviewOutputKind -> Text
reviewOutputPrefix AgentOutput = ""
reviewOutputPrefix ReasoningOutput = ""
reviewOutputPrefix CommandOutput = ""
reviewOutputPrefix DiagnosticOutput = "[codex] "

reviewOutputActivity :: ReviewOutputKind -> Text
reviewOutputActivity AgentOutput = "responding"
reviewOutputActivity ReasoningOutput = "thinking"
reviewOutputActivity CommandOutput = "running command"
reviewOutputActivity DiagnosticOutput = "diagnostic output"

showReviewOutput :: ChatVerbosity -> ReviewOutputKind -> Bool
showReviewOutput CompactChat AgentOutput = True
showReviewOutput CompactChat _ = False
showReviewOutput StandardChat DiagnosticOutput = False
showReviewOutput StandardChat _ = True
showReviewOutput FullChat _ = True

whenReviewOverlayOpen :: (Int -> EventM Name AppState ()) -> EventM Name AppState ()
whenReviewOverlayOpen action = do
  state <- get
  case state.appOverlay of
    Just (ReviewOverlay issueNumber) -> action issueNumber
    _ -> pure ()

reviewInputLimit :: Int
reviewInputLimit = 4000

reviewTranscriptLimit :: Int
reviewTranscriptLimit = 50000

scrollColumn :: BoardColumn -> Int -> EventM Name AppState ()
scrollColumn column amount = do
  modify (\state -> state {appEnsureSelectionVisible = False})
  vScrollBy (viewportScroll (ColumnViewport column)) amount

selectOrOpenCard :: BoardColumn -> Int -> EventM Name AppState ()
selectOrOpenCard column row = modify $ \state ->
  if state.appSelectedColumn == column && selectedRow state column == row
    then case safeIndex row (entriesFor state column) of
      Just entry -> state {appOverlay = Just (DetailsOverlay (entryItem entry)), appNotice = Nothing}
      Nothing -> state
    else
      state
        { appSelectedColumn = column,
          appSelectedRows = Map.insert column row state.appSelectedRows,
          appEnsureSelectionVisible = True,
          appNotice = Nothing
        }

openRunningProcessOrSelect :: BoardColumn -> Int -> EventM Name AppState ()
openRunningProcessOrSelect column row =
  modify $ \state ->
    let selectedState = selectCardOnly column row state
     in case safeIndex row (entriesFor state column) >>= runningProcessOverlay state . entryItem of
          Nothing -> selectedState
          Just overlay -> selectedState {appOverlay = Just overlay}

selectCardOnly :: BoardColumn -> Int -> AppState -> AppState
selectCardOnly column row state =
  state
    { appSelectedColumn = column,
      appSelectedRows = Map.insert column row state.appSelectedRows,
      appEnsureSelectionVisible = True,
      appNotice = Nothing
    }

runningProcessOverlay :: AppState -> BoardItem -> Maybe Overlay
runningProcessOverlay state (PullRequestItem pullRequest)
  | Map.member pullRequest.pullRequestNumber state.appPullRequestProcesses || pullRequestWorkerFor state pullRequest.pullRequestNumber /= Nothing =
      Just (PullRequestReviewOverlay pullRequest.pullRequestNumber)
  | otherwise = Nothing
runningProcessOverlay state (IssueItem issue)
  | issueReviewIsActive = Just (ReviewOverlay issueNumber)
  | Map.member issueNumber state.appSolveProcesses || solveWorkerFor state issueNumber /= Nothing = Just (SolveOverlay issueNumber)
  | Just pullRequestNumber <- boundAutoSolvePullRequest,
    Map.member pullRequestNumber state.appPullRequestProcesses =
      Just (PullRequestReviewOverlay pullRequestNumber)
  | otherwise = Nothing
  where
    issueNumber = issue.issueNumber
    issueReviewIsActive =
      Map.member issueNumber state.appCanonicalReviewProcesses
        || maybe False reviewSessionActive (Map.lookup issueNumber state.appReviewSessions)
    boundAutoSolvePullRequest = do
      session <- Map.lookup issueNumber state.appSolveSessions
      progress <- session.solveSessionAutoProgress
      progress.autoSolvePullRequest

startApplication :: EventM Name AppState ()
startApplication = do
  vty <- getVtyHandle
  liftIO (Vty.setMode (Vty.outputIface vty) Vty.Mouse True)
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

monitorDrainer :: DrainerController -> BChan AppEvent -> IO ()
monitorDrainer controller eventChannel = forever $ do
  queryDrainerStatus controller >>= writeBChan eventChannel . DrainerStatusRefreshed
  threadDelay drainerRefreshIntervalMicros

drainerRefreshIntervalMicros :: Int
drainerRefreshIntervalMicros = 10 * 1000 * 1000

openSelectedSolveChooser :: SolveWorkflow -> EventM Name AppState ()
openSelectedSolveChooser workflow = do
  state <- get
  case selectedReviewIssue state of
    Nothing -> setNotice ("Select an issue before pressing " <> workflowKey workflow)
    Just issue -> openIssueSolveChooser workflow issue

openItemSolveChooser :: SolveWorkflow -> BoardItem -> EventM Name AppState ()
openItemSolveChooser workflow (IssueItem issue) = openIssueSolveChooser workflow issue
openItemSolveChooser workflow (PullRequestItem _) = setNotice ("Select an issue before pressing " <> workflowKey workflow)

openIssueSolveChooser :: SolveWorkflow -> Issue -> EventM Name AppState ()
openIssueSolveChooser workflow issue = do
  state <- get
  case Map.lookup issue.issueNumber state.appSolveSessions of
    Just session
      | solveSessionActive session || session.solveSessionWorkflow == workflow ->
          modify (\current -> current {appOverlay = Just (SolveOverlay issue.issueNumber), appNotice = Nothing})
    _ -> modify (\current -> current {appOverlay = Just (SolveChooser workflow issue), appNotice = Nothing})

solveSessionActive :: SolveSession -> Bool
solveSessionActive session = session.solveSessionPhase `elem` [SolveStarting, SolveRunning, SolveAttention, SolveOrphanedPhase]

workflowKey :: SolveWorkflow -> Text
workflowKey SolveOnly = "S"
workflowKey AutoSolve = "A"

startIssueSolve :: Issue -> SolveWorkflow -> SolverBrand -> EventM Name AppState ()
startIssueSolve issue workflow brand = do
  state <- get
  let autoProgress = case workflow of
        SolveOnly -> Nothing
        AutoSolve ->
          Just
            AutoSolveProgress
              { autoSolveStage = AutoImplementing,
                autoSolvePullRequest = Nothing,
                autoSolveReviewRound = 0,
                autoSolveKnownPullRequests = boardPullRequestNumbers state.appBoard,
                autoSolveStartedAt = state.appNow
              }
  let session =
        SolveSession
          { solveSessionIssue = issue,
            solveSessionWorkflow = workflow,
            solveSessionBrand = brand,
            solveSessionId = Nothing,
            solveSessionPhase = SolveStarting,
            solveSessionActivity = "starting",
            solveSessionActivityStartedAt = state.appNow,
            solveSessionLogPath = Nothing,
            solveSessionTranscript = plainTranscript $
              "workflow: "
                <> Text.toLower (workflowTitle workflow)
                <> "\nsolver: "
                <> solverLabel brand
                <> ( case workflow of
                       SolveOnly -> ""
                       AutoSolve -> "\nreviewer: " <> solveReviewerLabel brand
                   )
                <> "\n\n",
            solveSessionInput = "",
            solveSessionSpinnerFrame = 0,
            solveSessionAutoProgress = autoProgress
          }
  modify
    ( \current ->
        current
          { appSolveSessions = Map.insert issue.issueNumber session current.appSolveSessions,
            appOverlay = Just (SolveOverlay issue.issueNumber),
            appNotice = Nothing
          }
    )
  launchSolveInvocation issue.issueNumber workflow brand Nothing ""

launchSolveInvocation :: Int -> SolveWorkflow -> SolverBrand -> Maybe Text -> Text -> EventM Name AppState ()
launchSolveInvocation issueNumber workflow brand existingSession input = do
  state <- get
  let existingLogPath = Map.lookup issueNumber state.appSolveSessions >>= (.solveSessionLogPath)
      eventChannel = state.appEventChannel
      parent = do
        session <- Map.lookup issueNumber state.appSolveSessions
        progress <- session.solveSessionAutoProgress
        pure
          WorkerParent
            { workerParentIssueNumber = issueNumber,
              workerParentReviewRound = progress.autoSolveReviewRound,
              workerParentSolverBrand = session.solveSessionBrand,
              workerParentSolverSession = session.solveSessionId,
              workerParentSolverLogPath = session.solveSessionLogPath,
              workerParentStartedAt = progress.autoSolveStartedAt,
              workerParentKnownPullRequests = progress.autoSolveKnownPullRequests
            }
  void
    . liftIO
    . forkIO
    $ do
      launched <- launchSolveWorker state.appRepository issueNumber workflow brand existingSession existingLogPath input parent
      case launched of
        Left message -> do
          writeBChan eventChannel (SolveProtocolEvent (SolveDiagnostic issueNumber message))
          writeBChan eventChannel (SolveProtocolEvent (SolveProcessFinished issueNumber (SolveFailed message)))
        Right descriptor -> do
          writeBChan eventChannel (WorkerRegistered descriptor)
  void
    . liftIO
    . forkIO
    $ do
      threadDelay solveInitialRefreshDelayMicros
      writeBChan eventChannel SolveBoardRefreshRequested

submitSolveInput :: Int -> EventM Name AppState ()
submitSolveInput issueNumber = do
  state <- get
  case Map.lookup issueNumber state.appSolveSessions of
    Nothing -> setNotice "Solve session is no longer available"
    Just session
      | session.solveSessionPhase == SolveAttention,
        Just progress <- session.solveSessionAutoProgress,
        progress.autoSolveStage == AutoReviewing,
        Just pullRequestNumber <- progress.autoSolvePullRequest ->
          modify (\current -> current {appOverlay = Just (PullRequestReviewOverlay pullRequestNumber), appNotice = Nothing})
      | session.solveSessionPhase /= SolveAttention -> setNotice "This solve session is not waiting for input"
      | Text.null (Text.strip session.solveSessionInput) -> setNotice "Type an answer before pressing Enter"
      | otherwise -> case session.solveSessionId of
          Nothing -> setNotice "The solver did not return a resumable session id"
          Just sessionId -> do
            let answer = Text.strip session.solveSessionInput
            modifySolveSession issueNumber
              ( \current ->
                  current
                    { solveSessionPhase = SolveStarting,
                      solveSessionActivity = "resuming",
                      solveSessionInput = "",
                      solveSessionTranscript = appendSolveTranscript current.solveSessionTranscript ("\nYou: " <> answer <> "\n")
                    }
              )
            launchSolveInvocation issueNumber session.solveSessionWorkflow session.solveSessionBrand (Just sessionId) answer

modifySolveSession :: Int -> (SolveSession -> SolveSession) -> EventM Name AppState ()
modifySolveSession issueNumber update =
  modify (\state -> state {appSolveSessions = Map.adjust update issueNumber state.appSolveSessions})

appendSolveTranscript :: ChatTranscript -> Text -> ChatTranscript
appendSolveTranscript = appendReviewTranscript

appendAgentTranscript :: AgentEvent -> ChatTranscript -> ChatTranscript
appendAgentTranscript agentEvent transcript =
  ChatTranscript
    { compactTranscript = appendRendered CompactChat transcript.compactTranscript,
      standardTranscript = appendRendered StandardChat transcript.standardTranscript,
      fullTranscript = appendRendered FullChat transcript.fullTranscript
    }
  where
    appendRendered verbosity value = case renderAgentEvent verbosity agentEvent of
      Nothing -> value
      Just rendered -> boundedAppend value (sanitizeText rendered <> "\n")

agentActivity :: AgentEvent -> Text
agentActivity agentEvent = case agentEvent.agentEventKind of
  "reasoning" -> "thinking"
  "command" -> "running " <> activitySummary "[command] " agentEvent.agentEventSummary
  "tool" -> Text.take 80 agentEvent.agentEventSummary
  "tool-result" -> "processing tool result"
  "file" -> "changing files"
  "plan" -> "updating plan"
  "message" -> "responding"
  "error" -> "error"
  _ -> "running"

activitySummary :: Text -> Text -> Text
activitySummary prefix summary =
  Text.take 120
    . Text.unwords
    . Text.words
    . sanitizeText
    $ fromMaybe summary (Text.stripPrefix prefix summary)

setSolveActivity :: UTCTime -> Text -> SolveSession -> SolveSession
setSolveActivity now activity session =
  session {solveSessionActivity = activity, solveSessionActivityStartedAt = now}

setPullRequestActivity :: UTCTime -> Text -> PullRequestReviewSession -> PullRequestReviewSession
setPullRequestActivity now activity session =
  session {pullRequestSessionActivity = activity, pullRequestSessionActivityStartedAt = now}

boundedAppend :: Text -> Text -> Text
boundedAppend transcript addition = Text.takeEnd reviewTranscriptLimit (transcript <> addition)

applySolveEvent :: SolveEvent -> EventM Name AppState ()
applySolveEvent solveEvent = case solveEvent of
  SolveProcessStarted issueNumber _ process -> do
    modify
      ( \state ->
          state
            { appSolveProcesses = Map.insert issueNumber process state.appSolveProcesses,
              appSolveSessions = Map.adjust (setSolveActivity state.appNow "thinking" . (\session -> session {solveSessionPhase = SolveRunning})) issueNumber state.appSolveSessions
            }
      )
    scheduleSolveTick issueNumber
  SolveLogOpened issueNumber path ->
    modifySolveSession issueNumber (\session -> session {solveSessionLogPath = Just path})
  SolveSessionIdentified issueNumber sessionId ->
    modifySolveSession issueNumber (\session -> session {solveSessionId = Just sessionId})
  SolveOutput issueNumber output -> do
    now <- (.appNow) <$> get
    modifySolveSession issueNumber
      (setSolveActivity now (agentActivity output) . (\session -> session {solveSessionTranscript = appendAgentTranscript output session.solveSessionTranscript}))
    whenSolveOverlayOpen issueNumber (vScrollToEnd (viewportScroll SolveViewport))
  SolveDiagnostic issueNumber diagnostic -> do
    now <- (.appNow) <$> get
    -- This specific diagnostic means a user-requested kill could not be
    -- verified (see Kanban.Worker's pending-termination marker) and the
    -- worker is still alive and retrying: render it orphaned rather than
    -- running or optimistically "killed". Matched by text, not by the
    -- session's current phase, so a TUI restart that replays this same
    -- event from a fresh session (which never ran the "killed by user" UI
    -- transition) still renders it correctly.
    modifySolveSession issueNumber
      ( setSolveActivity now "diagnostic output"
          . ( \session ->
                session
                  { solveSessionTranscript = appendSolveTranscript session.solveSessionTranscript ("[solver] " <> sanitizeText diagnostic <> "\n"),
                    solveSessionPhase = if pendingTerminationDiagnosticPrefix `Text.isInfixOf` diagnostic then SolveOrphanedPhase else session.solveSessionPhase
                  }
            )
      )
    whenSolveOverlayOpen issueNumber (vScrollToEnd (viewportScroll SolveViewport))
  SolveProcessFinished issueNumber outcome -> do
    state <- get
    let priorSession = Map.lookup issueNumber state.appSolveSessions
        priorPhase = (.solveSessionPhase) <$> priorSession
    modify
      ( \current ->
          current
            { appSolveProcesses = Map.delete issueNumber current.appSolveProcesses,
              appSolveSessions = Map.adjust (finishSolveSession priorPhase outcome) issueNumber current.appSolveSessions
            }
      )
    startBoardRefresh
    case priorPhase of
      Just SolveInterrupting -> setNotice ("Solve workflow for #" <> showText issueNumber <> " interrupted; type guidance and press Enter")
      Just SolveKilledPhase -> setNotice ("Solve workflow for #" <> showText issueNumber <> " was killed")
      _ -> case outcome of
        SolveCompleted -> case priorSession >>= (.solveSessionAutoProgress) of
          Just progress | progress.autoSolveStage == AutoImplementing ->
            setNotice ("Implementation for #" <> showText issueNumber <> " finished; discovering its new PR…")
          Just progress | progress.autoSolveStage == AutoRevising ->
            setNotice ("Revision for #" <> showText issueNumber <> " finished; waiting for the revised PR state…")
          _ -> setNotice ("Solve workflow for #" <> showText issueNumber <> " finished")
        SolveNeedsInput _ -> setNotice ("Solve workflow for #" <> showText issueNumber <> " needs input")
        SolveFailed message -> setNotice ("Solve workflow for #" <> showText issueNumber <> " failed: " <> sanitizeText message)
  where
    finishSolveSession (Just SolveInterrupting) _ session =
      session
        { solveSessionPhase = SolveAttention,
          solveSessionActivity = "waiting for guidance",
          solveSessionTranscript = appendSolveTranscript session.solveSessionTranscript "\n[interrupted] Type guidance and press Enter to resume this session.\n"
        }
    finishSolveSession (Just SolveKilledPhase) _ session =
      session {solveSessionActivity = "killed", solveSessionAutoProgress = markAutoSolveStopped <$> session.solveSessionAutoProgress}
    finishSolveSession _ outcome session = case outcome of
      SolveCompleted -> case session.solveSessionAutoProgress of
        Just progress | progress.autoSolveStage == AutoImplementing ->
          session
            { solveSessionPhase = SolveRunning,
              solveSessionActivity = "discovering pull request",
              solveSessionAutoProgress = Just progress {autoSolveStage = AutoDiscoveringPullRequest}
            }
        Just progress | progress.autoSolveStage == AutoRevising ->
          session
            { solveSessionPhase = SolveRunning,
              solveSessionActivity = "waiting for revised PR state",
              solveSessionAutoProgress = Just progress {autoSolveStage = AutoAwaitingRereview}
            }
        _ -> session {solveSessionPhase = SolveFinished, solveSessionActivity = "completed"}
      SolveNeedsInput question ->
        session
          { solveSessionPhase = SolveAttention,
            solveSessionActivity = "waiting for input",
            solveSessionTranscript = appendSolveTranscript session.solveSessionTranscript ("\nQuestion: " <> sanitizeText question <> "\n")
          }
      SolveFailed message ->
        session
          { solveSessionPhase = SolveFailedPhase,
            solveSessionActivity = "failed",
            solveSessionAutoProgress = markAutoSolveStopped <$> session.solveSessionAutoProgress,
            solveSessionTranscript = appendSolveTranscript session.solveSessionTranscript ("\n" <> sanitizeText message <> "\n")
          }
    markAutoSolveStopped progress = progress {autoSolveStage = AutoSolveStopped}

interruptSolveSession :: Int -> EventM Name AppState ()
interruptSolveSession issueNumber = do
  state <- get
  case (Map.lookup issueNumber state.appSolveSessions, Map.lookup issueNumber state.appSolveProcesses) of
    (Just session, Just process)
      | session.solveSessionPhase `elem` [SolveStarting, SolveRunning], session.solveSessionId /= Nothing -> do
          modifySolveSession issueNumber
            ( \current ->
                current
                  { solveSessionPhase = SolveInterrupting,
                    solveSessionActivity = "interrupting",
                    solveSessionTranscript = appendSolveTranscript current.solveSessionTranscript "\n[interrupt requested]\n"
                  }
            )
          liftIO (interruptManagedProcess process)
          setNotice ("Interrupting solve workflow #" <> showText issueNumber <> "…")
      | session.solveSessionId == Nothing -> setNotice "Wait for the resumable session id before interrupting"
      | otherwise -> setNotice "This solve workflow has no live turn to interrupt"
    _ -> setNotice "This solve workflow has no live process to interrupt"

whenSolveOverlayOpen :: Int -> EventM Name AppState () -> EventM Name AppState ()
whenSolveOverlayOpen issueNumber action = do
  state <- get
  case state.appOverlay of
    Just (SolveOverlay selectedIssue) | selectedIssue == issueNumber -> action
    _ -> pure ()

applySolveAnimationTick :: Int -> EventM Name AppState ()
applySolveAnimationTick issueNumber = do
  state <- get
  case (Map.lookup issueNumber state.appSolveSessions, Map.member issueNumber state.appSolveProcesses) of
    (Just session, True)
      | session.solveSessionPhase `elem` [SolveStarting, SolveRunning] -> do
          modifySolveSession issueNumber (\current -> current {solveSessionSpinnerFrame = current.solveSessionSpinnerFrame + 1})
          scheduleSolveTick issueNumber
    _ -> pure ()

scheduleSolveTick :: Int -> EventM Name AppState ()
scheduleSolveTick issueNumber = do
  eventChannel <- (.appEventChannel) <$> get
  void
    . liftIO
    . forkIO
    $ do
      threadDelay reviewAnimationIntervalMicros
      writeBChan eventChannel (SolveAnimationTick issueNumber)

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

solveWorkerFor :: AppState -> Int -> Maybe WorkerDescriptor
solveWorkerFor state issueNumber =
  find matches (Map.elems state.appWorkers)
  where
    matches descriptor = case descriptor.workerDescriptorSpec.workerTask of
      SolveWorkerTaskKind task -> task.solveWorkerIssueNumber == issueNumber
      PullRequestWorkerTaskKind _ -> False

pullRequestWorkerFor :: AppState -> Int -> Maybe WorkerDescriptor
pullRequestWorkerFor state number =
  find matches (Map.elems state.appWorkers)
  where
    matches descriptor = case descriptor.workerDescriptorSpec.workerTask of
      PullRequestWorkerTaskKind task -> task.pullRequestWorkerNumber == number
      SolveWorkerTaskKind _ -> False

applyWorkerProtocolEvent :: WorkerDescriptor -> WorkerEvent -> EventM Name AppState ()
applyWorkerProtocolEvent descriptor workerEvent = do
  ensureWorkerSession descriptor
  case descriptor.workerDescriptorSpec.workerTask of
    SolveWorkerTaskKind task -> case workerEvent of
      WorkerProviderStarted processId ->
        applySolveEvent (SolveProcessStarted task.solveWorkerIssueNumber task.solveWorkerBrand (managedProcessGroup (fromIntegral processId)))
      WorkerLogOpened path -> applySolveEvent (SolveLogOpened task.solveWorkerIssueNumber path)
      WorkerSessionIdentified sessionId -> applySolveEvent (SolveSessionIdentified task.solveWorkerIssueNumber sessionId)
      WorkerAgentOutput output -> applySolveEvent (SolveOutput task.solveWorkerIssueNumber output)
      WorkerDiagnostic message -> applySolveEvent (SolveDiagnostic task.solveWorkerIssueNumber message)
      WorkerOrphansDetected _ processes -> applySolveOrphans task.solveWorkerIssueNumber processes
      WorkerFinished outcome -> applySolveEvent (SolveProcessFinished task.solveWorkerIssueNumber outcome)
    PullRequestWorkerTaskKind task ->
      let brand = agentForAction task.pullRequestWorkerOrigin task.pullRequestWorkerAction
       in case workerEvent of
            WorkerProviderStarted processId ->
              applyPullRequestFlowEvent (PullRequestProcessStarted task.pullRequestWorkerNumber task.pullRequestWorkerAction brand (managedProcessGroup (fromIntegral processId)))
            WorkerLogOpened path -> applyPullRequestFlowEvent (PullRequestLogOpened task.pullRequestWorkerNumber path)
            WorkerSessionIdentified sessionId -> applyPullRequestFlowEvent (PullRequestSessionIdentified task.pullRequestWorkerNumber sessionId)
            WorkerAgentOutput output -> applyPullRequestFlowEvent (PullRequestFlowOutput task.pullRequestWorkerNumber output)
            WorkerDiagnostic message -> applyPullRequestFlowEvent (PullRequestFlowDiagnostic task.pullRequestWorkerNumber message)
            WorkerOrphansDetected _ processes -> applyPullRequestOrphans task.pullRequestWorkerNumber processes
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

applySolveOrphans :: Int -> [ProcessIdentity] -> EventM Name AppState ()
applySolveOrphans issueNumber processes = do
  let count = showText (length processes)
      message = count <> " subprocesses survived the solver; press x to terminate the orphaned process tree"
  now <- (.appNow) <$> get
  modify
    ( \state ->
        state
          { appSolveProcesses = Map.delete issueNumber state.appSolveProcesses,
            appSolveSessions =
              Map.adjust
                ( setSolveActivity now message
                    . ( \session ->
                          session
                            { solveSessionPhase = SolveOrphanedPhase,
                              solveSessionTranscript = appendSolveTranscript session.solveSessionTranscript ("\n[orphaned] " <> message <> "\n")
                            }
                      )
                )
                issueNumber
                state.appSolveSessions
          }
    )
  setNotice ("Solve #" <> showText issueNumber <> " is orphaned; press p to inspect it or x to kill it")

applyPullRequestOrphans :: Int -> [ProcessIdentity] -> EventM Name AppState ()
applyPullRequestOrphans number processes = do
  let count = showText (length processes)
      message = count <> " subprocesses survived the PR agent; press x to terminate the orphaned process tree"
  now <- (.appNow) <$> get
  modify
    ( \state ->
        state
          { appPullRequestProcesses = Map.delete number state.appPullRequestProcesses,
            appPullRequestReviewSessions =
              Map.adjust
                ( setPullRequestActivity now message
                    . ( \session ->
                          session
                            { pullRequestSessionPhase = SolveOrphanedPhase,
                              pullRequestSessionTranscript = appendSolveTranscript session.pullRequestSessionTranscript ("\n[orphaned] " <> message <> "\n")
                            }
                      )
                )
                number
                state.appPullRequestReviewSessions
          }
    )
  modifyAutoSolveForPullRequest number (\session -> session {solveSessionActivity = "PR agent left orphaned subprocesses; press p"})
  setNotice ("PR workflow #" <> showText number <> " is orphaned; press p to inspect it or x to kill it")

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
                        (recoveredSolveSession current descriptor issue task)
                        current.appSolveSessions
                  }
            )
      | otherwise -> setNotice ("Persistent worker for issue #" <> showText task.solveWorkerIssueNumber <> " is running, but the issue is absent from the cached board; press u to refresh")
    PullRequestWorkerTaskKind task -> do
      when (Map.notMember task.pullRequestWorkerNumber state.appPullRequestReviewSessions) $
        case pullRequestFromBoard state.appBoard task.pullRequestWorkerNumber of
          Nothing -> setNotice ("Persistent worker for PR #" <> showText task.pullRequestWorkerNumber <> " is running, but the PR is absent from the cached board; press u to refresh")
          Just pullRequest ->
            modify
              ( \current ->
                  current
                    { appPullRequestReviewSessions =
                        Map.insert
                          task.pullRequestWorkerNumber
                          (recoveredPullRequestSession descriptor pullRequest task)
                          current.appPullRequestReviewSessions
                    }
              )
      ensureRecoveredAutoSolve descriptor task

recoveredSolveSession :: AppState -> WorkerDescriptor -> Issue -> SolveWorkerTask -> SolveSession
recoveredSolveSession state descriptor issue task =
  SolveSession
    { solveSessionIssue = issue,
      solveSessionWorkflow = task.solveWorkerWorkflow,
      solveSessionBrand = task.solveWorkerBrand,
      solveSessionId = descriptor.workerDescriptorSpec.workerExistingSession,
      solveSessionPhase = SolveStarting,
      solveSessionActivity = "reattaching persistent worker",
      solveSessionActivityStartedAt = descriptor.workerDescriptorSpec.workerCreatedAt,
      solveSessionLogPath = descriptor.workerDescriptorSpec.workerExistingLogPath,
      solveSessionTranscript =
        plainTranscript
          ( "reattached persistent "
              <> Text.toLower (workflowTitle task.solveWorkerWorkflow)
              <> " worker\nsolver: "
              <> solverLabel task.solveWorkerBrand
              <> "\n\n"
          ),
      solveSessionInput = "",
      solveSessionSpinnerFrame = 0,
      solveSessionAutoProgress = recoveredAutoProgress state descriptor task
    }

recoveredAutoProgress :: AppState -> WorkerDescriptor -> SolveWorkerTask -> Maybe AutoSolveProgress
recoveredAutoProgress state descriptor task = case task.solveWorkerWorkflow of
  SolveOnly -> Nothing
  AutoSolve ->
    let parent = descriptor.workerDescriptorSpec.workerParent
        reviewRound = maybe 0 (.workerParentReviewRound) parent
     in Just
          AutoSolveProgress
            { autoSolveStage = if reviewRound == 0 then AutoImplementing else AutoRevising,
              autoSolvePullRequest = Nothing,
              autoSolveReviewRound = reviewRound,
              autoSolveKnownPullRequests = maybe (boardPullRequestNumbers state.appBoard) (.workerParentKnownPullRequests) parent,
              autoSolveStartedAt = maybe descriptor.workerDescriptorSpec.workerCreatedAt (.workerParentStartedAt) parent
            }

recoveredPullRequestSession :: WorkerDescriptor -> PullRequest -> PullRequestWorkerTask -> PullRequestReviewSession
recoveredPullRequestSession descriptor pullRequest task =
  let brand = agentForAction task.pullRequestWorkerOrigin task.pullRequestWorkerAction
   in PullRequestReviewSession
        { pullRequestSessionPullRequest = pullRequest,
          pullRequestSessionOrigin = task.pullRequestWorkerOrigin,
          pullRequestSessionAction = task.pullRequestWorkerAction,
          pullRequestSessionLaunchedForUpdatedAt = pullRequest.pullRequestUpdatedAt,
          pullRequestSessionBrand = brand,
          pullRequestSessionId = descriptor.workerDescriptorSpec.workerExistingSession,
          pullRequestSessionPhase = SolveStarting,
          pullRequestSessionActivity = "reattaching persistent worker",
          pullRequestSessionActivityStartedAt = descriptor.workerDescriptorSpec.workerCreatedAt,
          pullRequestSessionLogPath = descriptor.workerDescriptorSpec.workerExistingLogPath,
          pullRequestSessionTranscript = plainTranscript ("reattached persistent PR " <> pullRequestActionText task.pullRequestWorkerAction <> " worker\nagent: " <> pullRequestAgentLabel task.pullRequestWorkerAction brand <> "\n\n"),
          pullRequestSessionInput = "",
          pullRequestSessionSpinnerFrame = 0
        }

ensureRecoveredAutoSolve :: WorkerDescriptor -> PullRequestWorkerTask -> EventM Name AppState ()
ensureRecoveredAutoSolve descriptor task = case descriptor.workerDescriptorSpec.workerParent of
  Nothing -> pure ()
  Just parent -> do
    state <- get
    when (Map.notMember parent.workerParentIssueNumber state.appSolveSessions) $
      case issueFromBoard state.appBoard parent.workerParentIssueNumber of
        Nothing -> pure ()
        Just issue -> do
          let progress =
                AutoSolveProgress
                  { autoSolveStage = AutoReviewing,
                    autoSolvePullRequest = Just task.pullRequestWorkerNumber,
                    autoSolveReviewRound = parent.workerParentReviewRound,
                    autoSolveKnownPullRequests = parent.workerParentKnownPullRequests,
                    autoSolveStartedAt = parent.workerParentStartedAt
                  }
              session =
                (recoveredSolveSession state descriptor issue (SolveWorkerTask parent.workerParentIssueNumber AutoSolve parent.workerParentSolverBrand))
                  { solveSessionPhase = SolveRunning,
                    solveSessionActivity = "PR agent is running",
                    solveSessionId = parent.workerParentSolverSession,
                    solveSessionLogPath = parent.workerParentSolverLogPath,
                    solveSessionAutoProgress = Just progress
                  }
          modify (\current -> current {appSolveSessions = Map.insert parent.workerParentIssueNumber session current.appSolveSessions})

issueFromBoard :: Board -> Int -> Maybe Issue
issueFromBoard board issueNumber = do
  (_, _, item) <- findItem board (IssueId issueNumber)
  case item of
    IssueItem issue -> Just issue
    PullRequestItem _ -> Nothing

pullRequestFromBoard :: Board -> Int -> Maybe PullRequest
pullRequestFromBoard board number = do
  (_, _, item) <- findItem board (PullRequestId number)
  case item of
    PullRequestItem pullRequest -> Just pullRequest
    IssueItem _ -> Nothing

solveInitialRefreshDelayMicros :: Int
solveInitialRefreshDelayMicros = 5 * 1000 * 1000

startSelectedReview :: EventM Name AppState ()
startSelectedReview = do
  state <- get
  case selectedReviewItem state of
    Nothing -> setNotice "Select an issue or PR before pressing r"
    Just item -> startItemReview item

startItemReview :: BoardItem -> EventM Name AppState ()
startItemReview (IssueItem issue) = startIssueReview issue
startItemReview (PullRequestItem pullRequest) = startPullRequestReview pullRequest

startIssueReview :: Issue -> EventM Name AppState ()
startIssueReview issue = do
  state <- get
  let requestedStage = issueReviewStage issue
  case Map.lookup issue.issueNumber state.appReviewSessions of
    Just session
      | reviewSessionActive session || session.reviewSessionStage == requestedStage ->
          modify (\current -> current {appOverlay = Just (ReviewOverlay issue.issueNumber), appNotice = Nothing})
    _ -> do
      let session = newReviewSession issue requestedStage
      modify
        ( \current ->
            current
              { appReviewSessions = Map.insert issue.issueNumber session current.appReviewSessions,
                appOverlay = Just (ReviewOverlay issue.issueNumber),
                appNotice = Nothing
              }
        )
      if requestedStage == IssueRevision
        then do
          updated <- get
          case updated.appReviewBackend of
            ReviewBackendReady client -> launchIssueReview client issue.issueNumber
            ReviewBackendStarting -> pure ()
            ReviewBackendStopped -> startReviewBackend
            ReviewBackendFailed _ -> startReviewBackend
        else launchCanonicalIssueReview issue.issueNumber requestedStage

reviewSessionActive :: ReviewSession -> Bool
reviewSessionActive session = session.reviewSessionPhase `elem` [ReviewStarting, ReviewRunning, ReviewWaiting]

issueReviewStage :: Issue -> ReviewStage
issueReviewStage issue = reviewStageForLabels (map (.labelName) issue.issueLabels)

newReviewSession :: Issue -> ReviewStage -> ReviewSession
newReviewSession issue stage =
  ReviewSession
    { reviewSessionIssue = issue,
      reviewSessionStage = stage,
      reviewSessionThreadId = Nothing,
      reviewSessionTurnId = Nothing,
      reviewSessionPhase = ReviewStarting,
      reviewSessionActivity = if stage == IssueRevision then "starting coordinator" else "running canonical gate",
      reviewSessionTranscript = plainTranscript (if stage == IssueRevision then "" else "Running canonical issue-review:v2 gate…\n"),
      reviewSessionPending = Nothing,
      reviewSessionInput = "",
      reviewSessionSpinnerFrame = 0
    }

launchCanonicalIssueReview :: Int -> ReviewStage -> EventM Name AppState ()
launchCanonicalIssueReview issueNumber stage = do
  state <- get
  let channel = state.appEventChannel
  void . liftIO . forkIO $ do
    result <- runCanonicalIssueReview state.appRepository issueNumber stage (writeBChan channel . CanonicalIssueReviewProcessStarted issueNumber)
    writeBChan channel (CanonicalIssueReviewFinished issueNumber stage result)

applyCanonicalIssueReview :: Int -> ReviewStage -> Either Text CanonicalIssueReviewResult -> EventM Name AppState ()
applyCanonicalIssueReview issueNumber stage result = do
  modify (\current -> current {appCanonicalReviewProcesses = Map.delete issueNumber current.appCanonicalReviewProcesses})
  modifyReviewSession issueNumber $ \session -> case result of
    Left message -> session {reviewSessionPhase = ReviewFailed, reviewSessionActivity = "failed", reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript ("\n" <> sanitizeText message <> "\n")}
    Right canonicalResult ->
      session
        { reviewSessionPhase = if canonicalResult.canonicalReviewApproved then ReviewFinished else ReviewNeedsChanges,
          reviewSessionActivity = if canonicalResult.canonicalReviewApproved then "approved" else "changes requested",
          reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript ("\n" <> renderCanonicalIssueReviewResult stage canonicalResult)
        }
  startBoardRefresh
  setNotice (case result of Left message -> "Canonical issue review failed: " <> sanitizeText message; Right _ -> stageActivity stage <> " completed with issue-review:v2 state")
  where
    stageActivity InitialReview = "Issue review"
    stageActivity IssueRereview = "Issue rereview"
    stageActivity IssueRevision = "Issue revision"

selectedReviewIssue :: AppState -> Maybe Issue
selectedReviewIssue state = selectedReviewItem state >>= boardItemIssue
  where
    boardItemIssue (IssueItem issue) = Just issue
    boardItemIssue (PullRequestItem _) = Nothing

selectedReviewItem :: AppState -> Maybe BoardItem
selectedReviewItem state = case selectedEntry state of
  Just (Tracked context item)
    | primaryTrackerNumber context `Set.notMember` state.appExpandedTrackers ->
        Just (IssueItem context.trackingPrimary.membershipTracker.trackerIssue)
    | otherwise -> Just item
  Just (Standalone item) -> Just item
  Nothing -> Nothing

startPullRequestReview :: PullRequest -> EventM Name AppState ()
startPullRequestReview = startPullRequestReviewWithOptions True False

startPullRequestReviewWithVisibility :: Bool -> PullRequest -> EventM Name AppState ()
startPullRequestReviewWithVisibility showOverlay = startPullRequestReviewWithOptions showOverlay False

startPullRequestReviewWithOptions :: Bool -> Bool -> PullRequest -> EventM Name AppState ()
startPullRequestReviewWithOptions showOverlay forceFresh pullRequest = case originFromBody pullRequest.pullRequestBody of
  Left message -> setNotice message
  Right origin -> do
    state <- get
    let action = actionForLabels (map (.labelName) pullRequest.pullRequestLabels)
    case Map.lookup pullRequest.pullRequestNumber state.appPullRequestReviewSessions of
      Just session
        | pullRequestSessionReusable forceFresh (pullRequestReviewActive session) session.pullRequestSessionAction action session.pullRequestSessionLaunchedForUpdatedAt pullRequest.pullRequestUpdatedAt ->
            when showOverlay (modify (\current -> current {appOverlay = Just (PullRequestReviewOverlay pullRequest.pullRequestNumber), appNotice = Nothing}))
      _ -> do
        let brand = agentForAction origin action
            session =
              PullRequestReviewSession
                { pullRequestSessionPullRequest = pullRequest,
                  pullRequestSessionOrigin = origin,
                  pullRequestSessionAction = action,
                  pullRequestSessionLaunchedForUpdatedAt = pullRequest.pullRequestUpdatedAt,
                  pullRequestSessionBrand = brand,
                  pullRequestSessionId = Nothing,
                  pullRequestSessionPhase = SolveStarting,
                  pullRequestSessionActivity = "starting",
                  pullRequestSessionActivityStartedAt = state.appNow,
                  pullRequestSessionLogPath = Nothing,
                  pullRequestSessionTranscript = plainTranscript ("action: " <> pullRequestActionText action <> "\nagent: " <> pullRequestAgentLabel action brand <> "\n\n"),
                  pullRequestSessionInput = "",
                  pullRequestSessionSpinnerFrame = 0
                }
        modify
          ( \current ->
              current
                { appPullRequestReviewSessions = Map.insert pullRequest.pullRequestNumber session current.appPullRequestReviewSessions,
                  appOverlay = if showOverlay then Just (PullRequestReviewOverlay pullRequest.pullRequestNumber) else current.appOverlay,
                  appNotice = if showOverlay then Nothing else current.appNotice
                }
          )
        launchPullRequestFlow pullRequest.pullRequestNumber origin action brand Nothing ""

pullRequestReviewActive :: PullRequestReviewSession -> Bool
pullRequestReviewActive session = session.pullRequestSessionPhase `elem` [SolveStarting, SolveRunning, SolveAttention, SolveOrphanedPhase]

-- | Whether pressing r should reuse a tracked session's overlay rather than
-- launch a fresh action. An active session is always reused. A finished
-- session is only reused when the recomputed action still matches AND the
-- PR has not changed since that action was launched -- otherwise a fresh
-- canonical round is needed even if the recomputed action repeats, e.g. a
-- second reviewed:changes verdict after pr-revise's own rereview.
pullRequestSessionReusable :: Bool -> Bool -> PullRequestAction -> PullRequestAction -> UTCTime -> UTCTime -> Bool
pullRequestSessionReusable forceFresh active sessionAction currentAction launchedForUpdatedAt currentUpdatedAt =
  not forceFresh && (active || (sessionAction == currentAction && launchedForUpdatedAt == currentUpdatedAt))

launchPullRequestFlow :: Int -> PullRequestOrigin -> PullRequestAction -> SolverBrand -> Maybe Text -> Text -> EventM Name AppState ()
launchPullRequestFlow number origin action _brand existingSession input = do
  state <- get
  let existingLogPath = Map.lookup number state.appPullRequestReviewSessions >>= (.pullRequestSessionLogPath)
      parent = autoSolveWorkerParent state number
      eventChannel = state.appEventChannel
  void . liftIO . forkIO $ do
    launched <- launchPullRequestWorker state.appRepository number origin action existingSession existingLogPath input parent
    case launched of
      Left message -> do
        writeBChan eventChannel (PullRequestProtocolEvent (PullRequestFlowDiagnostic number message))
        writeBChan eventChannel (PullRequestProtocolEvent (PullRequestProcessFinished number (SolveFailed message)))
      Right descriptor -> do
        writeBChan eventChannel (WorkerRegistered descriptor)

autoSolveWorkerParent :: AppState -> Int -> Maybe WorkerParent
autoSolveWorkerParent state pullRequestNumber =
  case
      [ WorkerParent
          { workerParentIssueNumber = issueNumber,
            workerParentReviewRound = progress.autoSolveReviewRound,
            workerParentSolverBrand = session.solveSessionBrand,
            workerParentSolverSession = session.solveSessionId,
            workerParentSolverLogPath = session.solveSessionLogPath,
            workerParentStartedAt = progress.autoSolveStartedAt,
            workerParentKnownPullRequests = progress.autoSolveKnownPullRequests
          }
        | (issueNumber, session) <- Map.toList state.appSolveSessions,
          Just progress <- [session.solveSessionAutoProgress],
          progress.autoSolvePullRequest == Just pullRequestNumber
      ] of
    parent : _ -> Just parent
    [] -> Nothing

submitPullRequestInput :: Int -> EventM Name AppState ()
submitPullRequestInput number = do
  state <- get
  case Map.lookup number state.appPullRequestReviewSessions of
    Just session
      | session.pullRequestSessionPhase == SolveAttention,
        Just sessionId <- session.pullRequestSessionId,
        not (Text.null (Text.strip session.pullRequestSessionInput)) -> do
          let answer = Text.strip session.pullRequestSessionInput
          modifyPullRequestSession number (\current -> current {pullRequestSessionPhase = SolveStarting, pullRequestSessionActivity = "resuming", pullRequestSessionInput = "", pullRequestSessionTranscript = appendSolveTranscript current.pullRequestSessionTranscript ("\nYou: " <> answer <> "\n")})
          modifyAutoSolveForPullRequest number
            (\current -> current {solveSessionPhase = SolveRunning, solveSessionActivity = "resuming PR review"})
          launchPullRequestFlow number session.pullRequestSessionOrigin session.pullRequestSessionAction session.pullRequestSessionBrand (Just sessionId) answer
      | otherwise -> setNotice "This PR workflow is not waiting for a resumable answer"
    Nothing -> setNotice "PR workflow session is no longer available"

modifyPullRequestSession :: Int -> (PullRequestReviewSession -> PullRequestReviewSession) -> EventM Name AppState ()
modifyPullRequestSession number update = modify (\state -> state {appPullRequestReviewSessions = Map.adjust update number state.appPullRequestReviewSessions})

applyPullRequestFlowEvent :: PullRequestFlowEvent -> EventM Name AppState ()
applyPullRequestFlowEvent flowEvent = case flowEvent of
  PullRequestProcessStarted number _ _ process -> do
    modify
      ( \state ->
          state
            { appPullRequestProcesses = Map.insert number process state.appPullRequestProcesses,
              appPullRequestReviewSessions = Map.adjust (setPullRequestActivity state.appNow "thinking" . (\session -> session {pullRequestSessionPhase = SolveRunning})) number state.appPullRequestReviewSessions
            }
      )
    modifyAutoSolveForPullRequest number
      (\session -> session {solveSessionPhase = SolveRunning, solveSessionActivity = "PR agent is thinking"})
    schedulePullRequestTick number
  PullRequestLogOpened number path ->
    modifyPullRequestSession number (\session -> session {pullRequestSessionLogPath = Just path})
  PullRequestSessionIdentified number sessionId -> modifyPullRequestSession number (\session -> session {pullRequestSessionId = Just sessionId})
  PullRequestFlowOutput number output -> do
    now <- (.appNow) <$> get
    modifyPullRequestSession number
      (setPullRequestActivity now (agentActivity output) . (\session -> session {pullRequestSessionTranscript = appendAgentTranscript output session.pullRequestSessionTranscript}))
    scrollOpenSession number
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
      ( setPullRequestActivity now "diagnostic output"
          . (\session -> session {pullRequestSessionPhase = if pendingTerminationDiagnosticPrefix `Text.isInfixOf` output then SolveOrphanedPhase else session.pullRequestSessionPhase})
      )
  PullRequestProcessFinished number outcome -> do
    state <- get
    let priorPhase = (.pullRequestSessionPhase) <$> Map.lookup number state.appPullRequestReviewSessions
    modify
      ( \current ->
          current
            { appPullRequestProcesses = Map.delete number current.appPullRequestProcesses,
              appPullRequestReviewSessions = Map.adjust (finish priorPhase outcome) number current.appPullRequestReviewSessions
            }
      )
    case outcome of
      SolveNeedsInput _ ->
        modifyAutoSolveForPullRequest number
          (\session -> session {solveSessionPhase = SolveAttention, solveSessionActivity = "PR review needs input; press p"})
      SolveFailed message ->
        modifyAutoSolveForPullRequest number
          (\session -> session {solveSessionPhase = SolveFailedPhase, solveSessionActivity = "PR agent failed: " <> sanitizeText message})
      SolveCompleted -> pure ()
    startBoardRefresh
  where
    appendOutput number output = do
      modifyPullRequestSession number (\session -> session {pullRequestSessionTranscript = appendSolveTranscript session.pullRequestSessionTranscript output})
      scrollOpenSession number
    scrollOpenSession number = do
      state <- get
      case state.appOverlay of
        Just (PullRequestReviewOverlay selected) | selected == number -> vScrollToEnd (viewportScroll PullRequestReviewViewport)
        _ -> pure ()
    finish (Just SolveInterrupting) _ session = session {pullRequestSessionPhase = SolveAttention, pullRequestSessionActivity = "waiting for guidance", pullRequestSessionTranscript = appendSolveTranscript session.pullRequestSessionTranscript "\n[interrupted] Type guidance and press Enter to resume this session.\n"}
    finish (Just SolveKilledPhase) _ session = session {pullRequestSessionActivity = "killed"}
    finish _ SolveCompleted session = session {pullRequestSessionPhase = SolveFinished, pullRequestSessionActivity = "completed"}
    finish _ (SolveNeedsInput question) session = session {pullRequestSessionPhase = SolveAttention, pullRequestSessionActivity = "waiting for input", pullRequestSessionTranscript = appendSolveTranscript session.pullRequestSessionTranscript ("\nQuestion: " <> sanitizeText question <> "\n")}
    finish _ (SolveFailed message) session = session {pullRequestSessionPhase = SolveFailedPhase, pullRequestSessionActivity = "failed", pullRequestSessionTranscript = appendSolveTranscript session.pullRequestSessionTranscript ("\n" <> sanitizeText message <> "\n")}

modifyAutoSolveForPullRequest :: Int -> (SolveSession -> SolveSession) -> EventM Name AppState ()
modifyAutoSolveForPullRequest pullRequestNumber update =
  modify
    ( \state ->
        state
          { appSolveSessions =
              Map.map
                ( \session ->
                    case session.solveSessionAutoProgress of
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
      | session.pullRequestSessionPhase `elem` [SolveStarting, SolveRunning], session.pullRequestSessionId /= Nothing -> do
          modifyPullRequestSession number
            ( \current ->
                current
                  { pullRequestSessionPhase = SolveInterrupting,
                    pullRequestSessionActivity = "interrupting",
                    pullRequestSessionTranscript = appendSolveTranscript current.pullRequestSessionTranscript "\n[interrupt requested]\n"
                  }
            )
          liftIO (interruptManagedProcess process)
          setNotice ("Interrupting PR workflow #" <> showText number <> "…")
      | session.pullRequestSessionId == Nothing -> setNotice "Wait for the resumable session id before interrupting"
      | otherwise -> setNotice "This PR workflow has no live turn to interrupt"
    _ -> setNotice "This PR workflow has no live process to interrupt"

applyPullRequestAnimationTick :: Int -> EventM Name AppState ()
applyPullRequestAnimationTick number = do
  state <- get
  case Map.lookup number state.appPullRequestReviewSessions of
    Just session | session.pullRequestSessionPhase `elem` [SolveStarting, SolveRunning] -> do
      modifyPullRequestSession number (\current -> current {pullRequestSessionSpinnerFrame = current.pullRequestSessionSpinnerFrame + 1})
      schedulePullRequestTick number
    _ -> pure ()

schedulePullRequestTick :: Int -> EventM Name AppState ()
schedulePullRequestTick number = do
  channel <- (.appEventChannel) <$> get
  void . liftIO . forkIO $ threadDelay reviewAnimationIntervalMicros >> writeBChan channel (PullRequestAnimationTick number)

startReviewBackend :: EventM Name AppState ()
startReviewBackend = do
  state <- get
  modify (\current -> current {appReviewBackend = ReviewBackendStarting})
  let eventChannel = state.appEventChannel
      eventSink = writeBChan eventChannel . ReviewProtocolEvent
  void
    . liftIO
    . forkIO
    $ startReviewClient state.appRepository eventSink >>= writeBChan eventChannel . ReviewBackendStarted

launchIssueReview :: ReviewClient -> Int -> EventM Name AppState ()
launchIssueReview client issueNumber = do
  eventChannel <- (.appEventChannel) <$> get
  void
    . liftIO
    . forkIO
    $ do
      result <- beginIssueReview client issueNumber
      case result of
        Left message -> writeBChan eventChannel (ReviewProtocolEvent (ReviewStartFailed issueNumber message))
        Right () -> pure ()

applyReviewBackendStarted :: Either Text ReviewClient -> EventM Name AppState ()
applyReviewBackendStarted result = case result of
  Left message ->
    modify
      ( \state ->
          state
            { appReviewBackend = ReviewBackendFailed message,
              appReviewSessions = Map.map (failStartingSession message) state.appReviewSessions,
              appNotice = Just message
            }
      )
  Right client -> do
    modify (\state -> state {appReviewBackend = ReviewBackendReady client})
    sessions <- Map.elems . (.appReviewSessions) <$> get
    mapM_
      ( \session ->
          if session.reviewSessionStage == IssueRevision && session.reviewSessionPhase == ReviewStarting && session.reviewSessionThreadId == Nothing
            then launchIssueReview client session.reviewSessionIssue.issueNumber
            else pure ()
      )
      sessions
  where
    failStartingSession message session
      | session.reviewSessionStage == IssueRevision && session.reviewSessionPhase == ReviewStarting =
          session
            { reviewSessionPhase = ReviewFailed,
              reviewSessionActivity = "failed",
              reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript ("\n" <> message)
            }
      | otherwise = session

applyReviewEvent :: ReviewEvent -> EventM Name AppState ()
applyReviewEvent reviewEvent = case reviewEvent of
  ReviewThreadCreated issueNumber threadId ->
    modifyReviewSession issueNumber
      ( \session ->
          session
            { reviewSessionThreadId = Just threadId,
              reviewSessionActivity = "session ready",
              reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript "Codex session created.\n"
            }
      )
  ReviewTurnStarted threadId turnId -> do
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { reviewSessionTurnId = Just turnId,
              reviewSessionPhase = ReviewRunning,
              reviewSessionActivity = "thinking",
              reviewSessionPending = Nothing
            }
      )
    scheduleReviewTick threadId
  ReviewOutput threadId outputKind delta
    | Text.null threadId ->
        whenReviewOverlayOpen (\_ -> setNotice (reviewOutputPrefix outputKind <> sanitizeText delta))
    | otherwise -> do
        modifyReviewSessionByThread threadId
          ( \session ->
              session
                { reviewSessionTranscript =
                    appendReviewOutput outputKind (reviewOutputPrefix outputKind <> sanitizeText delta) session.reviewSessionTranscript,
                  reviewSessionActivity = reviewOutputActivity outputKind
                }
          )
        vScrollToEnd (viewportScroll ReviewViewport)
  ReviewQuestionRequested threadId requestId question ->
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { reviewSessionPhase = ReviewWaiting,
              reviewSessionActivity = "waiting for answer",
              reviewSessionPending = Just (PendingReviewQuestion requestId question)
            }
      )
  ReviewApprovalRequested threadId requestId approval ->
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { reviewSessionPhase = ReviewWaiting,
              reviewSessionActivity = "waiting for approval",
              reviewSessionPending = Just (PendingReviewApproval requestId approval)
            }
      )
  ReviewClaudeStarted threadId -> do
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { reviewSessionTranscript =
                appendReviewTranscript session.reviewSessionTranscript "\n[sonnet] Starting authenticated Sonnet 5 high…\n",
              reviewSessionActivity = "running Claude reviewer"
            }
      )
    vScrollToEnd (viewportScroll ReviewViewport)
  ReviewClaudeFinished threadId result -> do
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { reviewSessionTranscript =
                appendReviewTranscript session.reviewSessionTranscript ("[opus] " <> completionMessage result <> "\n"),
              reviewSessionActivity = "processing reviewer result"
            }
      )
    vScrollToEnd (viewportScroll ReviewViewport)
  ReviewGitHubStarted threadId summary -> do
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { reviewSessionTranscript =
                appendReviewTranscript session.reviewSessionTranscript ("\n[github] " <> sanitizeText summary <> "\n"),
              reviewSessionActivity = "updating GitHub"
            }
      )
    vScrollToEnd (viewportScroll ReviewViewport)
  ReviewGitHubFinished threadId result -> do
    modifyReviewSessionByThread threadId
      ( \session ->
          session
            { reviewSessionTranscript =
                appendReviewTranscript session.reviewSessionTranscript ("[github] " <> githubCompletionMessage result <> "\n"),
              reviewSessionActivity = "processing GitHub result"
            }
      )
    vScrollToEnd (viewportScroll ReviewViewport)
  ReviewTurnCompleted threadId outcome message result -> do
    modifyReviewSessionByThread threadId
      ( \session ->
          let completedStage = maybe session.reviewSessionStage (reviewResultStage . snd) result
           in session
                { reviewSessionStage = completedStage,
                  reviewSessionTurnId = Nothing,
                  reviewSessionPhase = outcomePhase completedStage outcome (snd <$> result),
                  reviewSessionActivity = reviewOutcomeActivity completedStage outcome (snd <$> result),
                  reviewSessionPending = Nothing,
                  reviewSessionTranscript =
                    maybe (formatReviewTranscript session.reviewSessionTranscript result)
                      (appendReviewTranscript session.reviewSessionTranscript . ("\n" <>))
                      message
                }
      )
    case outcome of
      TurnSucceeded -> startBoardRefresh
      _ -> pure ()
  ReviewStartFailed issueNumber message ->
    modifyReviewSession issueNumber
      ( \session ->
          session
            { reviewSessionPhase = ReviewFailed,
              reviewSessionActivity = "failed",
              reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript ("\n" <> message)
            }
      )
  ReviewClientStopped message ->
    modify
      ( \state ->
          state
            { appReviewBackend = ReviewBackendFailed message,
              appReviewSessions = Map.map (markDisconnected message) state.appReviewSessions,
              appNotice = Just message
            }
      )
  ReviewProtocolWarning message -> setNotice ("Codex protocol warning: " <> message)
  where
    outcomePhase IssueRevision TurnSucceeded (Just result)
      | null result.reviewResultBlockingReasons = ReviewFinished
      | otherwise = ReviewNeedsChanges
    outcomePhase _ TurnSucceeded (Just result)
      | result.reviewResultApproved = ReviewFinished
      | otherwise = ReviewNeedsChanges
    outcomePhase _ TurnSucceeded Nothing = ReviewFailed
    outcomePhase _ TurnFailed _ = ReviewFailed
    outcomePhase _ TurnInterrupted _ = ReviewInterrupted
    reviewOutcomeActivity completedStage TurnSucceeded (Just result)
      | completedStage == IssueRevision && null result.reviewResultBlockingReasons = "revision published"
      | result.reviewResultApproved = "approved"
      | otherwise = "changes requested"
    reviewOutcomeActivity _ TurnSucceeded Nothing = "invalid result"
    reviewOutcomeActivity _ TurnFailed _ = "failed"
    reviewOutcomeActivity _ TurnInterrupted _ = "interrupted"
    completionMessage (Right ()) = "Sonnet response returned to the coordinator."
    completionMessage (Left message) = "Sonnet failed: " <> sanitizeText message
    githubCompletionMessage (Right _) = "GitHub operation completed and returned to the coordinator."
    githubCompletionMessage (Left message) = "GitHub operation failed: " <> sanitizeText message
    formatReviewTranscript transcript Nothing = transcript
    formatReviewTranscript transcript (Just (rawResult, result)) =
      appendReviewTranscript
        (stripTranscriptSuffix (sanitizeText rawResult) transcript)
        ("\n\n" <> renderReviewResult result)
    stripTranscriptSuffix suffix transcript =
      ChatTranscript
        { compactTranscript = fromMaybe transcript.compactTranscript (Text.stripSuffix suffix transcript.compactTranscript),
          standardTranscript = fromMaybe transcript.standardTranscript (Text.stripSuffix suffix transcript.standardTranscript),
          fullTranscript = fromMaybe transcript.fullTranscript (Text.stripSuffix suffix transcript.fullTranscript)
        }
    markDisconnected message session
      | session.reviewSessionStage == IssueRevision && session.reviewSessionPhase `elem` [ReviewStarting, ReviewRunning, ReviewWaiting] =
          session
            { reviewSessionPhase = ReviewFailed,
              reviewSessionActivity = "disconnected",
              reviewSessionTranscript = appendReviewTranscript session.reviewSessionTranscript ("\n" <> message)
            }
      | otherwise = session

applyReviewAnimationTick :: Text -> EventM Name AppState ()
applyReviewAnimationTick threadId = do
  state <- get
  case findReviewSessionByThread threadId state of
    Just (_, session)
      | session.reviewSessionPhase `elem` [ReviewStarting, ReviewRunning] -> do
          modifyReviewSessionByThread threadId (\current -> current {reviewSessionSpinnerFrame = current.reviewSessionSpinnerFrame + 1})
          scheduleReviewTick threadId
    _ -> pure ()

scheduleReviewTick :: Text -> EventM Name AppState ()
scheduleReviewTick threadId = do
  eventChannel <- (.appEventChannel) <$> get
  void
    . liftIO
    . forkIO
    $ do
      threadDelay reviewAnimationIntervalMicros
      writeBChan eventChannel (ReviewAnimationTick threadId)

reviewAnimationIntervalMicros :: Int
reviewAnimationIntervalMicros = 100 * 1000

toggleDrainer :: EventM Name AppState ()
toggleDrainer = do
  state <- get
  if state.appDrainerBusy
    then setNotice "PR drainer is already starting or stopping"
    else case state.appDrainerController of
      Left message -> setNotice ("PR drainer control unavailable: " <> sanitizeText message)
      Right controller -> do
        let shouldRun = not (drainerIsRunning state.appDrainerStatus)
            transition = if shouldRun then DrainerStatus DrainerStarting "starting…" else DrainerStatus DrainerStopping "stopping…"
        modify
          ( \current ->
              current
                { appDrainerStatus = transition,
                  appDrainerBusy = True,
                  appNotice = Just (if shouldRun then "Starting PR drainer…" else "Stopping PR drainer…")
                }
          )
        void
          . liftIO
          . forkIO
          $ setDrainerRunning controller shouldRun >>= writeBChan state.appEventChannel . DrainerToggleFinished

applyDrainerStatus :: Either Text DrainerStatus -> EventM Name AppState ()
applyDrainerStatus result = modify $ \state ->
  if state.appDrainerBusy
    then state
    else state {appDrainerStatus = either drainerErrorStatus id result}

applyDrainerToggle :: Either Text DrainerStatus -> EventM Name AppState ()
applyDrainerToggle result = modify $ \state ->
  let status = either drainerErrorStatus id result
      notice = case result of
        Left message -> "PR drainer control failed: " <> sanitizeText message
        Right _ -> "PR drainer is " <> status.drainerDetail
   in state
        { appDrainerStatus = status,
          appDrainerBusy = False,
          appNotice = Just notice
        }

drainerErrorStatus :: Text -> DrainerStatus
drainerErrorStatus message = DrainerStatus DrainerError (sanitizeText message)

startAllRefreshes :: EventM Name AppState ()
startAllRefreshes = do
  startBoardRefresh
  startUsageRefreshes

startUsageRefreshes :: EventM Name AppState ()
startUsageRefreshes = do
  startCodexRefresh
  startClaudeRefresh

startBoardRefresh :: EventM Name AppState ()
startBoardRefresh = do
  state <- get
  case state.appBoardFreshness of
    Loading -> setNotice "GitHub refresh is already running"
    _ -> do
      modify
        ( \current ->
            current
              { appBoardFreshness = Loading,
                appNotice = Just "Refreshing GitHub…"
              }
        )
      void
        . liftIO
        . forkIO
        $ runBoardRefresh state.appOptions state.appRepository state.appEventChannel

runBoardRefresh :: Options -> Repository -> BChan AppEvent -> IO ()
runBoardRefresh options repository eventChannel = do
  timedResult <- timeout boardRefreshTimeoutMicros (fetchGitHubSnapshot repository)
  result <- case timedResult of
    Nothing -> pure (Left (ProviderError RequestTimedOut "GitHub refresh timed out after 30 seconds"))
    Just (Left providerError) -> pure (Left providerError)
    Just (Right githubResult)
      | options.optionNoCache -> pure (Right githubResult)
      | otherwise -> do
          cacheResult <- writeRepositoryCache repository githubResult.githubSnapshot
          pure . Right $ case cacheResult of
            Left warning -> githubResult {githubWarnings = githubResult.githubWarnings <> [warning]}
            Right () -> githubResult
  writeBChan eventChannel (BoardRefreshFinished result)

startCodexRefresh :: EventM Name AppState ()
startCodexRefresh = do
  state <- get
  case Map.findWithDefault NotLoaded Codex state.appUsageFreshness of
    Loading -> setNotice "Codex usage refresh is already running"
    _ -> do
      modify
        ( \current ->
            current
              { appUsageFreshness = Map.insert Codex Loading current.appUsageFreshness,
                appNotice = Just "Refreshing Codex usage…"
              }
        )
      void
        . liftIO
        . forkIO
        $ runCodexRefresh state.appEventChannel

runCodexRefresh :: BChan AppEvent -> IO ()
runCodexRefresh eventChannel = fetchCodexUsage >>= writeBChan eventChannel . CodexRefreshFinished

startClaudeRefresh :: EventM Name AppState ()
startClaudeRefresh = do
  state <- get
  case Map.findWithDefault NotLoaded Claude state.appUsageFreshness of
    Loading -> setNotice "Claude usage refresh is already running"
    _ -> do
      modify
        ( \current ->
            current
              { appUsageFreshness = Map.insert Claude Loading current.appUsageFreshness,
                appNotice = Just "Refreshing Claude usage…"
              }
        )
      void
        . liftIO
        . forkIO
        $ runClaudeRefresh state.appEventChannel

runClaudeRefresh :: BChan AppEvent -> IO ()
runClaudeRefresh eventChannel = fetchClaudeUsage >>= writeBChan eventChannel . ClaudeRefreshFinished

boardRefreshTimeoutMicros :: Int
boardRefreshTimeoutMicros = 30 * 1000 * 1000

applyBoardRefresh :: Either ProviderError GitHubResult -> EventM Name AppState ()
applyBoardRefresh result = do
  modify $ \state -> case result of
    Left providerError ->
      state
        { appBoardFreshness = failureFreshness state providerError,
          appNotice = Just (renderProviderError providerError)
        }
    Right githubResult ->
      let snapshot = githubResult.githubSnapshot
          refreshedBoard = deriveBoard defaultWorkflowConfig snapshot
          (selectedColumn, selectedRows) = preserveSelection state refreshedBoard
          (refreshedOverlay, overlayNotice) = refreshOverlay refreshedBoard state.appOverlay
          refreshedReviewSessions = reconcileReviewSessions snapshot.snapshotIssues state.appReviewSessions
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
  startPendingWorkerMonitors
  case result of
    Right githubResult -> advanceAutoSolves githubResult.githubSnapshot
    Left _ -> pure ()

reconcilePullRequestSessions :: [PullRequest] -> Map Int PullRequestReviewSession -> Map Int PullRequestReviewSession
reconcilePullRequestSessions pullRequests = Map.mapWithKey reconcile
  where
    pullRequestsByNumber = Map.fromList [(pullRequest.pullRequestNumber, pullRequest) | pullRequest <- pullRequests]
    reconcile number session = case Map.lookup number pullRequestsByNumber of
      Nothing -> session
      Just pullRequest -> session {pullRequestSessionPullRequest = pullRequest}

advanceAutoSolves :: RepoSnapshot -> EventM Name AppState ()
advanceAutoSolves snapshot = do
  sessions <- Map.toList . (.appSolveSessions) <$> get
  mapM_ (uncurry (advanceAutoSolve snapshot)) sessions

advanceAutoSolve :: RepoSnapshot -> Int -> SolveSession -> EventM Name AppState ()
advanceAutoSolve snapshot issueNumber session = case session.solveSessionAutoProgress of
  Nothing -> pure ()
  Just progress -> case progress.autoSolveStage of
    AutoDiscoveringPullRequest -> discoverAutoSolvePullRequest snapshot issueNumber session progress
    AutoReviewing -> advanceAutoSolveReview snapshot issueNumber session progress
    AutoAwaitingRereview -> advanceAutoSolveAwaitingRereview snapshot issueNumber session progress
    _ -> pure ()

discoverAutoSolvePullRequest :: RepoSnapshot -> Int -> SolveSession -> AutoSolveProgress -> EventM Name AppState ()
discoverAutoSolvePullRequest snapshot issueNumber session progress = case newLinkedPullRequests of
  [] ->
    modifySolveSession issueNumber
      (\current -> current {solveSessionActivity = "waiting for linked PR; press u to retry"})
  [pullRequest] -> case originFromBody pullRequest.pullRequestBody of
    Right origin | origin == expectedPullRequestOrigin session.solveSessionBrand -> do
      let roundNumber = 1
      modifySolveSession issueNumber
        ( \current ->
            current
              { solveSessionPhase = SolveRunning,
                solveSessionActivity = "reviewing PR #" <> showText pullRequest.pullRequestNumber,
                solveSessionAutoProgress =
                  Just
                    progress
                      { autoSolveStage = AutoReviewing,
                        autoSolvePullRequest = Just pullRequest.pullRequestNumber,
                        autoSolveReviewRound = roundNumber
                      },
                solveSessionTranscript = appendSolveTranscript current.solveSessionTranscript ("\n[kanban] Discovered PR #" <> showText pullRequest.pullRequestNumber <> "; starting review round 1.\n")
              }
        )
      startPullRequestReviewWithVisibility False pullRequest
      setNotice ("Autosolve #" <> showText issueNumber <> " discovered PR #" <> showText pullRequest.pullRequestNumber <> " and started review")
    Right _ -> stopAutoSolve issueNumber "new linked PR has the wrong origin marker for the selected solver"
    Left message -> stopAutoSolve issueNumber ("new linked PR cannot be reviewed: " <> message)
  _ -> stopAutoSolve issueNumber "multiple new linked PRs appeared; choose the intended PR manually"
  where
    newLinkedPullRequests =
      [ pullRequest
        | pullRequest <- snapshot.snapshotPullRequests,
          issueNumber `elem` pullRequest.pullRequestLinkedIssues,
          pullRequest.pullRequestNumber `Set.notMember` progress.autoSolveKnownPullRequests,
          pullRequest.pullRequestCreatedAt >= addUTCTime (-300) progress.autoSolveStartedAt
      ]

advanceAutoSolveReview :: RepoSnapshot -> Int -> SolveSession -> AutoSolveProgress -> EventM Name AppState ()
advanceAutoSolveReview snapshot issueNumber session progress = case progress.autoSolvePullRequest >>= findSnapshotPullRequest snapshot of
  Nothing -> stopAutoSolve issueNumber "the autosolve PR disappeared before review completed"
  Just pullRequest -> do
    state <- get
    case Map.lookup pullRequest.pullRequestNumber state.appPullRequestReviewSessions of
      Nothing -> startPullRequestReviewWithVisibility False pullRequest
      Just reviewSession -> case reviewSession.pullRequestSessionPhase of
        SolveFailedPhase -> failAutoSolve issueNumber ("PR #" <> showText pullRequest.pullRequestNumber <> " review failed; press p to inspect it")
        SolveKilledPhase -> failAutoSolve issueNumber ("PR #" <> showText pullRequest.pullRequestNumber <> " review was killed")
        SolveAttention ->
          modifySolveSession issueNumber
            (\current -> current {solveSessionActivity = "PR review needs input; press p"})
        SolveFinished
          | pullRequestHasLabel "reviewed:approve" pullRequest -> completeAutoSolve issueNumber pullRequest.pullRequestNumber
          | pullRequestHasLabel "reviewed:changes" pullRequest -> resumeAutoSolveRevision issueNumber pullRequest session progress
          | otherwise ->
              modifySolveSession issueNumber
                (\current -> current {solveSessionActivity = "waiting for review verdict; press u to retry"})
        _ ->
          modifySolveSession issueNumber
            (\current -> current {solveSessionActivity = "reviewing PR #" <> showText pullRequest.pullRequestNumber})

-- | pr-revise invokes the canonical rereview itself, so once the resumed
-- solver's revision finishes, the fresh verdict already lands on the PR as
-- reviewed:approve or reviewed:changes; this never waits on a Kanban-created
-- reviewed:revised label.
advanceAutoSolveAwaitingRereview :: RepoSnapshot -> Int -> SolveSession -> AutoSolveProgress -> EventM Name AppState ()
advanceAutoSolveAwaitingRereview snapshot issueNumber session progress = case progress.autoSolvePullRequest >>= findSnapshotPullRequest snapshot of
  Nothing -> stopAutoSolve issueNumber "the autosolve PR disappeared after revision"
  Just pullRequest -> case pullRequestVerdictForLabels (map (.labelName) pullRequest.pullRequestLabels) of
    PullRequestVerdictApproved -> completeAutoSolve issueNumber pullRequest.pullRequestNumber
    PullRequestVerdictChangesRequested -> resumeAutoSolveRevision issueNumber pullRequest session (progress {autoSolveReviewRound = progress.autoSolveReviewRound + 1})
    PullRequestVerdictPending ->
      modifySolveSession issueNumber
        (\current -> current {solveSessionActivity = "waiting for the canonical rereview verdict; press u to retry"})

resumeAutoSolveRevision :: Int -> PullRequest -> SolveSession -> AutoSolveProgress -> EventM Name AppState ()
resumeAutoSolveRevision issueNumber pullRequest session progress
  | progress.autoSolveReviewRound >= autoSolveReviewLimit =
      stopAutoSolve issueNumber ("PR #" <> showText pullRequest.pullRequestNumber <> " still has requested changes after " <> showText autoSolveReviewLimit <> " review rounds")
  | otherwise = case session.solveSessionId of
      Nothing -> stopAutoSolve issueNumber "the original solver did not return a resumable session id"
      Just sessionId -> do
        state <- get
        if Map.member issueNumber state.appSolveProcesses
          then pure ()
          else do
            let prompt = autoSolveRevisionPrompt session.solveSessionBrand pullRequest.pullRequestNumber progress.autoSolveReviewRound
            modifySolveSession issueNumber
              ( \current ->
                  current
                    { solveSessionPhase = SolveStarting,
                      solveSessionActivity = "resuming solver for requested changes",
                      solveSessionAutoProgress = Just progress {autoSolveStage = AutoRevising},
                      solveSessionTranscript = appendSolveTranscript current.solveSessionTranscript ("\n[kanban] Review requested changes on PR #" <> showText pullRequest.pullRequestNumber <> "; resuming the original solver.\n")
                    }
              )
            launchSolveInvocation issueNumber AutoSolve session.solveSessionBrand (Just sessionId) prompt
            setNotice ("Autosolve #" <> showText issueNumber <> " resumed its original solver for PR #" <> showText pullRequest.pullRequestNumber)

completeAutoSolve :: Int -> Int -> EventM Name AppState ()
completeAutoSolve issueNumber pullRequestNumber = do
  modifySolveSession issueNumber
    ( \session ->
        session
          { solveSessionPhase = SolveFinished,
            solveSessionActivity = "approved PR #" <> showText pullRequestNumber,
            solveSessionAutoProgress = (\progress -> progress {autoSolveStage = AutoSolveComplete}) <$> session.solveSessionAutoProgress,
            solveSessionTranscript = appendSolveTranscript session.solveSessionTranscript ("\n[kanban] PR #" <> showText pullRequestNumber <> " approved; autosolve complete.\n")
          }
    )
  setNotice ("Autosolve #" <> showText issueNumber <> " completed: PR #" <> showText pullRequestNumber <> " is approved")

stopAutoSolve :: Int -> Text -> EventM Name AppState ()
stopAutoSolve issueNumber reason = do
  modifySolveSession issueNumber
    ( \session ->
        session
          { solveSessionPhase = SolveAttention,
            solveSessionActivity = reason,
            solveSessionAutoProgress = (\progress -> progress {autoSolveStage = AutoSolveStopped}) <$> session.solveSessionAutoProgress,
            solveSessionTranscript = appendSolveTranscript session.solveSessionTranscript ("\n[kanban] Autosolve stopped: " <> sanitizeText reason <> "\n")
          }
    )
  setNotice ("Autosolve #" <> showText issueNumber <> " stopped: " <> sanitizeText reason)

failAutoSolve :: Int -> Text -> EventM Name AppState ()
failAutoSolve issueNumber reason = do
  modifySolveSession issueNumber
    ( \session ->
        session
          { solveSessionPhase = SolveFailedPhase,
            solveSessionActivity = reason,
            solveSessionAutoProgress = (\progress -> progress {autoSolveStage = AutoSolveStopped}) <$> session.solveSessionAutoProgress,
            solveSessionTranscript = appendSolveTranscript session.solveSessionTranscript ("\n[kanban] Autosolve failed: " <> sanitizeText reason <> "\n")
          }
    )
  setNotice ("Autosolve #" <> showText issueNumber <> " failed: " <> sanitizeText reason)

autoSolveRevisionPrompt :: SolverBrand -> Int -> Int -> Text
autoSolveRevisionPrompt brand pullRequestNumber reviewRound =
  Text.unlines
    [ "Kanban received CHANGES_REQUESTED for PR #" <> showText pullRequestNumber <> " in review round " <> showText reviewRound <> ".",
      "Resume the existing solve context and run " <> commandName "pr-revise" <> " for PR #" <> showText pullRequestNumber <> ".",
      "Use the canonical revise-and-rereview workflow: act only on a current canonical CHANGES_REQUESTED verdict for this head, rerouting stale feedback through canonical rereview before editing; work only in a clean isolated worktree and never overwrite a concurrently updated head; after pushing, wait for required CI on the pushed head, then invoke exactly one canonical PR rereview.",
      "Never merge, and leave reviewed:approve, reviewed:changes, and reviewed:revised to the canonical review coordinator."
    ]
  where
    commandName name = if brand == CodexSolver then "$" <> name else "/" <> name

autoSolveReviewLimit :: Int
autoSolveReviewLimit = 5

expectedPullRequestOrigin :: SolverBrand -> PullRequestOrigin
expectedPullRequestOrigin CodexSolver = PullRequestCodex
expectedPullRequestOrigin ClaudeSolver = PullRequestClaude

findSnapshotPullRequest :: RepoSnapshot -> Int -> Maybe PullRequest
findSnapshotPullRequest snapshot number =
  find ((== number) . (.pullRequestNumber)) snapshot.snapshotPullRequests

pullRequestHasLabel :: Text -> PullRequest -> Bool
pullRequestHasLabel labelName pullRequest =
  any ((== Text.toCaseFold labelName) . Text.toCaseFold . (.labelName)) pullRequest.pullRequestLabels

boardPullRequestNumbers :: Board -> Set Int
boardPullRequestNumbers board =
  Set.fromList
    [ pullRequest.pullRequestNumber
      | column <- allColumns,
        entry <- entriesForBoard board column,
        PullRequestItem pullRequest <- [entryItem entry]
    ]

reconcileReviewSessions :: [Issue] -> Map Int ReviewSession -> Map Int ReviewSession
reconcileReviewSessions issues = Map.mapWithKey reconcile
  where
    issuesByNumber = Map.fromList [(issue.issueNumber, issue) | issue <- issues]
    reconcile issueNumber session = case Map.lookup issueNumber issuesByNumber of
      Nothing -> session
      Just issue ->
        session
          { reviewSessionIssue = issue,
            reviewSessionPhase = reconciledPhase issue session
          }
    reconciledPhase issue session
      | issueHasLabel "reviewed:approve" issue = ReviewFinished
      | issueHasLabel "reviewed:changes" issue && session.reviewSessionPhase == ReviewFailed = ReviewNeedsChanges
      | otherwise = session.reviewSessionPhase

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
      if state.appOptions.optionNoCache
        then pure Nothing
        else either Just (const Nothing) <$> liftIO (writeUsageCache snapshots)
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

countedSource :: Text -> Int -> Bool -> Text
countedSource noun count truncated =
  showText count <> (if truncated then "+" else "") <> " " <> noun <> if count == 1 then "" else "s"

columnCountText :: AppState -> BoardColumn -> Text
columnCountText state column =
  showText (length (entriesFor state column)) <> if columnMayBeTruncated then "+" else ""
  where
    columnMayBeTruncated = case column of
      Issues -> state.appIssuesTruncated
      Active -> state.appIssuesTruncated
      Reviewing -> state.appPullRequestsTruncated
      Done -> state.appPullRequestsTruncated

appendWarnings :: Text -> [Text] -> Text
appendWarnings message [] = message
appendWarnings message warnings = message <> " · " <> Text.intercalate " · " warnings

preserveSelection :: AppState -> Board -> (BoardColumn, Map BoardColumn Int)
preserveSelection state board =
  case selectedItem state >>= (findItem board . itemId) of
    Just (column, row, _) ->
      let visibleRow = normalizeCollapsedRow state board column row
       in (column, rowsWithSelection column visibleRow)
    Nothing -> (state.appSelectedColumn, clampedRows)
  where
    clampedRows =
      Map.fromList
        [ (column, normalizeCollapsedRow state board column (clampRow board column (selectedRow state column)))
          | column <- allColumns
        ]
    rowsWithSelection selectedColumn selectedIndex = Map.insert selectedColumn selectedIndex clampedRows

clampRow :: Board -> BoardColumn -> Int -> Int
clampRow board column row = max 0 (min row (length (entriesForBoard board column) - 1))

normalizeCollapsedRow :: AppState -> Board -> BoardColumn -> Int -> Int
normalizeCollapsedRow state board column row = case safeIndex row entries >>= entryPrimaryTrackerNumber of
  Just trackerNumber
    | trackerNumber `Set.notMember` state.appExpandedTrackers ->
        maybe row id (findIndex ((== Just trackerNumber) . entryPrimaryTrackerNumber) entries)
  _ -> row
  where
    entries = entriesForBoard board column

refreshOverlay :: Board -> Maybe Overlay -> (Maybe Overlay, Maybe Text)
refreshOverlay _ Nothing = (Nothing, Nothing)
refreshOverlay _ (Just HelpOverlay) = (Just HelpOverlay, Nothing)
refreshOverlay _ (Just SettingsOverlay) = (Just SettingsOverlay, Nothing)
refreshOverlay _ (Just ProcessesOverlay) = (Just ProcessesOverlay, Nothing)
refreshOverlay _ (Just overlay@(ReviewOverlay _)) = (Just overlay, Nothing)
refreshOverlay _ (Just overlay@(SolveOverlay _)) = (Just overlay, Nothing)
refreshOverlay _ (Just overlay@(PullRequestReviewOverlay _)) = (Just overlay, Nothing)
refreshOverlay board (Just (SolveChooser workflow oldIssue)) =
  case findItem board (IssueId oldIssue.issueNumber) of
    Just (_, _, IssueItem refreshedIssue) -> (Just (SolveChooser workflow refreshedIssue), Nothing)
    _ -> (Nothing, Just "Solve choice closed because that issue is no longer open")
refreshOverlay board (Just (DetailsOverlay oldItem)) =
  case findItem board (itemId oldItem) of
    Just (_, _, refreshedItem) -> (Just (DetailsOverlay refreshedItem), Nothing)
    Nothing -> (Nothing, Just "Details closed because that item is no longer open")

findItem :: Board -> ItemId -> Maybe (BoardColumn, Int, BoardItem)
findItem board target = (\(column, row, entry) -> (column, row, entryItem entry)) <$> findEntryWithLocation board target

findEntry :: Board -> ItemId -> Maybe ColumnEntry
findEntry board target = (\(_, _, entry) -> entry) <$> findEntryWithLocation board target

findEntryWithLocation :: Board -> ItemId -> Maybe (BoardColumn, Int, ColumnEntry)
findEntryWithLocation board target = firstMatch allColumns
  where
    firstMatch [] = Nothing
    firstMatch (column : rest) =
      let entries = entriesForBoard board column
       in case findIndex ((== target) . itemId . entryItem) entries of
            Just row -> (\entry -> (column, row, entry)) <$> safeIndex row entries
            Nothing -> firstMatch rest

entriesForBoard :: Board -> BoardColumn -> [ColumnEntry]
entriesForBoard board column = Map.findWithDefault [] column board.boardColumns

moveCard :: Int -> EventM Name AppState ()
moveCard delta = modify $ \state ->
  let column = state.appSelectedColumn
      rows = visibleSelectionRows state column
      currentPosition = maybe 0 id (findIndex (== selectedRow state column) rows)
      nextPosition = max 0 (min (length rows - 1) (currentPosition + delta))
   in case safeIndex nextPosition rows of
        Nothing -> state {appEnsureSelectionVisible = True, appNotice = Nothing}
        Just nextRow -> state {appSelectedRows = Map.insert column nextRow state.appSelectedRows, appEnsureSelectionVisible = True, appNotice = Nothing}

moveColumn :: Int -> EventM Name AppState ()
moveColumn delta = modify $ \state ->
  let current = fromEnum state.appSelectedColumn
      maximumColumn = fromEnum (maxBound :: BoardColumn)
      next = max 0 (min maximumColumn (current + delta))
   in state {appSelectedColumn = toEnum next, appEnsureSelectionVisible = True, appNotice = Nothing}

selectBoundary :: Bool -> EventM Name AppState ()
selectBoundary selectLast = modify $ \state ->
  let column = state.appSelectedColumn
      rows = visibleSelectionRows state column
      target = if selectLast then safeLast rows else safeIndex 0 rows
   in case target of
        Nothing -> state {appEnsureSelectionVisible = True, appNotice = Nothing}
        Just row -> state {appSelectedRows = Map.insert column row state.appSelectedRows, appEnsureSelectionVisible = True, appNotice = Nothing}

toggleSelectedTracker :: EventM Name AppState ()
toggleSelectedTracker = modify $ \state ->
  let column = state.appSelectedColumn
      entries = entriesFor state column
      currentRow = selectedRow state column
   in case safeIndex currentRow entries >>= entryPrimaryTrackerNumber of
        Nothing -> state {appEnsureSelectionVisible = True, appNotice = Just "Focus an epic header or child before pressing e"}
        Just trackerNumber ->
          let firstRow = maybe currentRow id (findIndex ((== Just trackerNumber) . entryPrimaryTrackerNumber) entries)
           in toggleTrackerState column firstRow trackerNumber state

toggleTrackerFromClick :: BoardColumn -> Int -> Int -> EventM Name AppState ()
toggleTrackerFromClick column row trackerNumber =
  modify (toggleTrackerState column row trackerNumber)

toggleTrackerState :: BoardColumn -> Int -> Int -> AppState -> AppState
toggleTrackerState column row trackerNumber state
  | trackerNumber `Set.member` state.appExpandedTrackers =
      state
        { appSelectedColumn = column,
          appExpandedTrackers = Set.delete trackerNumber state.appExpandedTrackers,
          appSelectedRows = Map.insert column row state.appSelectedRows,
          appEnsureSelectionVisible = True,
          appNotice = Just ("Collapsed epic #" <> showText trackerNumber)
        }
  | otherwise =
      state
        { appSelectedColumn = column,
          appExpandedTrackers = Set.insert trackerNumber state.appExpandedTrackers,
          appSelectedRows = Map.insert column row state.appSelectedRows,
          appEnsureSelectionVisible = True,
          appNotice = Just ("Expanded epic #" <> showText trackerNumber)
        }

openSelectedDetails :: EventM Name AppState ()
openSelectedDetails = modify $ \state ->
  case selectedEntry state of
    Just entry@(Tracked trackingContext _)
      | primaryTrackerNumber trackingContext `Set.notMember` state.appExpandedTrackers ->
          state {appNotice = Just "Press e to expand this epic"}
      | otherwise -> openEntry state entry
    Just entry -> openEntry state entry
    Nothing -> state {appNotice = Just "No item is selected in this column"}
  where
    openEntry state entry = state {appOverlay = Just (DetailsOverlay (entryItem entry)), appNotice = Nothing}

selectedItem :: AppState -> Maybe BoardItem
selectedItem state = entryItem <$> selectedEntry state

selectedEntry :: AppState -> Maybe ColumnEntry
selectedEntry state = safeIndex (selectedRow state state.appSelectedColumn) (entriesFor state state.appSelectedColumn)

visibleSelectionRows :: AppState -> BoardColumn -> [Int]
visibleSelectionRows state column = collect (zip [0 ..] (entriesFor state column))
  where
    collect [] = []
    collect indexedEntries@((row, entry) : rest) = case entryPrimaryTrackerNumber entry of
      Nothing -> row : collect rest
      Just trackerNumber ->
        let (groupEntries, remaining) = span ((== Just trackerNumber) . entryPrimaryTrackerNumber . snd) indexedEntries
         in if trackerNumber `Set.member` state.appExpandedTrackers
              then map fst groupEntries <> collect remaining
              else row : collect remaining

safeLast :: [value] -> Maybe value
safeLast [] = Nothing
safeLast (value : values) = Just (foldl (\_ next -> next) value values)

entriesFor :: AppState -> BoardColumn -> [ColumnEntry]
entriesFor state column = Map.findWithDefault [] column state.appBoard.boardColumns

selectedRow :: AppState -> BoardColumn -> Int
selectedRow state column = Map.findWithDefault 0 column state.appSelectedRows

safeIndex :: Int -> [value] -> Maybe value
safeIndex index values
  | index < 0 = Nothing
  | otherwise = case drop index values of
      value : _ -> Just value
      [] -> Nothing

allColumns :: [BoardColumn]
allColumns = [minBound .. maxBound]

columnName :: BoardColumn -> Text
columnName Issues = "ISSUES"
columnName Active = "ACTIVE"
columnName Reviewing = "REVIEWING"
columnName Done = "DONE"

showText :: Show value => value -> Text
showText = Text.pack . show

shellBorderStyle :: AppState -> BorderStyle
shellBorderStyle state
  | state.appOptions.optionAscii = ascii
  | otherwise = doubleBorderStyle

innerBorderStyle :: AppState -> BorderStyle
innerBorderStyle state
  | state.appOptions.optionAscii = ascii
  | otherwise = unicodeBold

usesOpenBorders :: AppState -> Bool
usesOpenBorders state =
  not state.appOptions.optionAscii
    && state.appOptions.optionBorder == BorderOpen

cardBorderStyle :: AppState -> BorderStyle
cardBorderStyle state
  | state.appOptions.optionAscii = ascii
  | otherwise = unicode

doubleBorderStyle :: BorderStyle
doubleBorderStyle =
  BorderStyle
    { bsCornerTL = '╔',
      bsCornerTR = '╗',
      bsCornerBR = '╝',
      bsCornerBL = '╚',
      bsIntersectFull = '╬',
      bsIntersectL = '╠',
      bsIntersectR = '╣',
      bsIntersectT = '╦',
      bsIntersectB = '╩',
      bsHorizontal = '═',
      bsVertical = '║'
    }

themeFor :: Options -> AttrMap
themeFor options
  | options.optionColor == ColorNever = attrMap Vty.defAttr [(name, Vty.defAttr) | name <- allAttributeNames]
  | otherwise =
      attrMap
        Vty.defAttr
        [ (titleAttr, foreground Vty.brightCyan `Vty.withStyle` Vty.bold),
          (headingAttr, foreground Vty.brightWhite `Vty.withStyle` Vty.bold),
          (providerAttr, foreground Vty.brightCyan `Vty.withStyle` Vty.bold),
          (footerAttr, foreground Vty.brightBlack),
          (noticeAttr, foreground Vty.yellow),
          (dimAttr, foreground Vty.brightBlack),
          (neutralAttr, foreground Vty.white),
          (selectedAttr, foreground Vty.brightCyan `Vty.withStyle` Vty.bold),
          (approvedAttr, foreground Vty.brightGreen `Vty.withStyle` Vty.bold),
          (approvedInteriorAttr, onColor Vty.black Vty.green),
          (pendingAttr, foreground Vty.yellow),
          (attentionAttr, foreground (Vty.rgbColor (255 :: Int) 165 0) `Vty.withStyle` Vty.bold),
          (readyAttr, foreground Vty.brightGreen),
          (problemAttr, foreground Vty.brightRed `Vty.withStyle` Vty.bold),
          (trackerAttr, foreground (Vty.rgbColor (128 :: Int) 90 213) `Vty.withStyle` Vty.bold),
          (cardTitleAttr, Vty.defAttr `Vty.withStyle` Vty.bold),
          (selectedTitleAttr, foreground Vty.brightCyan `Vty.withStyle` Vty.bold),
          (linkAttr, foreground Vty.brightBlue),
          (labelDefaultAttr, onColor Vty.black Vty.brightWhite),
          (labelApprovalAttr, onColor Vty.black Vty.brightGreen),
          (labelProblemAttr, onColor Vty.brightWhite Vty.red),
          (labelUiAttr, onColor Vty.brightWhite Vty.blue),
          (issuesAttr, foreground Vty.brightWhite),
          (activeAttr, foreground Vty.brightBlue),
          (reviewingAttr, foreground Vty.yellow),
          (doneAttr, foreground Vty.brightGreen)
        ]
  where
    foreground = Vty.withForeColor Vty.defAttr
    onColor textColor background = Vty.withBackColor (Vty.withForeColor Vty.defAttr textColor) background

columnHeadingAttr :: BoardColumn -> AttrName
columnHeadingAttr Issues = issuesAttr
columnHeadingAttr Active = activeAttr
columnHeadingAttr Reviewing = reviewingAttr
columnHeadingAttr Done = doneAttr

labelAttribute :: Text -> AttrName
labelAttribute name
  | folded == "reviewed:approve" = labelApprovalAttr
  | folded == "reviewed:revised" = pendingAttr
  | folded `elem` ["blocked", "reviewed:changes", "bug"] = labelProblemAttr
  | folded `elem` ["ui", "input"] = labelUiAttr
  | otherwise = labelDefaultAttr
  where
    folded = Text.toCaseFold name

titleAttr, headingAttr, providerAttr, footerAttr, noticeAttr, dimAttr :: AttrName
neutralAttr, selectedAttr, approvedAttr, approvedInteriorAttr, pendingAttr, attentionAttr, readyAttr, problemAttr :: AttrName
trackerAttr :: AttrName
cardTitleAttr, selectedTitleAttr, linkAttr, labelDefaultAttr, labelApprovalAttr, labelProblemAttr, labelUiAttr :: AttrName
issuesAttr, activeAttr, reviewingAttr, doneAttr :: AttrName
titleAttr = attrName "title"
headingAttr = attrName "heading"
providerAttr = attrName "provider"
footerAttr = attrName "footer"
noticeAttr = attrName "notice"
dimAttr = attrName "dim"
neutralAttr = attrName "status.neutral"
selectedAttr = attrName "status.selected"
approvedAttr = attrName "status.approved"
approvedInteriorAttr = attrName "interior.approved"
pendingAttr = attrName "status.pending"
attentionAttr = attrName "status.attention"
readyAttr = attrName "status.ready"
problemAttr = attrName "status.problem"
trackerAttr = attrName "tracker"
cardTitleAttr = attrName "card.title"
selectedTitleAttr = attrName "card.title.selected"
linkAttr = attrName "link"
labelDefaultAttr = attrName "label.default"
labelApprovalAttr = attrName "label.approval"
labelProblemAttr = attrName "label.problem"
labelUiAttr = attrName "label.ui"
issuesAttr = attrName "column.issues"
activeAttr = attrName "column.active"
reviewingAttr = attrName "column.reviewing"
doneAttr = attrName "column.done"

allAttributeNames :: [AttrName]
allAttributeNames =
  [ titleAttr,
    headingAttr,
    providerAttr,
    footerAttr,
    noticeAttr,
    dimAttr,
    neutralAttr,
    selectedAttr,
    approvedAttr,
    approvedInteriorAttr,
    pendingAttr,
    attentionAttr,
    readyAttr,
    problemAttr,
    trackerAttr,
    cardTitleAttr,
    selectedTitleAttr,
    linkAttr,
    labelDefaultAttr,
    labelApprovalAttr,
    labelProblemAttr,
    labelUiAttr,
    issuesAttr,
    activeAttr,
    reviewingAttr,
    doneAttr
  ]
