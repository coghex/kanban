-- | The one owner of every @gh@ a board refresh starts, and of the durable
-- record that accounts for them.
--
-- Before this, a refresh was a lone @forkIO@ with nothing above it: each built
-- its own guard, each wrapped its own traversal in a timeout, and no refresh
-- could know another existed. That is safe only while exactly one exists. A
-- second concurrent generation would interleave read-modify-writes of the
-- durable @gh@ record — losing an entry, and with it a live @gh@ nothing knows
-- to reclaim — and would spend the GitHub budget the foreground refresh needs
-- without anything noticing.
--
-- So the scheduling lives here, above the fetch and below the dashboard, and
-- it is split in two. Everything that decides is pure: 'planCoordinator' and
-- the state transitions beside it are ordinary functions of the clock and the
-- state, which is what makes priority, coalescing, reserve pauses, and
-- rate-limit holds testable without a process, a socket, or a timer. The loop
-- below them only carries decisions out.
module Kanban.GitHub.Coordinator
  ( -- * The scheduling core
    CoordinatorPlan (..),
    CoordinatorState (..),
    HoldReason (..),
    JobHold (..),
    OpenGeneration,
    PendingJob (..),
    RefreshJob (..),
    beginCoordinatorShutdown,
    finishCoordinatorJob,
    holdCoordinatorJob,
    initialCoordinatorState,
    observeRateSample,
    planCoordinator,
    queueCoordinatorJob,
    rateLimitFallbackHold,
    rateLimitHoldUntil,
    settleHistoryJob,
    settleOpenJob,

    -- * The running coordinator
    CoordinatorNotice (..),
    HistoryPageResult (..),
    OpenRefreshResult (..),
    RefreshCoordinator,
    RefreshRunner (..),
    coordinatorMustSettle,
    coordinatorOpenCycleInFlight,
    newRefreshCoordinator,
    requestRefreshJob,
    shutdownRefreshCoordinator,
  )
where

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.MVar
  ( MVar,
    withMVar,
    modifyMVar,
    modifyMVar_,
    isEmptyMVar,
    newEmptyMVar,
    newMVar,
    putMVar,
    readMVar,
    takeMVar,
    tryPutMVar,
  )
import Control.Exception (SomeException, finally, try)
import Control.Monad (void, when)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, isJust)
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Kanban.GitHub.Fetch (RateObserver)
import Kanban.GitHub.Guard (GhCleanupFailure (..), GhCleanupGuard (..), GhFetchGuard, GhRecordLock, ghFetchCleanupFailure, holdBackUnrecordedGroup, newGhFetchGuard)
import Kanban.GitHub.Rate (HistoryRateVerdict (..), RateSample (..), historyRateVerdict, foregroundRateReserve)
import System.Timeout (timeout)

-- | The two kinds of work a board refresh is made of.
--
-- They are kinds rather than instances on purpose: the queue holds at most one
-- of each, so any number of requests for the same kind coalesce onto one
-- follow-up rather than accumulating.
data RefreshJob
  = -- | The foreground refresh a launch or @u@ asks for. It has a deadline,
    -- it publishes an outcome, and it outranks everything else.
    OpenJob
  | -- | Background traversal of completed history. It runs one page at a time
    -- and gives the owner back at every page boundary, so a foreground job
    -- never waits for a traversal to finish.
    HistoryJob
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Why a job may not start yet, and therefore what may end the wait.
data HoldReason
  = -- | Background history yielded to the budget held for foreground work. A
    -- later page reporting a healthy budget ends this, because the reserve is
    -- a fact about the present rather than about the clock.
    HeldForReserve
  | -- | GitHub refused a request against its primary rate limit. Only the
    -- reported reset ends this: the whole point is not to reissue the job
    -- into the same refusal.
    HeldForRateLimit
  deriving stock (Eq, Show)

data JobHold = JobHold
  { holdReason :: HoldReason,
    holdUntil :: UTCTime
  }
  deriving stock (Eq, Show)

-- | A job that has been asked for and has not run yet.
newtype PendingJob = PendingJob
  { -- | When the request must be given up on, for a job whose caller is
    -- waiting on an outcome. The deadline covers the whole request — queueing
    -- behind another job and any rate-limit hold included — because from the
    -- caller's side those are indistinguishable from a slow fetch.
    pendingDeadline :: Maybe UTCTime
  }
  deriving stock (Eq, Show)

-- | Which open cycle an outcome belongs to.
--
-- It counts /starts/, not requests. A press that only manages to queue a
-- follow-up has not begun a generation, so it cannot retroactively suppress
-- the cycle already running: that cycle keeps the identity it took the owner
-- with and is free to publish under it. Once a newer cycle has started,
-- anything still carrying an older identity is a result nobody is waiting for
-- and the board drops it.
type OpenGeneration = Int

