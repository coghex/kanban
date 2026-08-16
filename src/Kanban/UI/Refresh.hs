module Kanban.UI.Refresh
  ( BoardRefreshDispatch (..),
    boardRefreshDispatch,
    boardRefreshRunner,
    historyPausedNotice,
    markBoardRefreshRunning,
    newBoardRefreshCoordinator,
    releaseQueuedBoardRefresh,
    requireBoardRefresh,
    runBoardRefreshWith,
    runClaudeRefresh,
    runCodexRefresh,
    startAllRefreshes,
    startBoardRefresh,
    startCompletedHistory,
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
import Data.Time (TimeZone, UTCTime)
import Kanban.Claude (fetchClaudeUsage)
import Kanban.Codex (fetchCodexUsage)
import Kanban.Config (ResolvedConfig (..), TimeoutsConfig (..), UsageCommandConfig (..), UsageConfig (..))
import Kanban.Domain
import Kanban.GitHub
  ( CoordinatorNotice (..),
    GhFetchGuard,
    HistoryTraversal,
    OpenRefreshResult (..),
    RateObserver,
    RefreshCoordinator,
    RefreshJob (..),
    RefreshRunner (..),
    beginCompletedGeneration,
    coordinatorOpenCycleInFlight,
    fetchGitHubSnapshot,
    ghFetchCleanupFailure,
    newGhFetchGuard,
    newGhRecordLock,
    newRefreshCoordinator,
    requestRefreshJob,
    runCompletedHistoryPage
    )
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.Usage (claudeRefreshTimeoutMicros, codexRefreshTimeoutMicros, runUsageProvider)
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
      -- No whole-request deadline. `github_seconds` bounds one page now
      -- (§13), and an uncapped traversal of a large repository legitimately
      -- takes many pages: bounding the whole of it by a single page's budget
      -- would fail exactly the repositories this slice exists to serve.
      -- Waiting for the owner and waiting out a rate limit are likewise not
      -- the fetch being slow, and neither may spend a page's budget — a
      -- refusal is published when it happens and the job is reissued once the
      -- reported reset passes (§15).
      liftIO (requestRefreshJob state.appRefreshCoordinator OpenJob Nothing)
      -- Queued after the open job rather than before it. The coordinator
      -- answers a pending open job first whatever the order they arrived in,
      -- so this only decides which one an /idle/ coordinator picks up in the
      -- instant between the two calls -- and the press is waiting for the open
      -- board, not for a page of history it will never see (§15).
      startCompletedHistory

-- | Claims the next completed identity and asks for the traversal that
-- answers under it.
--
-- Every launch and every @u@ starts the whole history again rather than
-- fetching what has newly completed, which is what makes an edit to a
-- long-closed item visible at all: nothing about a title, label, or check
-- changing moves an item into a "recently completed" window.
--
-- The identity is claimed before the job is queued, so from this instant a
-- page still in flight for the previous generation is answering for a history
-- nobody wants: it cannot publish, and it cannot contribute to the generation
-- that replaced it. Presses arriving during one page claim an identity each
-- and leave a single restart, since only the newest is ever compared against.
startCompletedHistory :: EventM Name AppState ()
startCompletedHistory = do
  state <- get
  generation <- liftIO (beginCompletedGeneration state.appHistoryTraversal)
  modify
    ( \current ->
        current
          { appCompletedGeneration = generation,
            appCompletedProgress = emptyCompletedProgress,
            -- The previous generation's failure described a generation that no
            -- longer exists. The history it failed to replace stays exactly
            -- where it is, and the status is this generation's from here on.
            appCompletedStatus = CompletedHistoryLoading
          }
    )
  liftIO (requestRefreshJob state.appRefreshCoordinator HistoryJob Nothing)

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
--
-- The generation it carries is recorded as the newest one, which is what
-- makes a late outcome from the cycle this one superseded droppable.
markBoardRefreshRunning :: OpenGeneration -> EventM Name AppState ()
markBoardRefreshRunning generation =
  modify
    ( \state ->
        state
          { appBoardFreshness = Loading,
            appOpenGeneration = max state.appOpenGeneration generation
          }
    )

-- | The repository's one coordinator, wired to the board: outcomes reach the
-- event channel exactly as a lone refresh thread's did, and what the
-- scheduler has to say for itself reaches the same notice line.
newBoardRefreshCoordinator :: ResolvedConfig -> Repository -> HistoryTraversal -> BChan AppEvent -> IO (RefreshCoordinator BoardRefreshOutcome)
newBoardRefreshCoordinator config repository traversal eventChannel = do
  recordLock <- newGhRecordLock
  newRefreshCoordinator
    recordLock
    (boardRefreshRunner config repository traversal eventChannel)
    (\generation outcome -> writeBChan eventChannel (BoardRefreshFinished generation outcome))
    ( \notice -> case notice of
        HistoryPausedUntilReset resetAt -> writeBChan eventChannel (BoardHistoryPaused resetAt)
        OpenRefreshStarted generation -> writeBChan eventChannel (BoardRefreshStarted generation)
    )

-- | What the coordinator's two job kinds do for the board.
--
-- The two are deliberately asymmetric. A foreground job is one whole open
-- generation and the coordinator publishes its outcome; a history job is one
-- page of a traversal that spans many of them, so it reports through the event
-- channel itself and hands the coordinator nothing but "is there more". That
-- asymmetry is the page-boundary yield: everything a completed generation
-- accumulates lives in the traversal below rather than in a call the
-- coordinator is waiting on.
boardRefreshRunner :: ResolvedConfig -> Repository -> HistoryTraversal -> BChan AppEvent -> RefreshRunner BoardRefreshOutcome
boardRefreshRunner config repository traversal eventChannel =
  RefreshRunner
    { runOpenRefresh = runBoardOpenRefresh config repository,
      openRefreshExpired = boardRefreshUnanswered config,
      runHistoryPage =
        runCompletedHistoryPage
          (\generation outcome -> writeBChan eventChannel (BoardHistoryUpdated generation outcome))
          config.resolvedTimeouts.timeoutsGithubSeconds
          repository
          traversal
    }

-- | What a request earns when its own job produced no outcome.
--
-- An unverified cleanup outranks the timeout. A job that ran out of time over
-- a @gh@ nobody could confirm stopped is not an ordinary timeout, and the
-- board has to hold off refreshing rather than age into a failure that lets
-- the next fetch through beside a process that may still be running.
boardRefreshUnanswered :: ResolvedConfig -> Maybe GhFetchGuard -> IO BoardRefreshOutcome
boardRefreshUnanswered config guard = do
  cleanupFailure <- maybe (pure Nothing) ghFetchCleanupFailure guard
  pure (maybe (boardRefreshTimedOut config) BoardRefreshUnverified cleanupFailure)

-- | One foreground refresh: both open connections followed to their end, with
-- each page bounded by the configured GitHub timeout.
--
-- It fetches and nothing else. Nothing is persisted afterwards either — open
-- cards live only in this process's memory, so a generation that completes
-- leaves no file behind and a generation that is cancelled has nothing to
-- leave (§13).
runBoardOpenRefresh :: ResolvedConfig -> Repository -> GhFetchGuard -> RateObserver -> Maybe Int -> IO (OpenRefreshResult BoardRefreshOutcome)
runBoardOpenRefresh config repository guard observeRate remainingMicros = do
  timedResult <-
    withDeadline
      remainingMicros
      (fetchGitHubSnapshot guard observeRate config.resolvedTimeouts.timeoutsGithubSeconds config.resolvedWorkflow repository)
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
-- schedules, and with the same absence of a whole-request deadline, so what
-- it proves about per-page bounds and cleanup holds for the scheduled one too.
runBoardRefreshWith :: (BoardRefreshOutcome -> IO ()) -> ResolvedConfig -> Repository -> IO ()
runBoardRefreshWith publish config repository = do
  recordLock <- newGhRecordLock
  guard <- newGhFetchGuard recordLock
  result <- runBoardOpenRefresh config repository guard (const (pure ())) Nothing
  publish result.openRefreshOutcome

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

