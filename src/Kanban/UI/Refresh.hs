module Kanban.UI.Refresh
  ( BoardRefreshDispatch (..),
    boardRefreshDispatch,
    boardRefreshRunner,
    claudeRefreshTimeoutMicros,
    codexRefreshTimeoutMicros,
    githubRefreshTimeoutMicros,
    historyPausedNotice,
    markBoardRefreshRunning,
    newBoardRefreshCoordinator,
    persistBoardRefresh,
    releaseQueuedBoardRefresh,
    requireBoardRefresh,
    runBoardRefreshWith,
    runClaudeRefresh,
    runCodexRefresh,
    startAllRefreshes,
    startBoardRefresh,
    startQueuedBoardRefresh,
  )
where


import Brick
import Brick.BChan (BChan, writeBChan)
import Control.Concurrent (forkIO )
import Control.Monad (void, when)
import Control.Monad.IO.Class (liftIO)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (TimeZone, UTCTime, addUTCTime, getCurrentTime)
import Kanban.Cache
  ( writeRepositoryCache
    )
import Kanban.CLI (Options (..))
import Kanban.Claude (fetchClaudeUsage)
import Kanban.Codex (fetchCodexUsage)
import Kanban.Config (ResolvedConfig (..), TimeoutsConfig (..), UsageCommandConfig (..), UsageConfig (..))
import Kanban.Domain
import Kanban.GitHub
  ( CoordinatorNotice (..),
    GhFetchGuard,
    GitHubResult (..),
    HistoryPageResult (..),
    OpenRefreshResult (..),
    RateObserver,
    RefreshCoordinator,
    RefreshJob (..),
    RefreshRunner (..),
    coordinatorOpenCycleInFlight,
    fetchGitHubSnapshot,
    ghFetchCleanupFailure,
    newGhFetchGuard,
    newGhRecordLock,
    newRefreshCoordinator,
    requestRefreshJob
    )
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.UsageCommand (runUsageCommand)
import System.Timeout (timeout)
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.State

startAllRefreshes :: EventM Name AppState ()
startAllRefreshes = do
  startBoardRefresh
  startUsageRefreshes

startUsageRefreshes :: EventM Name AppState ()
startUsageRefreshes = do
  startCodexRefresh
  startClaudeRefresh

-- | Whether a requested refresh can start a cycle now, or has to wait for the
-- one in flight.
--
-- Both callers reach the same answer for the same reason. A refresh that must
-- observe an already-committed change is not satisfied by a fetch already in
-- flight, which may have read GitHub before the change landed; and a plain
-- update pressed during a cycle wants the state after it, not the state it is
-- already fetching. Neither may start a second cycle beside the first, so both
-- leave one follow-up behind instead.
--
-- It takes two answers because neither alone is complete. The board's own
-- freshness is what a running cycle is normally read off, but it is updated by
-- an event, so a cycle the coordinator started of its own accord -- the
-- reissue after a rate limit -- is in flight for a moment before the board
-- knows. The coordinator's answer has no such window and covers that moment;
-- the board's covers the mirror case, a cycle requested but not yet taken up.
data BoardRefreshDispatch = StartRefreshNow | QueueRefreshUntilIdle
  deriving stock (Eq, Show)

boardRefreshDispatch :: Freshness -> Bool -> BoardRefreshDispatch
boardRefreshDispatch Loading _ = QueueRefreshUntilIdle
boardRefreshDispatch _ True = QueueRefreshUntilIdle
boardRefreshDispatch _ False = StartRefreshNow

-- | Whether a queued required refresh may start now that a fetch has
-- published its outcome. A board still 'Loading' afterwards is one a failed
-- refresh left unable to fetch at all, so the request stays queued rather
-- than being spent on a call that would only be turned away.
releaseQueuedBoardRefresh :: Bool -> Freshness -> Bool
releaseQueuedBoardRefresh queued freshness = queued && freshness /= Loading