data CoordinatorState = CoordinatorState
  { -- | The job holding the owner. While this is set, nothing else may spawn
    -- @gh@ or touch the durable record.
    coordinatorRunning :: Maybe RefreshJob,
    coordinatorPending :: Map RefreshJob PendingJob,
    coordinatorHolds :: Map RefreshJob JobHold,
    -- | The identity of the newest open cycle to have been answered for:
    -- taken by one that started, or spent by a request that expired before it
    -- could. Every open publication carries the value this held when it was
    -- decided, which is what lets the board tell a current answer from a
    -- superseded one.
    coordinatorOpenGeneration :: OpenGeneration,
    -- | What the newest page reported, and nothing older. What is /left/ of a
    -- budget is spent continuously, so an earlier figure describes a balance
    -- that no longer exists; a page that reported nothing usable therefore
    -- clears this rather than leaving the last one standing.
    coordinatorRate :: Maybe RateSample,
    -- | The newest reset time any page has reported, which deliberately
    -- outlives the report that carried it.
    --
    -- A reset names a fixed moment rather than a balance, so unlike the figure
    -- above it stays true until it passes. It has to outlive the report
    -- because the response GitHub refuses a request with carries no rate
    -- report at all: without this, the one case that most needs the reported
    -- reset — deciding when a refused job may be reissued — would never have
    -- one to obey.
    coordinatorResetAt :: Maybe UTCTime,
    -- | Set once shutdown begins. From then on nothing is queued, nothing is
    -- published, and no job requeues itself.
    coordinatorStopping :: Bool
  }
  deriving stock (Eq, Show)

initialCoordinatorState :: CoordinatorState
initialCoordinatorState =
  CoordinatorState
    { coordinatorRunning = Nothing,
      coordinatorPending = Map.empty,
      coordinatorHolds = Map.empty,
      coordinatorOpenGeneration = 0,
      coordinatorRate = Nothing,
      coordinatorResetAt = Nothing,
      coordinatorStopping = False
    }

-- | What the loop should do next.
data CoordinatorPlan
  = -- | Take the owner and run this job. The time is the deadline the job
    -- inherits, which is what the run is bounded by.
    PlanRun RefreshJob (Maybe UTCTime)
  | -- | A pending job ran out of its deadline before it could ever start.
    PlanExpire RefreshJob
  | -- | History must yield the reserve until the named moment, and the board
    -- is told so.
    PlanPauseHistory UTCTime
  | -- | Nothing to do until the named moment, or until a request arrives.
    PlanWait (Maybe UTCTime)
  | -- | Shutdown has begun.
    PlanStop
  deriving stock (Eq, Show)

-- | Decides what happens next, given the clock and nothing else.
--
-- The order of the arms /is/ the priority contract of requirement 2: an open
-- job that is pending — even one waiting out a rate-limit hold — is answered
-- before history is considered at all, so history can neither start nor resume
-- beside foreground work. Everything a decision changes is returned in the
-- state, so the loop cannot carry out a plan the state does not already
-- reflect.
planCoordinator :: UTCTime -> CoordinatorState -> (CoordinatorState, CoordinatorPlan)
planCoordinator now state0
  | state.coordinatorStopping = (state, PlanStop)
  | isJust state.coordinatorRunning = (state, PlanWait Nothing)
  | otherwise = case Map.lookup OpenJob state.coordinatorPending of
      Just pending
        | deadlinePassed now pending -> (nextOpenGeneration (dropPending OpenJob state), PlanExpire OpenJob)
        | Just hold <- Map.lookup OpenJob state.coordinatorHolds ->
            (state, PlanWait (earliest [Just hold.holdUntil, pending.pendingDeadline]))
        | otherwise -> (nextOpenGeneration (takeOwner OpenJob state), PlanRun OpenJob pending.pendingDeadline)
      Nothing -> historyPlan
  where
    -- A hold that has run out is simply gone, which is the whole of "the job
    -- resumes on its own once that reset has passed": nothing has to notice
    -- the moment it passes, only that it has.
    state = state0 {coordinatorHolds = Map.filter ((> now) . holdUntil) state0.coordinatorHolds}

    historyPlan = case Map.lookup HistoryJob state.coordinatorPending of
      Nothing -> (state, PlanWait Nothing)
      Just pending
        | Just hold <- Map.lookup HistoryJob state.coordinatorHolds ->
            (state, PlanWait (Just hold.holdUntil))
        | otherwise -> case historyRateVerdict state.coordinatorRate of
            HistoryPausedUntil resetAt
              -- A reset already behind us means the sample is describing a
              -- window that has since turned over. Pausing on it would wait
              -- for a moment that has passed; running asks GitHub, and the
              -- page that comes back reports the budget that is actually
              -- current.
              | resetAt > now ->
                  (holdCoordinatorJob HistoryJob (JobHold HeldForReserve resetAt) state, PlanPauseHistory resetAt)
            _ -> (takeOwner HistoryJob state, PlanRun HistoryJob pending.pendingDeadline)

