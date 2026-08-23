-- | The first half of the @managed agent processes@ group: signal delivery, the
-- process census, issue leases, journal streaming and stale-supervisor
-- recovery.
module Spec.Agent.ManagedProcess.Lifecycle (examples) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, readMVar, takeMVar, threadDelay)
import Control.Exception (finally, throwIO)
import Control.Monad (void, when)
import Data.Aeson (eitherDecode, encode, object, (.=))
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.IORef (modifyIORef, newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Maybe (isJust)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Kanban.Domain
import Kanban.Models (ProviderName (..), RecordedAssignment (..))
import Kanban.Process
  ( IdentityPresence (..),
    ProcessIdentity (..),
    checkGroupMembershipWith,
    descendantProcesses,
    identityForPid,
    interruptManagedProcess,
    killManagedProcess,
    killVerifiedGroupWith,
    liveProcesses,
    managedProcess,
    managedProcessGroup,
    matchingIdentities,
    membersStillInGroup,
    readProcessSnapshot
  )
import Kanban.PullRequestFlow (PullRequestAction (..), PullRequestOrigin (..))
import Kanban.Solve
  ( AgentEvent (..),
    ResumeProvenance (..),
    SolveOutcome (..),
    SolveWorkflow (..),
    SolverBrand (..),
    emitStreamEvent,
    sealUnknownAggregates,
    newUnknownAggregator,
    parseSolveOutputLine,
    unknownNoticeSamples
  )
import Kanban.Worker
  ( PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerEnvelope (..),
    WorkerEvent (..),
    WorkerDescriptor (..),
    WorkerId (..),
    WorkerParent (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    WorkerTask (..),
    acquireWorkerLease,
    collectWorkerCacheWith,
    consumeJournalLines,
    discoverWorkerHistory,
    monitorWorker,
    recordLaunchedSupervisorIdentity,
    recoverIfWorkerStoppedWith,
    releaseWorkerLease,
    runWorker,
    runWorkerWith,
    terminateWorkerWith,
    waitForWorkerStart
  )
import Spec.Support.Env (permissionsOf, withEnvironmentValue, withFakeOnPath, withFileCreationMask, withTemporaryCacheRoot)
import Spec.Support.Expect (requireJust)
import Spec.Support.Fixtures (epoch)
import Spec.Support.Process
  ( assertBoundedWorkerSurfaces,
    identityForProcess,
    isDiagnosticEvent,
    isOrphaned,
    isTerminal,
    isWorkerFailedEvent,
    managedProcessFor,
    processIdentity,
    runChattyWorker,
    runningWorkerState,
    shouldNotHaveSwept,
    waitForWorkerState,
    withManagedShell,
    withNonLeaderShell,
    withSurvivingGroupLeader,
    workerFixtureAssignment,
    workerFixtureSpec
  )
import System.Directory
  ( createDirectory,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    removeFile,
    setModificationTime
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (raiseSignal, sigKILL, sigTERM, signalProcessGroup)
import System.Process
  ( CreateProcess (..),
    createProcess,
    getProcessExitCode,
    proc,
    waitForProcess
  )
import System.Timeout (timeout)
import Test.Hspec

examples :: Spec
examples = do
    it "delivers Ctrl-C to the worker process group" $
      withManagedShell "trap 'exit 42' INT; while :; do sleep 1; done" $ \process -> do
        threadDelay 100000
        managed <- managedProcessFor process
        interruptManagedProcess managed
        timeout 3000000 (waitForProcess process) `shouldReturn` Just (ExitFailure 42)

    it "escalates a TERM-resistant worker tree to SIGKILL" $
      withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \process -> do
        threadDelay 100000
        managed <- managedProcessFor process
        killManagedProcess managed
        timeout 3000000 (waitForProcess process) `shouldReturn` Just (ExitFailure (-9))

    it "flags a non-group-leader child at registration, then still delivers Ctrl-C via the per-PID fallback" $
      withNonLeaderShell "trap 'exit 42' INT; while :; do sleep 1; done" $ \process -> do
        threadDelay 100000
        (managed, groupLeaderProblem) <- managedProcess process
        groupLeaderProblem `shouldSatisfy` isJust
        interruptManagedProcess managed
        timeout 3000000 (waitForProcess process) `shouldReturn` Just (ExitFailure 42)

    it "flags a non-group-leader child at registration, then still escalates to SIGKILL via the per-PID fallback" $
      withNonLeaderShell "trap '' INT TERM; while :; do sleep 1; done" $ \process -> do
        threadDelay 100000
        (managed, groupLeaderProblem) <- managedProcess process
        groupLeaderProblem `shouldSatisfy` isJust
        killManagedProcess managed
        timeout 3000000 (waitForProcess process) `shouldReturn` Just (ExitFailure (-9))

    it "excludes a killed process from a snapshot even before its parent reaps it" $
      withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \process -> do
        threadDelay 100000
        identity <- identityForProcess process
        -- Signal the group directly, bypassing killManagedProcess/waitForProcess,
        -- so the process becomes a zombie this test process never reaps: a
        -- signalled process must not appear to survive its own confirmed kill
        -- merely because nothing has called wait() on it yet.
        signalProcessGroup sigKILL (fromIntegral identity.processIdentityGroupPid)
        threadDelay 500000
        snapshot <- readProcessSnapshot
        case snapshot of
          Left message -> expectationFailure (Data.Text.unpack message)
          Right identities -> identityForPid identity.processIdentityPid identities `shouldBe` Nothing

    it "still reaches a surviving group member after its own leader has already exited and been reaped (issue #16: the review client's tool calls and its own app-server shutdown share this primitive)" $
      -- A second process of the same shape, in a group of its own and
      -- recorded by nothing here: the group kill below has to reach this
      -- managed group and no further.
      withSurvivingGroupLeader $ \bystanderPid ->
        withTemporaryCacheRoot $ \temporaryRoot -> do
          let markerPath = temporaryRoot </> "child.pid"
          (_, _, _, leader) <-
            createProcess
              (proc "sh" ["-c", "sh -c 'trap \"\" TERM; while :; do sleep 1; done' </dev/null >/dev/null 2>&1 & echo $! > " <> markerPath <> "; exit 0"])
                { create_group = True }
          managed <- managedProcessFor leader
          -- The leader exits (and this waitForProcess reaps its handle) well
          -- before we ever signal it: `getPid`/`getProcessExitCode` on `leader`
          -- would now report it gone, which is exactly the state that used to
          -- make the old, handle-driven kill a no-op.
          timeout 3000000 (waitForProcess leader) `shouldReturn` Just ExitSuccess
          childPidText <- readFile markerPath
          let childPid = read (filter (`notElem` (" \n" :: String)) childPidText) :: Int
          killManagedProcess managed
          snapshot <- readProcessSnapshot
          case snapshot of
            Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
            Right identities -> do
              identityForPid childPid identities `shouldBe` Nothing
              identities `shouldNotHaveSwept` bystanderPid

    it "round-trips the durable worker protocol including autosolve parent identity" $ do
      let parent =
            WorkerParent
              { workerParentIssueNumber = 782,
                workerParentReviewRound = 2,
                workerParentSolverBrand = CodexSolver,
                workerParentSolverSession = Just "solver-session",
                workerParentSolverLogPath = Just "/tmp/solver.jsonl",
                workerParentStartedAt = epoch,
                workerParentKnownPullRequests = Set.fromList [857, 858],
                -- The solver's own cell, distinct from the reviewer's below:
                -- a decoder that dropped this would hand a restarted
                -- revision the wrong provider.
                workerParentSolverAssignment = Just (RecordedAssignment CodexProvider "codex-recorded" "high" "Recorded Codex")
              }
          spec =
            WorkerSpec
              { workerId = WorkerId "pr-858-test",
                workerRepository = Repository "/tmp/repo" "example" "project",
                workerTask = PullRequestWorkerTaskKind (PullRequestWorkerTask 858 PullRequestCodex PullRequestRereview),
                workerExistingSession = Just "review-session",
                workerExistingLogPath = Just "/tmp/review.jsonl",
                workerResumeProvenance = ResumeInterruptGuidance,
                workerUserMessage = "continue",
                workerParent = Just parent,
                workerCreatedAt = epoch,
                workerMaxRuntimeSeconds = 14400,
                workerConfigPath = Nothing,
                workerWorkflowConfig = defaultWorkflowConfig,
                -- The additive assignment field has to survive the round
                -- trip too: a spec that loses it on decode is one the
                -- supervisor then refuses to spawn from. Deliberately not
                -- this build's default cell, and deliberately the provider
                -- this task does /not/ route to today, so a decoder that
                -- dropped either could not pass.
                workerAssignment = Just (RecordedAssignment ClaudeProvider "claude-recorded" "xhigh" "Recorded Claude")
              }
      eitherDecode (encode spec) `shouldBe` Right spec
      -- Every PR action a key can spawn has to survive the durable spec, or
      -- a dashboard restart reattaches the worker as the wrong workflow.
      let repairSpec = spec {workerTask = PullRequestWorkerTaskKind (PullRequestWorkerTask 858 PullRequestClaude PullRequestRepair)}
      eitherDecode (encode repairSpec) `shouldBe` Right repairSpec
      eitherDecode (encode (WorkerFinished (SolveNeedsInput "choose a branch")))
        `shouldBe` Right (WorkerFinished (SolveNeedsInput "choose a branch"))
      let orphan = processIdentity 901 1 901 "diagnostic engine"
      eitherDecode (encode (WorkerOrphansDetected SolveCompleted [orphan]))
        `shouldBe` Right (WorkerOrphansDetected SolveCompleted [orphan])

    it "loads pre-census worker state with an empty process inventory" $ do
      let legacyState =
            object
              [ "workerStateId" .= WorkerId "legacy-worker",
                "workerStateStatus" .= WorkerRunning,
                "workerStateWorkerPid" .= (42 :: Int),
                "workerStateProviderPid" .= (Nothing :: Maybe Int),
                "workerStateSessionId" .= (Nothing :: Maybe Text),
                "workerStateLogPath" .= (Nothing :: Maybe FilePath),
                "workerStateHeartbeatAt" .= epoch,
                "workerStateLastActivity" .= ("running" :: Text)
              ]
      let decodedState = eitherDecode (encode legacyState) :: Either String WorkerState
      case decodedState of
        Left message -> expectationFailure message
        Right state -> do
          state.workerStateKnownProcesses `shouldBe` []
          state.workerStateWorkerIdentity `shouldBe` Nothing
          state.workerStateProviderIdentity `shouldBe` Nothing

    it "finds the full descendant tree without sweeping unrelated processes" $ do
      let root = processIdentity 100 1 100 "provider"
          child = processIdentity 101 100 100 "shell"
          grandchild = processIdentity 102 101 102 "engine"
          unrelated = processIdentity 200 1 200 "interactive agent"
      descendantProcesses [100] [unrelated, grandchild, root, child]
        `shouldBe` [grandchild, root, child]

    it "drops a recorded identity whose PID now belongs to a different process or has exited" $ do
      let alive = processIdentity 100 1 100 "provider"
          reused = processIdentity 101 1 101 "recorded-child"
          reusedNow = reused {processIdentityCommand = "unrelated-process", processIdentityStartedAt = "Fri Jul 17 13:00:00 2026"}
          exited = processIdentity 102 1 102 "exited-child"
          snapshot = [alive, reusedNow]
      matchingIdentities snapshot [alive, reused, exited] `shouldBe` [alive]

    it "drops a matching identity that changed process groups" $ do
      let anchor = processIdentity 100 1 100 "provider"
          movedGroup = anchor {processIdentityGroupPid = 105}
      membersStillInGroup 100 [anchor] [anchor] `shouldBe` [anchor]
      membersStillInGroup 100 [movedGroup] [anchor] `shouldBe` []

    it "sends the KILL once the grace window elapses and the group still matches, then verifies it exited" $
      withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \process -> do
        threadDelay 100000
        identity <- identityForProcess process
        callCount <- newIORef (0 :: Int)
        let takeSnapshot = do
              count <- readIORef callCount
              modifyIORef callCount (+ 1)
              pure (if count < 2 then Right [identity] else Right [])
        killVerifiedGroupWith takeSnapshot identity.processIdentityGroupPid [identity] `shouldReturn` Right ()
        timeout 3000000 (waitForProcess process) `shouldReturn` Just (ExitFailure (-9))

    it "reports inconclusive when a group survives verification after SIGKILL" $
      withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \process -> do
        threadDelay 100000
        identity <- identityForProcess process
        let takeSnapshot = pure (Right [identity])
        killVerifiedGroupWith takeSnapshot identity.processIdentityGroupPid [identity]
          `shouldReturn` Left "signalled group did not exit after SIGKILL"

    it "omits the KILL when the group's identity no longer matches after the grace window" $
      withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \process -> do
        threadDelay 100000
        identity <- identityForProcess process
        callCount <- newIORef (0 :: Int)
        let takeSnapshot = do
              count <- readIORef callCount
              modifyIORef callCount (+ 1)
              pure (if count == 0 then Right [identity] else Right [])
        killVerifiedGroupWith takeSnapshot identity.processIdentityGroupPid [identity] `shouldReturn` Right ()
        getProcessExitCode process `shouldReturn` Nothing

    it "omits the KILL when the same PID and start time have moved to a different, recyclable group" $
      withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \process -> do
        threadDelay 100000
        identity <- identityForProcess process
        callCount <- newIORef (0 :: Int)
        let movedGroup = identity {processIdentityGroupPid = identity.processIdentityGroupPid + 1}
            takeSnapshot = do
              count <- readIORef callCount
              modifyIORef callCount (+ 1)
              pure (Right [if count == 0 then identity else movedGroup])
        killVerifiedGroupWith takeSnapshot identity.processIdentityGroupPid [identity] `shouldReturn` Right ()
        getProcessExitCode process `shouldReturn` Nothing

    it "omits every signal when the verification snapshot fails" $
      withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \process -> do
        threadDelay 100000
        identity <- identityForProcess process
        let takeSnapshot = pure (Left "ps unavailable")
        killVerifiedGroupWith takeSnapshot identity.processIdentityGroupPid [identity] `shouldReturn` Left "ps unavailable"
        getProcessExitCode process `shouldReturn` Nothing
        checkGroupMembershipWith takeSnapshot identity.processIdentityGroupPid [identity] `shouldReturn` IdentitySnapshotFailed "ps unavailable"

    it "atomically refuses a second live lease for the same issue" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            firstSpec = workerFixtureSpec repository (WorkerId "solve-782-first") 782
            secondSpec = workerFixtureSpec repository (WorkerId "solve-782-second") 782
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile (workerRoot </> "solve-782-first.spec.json") (encode firstSpec)
        LazyByteString.writeFile (workerRoot </> "solve-782-second.spec.json") (encode secondSpec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case (find ((== firstSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors, find ((== secondSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors) of
            (Just first, Just second) -> do
              acquireWorkerLease first `shouldReturn` Right ()
              acquireWorkerLease second `shouldReturn` Left "issue #782 already has a live solve worker; open it from Processes or kill it before starting another"
              releaseWorkerLease first
              acquireWorkerLease second `shouldReturn` Right ()
              releaseWorkerLease second
            _ -> expectationFailure "worker fixtures were not discoverable"

    it "retires a stale lease once its recorded worker no longer matches its identity" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            firstSpec = workerFixtureSpec repository (WorkerId "solve-783-stale") 783
            secondSpec = workerFixtureSpec repository (WorkerId "solve-783-fresh") 783
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            statePath = workerRoot </> "solve-783-stale.state.json"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile (workerRoot </> "solve-783-stale.spec.json") (encode firstSpec)
        LazyByteString.writeFile (workerRoot </> "solve-783-fresh.spec.json") (encode secondSpec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case (find ((== firstSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors, find ((== secondSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors) of
            (Just first, Just second) -> do
              acquireWorkerLease first `shouldReturn` Right ()
              ownPid <- fromIntegral <$> getProcessID
              snapshot <- readProcessSnapshot
              case snapshot of
                Left message -> expectationFailure (Data.Text.unpack message)
                Right identities -> case identityForPid ownPid identities of
                  Nothing -> expectationFailure "could not find this test process in a process snapshot"
                  Just realIdentity -> do
                    let mismatched = realIdentity {processIdentityStartedAt = "Wed Jan 01 00:00:00 2020"}
                    LazyByteString.writeFile statePath (encode (runningWorkerState firstSpec.workerId ownPid (Just mismatched)))
                    acquireWorkerLease second `shouldReturn` Right ()
                    releaseWorkerLease second
            _ -> expectationFailure "worker fixtures were not discoverable"

    it "does not retire a lease with a pending user termination even once its supervisor identity is gone" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            firstSpec = workerFixtureSpec repository (WorkerId "solve-791-pending") 791
            secondSpec = workerFixtureSpec repository (WorkerId "solve-791-fresh") 791
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            statePath = workerRoot </> "solve-791-pending.state.json"
            pendingTerminationPath = workerRoot </> "solve-791-pending.pending-termination"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile (workerRoot </> "solve-791-pending.spec.json") (encode firstSpec)
        LazyByteString.writeFile (workerRoot </> "solve-791-fresh.spec.json") (encode secondSpec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case (find ((== firstSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors, find ((== secondSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors) of
            (Just first, Just second) -> do
              acquireWorkerLease first `shouldReturn` Right ()
              ownPid <- fromIntegral <$> getProcessID
              snapshot <- readProcessSnapshot
              case snapshot of
                Left message -> expectationFailure (Data.Text.unpack message)
                Right identities -> case identityForPid ownPid identities of
                  Nothing -> expectationFailure "could not find this test process in a process snapshot"
                  Just realIdentity -> do
                    -- Status stays WorkerRunning (never reaches WorkerOrphaned):
                    -- the supervisor exited before it ever learned about a
                    -- pending user termination it could not verify, so only
                    -- the marker file records that intent.
                    let mismatched = realIdentity {processIdentityStartedAt = "Wed Jan 01 00:00:00 2020"}
                    LazyByteString.writeFile statePath (encode (runningWorkerState firstSpec.workerId ownPid (Just mismatched)))
                    ByteString.writeFile pendingTerminationPath "pending\n"
                    acquireWorkerLease second `shouldReturn` Left "issue #791 already has a live solve worker; open it from Processes or kill it before starting another"
                    removeFile pendingTerminationPath
                    acquireWorkerLease second `shouldReturn` Right ()
                    releaseWorkerLease second
            _ -> expectationFailure "worker fixtures were not discoverable"

    it "does not retire a lease when the recorded worker has no verifiable identity" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            firstSpec = workerFixtureSpec repository (WorkerId "solve-784-legacy") 784
            secondSpec = workerFixtureSpec repository (WorkerId "solve-784-fresh") 784
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            statePath = workerRoot </> "solve-784-legacy.state.json"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile (workerRoot </> "solve-784-legacy.spec.json") (encode firstSpec)
        LazyByteString.writeFile (workerRoot </> "solve-784-fresh.spec.json") (encode secondSpec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case (find ((== firstSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors, find ((== secondSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors) of
            (Just first, Just second) -> do
              acquireWorkerLease first `shouldReturn` Right ()
              LazyByteString.writeFile statePath (encode (runningWorkerState firstSpec.workerId 999999 Nothing))
              acquireWorkerLease second `shouldReturn` Left "issue #784 already has a live solve worker; open it from Processes or kill it before starting another"
              releaseWorkerLease first
            _ -> expectationFailure "worker fixtures were not discoverable"

    it "fails a worker closed once its heartbeat is stale and its recorded identity no longer matches" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec = workerFixtureSpec repository (WorkerId "solve-785-mismatch") 785
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            statePath = workerRoot </> "solve-785-mismatch.state.json"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile (workerRoot </> "solve-785-mismatch.spec.json") (encode spec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
            Nothing -> expectationFailure "worker fixture was not discoverable"
            Just descriptor -> do
              ownPid <- fromIntegral <$> getProcessID
              snapshot <- readProcessSnapshot
              case snapshot of
                Left message -> expectationFailure (Data.Text.unpack message)
                Right identities -> case identityForPid ownPid identities of
                  Nothing -> expectationFailure "could not find this test process in a process snapshot"
                  Just realIdentity -> do
                    let mismatched = realIdentity {processIdentityStartedAt = "Wed Jan 01 00:00:00 2020"}
                    LazyByteString.writeFile statePath (encode (runningWorkerState spec.workerId ownPid (Just mismatched)))
                    collected <- newIORef []
                    let collect _ _ event = modifyIORef collected (event :)
                    timeout 5000000 (monitorWorker descriptor collect) `shouldReturn` Just ()
                    events <- reverse <$> readIORef collected
                    events `shouldSatisfy` any isDiagnosticEvent
                    events `shouldSatisfy` any isWorkerFailedEvent
                    finalState <- waitForWorkerState statePath isTerminal 30
                    finalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed "persistent worker stopped unexpectedly; its provider process group was terminated")

    it "persists a worker heartbeat, provider identity, journal, and terminal outcome" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            identifier = WorkerId "solve-782-fixture"
            repository = Repository repositoryRoot "coghex" "kanban"
            spec =
              WorkerSpec
                { workerId = identifier,
                  workerRepository = repository,
                  workerTask = SolveWorkerTaskKind (SolveWorkerTask 782 SolveOnly CodexSolver),
                  workerExistingSession = Nothing,
                  workerExistingLogPath = Nothing,
                  workerResumeProvenance = ResumeAnswer,
                  workerUserMessage = "",
                  workerParent = Nothing,
                  workerCreatedAt = now,
                  workerMaxRuntimeSeconds = 60,
                  workerConfigPath = Nothing,
                  workerWorkflowConfig = defaultWorkflowConfig,
                  workerAssignment = Just workerFixtureAssignment
                }
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-782-fixture.spec.json"
            statePath = workerRoot </> "solve-782-fixture.state.json"
            eventPath = workerRoot </> "solve-782-fixture.events.jsonl"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        createDirectoryIfMissing True workerRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"fixture-session\"}'",
                "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Created PR #999\"}}'"
              ]
          )
        setFileMode fakeCodex 0o700
        LazyByteString.writeFile specPath (encode spec)
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            runWorker specPath `shouldReturn` Right ()
            stateBytes <- LazyByteString.readFile statePath
            let decodedState = eitherDecode stateBytes :: Either String WorkerState
            case decodedState of
              Left message -> expectationFailure message
              Right workerState -> do
                workerState.workerStateStatus `shouldBe` WorkerTerminal SolveCompleted
                workerState.workerStateSessionId `shouldBe` Just "fixture-session"
                workerState.workerStateProviderPid `shouldBe` Nothing
                workerState.workerStateProviderIdentity `shouldBe` Nothing
                workerState.workerStateWorkerIdentity `shouldSatisfy` isJust
            eventBytes <- ByteString.readFile eventPath
            eventBytes `shouldSatisfy` ByteString.isInfixOf "WorkerProviderStarted"
            eventBytes `shouldSatisfy` ByteString.isInfixOf "fixture-session"
            eventBytes `shouldSatisfy` ByteString.isInfixOf "WorkerFinished"

    it "waits out a sample already being written before the seal returns, and refuses every one after" $ do
      -- The interleaving a bare compare-and-swap cannot cover: the stream
      -- thread has already been told to emit a sample and is part-way
      -- through writing it. If the seal could return here, a supervisor
      -- would write the aggregate and the terminal envelope while that
      -- sample was still in flight, landing it after the envelope where
      -- replay stops — or losing it to the cancellation that follows.
      aggregator <- newUnknownAggregator
      written <- newIORef []
      writing <- newEmptyMVar
      release <- newEmptyMVar
      let blockingEmit agentEvent = do
            putMVar writing ()
            takeMVar release
            modifyIORef written (agentEvent.agentEventSummary :)
      telemetry <- case parseSolveOutputLine "{\"type\":\"telemetry\",\"tick\":1}" of
        Right (_, streamEvents) -> pure streamEvents
        Left message -> throwIO (userError ("unparsable fixture line: " <> Data.Text.unpack message))
      void . forkIO $ mapM_ (emitStreamEvent aggregator blockingEmit) telemetry
      takeMVar writing
      sealed <- newEmptyMVar
      void . forkIO $ sealUnknownAggregates aggregator (const (pure ())) >> putMVar sealed ()
      -- The seal is blocked on the in-flight write, not racing past it.
      timeout 200000 (readMVar sealed) `shouldReturn` Nothing
      readIORef written `shouldReturn` []
      putMVar release ()
      void (timeout 5000000 (takeMVar sealed) >>= requireJust "seal never completed")
      -- The sample admitted before the seal was fully written before the
      -- seal returned, so it can never trail the terminal envelope.
      readIORef written `shouldReturn` ["[event] telemetry {\"tick\":1,\"type\":\"telemetry\"}"]
      -- ...and nothing gets through afterwards.
      mapM_ (emitStreamEvent aggregator blockingEmit) telemetry
      readIORef written `shouldReturn` ["[event] telemetry {\"tick\":1,\"type\":\"telemetry\"}"]

    it "blocks a terminalizing seal until the seal that won has finished writing its summaries" $ do
      -- The flow and its supervisor race the same seal. If the loser could
      -- return the instant it saw an already-sealed aggregator, it would
      -- write the terminal envelope while the winner's summaries were still
      -- in flight — appending them past the envelope, where replay stops, or
      -- losing them to the cancellation that follows a deadline.
      aggregator <- newUnknownAggregator
      telemetry <- case parseSolveOutputLine "{\"type\":\"telemetry\",\"tick\":1}" of
        Right (_, streamEvents) -> pure streamEvents
        Left message -> throwIO (userError ("unparsable fixture line: " <> Data.Text.unpack message))
      -- Enough occurrences that the seal actually has a summary to write.
      mapM_ (const (mapM_ (emitStreamEvent aggregator (const (pure ()))) telemetry)) [1 .. unknownNoticeSamples + 5]
      journal <- newIORef []
      writing <- newEmptyMVar
      release <- newEmptyMVar
      let winnerEmit agentEvent = do
            putMVar writing ()
            takeMVar release
            modifyIORef journal (agentEvent.agentEventSummary :)
      void . forkIO $ sealUnknownAggregates aggregator winnerEmit
      takeMVar writing
      -- The losing side reaches its seal while the winner is mid-write, then
      -- would go on to write its terminal envelope.
      terminalized <- newEmptyMVar
      void . forkIO $ do
        sealUnknownAggregates aggregator (\agentEvent -> modifyIORef journal (agentEvent.agentEventSummary :))
        modifyIORef journal ("WorkerFinished" :)
        putMVar terminalized ()
      timeout 200000 (readMVar terminalized) `shouldReturn` Nothing
      putMVar release ()
      void (timeout 5000000 (takeMVar terminalized) >>= requireJust "terminalizing seal never completed")
      -- One summary, written before the terminal envelope, exactly once.
      reverse <$> readIORef journal
        `shouldReturn` ["[event] telemetry ×" <> Data.Text.pack (show (unknownNoticeSamples + 5)), "WorkerFinished"]

    it "bounds a chatty unknown type in a real solve worker's journal, replay, and session log" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec = (workerFixtureSpec repository (WorkerId "solve-930-chatty") 930) {workerCreatedAt = now}
        surfaces <- runChattyWorker temporaryRoot spec "solve-930-chatty"
        assertBoundedWorkerSurfaces surfaces

    it "bounds a chatty unknown type in a real PR worker's journal, replay, and session log" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- The PR flow owns a separate stdout loop and a separate terminal
        -- path, so it needs its own end-to-end proof rather than inheriting
        -- the solve worker's.
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec =
              (workerFixtureSpec repository (WorkerId "pr-931-chatty") 931)
                { workerCreatedAt = now,
                  workerTask = PullRequestWorkerTaskKind (PullRequestWorkerTask 931 PullRequestClaude PullRequestReview)
                }
        surfaces <- runChattyWorker temporaryRoot spec "pr-931-chatty"
        assertBoundedWorkerSurfaces surfaces

    it "marks a completed provider orphaned until its surviving child exits" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
            spec = (workerFixtureSpec repository (WorkerId "solve-783-orphan-fixture") 783) {workerCreatedAt = now}
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-783-orphan-fixture.spec.json"
            statePath = workerRoot </> "solve-783-orphan-fixture.state.json"
            eventPath = workerRoot </> "solve-783-orphan-fixture.events.jsonl"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        createDirectoryIfMissing True workerRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "sh -c 'trap \"\" TERM; while :; do sleep 1; done' </dev/null >/dev/null 2>&1 &",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"orphan-session\"}'",
                "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Created PR #999\"}}'",
                "sleep 1"
              ]
          )
        setFileMode fakeCodex 0o700
        LazyByteString.writeFile specPath (encode spec)
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            finished <- newEmptyMVar
            void . forkIO $ runWorker specPath >>= putMVar finished
            orphanState <- waitForWorkerState statePath isOrphaned 80
            orphanState.workerStateStatus `shouldBe` WorkerOrphaned SolveCompleted
            survivingResult <- liveProcesses orphanState.workerStateKnownProcesses
            surviving <- case survivingResult of
              Left message -> fail ("expected a successful snapshot, not a query failure: " <> Data.Text.unpack message)
              Right identities -> pure identities
            surviving `shouldNotBe` []
            let groups = Set.toList (Set.fromList (map processIdentityGroupPid surviving))
            mapM_ (killManagedProcess . managedProcessGroup . fromIntegral) groups
            timeout 5000000 (takeMVar finished) `shouldReturn` Just (Right ())
            terminalState <- waitForWorkerState statePath isTerminal 30
            terminalState.workerStateStatus `shouldBe` WorkerTerminal SolveCompleted
            eventBytes <- ByteString.readFile eventPath
            eventBytes `shouldSatisfy` ByteString.isInfixOf "WorkerOrphansDetected"
            eventBytes `shouldSatisfy` ByteString.isInfixOf "WorkerFinished"

    it "keeps a completed provider pending while descendant verification fails, then completes once a snapshot succeeds" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
            spec = (workerFixtureSpec repository (WorkerId "solve-787-verify-fixture") 787) {workerCreatedAt = now}
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-787-verify-fixture.spec.json"
            statePath = workerRoot </> "solve-787-verify-fixture.state.json"
            eventPath = workerRoot </> "solve-787-verify-fixture.events.jsonl"
            leasePath = workerRoot </> "issue-787.lease"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        createDirectoryIfMissing True workerRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "sh -c 'trap \"\" TERM; while :; do sleep 1; done' </dev/null >/dev/null 2>&1 &",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"verify-session\"}'",
                "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Created PR #999\"}}'",
                "sleep 1"
              ]
          )
        setFileMode fakeCodex 0o700
        LazyByteString.writeFile specPath (encode spec)
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            -- runWorkerWith assumes its caller already holds the lease, as
            -- launchWorker does in production; acquire it explicitly so
            -- releaseWorkerLease's behavior at the end is meaningfully
            -- exercised.
            descriptors <- discoverWorkerHistory repository
            case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
              Nothing -> expectationFailure "worker fixture was not discoverable"
              Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
            failing <- newIORef True
            let flakySnapshot = do
                  stillFailing <- readIORef failing
                  if stillFailing then pure (Left "simulated ps outage") else readProcessSnapshot
            finished <- newEmptyMVar
            void . forkIO $ runWorkerWith flakySnapshot specPath >>= putMVar finished
            pendingState <- waitForWorkerState statePath isOrphaned 80
            pendingState.workerStateStatus `shouldBe` WorkerOrphaned SolveCompleted
            leaseHeldWhileUnverified <- doesDirectoryExist leasePath
            leaseHeldWhileUnverified `shouldBe` True
            threadDelay 1200000
            stillPending <- waitForWorkerState statePath isOrphaned 5
            stillPending.workerStateStatus `shouldBe` WorkerOrphaned SolveCompleted
            eventBytesWhileFailing <- ByteString.readFile eventPath
            eventBytesWhileFailing `shouldNotSatisfy` ByteString.isInfixOf "WorkerFinished"
            eventBytesWhileFailing `shouldSatisfy` ByteString.isInfixOf "could not verify recorded descendants"
            let diagnosticCount = length (filter (ByteString.isInfixOf "could not verify recorded descendants") (ByteString.lines eventBytesWhileFailing))
            diagnosticCount `shouldSatisfy` \count -> count >= 1 && count <= 3
            survivingResult <- liveProcesses stillPending.workerStateKnownProcesses
            case survivingResult of
              Left message -> fail ("expected a successful snapshot to identify the survivor to clean up: " <> Data.Text.unpack message)
              Right identities -> do
                let groups = Set.toList (Set.fromList (map processIdentityGroupPid identities))
                mapM_ (killManagedProcess . managedProcessGroup . fromIntegral) groups
            writeIORef failing False
            timeout 10000000 (takeMVar finished) `shouldReturn` Just (Right ())
            terminalState <- waitForWorkerState statePath isTerminal 30
            terminalState.workerStateStatus `shouldBe` WorkerTerminal SolveCompleted
            leaseReleased <- doesDirectoryExist leasePath
            leaseReleased `shouldBe` False

    it "keeps the lease held when a signal-triggered shutdown cannot verify recorded descendants are gone" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            fakePs = binaryRoot </> "ps"
            snapshotFailureMarker = temporaryRoot </> "fail-process-snapshots"
            repository = Repository repositoryRoot "coghex" "kanban"
            spec = (workerFixtureSpec repository (WorkerId "solve-788-signal-fixture") 788) {workerCreatedAt = now}
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-788-signal-fixture.spec.json"
            statePath = workerRoot </> "solve-788-signal-fixture.state.json"
            leasePath = workerRoot </> "issue-788.lease"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        createDirectoryIfMissing True workerRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "sh -c 'trap \"\" TERM; while :; do sleep 1; done' </dev/null >/dev/null 2>&1 &",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"signal-session\"}'",
                "while :; do sleep 1; done"
              ]
          )
        setFileMode fakeCodex 0o700
        ByteString.writeFile
          fakePs
          ( ByteString.unlines
              [ "#!/bin/sh",
                "if [ -e \"$KANBAN_PS_FAILURE_MARKER\" ]; then exit 1; fi",
                "exec /bin/ps \"$@\""
              ]
          )
        setFileMode fakePs 0o700
        LazyByteString.writeFile specPath (encode spec)
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $
            withEnvironmentValue "KANBAN_PS_FAILURE_MARKER" snapshotFailureMarker $ do
            -- runWorkerWith assumes its caller already holds the lease, as
            -- launchWorker does in production; acquire it explicitly so
            -- releaseWorkerLease's behavior at the end is meaningfully
            -- exercised.
            descriptors <- discoverWorkerHistory repository
            case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
              Nothing -> expectationFailure "worker fixture was not discoverable"
              Just descriptor -> acquireWorkerLease descriptor `shouldReturn` Right ()
            finished <- newEmptyMVar
            let cleanup = do
                  snapshotFailureEnabled <- doesFileExist snapshotFailureMarker
                  when snapshotFailureEnabled (removeFile snapshotFailureMarker)
                  stateBytes <- LazyByteString.readFile statePath
                  case (eitherDecode stateBytes :: Either String WorkerState) of
                    Right state -> do
                      let groups = Set.toList (Set.fromList (map processIdentityGroupPid state.workerStateKnownProcesses))
                      mapM_ (killManagedProcess . managedProcessGroup . fromIntegral) groups
                    Left _ -> pure ()
                  timeout 10000000 (takeMVar finished) `shouldReturn` Just (Right ())
            void . forkIO $ runWorkerWith readProcessSnapshot specPath >>= putMVar finished
            ( do
                -- WorkerRunning is published as soon as the provider itself
                -- is registered, before this fixture's background child has
                -- necessarily started or reached the next census. Wait for
                -- the descendant to be durably recorded so the signal below
                -- always exercises failed verification of known work rather
                -- than racing executable startup on slower platforms.
                _ <-
                  waitForWorkerState
                    statePath
                    (\state -> case state.workerStateStatus of
                      WorkerRunning ->
                        case state.workerStateProviderPid of
                          Nothing -> False
                          Just providerPid ->
                            any
                              ((/= providerPid) . processIdentityPid)
                              state.workerStateKnownProcesses
                      _ -> False
                    )
                    80
                -- Discovery above deliberately uses real process snapshots.
                -- Fail those snapshots only now, after the descendant is a
                -- known part of the worker census, so shutdown cannot prune
                -- it before verification observes the outage.
                ByteString.writeFile snapshotFailureMarker "fail"
                raiseSignal sigTERM
                pendingState <- waitForWorkerState statePath isOrphaned 80
                pendingState.workerStateStatus `shouldSatisfy` \status -> case status of
                  WorkerOrphaned _ -> True
                  _ -> False
                leaseHeldDuringShutdown <- doesDirectoryExist leasePath
                leaseHeldDuringShutdown `shouldBe` True
              )
              `finally` cleanup
            _ <- waitForWorkerState statePath isTerminal 30
            leaseReleased <- doesDirectoryExist leasePath
            leaseReleased `shouldBe` False

    it "retains a pending user termination until a snapshot verifies recorded descendants are gone" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec = workerFixtureSpec repository (WorkerId "solve-789-terminate-fixture") 789
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            statePath = workerRoot </> "solve-789-terminate-fixture.state.json"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile (workerRoot </> "solve-789-terminate-fixture.spec.json") (encode spec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
            Nothing -> expectationFailure "worker fixture was not discoverable"
            Just descriptor ->
              withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \selfProcess ->
                withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \descendantProcess -> do
                  selfIdentity <- identityForProcess selfProcess
                  descendantIdentity <- identityForProcess descendantProcess
                  now <- getCurrentTime
                  acquireWorkerLease descriptor `shouldReturn` Right ()
                  let state =
                        (runningWorkerState spec.workerId selfIdentity.processIdentityPid (Just selfIdentity))
                          { workerStateHeartbeatAt = now,
                            workerStateKnownProcesses = [descendantIdentity]
                          }
                  LazyByteString.writeFile statePath (encode state)
                  let failingSnapshot = pure (Left "simulated ps outage")
                  terminateWorkerWith failingSnapshot descriptor
                  pendingMarkerExists <- doesFileExist descriptor.workerDescriptorPendingTerminationPath
                  pendingMarkerExists `shouldBe` True
                  pendingState <- waitForWorkerState statePath (const True) 1
                  pendingState `shouldNotSatisfy` isTerminal
                  leaseHeld <- doesDirectoryExist descriptor.workerDescriptorLeasePath
                  leaseHeld `shouldBe` True
                  getProcessExitCode descendantProcess `shouldReturn` Nothing
                  eventBytes <- ByteString.readFile descriptor.workerDescriptorEventPath
                  let diagnosticLines message = filter (ByteString.isInfixOf message) (ByteString.lines eventBytes)
                  length (diagnosticLines "could not verify recorded descendants") `shouldBe` 1
                  terminateWorkerWith failingSnapshot descriptor
                  eventBytesAfterRetry <- ByteString.readFile descriptor.workerDescriptorEventPath
                  length (filter (ByteString.isInfixOf "could not verify recorded descendants") (ByteString.lines eventBytesAfterRetry)) `shouldBe` 1
                  managedProcessFor descendantProcess >>= killManagedProcess
                  void (timeout 3000000 (waitForProcess descendantProcess))
                  collected <- newIORef []
                  let collect _ _ event = modifyIORef collected (event :)
                  completed <- recoverIfWorkerStoppedWith readProcessSnapshot descriptor collect 0
                  completed `shouldBe` True
                  finalState <- waitForWorkerState statePath isTerminal 30
                  finalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed "killed by user")
                  leaseReleased <- doesDirectoryExist descriptor.workerDescriptorLeasePath
                  leaseReleased `shouldBe` False
                  events <- reverse <$> readIORef collected
                  events `shouldSatisfy` any (== WorkerFinished (SolveFailed "killed by user"))

    it "retains orphan state during stale-supervisor recovery until a snapshot verifies recorded descendants are gone" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec = workerFixtureSpec repository (WorkerId "solve-790-stale-fixture") 790
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            statePath = workerRoot </> "solve-790-stale-fixture.state.json"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile (workerRoot </> "solve-790-stale-fixture.spec.json") (encode spec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
            Nothing -> expectationFailure "worker fixture was not discoverable"
            Just descriptor ->
              withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \descendantProcess -> do
                deadSupervisorIdentity <- withManagedShell "sleep 0.3" $ \shortLived -> do
                  identity <- identityForProcess shortLived
                  void (waitForProcess shortLived)
                  pure identity
                descendantIdentity <- identityForProcess descendantProcess
                acquireWorkerLease descriptor `shouldReturn` Right ()
                let state =
                      (runningWorkerState spec.workerId deadSupervisorIdentity.processIdentityPid (Just deadSupervisorIdentity))
                        { workerStateKnownProcesses = [descendantIdentity]
                        }
                LazyByteString.writeFile statePath (encode state)
                callCount <- newIORef (0 :: Int)
                let flaky = do
                      count <- readIORef callCount
                      modifyIORef callCount (+ 1)
                      if even count then readProcessSnapshot else pure (Left "simulated ps outage")
                collected <- newIORef []
                let collect _ _ event = modifyIORef collected (event :)
                recovered1 <- recoverIfWorkerStoppedWith flaky descriptor collect 0
                recovered1 `shouldBe` False
                pendingState <- waitForWorkerState statePath isOrphaned 30
                case pendingState.workerStateStatus of
                  WorkerOrphaned (SolveFailed message) -> Data.Text.unpack message `shouldContain` "stale-supervisor recovery"
                  other -> expectationFailure ("expected a pending stale-recovery orphan status, got " <> show other)
                leaseHeld <- doesDirectoryExist descriptor.workerDescriptorLeasePath
                leaseHeld `shouldBe` True
                recovered2 <- recoverIfWorkerStoppedWith flaky descriptor collect 0
                recovered2 `shouldBe` False
                diagnosticsSoFar <- reverse <$> readIORef collected
                length (filter isDiagnosticEvent diagnosticsSoFar) `shouldBe` 1
                managedProcessFor descendantProcess >>= killManagedProcess
                void (timeout 3000000 (waitForProcess descendantProcess))
                recovered3 <- recoverIfWorkerStoppedWith readProcessSnapshot descriptor collect 0
                recovered3 `shouldBe` True
                finalState <- waitForWorkerState statePath isTerminal 30
                finalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed "persistent worker stopped unexpectedly; its provider process group was terminated")
                leaseReleased <- doesDirectoryExist descriptor.workerDescriptorLeasePath
                leaseReleased `shouldBe` False

    it "does not consume an unterminated trailing journal line, and consumes it once the newline arrives" $ do
      let partialLine = "{\"a\":1}"
          (unseenPartial, offsetPartial) = consumeJournalLines 0 partialLine
      unseenPartial `shouldBe` []
      offsetPartial `shouldBe` 0
      let completed = partialLine <> "\n"
          (unseenCompleted, offsetCompleted) = consumeJournalLines offsetPartial completed
      unseenCompleted `shouldBe` [partialLine]
      offsetCompleted `shouldBe` ByteString.length completed

    it "neither replays nor skips a line when consumption resumes at an unchanged offset after a failed read" $ do
      let journal = "{\"a\":1}\n{\"a\":2}\n"
          (firstBatch, afterFirst) = consumeJournalLines 0 journal
      firstBatch `shouldBe` ["{\"a\":1}", "{\"a\":2}"]
      -- A transient read failure must leave the offset unchanged; re-running
      -- consumption against the same unchanged content from that offset
      -- must not repeat anything already consumed.
      let (retryBatch, retryOffset) = consumeJournalLines afterFirst journal
      retryBatch `shouldBe` []
      retryOffset `shouldBe` afterFirst

    it "yields each complete journal line exactly once, in order, for any way of splitting its growth into read chunks" $ do
      let fullJournal = ByteString.concat ["{\"a\":1}\n", "{\"a\":2}\n", "{\"a\":3}\n", "{\"a\":4}\n"]
          expectedLines = ["{\"a\":1}", "{\"a\":2}", "{\"a\":3}", "{\"a\":4}"]
          totalLength = ByteString.length fullJournal
          -- Models re-reading the journal's full contents at successive
          -- points in its growth, exactly as 'monitorWorker' re-reads the
          -- whole file on every poll: each "chunk" is the file's full
          -- prefix at that point in time, not an incremental delta.
          consumeAcrossGrowth points = go 0 points []
            where
              go _ [] acc = acc
              go consumed (point : rest) acc =
                let (unseen, newConsumed) = consumeJournalLines consumed (ByteString.take point fullJournal)
                 in go newConsumed rest (acc <> unseen)
          growthPatterns =
            [ [totalLength],
              [8, totalLength],
              [1, 9, 16, totalLength],
              [4, 8, 8, 15, 24, totalLength],
              [0 .. totalLength]
            ]
      mapM_ (\points -> consumeAcrossGrowth points `shouldBe` expectedLines) growthPatterns

    it "delivers every journal event exactly once across a transient, non-ENOENT read failure between polls" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec = workerFixtureSpec repository (WorkerId "solve-8001-transient-read-failure") 8001
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            statePath = workerRoot </> "solve-8001-transient-read-failure.state.json"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile (workerRoot </> "solve-8001-transient-read-failure.spec.json") (encode spec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
            Nothing -> expectationFailure "worker fixture was not discoverable"
            Just descriptor -> do
              -- A fresh heartbeat keeps every recovery pass on the
              -- quick-return "pending termination? no" path for the
              -- duration of this test, so only the journal read itself is
              -- under test.
              now <- getCurrentTime
              LazyByteString.writeFile statePath (encode (runningWorkerState spec.workerId 999999 Nothing) {workerStateHeartbeatAt = now})
              LazyByteString.writeFile descriptor.workerDescriptorEventPath (encode (WorkerEnvelope now (WorkerDiagnostic "one")) <> "\n")
              collected <- newIORef []
              let collect _ _ event = modifyIORef collected (event :)
                  waitUntil predicate attempts
                    | attempts <= (0 :: Int) = expectationFailure "condition was not met in time"
                    | otherwise = do
                        value <- reverse <$> readIORef collected
                        if predicate value then pure () else threadDelay 50000 >> waitUntil predicate (attempts - 1)
              finished <- newEmptyMVar
              void . forkIO $ monitorWorker descriptor collect >> putMVar finished ()
              waitUntil (== [WorkerDiagnostic "one"]) 60
              -- Blacking out read (and write) permission on the journal
              -- forces 'ByteString.readFile' to fail with a permission
              -- error rather than "does not exist", simulating the
              -- transient EINTR/EMFILE races issue #8 describes. Several
              -- ~200ms poll intervals elapse while it stays unreadable.
              setFileMode descriptor.workerDescriptorEventPath 0o000
              threadDelay 700000
              setFileMode descriptor.workerDescriptorEventPath 0o600
              eventsAfterOutage <- reverse <$> readIORef collected
              eventsAfterOutage `shouldBe` [WorkerDiagnostic "one"]
              later <- getCurrentTime
              LazyByteString.appendFile descriptor.workerDescriptorEventPath (encode (WorkerEnvelope later (WorkerDiagnostic "two")) <> "\n")
              finishedAt <- getCurrentTime
              LazyByteString.appendFile descriptor.workerDescriptorEventPath (encode (WorkerEnvelope finishedAt (WorkerFinished SolveCompleted)) <> "\n")
              timeout 5000000 (takeMVar finished) `shouldReturn` Just ()
              finalEvents <- reverse <$> readIORef collected
              finalEvents `shouldBe` [WorkerDiagnostic "one", WorkerDiagnostic "two", WorkerFinished SolveCompleted]

    it "drains journal events appended after the last poll before finalizing recovery, delivering exactly one WorkerFinished" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \descendantProcess -> do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              spec = workerFixtureSpec repository (WorkerId "solve-8002-recovery-drain") 8002
              workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
              statePath = workerRoot </> "solve-8002-recovery-drain.state.json"
          createDirectory repository.repositoryRoot
          createDirectoryIfMissing True workerRoot
          LazyByteString.writeFile (workerRoot </> "solve-8002-recovery-drain.spec.json") (encode spec)
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            descriptors <- discoverWorkerHistory repository
            case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
              Nothing -> expectationFailure "worker fixture was not discoverable"
              Just descriptor -> do
                acquireWorkerLease descriptor `shouldReturn` Right ()
                descendantIdentity <- identityForProcess descendantProcess
                let liveTerminalState =
                      (runningWorkerState spec.workerId 999999 Nothing)
                        { workerStateStatus = WorkerTerminal SolveCompleted,
                          workerStateKnownProcesses = [descendantIdentity]
                        }
                LazyByteString.writeFile statePath (encode liveTerminalState)
                collected <- newIORef []
                let collect _ _ event = modifyIORef collected (event :)
                -- The descendant is still live, so this pass must not
                -- finalize -- mirroring a monitor poll that ran before the
                -- tail event below was ever appended.
                recovered1 <- recoverIfWorkerStoppedWith readProcessSnapshot descriptor collect 0
                recovered1 `shouldBe` False
                -- Simulates the real terminal envelope landing in the
                -- journal (e.g. written by the worker itself) in the crash
                -- window between the monitor's last read and this recovery
                -- pass finalizing.
                tailAt <- getCurrentTime
                LazyByteString.appendFile descriptor.workerDescriptorEventPath (encode (WorkerEnvelope tailAt (WorkerFinished SolveCompleted)) <> "\n")
                managedProcessFor descendantProcess >>= killManagedProcess
                void (timeout 3000000 (waitForProcess descendantProcess))
                recovered2 <- recoverIfWorkerStoppedWith readProcessSnapshot descriptor collect 0
                recovered2 `shouldBe` True
                leaseReleased <- doesDirectoryExist descriptor.workerDescriptorLeasePath
                leaseReleased `shouldBe` False
                -- Exactly the drained real 'WorkerFinished' is delivered;
                -- the branch's own synthetic one must be suppressed rather
                -- than appended as a duplicate.
                finalEvents <- reverse <$> readIORef collected
                finalEvents `shouldBe` [WorkerFinished SolveCompleted]

    it "aborts a recovery finalize (no lease release, no events) when its final journal drain read fails, then finalizes once the read succeeds" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \descendantProcess -> do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              spec = workerFixtureSpec repository (WorkerId "solve-8003-recovery-drain-failure") 8003
              workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
              statePath = workerRoot </> "solve-8003-recovery-drain-failure.state.json"
          createDirectory repository.repositoryRoot
          createDirectoryIfMissing True workerRoot
          LazyByteString.writeFile (workerRoot </> "solve-8003-recovery-drain-failure.spec.json") (encode spec)
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            descriptors <- discoverWorkerHistory repository
            case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
              Nothing -> expectationFailure "worker fixture was not discoverable"
              Just descriptor -> do
                acquireWorkerLease descriptor `shouldReturn` Right ()
                descendantIdentity <- identityForProcess descendantProcess
                let liveTerminalState =
                      (runningWorkerState spec.workerId 999999 Nothing)
                        { workerStateStatus = WorkerTerminal SolveCompleted,
                          workerStateKnownProcesses = [descendantIdentity]
                        }
                LazyByteString.writeFile statePath (encode liveTerminalState)
                earlier <- getCurrentTime
                LazyByteString.writeFile descriptor.workerDescriptorEventPath (encode (WorkerEnvelope earlier (WorkerDiagnostic "before-kill")) <> "\n")
                managedProcessFor descendantProcess >>= killManagedProcess
                void (timeout 3000000 (waitForProcess descendantProcess))
                collected <- newIORef []
                let collect _ _ event = modifyIORef collected (event :)
                setFileMode descriptor.workerDescriptorEventPath 0o000
                recoveredDuringOutage <- recoverIfWorkerStoppedWith readProcessSnapshot descriptor collect 0
                recoveredDuringOutage `shouldBe` False
                eventsDuringOutage <- readIORef collected
                eventsDuringOutage `shouldBe` []
                leaseHeldDuringOutage <- doesDirectoryExist descriptor.workerDescriptorLeasePath
                leaseHeldDuringOutage `shouldBe` True
                setFileMode descriptor.workerDescriptorEventPath 0o600
                recoveredAfterOutage <- recoverIfWorkerStoppedWith readProcessSnapshot descriptor collect 0
                recoveredAfterOutage `shouldBe` True
                leaseReleased <- doesDirectoryExist descriptor.workerDescriptorLeasePath
                leaseReleased `shouldBe` False
                finalEvents <- reverse <$> readIORef collected
                finalEvents `shouldBe` [WorkerDiagnostic "before-kill", WorkerFinished SolveCompleted]

    it "keeps a stalled launch's lease held until its timed-out supervisor is confirmed dead, then allows a fresh launch" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \process -> do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              firstSpec = workerFixtureSpec repository (WorkerId "solve-796-stalled") 796
              secondSpec = workerFixtureSpec repository (WorkerId "solve-796-fresh") 796
              workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
          createDirectory repository.repositoryRoot
          createDirectoryIfMissing True workerRoot
          LazyByteString.writeFile (workerRoot </> "solve-796-stalled.spec.json") (encode firstSpec)
          LazyByteString.writeFile (workerRoot </> "solve-796-fresh.spec.json") (encode secondSpec)
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            descriptors <- discoverWorkerHistory repository
            case (find ((== firstSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors, find ((== secondSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors) of
              (Just first, Just second) -> do
                -- Mirrors launchWorker's own order: the lease is acquired
                -- before the supervisor is spawned.
                acquireWorkerLease first `shouldReturn` Right ()
                -- Mirrors launchWorker recording the freshly spawned
                -- supervisor's identity onto the lease immediately after
                -- spawn, before it has any chance to write a state file.
                recordLaunchedSupervisorIdentity first process
                -- Backdate the lease directory well past its recency grace
                -- window: only the durably recorded supervisor identity —
                -- not elapsed time — should still be blocking a same-issue
                -- relaunch here.
                past <- addUTCTime (-30) <$> getCurrentTime
                setModificationTime first.workerDescriptorLeasePath past
                acquireWorkerLease second `shouldReturn` Left "issue #796 already has a live solve worker; open it from Processes or kill it before starting another"
                -- No state file is ever written for `first`, simulating a
                -- supervisor that stalls past the startup deadline; a
                -- handful of attempts keeps the test fast.
                result <- waitForWorkerStart first process 3
                result `shouldBe` Left "persistent worker did not initialize within three seconds"
                -- waitForWorkerStart must not return until the stalled
                -- supervisor is actually confirmed dead, not merely
                -- signalled: a single TERM only stops work the supervisor
                -- has already recorded as its own (see 'runWorkerWith'), not
                -- a task already in flight.
                getProcessExitCode process `shouldReturn` Just (ExitFailure (-9))
                -- Mirrors launchWorker's own release gate, which only
                -- releases once the exit code confirms the supervisor gone.
                releaseWorkerLease first
                acquireWorkerLease second `shouldReturn` Right ()
                releaseWorkerLease second
              _ -> expectationFailure "worker fixtures were not discoverable"

    it "refuses to retire a running-status lease while a recorded descendant survives its dead supervisor" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \descendantProcess -> do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              firstSpec = workerFixtureSpec repository (WorkerId "solve-797-running-descendant") 797
              secondSpec = workerFixtureSpec repository (WorkerId "solve-797-fresh") 797
              workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
              statePath = workerRoot </> "solve-797-running-descendant.state.json"
          createDirectory repository.repositoryRoot
          createDirectoryIfMissing True workerRoot
          LazyByteString.writeFile (workerRoot </> "solve-797-running-descendant.spec.json") (encode firstSpec)
          LazyByteString.writeFile (workerRoot </> "solve-797-fresh.spec.json") (encode secondSpec)
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            descriptors <- discoverWorkerHistory repository
            case (find ((== firstSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors, find ((== secondSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors) of
              (Just first, Just second) -> do
                acquireWorkerLease first `shouldReturn` Right ()
                ownPid <- fromIntegral <$> getProcessID
                snapshot <- readProcessSnapshot
                case snapshot of
                  Left message -> expectationFailure (Data.Text.unpack message)
                  Right identities -> case identityForPid ownPid identities of
                    Nothing -> expectationFailure "could not find this test process in a process snapshot"
                    Just realIdentity -> do
                      descendantIdentity <- identityForProcess descendantProcess
                      -- Status stays WorkerRunning (never WorkerOrphaned) to
                      -- exercise the generalized non-orphan branch: only the
                      -- supervisor's own identity used to be checked there,
                      -- so a dead supervisor with a still-live recorded
                      -- descendant was previously (incorrectly) treated as
                      -- retireable.
                      let deadSupervisor = realIdentity {processIdentityStartedAt = "Wed Jan 01 00:00:00 2020"}
                          state =
                            (runningWorkerState firstSpec.workerId ownPid (Just deadSupervisor))
                              {workerStateKnownProcesses = [descendantIdentity]}
                      LazyByteString.writeFile statePath (encode state)
                      acquireWorkerLease second `shouldReturn` Left "issue #797 already has a live solve worker; open it from Processes or kill it before starting another"
                      managedProcessFor descendantProcess >>= killManagedProcess
                      void (timeout 3000000 (waitForProcess descendantProcess))
                      acquireWorkerLease second `shouldReturn` Right ()
                      releaseWorkerLease second
              _ -> expectationFailure "worker fixtures were not discoverable"

    it "retires a stale orphaned lease once every recorded identity is confirmed gone" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            firstSpec = workerFixtureSpec repository (WorkerId "solve-798-orphan-stale") 798
            secondSpec = workerFixtureSpec repository (WorkerId "solve-798-fresh") 798
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            statePath = workerRoot </> "solve-798-orphan-stale.state.json"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile (workerRoot </> "solve-798-orphan-stale.spec.json") (encode firstSpec)
        LazyByteString.writeFile (workerRoot </> "solve-798-fresh.spec.json") (encode secondSpec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case (find ((== firstSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors, find ((== secondSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors) of
            (Just first, Just second) -> do
              acquireWorkerLease first `shouldReturn` Right ()
              ownPid <- fromIntegral <$> getProcessID
              snapshot <- readProcessSnapshot
              case snapshot of
                Left message -> expectationFailure (Data.Text.unpack message)
                Right identities -> case identityForPid ownPid identities of
                  Nothing -> expectationFailure "could not find this test process in a process snapshot"
                  Just realIdentity -> do
                    let deadSupervisor = realIdentity {processIdentityStartedAt = "Wed Jan 01 00:00:00 2020"}
                        state =
                          (runningWorkerState firstSpec.workerId ownPid (Just deadSupervisor))
                            { workerStateStatus = WorkerOrphaned SolveCompleted,
                              workerStateKnownProcesses = []
                            }
                    LazyByteString.writeFile statePath (encode state)
                    -- Previously WorkerOrphaned unconditionally kept the
                    -- lease active regardless of whether its recorded
                    -- survivors were actually still alive, permanently
                    -- blocking a same-issue relaunch even once everything
                    -- was confirmed gone (e.g. the supervisor itself died
                    -- without ever writing a terminal state).
                    acquireWorkerLease second `shouldReturn` Right ()
                    releaseWorkerLease second
            _ -> expectationFailure "worker fixtures were not discoverable"

    it "abandoning orphan-wait on TERM never releases the lease while a live recorded survivor remains, and permits relaunch once it exits" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
            spec = (workerFixtureSpec repository (WorkerId "solve-799-term-orphan-fixture") 799) {workerCreatedAt = now}
            freshSpec = workerFixtureSpec repository (WorkerId "solve-799-fresh") 799
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-799-term-orphan-fixture.spec.json"
            statePath = workerRoot </> "solve-799-term-orphan-fixture.state.json"
            eventPath = workerRoot </> "solve-799-term-orphan-fixture.events.jsonl"
            leasePath = workerRoot </> "issue-799.lease"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        createDirectoryIfMissing True workerRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "sh -c 'trap \"\" TERM; while :; do sleep 1; done' </dev/null >/dev/null 2>&1 &",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"term-orphan-session\"}'",
                "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Created PR #999\"}}'",
                "sleep 1"
              ]
          )
        setFileMode fakeCodex 0o700
        LazyByteString.writeFile specPath (encode spec)
        LazyByteString.writeFile (workerRoot </> "solve-799-fresh.spec.json") (encode freshSpec)
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            descriptors <- discoverWorkerHistory repository
            case (find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors, find ((== freshSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors) of
              (Just descriptor, Just freshDescriptor) -> do
                acquireWorkerLease descriptor `shouldReturn` Right ()
                finished <- newEmptyMVar
                let cleanup = do
                      stateBytes <- LazyByteString.readFile statePath
                      case (eitherDecode stateBytes :: Either String WorkerState) of
                        Right state -> do
                          let groups = Set.toList (Set.fromList (map processIdentityGroupPid state.workerStateKnownProcesses))
                          mapM_ (killManagedProcess . managedProcessGroup . fromIntegral) groups
                        Left _ -> pure ()
                      timeout 10000000 (takeMVar finished) `shouldReturn` Just (Right ())
                void . forkIO $ runWorker specPath >>= putMVar finished
                ( do
                    orphanState <- waitForWorkerState statePath isOrphaned 80
                    orphanState.workerStateStatus `shouldBe` WorkerOrphaned SolveCompleted
                    -- A genuinely live survivor (not an inconclusive
                    -- snapshot, already covered elsewhere) is present before
                    -- signalling.
                    survivingResult <- liveProcesses orphanState.workerStateKnownProcesses
                    surviving <- case survivingResult of
                      Left message -> fail ("expected a successful snapshot, not a query failure: " <> Data.Text.unpack message)
                      Right identities -> pure identities
                    surviving `shouldNotBe` []
                    raiseSignal sigTERM
                    threadDelay 300000
                    stillOrphaned <- waitForWorkerState statePath isOrphaned 30
                    stillOrphaned.workerStateStatus `shouldBe` WorkerOrphaned SolveCompleted
                    leaseHeldDuringSignal <- doesDirectoryExist leasePath
                    leaseHeldDuringSignal `shouldBe` True
                    eventBytesWhileOrphaned <- ByteString.readFile eventPath
                    eventBytesWhileOrphaned `shouldNotSatisfy` ByteString.isInfixOf "WorkerFinished"
                  )
                  `finally` cleanup
                terminalState <- waitForWorkerState statePath isTerminal 30
                terminalState.workerStateStatus `shouldBe` WorkerTerminal SolveCompleted
                eventBytes <- ByteString.readFile eventPath
                eventBytes `shouldSatisfy` ByteString.isInfixOf "WorkerFinished"
                leaseReleased <- doesDirectoryExist leasePath
                leaseReleased `shouldBe` False
                -- The one-live-worker invariant is what this whole sequence
                -- protects: a fresh worker for the same issue must now be
                -- able to launch.
                acquireWorkerLease freshDescriptor `shouldReturn` Right ()
                releaseWorkerLease freshDescriptor
              _ -> expectationFailure "worker fixtures were not discoverable"

    it "re-verifies every recorded identity of a terminal lease rather than trusting the status label or supervisor alone" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \descendantProcess -> do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              firstSpec = workerFixtureSpec repository (WorkerId "solve-800-terminal-live") 800
              secondSpec = workerFixtureSpec repository (WorkerId "solve-800-fresh") 800
              -- Each stale-retirement in this test renames the shared lease
              -- directory to a target keyed only by the acquiring workerId
              -- ('retireStaleLease' never cleans up that trail), so reusing
              -- one acquirer across more than one retirement in the same
              -- test collides with its own earlier rename target; a third,
              -- distinct fixture keeps the final scenario's retirement
              -- independent of the second's.
              thirdSpec = workerFixtureSpec repository (WorkerId "solve-800-fresh-2") 800
              workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
              statePath = workerRoot </> "solve-800-terminal-live.state.json"
          createDirectory repository.repositoryRoot
          createDirectoryIfMissing True workerRoot
          LazyByteString.writeFile (workerRoot </> "solve-800-terminal-live.spec.json") (encode firstSpec)
          LazyByteString.writeFile (workerRoot </> "solve-800-fresh.spec.json") (encode secondSpec)
          LazyByteString.writeFile (workerRoot </> "solve-800-fresh-2.spec.json") (encode thirdSpec)
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            descriptors <- discoverWorkerHistory repository
            case ( find ((== firstSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors,
                   find ((== secondSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors,
                   find ((== thirdSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors
                 ) of
              (Just first, Just second, Just third) -> do
                ownPid <- fromIntegral <$> getProcessID
                snapshot <- readProcessSnapshot
                realIdentity <- case snapshot of
                  Left message -> fail ("could not find this test process in a process snapshot: " <> Data.Text.unpack message)
                  Right identities -> case identityForPid ownPid identities of
                    Nothing -> fail "could not find this test process in a process snapshot"
                    Just identity -> pure identity
                descendantIdentity <- identityForProcess descendantProcess
                -- A Terminal write is only ever reached after every recorded
                -- identity has been verified absent; this constructs the
                -- anomalous case directly to prove the re-check — not the
                -- WorkerTerminal label alone — is what decides.
                acquireWorkerLease first `shouldReturn` Right ()
                let liveTerminalState = (runningWorkerState firstSpec.workerId ownPid (Just realIdentity)) {workerStateStatus = WorkerTerminal SolveCompleted}
                LazyByteString.writeFile statePath (encode liveTerminalState)
                acquireWorkerLease second `shouldReturn` Left "issue #800 already has a live solve worker; open it from Processes or kill it before starting another"
                releaseWorkerLease first
                -- The supervisor identity is absent, but a recorded
                -- descendant is still alive: the check must consult
                -- workerStateKnownProcesses too, not stop at the missing
                -- supervisor and assume retireable.
                acquireWorkerLease first `shouldReturn` Right ()
                let descendantOnlyTerminalState =
                      (runningWorkerState firstSpec.workerId 999999 Nothing)
                        { workerStateStatus = WorkerTerminal SolveCompleted,
                          workerStateKnownProcesses = [descendantIdentity]
                        }
                LazyByteString.writeFile statePath (encode descendantOnlyTerminalState)
                acquireWorkerLease second `shouldReturn` Left "issue #800 already has a live solve worker; open it from Processes or kill it before starting another"
                managedProcessFor descendantProcess >>= killManagedProcess
                void (timeout 3000000 (waitForProcess descendantProcess))
                acquireWorkerLease second `shouldReturn` Right ()
                releaseWorkerLease second
                -- A terminal state with no recorded identity anywhere keeps
                -- the prior unconditional release: nothing to re-verify, and
                -- Terminal already means done.
                acquireWorkerLease first `shouldReturn` Right ()
                let noIdentityTerminalState = (runningWorkerState firstSpec.workerId 999999 Nothing) {workerStateStatus = WorkerTerminal SolveCompleted}
                LazyByteString.writeFile statePath (encode noIdentityTerminalState)
                acquireWorkerLease third `shouldReturn` Right ()
                releaseWorkerLease third
              _ -> expectationFailure "worker fixtures were not discoverable"

    it "keeps a lease active indefinitely, with no time-based escape hatch, when capturing the launched supervisor's identity never once succeeds" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withManagedShell "true" $ \reapedProcess -> do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              firstSpec = workerFixtureSpec repository (WorkerId "solve-802-capture-fails") 802
              secondSpec = workerFixtureSpec repository (WorkerId "solve-802-fresh") 802
              workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
          createDirectory repository.repositoryRoot
          createDirectoryIfMissing True workerRoot
          LazyByteString.writeFile (workerRoot </> "solve-802-capture-fails.spec.json") (encode firstSpec)
          LazyByteString.writeFile (workerRoot </> "solve-802-fresh.spec.json") (encode secondSpec)
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            descriptors <- discoverWorkerHistory repository
            case (find ((== firstSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors, find ((== secondSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors) of
              (Just first, Just second) -> do
                acquireWorkerLease first `shouldReturn` Right ()
                -- A reaped process handle makes getPid return Nothing on
                -- every call: a deterministic stand-in for a launch whose
                -- best-effort identity capture never once succeeds, tried
                -- repeatedly as 'waitForWorkerStart' would across its poll.
                void (waitForProcess reapedProcess)
                recordLaunchedSupervisorIdentity first reapedProcess
                recordLaunchedSupervisorIdentity first reapedProcess
                recordLaunchedSupervisorIdentity first reapedProcess
                -- Unlike a merely-slow lease, this must stay blocked no
                -- matter how far past any recency window it is backdated:
                -- elapsed time can never distinguish a still-alive
                -- supervisor whose identity we simply never captured from a
                -- dead one.
                past <- addUTCTime (-3600) <$> getCurrentTime
                setModificationTime first.workerDescriptorLeasePath past
                acquireWorkerLease second `shouldReturn` Left "issue #802 already has a live solve worker; open it from Processes or kill it before starting another"
                -- The independent missing-state recovery path must likewise
                -- never finalize this launch on elapsed time alone.
                collected <- newIORef []
                let collect _ _ event = modifyIORef collected (event :)
                resolved <- recoverIfWorkerStoppedWith readProcessSnapshot first collect 0
                resolved `shouldBe` False
                events <- readIORef collected
                events `shouldBe` []
                releaseWorkerLease first
              _ -> expectationFailure "worker fixtures were not discoverable"

    it "never lets a later identity-recording attempt overwrite a lease's already-recorded supervisor" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \firstProcess ->
          withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \secondProcess -> do
            let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
                firstSpec = workerFixtureSpec repository (WorkerId "solve-801-identity-idempotent") 801
                secondSpec = workerFixtureSpec repository (WorkerId "solve-801-fresh") 801
                workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            createDirectory repository.repositoryRoot
            createDirectoryIfMissing True workerRoot
            LazyByteString.writeFile (workerRoot </> "solve-801-identity-idempotent.spec.json") (encode firstSpec)
            LazyByteString.writeFile (workerRoot </> "solve-801-fresh.spec.json") (encode secondSpec)
            withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
              descriptors <- discoverWorkerHistory repository
              case (find ((== firstSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors, find ((== secondSpec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors) of
                (Just first, Just second) -> do
                  acquireWorkerLease first `shouldReturn` Right ()
                  recordLaunchedSupervisorIdentity first firstProcess
                  -- A retried recording attempt (as happens when
                  -- 'waitForWorkerStart' retries on every poll after the
                  -- first attempt already succeeded) must not clobber the
                  -- identity already recorded, even though `secondProcess`
                  -- is itself a live, matchable identity.
                  recordLaunchedSupervisorIdentity first secondProcess
                  managedProcessFor firstProcess >>= killManagedProcess
                  void (timeout 3000000 (waitForProcess firstProcess))
                  -- If the second call had overwritten the recorded
                  -- identity, `secondProcess` (still alive) would keep the
                  -- lease blocked here even though `firstProcess` — the
                  -- identity that should still be recorded — is dead.
                  past <- addUTCTime (-30) <$> getCurrentTime
                  setModificationTime first.workerDescriptorLeasePath past
                  acquireWorkerLease second `shouldReturn` Right ()
                  releaseWorkerLease second
                _ -> expectationFailure "worker fixtures were not discoverable"

    it "does not release a terminal lease's recovery pass while a recorded identity is still live" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \descendantProcess -> do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              spec = workerFixtureSpec repository (WorkerId "solve-803-terminal-recovery") 803
              workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
              statePath = workerRoot </> "solve-803-terminal-recovery.state.json"
          createDirectory repository.repositoryRoot
          createDirectoryIfMissing True workerRoot
          LazyByteString.writeFile (workerRoot </> "solve-803-terminal-recovery.spec.json") (encode spec)
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            descriptors <- discoverWorkerHistory repository
            case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
              Nothing -> expectationFailure "worker fixture was not discoverable"
              Just descriptor -> do
                acquireWorkerLease descriptor `shouldReturn` Right ()
                descendantIdentity <- identityForProcess descendantProcess
                -- Mirrors leaseIsActive's own WorkerTerminal re-check: a
                -- recovery pass over an already-terminal state must not
                -- trust the label alone while a recorded descendant is
                -- still live.
                let liveTerminalState =
                      (runningWorkerState spec.workerId 999999 Nothing)
                        { workerStateStatus = WorkerTerminal SolveCompleted,
                          workerStateKnownProcesses = [descendantIdentity]
                        }
                LazyByteString.writeFile statePath (encode liveTerminalState)
                collected <- newIORef []
                let collect _ _ event = modifyIORef collected (event :)
                recovered1 <- recoverIfWorkerStoppedWith readProcessSnapshot descriptor collect 0
                recovered1 `shouldBe` False
                leaseHeld <- doesDirectoryExist descriptor.workerDescriptorLeasePath
                leaseHeld `shouldBe` True
                pendingEvents <- readIORef collected
                pendingEvents `shouldBe` []
                managedProcessFor descendantProcess >>= killManagedProcess
                void (timeout 3000000 (waitForProcess descendantProcess))
                recovered2 <- recoverIfWorkerStoppedWith readProcessSnapshot descriptor collect 0
                recovered2 `shouldBe` True
                leaseReleased <- doesDirectoryExist descriptor.workerDescriptorLeasePath
                leaseReleased `shouldBe` False
                finalEvents <- readIORef collected
                finalEvents `shouldBe` [WorkerFinished SolveCompleted]

    -- §16 requires 0600 on every file Kanban creates, and a worker journal
    -- carries issue bodies and whole agent transcripts for repositories that
    -- may well be private. The mask here is fully permissive on purpose: an
    -- append that merely inherited the umask would land at 0666, so only the
    -- code forcing the mode can produce this result.
    it "creates a worker journal as 0600 under a permissive umask" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec = (workerFixtureSpec repository (WorkerId "solve-900-journal") 900) {workerCreatedAt = now}
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-900-journal.spec.json"
            eventPath = workerRoot </> "solve-900-journal.events.jsonl"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile specPath (encode spec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withFakeOnPath temporaryRoot ("codex", completingProviderLines) $
            withFileCreationMask 0o000 $ do
              runWorker specPath `shouldReturn` Right ()
              permissionsOf eventPath `shouldReturn` 0o600

    -- A journal an earlier release created before the mode was enforced has
    -- to be tightened before this call appends more private bytes to it,
    -- rather than left for a rewrite that never comes: nothing else in the
    -- worker directory ever rewrites a journal in place.
    it "tightens a permissive journal an earlier release left behind, without losing it" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec = (workerFixtureSpec repository (WorkerId "solve-901-journal") 901) {workerCreatedAt = now}
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-901-journal.spec.json"
            eventPath = workerRoot </> "solve-901-journal.events.jsonl"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile specPath (encode spec)
        ByteString.writeFile eventPath "{\"legacy\":true}\n"
        setFileMode eventPath 0o644
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withFakeOnPath temporaryRoot ("codex", completingProviderLines) $
            withFileCreationMask 0o000 $ do
              runWorker specPath `shouldReturn` Right ()
              permissionsOf eventPath `shouldReturn` 0o600
              journal <- ByteString.readFile eventPath
              journal `shouldSatisfy` ByteString.isPrefixOf "{\"legacy\":true}"
              journal `shouldSatisfy` ByteString.isInfixOf "WorkerFinished"

    -- 'retireStaleLease' only ever renamed a lease it had proven dead, so one
    -- '.stale-*' directory accumulated for every recovered-from-crash launch
    -- and nothing removed any of them.
    it "collects a retired stale lease whose recorded processes are all gone" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            staleSpec = workerFixtureSpec repository (WorkerId "solve-910-stale") 910
            freshSpec = workerFixtureSpec repository (WorkerId "solve-910-fresh") 910
            heldSpec = workerFixtureSpec repository (WorkerId "solve-911-held") 911
            terminalSpec = workerFixtureSpec repository (WorkerId "solve-912-terminal") 912
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            retiredLease = workerRoot </> "issue-910.lease.stale-solve-910-fresh"
            heldLease = workerRoot </> "issue-911.lease"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        mapM_ (writeWorkerSpec workerRoot) [staleSpec, freshSpec, heldSpec]
        writeTerminalWorker workerRoot terminalSpec now
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          stale <- descriptorFor descriptors staleSpec
          fresh <- descriptorFor descriptors freshSpec
          held <- descriptorFor descriptors heldSpec
          acquireWorkerLease stale `shouldReturn` Right ()
          acquireWorkerLease held `shouldReturn` Right ()
          mismatched <- mismatchedIdentity
          LazyByteString.writeFile (workerRoot </> "solve-910-stale.state.json") (encode (runningWorkerState staleSpec.workerId mismatched.processIdentityPid (Just mismatched)))
          -- The real retirement path, rather than a hand-built directory:
          -- what the janitor has to collect is exactly what this produces.
          acquireWorkerLease fresh `shouldReturn` Right ()
          doesDirectoryExist retiredLease `shouldReturn` True
          collectWorkerCacheWith readProcessSnapshot repository
          doesDirectoryExist retiredLease `shouldReturn` False
          -- A live lease, the fresh worker's own lease, and an unacknowledged
          -- terminal worker inside the window are all left alone.
          doesDirectoryExist heldLease `shouldReturn` True
          doesDirectoryExist (workerRoot </> "issue-910.lease") `shouldReturn` True
          workerIsDiscoverable workerRoot terminalSpec.workerId `shouldReturn` True

    it "retains a retired stale lease it cannot prove dead" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            staleSpec = workerFixtureSpec repository (WorkerId "solve-913-stale") 913
            freshSpec = workerFixtureSpec repository (WorkerId "solve-913-fresh") 913
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            statePath = workerRoot </> "solve-913-stale.state.json"
            retiredLease = workerRoot </> "issue-913.lease.stale-solve-913-fresh"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        mapM_ (writeWorkerSpec workerRoot) [staleSpec, freshSpec]
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          stale <- descriptorFor descriptors staleSpec
          fresh <- descriptorFor descriptors freshSpec
          acquireWorkerLease stale `shouldReturn` Right ()
          mismatched <- mismatchedIdentity
          LazyByteString.writeFile statePath (encode (runningWorkerState staleSpec.workerId mismatched.processIdentityPid (Just mismatched)))
          acquireWorkerLease fresh `shouldReturn` Right ()
          -- A snapshot that cannot be taken says nothing about whether the
          -- recorded processes are gone, so the directory stays.
          collectWorkerCacheWith (pure (Left "ps unavailable")) repository
          doesDirectoryExist retiredLease `shouldReturn` True
          -- Neither does an identity that matches again — a reused PID with
          -- the same recorded start time is exactly what fail-closed is for.
          live <- liveIdentity
          LazyByteString.writeFile statePath (encode (runningWorkerState staleSpec.workerId live.processIdentityPid (Just live)))
          collectWorkerCacheWith readProcessSnapshot repository
          doesDirectoryExist retiredLease `shouldReturn` True

    -- A worker directory is keyed by 'safeKey' over @owner-name@, and that
    -- mapping collides: coghex-kan/ban and coghex/kan-ban both key to
    -- coghex-kan-ban and share one directory. Scanning it for '.stale-*'
    -- entries alone would let either repository's startup delete the other's
    -- retired lease, so the owner has to be one this repository's history
    -- actually contains.
    it "leaves a colliding repository's retired stale lease alone" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let neighbour = Repository (temporaryRoot </> "neighbour") "coghex-kan" "ban"
            ours = Repository (temporaryRoot </> "ours") "coghex" "kan-ban"
            staleSpec = workerFixtureSpec neighbour (WorkerId "solve-930-neighbour-stale") 930
            freshSpec = workerFixtureSpec neighbour (WorkerId "solve-930-neighbour-fresh") 930
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kan-ban"
            retiredLease = workerRoot </> "issue-930.lease.stale-solve-930-neighbour-fresh"
        createDirectory neighbour.repositoryRoot
        createDirectory ours.repositoryRoot
        createDirectoryIfMissing True workerRoot
        mapM_ (writeWorkerSpec workerRoot) [staleSpec, freshSpec]
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory neighbour
          stale <- descriptorFor descriptors staleSpec
          fresh <- descriptorFor descriptors freshSpec
          acquireWorkerLease stale `shouldReturn` Right ()
          mismatched <- mismatchedIdentity
          LazyByteString.writeFile (workerRoot </> "solve-930-neighbour-stale.state.json") (encode (runningWorkerState staleSpec.workerId mismatched.processIdentityPid (Just mismatched)))
          acquireWorkerLease fresh `shouldReturn` Right ()
          doesDirectoryExist retiredLease `shouldReturn` True
          -- Our repository shares the directory but owns nothing in it, so
          -- its pass must collect nothing even though the recorded processes
          -- are provably gone.
          collectWorkerCacheWith readProcessSnapshot ours
          doesDirectoryExist retiredLease `shouldReturn` True
          workerIsDiscoverable workerRoot staleSpec.workerId `shouldReturn` True
          -- The repository that does own it still collects it.
          collectWorkerCacheWith readProcessSnapshot neighbour
          doesDirectoryExist retiredLease `shouldReturn` False

    -- Milestone 8 keeps a terminal journal until a newer worker is durable
    -- proof its workflow step was superseded, so inside the window that proof
    -- plus acknowledgement is what makes one collectable — and the newest
    -- session for an item, the one the debugging contract promises, is not.
    it "collects an acknowledged terminal worker a newer durable worker superseded, keeping the newest" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            olderSpec = (workerFixtureSpec repository (WorkerId "solve-920-older") 920) {workerCreatedAt = addUTCTime (-3600) now}
            newerSpec = (workerFixtureSpec repository (WorkerId "solve-920-newer") 920) {workerCreatedAt = now}
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        writeTerminalWorker workerRoot olderSpec now
        writeTerminalWorker workerRoot newerSpec now
        ByteString.writeFile (workerRoot </> "solve-920-older.ack") "handled\n"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          collectWorkerCacheWith readProcessSnapshot repository
          workerIsDiscoverable workerRoot olderSpec.workerId `shouldReturn` False
          doesFileExist (workerRoot </> "solve-920-older.events.jsonl") `shouldReturn` False
          doesFileExist (workerRoot </> "solve-920-older.state.json") `shouldReturn` False
          doesFileExist (workerRoot </> "solve-920-older.ack") `shouldReturn` False
          workerIsDiscoverable workerRoot newerSpec.workerId `shouldReturn` True

    it "retains an unsuperseded terminal worker until its retention window expires" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            unacknowledgedSpec = workerFixtureSpec repository (WorkerId "solve-921-unacked") 921
            acknowledgedSpec = workerFixtureSpec repository (WorkerId "solve-922-acked") 922
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            expired = addUTCTime (-15 * 24 * 60 * 60) now
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        writeTerminalWorker workerRoot unacknowledgedSpec now
        writeTerminalWorker workerRoot acknowledgedSpec now
        ByteString.writeFile (workerRoot </> "solve-922-acked.ack") "handled\n"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          -- Inside the window neither is collectable: one is unacknowledged,
          -- and acknowledgement alone is not supersession.
          collectWorkerCacheWith readProcessSnapshot repository
          workerIsDiscoverable workerRoot unacknowledgedSpec.workerId `shouldReturn` True
          workerIsDiscoverable workerRoot acknowledgedSpec.workerId `shouldReturn` True
          -- Past it, the promise has expired and the rest is collected
          -- whatever its acknowledgement or supersession.
          writeTerminalState workerRoot unacknowledgedSpec.workerId expired
          writeTerminalState workerRoot acknowledgedSpec.workerId expired
          collectWorkerCacheWith readProcessSnapshot repository
          workerIsDiscoverable workerRoot unacknowledgedSpec.workerId `shouldReturn` False
          workerIsDiscoverable workerRoot acknowledgedSpec.workerId `shouldReturn` False

    -- Terminal status alone is never enough: lease recovery re-verifies
    -- recorded identities before releasing a terminal lease, and expiry must
    -- not become a way around that.
    it "keeps an expired terminal worker's artifacts while a recorded identity is still live" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \process -> do
          now <- getCurrentTime
          threadDelay 100000
          identity <- identityForProcess process
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              spec = workerFixtureSpec repository (WorkerId "solve-923-live") 923
              workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
              expired = addUTCTime (-15 * 24 * 60 * 60) now
              liveState = (terminalWorkerState spec.workerId expired) {workerStateKnownProcesses = [identity]}
          createDirectory repository.repositoryRoot
          createDirectoryIfMissing True workerRoot
          writeTerminalWorker workerRoot spec expired
          LazyByteString.writeFile (workerRoot </> "solve-923-live.state.json") (encode liveState)
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            collectWorkerCacheWith readProcessSnapshot repository
            workerIsDiscoverable workerRoot spec.workerId `shouldReturn` True
            managedProcessFor process >>= killManagedProcess
            void (timeout 3000000 (waitForProcess process))
            collectWorkerCacheWith readProcessSnapshot repository
            workerIsDiscoverable workerRoot spec.workerId `shouldReturn` False

    it "keeps an expired terminal worker's artifacts while it still owns its item's lease" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec = workerFixtureSpec repository (WorkerId "solve-924-leased") 924
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            expired = addUTCTime (-15 * 24 * 60 * 60) now
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        writeTerminalWorker workerRoot spec expired
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          descriptor <- descriptorFor descriptors spec
          acquireWorkerLease descriptor `shouldReturn` Right ()
          collectWorkerCacheWith readProcessSnapshot repository
          workerIsDiscoverable workerRoot spec.workerId `shouldReturn` True
          releaseWorkerLease descriptor
          collectWorkerCacheWith readProcessSnapshot repository
          workerIsDiscoverable workerRoot spec.workerId `shouldReturn` False

-- | A fake @codex@ that identifies a session and reports a completed solve,
-- so a real worker reaches its terminal envelope in a fraction of a second.
completingProviderLines :: [ByteString.ByteString]
completingProviderLines =
  [ "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"journal-fixture-session\"}'",
    "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Created PR #999\"}}'"
  ]

writeWorkerSpec :: FilePath -> WorkerSpec -> IO ()
writeWorkerSpec workerRoot spec =
  LazyByteString.writeFile (workerBase workerRoot spec.workerId <> ".spec.json") (encode spec)

-- | The durable file set a finished worker leaves behind: the @.spec.json@
-- discovery finds it through, the state recording its terminal status, and a
-- journal. Retention is measured from the state's heartbeat, so that is what
-- the caller chooses.
writeTerminalWorker :: FilePath -> WorkerSpec -> UTCTime -> IO ()
writeTerminalWorker workerRoot spec heartbeat = do
  writeWorkerSpec workerRoot spec
  writeTerminalState workerRoot spec.workerId heartbeat
  ByteString.writeFile (workerBase workerRoot spec.workerId <> ".events.jsonl") "{}\n"

writeTerminalState :: FilePath -> WorkerId -> UTCTime -> IO ()
writeTerminalState workerRoot identifier heartbeat =
  LazyByteString.writeFile (workerBase workerRoot identifier <> ".state.json") (encode (terminalWorkerState identifier heartbeat))

terminalWorkerState :: WorkerId -> UTCTime -> WorkerState
terminalWorkerState identifier heartbeat =
  (runningWorkerState identifier 999999 Nothing)
    { workerStateStatus = WorkerTerminal SolveCompleted,
      workerStateHeartbeatAt = heartbeat
    }

-- | Discovery reaches a worker only through its @.spec.json@, so that file's
-- presence is what "still in the cache" means.
workerIsDiscoverable :: FilePath -> WorkerId -> IO Bool
workerIsDiscoverable workerRoot identifier = doesFileExist (workerBase workerRoot identifier <> ".spec.json")

workerBase :: FilePath -> WorkerId -> FilePath
workerBase workerRoot identifier = workerRoot </> Data.Text.unpack identifier.unWorkerId

descriptorFor :: [WorkerDescriptor] -> WorkerSpec -> IO WorkerDescriptor
descriptorFor descriptors spec =
  requireJust
    ("worker fixture " <> Data.Text.unpack spec.workerId.unWorkerId <> " was not discoverable")
    (find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors)

-- | This process's real identity, so a recorded process provably matches a
-- live one.
liveIdentity :: IO ProcessIdentity
liveIdentity = do
  ownPid <- fromIntegral <$> getProcessID
  snapshot <- readProcessSnapshot
  case snapshot of
    Left message -> fail ("could not snapshot processes: " <> Data.Text.unpack message)
    Right identities -> requireJust "could not find this test process in a process snapshot" (identityForPid ownPid identities)

-- | The same identity with a start time no live process can have, which is
-- how the suite makes a recorded process provably gone without waiting for
-- one to exit.
mismatchedIdentity :: IO ProcessIdentity
mismatchedIdentity = do
  identity <- liveIdentity
  pure identity {processIdentityStartedAt = "Wed Jan 01 00:00:00 2020"}