-- | Refresh the board because something this dashboard did has already
-- changed GitHub. Unlike 'startBoardRefresh' this never simply reports that a
-- refresh is running: the request survives as 'appBoardRefreshQueued' and
-- starts when the in-flight fetch publishes.
requireBoardRefresh :: EventM Name AppState ()
requireBoardRefresh = do
  state <- get
  inFlight <- liftIO (coordinatorOpenCycleInFlight state.appRefreshCoordinator)
  case boardRefreshDispatch state.appBoardFreshness inFlight of
    StartRefreshNow -> startBoardRefresh
    QueueRefreshUntilIdle -> modify (\current -> current {appBoardRefreshQueued = True})

startQueuedBoardRefresh :: EventM Name AppState ()
startQueuedBoardRefresh = do
  state <- get
  when (releaseQueuedBoardRefresh state.appBoardRefreshQueued state.appBoardFreshness) $ do
    modify (\current -> current {appBoardRefreshQueued = False})
    startBoardRefresh

-- | Set a notice, keeping an outstanding direct-merge result in front of it
-- and carrying that result forward only while it is still the one displayed.
announceOverDirectMergeResult :: Text -> EventM Name AppState ()
announceOverDirectMergeResult notice =
  modify
    ( \state ->
        let outstanding = outstandingDirectMergeReport state.appNotice state.appDirectMergeResult
            (composed, carried) = directMergeNoticeFor outstanding notice
         in state {appNotice = Just composed, appDirectMergeResult = carried}
    )

-- | The board's own refresh request, which is now a request to the
-- repository's coordinator rather than a thread of its own.
--
-- A press arriving while a cycle is running still reports that, and now also
-- leaves exactly one follow-up behind it: 'appBoardRefreshQueued' is a single
-- flag, so any number of presses coalesce onto the one newest follow-up, and
-- none of them starts an overlapping worker. That follow-up is released by
-- 'startQueuedBoardRefresh' once the running cycle has published — and only
-- when the board can actually accept work, which is what keeps a request from
-- being spent on a dashboard held off by an unrecorded cleanup.
startBoardRefresh :: EventM Name AppState ()
startBoardRefresh = do
  state <- get
  inFlight <- liftIO (coordinatorOpenCycleInFlight state.appRefreshCoordinator)
  case boardRefreshDispatch state.appBoardFreshness inFlight of
    QueueRefreshUntilIdle -> do
      announceOverDirectMergeResult "GitHub refresh is already running"
      modify (\current -> current {appBoardRefreshQueued = True})
    StartRefreshNow -> do
      announceOverDirectMergeResult "Refreshing GitHub…"
      modify (\current -> current {appBoardFreshness = Loading})
      now <- liftIO getCurrentTime
      -- The deadline is set here rather than inside the fetch, because from
      -- the board's side waiting for the owner and waiting for a rate limit
      -- are indistinguishable from a slow response: all three are this
      -- request taking too long, and the configured timeout is what bounds
      -- the whole of it.
      let deadline = addUTCTime (fromIntegral state.appConfig.resolvedTimeouts.timeoutsGithubSeconds) now
      liftIO (requestRefreshJob state.appRefreshCoordinator OpenJob (Just deadline))

-- | Records that the coordinator has taken the owner for a foreground cycle.
--
-- The board's own "a refresh is already running" answer is read off this
-- state, so it has to cover every cycle rather than only the ones a key press
-- started. A cycle the coordinator reissued itself after a rate limit is one
-- nobody pressed for, and leaving it unrecorded is what would let the next
-- press start a second one beside it.
--
-- Only the freshness moves. Whatever notice is on screen -- above all the
-- rate limit that caused the reissue -- is the explanation for the wait, and
-- replacing it would remove the one report that says why.
markBoardRefreshRunning :: EventM Name AppState ()
markBoardRefreshRunning = modify (\state -> state {appBoardFreshness = Loading})

-- | The configured GitHub/Codex/Claude provider timeouts, converted from
-- whole seconds to the microseconds 'System.Timeout.timeout' takes.
githubRefreshTimeoutMicros, codexRefreshTimeoutMicros, claudeRefreshTimeoutMicros :: ResolvedConfig -> Int
githubRefreshTimeoutMicros config = config.resolvedTimeouts.timeoutsGithubSeconds * 1000000
codexRefreshTimeoutMicros config = config.resolvedTimeouts.timeoutsCodexSeconds * 1000000
claudeRefreshTimeoutMicros config = config.resolvedTimeouts.timeoutsClaudeSeconds * 1000000