deadlinePassed :: UTCTime -> PendingJob -> Bool
deadlinePassed now pending = maybe False (<= now) pending.pendingDeadline

earliest :: [Maybe UTCTime] -> Maybe UTCTime
earliest values = case catMaybes values of
  [] -> Nothing
  times -> Just (minimum times)

takeOwner :: RefreshJob -> CoordinatorState -> CoordinatorState
takeOwner job state =
  state
    { coordinatorRunning = Just job,
      coordinatorPending = Map.delete job state.coordinatorPending
    }

-- | Claims the next open identity. Taken in the same decision that makes an
-- open cycle answerable — starting it, or spending the request that expired —
-- so no two publications can ever share one, and the board's rule for
-- discarding a superseded answer is a plain comparison.
nextOpenGeneration :: CoordinatorState -> CoordinatorState
nextOpenGeneration state = state {coordinatorOpenGeneration = state.coordinatorOpenGeneration + 1}

dropPending :: RefreshJob -> CoordinatorState -> CoordinatorState
dropPending job state =
  state
    { coordinatorPending = Map.delete job state.coordinatorPending,
      coordinatorHolds = Map.delete job state.coordinatorHolds
    }

-- | Asks for a job. A request for a kind already queued replaces it, so any
-- number of presses leave exactly one — the newest — follow-up waiting.
--
-- Nothing is accepted once shutdown has begun: a request that arrived after
-- the dashboard decided to stop is work nobody is waiting for, and accepting
-- it would put a @gh@ back on the table the shutdown has just cleared.
queueCoordinatorJob :: RefreshJob -> Maybe UTCTime -> CoordinatorState -> CoordinatorState
queueCoordinatorJob job deadline state
  | state.coordinatorStopping = state
  | otherwise = state {coordinatorPending = Map.insert job (PendingJob deadline) state.coordinatorPending}

-- | Gives the owner back. History asks to be requeued at a page boundary,
-- which is what lets a newly requested open job take the owner from a
-- traversal that is nowhere near finished.
finishCoordinatorJob :: RefreshJob -> Bool -> CoordinatorState -> CoordinatorState
finishCoordinatorJob job requeue state
  | requeue = queueCoordinatorJob job Nothing released
  | otherwise = released
  where
    released = state {coordinatorRunning = Nothing}

holdCoordinatorJob :: RefreshJob -> JobHold -> CoordinatorState -> CoordinatorState
holdCoordinatorJob job hold state =
  state {coordinatorHolds = Map.insert job hold state.coordinatorHolds}

-- | Folds in what a page said about the budget.
--
-- A report of a healthy budget is the second way a reserve pause ends, and the
-- only one that does not wait for the reset: paused history cannot produce a
-- page of its own, so without this a pause taken at the start of a window
-- would outlast the foreground refreshes that went on to prove there was
-- plenty left.
--
-- A page that reported nothing usable ends a reserve pause too, because
-- section 13 makes an unknown budget one that pauses nothing. Leaving the
-- previous report standing would be the same mistake in slower motion: history
-- would stay paused on a figure the newest page did not confirm, until a reset
-- that nothing currently reports.
--
-- A rate-limit hold is ended by neither. GitHub refused a request outright,
-- and only the moment it named answers that.
observeRateSample :: Maybe RateSample -> CoordinatorState -> CoordinatorState
observeRateSample sample state =
  state
    { coordinatorRate = sample,
      coordinatorResetAt = maybe state.coordinatorResetAt (Just . (.rateSampleResetAt)) sample,
      coordinatorHolds = Map.filter (not . endedByReport) state.coordinatorHolds
    }
  where
    endedByReport hold =
      hold.holdReason == HeldForReserve
        && maybe True ((> foregroundRateReserve) . (.rateSampleRemaining)) sample

-- | Begins shutdown: queued work is discarded, and nothing further is
-- accepted, published, or requeued.
beginCoordinatorShutdown :: CoordinatorState -> CoordinatorState
beginCoordinatorShutdown state =
  state
    { coordinatorStopping = True,
      coordinatorPending = Map.empty,
      coordinatorHolds = Map.empty
    }

