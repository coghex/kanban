module Main (main) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (IOException, SomeException, bracket, finally, try)
import Control.Monad (void)
import Data.Aeson (Value (..), eitherDecode, encode, object, (.=))
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.IORef (modifyIORef, newIORef, readIORef, writeIORef)
import Data.List (find, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text
import Data.Time (UTCTime (..), diffUTCTime, fromGregorian, getCurrentTime, minutesToTimeZone, secondsToDiffTime)
import Kanban.Cache
  ( CacheLoad (..),
    UsageCacheLoad (..),
    loadRepositoryCache,
    loadUsageCache,
    repositoryCachePath,
    writeRepositoryCache,
    writeUsageCache,
  )
import Kanban.Claude (decodeClaudeUsageText)
import Kanban.Codex (decodeCodexUsageResponse)
import Kanban.Domain
import Kanban.Drainer (DrainerController (..), DrainerState (..), DrainerStatus (..), controllerFromProgramArguments, decodeDrainerStatus, drainerIsRunning)
import Kanban.GitHub (decodeGitHubItems, paginationDecision, snapshotWarnings)
import Kanban.Layout (responsiveColumnWidths, responsiveOpenColumnWidths)
import Kanban.Process
  ( IdentityPresence (..),
    ManagedProcess,
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
    readProcessSnapshot,
  )
import Kanban.Repository (parseRepositoryName)
import Kanban.PullRequestFlow
  ( PullRequestAction (..),
    PullRequestOrigin (..),
    actionForLabels,
    agentForAction,
    originFromBody,
    pullRequestArguments,
  )
import Kanban.Review
  ( CanonicalIssueReviewResult (..),
    GitHubIssueOperation (..),
    GitHubIssueToolRequest (..),
    ReviewChoice (..),
    ReviewQuestion (..),
    ReviewQuestionKind (..),
    ReviewResult (..),
    ReviewStage (..),
    ReviewWireMessage (..),
    decodeCanonicalIssueReviewResult,
    decodeClaudeToolPrompt,
    decodeGitHubIssueToolRequest,
    decodeReviewQuestion,
    decodeReviewResult,
    decodeReviewWireMessage,
    reviewStageForLabels,
    renderCanonicalIssueReviewResult,
    renderReviewResult,
  )
import Kanban.Solve
  ( AgentEvent (..),
    SolveOutcome (..),
    SolveWorkflow (..),
    SolverBrand (..),
    claudeReviewerModel,
    claudeSolverModel,
    codexReviewerModel,
    codexSolverModel,
    parseSolveOutputLine,
    renderAgentEvent,
    solveArguments,
  )
import Kanban.Settings (ChatVerbosity (..), Settings (..), defaultSettings, loadSettings, saveSettings)
import Kanban.Text (excerpt, sanitizeText)
import Kanban.Transcript (closeSessionLog, logRawLine, openSessionLog, sessionLogPath)
import Kanban.Tracker (implementationSortKey, parseTrackerBody, parseTrackerChildren)
import Kanban.UI (failureActivity, orphanMessage)
import Kanban.Workflow (CardStatus (..), deriveBoard, entryItem, pullRequestStatus)
import Kanban.Worker
  ( PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerEvent (..),
    WorkerDescriptor (..),
    WorkerId (..),
    WorkerParent (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    WorkerTask (..),
    acquireWorkerLease,
    discoverWorkerHistory,
    monitorWorker,
    recoverIfWorkerStoppedWith,
    releaseWorkerLease,
    runWorker,
    runWorkerWith,
    runWorkerWithTask,
    terminateWorkerWith,
    workerDeadlineReason,
  )
import System.Directory (createDirectory, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getTemporaryDirectory, removeFile, removePathForcibly)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.Posix.Files (setFileMode)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (raiseSignal, sigKILL, sigTERM, signalProcess, signalProcessGroup)
import System.Process (CreateProcess (..), ProcessHandle, createProcess, getPid, getProcessExitCode, proc, waitForProcess)
import System.Timeout (timeout)
import Test.Hspec

main :: IO ()
main = hspec $ do
  describe "managed agent processes" $ do
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

    it "round-trips the durable worker protocol including autosolve parent identity" $ do
      let parent =
            WorkerParent
              { workerParentIssueNumber = 782,
                workerParentReviewRound = 2,
                workerParentSolverBrand = CodexSolver,
                workerParentSolverSession = Just "solver-session",
                workerParentSolverLogPath = Just "/tmp/solver.jsonl",
                workerParentStartedAt = epoch,
                workerParentKnownPullRequests = Set.fromList [857, 858]
              }
          spec =
            WorkerSpec
              { workerId = WorkerId "pr-858-test",
                workerRepository = Repository "/tmp/repo" "example" "project",
                workerTask = PullRequestWorkerTaskKind (PullRequestWorkerTask 858 PullRequestCodex PullRequestRereview),
                workerExistingSession = Just "review-session",
                workerExistingLogPath = Just "/tmp/review.jsonl",
                workerUserMessage = "continue",
                workerParent = Just parent,
                workerCreatedAt = epoch,
                workerMaxRuntimeSeconds = 14400
              }
      eitherDecode (encode spec) `shouldBe` Right spec
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
            firstSpec = workerFixtureSpec epoch 60 repository (WorkerId "solve-782-first") 782
            secondSpec = workerFixtureSpec epoch 60 repository (WorkerId "solve-782-second") 782
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
            firstSpec = workerFixtureSpec epoch 60 repository (WorkerId "solve-783-stale") 783
            secondSpec = workerFixtureSpec epoch 60 repository (WorkerId "solve-783-fresh") 783
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
            firstSpec = workerFixtureSpec epoch 60 repository (WorkerId "solve-791-pending") 791
            secondSpec = workerFixtureSpec epoch 60 repository (WorkerId "solve-791-fresh") 791
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
            firstSpec = workerFixtureSpec epoch 60 repository (WorkerId "solve-784-legacy") 784
            secondSpec = workerFixtureSpec epoch 60 repository (WorkerId "solve-784-fresh") 784
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
            spec = workerFixtureSpec epoch 60 repository (WorkerId "solve-785-mismatch") 785
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
                  workerUserMessage = "",
                  workerParent = Nothing,
                  workerCreatedAt = now,
                  workerMaxRuntimeSeconds = 60
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

    it "marks a completed provider orphaned until its surviving child exits" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
            spec = workerFixtureSpec now 60 repository (WorkerId "solve-783-orphan-fixture") 783
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
            spec = workerFixtureSpec now 60 repository (WorkerId "solve-787-verify-fixture") 787
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
            repository = Repository repositoryRoot "coghex" "kanban"
            spec = workerFixtureSpec now 60 repository (WorkerId "solve-788-signal-fixture") 788
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
            finished <- newEmptyMVar
            let flakySnapshot = do
                  stillFailing <- readIORef failing
                  if stillFailing then pure (Left "simulated ps outage") else readProcessSnapshot
                cleanup = do
                  stateBytes <- LazyByteString.readFile statePath
                  case (eitherDecode stateBytes :: Either String WorkerState) of
                    Right state -> do
                      let groups = Set.toList (Set.fromList (map processIdentityGroupPid state.workerStateKnownProcesses))
                      mapM_ (killManagedProcess . managedProcessGroup . fromIntegral) groups
                    Left _ -> pure ()
                  writeIORef failing False
                  timeout 10000000 (takeMVar finished) `shouldReturn` Just (Right ())
            void . forkIO $ runWorkerWith flakySnapshot specPath >>= putMVar finished
            ( do
                _ <- waitForWorkerState statePath (\state -> case state.workerStateStatus of WorkerRunning -> True; _ -> False) 80
                threadDelay 300000
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
            spec = workerFixtureSpec epoch 60 repository (WorkerId "solve-789-terminate-fixture") 789
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
                  completed <- recoverIfWorkerStoppedWith readProcessSnapshot descriptor collect
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
            spec = workerFixtureSpec epoch 60 repository (WorkerId "solve-790-stale-fixture") 790
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
                recovered1 <- recoverIfWorkerStoppedWith flaky descriptor collect
                recovered1 `shouldBe` False
                pendingState <- waitForWorkerState statePath isOrphaned 30
                case pendingState.workerStateStatus of
                  WorkerOrphaned (SolveFailed message) -> Data.Text.unpack message `shouldContain` "stale-supervisor recovery"
                  other -> expectationFailure ("expected a pending stale-recovery orphan status, got " <> show other)
                leaseHeld <- doesDirectoryExist descriptor.workerDescriptorLeasePath
                leaseHeld `shouldBe` True
                recovered2 <- recoverIfWorkerStoppedWith flaky descriptor collect
                recovered2 `shouldBe` False
                diagnosticsSoFar <- reverse <$> readIORef collected
                length (filter isDiagnosticEvent diagnosticsSoFar) `shouldBe` 1
                managedProcessFor descendantProcess >>= killManagedProcess
                void (timeout 3000000 (waitForProcess descendantProcess))
                recovered3 <- recoverIfWorkerStoppedWith readProcessSnapshot descriptor collect
                recovered3 `shouldBe` True
                finalState <- waitForWorkerState statePath isTerminal 30
                finalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed "persistent worker stopped unexpectedly; its provider process group was terminated")
                leaseReleased <- doesDirectoryExist descriptor.workerDescriptorLeasePath
                leaseReleased `shouldBe` False

    it "commits the distinct deadline outcome and kills the provider and its census group once the runtime bound fires" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
            spec = workerFixtureSpec now 2 repository (WorkerId "solve-793-deadline-fixture") 793
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-793-deadline-fixture.spec.json"
            statePath = workerRoot </> "solve-793-deadline-fixture.state.json"
            eventPath = workerRoot </> "solve-793-deadline-fixture.events.jsonl"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        createDirectoryIfMissing True workerRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "sh -c 'trap \"\" TERM; while :; do sleep 1; done' </dev/null >/dev/null 2>&1 &",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"deadline-session\"}'",
                "trap '' TERM",
                "while :; do sleep 1; done"
              ]
          )
        setFileMode fakeCodex 0o700
        LazyByteString.writeFile specPath (encode spec)
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            finished <- newEmptyMVar
            void . forkIO $ runWorker specPath >>= putMVar finished
            runningState <- waitForWorkerState statePath (\state -> case state.workerStateStatus of WorkerRunning -> not (null state.workerStateKnownProcesses); _ -> False) 80
            runningState.workerStateKnownProcesses `shouldNotBe` []
            let knownBeforeDeadline = runningState.workerStateKnownProcesses
            timeout 10000000 (takeMVar finished) `shouldReturn` Just (Right ())
            finalState <- waitForWorkerState statePath isTerminal 10
            finalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
            survivingResult <- liveProcesses knownBeforeDeadline
            survivingResult `shouldBe` Right []
            eventBytes <- ByteString.readFile eventPath
            eventBytes `shouldSatisfy` ByteString.isInfixOf "persistent worker deadline exceeded"

    it "cancels a pre-provider task hang at the deadline and releases the lease promptly" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec = workerFixtureSpec now 1 repository (WorkerId "solve-794-pre-provider-fixture") 794
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            leasePath = workerRoot </> "issue-794.lease"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile (workerRoot </> "solve-794-pre-provider-fixture.spec.json") (encode spec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
            Nothing -> expectationFailure "worker fixture was not discoverable"
            Just descriptor -> do
              acquireWorkerLease descriptor `shouldReturn` Right ()
              -- Never registers a provider: exercises the case where the
              -- deadline must cancel the task's own execution, not just a
              -- provider process, before it has one to kill.
              let hangBeforeProvider _spec _remember _emit = threadDelay 30000000
              finished <- newEmptyMVar
              void . forkIO $ runWorkerWithTask readProcessSnapshot hangBeforeProvider descriptor.workerDescriptorSpecPath >>= putMVar finished
              timeout 8000000 (takeMVar finished) `shouldReturn` Just (Right ())
              finalState <- waitForWorkerState descriptor.workerDescriptorStatePath isTerminal 5
              finalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
              finalState.workerStateProviderPid `shouldBe` Nothing
              leaseReleased <- doesDirectoryExist leasePath
              leaseReleased `shouldBe` False

    it "kills a provider that registers around an already-fired deadline and keeps the deadline outcome" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
            -- A zero-second runtime bound means the deadline is already
            -- "now" by the time the watchdog thread starts, so the fake
            -- provider's registration genuinely races the watchdog's
            -- already-committed stop guard rather than a fixed ordering:
            -- either the registration wins and the provider is then killed
            -- through the normal provider/census path, or the watchdog
            -- wins and 'rememberProvider' kills it immediately as it
            -- registers. Both outcomes converge on the same terminal state.
            spec = workerFixtureSpec now 0 repository (WorkerId "solve-798-race-fixture") 798
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-798-race-fixture.spec.json"
            statePath = workerRoot </> "solve-798-race-fixture.state.json"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        createDirectoryIfMissing True workerRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"race-session\"}'",
                "trap '' TERM",
                "while :; do sleep 1; done"
              ]
          )
        setFileMode fakeCodex 0o700
        LazyByteString.writeFile specPath (encode spec)
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            finished <- newEmptyMVar
            void . forkIO $ runWorker specPath >>= putMVar finished
            timeout 10000000 (takeMVar finished) `shouldReturn` Just (Right ())
            finalState <- waitForWorkerState statePath isTerminal 5
            finalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
            finalState.workerStateProviderPid `shouldBe` Nothing

    it "keeps the deadline outcome even when the cancelled task itself tries to report success afterward" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spec = workerFixtureSpec now 1 repository (WorkerId "solve-799-race-completion-fixture") 799
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
        createDirectory repository.repositoryRoot
        createDirectoryIfMissing True workerRoot
        LazyByteString.writeFile (workerRoot </> "solve-799-race-completion-fixture.spec.json") (encode spec)
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          descriptors <- discoverWorkerHistory repository
          case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
            Nothing -> expectationFailure "worker fixture was not discoverable"
            Just descriptor -> do
              acquireWorkerLease descriptor `shouldReturn` Right ()
              -- Simulates a task that, once cancelled by the deadline,
              -- still tries to report its own successful outcome from
              -- inside its cancellation handler. The watchdog claims the
              -- completion slot before it ever cancels the task (see
              -- 'watchdogLoop'), so this later report — which necessarily
              -- runs only after that cancellation is delivered — is
              -- deterministically too late to replace it.
              let raceCompletion _spec _remember emit = do
                    outcome <- try @SomeException (threadDelay 30000000)
                    case outcome of
                      Left _ -> emit (WorkerFinished SolveCompleted)
                      Right () -> pure ()
              finished <- newEmptyMVar
              void . forkIO $ runWorkerWithTask readProcessSnapshot raceCompletion descriptor.workerDescriptorSpecPath >>= putMVar finished
              timeout 8000000 (takeMVar finished) `shouldReturn` Just (Right ())
              finalState <- waitForWorkerState descriptor.workerDescriptorStatePath isTerminal 5
              finalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)

    it "retains the lease and pending deadline outcome while verification fails, then completes exactly once a snapshot succeeds" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
            spec = workerFixtureSpec now 1 repository (WorkerId "solve-796-deadline-verify-fixture") 796
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-796-deadline-verify-fixture.spec.json"
            statePath = workerRoot </> "solve-796-deadline-verify-fixture.state.json"
            eventPath = workerRoot </> "solve-796-deadline-verify-fixture.events.jsonl"
            leasePath = workerRoot </> "issue-796.lease"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        createDirectoryIfMissing True workerRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "sh -c 'trap \"\" TERM; while :; do sleep 1; done' </dev/null >/dev/null 2>&1 &",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"deadline-verify-session\"}'",
                "trap '' TERM",
                "while :; do sleep 1; done"
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
              Just descriptor -> do
                acquireWorkerLease descriptor `shouldReturn` Right ()
                failing <- newIORef True
                let flakySnapshot = do
                      stillFailing <- readIORef failing
                      if stillFailing then pure (Left "simulated ps outage") else readProcessSnapshot
                finished <- newEmptyMVar
                void . forkIO $ runWorkerWith flakySnapshot specPath >>= putMVar finished
                pendingState <- waitForWorkerState statePath isOrphaned 80
                pendingState.workerStateStatus `shouldBe` WorkerOrphaned (SolveFailed workerDeadlineReason)
                leaseHeldWhileUnverified <- doesDirectoryExist leasePath
                leaseHeldWhileUnverified `shouldBe` True
                eventBytesWhileFailing <- ByteString.readFile eventPath
                eventBytesWhileFailing `shouldNotSatisfy` ByteString.isInfixOf "WorkerFinished"
                survivingResult <- liveProcesses pendingState.workerStateKnownProcesses
                case survivingResult of
                  Left message -> fail ("expected a successful snapshot to identify the survivor to clean up: " <> Data.Text.unpack message)
                  Right identities -> do
                    let groups = Set.toList (Set.fromList (map processIdentityGroupPid identities))
                    mapM_ (killManagedProcess . managedProcessGroup . fromIntegral) groups
                writeIORef failing False
                timeout 10000000 (takeMVar finished) `shouldReturn` Just (Right ())
                terminalState <- waitForWorkerState statePath isTerminal 30
                terminalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
                eventBytesFinal <- ByteString.readFile eventPath
                let finishedLines = filter (ByteString.isInfixOf "WorkerFinished") (ByteString.lines eventBytesFinal)
                length finishedLines `shouldBe` 1
                leaseReleased <- doesDirectoryExist leasePath
                leaseReleased `shouldBe` False

    it "fires immediately for an already-overdue workerCreatedAt instead of waiting a fresh full runtime window" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
            -- Deadline (epoch + 60s) is deep in the past relative to "now";
            -- the fake provider hangs forever, so only a delay computed
            -- from workerCreatedAt (clamped to zero) reaches terminal state
            -- quickly rather than actually waiting out 60 fresh seconds.
            spec = workerFixtureSpec epoch 60 repository (WorkerId "solve-797-overdue-fixture") 797
            workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
            specPath = workerRoot </> "solve-797-overdue-fixture.spec.json"
            statePath = workerRoot </> "solve-797-overdue-fixture.state.json"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        createDirectoryIfMissing True workerRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"overdue-session\"}'",
                "trap '' TERM",
                "while :; do sleep 1; done"
              ]
          )
        setFileMode fakeCodex 0o700
        LazyByteString.writeFile specPath (encode spec)
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            finished <- newEmptyMVar
            startedAt <- getCurrentTime
            void . forkIO $ runWorker specPath >>= putMVar finished
            timeout 10000000 (takeMVar finished) `shouldReturn` Just (Right ())
            finishedAt <- getCurrentTime
            diffUTCTime finishedAt startedAt `shouldSatisfy` (< 10)
            finalState <- waitForWorkerState statePath isTerminal 5
            finalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)

  describe "Codex app-server protocol" $ do
    it "decodes streamed notifications without scraping their payload" $ do
      let payload = "{\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"thread-1\",\"delta\":\"hello\"}}"
      decodeReviewWireMessage payload
        `shouldBe` Right
          ( WireNotification
              "item/agentMessage/delta"
              (object ["threadId" .= ("thread-1" :: Text), "delta" .= ("hello" :: Text)])
          )

    it "distinguishes server requests that require a client response" $ do
      let payload = "{\"id\":41,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"kanban_prompt_user\"}}"
      decodeReviewWireMessage payload
        `shouldBe` Right
          ( WireRequest
              (Number 41)
              "item/tool/call"
              (object ["tool" .= ("kanban_prompt_user" :: Text)])
          )

    it "validates structured multiple-choice questions" $ do
      let payload =
            "{\"id\":\"scope\",\"header\":\"SCOPE\",\"question\":\"Which contract?\",\"kind\":\"choice\",\"options\":[{\"id\":\"keep\",\"label\":\"Keep compatibility\",\"description\":\"Preserve callers\"},{\"id\":\"break\",\"label\":\"Break compatibility\"}]}"
      decodeReviewQuestion payload
        `shouldBe` Right
          ReviewQuestion
            { reviewQuestionId = "scope",
              reviewQuestionHeader = "SCOPE",
              reviewQuestionText = "Which contract?",
              reviewQuestionKind = QuestionChoice,
              reviewQuestionChoices =
                [ ReviewChoice "keep" "Keep compatibility" "Preserve callers",
                  ReviewChoice "break" "Break compatibility" ""
                ],
              reviewQuestionAllowOther = False,
              reviewQuestionMultiple = False
            }

    it "rejects a choice question with fewer than two options" $ do
      let payload = "{\"id\":\"scope\",\"question\":\"Which contract?\",\"kind\":\"choice\",\"options\":[{\"id\":\"keep\",\"label\":\"Keep\"}]}"
      decodeReviewQuestion payload `shouldBe` Left "Choice questions must provide at least two options"

    it "decodes and presents the final structured result as readable review metadata" $ do
      let payload =
            "{\"issue\":844,\"stage\":\"review\",\"approved\":false,\"reviewerRoute\":\"codex-origin → Opus 4.8\",\"models\":[\"Opus 4.8 xhigh\"],\"commentUrl\":\"https://example.test/issues/844#issuecomment-1\",\"blockingReasons\":[\"Clarify the save-version migration.\",\"Name the regression probe.\"]}"
          expected =
            ReviewResult
              { reviewResultIssue = 844,
                reviewResultStage = InitialReview,
                reviewResultApproved = False,
                reviewResultReviewerRoute = "codex-origin → Opus 4.8",
                reviewResultModels = ["Opus 4.8 xhigh"],
                reviewResultCommentUrl = Just "https://example.test/issues/844#issuecomment-1",
                reviewResultBlockingReasons = ["Clarify the save-version migration.", "Name the regression probe."]
              }
      decodeReviewResult payload `shouldBe` Right expected
      renderReviewResult expected
        `shouldBe` Data.Text.unlines
          [ "Review result",
            "  Outcome: CHANGES REQUESTED",
            "  Reviewer route: codex-origin → Opus 4.8",
            "  Models: Opus 4.8 xhigh",
            "  Comment: https://example.test/issues/844#issuecomment-1",
            "  Blocking reasons:",
            "    • Clarify the save-version migration.",
            "    • Name the regression probe."
          ]

    it "selects revision and rereview stages from durable workflow labels" $ do
      reviewStageForLabels [] `shouldBe` InitialReview
      reviewStageForLabels ["reviewed:changes"] `shouldBe` IssueRevision
      reviewStageForLabels ["REVIEWED:REVISED", "reviewed:changes"] `shouldBe` IssueRereview

    it "formats the canonical v2 gate without exposing raw JSON" $ do
      let payload =
            "{\"approved\":false,\"issue\":844,\"origin\":\"codex\",\"required_reviewers\":\"claude\",\"required_models\":\"claude-opus-4-8@xhigh\",\"reasons\":[\"latest current review verdict is CHANGES_REQUESTED\"]}"
          expected =
            CanonicalIssueReviewResult
              { canonicalReviewApproved = False,
                canonicalReviewIssue = 844,
                canonicalReviewOrigin = "codex",
                canonicalReviewRequiredReviewers = Just "claude",
                canonicalReviewRequiredModels = Just "claude-opus-4-8@xhigh",
                canonicalReviewReasons = ["latest current review verdict is CHANGES_REQUESTED"]
              }
      decodeCanonicalIssueReviewResult payload `shouldBe` Right expected
      renderCanonicalIssueReviewResult InitialReview expected
        `shouldBe` Data.Text.unlines
          [ "Review result",
            "  Outcome: CHANGES REQUESTED",
            "  Origin: codex",
            "  Reviewer route: claude",
            "  Models: claude-opus-4-8@xhigh",
            "  Blocking reasons:",
            "    • latest current review verdict is CHANGES_REQUESTED"
          ]

    it "validates standalone prompts for the authenticated Claude client tool" $ do
      decodeClaudeToolPrompt (object ["prompt" .= ("Review issue #844" :: Text)])
        `shouldBe` Right "Review issue #844"
      decodeClaudeToolPrompt (object ["prompt" .= ("   " :: Text)])
        `shouldBe` Left "kanban_run_claude requires a non-empty prompt"

    it "bounds authenticated GitHub updates to issue comments and review labels" $ do
      let request =
            object
              [ "operation" .= ("update" :: Text),
                "issue" .= (844 :: Int),
                "comment" .= ("## Review result\nApproved." :: Text),
                "addLabels" .= (["reviewed:approve"] :: [Text]),
                "removeLabels" .= (["reviewed:changes", "reviewed:revised"] :: [Text])
              ]
      decodeGitHubIssueToolRequest request
        `shouldBe` Right
          GitHubIssueToolRequest
            { githubToolOperation = GitHubIssueUpdate,
              githubToolIssue = 844,
              githubToolComment = Just "## Review result\nApproved.",
              githubToolAddLabels = ["reviewed:approve"],
              githubToolRemoveLabels = ["reviewed:changes", "reviewed:revised"]
            }
      decodeGitHubIssueToolRequest (object ["operation" .= ("update" :: Text), "issue" .= (844 :: Int), "addLabels" .= (["bug"] :: [Text])])
        `shouldBe` Left "kanban_github_issue may only change reviewed:approve, reviewed:changes, and reviewed:revised"

  describe "solve process protocol" $ do
    it "pins the canonical solver and reviewer model contract" $ do
      codexSolverModel `shouldBe` "gpt-5.4 high"
      claudeSolverModel `shouldBe` "Sonnet 5 high"
      codexReviewerModel `shouldBe` "GPT-5.6-Terra xhigh"
      claudeReviewerModel `shouldBe` "Opus 4.8 xhigh"

    it "launches each solver with its pinned model and effort" $ do
      let codexArguments = solveArguments 844 SolveOnly CodexSolver Nothing ""
          claudeArguments = solveArguments 844 SolveOnly ClaudeSolver Nothing ""
      codexArguments `shouldContain` ["--model", "gpt-5.4"]
      codexArguments `shouldContain` ["model_reasoning_effort=\"high\""]
      codexArguments `shouldContain` ["model_reasoning_summary=\"detailed\""]
      claudeArguments `shouldContain` ["--model", "claude-sonnet-5"]
      claudeArguments `shouldContain` ["--effort", "high"]

    it "runs the ordinary solve command for both S and Kanban-owned A orchestration" $ do
      let codexSolvePrompt = last (solveArguments 844 SolveOnly CodexSolver Nothing "")
          codexAutoSolvePrompt = last (solveArguments 844 AutoSolve CodexSolver Nothing "")
          claudeSolvePrompt = last (solveArguments 844 SolveOnly ClaudeSolver Nothing "")
          claudeAutoSolvePrompt = last (solveArguments 844 AutoSolve ClaudeSolver Nothing "")
      codexSolvePrompt `shouldContain` "$solve"
      codexAutoSolvePrompt `shouldContain` "$solve"
      codexAutoSolvePrompt `shouldNotContain` "$autosolve"
      codexAutoSolvePrompt `shouldContain` "Kanban owns the bounded review/fix loop"
      claudeSolvePrompt `shouldContain` "/solve"
      claudeAutoSolvePrompt `shouldContain` "/solve"
      claudeAutoSolvePrompt `shouldNotContain` "/autosolve"
      codexSolvePrompt `shouldContain` "Do not run issue-review"

    it "recovers an interrupted same-issue worktree instead of treating it as a collision" $ do
      let solvePrompt = last (solveArguments 782 SolveOnly CodexSolver Nothing "")
      solvePrompt `shouldContain` "existing worktree for issue #782"
      solvePrompt `shouldContain` "prior solve was interrupted; it is recovery work, not a collision"
      solvePrompt `shouldContain` "inspect `git status`, committed progress relative to that base, and both staged and unstaged diffs"
      solvePrompt `shouldContain` "Do not discard, reset, or overwrite unfinished changes merely to start clean"
      solvePrompt `shouldContain` "Only create a new sibling worktree when no same-issue worktree exists"

    it "extracts Codex session ids and readable agent output" $ do
      parseSolveOutputLine "{\"type\":\"thread.started\",\"thread_id\":\"019f-session\"}"
        `shouldBe` Right (Just "019f-session", [])
      parseSolveOutputLine "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Created PR #42\"}}"
        `shouldBe` Right (Nothing, [AgentEvent "message" "Created PR #42" "" (Just "Created PR #42")])

    it "extracts Claude session ids and assistant text" $ do
      parseSolveOutputLine "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"claude-session\"}"
        `shouldBe` Right (Just "claude-session", [])
      parseSolveOutputLine "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Working in issue-42\"}]}}"
        `shouldBe` Right (Nothing, [AgentEvent "message" "Working in issue-42" "" (Just "Working in issue-42")])

    it "promotes Claude Bash tools to visible running commands while retaining full input" $ do
      let toolLine = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"git status --short\"}}]}}"
      case parseSolveOutputLine toolLine of
        Right (_, [agentEvent]) -> do
          agentEvent.agentEventKind `shouldBe` "command"
          renderAgentEvent CompactChat agentEvent `shouldBe` Just "[command] git status --short"
          renderAgentEvent StandardChat agentEvent `shouldSatisfy` maybe False (Data.Text.isInfixOf "git status --short")
          renderAgentEvent FullChat agentEvent `shouldSatisfy` maybe False (Data.Text.isInfixOf "command")
        result -> expectationFailure ("unexpected parsed tool event: " <> show result)

  describe "settings" $ do
    it "defaults chat output to standard and persists a selected verbosity" $
      withTemporaryCacheRoot $ \configRoot ->
        withEnvironmentValue "XDG_CONFIG_HOME" configRoot $ do
          loadSettings `shouldReturn` (defaultSettings, Nothing)
          saveSettings (Settings FullChat) `shouldReturn` Right ()
          loadSettings `shouldReturn` (Settings FullChat, Nothing)

  describe "full agent transcripts" $ do
    it "records raw provider lines independently of display verbosity" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/example" "coghex" "example"
              providerLine = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"git status\"}}]}}"
          opened <- openSessionLog repository "solve-claude" 42 Nothing
          case opened of
            Left message -> expectationFailure (Data.Text.unpack message)
            Right sessionLog -> do
              logRawLine sessionLog "stdout" providerLine
              closeSessionLog sessionLog
              contents <- ByteString.readFile sessionLog.sessionLogPath
              contents `shouldSatisfy` ByteString.isInfixOf "git status"

  describe "pull request review/revision routing" $ do
    it "requires one unambiguous PR origin marker" $ do
      originFromBody "body\n<!-- pr-origin:codex -->" `shouldBe` Right PullRequestCodex
      originFromBody "body\n<!-- pr-origin:claude -->" `shouldBe` Right PullRequestClaude
      originFromBody "body" `shouldBe` Left "PR body has no valid pr-origin marker"

    it "advances review, revision, and rereview from durable labels" $ do
      actionForLabels [] `shouldBe` PullRequestReview
      actionForLabels ["reviewed:changes"] `shouldBe` PullRequestRevision
      actionForLabels ["reviewed:changes", "reviewed:revised"] `shouldBe` PullRequestRereview

    it "uses the opposite brand to review and the origin brand to revise" $ do
      agentForAction PullRequestCodex PullRequestReview `shouldBe` ClaudeSolver
      agentForAction PullRequestCodex PullRequestRevision `shouldBe` CodexSolver
      agentForAction PullRequestClaude PullRequestReview `shouldBe` CodexSolver
      agentForAction PullRequestClaude PullRequestRevision `shouldBe` ClaudeSolver

    it "pins canonical reviewer and reviser models" $ do
      pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing "" `shouldContain` ["--model", "claude-opus-4-8", "--effort", "xhigh"]
      pullRequestArguments 42 PullRequestCodex PullRequestRevision CodexSolver Nothing "" `shouldContain` ["--model", "gpt-5.4"]
      pullRequestArguments 42 PullRequestClaude PullRequestRereview CodexSolver Nothing "" `shouldContain` ["--model", "gpt-5.6-terra"]

  describe "repository identity parsing" $ do
    it "parses an HTTPS GitHub remote" $
      parseRepositoryName "https://github.com/coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
    it "parses an SSH GitHub remote" $
      parseRepositoryName "git@github.com:coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
    it "parses explicit OWNER/NAME syntax" $
      parseRepositoryName "coghex/kanban" `shouldBe` Right ("coghex", "kanban")

  describe "external text sanitization" $ do
    it "strips ANSI, control, and bidi sequences" $
      sanitizeText "safe\ESC[31m red\ESC[0m\NUL\x202Etext" `shouldBe` "safe redtext"
    it "selects and normalizes the first meaningful paragraph" $
      excerpt "\n\n  First\tparagraph\nwraps.  \n\nSecond paragraph." `shouldBe` "First paragraph wraps."
    it "excerpts a CRLF single-paragraph body to the full paragraph, not the first line" $
      excerpt "Repro steps:\r\nRun kanban\r\nPress j" `shouldBe` "Repro steps: Run kanban Press j"
    it "excerpts only the first paragraph of a CRLF body with a real paragraph break" $
      excerpt "First paragraph.\r\nstill first.\r\n\r\nSecond paragraph." `shouldBe` "First paragraph. still first."
    it "sanitizes a CRLF body the same as its LF twin" $
      sanitizeText "First paragraph.\r\nstill first.\r\n\r\nSecond paragraph."
        `shouldBe` sanitizeText "First paragraph.\nstill first.\n\nSecond paragraph."
    it "normalizes a lone carriage return to a line break" $
      sanitizeText "left\rright" `shouldBe` "left\nright"

  describe "persistent worker deadline UI projection" $ do
    it "shows the deadline distinctly from a generic failure for both solve and PR worker activity" $ do
      failureActivity "persistent worker deadline exceeded" `shouldBe` "deadline exceeded"
      failureActivity "provider crashed" `shouldBe` "failed"
      failureActivity "persistent worker stopped unexpectedly; its provider process group was terminated" `shouldBe` "failed"

    it "labels an orphan-pending deadline distinctly from ordinary solver or PR agent survivors" $ do
      orphanMessage (SolveFailed "persistent worker deadline exceeded") "2" "the solver"
        `shouldBe` "deadline exceeded; 2 subprocesses survived termination; press x to terminate the orphaned process tree"
      orphanMessage (SolveFailed "persistent worker deadline exceeded") "2" "the PR agent"
        `shouldBe` "deadline exceeded; 2 subprocesses survived termination; press x to terminate the orphaned process tree"
      orphanMessage SolveCompleted "2" "the solver"
        `shouldBe` "2 subprocesses survived the solver; press x to terminate the orphaned process tree"
      orphanMessage SolveCompleted "2" "the PR agent"
        `shouldBe` "2 subprocesses survived the PR agent; press x to terminate the orphaned process tree"

  describe "workflow classification" $ do
    it "keeps linked issues visible while showing their pull requests as separate cards" $ do
      let snapshot = RepoSnapshot [baseIssue 1 [], baseIssue 2 [Assignee "agent"]] [basePullRequest 10 [1] False []] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [1]
      map (itemNumber . entryItem) (Map.findWithDefault [] Active columns) `shouldBe` [2]
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing columns) `shouldBe` [10]

    it "treats a truncated non-empty assignee connection as Active" $ do
      let issue = (baseIssue 1 []) {issueAssigneeOverflow = 1}
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [issue] [] epoch False False)
      map (itemNumber . entryItem) (Map.findWithDefault [] Active columns) `shouldBe` [1]

    it "keeps draft approved pull requests in Reviewing" $ do
      let pullRequest = basePullRequest 10 [] True [Label "reviewed:approve" "00ff00"]
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [] [pullRequest] epoch False False)
      Map.size columns `shouldBe` 4
      length (Map.findWithDefault [] Reviewing columns) `shouldBe` 1
      Map.findWithDefault [] Done columns `shouldBe` []

    it "classifies non-draft approved pull requests as Done" $ do
      let pullRequest = basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [] [pullRequest] epoch False False)
      length (Map.findWithDefault [] Done columns) `shouldBe` 1

    it "keeps tracker issues visible as standalone cards before hierarchy is applied" $ do
      let tracker = (baseIssue 12 []) {issueLabels = [Label "epic" "5319e7"]}
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [tracker] [] epoch False False)
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [12]

    it "sorts standalone issues awaiting rereview ahead of tracker groups and problems" $ do
      let tracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #2 — A1: Tracked"
              }
          revised = (baseIssue 3 []) {issueLabels = [Label "ReViEwEd:ReViSeD" "8250DF"]}
          problem = (baseIssue 4 []) {issueLabels = [Label "blocked" "d73a4a"]}
          snapshot = RepoSnapshot [tracker, baseIssue 2 [], revised, problem] [] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [3, 2, 4]

    it "promotes tracker groups containing rereview issues and puts those children first" $ do
      let revisedTracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #1 — A1: First\n- [ ] #2 — A2: Revised"
              }
          ordinaryTracker =
            (baseIssue 200 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #3 — A1: Ordinary"
              }
          revised = (baseIssue 2 []) {issueLabels = [Label "reviewed:revised" "8250DF"]}
          snapshot = RepoSnapshot [revisedTracker, ordinaryTracker, baseIssue 1 [], revised, baseIssue 3 []] [] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [2, 1, 3]

    it "promotes groups whose tracker issue is awaiting rereview" $ do
      let problemTracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #1 — A1: Problem"
              }
          revisedTracker =
            (baseIssue 200 [])
              { issueLabels = [Label "epic" "5319e7", Label "reviewed:revised" "8250DF"],
                issueBody = "## Children\n- [ ] #2 — A1: Revised tracker child"
              }
          problem = (baseIssue 1 []) {issueLabels = [Label "blocked" "d73a4a"]}
          snapshot = RepoSnapshot [problemTracker, revisedTracker, problem, baseIssue 2 []] [] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [2, 1]

    it "groups tracker children in natural implementation order" $ do
      let tracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #2 — A10: Later\n- [ ] #1 — A2: Earlier"
              }
          snapshot = RepoSnapshot [tracker, baseIssue 1 [], baseIssue 2 []] [] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
          entries = Map.findWithDefault [] Issues columns
      map (itemNumber . entryItem) entries `shouldBe` [1, 2]
      map entryImplementationKey entries `shouldBe` [Just "A2", Just "A10"]

    it "inherits tracker membership through a PR's linked child issue" $ do
      let tracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Phase plan\n- [ ] #1 — B1: Child"
              }
          snapshot = RepoSnapshot [tracker, baseIssue 1 []] [basePullRequest 10 [1] False []] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      case Map.findWithDefault [] Reviewing columns of
        [Tracked trackingContext item] -> do
          itemNumber item `shouldBe` 10
          trackingContext.trackingPrimary.membershipChild.trackerChildImplementationKey `shouldBe` Just "B1"
        values -> expectationFailure ("unexpected reviewing entries: " <> show values)

    it "chooses the earliest implementation key for multi-tracked PRs" $ do
      let laterTracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #1 — B1: Child"
              }
          earlierTracker =
            (baseIssue 200 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #1 — A2: Child"
              }
          snapshot = RepoSnapshot [laterTracker, earlierTracker, baseIssue 1 []] [basePullRequest 10 [1] False []] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      case Map.findWithDefault [] Reviewing columns of
        [Tracked trackingContext _] -> do
          trackingContext.trackingPrimary.membershipTracker.trackerIssue.issueNumber `shouldBe` 200
          map (.membershipTracker.trackerIssue.issueNumber) trackingContext.trackingAdditional `shouldBe` [100]
        values -> expectationFailure ("unexpected multi-tracked entries: " <> show values)

  describe "tracker checklist parsing" $ do
    it "parses supported checkboxes, progress, and natural keys only in tracker sections" $ do
      let body =
            "## Related\n- [ ] #99 — A1: Ignore\n"
              <> "## Children\n### Phase A\n- [ ] #2 — **A10:** Later\n- [x] **#1 — A2: Earlier**\n"
              <> "External prerequisite:\n- [ ] #77 — A3: Ignore\n"
          children = parseTrackerChildren body
      map (.trackerChildIssueNumber) children `shouldBe` [2, 1]
      map (.trackerChildComplete) children `shouldBe` [False, True]
      map (.trackerChildImplementationKey) (sortOn implementationSortKey children) `shouldBe` [Just "A2", Just "A10"]

    it "reports structural checklist loss while retaining valid children" $ do
      let body = "## Children\n- [ ] #2 — A1: Valid\n- [ ] missing reference\n- [?] #3\n- [x] #2 — duplicate"
          (children, diagnostics) = parseTrackerBody body
      map (.trackerChildIssueNumber) children `shouldBe` [2]
      diagnostics
        `shouldBe` [ TrackerIssueReferenceMissing 3,
                     TrackerMalformedCheckbox 4,
                     TrackerDuplicateChild 5 2
                   ]

    it "keeps children from malformed rows standalone on the board" $ do
      let tracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #2 — A1: Valid\n- [?] #3 — A2: Malformed"
              }
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [tracker, baseIssue 2 [], baseIssue 3 []] [] epoch False False)
          entries = Map.findWithDefault [] Issues columns
      entries `shouldSatisfy` any (isStandaloneIssue 3)

    it "diagnoses a labeled tracker without a tracker section" $ do
      let body = "## Context\n- [ ] #2 — A1: Not authoritative"
          tracker = (baseIssue 100 []) {issueLabels = [Label "epic" "5319e7"], issueBody = body}
      snd (parseTrackerBody body) `shouldBe` [TrackerSectionMissing]
      snapshotWarnings (RepoSnapshot [tracker] [] epoch False False)
        `shouldSatisfy` any (Data.Text.isInfixOf "1 tracker")

  describe "GitHub GraphQL decoding" $ do
    it "decodes issue and pull-request fields used by the workflow" $ do
      case decodeGitHubItems (LazyByteString.pack githubResponse) of
        Left message -> expectationFailure message
        Right ([issue], [pullRequest]) -> do
          issue.issueNumber `shouldBe` 41
          issue.issueAssignees `shouldBe` [Assignee "worker"]
          issue.issueLabels `shouldBe` [Label "blocked" "d73a4a"]
          issue.issueLabelOverflow `shouldBe` 2
          issue.issueAssigneeOverflow `shouldBe` 1
          pullRequest.pullRequestLinkedIssues `shouldBe` [41]
          pullRequest.pullRequestLinkedIssueOverflow `shouldBe` 3
          pullRequest.pullRequestReviewDecision `shouldBe` ReviewApproved
          pullRequest.pullRequestMergeState `shouldBe` MergeConflicting
          pullRequest.pullRequestChecks `shouldBe` ChecksFailed 1 2
          let warnings = snapshotWarnings (RepoSnapshot [issue] [pullRequest] epoch True True)
          length warnings `shouldBe` 3
          warnings `shouldSatisfy` any (Data.Text.isInfixOf "+N markers")
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    it "deduplicates rerun checks and treats mergeable policy blocks as protected" $ do
      case decodeGitHubItems (LazyByteString.pack githubRerunResponse) of
        Left message -> expectationFailure message
        Right ([], [pullRequest]) -> do
          pullRequest.pullRequestChecks `shouldBe` ChecksPassed 3
          pullRequest.pullRequestMergeState `shouldBe` MergeProtected
          pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusReady
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    it "rejects GraphQL error responses" $
      decodeGitHubItems "{\"errors\":[{\"message\":\"boom\"}],\"data\":{}}"
        `shouldSatisfy` isLeft

    it "marks a capped connection incomplete instead of requesting beyond its limit" $
      paginationDecision 250 250 True (Just "next") `shouldBe` Right (False, Nothing, True)

    it "does not mark an exact cap incomplete when GitHub reports no next page" $
      paginationDecision 250 250 False Nothing `shouldBe` Right (False, Nothing, False)

    it "requires a cursor whenever another page is needed" $
      paginationDecision 250 100 True Nothing `shouldSatisfy` isLeft

  describe "Codex app-server decoding" $ do
    it "maps returned windows by duration and computes percentage left" $ do
      case decodeCodexUsageResponse epoch codexRateLimitResponse of
        Left providerError -> expectationFailure (show providerError)
        Right snapshot -> do
          map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["5 hour", "week"]
          map (.usagePercentLeft) snapshot.usageWindows `shouldBe` [78, 59]
          snapshot.usageFetchedAt `shouldBe` epoch

    it "accepts an account that currently exposes only a weekly window" $ do
      case decodeCodexUsageResponse epoch codexWeeklyOnlyResponse of
        Left providerError -> expectationFailure (show providerError)
        Right snapshot -> map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["week"]

  describe "Claude /usage decoding" $ do
    it "selects the last complete screen-reader update" $ do
      case decodeClaudeUsageText (minutesToTimeZone (-420)) epoch claudeUsageOutput of
        Left providerError -> expectationFailure (show providerError)
        Right snapshot -> do
          map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["5 hour", "week"]
          map (.usagePercentLeft) snapshot.usageWindows `shouldBe` [79, 86]

    it "fails closed when the interactive usage request fails" $
      decodeClaudeUsageText (minutesToTimeZone (-420)) epoch "Current session\nFailed to load usage data"
        `shouldSatisfy` isLeft

  describe "PR drainer status decoding" $ do
    it "replaces the LaunchAgent's managed repository with the current one" $ do
      let repository = Repository "/tmp/current-project" "example" "project"
          expected =
            Right
              ( DrainerController
                  "/usr/bin/python3"
                  ["/tmp/drain_prs_service.py", "--path", "/tmp/current-project"]
              )
      controllerFromProgramArguments
        repository
        ["/usr/bin/python3", "/tmp/drain_prs_service.py", "run"]
        `shouldBe` expected
      controllerFromProgramArguments
        repository
        ["/usr/bin/python3", "/tmp/drain_prs_service.py", "--path", "/tmp/previous-project", "run"]
        `shouldBe` expected

    it "maps a running managed drainer to green/on" $ do
      let result = decodeDrainerStatus "{\"state\":\"running\",\"open_incident\":null}"
      result `shouldBe` Right (DrainerStatus DrainerOn "on")
      result `shouldSatisfy` either (const False) drainerIsRunning

    it "makes a running drainer with an unresolved incident a warning" $ do
      let result = decodeDrainerStatus "{\"state\":\"running\",\"open_incident\":{\"summary\":\"prior crash\"}}"
      result `shouldBe` Right (DrainerStatus DrainerWarning "on · unresolved incident · prior crash")
      result `shouldSatisfy` either (const False) drainerIsRunning

    it "makes a stopped drainer with an unresolved incident an error" $
      decodeDrainerStatus "{\"state\":\"stopped\",\"open_incident\":{\"summary\":\"model failed\"}}"
        `shouldBe` Right (DrainerStatus DrainerError "stopped · unresolved incident · model failed")

    it "warns when the singleton drainer belongs to another repository" $
      decodeDrainerStatus "{\"state\":\"foreign\",\"open_incident\":null}"
        `shouldBe` Right (DrainerStatus DrainerWarning "another repository is running")

    it "rejects unsupported controller output" $
      decodeDrainerStatus "{\"state\":\"paused\"}"
        `shouldBe` Right (DrainerStatus DrainerError "unknown state: paused")

  describe "repository snapshot cache" $ do
    it "round-trips a versioned snapshot and ignores corrupt JSON" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
              snapshot = RepoSnapshot [baseIssue 7 []] [] epoch False False
          writeRepositoryCache repository snapshot `shouldReturn` Right ()
          loadRepositoryCache repository `shouldReturn` CacheLoaded snapshot
          cachePath <- repositoryCachePath repository
          LazyByteString.writeFile cachePath "not JSON"
          invalid <- loadRepositoryCache repository
          invalid `shouldSatisfy` isInvalidCache

    it "round-trips global usage snapshots" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let codexUsage = UsageSnapshot [UsageWindow "week" 77 epoch] epoch
              claudeUsage = UsageSnapshot [UsageWindow "5 hour" 65 epoch] epoch
              snapshots = Map.fromList [(Codex, codexUsage), (Claude, claudeUsage)]
          writeUsageCache snapshots `shouldReturn` Right ()
          loadUsageCache `shouldReturn` UsageCacheLoaded snapshots

  describe "pull request status" $ do
    it "makes conflicts red even when approved and CI passed" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeConflicting, pullRequestChecks = ChecksPassed 4}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusProblem "merge conflict"
    it "makes clean approved pull requests green when CI passed" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeClean, pullRequestChecks = ChecksPassed 4}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusReady

  describe "responsive board layout" $ do
    it "shares a wide board across all four columns" $
      responsiveColumnWidths 167 `shouldBe` [41, 41, 40, 40]
    it "keeps readable columns and relies on scrolling below the threshold" $
      responsiveColumnWidths 100 `shouldBe` [32, 32, 32, 32]
    it "accounts for two-cell gutters in the open layout" $
      responsiveOpenColumnWidths 170 `shouldBe` [41, 41, 41, 41]

