-- | The repository's refresh coordinator: what it decides, and what it does.
--
-- The scheduling itself is a pure function of the clock and the state, so most
-- of what is asserted below needs no process, no socket, and no timer — which
-- is the point of having lifted it out of the loop. The groups after those
-- drive the real loop, and the last group drives a real @gh@ through it, so
-- ownership and cleanup are established against the thing itself rather than
-- against a model of it.
module Spec.GitHub.RefreshCoordinator (spec) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Monad (unless, void)
import qualified Data.ByteString.Char8 as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime, getCurrentTime, utc)
import Kanban.Cache (ghGroupRecordPath)
import Kanban.Config
import Kanban.Domain
import Kanban.GitHub
  ( CoordinatorNotice (..),
    GhCleanupFailure (..),
    GhCleanupGuard (..),
    GhFetchGuard,
    CoordinatorPlan (..),
    CoordinatorState (..),
    HistoryPageResult (..),
    HistoryRateVerdict (..),
    HoldReason (..),
    JobHold (..),
    OpenRefreshResult (..),
    PendingJob (..),
    RateSample (..),
    RefreshCoordinator,
    RefreshJob (..),
    RefreshRunner (..),
    beginCoordinatorShutdown,
    classifyFailure,
    coordinatorMustSettle,
    finishCoordinatorJob,
    foregroundRateReserve,
    historyRateVerdict,
    holdCoordinatorJob,
    initialCoordinatorState,
    newGhFetchGuard,
    newGhRecordLock,
    newRefreshCoordinator,
    observeRateSample,
    planCoordinator,
    queueCoordinatorJob,
    rateLimitFallbackHold,
    rateLimitHoldUntil,
    rateSampleFromResponse,
    requestRefreshJob,
    setCleanupFailure,
    settleHistoryJob,
    settleOpenJob,
    shutdownRefreshCoordinator,
    usableRateSample
  )
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.Process (identityForPid, readProcessSnapshot)
import Kanban.UI.Events (QuitDecision (..), quitDecision, stoppingGitHubWorkNotice)
import Kanban.UI.Refresh
  ( BoardRefreshDispatch (..),
    boardRefreshDispatch,
    boardRefreshRunner,
    historyPausedNotice,
    releaseQueuedBoardRefresh
  )
import Kanban.UI.Types (BoardRefreshOutcome (..))
import Spec.Support.Board (readMarkerPid, withFakeGh)
import Spec.Support.Env (withTemporaryCacheRoot)
import Spec.Support.Expect (shouldMention)
import Spec.Support.Fixtures (epoch, testOptions, testResolvedConfig)
import Spec.Support.Json (emptyGraphqlPage, graphqlPageWithRateLimit, rateLimitedGraphqlResponse)
import System.Directory (doesFileExist)
import Test.Hspec

