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
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Kanban.ApprovalService (ApprovalController, ApprovalUnavailable, discoverApprovalController)
import Kanban.Cache (normalizedRepositoryIdentity)
import Kanban.Models (OperatingMode, loadModelRoster, loadedOperatingMode)
import Kanban.Preflight (IssueOrigin, PreflightAction (..), preflightBlocker)
import Kanban.Process (ManagedProcess, ProcessIdentity, identityForPid, interruptThenKillManagedProcess, managedProcessPid, readProcessSnapshot)
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
    reviewCommandAcknowledgement,
    reviewCommandPayloadSummary,
    undeliveredReviewCommands,
  )
import Kanban.Worker.Discovery (discoverWorkerHistory)
import Kanban.Worker.Journal (EventJournalLock, appendWorkerEvent, newEventJournalLock)
import Kanban.Worker.Lease (releaseWorkerLease)
import Kanban.Worker.Paths (descriptorForSpec, readWorkerState, writeState)
import Kanban.Worker.Types
  ( IssueActionWorkerTask (..),
    WorkerDescriptor (..),
    WorkerEvent (..),
    WorkerId (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    issueActionTask,
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
    -- | Children this host has settled, kept addressable by issue number.
    --
    -- A child is settled the instant a termination command, a deadline, or a
    -- dead connection says so, and that can be before the provider has
    -- finished creating the thread the child asked for. The creation is
    -- announced asynchronously, so the announcement can arrive after the
    -- child has left 'hostChildren' entirely — and a thread nobody owns is a
    -- thread nobody closes.
    --
    -- Retained for the host's whole life rather than expired: the set is
    -- bounded by the actions one host serves, and the alternative is a second
    -- timer whose expiry is exactly the race it was added to close.
    hostRetired :: MVar (Map Int HostChild),
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
    hostProvider :: MVar (Maybe IssueHostProvider),
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
runIssueReviewHost = runIssueReviewHostWith defaultIssueHostTuning startEmbeddedProvider
  where
    startEmbeddedProvider spec sink = do
      rosterResult <- loadModelRoster
      case rosterResult of
        -- The roster is what 'startReviewClient' resolves the embedded
        -- backend's cell from, so a roster that will not load is the
        -- backend's own failure surface rather than a routing decision made
        -- here.
        Left _ -> pure (Left "the model roster could not be loaded, so no review backend could be started")
        Right roster ->
          fmap embeddedIssueHostProvider
            <$> startReviewClient roster spec.workerWorkflowConfig spec.workerRepository sink

runIssueReviewHostWith ::
  IssueHostTuning ->
  (WorkerSpec -> (ReviewEvent -> IO ()) -> IO (Either Text IssueHostProvider)) ->
  WorkerSpec ->
  (ManagedProcess -> IO ()) ->
  (WorkerEvent -> IO ()) ->
  IO ()
runIssueReviewHostWith tuning startProvider spec rememberProvider emit = do
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
            hostRememberProvider = rememberProvider,
            hostRegisteredProcesses = registered,
            hostApprovalController = controller,
            hostRepositoryIdentity = normalizedRepositoryIdentity spec.workerRepository,
            hostOperatingMode = loadedOperatingMode rosterResult,
            hostPid = pid,
            hostProcessIdentity = either (const Nothing) (identityForPid pid) snapshot,
            hostStopped = stopped
          }
  emit (WorkerDiagnostic "starting the repository review host")
  started <- startProvider spec (routeReviewEvent host)
  case started of
    Left message -> finishHost host (SolveFailed message)
    Right provider -> do
      modifyMVar_ providerCell (pure . const (Just provider))
      -- Deliberately not 'WorkerProviderStarted' with this host's own pid.
      -- The host is not a provider turn, and a recorded provider pid with no
      -- recorded identity is precisely the shape every termination path reads
      -- as "started, but unverifiable" — which leaves a host kill recording a
      -- pending termination it can never complete. What the host does record
      -- is its client's actual processes, below, each through the supervisor's
      -- own registration so they are identified, censused, and killable.
      emit (WorkerDiagnostic ("repository review host running as pid " <> Text.pack (show pid)))
      forM_ provider.providerLogPath (emit . WorkerLogOpened)
      now <- getCurrentTime
      -- The loop's own failure is a terminal outcome for the host, not a
      -- silent death. A host thread that simply ended would leave every child
      -- it was serving recorded as running under a process that is gone, with
      -- nothing saying why — which is the hardest state for a later dashboard
      -- to make sense of and the one this layer exists to avoid.
      looped <- try @SomeException (hostLoop host now)
      let outcome = either (SolveFailed . ("the repository review host failed: " <>) . Text.pack . show) id looped
      provider.providerStop
      -- Every child's raw log is closed here rather than when that child
      -- settled. A settled child can still receive a late thread
      -- announcement, and that is evidence worth keeping; closing at settle
      -- would throw it away and, worse, leave a closed handle for the very
      -- write that records it.
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
  forM_ candidates $ \(descriptor, task) ->
    unless (Map.member descriptor.workerDescriptorSpec.workerId held) $ do
      stateResult <- readWorkerState descriptor
      case stateResult of
        Right state | terminalStatus state.workerStateStatus -> pure ()
        _ -> adoptChild host descriptor task

-- | Whether this host may run this child.
--
-- Naming this host is the ordinary claim, and the only one that reaches a
-- child another host is already serving (requirement 16).
--
-- The second arm is recovery, and it is needed because host selection and
-- child admission cannot be made atomic from the launch side: a dispatch
-- reads a live host, and that host can reach its idle grace and exit before
-- the child's specification is written. The child then names a host that has
-- terminated, and under the first arm alone it would sit unadopted until
-- stale recovery — an action the operator started that simply never runs.
--
-- So a host also adopts a child whose named host is provably finished and
-- which no host has ever adopted. Both halves are load-bearing. "Provably
-- finished" excludes a live host's children, so this can never steal one; a
-- host record that will not decode is not proof and is left alone. "Never
-- adopted" means still starting, with no thread and no provider recorded —
-- an action that has done nothing yet, so re-homing it repeats nothing and
-- loses nothing.
childCandidate :: IssueReviewHost -> WorkerDescriptor -> IO (Maybe (WorkerDescriptor, IssueActionWorkerTask))
childCandidate host descriptor = case issueActionTask descriptor.workerDescriptorSpec.workerTask of
  Nothing -> pure Nothing
  Just task
    | task.issueActionHost == host.hostSpec.workerId -> pure (Just (descriptor, task))
    | otherwise -> do
        orphaned <- namedHostFinished host task.issueActionHost
        untouched <- neverAdopted descriptor
        pure (if orphaned && untouched then Just (descriptor, task) else Nothing)

-- | Whether the host a child names has provably finished.
--
-- Fails closed in both directions: a host whose record cannot be found or
-- cannot be read is not proven finished, and its children are left to it.
namedHostFinished :: IssueReviewHost -> WorkerId -> IO Bool
namedHostFinished host named = do
  history <- discoverWorkerHistory host.hostSpec.workerRepository
  case find ((== named) . (.workerId) . (.workerDescriptorSpec)) history of
    Nothing -> pure True
    Just descriptor -> do
      stateResult <- readWorkerState descriptor
      pure $ case stateResult of
        Right state -> terminalStatus state.workerStateStatus
        Left _ -> False

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

adoptChild :: IssueReviewHost -> WorkerDescriptor -> IssueActionWorkerTask -> IO ()
adoptChild host descriptor task = do
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
  settleClaim <- newIORef False
  let child =
        HostChild
          { hostChildDescriptor = descriptor,
            hostChildTask = task,
            hostChildJournal = journal,
            hostChildLog = rawLog,
            hostChildState = stateCell,
            hostChildStageThread = stageThread,
            hostChildProcess = process,
            hostChildSettleClaim = settleClaim
          }
  modifyMVar_ host.hostChildren (pure . Map.insert descriptor.workerDescriptorSpec.workerId child)
  persistChild child
  journalChild child (WorkerDiagnostic (adoptionDiagnostic task))
  threadId <- forkIO (runChildStage host child)
  writeIORef stageThread (Just threadId)

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
  result <-
    canonicalLaunchOutcome
      stage
      host.hostRepositoryIdentity
      host.hostApprovalController
      (preflightBlocker spec.workerRepository host.hostOperatingMode (issueActionPreflightAction stage task.issueActionOrigin))
      ( runCanonicalIssueReview
          spec.workerConfigPath
          spec.workerRepository
          task.issueActionIssueNumber
          stage
          (recordCanonicalProcess child)
      )
  journalChild child (WorkerCanonicalReviewFinished stage result)
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
recordCanonicalProcess :: HostChild -> ManagedProcess -> IO ()
recordCanonicalProcess child process = do
  -- The canonical spawn is the same race the late thread announcement is: a
  -- termination between the interlock and the process existing would leave a
  -- gate subprocess running under a child that is already terminal. Settling
  -- first means this claim is already taken, and the process is ended here
  -- rather than recorded onto a child nothing will settle again.
  alreadySettled <- readIORef child.hostChildSettleClaim
  if alreadySettled
    then do
      journalChild child (WorkerDiagnostic lateCanonicalProcessDiagnostic)
      interruptThenKillManagedProcess process
    else recordLiveCanonicalProcess child process

lateThreadDiagnostic :: Text
lateThreadDiagnostic = "the provider announced this action's thread after it had already been settled; the thread was closed"

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
  provider <- readMVar host.hostProvider
  result <- case (blocked, provider) of
    (Just message, _) -> pure (Left message)
    (Nothing, Nothing) -> pure (Left "the review backend is not connected")
    (Nothing, Just connected) -> do
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
        journalChild child (WorkerReviewEvent event)
        settled <- readIORef child.hostChildSettleClaim
        if settled
          then do
            -- The child asked for this thread and was settled before the
            -- provider announced it. Closing it here is the whole reason a
            -- settled child stays addressable: the alternative is a live
            -- provider thread — and, under a process-per-thread backend, a
            -- live process — that nothing owns and nothing will ever stop.
            journalChild child (WorkerDiagnostic lateThreadDiagnostic)
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
  claim <- reviewCommandAcknowledgement command ReviewCommandClaimed
  claimed <- acknowledgeReviewCommand child.hostChildDescriptor claim
  case claimed of
    Left message ->
      -- Nothing was applied, and the command stays owed. Saying so is worth
      -- a journal line: a ledger that cannot be written is why an answer the
      -- user gave appears to go nowhere.
      journalChild child (WorkerDiagnostic ("a review command could not be claimed and was not applied: " <> message))
    Right () -> do
      outcome <- applyChildCommand host child command
      journalChild child (WorkerReviewInput (commandDisplay command.reviewCommandPayload) (rejectionReason outcome))
      acknowledgement <- reviewCommandAcknowledgement command outcome
      void (acknowledgeReviewCommand child.hostChildDescriptor acknowledgement)

-- | What the overlay showed for a command, which is what its transcript entry
-- reads. The three payloads a person types or chooses carry their own display
-- text; the two that are gestures rather than words are named by the
-- vocabulary's own summary.
commandDisplay :: ReviewCommandPayload -> Text
commandDisplay payload = case payload of
  AnswerReviewQuestion _ _ display -> display
  AnswerReviewApproval _ _ _ display -> display
  SendReviewFeedback message -> message
  ResendReviewSteer message -> message
  InterruptReviewTurn -> reviewCommandPayloadSummary InterruptReviewTurn
  TerminateIssueAction -> reviewCommandPayloadSummary TerminateIssueAction

rejectionReason :: ReviewCommandOutcome -> Maybe Text
rejectionReason ReviewCommandAccepted = Nothing
rejectionReason ReviewCommandClaimed = Just "the outcome of this command was never observed"
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
  case provider of
    Nothing -> pure (ReviewCommandRejected "the review backend is not connected")
    -- Every command that acts on a thread is checked against the thread the
    -- child is actually on before any provider call. A command written for
    -- one thread and read after the child moved to another must not be
    -- retargeted: the user meant the turn they were looking at, and silently
    -- moving it is worse than saying it did not land.
    Just _ | Just refusal <- staleThread state command -> pure (ReviewCommandRejected refusal)
    Just connected -> case command.reviewCommandPayload of
      TerminateIssueAction -> do
        settleChild host child (SolveFailed "the issue action was terminated")
        pure ReviewCommandAccepted
      InterruptReviewTurn -> case (state.workerStateReviewThread, state.workerStateReviewTurn) of
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
        requireRequest state requestId (connected.providerAnswerQuestion requestId answer)
      AnswerReviewApproval requestId accepted forSession _ ->
        requireRequest state requestId (connected.providerApproveAction requestId accepted forSession)
      SendReviewFeedback message -> sendOnThread connected state message
      ResendReviewSteer message -> sendOnThread connected state message
  where
    sendOnThread connected state message = case state.workerStateReviewThread of
      Nothing -> pure (ReviewCommandRejected "this action has no provider thread to send to")
      Just threadId -> childCommandOutcome <$> connected.providerSendMessage threadId state.workerStateReviewTurn message
    -- The request the command answers has to be the one the child is actually
    -- waiting on. A question answered twice, or an answer racing the
    -- provider's own timeout, would otherwise be written against whatever
    -- request came next.
    requireRequest state requestId action
      | state.workerStateReviewRequest /= Just requestId =
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
          workerStateReviewTurn = Nothing,
          workerStateReviewRequest = Nothing,
          workerStateLastActivity = terminalActivity outcome
        }
    journalChild child (WorkerFinished outcome)
    releaseWorkerLease child.hostChildDescriptor
    modifyMVar_ host.hostChildren (pure . Map.delete child.hostChildDescriptor.workerDescriptorSpec.workerId)
    -- Out of the live map and into the retired one in the same step, so a
    -- thread or process the provider is still creating for this child has
    -- somewhere to be closed against.
    modifyMVar_ host.hostRetired (pure . Map.insert child.hostChildTask.issueActionIssueNumber child)
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
        Nothing -> do
          settled <- readMVar host.hostRetired
          pure (find ((== identifier) . (.workerId) . (.workerDescriptorSpec) . (.hostChildDescriptor)) (Map.elems settled))

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
journalChild child event = do
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
  forM_ provider $ \connected -> do
    processes <- connected.providerProcesses
    forM_ processes $ \process -> do
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