-- | How long a rate-limited job waits when GitHub's own reset time is not
-- available — no page ever reported a usable budget, or the one that did
-- named a reset already behind us.
--
-- It exists so that "wait for the reported reset" still has an answer when
-- nothing was reported. Short, because it is a guess and the cost of guessing
-- low is one refused request; never zero, because retrying immediately is the
-- hot loop this whole hold exists to prevent.
rateLimitFallbackHold :: NominalDiffTime
rateLimitFallbackHold = 60

-- | When a job refused against the primary rate limit may be tried again.
--
-- Read off the newest reported reset rather than the newest report, since the
-- refusal itself arrives carrying no report: the reset a page named earlier in
-- the same window is the one GitHub actually gave for it.
rateLimitHoldUntil :: UTCTime -> CoordinatorState -> UTCTime
rateLimitHoldUntil now state = case state.coordinatorResetAt of
  Just resetAt | resetAt > now -> resetAt
  _ -> addUTCTime rateLimitFallbackHold now

-- | Where a finished foreground job leaves the coordinator.
--
-- A refusal GitHub attributed to its primary rate limit is /reissued/, not
-- merely held: the job goes back in the queue under a hold until the reported
-- reset, so it is tried again rather than being dropped the moment the hold
-- lapses. It keeps its original deadline, which is what bounds the whole of
-- this — the retry runs only if the reset arrives first, and otherwise the
-- deadline expires and publishes the configured timeout, leaving no stale
-- retry to complete afterwards.
--
-- The refusal itself is still published when it happens. Section 13 shows a
-- rate limit to the user while retaining the last good snapshot, and a
-- reissue that is silent until it succeeds would leave the board saying
-- nothing at all for as long as the budget takes to return.
settleOpenJob :: UTCTime -> Maybe UTCTime -> Bool -> CoordinatorState -> CoordinatorState
settleOpenJob now deadline rateLimited state
  | not rateLimited || released.coordinatorStopping = released
  | otherwise =
      holdCoordinatorJob
        OpenJob
        (JobHold HeldForRateLimit (rateLimitHoldUntil now released))
        (queueCoordinatorJob OpenJob deadline released)
  where
    released = finishCoordinatorJob OpenJob False state

-- | Where a finished history page leaves the coordinator.
--
-- More pages requeue the traversal, which is its page-boundary yield. A
-- refusal against the primary rate limit requeues it too, under a hold until
-- the reported reset, so a background traversal waits the limit out instead of
-- hot-looping it. Any other failure ends the traversal: a page that failed for
-- a reason nothing here can wait out is not one to reissue.
settleHistoryJob :: UTCTime -> Maybe HistoryPageResult -> CoordinatorState -> CoordinatorState
settleHistoryJob now result state = case result of
  -- Interrupted: the owner goes back, and nothing requeues itself.
  Nothing -> finishCoordinatorJob HistoryJob False state
  Just (HistoryPageFetched more) -> finishCoordinatorJob HistoryJob more state
  Just (HistoryPageFailed rateLimited)
    | not rateLimited -> finishCoordinatorJob HistoryJob False state
    | otherwise ->
        let released = finishCoordinatorJob HistoryJob True state
         in if released.coordinatorStopping
              then finishCoordinatorJob HistoryJob False state
              else holdCoordinatorJob HistoryJob (JobHold HeldForRateLimit (rateLimitHoldUntil now released)) released

-- | What a foreground refresh produced.
data OpenRefreshResult outcome = OpenRefreshResult
  { openRefreshOutcome :: outcome,
    -- | Whether GitHub refused this refresh against its primary rate limit.
    -- The outcome is still published — section 13 shows a rate limit rather
    -- than hiding it — but the next open job waits out the reported reset
    -- instead of walking into the same refusal.
    openRefreshRateLimited :: Bool
  }

-- | What one page of background history produced.
data HistoryPageResult
  = -- | The page arrived. 'True' when the traversal has more to fetch, which
    -- requeues the job behind whatever else is waiting.
    HistoryPageFetched Bool
  | -- | The page failed. A traversal does not retry its way through an error;
    -- only a rate limit earns another attempt, after the reported reset.
    HistoryPageFailed Bool
  deriving stock (Eq, Show)

