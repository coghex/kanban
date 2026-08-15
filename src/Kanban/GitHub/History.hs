-- | The background traversal of completed history: the accumulator that
-- survives between coordinator jobs, the generation identity that decides
-- which accumulator is still wanted, and the one page the coordinator asks for
-- at a time.
--
-- The coordinator schedules a history job as a single page and takes the owner
-- back at every boundary (§15), so the traversal itself cannot live inside one
-- call the way the open generation's does. What lives here is exactly the part
-- that has to outlive a job: where each connection got to, what has been
-- collected so far, and which generation that collection belongs to. The
-- fetching is 'Kanban.GitHub.Fetch'\'s, unchanged, and the scheduling is
-- 'Kanban.GitHub.Coordinator'\'s, unchanged.
module Kanban.GitHub.History
  ( CompletedGeneration,
    HistoryOutcome (..),
    HistoryTraversal,
    beginCompletedGeneration,
    newHistoryTraversal,
    runCompletedHistoryPage,
  )
where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Time (getCurrentTime)
import Kanban.Domain (CompletedHistory (..), CompletedProgress, Repository)
import Kanban.GitHub.Coordinator (HistoryPageResult (..))
import Kanban.GitHub.Fetch
  ( HistoryFetchState (..),
    RateObserver,
    fetchHistoryPage,
    historyFetchProgress,
    historyTraversalComplete,
    initialHistoryFetchState,
  )
import Kanban.GitHub.Guard (GhFetchGuard)
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))

-- | Which completed cycle an outcome belongs to.
--
-- It counts /requests/ rather than starts, unlike the open generation's
-- identity. A completed generation is answered by many jobs over many minutes
-- and only the last of them publishes, so what an outcome has to be checked
-- against is the newest history the user asked for — which is claimed the
-- moment they ask, before anything is queued.
type CompletedGeneration = Int

-- | What one completed page had to say for its generation.
data HistoryOutcome
  = -- | Another page landed and the traversal continues. Carries the
    -- loaded\/total counts for both kinds, which is the only thing about a
    -- generation in flight that is ever true — a partial page set is never
    -- history.
    HistoryProgressed CompletedProgress
  | -- | Both connections reached their final page, so this generation is
    -- whole and may be published and cached.
    HistoryCompleted CompletedHistory
  | -- | The generation ended without completing. The last complete history,
    -- in memory or on disk, is untouched by this (§15).
    HistoryFailed ProviderError
  deriving stock (Eq, Show)

-- | The repository's one completed traversal.
--
-- Two references rather than one: what the user has asked for, and what has
-- actually been collected. Keeping them apart is what makes supersession a
-- comparison instead of a protocol — a request bumps the first from the
-- dashboard thread while a page is in flight, and the job thread notices at the
-- boundary it was always going to stop at.
data HistoryTraversal = HistoryTraversal
  { traversalRequested :: IORef CompletedGeneration,
    traversalRun :: IORef (Maybe HistoryRun)
  }

data HistoryRun = HistoryRun
  { runGeneration :: CompletedGeneration,
    runState :: HistoryFetchState
  }

newHistoryTraversal :: IO HistoryTraversal
newHistoryTraversal = HistoryTraversal <$> newIORef 0 <*> newIORef Nothing

-- | Claims the next completed identity, which every launch and every @u@ does
-- before queueing a history job.
--
-- Claiming before queueing is what makes the restart total: from this instant
-- the page in flight is answering for a generation nobody wants, so it can
-- neither publish nor contribute to the one that replaced it. Two requests
-- arriving during one page claim two identities and leave one restart, because
-- only the newest is ever compared against.
beginCompletedGeneration :: HistoryTraversal -> IO CompletedGeneration
beginCompletedGeneration traversal =
  atomicModifyIORef' traversal.traversalRequested (\generation -> (generation + 1, generation + 1))

-- | Fetches one page of the newest requested generation and reports what it
-- meant, in the shape the coordinator schedules by.
--
-- The generation is read before the page and again after it. A page whose
-- generation was superseded while it was in flight is discarded whole — it
-- publishes nothing, records nothing, and reports more work so the newest
-- generation starts from its own first page — which is requirement 4's
-- \"a completion belonging to a superseded generation\" closed at the source
-- rather than only at the board.
runCompletedHistoryPage ::
  -- | How an outcome reaches the board, under the generation it answers for.
  (CompletedGeneration -> HistoryOutcome -> IO ()) ->
  -- | The configured GitHub timeout, which bounds this page exactly as it
  -- bounds an open one (§13).
  Int ->
  Repository ->
  HistoryTraversal ->
  GhFetchGuard ->
  RateObserver ->
  IO HistoryPageResult
runCompletedHistoryPage report pageSeconds repository traversal guard observeRate = do
  requested <- readIORef traversal.traversalRequested
  existing <- readIORef traversal.traversalRun
  let state = case existing of
        Just run | run.runGeneration == requested -> run.runState
        -- Either nothing has been collected, or what has belongs to a
        -- generation a later request superseded. Both start over, which is
        -- requirement 7's whole-history re-traversal: there is no
        -- "since last time" cursor to resume from, so an edit to an item
        -- closed years ago is picked up by the same pass as a fresh one.
        _ -> initialHistoryFetchState
  result <- fetchHistoryPage guard observeRate pageSeconds repository state
  current <- readIORef traversal.traversalRequested
  if current /= requested
    then do
      writeIORef traversal.traversalRun Nothing
      pure (HistoryPageFetched True)
    else case result of
      Left providerError
        -- A refusal against the primary rate limit is the one failure the
        -- coordinator waits out and reissues, so the accumulator stays and the
        -- traversal resumes at the page the refusal interrupted. Nothing is
        -- reported: the generation has not ended, and the board already learns
        -- about the limit from the foreground refresh that shares the budget.
        | providerError.providerErrorKind == RateLimited -> do
            writeIORef traversal.traversalRun (Just (HistoryRun requested state))
            pure (HistoryPageFailed True)
        | otherwise -> do
            writeIORef traversal.traversalRun Nothing
            report requested (HistoryFailed providerError)
            pure (HistoryPageFailed False)
      Right next
        | historyTraversalComplete next -> do
            writeIORef traversal.traversalRun Nothing
            fetchedAt <- getCurrentTime
            report
              requested
              ( HistoryCompleted
                  CompletedHistory
                    { historyIssues = next.historyFetchedIssues,
                      historyPullRequests = next.historyFetchedPullRequests,
                      historyFetchedAt = fetchedAt
                    }
              )
            pure (HistoryPageFetched False)
        | otherwise -> do
            writeIORef traversal.traversalRun (Just (HistoryRun requested next))
            report requested (HistoryProgressed (historyFetchProgress next))
            pure (HistoryPageFetched True)