baseIssue :: Int -> [Assignee] -> Issue
baseIssue number assignees =
  Issue number ("Issue " <> showText number) "Body" "https://example.test" [] assignees epoch epoch 0 0

basePullRequest :: Int -> [Int] -> Bool -> [Label] -> PullRequest
basePullRequest number linked draft labels =
  PullRequest
    number
    ("PR " <> showText number)
    "Body"
    "https://example.test"
    labels
    "agent"
    draft
    "master"
    "branch"
    linked
    ReviewRequired
    MergeUnknown
    ChecksUnknown
    epoch
    epoch
    0
    0

itemNumber :: BoardItem -> Int
itemNumber (IssueItem issue) = issue.issueNumber
itemNumber (PullRequestItem pullRequest) = pullRequest.pullRequestNumber

isStandaloneIssue :: Int -> ColumnEntry -> Bool
isStandaloneIssue expectedNumber (Standalone (IssueItem issue)) = issue.issueNumber == expectedNumber
isStandaloneIssue _ _ = False

entryImplementationKey :: ColumnEntry -> Maybe Text
entryImplementationKey (Tracked trackingContext _) = trackingContext.trackingPrimary.membershipChild.trackerChildImplementationKey
entryImplementationKey (Standalone _) = Nothing

showText :: Show value => value -> Text
showText = Data.Text.pack . show