-- | What the two job kinds actually do, injected so the scheduling above can
-- be exercised without a GitHub account, a network, or a @gh@ on @PATH@.
data RefreshRunner outcome = RefreshRunner
  { -- | Runs a foreground refresh under the given guard, reporting each page's
    -- budget, and bounded by the microseconds left of its deadline.
    runOpenRefresh :: GhFetchGuard -> RateObserver -> Maybe Int -> IO (OpenRefreshResult outcome),
    -- | The outcome a foreground request earns when it produced none of its
    -- own: its deadline ran out, or its body gave up.
    --
    -- The guard is present exactly when a job ran under one, so an
    -- implementation can account for whatever that job's verified cleanup
    -- concluded rather than reporting a bare timeout over a @gh@ whose fate
    -- is unresolved. 'Nothing' is the request that never started at all.
    openRefreshExpired :: Maybe GhFetchGuard -> IO outcome,
    -- | Fetches one page of background history, then returns the owner.
    runHistoryPage :: GhFetchGuard -> RateObserver -> IO HistoryPageResult
  }

-- | Something the coordinator has to say to the board.
data CoordinatorNotice
  = -- | Background history yielded the reserve, and will resume no earlier
    -- than the moment GitHub named.
    HistoryPausedUntilReset UTCTime
  | -- | A foreground cycle has taken the owner.
    --
    -- Announced for every one, including a cycle the coordinator reissued of
    -- its own accord after a rate limit. The board coalesces further update
    -- requests against its own \"a refresh is running\" state, and that state
    -- is only the truth while every cycle is one the board asked for. Without
    -- this, a reissued cycle would run unannounced: the next press would read
    -- an idle board, report no refresh in progress, and leave a follow-up
    -- beside the one already in flight.
    --
    -- It carries the identity the cycle took, which is what the board records
    -- as the newest generation and compares every later outcome against.
    OpenRefreshStarted OpenGeneration
  deriving stock (Eq, Show)

data RefreshCoordinator outcome = RefreshCoordinator
  { coordinatorState :: MVar CoordinatorState,
    -- | Signalled whenever the state changed in a way that could make a
    -- different plan the right one.
    coordinatorWake :: MVar (),
    coordinatorRecordLock :: GhRecordLock,
    coordinatorRunner :: RefreshRunner outcome,
    -- | Hands an open cycle's outcome to the board under the identity that
    -- cycle was answered for. Only open work publishes; a history page
    -- reports nothing.
    coordinatorPublish :: OpenGeneration -> outcome -> IO (),
    coordinatorReport :: CoordinatorNotice -> IO (),
    -- | The last job to hold the owner, as something shutdown can reach: the
    -- thread to interrupt and the guard whose cleanup verdict decides whether
    -- the dashboard may stop. 'Nothing' only until the first job runs.
    --
    -- It is an 'MVar' rather than a reference because it is also the
    -- handshake. The scheduler empties it in the same critical section that
    -- takes the owner and refills it once the job is registered, so a
    -- shutdown arriving in between blocks on it instead of reading an empty
    -- slot and concluding — wrongly — that no @gh@ was ever started.
    coordinatorLive :: MVar (Maybe LiveJob),
    -- | Held for as long as a publication is actually in flight.
    --
    -- Whether to publish is decided in the same critical section that releases
    -- the owner, so a shutdown either wins that section — and the publication
    -- never happens — or loses it and must wait here for the one already
    -- committed to. Without the wait, a quit could return while a publisher was
    -- still running and let the dashboard halt with a board update, and a cache
    -- write, still to land.
    --
    -- It is a lock of its own rather than the state lock because publishing
    -- writes to the event channel the dashboard drains. Holding the state lock
    -- across that would deadlock the moment the channel filled: the publisher
    -- would wait for the dashboard to drain it, and the dashboard would be
    -- waiting on the state lock to answer whether a cycle was in flight.
    coordinatorPublishLock :: MVar ()
  }

data LiveJob = LiveJob
  { liveJobThread :: ThreadId,
    liveJobGuard :: GhFetchGuard,
    -- | Filled once the job body has fully unwound, cleanup included. Reading
    -- the guard before this is set would read a verdict that is not final.
    liveJobSettled :: MVar ()
  }

newRefreshCoordinator ::
  GhRecordLock ->
  RefreshRunner outcome ->
  (OpenGeneration -> outcome -> IO ()) ->
  (CoordinatorNotice -> IO ()) ->
  IO (RefreshCoordinator outcome)
newRefreshCoordinator recordLock runner publish report = do
  state <- newMVar initialCoordinatorState
  wake <- newEmptyMVar
  live <- newMVar Nothing
  publishLock <- newMVar ()
  let coordinator =
        RefreshCoordinator
          { coordinatorState = state,
            coordinatorWake = wake,
            coordinatorRecordLock = recordLock,
            coordinatorRunner = runner,
            coordinatorPublish = publish,
            coordinatorReport = report,
            coordinatorLive = live,
            coordinatorPublishLock = publishLock
          }
  void (forkIO (schedulerLoop coordinator))
  pure coordinator