spec :: Spec
spec = do
  describe "refresh coordinator scheduling" $ do
    it "runs a pending open job before a pending history job" $ do
      let queued =
            queueCoordinatorJob HistoryJob Nothing
              . queueCoordinatorJob OpenJob (Just (secondsAfterEpoch 30))
              $ initialCoordinatorState
      snd (planCoordinator epoch queued) `shouldBe` PlanRun OpenJob (Just (secondsAfterEpoch 30))

    -- Requirement 2's "never starts or resumes while an open job is pending or
    -- running" covers a pending open job that cannot run yet, which is the
    -- case a priority check written against "running" alone would miss.
    it "keeps history waiting while an open job is only pending, even one that is itself held" $ do
      let queued =
            holdCoordinatorJob OpenJob (JobHold HeldForRateLimit (secondsAfterEpoch 90))
              . queueCoordinatorJob HistoryJob Nothing
              . queueCoordinatorJob OpenJob (Just (secondsAfterEpoch 300))
              $ initialCoordinatorState
      snd (planCoordinator epoch queued) `shouldBe` PlanWait (Just (secondsAfterEpoch 90))

    it "leaves nothing runnable while a job holds the owner" $ do
      let running =
            queueCoordinatorJob OpenJob (Just (secondsAfterEpoch 30))
              . fst
              . planCoordinator epoch
              . queueCoordinatorJob HistoryJob Nothing
              $ initialCoordinatorState
      running.coordinatorRunning `shouldBe` Just HistoryJob
      snd (planCoordinator epoch running) `shouldBe` PlanWait Nothing

    it "coalesces repeated requests for one kind onto a single newest follow-up" $ do
      let queued =
            queueCoordinatorJob OpenJob (Just (secondsAfterEpoch 90))
              . queueCoordinatorJob OpenJob (Just (secondsAfterEpoch 60))
              . queueCoordinatorJob OpenJob (Just (secondsAfterEpoch 30))
              $ initialCoordinatorState
      Map.keys queued.coordinatorPending `shouldBe` [OpenJob]
      snd (planCoordinator epoch queued) `shouldBe` PlanRun OpenJob (Just (secondsAfterEpoch 90))

    -- The page boundary is the whole of history's yield: it gives the owner
    -- back with more work still to do, and whatever was requested meanwhile
    -- is chosen ahead of it on the very next decision.
    it "hands a newly requested open job the owner at a history page boundary" $ do
      let running = fst (planCoordinator epoch (queueCoordinatorJob HistoryJob Nothing initialCoordinatorState))
          interrupted = queueCoordinatorJob OpenJob (Just (secondsAfterEpoch 30)) running
          yielded = finishCoordinatorJob HistoryJob True interrupted
      yielded.coordinatorRunning `shouldBe` Nothing
      Map.keys yielded.coordinatorPending `shouldBe` [OpenJob, HistoryJob]
      snd (planCoordinator epoch yielded) `shouldBe` PlanRun OpenJob (Just (secondsAfterEpoch 30))

    it "expires a pending open job whose deadline passed before it could start" $ do
      let queued = queueCoordinatorJob OpenJob (Just (secondsAfterEpoch 30)) initialCoordinatorState
          (expired, plan) = planCoordinator (secondsAfterEpoch 31) queued
      plan `shouldBe` PlanExpire OpenJob
      expired.coordinatorPending `shouldBe` Map.empty

    -- The deadline has to be able to end the wait as well as the hold, or a
    -- request would sit behind a reset an hour away with nothing to stop it.
    it "waits only until the earlier of a rate-limit hold and the deadline" $ do
      let queued =
            holdCoordinatorJob OpenJob (JobHold HeldForRateLimit (secondsAfterEpoch 900))
              . queueCoordinatorJob OpenJob (Just (secondsAfterEpoch 30))
              $ initialCoordinatorState
      snd (planCoordinator epoch queued) `shouldBe` PlanWait (Just (secondsAfterEpoch 30))

  describe "the foreground rate reserve" $ do
    it "runs history while the remaining budget is above the reserve" $
      historyRateVerdict (Just (sampleWith (foregroundRateReserve + 1))) `shouldBe` HistoryMayRun

    -- The reserve is the balance that must survive, so spending down /to/ it
    -- is already spending it.
    it "pauses history when the remaining budget is exactly the reserve" $
      historyRateVerdict (Just (sampleWith foregroundRateReserve))
        `shouldBe` HistoryPausedUntil (secondsAfterEpoch 3600)

    it "pauses history when the remaining budget is below the reserve" $
      historyRateVerdict (Just (sampleWith (foregroundRateReserve - 1)))
        `shouldBe` HistoryPausedUntil (secondsAfterEpoch 3600)

    it "runs history while the budget is unknown" $
      historyRateVerdict Nothing `shouldBe` HistoryMayRun

    it "reports the pause with GitHub's own reset time and holds the job on it" $ do
      let queued =
            queueCoordinatorJob HistoryJob Nothing
              (observeRateSample (Just (sampleWith 10)) initialCoordinatorState)
          (paused, plan) = planCoordinator epoch queued
      plan `shouldBe` PlanPauseHistory (secondsAfterEpoch 3600)
      Map.lookup HistoryJob paused.coordinatorHolds
        `shouldBe` Just (JobHold HeldForReserve (secondsAfterEpoch 3600))
      historyPausedNotice utc (secondsAfterEpoch 3600)
        `shouldBe` "History paused · GitHub limit resets 2026-01-01 01:00 UTC"

    -- A paused history job cannot produce the page that would clear it, so the
    -- foreground's own page is the only evidence that can arrive in time.
    it "resumes a paused history job once a later page reports a healthy budget" $ do
      let paused = pausedHistoryState
          woken = observeRateSample (Just (sampleWith (foregroundRateReserve + 1))) paused
      Map.lookup HistoryJob woken.coordinatorHolds `shouldBe` Nothing
      snd (planCoordinator epoch woken) `shouldBe` PlanRun HistoryJob Nothing

    it "resumes a paused history job once the reported reset has passed" $
      snd (planCoordinator (secondsAfterEpoch 3601) pausedHistoryState)
        `shouldBe` PlanRun HistoryJob Nothing

    -- The stale sample still says the budget is spent, but it is describing a
    -- window that has already turned over; only asking can say what is left.
    it "runs rather than pausing on a sample whose reset is already behind us" $ do
      let queued =
            queueCoordinatorJob HistoryJob Nothing
              (observeRateSample (Just (sampleWith 0)) initialCoordinatorState)
      snd (planCoordinator (secondsAfterEpoch 7200) queued) `shouldBe` PlanRun HistoryJob Nothing

  describe "primary rate-limit scheduling" $ do
    it "waits for the reported reset before a refused job may run again" $ do
      let observed = observeRateSample (Just (sampleWith 0)) initialCoordinatorState
      rateLimitHoldUntil epoch observed `shouldBe` secondsAfterEpoch 3600

    it "still waits a bounded while when nothing reported a reset" $
      rateLimitHoldUntil epoch initialCoordinatorState
        `shouldBe` addUTCTime rateLimitFallbackHold epoch

    it "still waits a bounded while when the only reported reset is already behind us" $ do
      let observed = observeRateSample (Just (sampleWith 0)) initialCoordinatorState
      rateLimitHoldUntil (secondsAfterEpoch 7200) observed
        `shouldBe` addUTCTime rateLimitFallbackHold (secondsAfterEpoch 7200)

    -- GitHub refused the request outright, so a page that happens to report a
    -- healthy budget is not a reason to walk back into the same refusal.
    it "does not let a healthy later page cut a rate-limit hold short" $ do
      let held =
            holdCoordinatorJob HistoryJob (JobHold HeldForRateLimit (secondsAfterEpoch 3600))
              (queueCoordinatorJob HistoryJob Nothing initialCoordinatorState)
          observed = observeRateSample (Just (sampleWith (foregroundRateReserve + 1))) held
      Map.lookup HistoryJob observed.coordinatorHolds
        `shouldBe` Just (JobHold HeldForRateLimit (secondsAfterEpoch 3600))
      snd (planCoordinator epoch observed) `shouldBe` PlanWait (Just (secondsAfterEpoch 3600))

  describe "a job that GitHub refused" $ do
    -- A hold on its own only delays; without the requeue the job is simply
    -- gone once the hold lapses, and the refresh nobody answered never
    -- happens.
    it "puts the refused open job back in the queue under a hold, keeping its deadline" $ do
      -- A deadline past the reported reset, so the reissue is the thing under
      -- test rather than the expiry the next case covers.
      let running = fst (planCoordinator epoch (queueCoordinatorJob OpenJob (Just (secondsAfterEpoch 7200)) initialCoordinatorState))
          observed = observeRateSample (Just (sampleWith 0)) running
          settled = settleOpenJob epoch (Just (secondsAfterEpoch 7200)) True observed
      settled.coordinatorRunning `shouldBe` Nothing
      Map.lookup OpenJob settled.coordinatorPending `shouldBe` Just (PendingJob (Just (secondsAfterEpoch 7200)))
      Map.lookup OpenJob settled.coordinatorHolds
        `shouldBe` Just (JobHold HeldForRateLimit (secondsAfterEpoch 3600))
      -- Held until the reset, then reissued rather than dropped.
      snd (planCoordinator (secondsAfterEpoch 60) settled)
        `shouldBe` PlanWait (Just (secondsAfterEpoch 3600))
      snd (planCoordinator (secondsAfterEpoch 3601) settled)
        `shouldBe` PlanRun OpenJob (Just (secondsAfterEpoch 7200))

    -- The deadline is what stops the reissue turning into an unbounded wait,
    -- and what makes sure no retry completes after the request gave up.
    it "expires the reissued job instead of retrying when its deadline runs out first" $ do
      let settled = settleOpenJob epoch (Just (secondsAfterEpoch 30)) True (observeRateSample (Just (sampleWith 0)) initialCoordinatorState)
          (expired, plan) = planCoordinator (secondsAfterEpoch 31) settled
      plan `shouldBe` PlanExpire OpenJob
      expired.coordinatorPending `shouldBe` Map.empty
      expired.coordinatorHolds `shouldBe` Map.empty

    it "requeues nothing for an open job that failed for any other reason" $ do
      let settled = settleOpenJob epoch (Just (secondsAfterEpoch 300)) False initialCoordinatorState
      settled.coordinatorPending `shouldBe` Map.empty
      settled.coordinatorHolds `shouldBe` Map.empty

    it "reissues nothing once shutdown has begun" $ do
      let settled = settleOpenJob epoch (Just (secondsAfterEpoch 300)) True (beginCoordinatorShutdown initialCoordinatorState)
      settled.coordinatorPending `shouldBe` Map.empty
      settled.coordinatorHolds `shouldBe` Map.empty

    it "resumes a rate-limited history traversal after the reset rather than hot-looping it" $ do
      let observed = observeRateSample (Just (sampleWith 0)) initialCoordinatorState
          settled = settleHistoryJob epoch (Just (HistoryPageFailed True)) observed
      Map.keys settled.coordinatorPending `shouldBe` [HistoryJob]
      Map.lookup HistoryJob settled.coordinatorHolds
        `shouldBe` Just (JobHold HeldForRateLimit (secondsAfterEpoch 3600))
      snd (planCoordinator (secondsAfterEpoch 3601) settled) `shouldBe` PlanRun HistoryJob Nothing

    it "ends a history traversal that failed for a reason nothing can wait out" $ do
      let settled = settleHistoryJob epoch (Just (HistoryPageFailed False)) initialCoordinatorState
      settled.coordinatorPending `shouldBe` Map.empty

    it "carries a history traversal on to its next page" $ do
      let settled = settleHistoryJob epoch (Just (HistoryPageFetched True)) initialCoordinatorState
      Map.keys settled.coordinatorPending `shouldBe` [HistoryJob]

  describe "coordinator shutdown" $ do
    it "discards queued work and refuses anything requested afterwards" $ do
      let stopping =
            beginCoordinatorShutdown
              . queueCoordinatorJob HistoryJob Nothing
              . queueCoordinatorJob OpenJob (Just (secondsAfterEpoch 30))
              $ initialCoordinatorState
          reasked = queueCoordinatorJob OpenJob (Just (secondsAfterEpoch 60)) stopping
      stopping.coordinatorPending `shouldBe` Map.empty
      reasked.coordinatorPending `shouldBe` Map.empty
      snd (planCoordinator epoch reasked) `shouldBe` PlanStop

  describe "GitHub's rate report" $ do
    it "reads cost, remaining and reset from a page that carries them" $
      rateSampleFromResponse (graphqlPageWithRateLimit "{\"cost\":7,\"remaining\":4321,\"resetAt\":\"2026-01-01T01:00:00Z\"}")
        `shouldBe` Just (RateSample 7 4321 (secondsAfterEpoch 3600))

    it "reads no sample from a page that never reported one" $
      rateSampleFromResponse emptyGraphqlPage `shouldBe` Nothing

    it "reads no sample from a report missing one of its parts" $
      rateSampleFromResponse (graphqlPageWithRateLimit "{\"cost\":7,\"remaining\":4321}") `shouldBe` Nothing

    it "reads no sample from a reset time that is not a time" $
      rateSampleFromResponse (graphqlPageWithRateLimit "{\"cost\":7,\"remaining\":4321,\"resetAt\":\"soon\"}")
        `shouldBe` Nothing

    it "reads no sample from a count that is not a number" $
      rateSampleFromResponse (graphqlPageWithRateLimit "{\"cost\":\"free\",\"remaining\":4321,\"resetAt\":\"2026-01-01T01:00:00Z\"}")
        `shouldBe` Nothing

    it "reads no sample from a null report" $
      rateSampleFromResponse (graphqlPageWithRateLimit "null") `shouldBe` Nothing

    it "reads no sample from a response that is not JSON at all" $
      rateSampleFromResponse "gh: could not resolve host" `shouldBe` Nothing

    it "reads no sample from a response GitHub answered with no data" $
      rateSampleFromResponse rateLimitedGraphqlResponse `shouldBe` Nothing

    -- A budget that cannot be subtracted against is not a budget. Left usable,
    -- a negative remaining would pause background work for good.
    it "rejects an implausible cost or remaining rather than scheduling against it" $ do
      usableRateSample (RateSample (-1) 4321 epoch) `shouldBe` Nothing
      usableRateSample (RateSample 7 (-1) epoch) `shouldBe` Nothing
      usableRateSample (RateSample 0 0 epoch) `shouldBe` Just (RateSample 0 0 epoch)

  describe "primary rate-limit classification" $ do
    it "classifies GitHub's own primary refusal distinctly from a request error" $ do
      classifyFailure "gh: API rate limit exceeded for user ID 4242." `shouldBe` RateLimited
      classifyFailure "GitHub GraphQL response contained no data: RATE_LIMITED" `shouldBe` RateLimited

    -- The secondary limit reports no reset, so there is nothing to schedule
    -- against and it stays the ordinary failure it has always been.
    it "leaves a secondary rate limit an ordinary request failure" $
      classifyFailure "You have exceeded a secondary rate limit and have been temporarily blocked"
        `shouldBe` RequestFailed

    it "leaves unrelated token and limit wording an ordinary request failure" $ do
      classifyFailure "GraphQL: token bucket exhausted, retry after 60s" `shouldBe` RequestFailed
      classifyFailure "gh: OAuth application rate limit reached" `shouldBe` RequestFailed

  describe "the running coordinator" $ do
    it "never lets two jobs hold the owner at once" $ do
      probe <- newProbe
      release <- newEmptyMVar
      coordinator <-
        startProbeCoordinator
          probe
          (\_ _ -> takeMVar release >> pure (OpenRefreshResult "open" False))
          (\_ -> takeMVar release >> pure (HistoryPageFetched False))
      requestRefreshJob coordinator OpenJob Nothing
      requestRefreshJob coordinator HistoryJob Nothing
      -- Both are asked for before either can finish, so the only thing keeping
      -- them apart is the owner.
      void (forkIO (mapM_ (const (putMVar release ())) [1 :: Int, 2]))
      awaitCount probe.probeStarted 2
      readIORef probe.probePeakInFlight `shouldReturn` 1
      readIORef probe.probeStarted `shouldReturn` [HistoryJob, OpenJob]

    it "hands the owner to a newly requested open job at a history page boundary" $ do
      probe <- newProbe
      firstPageStarted <- newEmptyMVar
      coordinator <-
        startProbeCoordinator
          probe
          (\_ _ -> pure (OpenRefreshResult "open" False))
          ( \_ -> do
              pages <- atomicModifyIORef' probe.probeHistoryPages (\count -> (count + 1, count + 1))
              unless (pages > 1) (putMVar firstPageStarted ())
              pure (HistoryPageFetched (pages < 3))
          )
      requestRefreshJob coordinator HistoryJob Nothing
      takeMVar firstPageStarted
      requestRefreshJob coordinator OpenJob Nothing
      awaitCount probe.probeStarted 4
      started <- readIORef probe.probeStarted
      -- The traversal did not have to finish for the open job to run: it took
      -- the owner at the very next boundary, with history pages still to go.
      reverse started `shouldSatisfy` (\order -> take 1 order == [HistoryJob] && OpenJob `elem` drop 1 (take 3 order))
      readIORef probe.probePeakInFlight `shouldReturn` 1

    it "leaves exactly one queued follow-up however many requests arrive during one job" $ do
      probe <- newProbe
      release <- newEmptyMVar
      coordinator <-
        startProbeCoordinator
          probe
          (\_ _ -> takeMVar release >> pure (OpenRefreshResult "open" False))
          (\_ -> pure (HistoryPageFetched False))
      requestRefreshJob coordinator OpenJob Nothing
      awaitCount probe.probeStarted 1
      mapM_ (const (requestRefreshJob coordinator OpenJob Nothing)) [1 :: Int .. 5]
      mapM_ (const (putMVar release ())) [1 :: Int, 2]
      awaitCount probe.probeStarted 2
      -- Five presses during one running cycle, one follow-up. Waiting a moment
      -- longer is what would catch a sixth start; nothing arrives.
      threadDelay 200000
      readIORef probe.probeStarted `shouldReturn` [OpenJob, OpenJob]
      readIORef probe.probePublished `shouldReturn` ["open", "open"]

    -- The reset is taken from the real clock rather than the fixed epoch the
    -- pure cases use: a reset already behind the running loop is a spent
    -- sample, which the scheduler is right to fetch through rather than
    -- pause on.
    it "reports the paused history notice with the reset GitHub gave" $ do
      probe <- newProbe
      resetAt <- addUTCTime 3600 <$> getCurrentTime
      coordinator <-
        startProbeCoordinator
          probe
          (\_ _ -> pure (OpenRefreshResult "open" False))
          (\observe -> observe (Just (RateSample 1 5 resetAt)) >> pure (HistoryPageFetched True))
      requestRefreshJob coordinator HistoryJob Nothing
      awaitCount probe.probeNotices 1
      readIORef probe.probeNotices `shouldReturn` [HistoryPausedUntilReset resetAt]
      -- One page, then the reserve stops it: the traversal did not spin.
      readIORef probe.probeStarted `shouldReturn` [HistoryJob]

    -- The verdict is what decides whether the dashboard may stop, so a quit
    -- issued against a job that settles a moment later has to find that job
    -- rather than an empty slot reading as "nothing was ever running".
    it "answers a quit with the settled job's verdict rather than with silence" $ do
      probe <- newProbe
      coordinator <-
        startProbeCoordinator
          probe
          ( \guard _ -> do
              setCleanupFailure guard (GhCleanupFailure "ps exited 1" GuardRecorded)
              pure (OpenRefreshResult "open" False)
          )
          (\_ -> pure (HistoryPageFetched False))
      requestRefreshJob coordinator OpenJob Nothing
      awaitCount probe.probePublished 1
      shutdownRefreshCoordinator coordinator
        `shouldReturn` Just (GhCleanupFailure "ps exited 1" GuardRecorded)

    -- The whole point of the reissue: the refusal is answered now, and the
    -- job is tried again once GitHub says the budget is back -- not before.
    it "reissues a rate-limited open job no earlier than the reported reset" $ do
      probe <- newProbe
      resetAt <- addUTCTime 0.4 <$> getCurrentTime
      attempts <- newIORef (0 :: Int)
      deadline <- deadlineIn 30
      coordinator <-
        startProbeCoordinator
          probe
          ( \_ observe -> do
              attempt <- atomicModifyIORef' attempts (\seen -> (seen + 1, seen + 1))
              observe (Just (RateSample 1 5000 resetAt))
              pure (OpenRefreshResult (if attempt == 1 then "limited" else "open") (attempt == 1))
          )
          (\_ -> pure (HistoryPageFetched False))
      requestRefreshJob coordinator OpenJob (Just deadline)
      awaitCount probe.probePublished 2
      reissuedAt <- getCurrentTime
      reissuedAt `shouldSatisfy` (>= resetAt)
      readIORef probe.probePublished `shouldReturn` ["limited", "open"]
      readIORef probe.probeStarted `shouldReturn` [OpenJob, OpenJob]

    -- Requirement 7's guarantee is about what is left behind, not about what
    -- is still running: a settled job whose group only this process holds back
    -- has to reach the quit path just as a running one does.
    it "makes a quit settle over a finished job that left a possibly-live gh" $ do
      probe <- newProbe
      coordinator <-
        startProbeCoordinator
          probe
          ( \guard _ -> do
              setCleanupFailure guard (GhCleanupFailure "ps exited 1" GuardInMemoryOnly)
              pure (OpenRefreshResult "open" False)
          )
          (\_ -> pure (HistoryPageFetched False))
      requestRefreshJob coordinator OpenJob Nothing
      awaitCount probe.probePublished 1
      coordinatorMustSettle coordinator `shouldReturn` True
      verdict <- shutdownRefreshCoordinator coordinator
      verdict `shouldBe` Just (GhCleanupFailure "ps exited 1" GuardInMemoryOnly)
      case quitDecision verdict of
        QuitHalts -> expectationFailure "expected the quit to be held back"
        QuitHeldBack notice -> notice `shouldMention` "stray gh"

    it "lets a quit past a finished job that left nothing behind" $ do
      probe <- newProbe
      coordinator <-
        startProbeCoordinator
          probe
          (\_ _ -> pure (OpenRefreshResult "open" False))
          (\_ -> pure (HistoryPageFetched False))
      requestRefreshJob coordinator OpenJob Nothing
      awaitCount probe.probePublished 1
      coordinatorMustSettle coordinator `shouldReturn` False

    it "publishes nothing from a job shutdown cancelled, and starts nothing after" $ do
      probe <- newProbe
      running <- newEmptyMVar
      coordinator <-
        startProbeCoordinator
          probe
          (\_ _ -> putMVar running () >> threadDelay 30000000 >> pure (OpenRefreshResult "open" False))
          (\_ -> pure (HistoryPageFetched False))
      requestRefreshJob coordinator OpenJob Nothing
      takeMVar running
      requestRefreshJob coordinator HistoryJob Nothing
      shutdownRefreshCoordinator coordinator `shouldReturn` Nothing
      requestRefreshJob coordinator OpenJob Nothing
      threadDelay 200000
      readIORef probe.probePublished `shouldReturn` []
      readIORef probe.probeStarted `shouldReturn` [OpenJob]

  describe "an update requested during a running cycle" $ do
    -- Requirement 3 as the board sees it: `u` during a cycle reports the
    -- cycle and leaves one follow-up, and the one flag it leaves it in is
    -- what makes any number of presses collapse onto one.
    it "queues a follow-up rather than starting a second cycle" $ do
      boardRefreshDispatch Loading `shouldBe` QueueRefreshUntilIdle
      boardRefreshDispatch NotLoaded `shouldBe` StartRefreshNow
      boardRefreshDispatch (Fresh epoch) `shouldBe` StartRefreshNow

    it "releases that follow-up once the running cycle has published" $ do
      releaseQueuedBoardRefresh True (Fresh epoch) `shouldBe` True
      releaseQueuedBoardRefresh False (Fresh epoch) `shouldBe` False

    -- An unrecorded unverified cleanup deliberately leaves the board
    -- 'Loading', which is the board's way of saying it cannot accept work.
    -- The request has to survive that rather than be spent on it.
    it "keeps the follow-up queued while the board still cannot accept work" $
      releaseQueuedBoardRefresh True Loading `shouldBe` False

  describe "quitting over a cancelled refresh" $ do
    it "halts once the cleanup proved the group gone" $
      quitDecision Nothing `shouldBe` QuitHalts

    -- A recorded group is re-checked before this dashboard, or any later one,
    -- spawns anything, so stopping leaves nothing unaccounted for.
    it "halts once the cleanup durably recorded what it could not confirm" $
      quitDecision (Just (GhCleanupFailure "ps exited 1" GuardRecorded)) `shouldBe` QuitHalts

    it "refuses to halt over a possibly-live gh nothing durable records" $
      case quitDecision (Just (GhCleanupFailure "ps exited 1" GuardInMemoryOnly)) of
        QuitHalts -> expectationFailure "expected the quit to be held back"
        QuitHeldBack notice -> do
          notice `shouldMention` "ps exited 1"
          notice `shouldMention` "stop the stray gh"

    it "says it is stopping GitHub work while the cancellation runs" $
      stoppingGitHubWorkNotice `shouldMention` "Stopping GitHub work"

  describe "coordinated board refreshes against gh" $ do
    it "runs two requested refreshes one at a time and leaves the durable gh record empty" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository temporaryRoot "coghex" "kanban"
            busyMarker = temporaryRoot </.> "gh.busy"
            overlapMarker = temporaryRoot </.> "gh.overlap"
            startedMarker = temporaryRoot </.> "gh.started"
        published <- newIORef (0 :: Int)
        settled <- newEmptyMVar
        coordinator <-
          startBoardCoordinator
            repository
            ( \_ -> do
                count <- atomicModifyIORef' published (\seen -> (seen + 1, seen + 1))
                unless (count < 2) (putMVar settled ())
            )
        withFakeGh
          temporaryRoot
          [ "if [ -e " <> ByteString.pack busyMarker <> " ]; then : > " <> ByteString.pack overlapMarker <> "; fi",
            ": > " <> ByteString.pack busyMarker,
            ": > " <> ByteString.pack startedMarker,
            "sleep 0.2",
            "printf '%s' '" <> emptyGraphqlPage <> "'",
            "rm -f " <> ByteString.pack busyMarker
          ]
          $ do
            requestRefreshJob coordinator OpenJob . Just =<< deadlineIn 30
            -- Asked for again only once the first is demonstrably inside gh,
            -- so this is a second fetch rather than a request coalesced onto
            -- the first.
            awaitFile startedMarker
            requestRefreshJob coordinator OpenJob . Just =<< deadlineIn 30
            takeMVar settled
        doesFileExist overlapMarker `shouldReturn` False
        readIORef published `shouldReturn` 2
        -- Every group both fetches spawned was confirmed gone, so nothing is
        -- left for the record to account for.
        (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    it "reports each page's cost, remaining and reset exactly as GitHub gave them" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository temporaryRoot "coghex" "kanban"
        samples <- newIORef []
        recordLock <- newGhRecordLock
        guard <- newGhFetchGuard recordLock
        result <-
          withFakeGh
            temporaryRoot
            [ "printf '%s' '"
                <> graphqlPageWithRateLimit "{\"cost\":3,\"remaining\":4997,\"resetAt\":\"2026-01-01T01:00:00Z\"}"
                <> "'"
            ]
            ( (boardRefreshRunner testOptions (uncachedConfig 30) repository).runOpenRefresh
                guard
                (\sample -> atomicModifyIORef' samples (\seen -> (sample : seen, ())))
                (Just (30 * 1000000))
            )
        result.openRefreshRateLimited `shouldBe` False
        readIORef samples `shouldReturn` [Just (RateSample 3 4997 (secondsAfterEpoch 3600))]

    it "reports an unknown budget, and no failure, for a page that never mentioned one" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository temporaryRoot "coghex" "kanban"
        samples <- newIORef []
        recordLock <- newGhRecordLock
        guard <- newGhFetchGuard recordLock
        result <-
          withFakeGh
            temporaryRoot
            ["printf '%s' '" <> emptyGraphqlPage <> "'"]
            ( (boardRefreshRunner testOptions (uncachedConfig 30) repository).runOpenRefresh
                guard
                (\sample -> atomicModifyIORef' samples (\seen -> (sample : seen, ())))
                (Just (30 * 1000000))
            )
        readIORef samples `shouldReturn` [Nothing]
        case result.openRefreshOutcome of
          BoardRefreshCompleted (Right _) -> pure ()
          other -> expectationFailure ("expected an ordinary successful refresh, got " <> show other)

    -- Requirement 6 end to end: GitHub's own refusal is classified as its own
    -- kind, and the refusal is what the next job is made to wait out.
    it "sorts GitHub's primary refusal onto its own kind and makes the next job wait for the reset" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository temporaryRoot "coghex" "kanban"
        recordLock <- newGhRecordLock
        guard <- newGhFetchGuard recordLock
        result <-
          withFakeGh
            temporaryRoot
            ["printf '%s' '" <> rateLimitedGraphqlResponse <> "'"]
            ( (boardRefreshRunner testOptions (uncachedConfig 30) repository).runOpenRefresh
                guard
                (const (pure ()))
                (Just (30 * 1000000))
            )
        result.openRefreshRateLimited `shouldBe` True
        case result.openRefreshOutcome of
          BoardRefreshCompleted (Left providerError) -> do
            providerError.providerErrorKind `shouldBe` RateLimited
            providerError.providerErrorMessage `shouldSatisfy` (not . null . show)
          other -> expectationFailure ("expected a rate-limited refresh failure, got " <> show other)

    it "confirms the gh it owned is gone before a quit is allowed to halt" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository temporaryRoot "coghex" "kanban"
            leaderMarker = temporaryRoot </.> "gh.pid"
        published <- newIORef (0 :: Int)
        coordinator <- startBoardCoordinator repository (\_ -> atomicModifyIORef' published (\seen -> (seen + 1, ())))
        verdict <-
          withFakeGh
            temporaryRoot
            [ "printf '%s\\n' \"$$\" > " <> ByteString.pack leaderMarker,
              "sleep 30",
              "printf '%s' '" <> emptyGraphqlPage <> "'"
            ]
            $ do
              requestRefreshJob coordinator OpenJob . Just =<< deadlineIn 30
              awaitFile leaderMarker
              shutdownRefreshCoordinator coordinator
        -- Nothing left unaccounted for: the cleanup proved the group empty, so
        -- there is no verdict to hold the quit back.
        verdict `shouldBe` Nothing
        leaderPid <- readMarkerPid leaderMarker
        snapshot <- readProcessSnapshot
        case snapshot of
          Left message -> expectationFailure ("could not snapshot processes: " <> show message)
          Right identities -> identityForPid leaderPid identities `shouldBe` Nothing
        (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False
        -- The cancelled job published nothing; a board on its way out never
        -- takes an update from work it just abandoned.
        readIORef published `shouldReturn` 0

-- | A coordinator wired to the board's own runner, so what it schedules is
-- the fetch the dashboard schedules.
startBoardCoordinator :: Repository -> (BoardRefreshOutcome -> IO ()) -> IO (RefreshCoordinator BoardRefreshOutcome)
startBoardCoordinator repository publish = do
  recordLock <- newGhRecordLock
  newRefreshCoordinator recordLock (boardRefreshRunner testOptions (uncachedConfig 30) repository) publish (const (pure ()))

uncachedConfig :: Int -> ResolvedConfig
uncachedConfig githubSeconds =
  testResolvedConfig
    { resolvedCache = False,
      resolvedTimeouts = defaultTimeoutsConfig {timeoutsGithubSeconds = githubSeconds}
    }

-- | What a coordinator did, recorded as it did it.
data Probe = Probe
  { -- | Every job that took the owner, newest first.
    probeStarted :: IORef [RefreshJob],
    probePublished :: IORef [Text],
    probeNotices :: IORef [CoordinatorNotice],
    probeInFlight :: IORef Int,
    -- | The most jobs ever holding the owner at once. Anything but one is a
    -- coordinator that is not coordinating.
    probePeakInFlight :: IORef Int,
    probeHistoryPages :: IORef Int
  }

newProbe :: IO Probe
newProbe =
  Probe
    <$> newIORef []
    <*> newIORef []
    <*> newIORef []
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef 0

-- | A coordinator whose jobs are whatever the test says they are, wrapped so
-- every start, overlap, publication and notice is recorded.
startProbeCoordinator ::
  Probe ->
  (GhFetchGuard -> (Maybe RateSample -> IO ()) -> IO (OpenRefreshResult Text)) ->
  ((Maybe RateSample -> IO ()) -> IO HistoryPageResult) ->
  IO (RefreshCoordinator Text)
startProbeCoordinator probe openBody historyBody = do
  recordLock <- newGhRecordLock
  newRefreshCoordinator
    recordLock
    RefreshRunner
      { runOpenRefresh = \guard observe _ -> instrumentedJob probe OpenJob (openBody guard observe),
        openRefreshExpired = pure "expired",
        runHistoryPage = \_ observe -> instrumentedJob probe HistoryJob (historyBody observe)
      }
    (\value -> atomicModifyIORef' probe.probePublished (\seen -> (seen <> [value], ())))
    (\notice -> atomicModifyIORef' probe.probeNotices (\seen -> (seen <> [notice], ())))

-- | Records a job taking and giving back the owner, whatever the job returns.
instrumentedJob :: Probe -> RefreshJob -> IO value -> IO value
instrumentedJob probe job body = do
  inFlight <- atomicModifyIORef' probe.probeInFlight (\count -> (count + 1, count + 1))
  atomicModifyIORef' probe.probePeakInFlight (\peak -> (max peak inFlight, ()))
  atomicModifyIORef' probe.probeStarted (\seen -> (job : seen, ()))
  value <- body
  atomicModifyIORef' probe.probeInFlight (\count -> (count - 1, ()))
  pure value

-- | Waits for a recorded list to reach a length, rather than for a duration.
awaitCount :: IORef [value] -> Int -> IO ()
awaitCount reference wanted = go (400 :: Int)
  where
    go 0 = do
      seen <- readIORef reference
      expectationFailure ("timed out waiting for " <> show wanted <> " entries, saw " <> show (length seen))
    go attempts = do
      seen <- readIORef reference
      unless (length seen >= wanted) (threadDelay 25000 >> go (attempts - 1))

-- | A deadline measured from the real clock, since the running coordinator
-- plans against that rather than against the suite's fixed epoch.
deadlineIn :: Int -> IO UTCTime
deadlineIn seconds = addUTCTime (fromIntegral seconds) <$> getCurrentTime

awaitFile :: FilePath -> IO ()
awaitFile path = go (400 :: Int)
  where
    go 0 = expectationFailure ("timed out waiting for " <> path)
    go attempts = do
      there <- doesFileExist path
      unless there (threadDelay 25000 >> go (attempts - 1))

(</.>) :: FilePath -> FilePath -> FilePath
directory </.> name = directory <> "/" <> name

secondsAfterEpoch :: Int -> UTCTime
secondsAfterEpoch seconds = addUTCTime (fromIntegral seconds) epoch

-- | A report whose reset is an hour past the fixed epoch, so every assertion
-- about a pause names one time.
sampleWith :: Int -> RateSample
sampleWith remaining = RateSample 1 remaining (secondsAfterEpoch 3600)

pausedHistoryState :: CoordinatorState
pausedHistoryState =
  fst
    ( planCoordinator
        epoch
        (queueCoordinatorJob HistoryJob Nothing (observeRateSample (Just (sampleWith 10)) initialCoordinatorState))
    )