epoch :: UTCTime
epoch = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)

isLeft :: Either left right -> Bool
isLeft (Left _) = True
isLeft (Right _) = False

isInvalidCache :: CacheLoad -> Bool
isInvalidCache (CacheInvalid _) = True
isInvalidCache _ = False

withTemporaryCacheRoot :: (FilePath -> IO result) -> IO result
withTemporaryCacheRoot = bracket createTemporaryDirectory removePathForcibly

createTemporaryDirectory :: IO FilePath
createTemporaryDirectory = do
  temporaryRoot <- getTemporaryDirectory
  (path, handle) <- openTempFile temporaryRoot "kanban-cache-test"
  hClose handle
  removeFile path
  createDirectory path
  pure path

withEnvironmentValue :: String -> String -> IO result -> IO result
withEnvironmentValue name value action =
  bracket
    (do previous <- lookupEnv name; setEnv name value; pure previous)
    (maybe (unsetEnv name) (setEnv name))
    (const action)

withManagedShell :: String -> (ProcessHandle -> IO result) -> IO result
withManagedShell command = bracket start stop
  where
    start = do
      (_, _, _, process) <- createProcess (proc "sh" ["-c", command]) {create_group = True}
      pure process
    stop process = do
      managedProcessFor process >>= killManagedProcess
      void (timeout 3000000 (waitForProcess process))