requestRefreshJob :: RefreshCoordinator outcome -> RefreshJob -> Maybe UTCTime -> IO ()
requestRefreshJob coordinator job deadline = do
  modifyMVar_ coordinator.coordinatorState (pure . queueCoordinatorJob job deadline)
  wakeCoordinator coordinator

-- | Whether a quit has to go through the coordinator before the dashboard may
-- halt.
--
-- Queued or running work is the obvious reason. The other is a job that has
-- already finished and left a verdict that would refuse the quit: a
-- possibly-live @gh@ that nothing durable records, held back by nothing but
-- this process's own refusal to start another. Halting straight past that
-- would drop exactly the guard that makes it safe, so it counts as something
-- to settle even though nothing is running — which is the difference between
-- asking "is work in flight?" and asking "may this dashboard stop?".
-- | Whether a foreground cycle is already running or waiting to run.
--
-- The board coalesces update requests against its own "a refresh is running"
-- state, which the coordinator keeps current by announcing every cycle it
-- starts. That announcement travels through the event channel, so there is a
-- window in which a cycle is running and the board has not heard yet -- and a
-- press landing in it would read an idle board. This is the same question
-- asked of the coordinator directly, which has no such window.
coordinatorOpenCycleInFlight :: RefreshCoordinator outcome -> IO Bool
coordinatorOpenCycleInFlight coordinator = do
  state <- readMVar coordinator.coordinatorState
  pure (state.coordinatorRunning == Just OpenJob || Map.member OpenJob state.coordinatorPending)

coordinatorMustSettle :: RefreshCoordinator outcome -> IO Bool
coordinatorMustSettle coordinator = do
  state <- readMVar coordinator.coordinatorState
  -- Read after the state, and deliberately so: a reservation is taken while
  -- the state lock is held, so a read that got past that lock either saw the
  -- job still running or sees the reservation here. There is no order in
  -- which both look idle.
  reserved <- isEmptyMVar coordinator.coordinatorPublishLock
  if reserved || isJust state.coordinatorRunning || not (Map.null state.coordinatorPending)
    then pure True
    else do
      live <- readMVar coordinator.coordinatorLive
      maybe (pure False) (fmap unsettledVerdict . ghFetchCleanupFailure . liveJobGuard) live

-- | Whether a cleanup verdict leaves a group only this process is holding
-- back. A group confirmed gone has nothing left to hold back, and a recorded
-- one is re-checked by any later run before it spawns anything.
unsettledVerdict :: Maybe GhCleanupFailure -> Bool
unsettledVerdict = maybe False ((== GuardInMemoryOnly) . (.ghCleanupGuard))

wakeCoordinator :: RefreshCoordinator outcome -> IO ()
wakeCoordinator coordinator = void (tryPutMVar coordinator.coordinatorWake ())

-- | Cancels everything the coordinator owns and reports what became of the
-- @gh@ it had running, if any.
--
-- Queued work is discarded outright — nobody is waiting for it any more — and
-- the running job is interrupted exactly the way a refresh timeout interrupts
-- one, so it unwinds through the same verified cleanup rather than through a
-- second implementation of it. 'Nothing' means nothing was left behind;
-- 'Just' carries the guard's verdict, which is what decides whether stopping
-- is safe.
shutdownRefreshCoordinator :: RefreshCoordinator outcome -> IO (Maybe GhCleanupFailure)
shutdownRefreshCoordinator coordinator = do
  modifyMVar_ coordinator.coordinatorState (pure . beginCoordinatorShutdown)
  wakeCoordinator coordinator
  -- Stopping is set, so nothing new will be published. This waits out the one
  -- publication that may already have been committed to before that, which is
  -- what makes "the dashboard may halt" true rather than merely likely.
  withMVar coordinator.coordinatorPublishLock (const (pure ()))
  -- Blocks for exactly as long as a job that has taken the owner is still
  -- being registered, which is the window in which the slot is empty and a
  -- plain read would answer "nothing running" about a @gh@ that is about to
  -- exist.
  live <- takeMVar coordinator.coordinatorLive
  putMVar coordinator.coordinatorLive live
  case live of
    -- Nothing has ever run, so nothing was ever spawned.
    Nothing -> pure Nothing
    Just job -> do
      killThread job.liveJobThread
      -- The cleanup runs while the job unwinds and holds itself to the budget
      -- in "Kanban.GitHub.Guard", so this wait is bounded by that budget
      -- rather than by the fetch it interrupted. A job that had already
      -- settled passes straight through both of these, and its verdict is the
      -- one that answers for whatever it left behind.
      readMVar job.liveJobSettled
      ghFetchCleanupFailure job.liveJobGuard

