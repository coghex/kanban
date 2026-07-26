-- | The second half of the @managed agent processes@ group: the deadline
-- watchdog.
module Spec.Agent.ManagedProcess.Deadline (examples) where

import Control.Concurrent
  ( forkIO,
    newEmptyMVar,
    newMVar,
    putMVar,
    readMVar,
    takeMVar,
    threadDelay
  )
import Control.Exception (SomeException, finally, throwIO, try, uninterruptibleMask_)
import Control.Monad (void, when)
import Data.Aeson (eitherDecode, encode)
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find, findIndex, findIndices)
import Data.Maybe (isJust)
import qualified Data.Text
import Data.Time (addUTCTime, getCurrentTime)
import Kanban.Domain
import Kanban.Process
  ( ProcessIdentity (..),
    descendantProcesses,
    identityForPid,
    managedProcessPid,
    readProcessSnapshot
  )
import Kanban.Solve
  ( ResumeProvenance (..),
    SolveOutcome (..),
    SolveWorkflow (..),
    SolverBrand (..),
    unknownNoticeSamples
  )
import Kanban.Worker
  ( ProviderSlot (..),
    SolveWorkerTask (..),
    WorkerEvent (..),
    WorkerDescriptor (..),
    WorkerId (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    WorkerTask (..),
    acquireWorkerLease,
    discoverWorkerHistory,
    runWorker,
    runWorkerWithTask,
    spawnDetachedSupervisor,
    terminateProviderRefWith,
    terminateRecordedStateProcessesWith,
    waitForOrphanResolution,
    workerDeadlineReason
  )
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Expect (requireJust, requireLeft)
import Spec.Support.Process
  ( admitTelemetry,
    chattyProviderLines,
    deadlineFixtureSpec,
    detachedEscapedDescendantCommand,
    isOrphaned,
    isTerminal,
    managedProcessFor,
    waitForWorkerState,
    withManagedShell
  )
import System.Directory (createDirectory, createDirectoryIfMissing, doesDirectoryExist)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Posix.Signals (sigKILL, signalProcessGroup)
import System.Process (waitForProcess)
import System.Timeout (timeout)
import Test.Hspec

examples :: Spec
examples = do
    it "fires the deadline immediately for an already-overdue workerCreatedAt rather than waiting out a fresh runtime window" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            longAgo = addUTCTime (-3600) now
            spec = deadlineFixtureSpec repository (WorkerId "solve-810-overdue") 810 longAgo 60
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-810-overdue.spec.json"
            statePath = workerRoot </> "solve-810-overdue.state.json"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile specPath (encode spec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
            Nothing -> expectationFailure "worker fixture was not discoverable"
            Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
          let stallForever _spec _aggregator _rememberProvider _emit = threadDelay (120 * 1000000)
          result <- timeout 5000000 (runWorkerWithTask readProcessSnapshot stallForever specPath)
          result `shouldBe` Just (Right ())
          terminalState <- waitForWorkerState statePath isTerminal 10
          terminalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)

    it "still fires the deadline outcome for an already-overdue workerCreatedAt when the task itself finishes immediately" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            longAgo = addUTCTime (-3600) now
            spec = deadlineFixtureSpec repository (WorkerId "solve-810b-overdue-fast") 8102 longAgo 60
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-810b-overdue-fast.spec.json"
            statePath = workerRoot </> "solve-810b-overdue-fast.state.json"
            eventPath = workerRoot </> "solve-810b-overdue-fast.events.jsonl"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile specPath (encode spec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
            Nothing -> expectationFailure "worker fixture was not discoverable"
            Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
          -- The task reports success essentially instantly, well before the
          -- zero-delay watchdog thread is even guaranteed to have had its
          -- first chance to run: thread-scheduling order has no relationship
          -- to wall-clock deadline elapsed-ness, so a task finishing this
          -- fast must not be able to claim a normal outcome ahead of an
          -- already-overdue deadline just because it got scheduled first.
          let finishInstantly _spec _aggregator _rememberProvider emit = emit (WorkerFinished SolveCompleted)
          result <- timeout 5000000 (runWorkerWithTask readProcessSnapshot finishInstantly specPath)
          result `shouldBe` Just (Right ())
          terminalState <- waitForWorkerState statePath isTerminal 10
          terminalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
          eventBytes <- ByteString.readFile eventPath
          eventBytes `shouldNotSatisfy` ByteString.isInfixOf "SolveCompleted"

    it "cancels a task stalled before any provider registers once the deadline fires, releasing the lease promptly" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec = deadlineFixtureSpec repository (WorkerId "solve-811-pre-provider") 811 now 1
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-811-pre-provider.spec.json"
            statePath = workerRoot </> "solve-811-pre-provider.state.json"
            leasePath = workerRoot </> "issue-811.lease"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile specPath (encode spec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
            Nothing -> expectationFailure "worker fixture was not discoverable"
            Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
          let hangForever _spec _aggregator _rememberProvider _emit = threadDelay (300 * 1000000)
          finished <- newEmptyMVar
          void . forkIO $ runWorkerWithTask readProcessSnapshot hangForever specPath >>= putMVar finished
          timeout 5000000 (takeMVar finished) `shouldReturn` Just (Right ())
          terminalState <- waitForWorkerState statePath isTerminal 10
          terminalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
          leaseReleased <- doesDirectoryExist leasePath
          leaseReleased `shouldBe` False

    it "journals the unknown-event aggregate summary before the terminal envelope when the deadline cancels the task" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- A deadline emits the terminal envelope from the watchdog thread
        -- and then cancels the task outright, so the task can neither run
        -- its own flush first nor be trusted to run one at all. The
        -- aggregator is the supervisor's for exactly this reason: replay
        -- stops at the terminal envelope, so a summary written after it —
        -- or lost with the cancelled thread — is a suppressed count nobody
        -- ever sees.
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec = deadlineFixtureSpec repository (WorkerId "solve-813-deadline-aggregate") 813 now 1
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-813-deadline-aggregate.spec.json"
            statePath = workerRoot </> "solve-813-deadline-aggregate.state.json"
            eventPath = workerRoot </> "solve-813-deadline-aggregate.events.jsonl"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile specPath (encode spec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
            Nothing -> expectationFailure "worker fixture was not discoverable"
            Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
          -- Streams enough repeats of one unknown type to leave suppressed
          -- occupancy in the shared aggregator, then hangs so the deadline
          -- is what ends it.
          let chattyThenHang _spec aggregator _rememberProvider emit = do
                admitTelemetry aggregator emit chattyProviderLines
                threadDelay (300 * 1000000)
          finished <- newEmptyMVar
          void . forkIO $ runWorkerWithTask readProcessSnapshot chattyThenHang specPath >>= putMVar finished
          timeout 10000000 (takeMVar finished) `shouldReturn` Just (Right ())
          terminalState <- waitForWorkerState statePath isTerminal 10
          terminalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
          journal <- ByteString.lines <$> ByteString.readFile eventPath
          let noticeIndices = findIndices (ByteString.isInfixOf "[event] telemetry") journal
              terminalIndex = findIndex (ByteString.isInfixOf "WorkerFinished") journal
          -- The samples plus exactly one summary, and no more: the
          -- cancellation neither dropped the count nor re-reported it.
          length noticeIndices `shouldBe` unknownNoticeSamples + 1
          case (reverse noticeIndices, terminalIndex) of
            (lastNotice : _, Just terminal) -> do
              lastNotice `shouldSatisfy` (< terminal)
              -- The samples carry a payload prefix; the aggregate summary
              -- carries only the count.
              (journal !! lastNotice) `shouldNotSatisfy` ByteString.isInfixOf "tick"
            _ -> expectationFailure "expected bounded notices and a terminal envelope in the journal"

    it "seals aggregation against a stream still draining unknown events when the deadline cancels the task" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- The harder race: the stream loop is still admitting unknown events
        -- when the watchdog flushes, and keeps admitting until 'killThread'
        -- finally lands. An unsealed aggregator would restart from zero
        -- after the flush and emit fresh notices after the final summary —
        -- and after the terminal envelope, where replay stops — while the
        -- occurrences those suppressed died counted but never reported.
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec = deadlineFixtureSpec repository (WorkerId "solve-815-deadline-drain") 815 now 1
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-815-deadline-drain.spec.json"
            statePath = workerRoot </> "solve-815-deadline-drain.state.json"
            eventPath = workerRoot </> "solve-815-deadline-drain.events.jsonl"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile specPath (encode spec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
            Nothing -> expectationFailure "worker fixture was not discoverable"
            Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
          let drainUntilKilled _spec aggregator _rememberProvider emit =
                let keepDraining = admitTelemetry aggregator emit 5 >> threadDelay 20000 >> keepDraining
                 in keepDraining
          finished <- newEmptyMVar
          void . forkIO $ runWorkerWithTask readProcessSnapshot drainUntilKilled specPath >>= putMVar finished
          timeout 10000000 (takeMVar finished) `shouldReturn` Just (Right ())
          terminalState <- waitForWorkerState statePath isTerminal 10
          terminalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
          journal <- ByteString.lines <$> ByteString.readFile eventPath
          let noticeIndices = findIndices (ByteString.isInfixOf "[event] telemetry") journal
              terminalIndex = findIndex (ByteString.isInfixOf "WorkerFinished") journal
          -- Still exactly the samples plus one summary, no matter how long
          -- the drain kept running past the flush.
          length noticeIndices `shouldBe` unknownNoticeSamples + 1
          case (reverse noticeIndices, terminalIndex) of
            (lastNotice : _, Just terminal) -> do
              -- Nothing from the drain reaches the journal after the
              -- terminal envelope, where replay would never see it.
              lastNotice `shouldSatisfy` (< terminal)
              (journal !! lastNotice) `shouldNotSatisfy` ByteString.isInfixOf "tick"
            _ -> expectationFailure "expected bounded notices and a terminal envelope in the journal"

    it "kills the current provider and records the deadline outcome when it is still running at the deadline" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \providerProcess -> do
          now <- getCurrentTime
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              spec = deadlineFixtureSpec repository (WorkerId "solve-812-provider") 812 now 1
              workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
              specPath = workerRoot </> "solve-812-provider.spec.json"
              statePath = workerRoot </> "solve-812-provider.state.json"
          createDirectory repository.repositoryRoot
          createDirectoryIfMissing True workerRoot
          LazyByteString.writeFile specPath (encode spec)
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            descriptors <- discoverWorkerHistory repository
            case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
              Nothing -> expectationFailure "worker fixture was not discoverable"
              Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
            managed <- managedProcessFor providerProcess
            let registerThenHang _spec _aggregator rememberProvider _emit = do
                  rememberProvider managed
                  threadDelay (300 * 1000000)
            finished <- newEmptyMVar
            void . forkIO $ runWorkerWithTask readProcessSnapshot registerThenHang specPath >>= putMVar finished
            timeout 15000000 (takeMVar finished) `shouldReturn` Just (Right ())
            terminalState <- waitForWorkerState statePath isTerminal 10
            terminalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
            exitCode <- timeout 3000000 (waitForProcess providerProcess)
            exitCode `shouldSatisfy` isJust

    it "keeps the deadline outcome when a provider registration event lands just after it already fired" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec = deadlineFixtureSpec repository (WorkerId "solve-813-late-registration") 813 now 1
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-813-late-registration.spec.json"
            statePath = workerRoot </> "solve-813-late-registration.state.json"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile specPath (encode spec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
            Nothing -> expectationFailure "worker fixture was not discoverable"
            Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
          -- Simulates the task thread resuming just as (or after) the
          -- watchdog has already committed the deadline outcome, emitting
          -- the same 'WorkerProviderStarted' event a genuine late
          -- registration would: this must never revert the already-terminal
          -- status back to 'WorkerRunning'.
          let lateRegister _spec _aggregator _rememberProvider emit = uninterruptibleMask_ $ do
                _ <- waitForWorkerState statePath isTerminal 50
                emit (WorkerProviderStarted 999999)
          finished <- newEmptyMVar
          void . forkIO $ runWorkerWithTask readProcessSnapshot lateRegister specPath >>= putMVar finished
          terminalState <- waitForWorkerState statePath isTerminal 50
          terminalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
          timeout 5000000 (takeMVar finished) `shouldReturn` Just (Right ())
          stateBytes <- LazyByteString.readFile statePath
          case eitherDecode stateBytes :: Either String WorkerState of
            Left message -> expectationFailure message
            Right finalState -> finalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)

    it "keeps the deadline outcome pending while its kill stays unverified, then resolves once a snapshot succeeds" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \providerProcess -> do
          now <- getCurrentTime
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              spec = deadlineFixtureSpec repository (WorkerId "solve-814-deadline-verify") 814 now 1
              workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
              specPath = workerRoot </> "solve-814-deadline-verify.spec.json"
              statePath = workerRoot </> "solve-814-deadline-verify.state.json"
              eventPath = workerRoot </> "solve-814-deadline-verify.events.jsonl"
              leasePath = workerRoot </> "issue-814.lease"
          createDirectory repository.repositoryRoot
          createDirectoryIfMissing True workerRoot
          LazyByteString.writeFile specPath (encode spec)
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            descriptors <- discoverWorkerHistory repository
            case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
              Nothing -> expectationFailure "worker fixture was not discoverable"
              Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
            managed <- managedProcessFor providerProcess
            let registerThenHang _spec _aggregator rememberProvider _emit = do
                  rememberProvider managed
                  threadDelay (300 * 1000000)
            -- The provider and census kills the watchdog attempts are real
            -- (they use the live process handle, not this snapshot) and do
            -- succeed, but the injected snapshot keeps their *confirmation*
            -- unavailable throughout: an empty recorded census must not be
            -- trusted as proof of that on its own (see
            -- 'waitForOrphanResolution'), so the worker must stay
            -- orphan-pending — not finalize on the coincidence of zero
            -- survivors — until a real snapshot succeeds.
            failing <- newIORef True
            let flakySnapshot = do
                  stillFailing <- readIORef failing
                  if stillFailing then pure (Left "simulated ps outage") else readProcessSnapshot
            finished <- newEmptyMVar
            void . forkIO $ runWorkerWithTask flakySnapshot registerThenHang specPath >>= putMVar finished
            pendingState <- waitForWorkerState statePath isOrphaned 80
            pendingState.workerStateStatus `shouldBe` WorkerOrphaned (SolveFailed workerDeadlineReason)
            leaseHeldWhileUnverified <- doesDirectoryExist leasePath
            leaseHeldWhileUnverified `shouldBe` True
            stillPending <- timeout 2000000 (takeMVar finished)
            stillPending `shouldBe` Nothing
            eventBytesWhileFailing <- ByteString.readFile eventPath
            eventBytesWhileFailing `shouldNotSatisfy` ByteString.isInfixOf "WorkerFinished"
            eventBytesWhileFailing `shouldSatisfy` ByteString.isInfixOf "could not verify the current provider was terminated"
            eventBytesWhileFailing `shouldSatisfy` ByteString.isInfixOf "WorkerOrphansDetected"
            writeIORef failing False
            timeout 10000000 (takeMVar finished) `shouldReturn` Just (Right ())
            terminalState <- waitForWorkerState statePath isTerminal 30
            terminalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
            leaseReleased <- doesDirectoryExist leasePath
            leaseReleased `shouldBe` False

    it "lets an in-flight completion finish instead of being cut off by a deadline that fires while it is running" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withManagedShell "sleep 0.5" $ \providerProcess -> do
          now <- getCurrentTime
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              spec = deadlineFixtureSpec repository (WorkerId "solve-815-completion-boundary") 815 now 1
              workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
              specPath = workerRoot </> "solve-815-completion-boundary.spec.json"
              statePath = workerRoot </> "solve-815-completion-boundary.state.json"
          createDirectory repository.repositoryRoot
          createDirectoryIfMissing True workerRoot
          LazyByteString.writeFile specPath (encode spec)
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            descriptors <- discoverWorkerHistory repository
            case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
              Nothing -> expectationFailure "worker fixture was not discoverable"
              Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
            managed <- managedProcessFor providerProcess
            -- A provider registered here so the deadline-firing completion's
            -- own verification below has something to actually wait on: an
            -- empty census would resolve immediately and never overlap the
            -- deadline. It exits on its own well before the slow snapshot
            -- resolves, so this always lands on the real completion's
            -- 'WorkerFinished' rather than an orphan-pending detour.
            let completeThenSlow _spec _aggregator rememberProvider emit = do
                  rememberProvider managed
                  emit (WorkerFinished SolveCompleted)
                slowSnapshot = threadDelay 2000000 >> readProcessSnapshot
            finished <- newEmptyMVar
            void . forkIO $ runWorkerWithTask slowSnapshot completeThenSlow specPath >>= putMVar finished
            timeout 10000000 (takeMVar finished) `shouldReturn` Just (Right ())
            terminalState <- waitForWorkerState statePath isTerminal 10
            terminalState.workerStateStatus `shouldBe` WorkerTerminal SolveCompleted

    it "keeps the deadline outcome when a normal completion attempt lands just after it already fired" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec = deadlineFixtureSpec repository (WorkerId "solve-817-completion-race") 817 now 1
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-817-completion-race.spec.json"
            statePath = workerRoot </> "solve-817-completion-race.state.json"
            eventPath = workerRoot </> "solve-817-completion-race.events.jsonl"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile specPath (encode spec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
            Nothing -> expectationFailure "worker fixture was not discoverable"
            Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
          -- Simulates a task thread that only reaches its own normal
          -- completion after the deadline has already claimed the single
          -- completion slot and committed its outcome: the deadline must
          -- keep ownership, not be silently replaced by a later-arriving
          -- ordinary 'WorkerFinished'.
          let completeAfterDeadline _spec _aggregator _rememberProvider emit = uninterruptibleMask_ $ do
                _ <- waitForWorkerState statePath isTerminal 50
                emit (WorkerFinished SolveCompleted)
          finished <- newEmptyMVar
          void . forkIO $ runWorkerWithTask readProcessSnapshot completeAfterDeadline specPath >>= putMVar finished
          terminalState <- waitForWorkerState statePath isTerminal 50
          terminalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
          timeout 5000000 (takeMVar finished) `shouldReturn` Just (Right ())
          stateBytes <- LazyByteString.readFile statePath
          case eitherDecode stateBytes :: Either String WorkerState of
            Left message -> expectationFailure message
            Right finalState -> finalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
          eventBytes <- ByteString.readFile eventPath
          eventBytes `shouldNotSatisfy` ByteString.isInfixOf "SolveCompleted"

    it "keeps the lease held until the watchdog's own verification finishes, even when the task's thread returns first" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        -- No TERM trap: this provider exits promptly once the watchdog
        -- signals it, well inside the mandatory termination-grace wait the
        -- watchdog's own verified kill always sleeps through afterward.
        withManagedShell "while :; do sleep 1; done" $ \providerProcess -> do
          now <- getCurrentTime
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              spec = deadlineFixtureSpec repository (WorkerId "solve-819-watchdog-join") 819 now 1
              workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
              specPath = workerRoot </> "solve-819-watchdog-join.spec.json"
              statePath = workerRoot </> "solve-819-watchdog-join.state.json"
              leasePath = workerRoot </> "issue-819.lease"
          createDirectory repository.repositoryRoot
          createDirectoryIfMissing True workerRoot
          LazyByteString.writeFile specPath (encode spec)
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            descriptors <- discoverWorkerHistory repository
            case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
              Nothing -> expectationFailure "worker fixture was not discoverable"
              Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
            managed <- managedProcessFor providerProcess
            -- Mirrors what a real runSolve/runPullRequestFlow does: register,
            -- then wait on the actual provider process and report its exit.
            -- Once the watchdog's own termination signal reaches it, this
            -- naturally observes the exit and tries to complete normally —
            -- losing the already-claimed slot — well before the watchdog's
            -- own mandatory grace wait lets it finish verifying and
            -- committing.
            let registerThenWaitAndFinish _spec _aggregator rememberProvider emit = do
                  rememberProvider managed
                  _ <- waitForProcess providerProcess
                  emit (WorkerFinished SolveCompleted)
            finished <- newEmptyMVar
            void . forkIO $ runWorkerWithTask readProcessSnapshot registerThenWaitAndFinish specPath >>= putMVar finished
            timeout 15000000 (takeMVar finished) `shouldReturn` Just (Right ())
            -- Checked immediately, with no polling wait: by the time
            -- runWorkerWithTask has fully returned, the watchdog's own
            -- commit must already be reflected on disk, not still catching
            -- up in the background after the lease was released.
            stateBytes <- LazyByteString.readFile statePath
            case eitherDecode stateBytes :: Either String WorkerState of
              Left message -> expectationFailure message
              Right finalState -> finalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
            leaseReleased <- doesDirectoryExist leasePath
            leaseReleased `shouldBe` False

    it "never leaks a provider spawned right as an already-overdue deadline fires" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            identifier = WorkerId "solve-818-overdue-spawn"
            repository = Repository repositoryRoot "coghex" "kanban"
            longAgo = addUTCTime (-3600) now
            spec =
              WorkerSpec
                { workerId = identifier,
                  workerRepository = repository,
                  workerTask = SolveWorkerTaskKind (SolveWorkerTask 818 SolveOnly CodexSolver),
                  workerExistingSession = Nothing,
                  workerExistingLogPath = Nothing,
                  workerResumeProvenance = ResumeAnswer,
                  workerUserMessage = "",
                  workerParent = Nothing,
                  workerCreatedAt = longAgo,
                  workerMaxRuntimeSeconds = 60,
                  workerConfigPath = Nothing,
                  workerWorkflowConfig = defaultWorkflowConfig
                }
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-818-overdue-spawn.spec.json"
            statePath = workerRoot </> "solve-818-overdue-spawn.state.json"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        createDirectoryIfMissing True workerRoot
        -- A real provider, spawned through the actual 'runSolve' path (not a
        -- synthetic event), that resists TERM so a leak would show up as a
        -- process this test's own final snapshot can still see.
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "trap '' TERM",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"overdue-session\"}'",
                "while :; do sleep 1; done"
              ]
          )
        setFileMode fakeCodex 0o700
        LazyByteString.writeFile specPath (encode spec)
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            result <- timeout 15000000 (runWorker specPath)
            result `shouldBe` Just (Right ())
            stateBytes <- LazyByteString.readFile statePath
            case eitherDecode stateBytes :: Either String WorkerState of
              Left message -> expectationFailure message
              Right finalState -> finalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
            survivorSnapshot <- readProcessSnapshot
            case survivorSnapshot of
              Left message -> expectationFailure (Data.Text.unpack message)
              Right identities ->
                identities `shouldSatisfy` all (\identity -> not (Data.Text.isInfixOf (Data.Text.pack fakeCodex) identity.processIdentityCommand))

    it "retains orphan state instead of vacuously finalizing when the deadline fires mid-spawn, before registration lands" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \providerProcess -> do
          now <- getCurrentTime
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              spec = deadlineFixtureSpec repository (WorkerId "solve-821-spawn-registration-race") 821 now 1
              workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
              specPath = workerRoot </> "solve-821-spawn-registration-race.spec.json"
              statePath = workerRoot </> "solve-821-spawn-registration-race.state.json"
              eventPath = workerRoot </> "solve-821-spawn-registration-race.events.jsonl"
              leasePath = workerRoot </> "issue-821.lease"
          createDirectory repository.repositoryRoot
          createDirectoryIfMissing True workerRoot
          LazyByteString.writeFile specPath (encode spec)
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            descriptors <- discoverWorkerHistory repository
            case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
              Nothing -> expectationFailure "worker fixture was not discoverable"
              Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
            managed <- managedProcessFor providerProcess
            -- Reproduces the exact narrow window 'runSolve'/'runPullRequestFlow's
            -- own masked spawn-to-registration block leaves open, without
            -- depending on how fast a real 'createProcess' happens to run:
            -- 'WorkerProviderSpawning True' marks the spawn as started, then
            -- this masked delay holds 'rememberProvider' back for 2 seconds
            -- — well past the 1-second deadline — so the watchdog's check
            -- deterministically lands while the provider slot is still
            -- 'ProviderSlotSpawning' (not yet registered) and a real, live
            -- process is already running unrecorded.
            let spawningThenRegister _spec _aggregator rememberProvider emit = uninterruptibleMask_ $ do
                  emit (WorkerProviderSpawning True)
                  threadDelay 2000000
                  rememberProvider managed
            finished <- newEmptyMVar
            void . forkIO $ runWorkerWithTask readProcessSnapshot spawningThenRegister specPath >>= putMVar finished
            terminalState <- waitForWorkerState statePath isTerminal 80
            terminalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
            timeout 10000000 (takeMVar finished) `shouldReturn` Just (Right ())
            leaseReleased <- doesDirectoryExist leasePath
            leaseReleased `shouldBe` False
            -- The real assertion: a provider spawned (but not yet
            -- registered) when the deadline fires must not let the
            -- watchdog treat the still-'ProviderSlotSpawning' slot as
            -- vacuously verified and finalize directly. It must retain
            -- orphan state until the census actually reflects — and
            -- confirms gone — the process this spawn attempt started, so
            -- the lease is never released on an unverified guess.
            eventBytes <- ByteString.readFile eventPath
            eventBytes `shouldSatisfy` ByteString.isInfixOf "WorkerOrphansDetected"

    it "rejects a late spawn claim -- never adopting a real process -- once the watchdog has already claimed the provider slot empty" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \providerProcess -> do
          now <- getCurrentTime
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              spec = deadlineFixtureSpec repository (WorkerId "solve-823-late-spawn-claim") 823 now 1
              workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
              specPath = workerRoot </> "solve-823-late-spawn-claim.spec.json"
              statePath = workerRoot </> "solve-823-late-spawn-claim.state.json"
              leasePath = workerRoot </> "issue-823.lease"
          createDirectory repository.repositoryRoot
          createDirectoryIfMissing True workerRoot
          LazyByteString.writeFile specPath (encode spec)
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            descriptors <- discoverWorkerHistory repository
            case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
              Nothing -> expectationFailure "worker fixture was not discoverable"
              Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
            managed <- managedProcessFor providerProcess
            registeredRef <- newIORef False
            -- The mirror image of the race above: this task deliberately
            -- waits for the deadline to have already fired and committed
            -- its terminal, verified-empty outcome (nothing was ever
            -- spawned yet, so the watchdog's compare-and-swap into
            -- 'ProviderSlotClaimedEmpty' wins outright) before it ever
            -- attempts to begin its own spawn. Held under
            -- 'uninterruptibleMask_' so the watchdog's 'killThread' cannot
            -- race ahead and interrupt this before its spawn-claim attempt
            -- actually runs, guaranteeing this exercises the real
            -- compare-and-swap rejection deterministically rather than an
            -- incidental early kill. If the claim were ever granted here,
            -- 'rememberProvider' would hand a real, live process to a
            -- worker that has already released its lease; 'registeredRef'
            -- proves that never happens.
            let lateSpawnClaim _spec _aggregator rememberProvider emit = uninterruptibleMask_ $ do
                  _ <- waitForWorkerState statePath isTerminal 80
                  emit (WorkerProviderSpawning True)
                  rememberProvider managed
                  writeIORef registeredRef True
            finished <- newEmptyMVar
            void . forkIO $ runWorkerWithTask readProcessSnapshot lateSpawnClaim specPath >>= putMVar finished
            terminalState <- waitForWorkerState statePath isTerminal 80
            terminalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
            timeout 10000000 (takeMVar finished) `shouldReturn` Just (Right ())
            leaseReleased <- doesDirectoryExist leasePath
            leaseReleased `shouldBe` False
            registered <- readIORef registeredRef
            registered `shouldBe` False
            stateBytes <- LazyByteString.readFile statePath
            case eitherDecode stateBytes :: Either String WorkerState of
              Left message -> expectationFailure message
              Right finalState -> finalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)

    it "captures a provider's live descendants into the census before killing it, even when identity recording never ran -- an escaped-descendant regression" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec = deadlineFixtureSpec repository (WorkerId "solve-825-escaped-descendant-capture") 825 now 60
            pidFile = temporaryRoot </> "detached-child.pid"
            -- Simulates the exact precondition the bug depends on:
            -- 'recordProviderIdentity' silently swallows a snapshot failure
            -- ('Left _ -> pure ()') and is never retried, permanently
            -- leaving 'workerStateProviderIdentity' unset -- which starves
            -- 'refreshProcessCensus's own descendant walk of a root, so
            -- 'workerStateKnownProcesses' never discovers anything either,
            -- for this worker's entire remaining lifetime.
            fixtureState =
              WorkerState
                { workerStateId = spec.workerId,
                  workerStateStatus = WorkerStarting,
                  workerStateWorkerPid = 0,
                  workerStateWorkerIdentity = Nothing,
                  workerStateProviderPid = Nothing,
                  workerStateProviderIdentity = Nothing,
                  workerStateSessionId = Nothing,
                  workerStateLogPath = Nothing,
                  workerStateHeartbeatAt = now,
                  workerStateLastActivity = "",
                  workerStateKnownProcesses = []
                }
        withManagedShell (detachedEscapedDescendantCommand pidFile) $ \providerProcess -> do
          managed <- managedProcessFor providerProcess
          -- Independent of 'killVerifiedGroupWith'/'terminateRecordedStateProcessesWith'
          -- (the very operations under test), so a failing assertion above
          -- still cannot leak the detached child: 'withManagedShell's own
          -- 'stop' bracket only ever reaches the *provider's* group, not
          -- necessarily this deliberately detached one.
          let cleanupAnyDescendant =
                void $
                  (try @SomeException $ do
                     contents <- readFile pidFile
                     case reads contents :: [(Int, String)] of
                       [(childPid, _)] -> signalProcessGroup sigKILL (fromIntegral childPid)
                       _ -> pure ())
          ( do
              stateLock <- newMVar fixtureState
              providerSlotRef <- newIORef (ProviderSlotRegistered managed)
              -- Poll for the detached child to actually appear as the
              -- provider's descendant in a real process snapshot, rather
              -- than guessing a fixed delay: under load, a fixed sleep can
              -- fire before the fork/exec has settled, making this flaky
              -- for reasons unrelated to the fix under test.
              maybeProviderPid <- managedProcessPid managed
              providerPid <- case maybeProviderPid of
                Just pid -> pure pid
                Nothing -> expectationFailure "provider process had no observable pid" >> fail "unreachable"
              let waitForDetachedChild attempts = do
                    snapshotResult <- readProcessSnapshot
                    case snapshotResult of
                      Right snapshot | not (null (descendantProcesses [fromIntegral providerPid] snapshot)) -> pure ()
                      _
                        | attempts <= (0 :: Int) -> expectationFailure "detached descendant never appeared in a process snapshot"
                        | otherwise -> threadDelay 100000 >> waitForDetachedChild (attempts - 1)
              waitForDetachedChild 50
              providerOk <- terminateProviderRefWith readProcessSnapshot stateLock providerSlotRef
              providerOk `shouldBe` True
              -- The real assertion: 'workerStateKnownProcesses' now holds
              -- the detached child even though 'workerStateProviderIdentity'
              -- was never set and nothing else ever recorded it --
              -- 'terminateProviderRefWith' discovered and captured it purely
              -- from the live handle's own pid and a snapshot it took
              -- itself. Without that capture this stays empty, exactly the
              -- gap that let an escaped descendant survive a "verified"
              -- deadline finalization untracked.
              capturedState <- readMVar stateLock
              capturedState.workerStateKnownProcesses `shouldSatisfy` (not . null)
              -- The second, independent pass 'watchdogLoop' always runs
              -- right after this one is what actually finishes the job: it
              -- finds the descendant this call just recorded (whether or
              -- not the provider's own group-kill already reached it) and
              -- kills/verifies it for real, closing the gap end to end.
              recordedOk <- terminateRecordedStateProcessesWith readProcessSnapshot capturedState
              recordedOk `shouldBe` True
              finalSnapshot <- readProcessSnapshot
              case finalSnapshot of
                Left message -> expectationFailure (Data.Text.unpack message)
                Right snapshot ->
                  [p | p <- capturedState.workerStateKnownProcesses, isJust (identityForPid p.processIdentityPid snapshot)]
                    `shouldBe` []
            )
            `finally` cleanupAnyDescendant

    it "kills a descendant discovered only by a late registration, after the deadline already gave up on an empty spawning census" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec = deadlineFixtureSpec repository (WorkerId "solve-826-late-registration-descendant") 826 now 1
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-826-late-registration-descendant.spec.json"
            statePath = workerRoot </> "solve-826-late-registration-descendant.state.json"
            leasePath = workerRoot </> "issue-826.lease"
            pidFile = temporaryRoot </> "detached-child.pid"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile specPath (encode spec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withManagedShell (detachedEscapedDescendantCommand pidFile) $ \providerProcess -> do
            descriptors <- discoverWorkerHistory repository
            case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
              Nothing -> expectationFailure "worker fixture was not discoverable"
              Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
            managed <- managedProcessFor providerProcess
            let cleanupAnyDescendant =
                  void $
                    (try @SomeException $ do
                       contents <- readFile pidFile
                       case reads contents :: [(Int, String)] of
                         [(childPid, _)] -> signalProcessGroup sigKILL (fromIntegral childPid)
                         _ -> pure ())
            -- Mirrors 'spawningThenRegister' above (the deadline fires while
            -- the slot is still 'ProviderSlotSpawning'), but this provider
            -- has a real descendant in its own process group -- an
            -- integration check that 'rememberProvider's stopped path
            -- (now 'terminateProviderRefWith' rather than a bare
            -- 'killManagedProcess') stays correctly wired end to end and
            -- still confirms the descendant gone before the lease releases.
            let lateRegistrationWithDescendant _spec _aggregator rememberProvider emit = uninterruptibleMask_ $ do
                  emit (WorkerProviderSpawning True)
                  threadDelay 2000000
                  rememberProvider managed
            ( do
                finished <- newEmptyMVar
                void . forkIO $ runWorkerWithTask readProcessSnapshot lateRegistrationWithDescendant specPath >>= putMVar finished
                terminalState <- waitForWorkerState statePath isTerminal 80
                terminalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
                timeout 10000000 (takeMVar finished) `shouldReturn` Just (Right ())
                leaseReleased <- doesDirectoryExist leasePath
                leaseReleased `shouldBe` False
                childPidText <- readFile pidFile
                case reads childPidText :: [(Int, String)] of
                  [(childPid, _)] -> do
                    finalSnapshot <- readProcessSnapshot
                    case finalSnapshot of
                      Left message -> expectationFailure (Data.Text.unpack message)
                      Right snapshot -> identityForPid childPid snapshot `shouldBe` Nothing
                  _ -> expectationFailure "detached child pid was never written"
              )
              `finally` cleanupAnyDescendant

    it "kills a recorded census group and takes over the pending outcome when the deadline fires on an already-orphaned normal completion" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            identifier = WorkerId "solve-820-orphan-then-deadline"
            repository = Repository repositoryRoot "coghex" "kanban"
            spec = deadlineFixtureSpec repository identifier 820 now 1
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-820-orphan-then-deadline.spec.json"
            statePath = workerRoot </> "solve-820-orphan-then-deadline.state.json"
            eventPath = workerRoot </> "solve-820-orphan-then-deadline.events.jsonl"
            leasePath = workerRoot </> "issue-820.lease"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        createDirectoryIfMissing True workerRoot
        -- The provider itself exits normally almost immediately, backgrounding
        -- a TERM-resistant child first: the normal completion claims
        -- completedRef and, finding that child still alive, reports
        -- WorkerOrphansDetected SolveCompleted rather than WorkerFinished. The
        -- one-second deadline then fires while that orphan-pending state is
        -- still unresolved.
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "sh -c 'trap \"\" TERM; while :; do sleep 1; done' </dev/null >/dev/null 2>&1 &",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"orphan-then-deadline-session\"}'",
                "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Created PR #999\"}}'",
                -- Long enough that the periodic census loop (every 250ms)
                -- captures the backgrounded child at least once while this
                -- script is still its live parent -- once this script exits
                -- and the child gets reparented, a fresh census can no
                -- longer discover it by descent -- but short enough that
                -- the normal completion below still lands well before the
                -- one-second deadline fires.
                "sleep 0.5"
              ]
          )
        setFileMode fakeCodex 0o700
        LazyByteString.writeFile specPath (encode spec)
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            descriptors <- discoverWorkerHistory repository
            case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
              Nothing -> expectationFailure "worker fixture was not discoverable"
              Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
            finished <- newEmptyMVar
            void . forkIO $ runWorker specPath >>= putMVar finished
            orphanState <- waitForWorkerState statePath isOrphaned 80
            orphanState.workerStateStatus `shouldBe` WorkerOrphaned SolveCompleted
            -- The one-second deadline fires next, while the survivor is
            -- still alive and the worker is still orphan-pending on it: it
            -- must take over the pending outcome even though it lost
            -- completedRef to the normal completion above.
            deadlineTookOver <-
              waitForWorkerState
                statePath
                ( \state -> case state.workerStateStatus of
                    WorkerOrphaned (SolveFailed message) -> message == workerDeadlineReason
                    _ -> False
                )
                80
            deadlineTookOver.workerStateStatus `shouldBe` WorkerOrphaned (SolveFailed workerDeadlineReason)
            timeout 10000000 (takeMVar finished) `shouldReturn` Just (Right ())
            terminalState <- waitForWorkerState statePath isTerminal 30
            terminalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
            leaseReleased <- doesDirectoryExist leasePath
            leaseReleased `shouldBe` False
            eventBytes <- ByteString.readFile eventPath
            let orphanEvents = length (filter (ByteString.isInfixOf "WorkerOrphansDetected") (ByteString.lines eventBytes))
            orphanEvents `shouldSatisfy` (>= 2)
            eventBytes `shouldSatisfy` ByteString.isInfixOf "\"SolveCompleted\""

    it "does not finalize an orphan-pending normal completion on its own stale outcome once the deadline has passed" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withManagedShell "sleep 0.95" $ \providerProcess -> do
          now <- getCurrentTime
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              spec = deadlineFixtureSpec repository (WorkerId "solve-822-orphan-poll-race") 822 now 1
              workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
              specPath = workerRoot </> "solve-822-orphan-poll-race.spec.json"
              statePath = workerRoot </> "solve-822-orphan-poll-race.state.json"
              leasePath = workerRoot </> "issue-822.lease"
          createDirectory repository.repositoryRoot
          createDirectoryIfMissing True workerRoot
          LazyByteString.writeFile specPath (encode spec)
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            descriptors <- discoverWorkerHistory repository
            case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
              Nothing -> expectationFailure "worker fixture was not discoverable"
              Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
            managed <- managedProcessFor providerProcess
            -- Unlike the TERM-resistant survivor above (only ever killed by
            -- the watchdog's own verified kill, guaranteeing its takeover
            -- write lands before the census can ever read empty), this one
            -- exits entirely on its own, just before the one-second
            -- deadline: the orphan-poll's own periodic census check can
            -- observe "empty" from that natural exit alone, independently
            -- of anything the watchdog does, and can win 'claimLeaseRelease'
            -- for itself well before the watchdog thread ever gets
            -- scheduled. This end-to-end run cannot force that exact
            -- scheduling interleaving deterministically (a direct, isolated
            -- test of 'waitForOrphanResolution' below covers that
            -- precisely), but it still exercises 'waitForOrphanResolution's
            -- own post-win wall-clock recheck for real: this shell's 0.95s
            -- runtime leaves only a razor-thin margin before the one-second
            -- deadline, so by the time the orphan-poll's periodic check
            -- (plus a real 'ps' shell-out) actually observes the census as
            -- empty, wall-clock time has consistently already crossed the
            -- deadline in practice. It is kept as an end-to-end
            -- confirmation that an orphan-pending completion resolves to
            -- the deadline outcome once genuinely past it, alongside the
            -- more targeted unit coverage below.
            let completeThenOrphan _spec _aggregator rememberProvider emit = do
                  rememberProvider managed
                  emit (WorkerFinished SolveCompleted)
            finished <- newEmptyMVar
            void . forkIO $ runWorkerWithTask readProcessSnapshot completeThenOrphan specPath >>= putMVar finished
            orphanState <- waitForWorkerState statePath isOrphaned 80
            orphanState.workerStateStatus `shouldBe` WorkerOrphaned SolveCompleted
            terminalState <- waitForWorkerState statePath isTerminal 80
            terminalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
            timeout 10000000 (takeMVar finished) `shouldReturn` Just (Right ())
            leaseReleased <- doesDirectoryExist leasePath
            leaseReleased `shouldBe` False
            stateBytes <- LazyByteString.readFile statePath
            case eitherDecode stateBytes :: Either String WorkerState of
              Left message -> expectationFailure message
              Right finalState -> finalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)

    it "waitForOrphanResolution reports the deadline outcome, not a stale pre-deadline one, when it wins the lease race after the deadline has passed" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            -- Created ten seconds in the past against a one-second runtime
            -- bound, so the deadline sits nine seconds behind "now" --
            -- unambiguously already passed, with no reliance on any real
            -- timing margin or thread-scheduling luck.
            spec = deadlineFixtureSpec repository (WorkerId "solve-824-orphan-poll-deadline-recheck") 824 (addUTCTime (-10) now) 1
            descriptor =
              WorkerDescriptor
                { workerDescriptorSpec = spec,
                  workerDescriptorSpecPath = temporaryRoot </> "unused.spec.json",
                  workerDescriptorEventPath = temporaryRoot </> "unused.events.jsonl",
                  workerDescriptorStatePath = temporaryRoot </> "unused.state.json",
                  workerDescriptorAckPath = temporaryRoot </> "unused.ack",
                  workerDescriptorLeasePath = temporaryRoot </> "unused.lease",
                  workerDescriptorLeaseOwnerPath = temporaryRoot </> "unused.lease" </> "owner.json",
                  workerDescriptorPendingTerminationPath = temporaryRoot </> "unused.pending-termination"
                }
            fixtureState =
              WorkerState
                { workerStateId = spec.workerId,
                  workerStateStatus = WorkerStarting,
                  workerStateWorkerPid = 0,
                  workerStateWorkerIdentity = Nothing,
                  workerStateProviderPid = Nothing,
                  workerStateProviderIdentity = Nothing,
                  workerStateSessionId = Nothing,
                  workerStateLogPath = Nothing,
                  workerStateHeartbeatAt = now,
                  workerStateLastActivity = "",
                  workerStateKnownProcesses = []
                }
        stateLock <- newMVar fixtureState
        pendingOutcomeRef <- newIORef (Just (True, SolveCompleted))
        signalShutdownRef <- newIORef False
        watchdogAdjudicatedVar <- newEmptyMVar
        emittedRef <- newIORef []
        -- 'claimLeaseRelease' always "wins" on its very first attempt: this
        -- directly constructs the exact interleaving the reviewer flagged
        -- (the orphan-poll winning the lease-release race before the
        -- watchdog thread has ever been scheduled to contend for it) rather
        -- than approximating it with real thread timing, so this reliably
        -- exercises 'waitForOrphanResolution's own post-win wall-clock
        -- recheck on every run.
        let claimLeaseRelease = pure True
            emit event = atomicModifyIORef' emittedRef (\events -> (events <> [event], ()))
        wonLease <- waitForOrphanResolution descriptor spec stateLock readProcessSnapshot signalShutdownRef emit pendingOutcomeRef claimLeaseRelease watchdogAdjudicatedVar
        wonLease `shouldBe` True
        emitted <- readIORef emittedRef
        emitted `shouldBe` [WorkerFinished (SolveFailed workerDeadlineReason)]

    it "attaches a detached supervisor's standard descriptors to /dev/null instead of closing them" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- Closing fds 0-2 (the old 'NoStream' spawn) leaves them unallocated,
        -- so the journal and state files the supervisor opens land on those
        -- numbers and any stray write to stdout or stderr is appended into
        -- the JSONL the dashboard parses. The identity checks below run
        -- before the probe opens any file of its own, so a probe can never
        -- take a free descriptor and then report it as /dev/null.
        let reportPath = temporaryRoot </> "descriptors.txt"
            probe =
              unlines
                [ "r=\"\"",
                  "if [ /dev/null -ef /dev/null ]; then r=\"control=ok\"; else r=\"control=unsupported\"; fi",
                  "for fd in 0 1 2; do",
                  "  if [ \"/dev/fd/$fd\" -ef /dev/null ]; then r=\"$r fd$fd=null\"; else r=\"$r fd$fd=other\"; fi",
                  "done",
                  "if cat <&0 >/dev/null 2>/dev/null; then r=\"$r stdin=readable\"; else r=\"$r stdin=unreadable\"; fi",
                  "if echo probe >&1 2>/dev/null; then r=\"$r stdout=writable\"; else r=\"$r stdout=unwritable\"; fi",
                  "if echo probe >&2 2>/dev/null; then r=\"$r stderr=writable\"; else r=\"$r stderr=unwritable\"; fi",
                  "printf '%s\\n' \"$r\" > " <> show reportPath
                ]
        spawned <- spawnDetachedSupervisor "/bin/sh" ["-c", probe]
        case spawned of
          Left exception -> expectationFailure ("could not spawn the descriptor probe: " <> show exception)
          Right processHandle -> do
            waitForProcess processHandle `shouldReturn` ExitSuccess
            report <- readFile reportPath
            words report
              `shouldBe` [ "control=ok",
                           "fd0=null",
                           "fd1=null",
                           "fd2=null",
                           "stdin=readable",
                           "stdout=writable",
                           "stderr=writable"
                         ]

    it "records a terminal outcome when the supervisor fails outside the task's own exception boundary" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withManagedShell "sleep 30" $ \providerProcess -> do
          now <- getCurrentTime
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              -- A long deadline keeps the watchdog out of this entirely: the
              -- only failure under test is the supervisor's own.
              spec = deadlineFixtureSpec repository (WorkerId "solve-814-supervisor-failure") 814 now 600
              workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
              specPath = workerRoot </> "solve-814-supervisor-failure.spec.json"
              statePath = workerRoot </> "solve-814-supervisor-failure.state.json"
              eventPath = workerRoot </> "solve-814-supervisor-failure.events.jsonl"
              leasePath = workerRoot </> "issue-814.lease"
          createDirectory repository.repositoryRoot
          createDirectoryIfMissing True workerRoot
          LazyByteString.writeFile specPath (encode spec)
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            descriptors <- discoverWorkerHistory repository
            case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
              Nothing -> expectationFailure "worker fixture was not discoverable"
              Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
            -- The task itself succeeds, so nothing reaches the 'try' around
            -- 'runTask'. The supervisor's own fallback completion then raises
            -- on the main thread, past that boundary: the snapshot throws
            -- rather than returning 'Left', a shape the existing handling
            -- does not model. Registering a real provider first is what makes
            -- the census non-empty, so the failing snapshot is actually
            -- consulted instead of short-circuited.
            managed <- managedProcessFor providerProcess
            armedRef <- newIORef True
            let explodingSnapshot = do
                  -- Only the first call throws, so the guard's own
                  -- finalization can still verify nothing survives and commit
                  -- a terminal outcome -- the behaviour under test.
                  armed <- atomicModifyIORef' armedRef (\wasArmed -> (False, wasArmed))
                  when armed (throwIO (userError "process snapshot exploded"))
                  pure (Right [])
                registerThenReturn _spec _aggregator rememberProvider _emit = rememberProvider managed
            result <- timeout 15000000 (runWorkerWithTask explodingSnapshot registerThenReturn specPath)
            -- The supervisor reports the failure instead of dying silently.
            failure <- requireJust "supervisor did not return" result >>= requireLeft "supervisor hid its own failure"
            failure `shouldSatisfy` Data.Text.isInfixOf "persistent worker supervisor failed"
            -- ...and the failure is durable: decodable terminal state plus the
            -- journal record, neither of which the old code produced.
            terminalState <- waitForWorkerState statePath isTerminal 10
            case terminalState.workerStateStatus of
              WorkerTerminal (SolveFailed message) ->
                message `shouldSatisfy` Data.Text.isInfixOf "persistent worker supervisor failed"
              status -> expectationFailure ("unexpected terminal status: " <> show status)
            journal <- ByteString.readFile eventPath
            journal `shouldSatisfy` ByteString.isInfixOf "WorkerFinished"
            journal `shouldSatisfy` ByteString.isInfixOf "SolveFailed"
            -- Absence was verified, so the lease is released rather than left
            -- behind for stale-lease recovery.
            doesDirectoryExist leasePath `shouldReturn` False