managedProcessFor :: ProcessHandle -> IO ManagedProcess
managedProcessFor process = fst <$> managedProcess process

-- | Like 'withManagedShell', but deliberately spawns the child *without*
-- becoming its own process group leader, to exercise the
-- signal-the-individual-PID fallback ('signalOwnedGroup' in
-- "Kanban.Process"). Cleanup signals the child's own PID directly with
-- SIGKILL rather than going through 'killManagedProcess' — the very
-- operation under test — so a failing assertion in the fallback it tests
-- still cannot leak this intentionally non-grouped child.
withNonLeaderShell :: String -> (ProcessHandle -> IO result) -> IO result
withNonLeaderShell command = bracket start stop
  where
    start = do
      (_, _, _, process) <- createProcess (proc "sh" ["-c", command]) {create_group = False}
      pure process
    stop process = do
      maybePid <- getPid process
      mapM_ (\pid -> void (try (signalProcess sigKILL pid) :: IO (Either IOException ()))) maybePid
      void (timeout 3000000 (waitForProcess process))

processIdentity :: Int -> Int -> Int -> Text -> ProcessIdentity
processIdentity processId parentId groupId command =
  ProcessIdentity
    { processIdentityPid = processId,
      processIdentityParentPid = parentId,
      processIdentityGroupPid = groupId,
      processIdentityStartedAt = "Fri Jul 17 12:00:00 2026",
      processIdentityCommand = command
    }