schedulerLoop :: RefreshCoordinator outcome -> IO ()
schedulerLoop coordinator = do
  now <- getCurrentTime
  -- The identity comes back out of the same critical section that claimed it,
  -- rather than being read afterwards: an expiry releases nothing, so a later
  -- read could already have been overtaken by the next request's claim.
  (plan, generation) <- modifyMVar coordinator.coordinatorState $ \state -> do
    let (planned, decision) = planCoordinator now state
    -- Claimed under the state lock, so the owner and the slot that names its
    -- thread are taken together and a shutdown can never observe one without
    -- the other.
    --
    -- An expiring request claims its publication here for the same reason.
    -- The plan has just taken it out of the queue, so from this instant it is
    -- no longer observable as pending work; reserving anywhere later would
    -- leave a gap in which nothing looks outstanding and a timeout result is
    -- still to be published. Stopping never reaches this arm -- it plans as
    -- 'PlanStop' -- so the claim needs no condition.
    case decision of
      PlanRun _ _ -> void (takeMVar coordinator.coordinatorLive)
      PlanExpire OpenJob -> takeMVar coordinator.coordinatorPublishLock
      _ -> pure ()
    pure (planned, (decision, planned.coordinatorOpenGeneration))
  case plan of
    PlanStop -> pure ()
    PlanWait deadline -> awaitWake coordinator deadline >> schedulerLoop coordinator
    PlanPauseHistory resetAt -> do
      coordinator.coordinatorReport (HistoryPausedUntilReset resetAt)
      schedulerLoop coordinator
    PlanExpire OpenJob -> do
      -- Nothing ever spawned, so there is nothing to clean up: the request
      -- simply outlived its deadline while waiting for the owner or for a
      -- rate limit to lift, and gets the same timeout outcome a slow fetch
      -- would have earned it.
      publishReserved coordinator generation (coordinator.coordinatorRunner.openRefreshExpired Nothing)
      schedulerLoop coordinator
    PlanExpire HistoryJob -> schedulerLoop coordinator
    PlanRun OpenJob deadline -> runOpenJob coordinator generation deadline >> schedulerLoop coordinator
    PlanRun HistoryJob _ -> runHistoryJob coordinator >> schedulerLoop coordinator