-- | The repository's one coordinator, wired to the board: outcomes reach the
-- event channel exactly as a lone refresh thread's did, and what the
-- scheduler has to say for itself reaches the same notice line.
newBoardRefreshCoordinator :: Options -> ResolvedConfig -> Repository -> BChan AppEvent -> IO (RefreshCoordinator BoardRefreshOutcome)
newBoardRefreshCoordinator options config repository eventChannel = do
  recordLock <- newGhRecordLock
  newRefreshCoordinator
    recordLock
    (boardRefreshRunner config repository)
    (\outcome -> persistBoardRefresh options config repository outcome >>= writeBChan eventChannel . BoardRefreshFinished)
    ( \notice -> case notice of
        HistoryPausedUntilReset resetAt -> writeBChan eventChannel (BoardHistoryPaused resetAt)
        OpenRefreshStarted -> writeBChan eventChannel BoardRefreshStarted
    )

-- | What the coordinator's two job kinds do for the board.
--
-- History has no source yet: completed issue and pull-request traversal
-- arrives with its own slice, and until then a history page reports itself
-- immediately finished rather than pretending to fetch. The scheduling around
-- it is real all the same, which is what lets that slice supply a page and
-- nothing else change.
boardRefreshRunner :: ResolvedConfig -> Repository -> RefreshRunner BoardRefreshOutcome
boardRefreshRunner config repository =
  RefreshRunner
    { runOpenRefresh = runBoardOpenRefresh config repository,
      openRefreshExpired = pure (boardRefreshTimedOut config),
      runHistoryPage = \_ _ -> pure (HistoryPageFetched False)
    }

-- | One foreground refresh, bounded by whatever is left of its deadline.
--
-- It fetches and nothing else. Writing the snapshot to the last-good cache is
-- part of publishing the outcome, not of producing it — see
-- 'persistBoardRefresh'.
runBoardOpenRefresh :: ResolvedConfig -> Repository -> GhFetchGuard -> RateObserver -> Maybe Int -> IO (OpenRefreshResult BoardRefreshOutcome)
runBoardOpenRefresh config repository guard observeRate remainingMicros = do
  timedResult <- withDeadline remainingMicros (fetchGitHubSnapshot guard observeRate config.resolvedLimits config.resolvedWorkflow repository)
  -- Read after the fetch has fully unwound, so the abandoned group's
  -- verified cleanup has already run to completion: whatever it recorded is
  -- final by now, and nothing is published before it is known.
  cleanupFailure <- ghFetchCleanupFailure guard
  let outcome = case (cleanupFailure, timedResult) of
        (Just failure, _) -> BoardRefreshUnverified failure
        (Nothing, Nothing) -> boardRefreshTimedOut config
        (Nothing, Just (Left providerError)) -> BoardRefreshCompleted (Left providerError)
        (Nothing, Just (Right githubResult)) -> BoardRefreshCompleted (Right githubResult)
  pure (OpenRefreshResult outcome (rateLimitedOutcome outcome))

-- | Commits a completed refresh's snapshot to the last-good cache, folding any
-- warning into the outcome that reports it.
--
-- This belongs to publishing rather than to the fetch, and deliberately so. A
-- job the coordinator cancelled must leave behind no board result /and no
-- cache result/, and the cancellation is only known at the publish step a
-- cancelled job never reaches. Writing from inside the fetch would commit a
-- cache in the instant before the cancellation that suppressed everything else
-- about that job — the one result nothing downstream would ever mention, and
-- the one a later launch would load as its own.
persistBoardRefresh :: Options -> ResolvedConfig -> Repository -> BoardRefreshOutcome -> IO BoardRefreshOutcome
persistBoardRefresh options config repository outcome = case outcome of
  BoardRefreshCompleted (Right githubResult)
    | cacheEnabled options config -> do
        cacheResult <- writeRepositoryCache repository githubResult.githubSnapshot
        pure . BoardRefreshCompleted . Right $ case cacheResult of
          Left warning -> githubResult {githubWarnings = githubResult.githubWarnings <> [warning]}
          Right () -> githubResult
  _ -> pure outcome