identityForProcess :: ProcessHandle -> IO ProcessIdentity
identityForProcess process = do
  processId <- getPid process
  pid <- maybe (fail "managed shell exited before it could be identified") (pure . fromIntegral) processId
  snapshot <- readProcessSnapshot
  case snapshot of
    Left message -> fail ("could not snapshot processes: " <> Data.Text.unpack message)
    Right identities -> case identityForPid pid identities of
      Just identity -> pure identity
      Nothing -> fail "spawned process was not present in a process snapshot"

runningWorkerState :: WorkerId -> Int -> Maybe ProcessIdentity -> WorkerState
runningWorkerState identifier pid identity =
  WorkerState
    { workerStateId = identifier,
      workerStateStatus = WorkerRunning,
      workerStateWorkerPid = pid,
      workerStateWorkerIdentity = identity,
      workerStateProviderPid = Nothing,
      workerStateProviderIdentity = Nothing,
      workerStateSessionId = Nothing,
      workerStateLogPath = Nothing,
      workerStateHeartbeatAt = epoch,
      workerStateLastActivity = "running",
      workerStateKnownProcesses = []
    }

isDiagnosticEvent :: WorkerEvent -> Bool
isDiagnosticEvent (WorkerDiagnostic _) = True
isDiagnosticEvent _ = False

