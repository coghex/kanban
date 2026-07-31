module Kanban.UI.Refresh
  ( BoardRefreshDispatch (..),
    claudeRefreshTimeoutMicros,
    codexRefreshTimeoutMicros,
    githubRefreshTimeoutMicros,
    releaseQueuedBoardRefresh,
    requireBoardRefresh,
    requiredBoardRefreshDispatch,
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
import Kanban.Cache
  ( writeRepositoryCache
    )
import Kanban.CLI (Options (..))
import Kanban.Claude (fetchClaudeUsage)
import Kanban.Codex (fetchCodexUsage)
import Kanban.Config (ResolvedConfig (..), TimeoutsConfig (..), UsageCommandConfig (..), UsageConfig (..))
import Kanban.Domain
import Kanban.GitHub (GitHubResult (..), fetchGitHubSnapshot, ghFetchCleanupFailure, newGhFetchGuard )
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

-- | Whether a refresh that must observe an already-committed change can start
-- now. A fetch already in flight does not satisfy one: it may have read
-- GitHub before the change landed, so believing it would leave the board
-- permanently behind a merge that really happened.
data BoardRefreshDispatch = StartRefreshNow | QueueRefreshUntilIdle
  deriving stock (Eq, Show)

requiredBoardRefreshDispatch :: Freshness -> BoardRefreshDispatch
requiredBoardRefreshDispatch Loading = QueueRefreshUntilIdle
requiredBoardRefreshDispatch _ = StartRefreshNow

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
  case requiredBoardRefreshDispatch state.appBoardFreshness of
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

startBoardRefresh :: EventM Name AppState ()
startBoardRefresh = do
  state <- get
  case state.appBoardFreshness of
    Loading -> announceOverDirectMergeResult "GitHub refresh is already running"
    _ -> do
      announceOverDirectMergeResult "Refreshing GitHub…"
      modify (\current -> current {appBoardFreshness = Loading})
      void
        . liftIO
        . forkIO
        $ runBoardRefresh state.appOptions state.appConfig state.appRepository state.appEventChannel

-- | The configured GitHub/Codex/Claude provider timeouts, converted from
-- whole seconds to the microseconds 'System.Timeout.timeout' takes.
githubRefreshTimeoutMicros, codexRefreshTimeoutMicros, claudeRefreshTimeoutMicros :: ResolvedConfig -> Int
githubRefreshTimeoutMicros config = config.resolvedTimeouts.timeoutsGithubSeconds * 1000000
codexRefreshTimeoutMicros config = config.resolvedTimeouts.timeoutsCodexSeconds * 1000000
claudeRefreshTimeoutMicros config = config.resolvedTimeouts.timeoutsClaudeSeconds * 1000000

runBoardRefresh :: Options -> ResolvedConfig -> Repository -> BChan AppEvent -> IO ()
runBoardRefresh options config repository eventChannel =
  runBoardRefreshWith (writeBChan eventChannel . BoardRefreshFinished) options config repository

-- | 'runBoardRefresh' with the publish step injected, so the suite can
-- observe the process table at exactly the instant the outcome is published
-- and prove the abandoned @gh@ group is already gone by then — something no
-- assertion made after reading a 'BChan' could establish.
runBoardRefreshWith :: (BoardRefreshOutcome -> IO ()) -> Options -> ResolvedConfig -> Repository -> IO ()
runBoardRefreshWith publish options config repository = do
  let timeoutMicros = githubRefreshTimeoutMicros config
  guard <- newGhFetchGuard
  timedResult <- timeout timeoutMicros (fetchGitHubSnapshot guard config.resolvedLimits config.resolvedWorkflow repository)
  -- Read after the fetch has fully unwound, so the abandoned group's
  -- verified cleanup has already run to completion: whatever it recorded is
  -- final by now, and nothing is published before it is known.
  cleanupFailure <- ghFetchCleanupFailure guard
  outcome <- case (cleanupFailure, timedResult) of
    (Just failure, _) -> pure (BoardRefreshUnverified failure)
    (Nothing, Nothing) -> pure (BoardRefreshCompleted (Left (ProviderError RequestTimedOut ("GitHub refresh timed out after " <> Text.pack (show config.resolvedTimeouts.timeoutsGithubSeconds) <> " seconds"))))
    (Nothing, Just (Left providerError)) -> pure (BoardRefreshCompleted (Left providerError))
    (Nothing, Just (Right githubResult))
      | not (cacheEnabled options config) -> pure (BoardRefreshCompleted (Right githubResult))
      | otherwise -> do
          cacheResult <- writeRepositoryCache repository githubResult.githubSnapshot
          pure . BoardRefreshCompleted . Right $ case cacheResult of
            Left warning -> githubResult {githubWarnings = githubResult.githubWarnings <> [warning]}
            Right () -> githubResult
  publish outcome

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