-- | Whether GitHub refused this refresh against its primary rate limit, which
-- is what makes the next one wait rather than walk into the same refusal.
rateLimitedOutcome :: BoardRefreshOutcome -> Bool
rateLimitedOutcome (BoardRefreshCompleted (Left providerError)) = providerError.providerErrorKind == RateLimited
rateLimitedOutcome _ = False

boardRefreshTimedOut :: ResolvedConfig -> BoardRefreshOutcome
boardRefreshTimedOut config =
  BoardRefreshCompleted
    ( Left
        ( ProviderError
            RequestTimedOut
            ("GitHub refresh timed out after " <> Text.pack (show config.resolvedTimeouts.timeoutsGithubSeconds) <> " seconds")
        )
    )

-- | Runs the fetch under a deadline, or without one when the caller set none.
withDeadline :: Maybe Int -> IO result -> IO (Maybe result)
withDeadline Nothing action = Just <$> action
withDeadline (Just micros) action = timeout micros action

-- | What the board says while background history is yielding the budget
-- foreground work is held back for.
historyPausedNotice :: TimeZone -> UTCTime -> Text
historyPausedNotice timeZone resetAt =
  "History paused · GitHub limit resets " <> absoluteTime timeZone resetAt

-- | One board refresh run on its own, outside the coordinator, with the
-- publish step injected.
--
-- This is the seam the cleanup suite drives: it observes the process table at
-- exactly the instant the outcome is published and proves the abandoned @gh@
-- group is already gone by then, which no assertion made after reading a
-- 'BChan' could establish. It runs the same open job the coordinator
-- schedules, so what it proves about cleanup holds for the scheduled one too.
runBoardRefreshWith :: (BoardRefreshOutcome -> IO ()) -> Options -> ResolvedConfig -> Repository -> IO ()
runBoardRefreshWith publish options config repository = do
  recordLock <- newGhRecordLock
  guard <- newGhFetchGuard recordLock
  result <- runBoardOpenRefresh config repository guard (const (pure ())) (Just (githubRefreshTimeoutMicros config))
  persistBoardRefresh options config repository result.openRefreshOutcome >>= publish

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
        $ runCodexRefresh (codexRefreshTimeoutMicros state.appConfig) state.appConfig.resolvedUsage.usageCodexCommand state.appEventChannel

-- | With a configured command, it *is* the provider (§14): the built-in
-- integration is never invoked.
runCodexRefresh :: Int -> Maybe UsageCommandConfig -> BChan AppEvent -> IO ()
runCodexRefresh timeoutMicros command eventChannel =
  runUsageProvider timeoutMicros command fetchCodexUsage >>= writeBChan eventChannel . CodexRefreshFinished

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
        $ runClaudeRefresh (claudeRefreshTimeoutMicros state.appConfig) state.appConfig.resolvedUsage.usageClaudeCommand state.appEventChannel

runClaudeRefresh :: Int -> Maybe UsageCommandConfig -> BChan AppEvent -> IO ()
runClaudeRefresh timeoutMicros command eventChannel =
  runUsageProvider timeoutMicros command fetchClaudeUsage >>= writeBChan eventChannel . ClaudeRefreshFinished

-- | Routes a usage refresh to the configured external command when one is
-- set, or to the built-in provider otherwise (§14: "the external command is
-- the provider").
runUsageProvider :: Int -> Maybe UsageCommandConfig -> (Int -> IO (Either ProviderError UsageSnapshot)) -> IO (Either ProviderError UsageSnapshot)
runUsageProvider timeoutMicros Nothing builtIn = builtIn timeoutMicros
runUsageProvider timeoutMicros (Just command) _ = runUsageCommand timeoutMicros command.usageCommandArgv