isWorkerFailedEvent :: WorkerEvent -> Bool
isWorkerFailedEvent (WorkerFinished (SolveFailed _)) = True
isWorkerFailedEvent _ = False

workerFixtureSpec :: UTCTime -> Int -> Repository -> WorkerId -> Int -> WorkerSpec
workerFixtureSpec createdAt maxRuntimeSeconds repository identifier issueNumber =
  WorkerSpec
    { workerId = identifier,
      workerRepository = repository,
      workerTask = SolveWorkerTaskKind (SolveWorkerTask issueNumber SolveOnly CodexSolver),
      workerExistingSession = Nothing,
      workerExistingLogPath = Nothing,
      workerUserMessage = "",
      workerParent = Nothing,
      workerCreatedAt = createdAt,
      workerMaxRuntimeSeconds = maxRuntimeSeconds
    }

waitForWorkerState :: FilePath -> (WorkerState -> Bool) -> Int -> IO WorkerState
waitForWorkerState path predicate attempts = do
  exists <- doesFileExist path
  decoded <- if exists then eitherDecode <$> LazyByteString.readFile path else pure (Left "state not created")
  case decoded of
    Right state | predicate state -> pure state
    _
      | attempts <= 0 -> fail ("worker state did not reach the expected condition: " <> show decoded)
      | otherwise -> threadDelay 100000 >> waitForWorkerState path predicate (attempts - 1)

