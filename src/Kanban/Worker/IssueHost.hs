{-# LANGUAGE DerivingStrategies #-}

-- | The repository-scoped issue review host (SAG-10).
--
-- One detached process per canonical repository owns that repository's
-- 'ReviewClient' and its connection pool, and every initial review,
-- rereview, and revision is an independently durable /child action/ of it.
-- The split is what makes both of the adapter's process shapes expressible at
-- once: a 'SharedProcess' backend multiplexes two concurrent issue threads
-- through the host's one connection, a 'ProcessPerThread' backend gives each
-- child a connection and process of its own, and either way each child has
-- its own specification, state, journal, command ledger, lease, and terminal
-- result.
--
-- The host runs no review itself. It starts children, routes each provider
-- event to the child it belongs to, applies the commands a dashboard leaves
-- for a child, and settles a child when that child ends — never a sibling,
-- and never itself.
--
-- Three boundaries are deliberately /not/ crossed here.
--
-- The host chooses no provider and no model. 'startReviewClient' resolves the
-- embedded backend through the adapter exactly as the dashboard's own backend
-- start always has, and this module consumes the topology that comes back
-- (requirement 8).
--
-- The host publishes nothing to GitHub. A canonical stage's comment and
-- verdict label are @approve_issues.py@'s alone, reached through
-- 'runCanonicalIssueReview'; a revision's specification amendment and
-- @reviewed:changes@ → @reviewed:revised@ move are @kanban_github_issue@'s
-- alone, reached through the review client's own tool. Nothing in this module
-- posts a verdict, moves a label, or reports an unobserved canonical outcome
-- as an approval (requirement 6).
--
-- The host adds no bound of its own to a child. Its lifetime is derived from
-- its children's — it exits once it holds none — because the four-hour
-- persistent-worker deadline applied to a multi-child process would settle
-- children still inside their own bound and, under a shared connection, take
-- every sibling with it.
--
-- This module is internal — "Kanban.Worker" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Worker.IssueHost
  ( runIssueReviewHost,
    runIssueReviewHostWith,
    IssueHostProvider (..),
    IssueHostTuning (..),
    defaultIssueHostTuning,
    embeddedIssueHostProvider,
    issueHostPollIntervalMicros,
    issueHostIdleGraceSeconds,
    issueActionStartingState,
    childCommandOutcome,
    canonicalStageOutcome,
    revisionTurnOutcome,
    issueActionPreflightAction,
  )
where

import Control.Concurrent (ThreadId, forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (IOException, SomeException, try)
import Control.Monad (forM_, unless, void, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Maybe (catMaybes, isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Kanban.ApprovalService (ApprovalController, ApprovalUnavailable, discoverApprovalController)
import Kanban.Cache (normalizedRepositoryIdentity)
import Kanban.Models (OperatingMode, loadModelRoster, loadedOperatingMode)
import Kanban.Preflight (IssueOrigin, PreflightAction (..), preflightBlocker)
import Kanban.Process (IdentityPresence (..), ManagedProcess, ProcessIdentity, checkIdentityPresenceWith, defaultProcessSnapshot, identityForPid, interruptThenKillManagedProcess, managedProcessPid, readProcessSnapshot)
import Kanban.Worker.Census (recordProviderIdentity, refreshProcessCensus)
import Kanban.Worker.Termination (terminateRecordedProcesses)
import Kanban.Review
  ( CanonicalIssueReviewResult (..),
    ConnectionId,
    ReviewClient,
    ReviewAnswer,
    ReviewEvent (..),
    ReviewRequestId,
    ReviewResult (..),
    ReviewStage (..),
    ReviewThreadId (..),
    ReviewTurnOutcome (..),
    answerReviewQuestion,
    approveReviewAction,
    beginIssueReview,
    canonicalLaunchOutcome,
    finishReviewThread,
    interruptReview,
    reviewClientLogPath,
    reviewConnectionProcesses,
    reviewTurnResumable,
    runCanonicalIssueReview,
    sendReviewMessage,
    startReviewClient,
    stopReviewClient,
  )
import Kanban.Solve (SolveOutcome (..))
import Kanban.Transcript (SessionLog, closeSessionLog, logMessage, logRawLine, openSessionLog, sessionLogPath)
import Kanban.Worker.Command
  ( ReviewCommand (..),
    ReviewCommandOutcome (..),
    ReviewCommandPayload (..),
    acknowledgeReviewCommand,
    readReviewCommandAcknowledgements,
    readReviewCommands,
    reconcileIssueActionClaims,
    reviewCommandAcknowledgement,
    reviewCommandDisplay,
    undeliveredReviewCommands,
    unobservedCommandOutcome,
  )
import Kanban.Worker.Discovery (discoverWorkerHistory)
import Kanban.Worker.Journal (EventJournalLock, appendWorkerEvent, newEventJournalLock)
import Kanban.Worker.Lease (releaseWorkerLease)
import Kanban.Worker.Paths (descriptorForSpec, readWorkerState, writePrivateJson, writeState)
import Kanban.Worker.Types
  ( IssueActionWorkerTask (..),
    WorkerDescriptor (..),
    WorkerEvent (..),
    WorkerId (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    issueActionTask,
    WorkerTask (..),
  )
import System.Posix.Process (getProcessID)

-- | How often the host looks for new children, new commands, and children
-- past their own bound.
--
-- One interval for all three because they are one question — "what has
-- changed on disk for my children" — and separate timers would only let a
-- command be applied to a child a sibling pass had already settled.
issueHostPollIntervalMicros :: Int
issueHostPollIntervalMicros = 500 * 1000

-- | How long a host with no live child waits before exiting.
--
-- Not zero, because a dashboard writes a child's specification and then finds
-- the host, so a host that exited the instant it was idle would race the very
-- first child it was started for. Not long, because a host that stays after
-- its last child holds this repository's host lease and its discovery record
-- for no reason, which requirement 4's later dashboard would then adopt as a
-- live host serving nothing.
issueHostIdleGraceSeconds :: Int
issueHostIdleGraceSeconds = 30

-- | Everything the host asks of a provider, and nothing else.
--
-- A record rather than a 'ReviewClient' for two reasons. It names the whole
-- provider surface this module depends on, which is what makes requirement
-- 8's claim — that the host consumes the adapter's topology and chooses
-- nothing — checkable by reading one type. And it is a seam: the suite drives
-- a real host through adoption, routing, commands, settling, and exit against
-- a provider it controls, the same way 'Kanban.Worker.runWorkerWith'
-- substitutes a process snapshot.
--
-- Every operation is thread-scoped or child-scoped. There is deliberately no
-- "stop the client" among them beyond 'providerStop', which only the host's
-- own shutdown reaches: a child ending must never be able to end the client
-- (requirement 11).
data IssueHostProvider = IssueHostProvider
  { providerBeginReview :: Int -> IO (Either Text ()),
    providerAnswerQuestion :: ReviewRequestId -> ReviewAnswer -> IO (Either Text ()),
    providerApproveAction :: ReviewRequestId -> Bool -> Bool -> IO (Either Text ()),
    providerSendMessage :: ReviewThreadId -> Maybe Text -> Text -> IO (Either Text ()),
    providerInterruptTurn :: ReviewThreadId -> Text -> IO (Either Text ()),
    -- | Settle one thread and whatever that thread owns, which under
    -- 'ProcessPerThread' is its own process and under 'SharedProcess' is its
    -- tool descendants alone.
    providerFinishThread :: ReviewThreadId -> IO (),
    -- | Every provider process the client currently holds, so the host can
    -- register them with its own supervisor. A host that died uncleanly
    -- otherwise leaves them orphaned with nothing durable naming them, and
    -- nothing for a recovery pass to verify.
    providerProcesses :: IO [ManagedProcess],
    -- | Where the client writes the traffic that belongs to no one thread.
    -- The host records it as its own log; each child keeps its own.
    providerLogPath :: Maybe FilePath,
    providerStop :: IO ()
  }

-- | The real provider: one started 'ReviewClient', wrapped.
--
-- 'startReviewClient' is what resolves the embedded backend through the
-- adapter, so this function chooses no provider and no cell; it only names
-- which of the client's operations the host is allowed to reach.
embeddedIssueHostProvider :: ReviewClient -> IssueHostProvider
embeddedIssueHostProvider client =
  IssueHostProvider
    { providerBeginReview = beginIssueReview client,
      providerAnswerQuestion = answerReviewQuestion client,
      providerApproveAction = approveReviewAction client,
      providerSendMessage = sendReviewMessage client,
      providerInterruptTurn = interruptReview client,
      providerFinishThread = finishReviewThread client,
      providerProcesses = reviewConnectionProcesses client,
      providerLogPath = reviewClientLogPath client,
      providerStop = stopReviewClient client
    }

-- | The host's two timings, injected for the same reason the provider is: a
-- suite that waited out the production idle grace would spend half a minute
-- proving a host exits.
data IssueHostTuning = IssueHostTuning
  { hostPollMicros :: Int,
    hostIdleGraceSeconds :: Int
  }

defaultIssueHostTuning :: IssueHostTuning
defaultIssueHostTuning = IssueHostTuning issueHostPollIntervalMicros issueHostIdleGraceSeconds

-- | One child action, as the host holds it while it runs.
--
-- Everything durable about a child is in its own files; this is the live
-- half — the thread running its stage, the canonical subprocess it may own,
-- and the one-shot settle claim that stops two paths committing two terminal
-- outcomes for it.
data HostChild = HostChild
  { hostChildDescriptor :: WorkerDescriptor,
    hostChildTask :: IssueActionWorkerTask,
    hostChildJournal :: EventJournalLock,
    -- | This child's own raw log.
    --
    -- Its own, and not the client's. A shared-process backend writes every
    -- thread's traffic to one client-wide transcript, interleaved and with no
    -- record of which action any line belongs to — so a child would have no
    -- raw evidence it could point at, let alone replay. This log holds the
    -- provider traffic routed to this child, byte-accurate for output, and
    -- its path is on the child's own state where a dashboard reads it.
    --
    -- 'Nothing' when the log could not be opened. A raw log that will not
    -- open is a hygiene failure, never a reason to refuse the review: the
    -- event journal is the evidence a replay actually needs.
    hostChildLog :: Maybe SessionLog,
    hostChildState :: MVar WorkerState,
    hostChildStageThread :: IORef (Maybe ThreadId),
    -- | The canonical @approve_issues.py@ subprocess, for a canonical stage
    -- only. A revision has none; its provider work happens on a review thread
    -- inside the host's client.
    hostChildProcess :: IORef (Maybe ManagedProcess),
    -- | Closed the instant this child's terminal envelope is written, under
    -- the same lock that writes it.
    --
    -- A monitor stops replaying at that envelope, so anything appended after
    -- it is seen by a dashboard that reattaches and not by one that was
    -- watching — which is the live-versus-reattached divergence requirement 4
    -- exists to rule out. Stage threads are cancelled by a settle rather than
    -- joined, so a canonical invocation can return its result while the
    -- settle is committing; making "nothing follows the terminal envelope" a
    -- property of the journal itself is what makes that harmless, rather than
    -- a discipline every writer has to remember.
    hostChildJournalGate :: MVar Bool,
    -- | Won once. Whoever wins commits this child's terminal outcome,
    -- releases its lease, and stops its stage; every later claimant is a
    -- no-op. Without it a turn completing while a termination command is
    -- being applied would write two terminal states for one child.
    hostChildSettleClaim :: IORef Bool
  }

data IssueReviewHost = IssueReviewHost
  { hostSpec :: WorkerSpec,
    hostDescriptor :: WorkerDescriptor,
    hostEmit :: WorkerEvent -> IO (),
    hostTuning :: IssueHostTuning,
    hostChildren :: MVar (Map WorkerId HostChild),
    -- | Children this host has settled, kept addressable by action id.
    --
    -- A child is settled the instant a termination command, a deadline, or a
    -- dead connection says so, and that can be before the provider has
    -- finished creating the thread the child asked for. The creation is
    -- announced asynchronously, so the announcement can arrive after the
    -- child has left 'hostChildren' entirely — and a thread nobody owns is a
    -- thread nobody closes.
    --
    -- By action id and not by issue: an issue can have several settled
    -- actions, each with its own pending announcement, and keying by issue
    -- would let the newest overwrite the ones before it — whose threads would
    -- then resolve to nothing and never be closed.
    --
    -- Retained for the host's whole life rather than expired: the set is
    -- bounded by the actions one host serves, and the alternative is a second
    -- timer whose expiry is exactly the race it was added to close.
    hostRetired :: MVar (Map WorkerId HostChild),
    -- | The children that have asked the provider for a thread and not yet
    -- been told which one, oldest first, per issue.
    --
    -- The wire names only an issue number, and an issue can outlive the
    -- action that asked: a child settled before its thread was announced
    -- releases its lease, a replacement action for the same issue starts, and
    -- the late announcement would then attach the first action's thread to
    -- the second — where it would take the second's commands and never be
    -- closed. Start order is the correlation the protocol actually gives us,
    -- so the announcement resolves to the oldest start still waiting rather
    -- than to whichever child holds the issue now.
    hostPendingStarts :: MVar (Map Int [WorkerId]),
    -- | The embedded review client, once something has needed one.
    --
    -- Started on demand rather than at startup, because only an interactive
    -- revision needs it. A canonical initial review or rereview runs
    -- @approve_issues.py@ and has no embedded provider session at all
    -- (requirement 5); starting one for it would make a canonical review fail
    -- on an install whose embedded backend is unavailable — for a component
    -- its own stage-specific preflight never asks about.
    hostProvider :: MVar (Maybe IssueHostProvider),
    hostStartProvider :: WorkerSpec -> (ManagedProcess -> IO ()) -> (ReviewEvent -> IO ()) -> IO (Either Text IssueHostProvider),
    -- | Runs one canonical stage's @approve_issues.py@ invocation, reporting
    -- the subprocess it spawned through the callback.
    --
    -- Held by the host rather than by the provider precisely because a
    -- canonical stage needs no provider. What surrounds it — the preflight,
    -- the approval-service interlock re-asked immediately before the spawn,
    -- the recording of the subprocess against this child — stays in the host,
    -- where requirement 7 puts it. Production is
    -- 'Kanban.Review.runCanonicalIssueReview' and nothing else.
    hostRunCanonical :: ReviewStage -> Int -> (ManagedProcess -> IO ()) -> IO (Either Text CanonicalIssueReviewResult),
    -- | The supervisor's own provider registration, which records a process's
    -- identity, adds it to this worker's census, and makes it reachable by
    -- termination and recovery.
    hostRememberProvider :: ManagedProcess -> IO (),
    -- | Which of the client's processes have already been registered, so each
    -- is registered once. Repeated registration is what accumulates the whole
    -- set in the census: each call adds the newest and retains what a
    -- previous one recorded.
    hostRegisteredProcesses :: IORef [Int],
    hostApprovalController :: Either ApprovalUnavailable ApprovalController,
    hostRepositoryIdentity :: Text,
    hostOperatingMode :: OperatingMode,
    hostPid :: Int,
    hostProcessIdentity :: Maybe ProcessIdentity,
    hostStopped :: IORef Bool
  }

-- | The host's whole life.
--
-- The client is started first and torn down last, and nothing between the two
-- ever tears it down: a child ending reaches 'finishReviewThread' for its own
-- thread and no further (requirement 11). A client that will not start is
-- reported to every child waiting on it and ends the host, because a host
-- with no client can serve nobody.
runIssueReviewHost :: WorkerSpec -> (ManagedProcess -> IO ()) -> (WorkerEvent -> IO ()) -> IO ()
runIssueReviewHost hostSpec = runIssueReviewHostWith defaultIssueHostTuning startEmbeddedProvider runCanonicalStage hostSpec
  where
    startEmbeddedProvider spec register sink = do
      rosterResult <- loadModelRoster
      case rosterResult of
        -- The roster is what 'startReviewClient' resolves the embedded
        -- backend's cell from, so a roster that will not load is the
        -- backend's own failure surface rather than a routing decision made
        -- here. It is only ever reached by a revision, which is the one stage
        -- that needs a provider session at all.
        Left _ -> pure (Left "the model roster could not be loaded, so no review backend could be started")
        Right roster ->
          fmap embeddedIssueHostProvider
            <$> startReviewClient roster spec.workerWorkflowConfig spec.workerRepository register sink
    runCanonicalStage stage issueNumber started =
      runCanonicalIssueReview hostSpec.workerConfigPath hostSpec.workerRepository issueNumber stage started

runIssueReviewHostWith ::
  IssueHostTuning ->
  (WorkerSpec -> (ManagedProcess -> IO ()) -> (ReviewEvent -> IO ()) -> IO (Either Text IssueHostProvider)) ->
  (ReviewStage -> Int -> (ManagedProcess -> IO ()) -> IO (Either Text CanonicalIssueReviewResult)) ->
  WorkerSpec ->
  (ManagedProcess -> IO ()) ->
  (WorkerEvent -> IO ()) ->
  IO ()
runIssueReviewHostWith tuning startProvider runCanonical spec rememberProvider emit = do
  descriptor <- descriptorForSpec spec
  rosterResult <- loadModelRoster
  controller <- discoverApprovalController spec.workerRepository
  pid <- fromIntegral <$> getProcessID
  snapshot <- readProcessSnapshot
  children <- newMVar Map.empty
  retired <- newMVar Map.empty
  pendingStarts <- newMVar Map.empty
  providerCell <- newMVar Nothing
  registered <- newIORef []
  stopped <- newIORef False
  let host =
        IssueReviewHost
          { hostSpec = spec,
            hostDescriptor = descriptor,
            hostEmit = emit,
            hostTuning = tuning,
            hostChildren = children,
            hostRetired = retired,
            hostPendingStarts = pendingStarts,
            hostProvider = providerCell,
            hostStartProvider = startProvider,
            hostRunCanonical = runCanonical,
            hostRememberProvider = rememberProvider,
            hostRegisteredProcesses = registered,
            hostApprovalController = controller,
            hostRepositoryIdentity = normalizedRepositoryIdentity spec.workerRepository,
            hostOperatingMode = loadedOperatingMode rosterResult,
            hostPid = pid,
            hostProcessIdentity = either (const Nothing) (identityForPid pid) snapshot,
            hostStopped = stopped
          }
  -- Deliberately not 'WorkerProviderStarted' with this host's own pid. The
  -- host is not a provider turn, and a recorded provider pid with no recorded
  -- identity is precisely the shape every termination path reads as "started,
  -- but unverifiable" — which leaves a host kill recording a pending
  -- termination it can never complete. What the host records is its client's
  -- actual processes, each through the supervisor's own registration, as the
  -- client creates them.
  emit (WorkerDiagnostic ("repository review host running as pid " <> Text.pack (show pid)))
  now <- getCurrentTime
  -- The loop's own failure is a terminal outcome for the host, not a silent
  -- death. A host thread that simply ended would leave every child it was
  -- serving recorded as running under a process that is gone, with nothing
  -- saying why — which is the hardest state for a later dashboard to make
  -- sense of and the one this layer exists to avoid.
  looped <- try @SomeException (hostLoop host now)
  let outcome = either (SolveFailed . ("the repository review host failed: " <>) . Text.pack . show) id looped
  -- Only if something needed one. A host that served nothing but canonical
  -- stages never started a client and has none to stop.
  readMVar providerCell >>= mapM_ (.providerStop)
  -- Every child's raw log is closed here rather than when that child settled.
  -- A settled child can still receive a late thread announcement, and that is
  -- evidence worth keeping; closing at settle would throw it away and, worse,
  -- leave a closed handle for the very write that records it.
  closeChildLogs host
  finishHost host outcome

-- | The poll. Adopt, command, bound, exit — in that order, because each step
-- can only be answered correctly against what the one before it just did.
hostLoop :: IssueReviewHost -> UTCTime -> IO SolveOutcome
hostLoop host lastLive = do
  threadDelay host.hostTuning.hostPollMicros
  -- Each step is isolated. A step that throws — an unreadable directory, a
  -- child whose records have gone, a provider call that failed in a way its
  -- own result could not express — must not end the poll, because ending the
  -- poll ends the host and every sibling action it is serving (requirement
  -- 11). What it does instead is say so on the host's own journal.
  mapM_
    (isolateHostStep host)
    [ ("registering the client's processes", registerProviderProcesses host),
      ("adopting new children", adoptNewChildren host),
      ("applying dashboard commands", applyPendingCommands host),
      ("enforcing child bounds", enforceChildBounds host),
      ("refreshing child heartbeats", refreshChildHeartbeats host)
    ]
  live <- liveChildren host
  now <- getCurrentTime
  if not (null live)
    then hostLoop host now
    else
      if diffUTCTime now lastLive >= fromIntegral host.hostTuning.hostIdleGraceSeconds
        then pure SolveCompleted
        else hostLoop host lastLive

-- | Runs one poll step, reporting a failure rather than letting it end the
-- host.
isolateHostStep :: IssueReviewHost -> (Text, IO ()) -> IO ()
isolateHostStep host (what, step) = do
  outcome <- try @SomeException step
  case outcome of
    Right () -> pure ()
    Left failure -> hostDiagnostic host (what <> " failed: " <> Text.pack (show failure))

-- | Commit the host's own terminal outcome. Children are already settled by
-- the time this runs: the loop only exits when it holds none.
finishHost :: IssueReviewHost -> SolveOutcome -> IO ()
finishHost host outcome = do
  writeIORef host.hostStopped True
  host.hostEmit (WorkerFinished outcome)

-- ---------------------------------------------------------------------------
-- Adoption
-- ---------------------------------------------------------------------------

-- | Take on every child specification that names this host and is not already
-- running or already terminal.
--
-- Naming the host is the whole of the claim (requirement 16): a child records
-- the host it was launched for, and a host adopts only children that name it,
-- so a stale host and a live one in one directory can never both serve one
-- action.
adoptNewChildren :: IssueReviewHost -> IO ()
adoptNewChildren host = do
  history <- discoverWorkerHistory host.hostSpec.workerRepository
  held <- readMVar host.hostChildren
  candidates <- catMaybes <$> mapM (childCandidate host) history
  forM_ candidates $ \(descriptor, task, adoption) ->
    unless (Map.member descriptor.workerDescriptorSpec.workerId held) $ do
      stateResult <- readWorkerState descriptor
      case stateResult of
        Right state | terminalStatus state.workerStateStatus -> pure ()
        _ -> do
          (owned, ownedTask) <- rehomeChild host descriptor task
          adoptChild host owned ownedTask adoption

-- | What this host may do with a child, if anything.
--
-- Naming this host is the ordinary claim, and the only one that reaches a
-- child another host is already serving (requirement 16).
--
-- The other two are recovery, and they are needed because host selection and
-- child admission cannot be made atomic from the launch side: a dispatch
-- reads a live host, and that host can reach its idle grace and exit — or
-- simply die — before or after the child's specification is written. Under
-- the first arm alone such a child sits unadopted until stale recovery: an
-- action the operator started that never runs, and whose dashboard commands
-- are never answered.
--
-- Which of the two recoveries applies turns on whether the child ever
-- started. One that has done nothing is re-homed and run, because repeating
-- nothing loses nothing. One that /had/ started is re-homed and settled
-- without being restarted: its provider session belonged to a host that is
-- gone and cannot be resumed, and requirement 15 is explicit that such an
-- action is reported rather than silently run again as a new one.
--
-- "Provably gone" is what keeps either from being theft. A live host's
-- children are never candidates, and a host record that cannot be read is not
-- proof.
data ChildAdoption
  = -- | Run this child's stage.
    AdoptToRun
  | -- | Settle it, without restarting anything.
    AdoptToRecover
  deriving stock (Eq, Show)

childCandidate :: IssueReviewHost -> WorkerDescriptor -> IO (Maybe (WorkerDescriptor, IssueActionWorkerTask, ChildAdoption))
childCandidate host descriptor = case issueActionTask descriptor.workerDescriptorSpec.workerTask of
  Nothing -> pure Nothing
  Just task
    | task.issueActionHost == host.hostSpec.workerId -> pure (Just (descriptor, task, AdoptToRun))
    | otherwise -> do
        orphaned <- namedHostGone host task.issueActionHost
        if not orphaned
          then pure Nothing
          else do
            untouched <- neverAdopted descriptor
            pure (Just (descriptor, task, if untouched then AdoptToRun else AdoptToRecover))

-- | Rewrites an orphaned child's specification to name this host.
--
-- Persisted rather than held in memory, because the ownership it records is
-- read by things outside this process: startup discovery decides which host a
-- child reattaches to from it, and the cache collection pass decides whether
-- a child's records may be removed by whether /its named host/ is live. A
-- child running under this host while its specification still names a dead
-- one is two answers to one question, and the collection pass would take the
-- dead one.
rehomeChild :: IssueReviewHost -> WorkerDescriptor -> IssueActionWorkerTask -> IO (WorkerDescriptor, IssueActionWorkerTask)
rehomeChild host descriptor task
  | task.issueActionHost == host.hostSpec.workerId = pure (descriptor, task)
  | otherwise = do
      let rehomed = task {issueActionHost = host.hostSpec.workerId}
          spec = descriptor.workerDescriptorSpec {workerTask = IssueActionWorkerTaskKind rehomed}
      written <- writePrivateJson descriptor.workerDescriptorSpecPath spec
      pure $ case written of
        -- A specification that cannot be rewritten leaves the child named to
        -- its dead host. It is still adopted and still answered for; what is
        -- lost is only the durable record of who is serving it, which the
        -- next pass tries again.
        Left _ -> (descriptor, task)
        Right () -> (descriptor {workerDescriptorSpec = spec}, rehomed)

-- | Whether the host a child names is definitely not going to run it.
--
-- Terminal is the obvious case. The other is a host that died without
-- recording anything — killed, or stopped between persisting a running state
-- and doing anything with it — which leaves a record that reads as running
-- forever. Its recorded identity is what tells the two apart, so it is
-- checked against a live process snapshot.
--
-- Fails closed: a record that cannot be read, and a snapshot that cannot be
-- taken, both leave the child to the host it names.
namedHostGone :: IssueReviewHost -> WorkerId -> IO Bool
namedHostGone host named = do
  history <- discoverWorkerHistory host.hostSpec.workerRepository
  case find ((== named) . (.workerId) . (.workerDescriptorSpec)) history of
    Nothing -> pure True
    Just descriptor -> do
      stateResult <- readWorkerState descriptor
      case stateResult of
        Left _ -> pure False
        Right state
          | terminalStatus state.workerStateStatus -> pure True
          | otherwise -> case state.workerStateWorkerIdentity of
              Nothing -> pure False
              Just identity -> (== IdentityAbsent) <$> checkIdentityPresenceWith defaultProcessSnapshot [identity]

-- | Whether a child has done nothing at all yet, which is what makes
-- re-homing it safe.
neverAdopted :: WorkerDescriptor -> IO Bool
neverAdopted descriptor = do
  stateResult <- readWorkerState descriptor
  pure $ case stateResult of
    Right state ->
      state.workerStateStatus == WorkerStarting
        && state.workerStateReviewThread == Nothing
        && state.workerStateProviderPid == Nothing
    Left _ -> False

terminalStatus :: WorkerStatus -> Bool
terminalStatus (WorkerTerminal _) = True
terminalStatus (WorkerOrphaned _) = True
terminalStatus _ = False

adoptChild :: IssueReviewHost -> WorkerDescriptor -> IssueActionWorkerTask -> ChildAdoption -> IO ()
adoptChild host descriptor task adoption = do
  journal <- newEventJournalLock
  now <- getCurrentTime
  rawLog <- openChildLog descriptor task
  stateCell <-
    newMVar
      ( (issueActionStartingState host.hostPid host.hostProcessIdentity now descriptor.workerDescriptorSpec)
          {workerStateLogPath = sessionLogPath <$> rawLog}
      )
  stageThread <- newIORef Nothing
  process <- newIORef Nothing
  journalGate <- newMVar False
  settleClaim <- newIORef False
  let child =
        HostChild
          { hostChildDescriptor = descriptor,
            hostChildTask = task,
            hostChildJournal = journal,
            hostChildLog = rawLog,
            hostChildJournalGate = journalGate,
            hostChildState = stateCell,
            hostChildStageThread = stageThread,
            hostChildProcess = process,
            hostChildSettleClaim = settleClaim
          }
  modifyMVar_ host.hostChildren (pure . Map.insert descriptor.workerDescriptorSpec.workerId child)
  persistChild child
  journalChild child (WorkerDiagnostic (adoptionDiagnostic task))
  -- Before anything else, and for both adoptions: a claim a previous host
  -- left standing is answered whether this host goes on to run the action or
  -- only to settle it.
  -- A claim a previous host left standing is answered whether this host goes
  -- on to run the action or only to settle it. The same function stale
  -- recovery uses, so a child reaches one answer however it is discovered.
  reconcileIssueActionClaims descriptor
  case adoption of
    AdoptToRun -> do
      threadId <- forkIO (runChildStage host child)
      writeIORef stageThread (Just threadId)
    -- Recovered, not restarted. Its provider session belonged to a host that
    -- is gone; replaying its evidence and reporting an unknown outcome is
    -- what requirement 15 asks for, and starting a fresh turn under the same
    -- action is what it forbids.
    AdoptToRecover -> do
      journalChild child (WorkerDiagnostic unresumableActionDiagnostic)
      settleChild host child (SolveFailed unresumableActionDiagnostic)

-- | Answers for the commands a previous host claimed and never settled.
--
-- A claim is what stops a command being applied twice, so these must not be
-- applied again — but a claim on its own is indistinguishable from one whose
-- host is still working on it, and the dashboard that submitted the command
-- cleared its draft when it did. Left alone, that message simply vanishes:
-- no journal entry, no acknowledgement, nothing to put it back on the line.
--
-- So each is settled as an outcome nobody observed, and journaled as an
-- undelivered input — which is exactly what hands the text back to the
-- overlay's input line on replay.
-- | Opens this child's raw log, named for the action rather than the host so
-- two concurrent revisions never share one.
openChildLog :: WorkerDescriptor -> IssueActionWorkerTask -> IO (Maybe SessionLog)
openChildLog descriptor task = do
  opened <- openSessionLog descriptor.workerDescriptorSpec.workerRepository "issue-action" task.issueActionIssueNumber Nothing
  case opened of
    Left _ -> pure Nothing
    Right sessionLog -> Just sessionLog <$ logMessage sessionLog "action-started" (adoptionDiagnostic task)

adoptionDiagnostic :: IssueActionWorkerTask -> Text
adoptionDiagnostic task =
  "issue #"
    <> Text.pack (show task.issueActionIssueNumber)
    <> " "
    <> stageLabel task.issueActionStage
    <> " adopted by the repository review host"

stageLabel :: ReviewStage -> Text
stageLabel InitialReview = "review"
stageLabel IssueRereview = "rereview"
stageLabel IssueRevision = "revision"

-- | The state a child is discoverable under from the moment it is adopted.
--
-- The worker pid and identity are the /host's/, because the host is this
-- child's supervisor: a child is a durable action, not an operating-system
-- process. That is also what makes requirement 16's classification fall out
-- of the existing rules — when a host dies, every child it was serving is
-- left recording an identity that is provably gone, which is exactly the
-- orphaned reading, and each child keeps its own evidence while being read
-- that way.
issueActionStartingState :: Int -> Maybe ProcessIdentity -> UTCTime -> WorkerSpec -> WorkerState
issueActionStartingState pid identity now spec =
  WorkerState
    { workerStateId = spec.workerId,
      workerStateStatus = WorkerStarting,
      workerStateWorkerPid = pid,
      workerStateWorkerIdentity = identity,
      workerStateProviderPid = Nothing,
      workerStateProviderIdentity = Nothing,
      workerStateSessionId = Nothing,
      workerStateLogPath = Nothing,
      workerStateHeartbeatAt = now,
      workerStateLastActivity = "starting",
      workerStateKnownProcesses = [],
      workerStateReviewThread = Nothing,
      workerStateReviewTurn = Nothing,
      workerStateReviewRequest = Nothing
    }

-- ---------------------------------------------------------------------------
-- Running one child's stage
-- ---------------------------------------------------------------------------

-- | What preflight asks about a child, which is stage-specific for the same
-- reason its authority is: a canonical stage needs the canonical backend and
-- the reviewers its origin routes to, a revision needs the interactive
-- coordinator's own dependencies.
issueActionPreflightAction :: ReviewStage -> IssueOrigin -> PreflightAction
issueActionPreflightAction IssueRevision origin = ActionIssueRevision origin
issueActionPreflightAction _ origin = ActionIssueReview origin

runChildStage :: IssueReviewHost -> HostChild -> IO ()
runChildStage host child = do
  outcome <- try @SomeException (dispatchChildStage host child)
  case outcome of
    Left failure -> settleChild host child (SolveFailed (Text.pack (show failure)))
    Right () -> pure ()

dispatchChildStage :: IssueReviewHost -> HostChild -> IO ()
dispatchChildStage host child = case child.hostChildTask.issueActionStage of
  IssueRevision -> runRevisionChild host child
  stage -> runCanonicalChild host child stage

-- | A canonical initial review or rereview.
--
-- The approval-service interlock is preserved exactly (requirement 7): the
-- board asked once when the action was requested, and 'canonicalLaunchOutcome'
-- asks again here, after the preflight and immediately before the subprocess
-- is spawned, because the service can take the backend's approval lock while
-- the probes run. A revision never reaches this arm and is exempt from both.
runCanonicalChild :: IssueReviewHost -> HostChild -> ReviewStage -> IO ()
runCanonicalChild host child stage = do
  let task = child.hostChildTask
      spec = child.hostChildDescriptor.workerDescriptorSpec
  -- No provider, and deliberately none: this stage's whole work is
  -- @approve_issues.py@, and requiring an embedded session for it would make
  -- a canonical review fail on an install whose embedded backend is
  -- unavailable — for a component this stage's own preflight never asks
  -- about (requirement 5).
  result <-
    canonicalLaunchOutcome
      stage
      host.hostRepositoryIdentity
      host.hostApprovalController
      (preflightBlocker spec.workerRepository host.hostOperatingMode (issueActionPreflightAction stage task.issueActionOrigin))
      (host.hostRunCanonical stage task.issueActionIssueNumber (recordCanonicalProcess host child))
  -- The gate can finish while a termination is settling this child, and the
  -- settle closes the journal. Recording the result on the host instead of
  -- dropping it keeps the evidence an operator needs — the gate may well have
  -- posted its comment and moved the labels — without appending to a
  -- transcript a reattaching dashboard would replay past the terminal event.
  recorded <- journalChildRecord child (WorkerCanonicalReviewFinished stage result)
  unless recorded (hostDiagnostic host (lateCanonicalResultDiagnostic child.hostChildTask result))
  writeIORef child.hostChildProcess Nothing
  settleChild host child (canonicalStageOutcome result)

-- | What a canonical child's terminal outcome is.
--
-- A refused or failed invocation is a failure of /this/ invocation and never
-- a verdict: an approved review and a changes-requested one both completed,
-- and the difference between them lives in the labels the backend moved and
-- the record journaled beside this, never in whether the worker succeeded.
-- Reporting "not approved" as a failed action is what would let a caller read
-- a legitimate changes-requested round as a broken one.
canonicalStageOutcome :: Either Text CanonicalIssueReviewResult -> SolveOutcome
canonicalStageOutcome (Left message) = SolveFailed message
canonicalStageOutcome (Right _) = SolveCompleted

-- | Records the canonical subprocess against the /child/ that spawned it.
--
-- Through the same census the solve and pull-request supervisors record
-- theirs through, which is what makes requirement 11's "settles its owned
-- provider process and descendants" true here without a second notion of
-- ownership: the identity and its descendant group land in this child's
-- 'workerStateKnownProcesses', and settling this child terminates exactly
-- that group.
recordCanonicalProcess :: IssueReviewHost -> HostChild -> ManagedProcess -> IO ()
recordCanonicalProcess host child process = do
  -- Installed first, then checked. Checking first and installing second is a
  -- read that a termination can win behind: the settle would find no process
  -- to kill and release the child, and this callback would then record a
  -- subprocess nothing is ever going to settle.
  --
  -- Installing first makes the two orderings exhaustive instead. Either the
  -- settle sees the process and kills it, or the settle ran before the
  -- install and this re-read sees the claim taken and kills it here. There is
  -- no interleaving in which neither does, and killing twice is harmless.
  recordLiveCanonicalProcess child process
  settled <- readIORef child.hostChildSettleClaim
  when settled $ do
    -- On the host, for the same reason the late thread is: the child's
    -- journal ended at its terminal envelope.
    hostDiagnostic host (lateCanonicalProcessDiagnostic <> " (issue #" <> Text.pack (show child.hostChildTask.issueActionIssueNumber) <> ")")
    writeIORef child.hostChildProcess Nothing
    interruptThenKillManagedProcess process

lateThreadDiagnostic :: Text
lateThreadDiagnostic = "the provider announced this action's thread after it had already been settled; the thread was closed"

-- | What a canonical result that arrived after its child was settled reads as
-- on the host's own journal.
lateCanonicalResultDiagnostic :: IssueActionWorkerTask -> Either Text CanonicalIssueReviewResult -> Text
lateCanonicalResultDiagnostic task result =
  "issue #"
    <> Text.pack (show task.issueActionIssueNumber)
    <> " was terminated while its canonical gate was running; the gate then reported: "
    <> either id reportedVerdict result
  where
    reportedVerdict reported
      | reported.canonicalReviewApproved = "approved"
      | otherwise = "changes requested"

unresumableActionDiagnostic :: Text
unresumableActionDiagnostic = "the review host that owned this action stopped before it finished; its provider session cannot be resumed"

lateCanonicalProcessDiagnostic :: Text
lateCanonicalProcessDiagnostic = "the canonical gate started after this action had already been settled; the subprocess was ended"

recordLiveCanonicalProcess :: HostChild -> ManagedProcess -> IO ()
recordLiveCanonicalProcess child process = do
  writeIORef child.hostChildProcess (Just process)
  processId <- managedProcessPid process
  forM_ processId $ \pid -> do
    recordProviderIdentity child.hostChildDescriptor child.hostChildState (fromIntegral pid)
    refreshProcessCensus child.hostChildDescriptor child.hostChildState
    updateChildState child $ \state ->
      state
        { workerStateProviderPid = Just (fromIntegral pid),
          workerStateStatus = runningUnlessSettled state.workerStateStatus,
          workerStateLastActivity = "running canonical gate"
        }

-- | An interactive revision.
--
-- Nothing is journaled from here: the turn's whole account arrives as
-- 'ReviewEvent's on the client's own reader thread and is routed to this
-- child there. Only a refusal — a preflight blocker, or a coordinator that
-- would not open the thread — is this call's to report, and it is reported as
-- the same 'ReviewStartFailed' the live dashboard has always shown.
runRevisionChild :: IssueReviewHost -> HostChild -> IO ()
runRevisionChild host child = do
  let task = child.hostChildTask
      spec = child.hostChildDescriptor.workerDescriptorSpec
  blocked <- preflightBlocker spec.workerRepository host.hostOperatingMode (issueActionPreflightAction IssueRevision task.issueActionOrigin)
  -- The client is started here, by the one stage that needs it, and only
  -- after this child's own preflight has passed.
  provider <- if isJust blocked then pure (Left "") else ensureHostProvider host
  result <- case (blocked, provider) of
    (Just message, _) -> pure (Left message)
    (Nothing, Left message) -> pure (Left message)
    (Nothing, Right connected) -> do
      -- Recorded before the call, because the provider announces the thread
      -- through the event sink and that announcement can arrive before this
      -- call has returned.
      recordPendingStart host child
      begun <- connected.providerBeginReview task.issueActionIssueNumber
      -- A process-per-thread backend spawns this thread's process during that
      -- call, so its identity is recorded now rather than at the next poll:
      -- a host killed in the gap would otherwise leak it with nothing durable
      -- naming it.
      registerProviderProcesses host
      pure begun
  case result of
    Left message -> do
      -- A start that failed will never be announced, so the pending start it
      -- recorded must not claim a later announcement for this issue.
      dropPendingStart host child
      journalChild child (WorkerReviewEvent (ReviewStartFailed task.issueActionIssueNumber message))
      settleChild host child (SolveFailed message)
    Right () -> updateChildState child (\state -> state {workerStateLastActivity = "starting coordinator"})

-- ---------------------------------------------------------------------------
-- Routing provider events to the child they belong to
-- ---------------------------------------------------------------------------

-- | Every review event this host's client produces, delivered to exactly one
-- child's journal — or to the host's own when it belongs to no child.
--
-- Routing by thread is what keeps siblings isolated under a shared connection
-- (requirement 12): two children multiplexed onto one process are told apart
-- by the thread each was given, never by the connection they share.
routeReviewEvent :: IssueReviewHost -> ReviewEvent -> IO ()
routeReviewEvent host event = case event of
  ReviewThreadCreated issueNumber threadId -> do
    found <- takePendingStart host issueNumber
    case found of
      Nothing -> hostDiagnostic host ("a review thread was created for issue #" <> Text.pack (show issueNumber) <> ", which this host holds no pending start for")
      Just child -> do
        settled <- readIORef child.hostChildSettleClaim
        unless settled (journalChild child (WorkerReviewEvent event))
        if settled
          then do
            -- The child asked for this thread and was settled before the
            -- provider announced it. Closing it here is the whole reason a
            -- settled child stays addressable: the alternative is a live
            -- provider thread — and, under a process-per-thread backend, a
            -- live process — that nothing owns and nothing will ever stop.
            --
            -- Recorded on the host rather than the child, because the child's
            -- journal ends at its terminal envelope and this happened after
            -- it. The host's log is where an operator finds what became of a
            -- thread that outlived the action that asked for it.
            hostDiagnostic host (lateThreadDiagnostic <> " (issue #" <> Text.pack (show issueNumber) <> ")")
            provider <- readMVar host.hostProvider
            forM_ provider (\connected -> connected.providerFinishThread threadId)
          else do
            updateChildState child $ \state ->
              state
                { workerStateReviewThread = Just threadId,
                  workerStateStatus = runningUnlessSettled state.workerStateStatus,
                  workerStateLastActivity = "session ready"
                }
            -- Registered here rather than left to the next poll. A
            -- process-per-thread backend spawns this thread's process in
            -- order to announce it, and a host killed in between would leave
            -- that process with no recorded identity for any recovery pass to
            -- verify or terminate.
            registerProviderProcesses host
  ReviewStartFailed issueNumber message -> do
    -- A start that failed is a start that will never be announced, so it is
    -- the one this issue is waiting on.
    found <- takePendingStart host issueNumber
    forM_ found $ \child -> do
      journalChild child (WorkerReviewEvent event)
      settleChild host child (SolveFailed message)
  -- Only a shared-process backend ever raises this, and it means the one
  -- connection every thread was on has ended. Every live child is finished,
  -- and each is settled in its own right with its own evidence intact.
  ReviewClientStopped message -> do
    live <- liveChildren host
    forM_ live $ \child -> do
      journalChild child (WorkerReviewEvent event)
      settleChild host child (SolveFailed message)
  -- One of several connections ended. Only the children it was serving are
  -- finished; a sibling on another connection is untouched.
  ReviewConnectionStopped connectionId message -> do
    affected <- childrenOnConnection host connectionId
    forM_ affected $ \child -> do
      journalChild child (WorkerReviewEvent event)
      settleChild host child (SolveFailed message)
  -- A protocol warning names a provider, not a thread: it is the client's own
  -- diagnostic about traffic it could not make sense of, so it belongs to the
  -- host that owns the client rather than to whichever child happens to be
  -- running.
  ReviewProtocolWarning _ _ -> journalHost host (WorkerReviewEvent event)
  _ -> case reviewEventThread event of
    Nothing -> journalHost host (WorkerReviewEvent event)
    Just threadId -> do
      found <- childOnThread host threadId
      case found of
        Nothing -> journalHost host (WorkerReviewEvent event)
        Just child -> applyThreadEvent host child event

-- | The thread an event happened on, where it happened on one.
--
-- Total over the vocabulary on purpose: a new event carrying a thread is a
-- compile error here rather than one silently journaled to the host and
-- invisible in the child it described.
reviewEventThread :: ReviewEvent -> Maybe ReviewThreadId
reviewEventThread event = case event of
  ReviewThreadCreated _ threadId -> Just threadId
  ReviewTurnStarted threadId _ -> Just threadId
  ReviewOutput threadId _ _ -> Just threadId
  ReviewQuestionRequested threadId _ _ -> Just threadId
  ReviewApprovalRequested threadId _ _ -> Just threadId
  ReviewClaudeStarted threadId _ -> Just threadId
  ReviewClaudeFinished threadId _ -> Just threadId
  ReviewGitHubStarted threadId _ -> Just threadId
  ReviewGitHubFinished threadId _ -> Just threadId
  ReviewTurnCompleted threadId _ _ _ -> Just threadId
  ReviewSteerUndelivered threadId _ _ -> Just threadId
  ReviewInterruptFailed threadId _ _ -> Just threadId
  ReviewStartFailed _ _ -> Nothing
  ReviewClientStopped _ -> Nothing
  ReviewConnectionStopped _ _ -> Nothing
  ReviewProtocolWarning _ _ -> Nothing

-- | Journal a thread's event and move the child's durable identifiers with it.
--
-- The three identifiers a command later needs — thread, turn, pending request
-- — are recorded here rather than derived at command time, because the
-- dashboard that submits a command may be a different process from the one
-- that saw the question asked (requirement 10).
applyThreadEvent :: IssueReviewHost -> HostChild -> ReviewEvent -> IO ()
applyThreadEvent host child event = do
  journalChild child (WorkerReviewEvent event)
  case event of
    ReviewTurnStarted _ turnId ->
      updateChildState child $ \state ->
        state
          { workerStateReviewTurn = Just turnId,
            workerStateReviewRequest = Nothing,
            workerStateStatus = runningUnlessSettled state.workerStateStatus,
            workerStateLastActivity = "thinking"
          }
    ReviewQuestionRequested _ requestId _ ->
      updateChildState child $ \state ->
        state {workerStateReviewRequest = Just requestId, workerStateLastActivity = "waiting for answer"}
    ReviewApprovalRequested _ requestId _ ->
      updateChildState child $ \state ->
        state {workerStateReviewRequest = Just requestId, workerStateLastActivity = "waiting for approval"}
    ReviewTurnCompleted _ outcome _ result -> do
      updateChildState child $ \state ->
        state {workerStateReviewTurn = Nothing, workerStateReviewRequest = Nothing}
      let stage = maybe child.hostChildTask.issueActionStage (reviewResultStage . snd) result
      case revisionTurnOutcome stage outcome (snd <$> result) of
        Nothing -> updateChildState child (\state -> state {workerStateLastActivity = "interrupted"})
        Just settled -> settleChild host child settled
    _ -> pure ()

-- | What a completed turn does to its child: 'Nothing' leaves it live and
-- resumable, 'Just' settles it.
--
-- 'reviewTurnResumable' is the one spelling of that rule, shared with the
-- overlay's own phase mapping, so a turn the dashboard still offers an input
-- line for is exactly a turn whose child is still here to receive it.
revisionTurnOutcome :: ReviewStage -> ReviewTurnOutcome -> Maybe ReviewResult -> Maybe SolveOutcome
revisionTurnOutcome stage outcome result
  | reviewTurnResumable stage outcome = Nothing
  | otherwise = Just $ case (outcome, result) of
      (TurnSucceeded, Just _) -> SolveCompleted
      (TurnSucceeded, Nothing) -> SolveFailed "the review turn completed without a result"
      (TurnFailed, _) -> SolveFailed "the review turn failed"
      (TurnInterrupted, _) -> SolveFailed "the review turn was interrupted"

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

-- | Apply what dashboards have left for each live child, oldest first, and
-- acknowledge every one.
applyPendingCommands :: IssueReviewHost -> IO ()
applyPendingCommands host = do
  live <- liveChildren host
  forM_ live $ \child -> do
    commands <- readReviewCommands child.hostChildDescriptor
    acknowledgements <- readReviewCommandAcknowledgements child.hostChildDescriptor
    let owed =
          [ command
            | command <- undeliveredReviewCommands commands acknowledgements,
              command.reviewCommandTarget == child.hostChildDescriptor.workerDescriptorSpec.workerId
          ]
    forM_ owed (deliverChildCommand host child)

-- | One command, claimed before it is applied and settled after.
--
-- The claim is what makes delivery exactly-once rather than at-least-once.
-- Applying first and recording after leaves a window in which a host that
-- died — or an acknowledgement write that simply failed — left the command
-- still owed, so the next pass sent the same steer to the same provider
-- thread a second time. Writing the claim first inverts the failure: a claim
-- that could not be written means nothing was applied and the command is
-- still owed, which is safe, and a claim that was written means the command
-- is never applied again whatever happens next.
--
-- A claim left standing is an attempt whose result was never observed. It is
-- reported as exactly that rather than guessed either way, which is the same
-- outcome-unknown discipline every other terminal path here follows.
deliverChildCommand :: IssueReviewHost -> HostChild -> ReviewCommand -> IO ()
deliverChildCommand host child command = do
  -- Asked again here, per command, rather than once for the batch. A
  -- termination settles the child part-way through a list this pass already
  -- snapshotted, and everything queued behind it is addressed to an action
  -- that no longer exists — under a shared connection, a feedback command
  -- read after that point would open a new turn on a thread the settle had
  -- finished with.
  settled <- readIORef child.hostChildSettleClaim
  if settled
    then do
      acknowledgement <- reviewCommandAcknowledgement command (ReviewCommandRejected settledActionReason)
      void (acknowledgeReviewCommand child.hostChildDescriptor acknowledgement)
    else deliverToLiveChild host child command

settledActionReason :: Text
settledActionReason = "this issue action has already ended"

deliverToLiveChild :: IssueReviewHost -> HostChild -> ReviewCommand -> IO ()
deliverToLiveChild host child command = do
  claim <- reviewCommandAcknowledgement command ReviewCommandClaimed
  claimed <- acknowledgeReviewCommand child.hostChildDescriptor claim
  case claimed of
    Left message ->
      -- Nothing was applied, and the command stays owed. Saying so is worth
      -- a journal line: a ledger that cannot be written is why an answer the
      -- user gave appears to go nowhere.
      journalChild child (WorkerDiagnostic ("a review command could not be claimed and was not applied: " <> message))
    Right () -> do
      -- A command that ends the child journals its line /before/ it is
      -- applied, because settling writes the child's terminal envelope and
      -- nothing may follow that: a monitor stops replaying there, so a later
      -- record is never seen at all — and one that is seen resurrects a
      -- session the terminal event had just settled. Its outcome is known in
      -- advance precisely because ending an action cannot be refused.
      let display = reviewCommandDisplay command.reviewCommandPayload
          endsChild = command.reviewCommandPayload == TerminateIssueAction
      when endsChild (journalChild child (WorkerReviewInput command.reviewCommandId display Nothing))
      outcome <- applyChildCommand host child command
      unless endsChild (journalChild child (WorkerReviewInput command.reviewCommandId display (rejectionReason outcome)))
      acknowledgement <- reviewCommandAcknowledgement command outcome
      settled <- acknowledgeReviewCommand child.hostChildDescriptor acknowledgement
      -- A final acknowledgement that will not write leaves the ledger holding
      -- only the claim. The command is still never re-applied — that is what
      -- the claim is for — and the journal entry just above is what lets the
      -- next host recover the real outcome instead of calling it unobserved,
      -- so this says so rather than passing silently.
      forM_ (either Just (const Nothing) settled) $ \message ->
        journalChild child (WorkerDiagnostic ("a review command's outcome could not be acknowledged: " <> message))

rejectionReason :: ReviewCommandOutcome -> Maybe Text
rejectionReason ReviewCommandAccepted = Nothing
rejectionReason ReviewCommandClaimed = Just unobservedCommandOutcome
rejectionReason ReviewCommandOutcomeUnknown = Just unobservedCommandOutcome
rejectionReason (ReviewCommandRejected message) = Just message

-- | One command, against the child it names.
--
-- Every arm checks the identity the command carries against what the child
-- currently holds before acting. A command written for a turn that has since
-- ended is rejected rather than retargeted at the turn running now: the user
-- meant the turn they were looking at, and silently moving it is worse than
-- saying it did not land.
applyChildCommand :: IssueReviewHost -> HostChild -> ReviewCommand -> IO ReviewCommandOutcome
applyChildCommand host child command = do
  provider <- readMVar host.hostProvider
  state <- readMVar child.hostChildState
  case command.reviewCommandPayload of
    -- Ending an action needs no provider. A backend that has gone is exactly
    -- when an operator most needs to be able to stop the action waiting on
    -- it, and refusing here would leave one nothing could settle.
    TerminateIssueAction -> do
      settleChild host child (SolveFailed "the issue action was terminated")
      pure ReviewCommandAccepted
    _ -> applyProviderCommand command provider state

-- | Every command that reaches the provider, which is all of them but the one
-- that ends the action.
applyProviderCommand :: ReviewCommand -> Maybe IssueHostProvider -> WorkerState -> IO ReviewCommandOutcome
applyProviderCommand command provider held =
  case provider of
    Nothing -> pure (ReviewCommandRejected "the review backend is not connected")
    -- Every command that acts on a thread is checked against the thread the
    -- child is actually on before any provider call. A command written for
    -- one thread and read after the child moved to another must not be
    -- retargeted: the user meant the turn they were looking at, and silently
    -- moving it is worse than saying it did not land.
    Just _ | Just refusal <- staleThread held command -> pure (ReviewCommandRejected refusal)
    Just connected -> case command.reviewCommandPayload of
      -- Handled by the caller, which reaches it without a provider.
      TerminateIssueAction -> pure ReviewCommandAccepted
      InterruptReviewTurn -> case (held.workerStateReviewThread, held.workerStateReviewTurn) of
        (Just threadId, Just turnId)
          | staleTurn command turnId -> pure (ReviewCommandRejected "that turn has already ended")
          | otherwise -> do
              -- Thread-scoped, exactly as the live dashboard's Ctrl-C is: the
              -- tool subprocesses this thread started, then the turn itself.
              -- The child stays live because an interrupted revision remains
              -- resumable.
              interrupted <- connected.providerInterruptTurn threadId turnId
              pure (childCommandOutcome interrupted)
        _ -> pure (ReviewCommandRejected "this action has no active turn to interrupt")
      AnswerReviewQuestion requestId answer _ ->
        requireRequest held requestId (connected.providerAnswerQuestion requestId answer)
      AnswerReviewApproval requestId accepted forSession _ ->
        requireRequest held requestId (connected.providerApproveAction requestId accepted forSession)
      SendReviewFeedback message -> sendOnThread connected held command message
      ResendReviewSteer message -> sendOnThread connected held command message
  where
    -- The turn as well as the thread. A message written to steer one turn and
    -- read after that turn ended would otherwise steer the next one, or —
    -- with no turn left — open a fresh turn carrying text meant to redirect a
    -- finished one. Requiring the two to agree covers both: a follow-up
    -- deliberately sent between turns carries no turn and is accepted only
    -- while the child holds none.
    sendOnThread connected onThread issued message = case onThread.workerStateReviewThread of
      Nothing -> pure (ReviewCommandRejected "this action has no provider thread to send to")
      Just threadId
        | issued.reviewCommandTurn /= onThread.workerStateReviewTurn ->
            pure (ReviewCommandRejected "that turn has already ended")
        | otherwise -> childCommandOutcome <$> connected.providerSendMessage threadId onThread.workerStateReviewTurn message
    -- The request the command answers has to be the one the child is actually
    -- waiting on. A question answered twice, or an answer racing the
    -- provider's own timeout, would otherwise be written against whatever
    -- request came next.
    requireRequest pending requestId action
      | pending.workerStateReviewRequest /= Just requestId =
          pure (ReviewCommandRejected "that review request is no longer pending")
      | otherwise = childCommandOutcome <$> action
    staleTurn issued turnId = maybe False (/= turnId) issued.reviewCommandTurn

-- | Whether a command names a thread other than the one its child is on.
--
-- Termination is the one command that names no thread and needs none: it ends
-- the child whichever thread it is on, and refusing it for a thread that
-- moved would leave an action nobody can stop.
--
-- Everything else is thread-scoped, so a command carrying no thread at all is
-- refused as firmly as one carrying the wrong thread. A dashboard only offers
-- these operations once a thread exists, so a command without one was written
-- against state this child has since left behind.
staleThread :: WorkerState -> ReviewCommand -> Maybe Text
staleThread state command = case command.reviewCommandPayload of
  TerminateIssueAction -> Nothing
  _ -> case (command.reviewCommandThread, state.workerStateReviewThread) of
    (_, Nothing) -> Just "this action has no provider thread to send to"
    (Nothing, Just _) -> Just "that command names no provider thread"
    (Just named, Just held)
      | named /= held -> Just "that provider thread has already ended"
      | otherwise -> Nothing

childCommandOutcome :: Either Text () -> ReviewCommandOutcome
childCommandOutcome (Left message) = ReviewCommandRejected message
childCommandOutcome (Right ()) = ReviewCommandAccepted

-- ---------------------------------------------------------------------------
-- Bounds and settling
-- ---------------------------------------------------------------------------

-- | Each child against its own bound, and nothing against the host's.
--
-- The persistent-worker deadline is per action here, measured from the
-- action's own creation exactly as it is for a solve or a pull request. A
-- host-level bound would settle a child still inside its own and, under a
-- shared connection, take every sibling with it.
enforceChildBounds :: IssueReviewHost -> IO ()
enforceChildBounds host = do
  live <- liveChildren host
  now <- getCurrentTime
  forM_ live $ \child -> do
    let spec = child.hostChildDescriptor.workerDescriptorSpec
        deadline = addUTCTime (fromIntegral spec.workerMaxRuntimeSeconds) spec.workerCreatedAt
    when (now >= deadline) (settleChild host child (SolveFailed issueActionDeadlineReason))

issueActionDeadlineReason :: Text
issueActionDeadlineReason = "persistent worker deadline exceeded"

-- | Settle one child, once.
--
-- Child-scoped throughout, which is the whole of requirement 11. It stops the
-- stage thread this child owns, settles the canonical subprocess this child
-- spawned, finishes this child's provider thread — which under
-- 'ProcessPerThread' is that thread's own process and under 'SharedProcess' is
-- only its tool descendants — writes this child's terminal state and terminal
-- envelope, and releases this child's lease. It touches no sibling, no host
-- record, and never the client.
settleChild :: IssueReviewHost -> HostChild -> SolveOutcome -> IO ()
settleChild host child outcome = do
  claimed <- atomicModifyIORef' child.hostChildSettleClaim (\settled -> (True, not settled))
  when claimed $ do
    provider <- readMVar host.hostProvider
    state <- readMVar child.hostChildState
    forM_ state.workerStateReviewThread $ \threadId ->
      forM_ provider (\connected -> connected.providerFinishThread threadId)
    readIORef child.hostChildProcess >>= mapM_ interruptThenKillManagedProcess
    -- The canonical subprocess's own descendants, verified against this
    -- child's recorded census. A @gh@ or @python3@ the gate started outlives
    -- the process that spawned it otherwise.
    terminateRecordedProcesses child.hostChildState
    updateChildState child $ \current ->
      current
        { workerStateStatus = WorkerTerminal outcome,
          workerStateProviderPid = Nothing,
          workerStateProviderIdentity = Nothing,
          -- The thread goes with the turn. A settled child holding a thread
          -- still reads as addressable to every thread-scoped check, which is
          -- what let a command queued behind a termination pass one.
          workerStateReviewThread = Nothing,
          workerStateReviewTurn = Nothing,
          workerStateReviewRequest = Nothing,
          workerStateLastActivity = terminalActivity outcome
        }
    journalChildTerminal child (WorkerFinished outcome)
    releaseWorkerLease child.hostChildDescriptor
    -- Retired first, live entry removed second. The two maps are separate
    -- cells, so a lookup landing between the updates sees whichever order
    -- they happen in — and in this order that is "both", never "neither". The
    -- other order leaves a window in which an announcement for this action
    -- resolves to nothing and its thread is never closed, which is the whole
    -- thing retirement exists to prevent. Finding the live entry in that
    -- window is harmless: the settle claim is already taken, so every reader
    -- takes the settled branch.
    modifyMVar_ host.hostRetired (pure . Map.insert child.hostChildDescriptor.workerDescriptorSpec.workerId child)
    modifyMVar_ host.hostChildren (pure . Map.delete child.hostChildDescriptor.workerDescriptorSpec.workerId)
    -- Last, and from outside the thread being stopped: a stage thread that
    -- reached here itself would otherwise kill itself before its own journal
    -- write landed.
    void . forkIO $ readIORef child.hostChildStageThread >>= mapM_ killThread

terminalActivity :: SolveOutcome -> Text
terminalActivity SolveCompleted = "completed"
terminalActivity (SolveNeedsInput _) = "waiting for input"
terminalActivity (SolveFailed _) = "failed"

-- | Never revert a settled child to running. A provider event can arrive
-- after a termination command has already committed this child's outcome, and
-- the outcome that was committed is the authoritative one.
runningUnlessSettled :: WorkerStatus -> WorkerStatus
runningUnlessSettled (WorkerTerminal outcome) = WorkerTerminal outcome
runningUnlessSettled (WorkerOrphaned outcome) = WorkerOrphaned outcome
runningUnlessSettled _ = WorkerRunning

-- ---------------------------------------------------------------------------
-- Child lookup and record keeping
-- ---------------------------------------------------------------------------

-- | Records that this child has asked the provider for a thread.
recordPendingStart :: IssueReviewHost -> HostChild -> IO ()
recordPendingStart host child =
  modifyMVar_ host.hostPendingStarts $ \pending ->
    pure (Map.insertWith (flip (<>)) issueNumber [identifier] pending)
  where
    issueNumber = child.hostChildTask.issueActionIssueNumber
    identifier = child.hostChildDescriptor.workerDescriptorSpec.workerId

-- | Forgets a start that will never be announced.
dropPendingStart :: IssueReviewHost -> HostChild -> IO ()
dropPendingStart host child =
  modifyMVar_ host.hostPendingStarts $ \pending ->
    pure (Map.adjust (filter (/= identifier)) child.hostChildTask.issueActionIssueNumber pending)
  where
    identifier = child.hostChildDescriptor.workerDescriptorSpec.workerId

-- | The child an announcement for this issue belongs to: the oldest start
-- still waiting, live or already settled.
--
-- Nothing rather than whichever child currently holds the issue. A thread
-- announced with no start waiting for it is a thread this host did not ask
-- for, and attaching it to an unrelated action is exactly the misrouting this
-- correlation exists to prevent — a settled action's thread taking its
-- replacement's commands, and never being closed.
takePendingStart :: IssueReviewHost -> Int -> IO (Maybe HostChild)
takePendingStart host issueNumber = do
  claimed <- modifyMVar host.hostPendingStarts $ \pending -> case Map.lookup issueNumber pending of
    Just (oldest : remaining) -> pure (Map.insert issueNumber remaining pending, Just oldest)
    _ -> pure (pending, Nothing)
  case claimed of
    Nothing -> pure Nothing
    Just identifier -> do
      live <- readMVar host.hostChildren
      case Map.lookup identifier live of
        Just child -> pure (Just child)
        Nothing -> Map.lookup identifier <$> readMVar host.hostRetired

liveChildren :: IssueReviewHost -> IO [HostChild]
liveChildren host = Map.elems <$> readMVar host.hostChildren

childOnThread :: IssueReviewHost -> ReviewThreadId -> IO (Maybe HostChild)
childOnThread host threadId = do
  live <- liveChildren host
  matches <- mapM (childHoldsThread threadId) live
  pure (fst <$> find snd (zip live matches))

childrenOnConnection :: IssueReviewHost -> ConnectionId -> IO [HostChild]
childrenOnConnection host connectionId = do
  live <- liveChildren host
  states <- mapM (readMVar . (.hostChildState)) live
  pure [child | (child, state) <- zip live states, onConnection state]
  where
    onConnection state = case state.workerStateReviewThread of
      Just threadId -> threadId.reviewThreadConnection == connectionId
      Nothing -> False

childHoldsThread :: ReviewThreadId -> HostChild -> IO Bool
childHoldsThread threadId child = do
  state <- readMVar child.hostChildState
  pure (state.workerStateReviewThread == Just threadId)

-- | Records one event in this child's durable evidence: its event journal,
-- and its own raw log.
--
-- Both, because they answer different questions. The journal is what a
-- dashboard replays to rebuild the overlay; the raw log is the provider
-- traffic an operator reads when they want to know what the provider actually
-- said, and it is this child's share of it rather than the whole client's.
journalChild :: HostChild -> WorkerEvent -> IO ()
journalChild child = void . journalChildRecord child

-- | Records one event, reporting whether the journal was still open.
--
-- 'False' is a write refused because this child's terminal envelope has
-- already been written. The caller decides what to do about it; most have
-- nothing to say, and the one that does — a canonical result that finished
-- while a termination was settling — reports it on the host's own journal
-- instead, where it is evidence without being replay.
journalChildRecord :: HostChild -> WorkerEvent -> IO Bool
journalChildRecord child event =
  modifyMVar child.hostChildJournalGate $ \closed -> do
    unless closed (writeChildRecord child event)
    pure (closed, not closed)

-- | The terminal envelope, and the closure of the journal, as one step.
--
-- Under the same lock so no write can slip between them: a concurrent
-- 'journalChildRecord' either lands entirely before this or is refused.
journalChildTerminal :: HostChild -> WorkerEvent -> IO ()
journalChildTerminal child event =
  modifyMVar_ child.hostChildJournalGate $ \closed -> do
    unless closed (writeChildRecord child event)
    pure True

writeChildRecord :: HostChild -> WorkerEvent -> IO ()
writeChildRecord child event = do
  appendWorkerEvent child.hostChildDescriptor child.hostChildJournal event
  -- Best-effort, and deliberately so. The event journal above is the evidence
  -- a replay needs; the raw log is what an operator reads afterwards. A log
  -- that cannot be written — a full disk, a handle closed by a shutdown
  -- racing a late event — is a hygiene failure, and letting it propagate
  -- would take down the host serving every other action for it.
  forM_ child.hostChildLog $ \sessionLog ->
    void (try @IOException (logRawLine sessionLog "provider" (LazyByteString.toStrict (encode event))))

journalHost :: IssueReviewHost -> WorkerEvent -> IO ()
journalHost host = host.hostEmit

hostDiagnostic :: IssueReviewHost -> Text -> IO ()
hostDiagnostic host = host.hostEmit . WorkerDiagnostic

updateChildState :: HostChild -> (WorkerState -> WorkerState) -> IO ()
updateChildState child transform = do
  now <- getCurrentTime
  modifyMVar_ child.hostChildState $ \state -> do
    let updated = (transform state) {workerStateHeartbeatAt = now}
    writeState child.hostChildDescriptor updated
    pure updated

persistChild :: HostChild -> IO ()
persistChild child = readMVar child.hostChildState >>= writeState child.hostChildDescriptor

-- | Registers each of the client's processes with this host's supervisor
-- exactly once.
--
-- Polled rather than done at startup because a process-per-thread backend
-- spawns a process per review thread, so the set grows as children arrive.
-- Each registration records that process's identity and refreshes the census,
-- and the census retains what earlier registrations recorded — which is what
-- accumulates the whole set rather than replacing it.
registerProviderProcesses :: IssueReviewHost -> IO ()
registerProviderProcesses host = do
  provider <- readMVar host.hostProvider
  forM_ provider $ \connected -> connected.providerProcesses >>= mapM_ (registerHostProcess host)

-- | The embedded review client, started the first time something needs one.
--
-- Under the cell's own lock, so two revisions adopted in one poll start one
-- client between them rather than two. Only a success is cached: a start that
-- failed is worth trying again for the next revision, since what stopped it
-- may have been transient.
ensureHostProvider :: IssueReviewHost -> IO (Either Text IssueHostProvider)
ensureHostProvider host = modifyMVar host.hostProvider $ \held -> case held of
  Just provider -> pure (Just provider, Right provider)
  Nothing -> do
    started <- host.hostStartProvider host.hostSpec (registerHostProcess host) (routeReviewEvent host)
    case started of
      Left message -> pure (Nothing, Left message)
      Right provider -> do
        forM_ provider.providerLogPath (host.hostEmit . WorkerLogOpened)
        pure (Just provider, Right provider)

-- | Registers one provider process with this host's supervisor, once.
--
-- The client calls this as it creates each connection, which is the only
-- moment with no window: registering after the spawn returned, or at the
-- host's next poll, leaves an interval in which the process is running and
-- nothing durable names it. The poll still sweeps, as a backstop for anything
-- the client created before this host had a provider to ask.
--
-- Idempotent by pid, because both callers reach the same processes and
-- registering one twice would replace the recorded provider identity with
-- itself for no reason.
registerHostProcess :: IssueReviewHost -> ManagedProcess -> IO ()
registerHostProcess host process = do
  processId <- managedProcessPid process
  forM_ processId $ \pid -> do
    fresh <- atomicModifyIORef' host.hostRegisteredProcesses $ \known ->
      if fromIntegral pid `elem` known then (known, False) else (fromIntegral pid : known, True)
    when fresh (host.hostRememberProvider process)

-- | Closes every child's raw log, live and retired alike.
closeChildLogs :: IssueReviewHost -> IO ()
closeChildLogs host = do
  live <- liveChildren host
  settled <- Map.elems <$> readMVar host.hostRetired
  forM_ (live <> settled) $ \child ->
    forM_ child.hostChildLog (void . try @IOException . closeSessionLog)

-- | Keeps every live child's heartbeat fresh.
--
-- A child waiting on an answer produces no events at all, and a heartbeat
-- that only moved with events would let exactly the children requirement 10
-- protects — the ones holding a pending question across a dashboard restart —
-- age into looking abandoned.
refreshChildHeartbeats :: IssueReviewHost -> IO ()
refreshChildHeartbeats host = liveChildren host >>= mapM_ (\child -> updateChildState child id)