-- | Sleeps until a request arrives, or until the moment a plan is waiting for.
--
-- The cap keeps one wait short enough that a clock jump or a reset far in the
-- future cannot leave the loop unresponsive, and re-planning early costs
-- nothing: an unchanged state simply waits again.
awaitWake :: RefreshCoordinator outcome -> Maybe UTCTime -> IO ()
awaitWake coordinator deadline = do
  now <- getCurrentTime
  case deadline of
    Nothing -> takeMVar coordinator.coordinatorWake
    Just until' -> do
      let micros = min maximumWaitMicros (ceiling (realToFrac (diffUTCTime until' now) * (1000000 :: Double)) :: Int)
      when (micros > 0) (void (timeout micros (takeMVar coordinator.coordinatorWake)))

maximumWaitMicros :: Int
maximumWaitMicros = 60 * 1000 * 1000

rateObserverFor :: RefreshCoordinator outcome -> RateObserver
rateObserverFor coordinator sample = do
  modifyMVar_ coordinator.coordinatorState (pure . observeRateSample sample)
  wakeCoordinator coordinator

runOpenJob :: RefreshCoordinator outcome -> OpenGeneration -> Maybe UTCTime -> IO ()
runOpenJob coordinator generation deadline = do
  coordinator.coordinatorReport (OpenRefreshStarted generation)
  guard <- newGhFetchGuard coordinator.coordinatorRecordLock
  now <- getCurrentTime
  let remaining = fmap (remainingMicros now) deadline
  result <- onJobThread coordinator guard (coordinator.coordinatorRunner.runOpenRefresh guard (rateObserverFor coordinator) remaining)
  -- Read while this job still holds the owner, so no later job can be started
  -- before the refusal it may have earned is on the repository's record lock.
  holdBackUnrecordedGroup guard
  finished <- getCurrentTime
  -- A job that produced nothing was either cancelled or gave up: its deadline
  -- expired, or its body failed outright. Cancellation is the coordinator's
  -- own doing and publishes nothing; anything else still owes the request an
  -- answer, or the board waits on a cycle that will never report. The guard
  -- goes with it, because by here its cleanup has run to completion and its
  -- verdict is what the answer has to account for.
  expired <- maybe (Just <$> coordinator.coordinatorRunner.openRefreshExpired (Just guard)) (const (pure Nothing)) result
  -- Releasing the owner, choosing an outcome, and /reserving/ the publication
  -- are one step. Deciding here but reserving afterwards leaves an instant in
  -- which the work looks finished and the publication has claimed nothing: a
  -- quit landing there finds nothing to settle, halts, and the publisher then
  -- commits a board update and a cache on behalf of a dashboard that has
  -- already stopped.
  publishing <- modifyMVar coordinator.coordinatorState $ \state -> do
    let settled = settleOpenJob finished deadline (maybe False (.openRefreshRateLimited) result) state
        answer = maybe expired (Just . (.openRefreshOutcome)) result
    case answer of
      Just outcome | not state.coordinatorStopping -> do
        takeMVar coordinator.coordinatorPublishLock
        pure (settled, Just outcome)
      _ -> pure (settled, Nothing)
  mapM_ (publishReserved coordinator generation . pure) publishing

-- | Produces an outcome and hands it to the board, releasing the reservation
-- already taken for it.
--
-- The lock is acquired by the caller, inside the section that made the work
-- unobservable, and released only here, so a shutdown either sees it held and
-- waits or arrives before the claim and prevents the publication entirely.
-- Producing the outcome is inside the reservation rather than before it: a
-- caller that computed one first would reopen the very gap the claim closes,
-- and an outcome that fails to compute would strand the lock.
publishReserved :: RefreshCoordinator outcome -> OpenGeneration -> IO outcome -> IO ()
publishReserved coordinator generation produce =
  (produce >>= coordinator.coordinatorPublish generation)
    `finally` putMVar coordinator.coordinatorPublishLock ()

-- | Runs one page of background history.
--
-- It publishes nothing — a page reports through the runner's own channel — but
-- it accounts for its @gh@ exactly as a foreground job does. A background page
-- spawns the same process under the same durable record, so a page that ends
-- holding back a group nothing durable accounts for has to refuse every later
-- job just as a foreground one does: without that, the next open refresh would
-- find an absent record, reclaim nothing, and spawn straight past a group only
-- the finished page's guard ever knew about.
runHistoryJob :: RefreshCoordinator outcome -> IO ()
runHistoryJob coordinator = do
  guard <- newGhFetchGuard coordinator.coordinatorRecordLock
  result <- onJobThread coordinator guard (coordinator.coordinatorRunner.runHistoryPage guard (rateObserverFor coordinator))
  holdBackUnrecordedGroup guard
  finished <- getCurrentTime
  modifyMVar_ coordinator.coordinatorState (pure . settleHistoryJob finished result)

remainingMicros :: UTCTime -> UTCTime -> Int
remainingMicros now deadline =
  max 0 (ceiling (realToFrac (diffUTCTime deadline now) * (1000000 :: Double)) :: Int)

-- | Runs a job's body somewhere it can be interrupted.
--
-- The body has to be on a thread of its own because that is the only way a
-- quit can reach it: interrupting it there unwinds the fetch through the same
-- verified cleanup a refresh timeout does, rather than through a second
-- implementation of it. 'Nothing' comes back when the body was interrupted or
-- raised, which is exactly the set of endings that must publish nothing.
onJobThread :: RefreshCoordinator outcome -> GhFetchGuard -> IO result -> IO (Maybe result)
onJobThread coordinator guard body = do
  settled <- newEmptyMVar
  value <- newIORef Nothing
  threadId <-
    forkIO $
      (try @SomeException body >>= writeIORef value . either (const Nothing) Just)
        `finally` void (tryPutMVar settled ())
  -- Fills the slot the plan emptied. Anything waiting on it — a shutdown that
  -- arrived while this was being set up — is released here with the job it was
  -- looking for.
  --
  -- A finished job is left in the slot rather than cleared out of it, and the
  -- next plan to take the owner is what replaces it. Clearing would open a
  -- window one instruction wide in which a quit issued against a running job
  -- finds nothing: the job would have settled, its cleanup verdict would be
  -- exactly what decides whether stopping is safe, and the shutdown would
  -- report that nothing had been running. Reading a settled job costs nothing
  -- — interrupting a dead thread does nothing, its wait is already over, and
  -- its verdict is final — while a quit made when nothing is queued or running
  -- never consults this at all.
  putMVar coordinator.coordinatorLive (Just (LiveJob threadId guard settled))
  readMVar settled
  readIORef value