isOrphaned :: WorkerState -> Bool
isOrphaned state = case state.workerStateStatus of
  WorkerOrphaned _ -> True
  _ -> False

isTerminal :: WorkerState -> Bool
isTerminal state = case state.workerStateStatus of
  WorkerTerminal _ -> True
  _ -> False

githubResponse :: String
githubResponse =
  unlines
    [ "{",
      "  \"data\": {",
      "    \"repository\": {",
      "      \"issues\": {",
      "        \"nodes\": [{",
      "          \"number\": 41, \"title\": \"Blocked issue\", \"body\": \"Details\",",
      "          \"url\": \"https://example.test/issues/41\",",
      "          \"labels\": {\"totalCount\": 3, \"nodes\": [{\"name\": \"blocked\", \"color\": \"d73a4a\"}]},",
      "          \"assignees\": {\"totalCount\": 2, \"nodes\": [{\"login\": \"worker\"}]},",
      "          \"createdAt\": \"2026-01-01T00:00:00Z\", \"updatedAt\": \"2026-01-02T00:00:00Z\"",
      "        }],",
      "        \"pageInfo\": {\"hasNextPage\": false, \"endCursor\": null}",
      "      },",
      "      \"pullRequests\": {",
      "        \"nodes\": [{",
      "          \"number\": 9, \"title\": \"Fix it\", \"body\": \"PR details\",",
      "          \"url\": \"https://example.test/pull/9\", \"labels\": {\"totalCount\": 0, \"nodes\": []},",
      "          \"author\": {\"login\": \"author\"}, \"isDraft\": false,",
      "          \"baseRefName\": \"master\", \"headRefName\": \"fix\",",
      "          \"closingIssuesReferences\": {\"totalCount\": 4, \"nodes\": [{\"number\": 41}]},",
      "          \"reviewDecision\": \"APPROVED\", \"mergeable\": \"CONFLICTING\",",
      "          \"mergeStateStatus\": \"DIRTY\",",
      "          \"statusCheckRollup\": {\"contexts\": {\"totalCount\": 3, \"nodes\": [",
      "            {\"__typename\": \"CheckRun\", \"name\": \"build-test\", \"status\": \"COMPLETED\", \"conclusion\": \"SUCCESS\", \"startedAt\": \"2026-01-03T00:00:00Z\", \"completedAt\": \"2026-01-03T00:01:00Z\", \"checkSuite\": {\"app\": {\"slug\": \"github-actions\"}}},",
      "            {\"__typename\": \"CheckRun\", \"name\": \"review-approved\", \"status\": \"COMPLETED\", \"conclusion\": \"SUCCESS\", \"startedAt\": \"2026-01-03T00:00:00Z\", \"completedAt\": \"2026-01-03T00:01:00Z\", \"checkSuite\": {\"app\": {\"slug\": \"github-actions\"}}},",
      "            {\"__typename\": \"CheckRun\", \"name\": \"review-approved\", \"status\": \"COMPLETED\", \"conclusion\": \"FAILURE\", \"startedAt\": \"2026-01-03T00:02:00Z\", \"completedAt\": \"2026-01-03T00:03:00Z\", \"checkSuite\": {\"app\": {\"slug\": \"github-actions\"}}}",
      "          ]}},",
      "          \"createdAt\": \"2026-01-03T00:00:00Z\", \"updatedAt\": \"2026-01-04T00:00:00Z\"",
      "        }],",
      "        \"pageInfo\": {\"hasNextPage\": false, \"endCursor\": null}",
      "      }",
      "    }",
      "  }",
      "}"
    ]

githubRerunResponse :: String
githubRerunResponse =
  unlines
    [ "{\"data\":{\"repository\":{",
      "\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}},",
      "\"pullRequests\":{\"nodes\":[{",
      "\"number\":858,\"title\":\"Ready after rerun\",\"body\":\"Closes #844\",\"url\":\"https://example.test/pull/858\",",
      "\"labels\":{\"totalCount\":1,\"nodes\":[{\"name\":\"reviewed:approve\",\"color\":\"0e8a16\"}]},",
      "\"author\":{\"login\":\"author\"},\"isDraft\":false,\"baseRefName\":\"master\",\"headRefName\":\"fix\",",
      "\"closingIssuesReferences\":{\"totalCount\":1,\"nodes\":[{\"number\":844}]},",
      "\"reviewDecision\":null,\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"BLOCKED\",",
      "\"statusCheckRollup\":{\"contexts\":{\"totalCount\":5,\"nodes\":[",
      checkRunJson "review-approved" "FAILURE" "2026-07-17T14:43:13Z",
      ",",
      checkRunJson "review-approved" "SUCCESS" "2026-07-17T14:48:53Z",
      ",",
      checkRunJson "build-test" "SUCCESS" "2026-07-17T14:43:35Z",
      ",",
      checkRunJson "dismiss-stale-approval" "SKIPPED" "2026-07-17T14:48:50Z",
      ",",
      checkRunJson "dismiss-stale-approval" "SKIPPED" "2026-07-17T14:43:16Z",
      "]}},",
      "\"createdAt\":\"2026-07-17T13:21:31Z\",\"updatedAt\":\"2026-07-17T14:48:47Z\"",
      "}],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}",
      "}}}"
    ]

checkRunJson :: String -> String -> String -> String
checkRunJson name conclusion startedAt =
  "{\"__typename\":\"CheckRun\",\"name\":\""
    <> name
    <> "\",\"status\":\"COMPLETED\",\"conclusion\":\""
    <> conclusion
    <> "\",\"startedAt\":\""
    <> startedAt
    <> "\",\"completedAt\":\""
    <> startedAt
    <> "\",\"checkSuite\":{\"app\":{\"slug\":\"github-actions\"}}}"

codexRateLimitResponse :: LazyByteString.ByteString
codexRateLimitResponse =
  "{\"id\":1,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":99,\"windowDurationMins\":10080,\"resetsAt\":1784810495},\"secondary\":null},\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"usedPercent\":22,\"windowDurationMins\":300,\"resetsAt\":1784010000},\"secondary\":{\"usedPercent\":41,\"windowDurationMins\":10080,\"resetsAt\":1784810495}}}}}"

codexWeeklyOnlyResponse :: LazyByteString.ByteString
codexWeeklyOnlyResponse =
  "{\"id\":1,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":23,\"windowDurationMins\":10080,\"resetsAt\":1784810495},\"secondary\":null},\"rateLimitsByLimitId\":null}}"

claudeUsageOutput :: Text
claudeUsageOutput =
  Data.Text.unlines
    [ "Current session",
      "20% 20% used",
      "Resets 8:40pm (America/Los_Angeles)",
      "Current week (all models)",
      "13% 13% used",
      "Resets Jul 22 at 11pm (America/Los_Angeles)",
      "Refreshing…",
      "21% 21% used",
      "Resets 8:39pm (America/Los_Angeles)",
      "Current week (all models)",
      "14% 14% used",
      "Resets Jul 22 at 10:59pm (America/Los_Angeles)",
      "Usage credits",
      "78% 78% used",
      "$156.37 / $200.00 spent · Resets Aug 1 (America/Los_Angeles)"
    ]
