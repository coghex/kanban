module Main (main) where

import Brick (BrickEvent (..), Location (..))
import Control.Concurrent (forkIO, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar, threadDelay)
import Control.Exception (IOException, SomeException, bracket, finally, try, uninterruptibleMask_)
import Control.Monad (void)
import Data.Aeson (Value (..), eitherDecode, encode, object, (.=))
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.IORef (atomicModifyIORef', modifyIORef, newIORef, readIORef, writeIORef)
import Data.List (find, isInfixOf, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, getCurrentTime, minutesToTimeZone, secondsToDiffTime)
import qualified Graphics.Vty as Vty
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
    managedProcessPid,
    matchingIdentities,
    membersStillInGroup,
    readProcessSnapshot,
  )
import Kanban.Repository (parseRepositoryName)
import Kanban.PullRequestFlow
  ( PullRequestAction (..),
    PullRequestOrigin (..),
    PullRequestVerdict (..),
    actionForLabels,
    agentForAction,
    originFromBody,
    pullRequestArguments,
    pullRequestVerdictForLabels,
  )
import Kanban.Review
  ( CanonicalIssueReviewResult (..),
    GitHubIssueOperation (..),
    GitHubIssueToolRequest (..),
    ReviewApproval (..),
    ReviewChoice (..),
    ReviewQuestion (..),
    ReviewQuestionKind (..),
    ReviewRequestId (..),
    ReviewResult (..),
    ReviewStage (..),
    ReviewWireMessage (..),
    decodeCanonicalIssueReviewResult,
    decodeClaudeToolPrompt,
    decodeGitHubIssueToolRequest,
    decodeReviewQuestion,
    decodeReviewResult,
    decodeReviewWireMessage,
    canonicalIssueReviewerPath,
    resolveCanonicalIssueReviewer,
    reviewStageForLabels,
    renderCanonicalIssueReviewResult,
    renderReviewResult,
  )
import Kanban.Solve
  ( AgentEvent (..),
    ResumeProvenance (..),
    SolveOutcome (..),
    SolveWorkflow (..),
    SolverBrand (..),
    claudeReviewerModel,
    claudeSolverModel,
    codexReviewerModel,
    codexSolverModel,
    parseSolveOutputLine,
    renderAgentEvent,
    resumeProvenanceHeader,
    solveArguments,
  )
import Kanban.Settings (ChatVerbosity (..), Settings (..), defaultSettings, loadSettings, saveSettings)
import Kanban.Text (excerpt, sanitizeText)
import Kanban.Transcript (closeSessionLog, logRawLine, openSessionLog, sessionLogPath)
import Kanban.Tracker (implementationSortKey, parseTrackerBody, parseTrackerChildren)
import Kanban.UI
  ( AgentSessionEntry (..),
    AgentSessionRef (..),
    ChatTranscript (..),
    Name (..),
    OverlayMouseAction (..),
    PendingReviewInteraction (..),
    ProcessClickOutcome (..),
    ProcessSelection (..),
    PullRequestReviewSession (..),
    ReviewCancelAction (..),
    ReviewDigitAction (..),
    ReviewPhase (..),
    ReviewSession (..),
    SolvePhase (..),
    SolveSession (..),
    canonicalReviewCompletionSuperseded,
    failureActivity,
    orphanMessage,
    overlayMouseAction,
    pullRequestSessionAlreadyResolved,
    pullRequestSessionReusable,
    reconcileReviewSessions,
    resolveReviewCancelAction,
    resolveProcessClick,
    resolveProcessSelection,
    resolveReviewDigitAction,
    reviewPhaseAttribute,
    reviewPhaseGlyphFor,
    reviewPhaseLabel,
    reviewSessionReusable,
    revisedAttr,
    solveSessionAlreadyResolved,
  )
import Kanban.Workflow (CardStatus (..), deriveBoard, entryItem, pullRequestStatus)
import Kanban.Worker
  ( ProviderSlot (..),
    PullRequestWorkerTask (..),
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
    recordLaunchedSupervisorIdentity,
    recoverIfWorkerStoppedWith,
    releaseWorkerLease,
    runWorker,
    runWorkerWith,
    runWorkerWithTask,
    terminateProviderRefWith,
    terminateRecordedStateProcessesWith,
    terminateWorkerWith,
    waitForOrphanResolution,
    waitForWorkerStart,
    workerDeadlineReason,
  )
import System.Directory (createDirectory, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getTemporaryDirectory, removeFile, removePathForcibly, setModificationTime)
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
                workerResumeProvenance = ResumeInterruptGuidance,
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
                resolved <- recoverIfWorkerStoppedWith readProcessSnapshot first collect
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
                recovered1 <- recoverIfWorkerStoppedWith readProcessSnapshot descriptor collect
                recovered1 `shouldBe` False
                leaseHeld <- doesDirectoryExist descriptor.workerDescriptorLeasePath
                leaseHeld `shouldBe` True
                pendingEvents <- readIORef collected
                pendingEvents `shouldBe` []
                managedProcessFor descendantProcess >>= killManagedProcess
                void (timeout 3000000 (waitForProcess descendantProcess))
                recovered2 <- recoverIfWorkerStoppedWith readProcessSnapshot descriptor collect
                recovered2 `shouldBe` True
                leaseReleased <- doesDirectoryExist descriptor.workerDescriptorLeasePath
                leaseReleased `shouldBe` False
                finalEvents <- readIORef collected
                finalEvents `shouldBe` [WorkerFinished SolveCompleted]

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
          let stallForever _spec _rememberProvider _emit = threadDelay (120 * 1000000)
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
          let finishInstantly _spec _rememberProvider emit = emit (WorkerFinished SolveCompleted)
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
          let hangForever _spec _rememberProvider _emit = threadDelay (300 * 1000000)
          finished <- newEmptyMVar
          void . forkIO $ runWorkerWithTask readProcessSnapshot hangForever specPath >>= putMVar finished
          timeout 5000000 (takeMVar finished) `shouldReturn` Just (Right ())
          terminalState <- waitForWorkerState statePath isTerminal 10
          terminalState.workerStateStatus `shouldBe` WorkerTerminal (SolveFailed workerDeadlineReason)
          leaseReleased <- doesDirectoryExist leasePath
          leaseReleased `shouldBe` False

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
            let registerThenHang _spec rememberProvider _emit = do
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
          let lateRegister _spec _rememberProvider emit = uninterruptibleMask_ $ do
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
            let registerThenHang _spec rememberProvider _emit = do
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
            let completeThenSlow _spec rememberProvider emit = do
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
          let completeAfterDeadline _spec _rememberProvider emit = uninterruptibleMask_ $ do
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
            let registerThenWaitAndFinish _spec rememberProvider emit = do
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
                  workerMaxRuntimeSeconds = 60
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
            let spawningThenRegister _spec rememberProvider emit = uninterruptibleMask_ $ do
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
            let lateSpawnClaim _spec rememberProvider emit = uninterruptibleMask_ $ do
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
            let lateRegistrationWithDescendant _spec rememberProvider emit = uninterruptibleMask_ $ do
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
            let completeThenOrphan _spec rememberProvider emit = do
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

  describe "persistent worker deadline UI projections" $ do
    it "renders the deadline reason distinctly from a generic provider failure" $ do
      failureActivity workerDeadlineReason `shouldBe` "deadline exceeded"
      failureActivity "some other unexpected failure" `shouldBe` "failed"

    it "renders the deadline reason distinctly for orphan-pending subprocesses, for both solve and PR workers" $ do
      orphanMessage (SolveFailed workerDeadlineReason) "2" "the solver"
        `shouldBe` "deadline exceeded; 2 subprocesses survived termination; press x to terminate the orphaned process tree"
      orphanMessage SolveCompleted "2" "the solver"
        `shouldBe` "2 subprocesses survived the solver; press x to terminate the orphaned process tree"
      orphanMessage (SolveFailed workerDeadlineReason) "1" "the PR agent"
        `shouldBe` "deadline exceeded; 1 subprocesses survived termination; press x to terminate the orphaned process tree"
      orphanMessage SolveCompleted "1" "the PR agent"
        `shouldBe` "1 subprocesses survived the PR agent; press x to terminate the orphaned process tree"

    it "suppresses a late WorkerAgentOutput/WorkerDiagnostic projection once a solve or PR session has already resolved" $ do
      -- 'applyWorkerProtocolEvent' cannot be exercised directly in a unit
      -- test (it runs in brick's 'EventM', which exposes no way to run an
      -- action against a plain state outside a live Vty event loop); this
      -- instead directly covers 'solveSessionAlreadyResolved' and
      -- 'pullRequestSessionAlreadyResolved', the pure predicates that
      -- decide whether a trailing 'WorkerAgentOutput'/'WorkerDiagnostic'
      -- event -- which 'streamOutput'/'streamDiagnostics' can still emit
      -- after the watchdog has already committed 'WorkerOrphansDetected' or
      -- 'WorkerFinished' -- gets applied at all.
      let solveSessionWith phase =
            SolveSession
              { solveSessionIssue = baseIssue 787 [],
                solveSessionWorkflow = SolveOnly,
                solveSessionBrand = CodexSolver,
                solveSessionId = Nothing,
                solveSessionPhase = phase,
                solveSessionActivity = "thinking",
                solveSessionActivityStartedAt = epoch,
                solveSessionLogPath = Nothing,
                solveSessionTranscript = ChatTranscript "" "" "",
                solveSessionInput = "",
                solveSessionSpinnerFrame = 0,
                solveSessionAutoProgress = Nothing,
                solveSessionResumeProvenance = ResumeAnswer
              }
          solveSessionsWith phase = Map.fromList [(787, solveSessionWith phase)]
      mapM_
        (\phase -> solveSessionAlreadyResolved 787 (solveSessionsWith phase) `shouldBe` True)
        [SolveFinished, SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase]
      mapM_
        (\phase -> solveSessionAlreadyResolved 787 (solveSessionsWith phase) `shouldBe` False)
        [SolveStarting, SolveRunning, SolveInterrupting, SolveAttention]
      solveSessionAlreadyResolved 999 (solveSessionsWith SolveFinished) `shouldBe` False
      let pullRequestSessionWith phase =
            PullRequestReviewSession
              { pullRequestSessionPullRequest = basePullRequest 826 [] False [],
                pullRequestSessionOrigin = PullRequestCodex,
                pullRequestSessionAction = PullRequestReview,
                pullRequestSessionLaunchedForUpdatedAt = epoch,
                pullRequestSessionBrand = CodexSolver,
                pullRequestSessionId = Nothing,
                pullRequestSessionPhase = phase,
                pullRequestSessionActivity = "thinking",
                pullRequestSessionActivityStartedAt = epoch,
                pullRequestSessionLogPath = Nothing,
                pullRequestSessionTranscript = ChatTranscript "" "" "",
                pullRequestSessionInput = "",
                pullRequestSessionSpinnerFrame = 0,
                pullRequestSessionResumeProvenance = ResumeAnswer
              }
          pullRequestSessionsWith phase = Map.fromList [(826, pullRequestSessionWith phase)]
      mapM_
        (\phase -> pullRequestSessionAlreadyResolved 826 (pullRequestSessionsWith phase) `shouldBe` True)
        [SolveFinished, SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase]
      mapM_
        (\phase -> pullRequestSessionAlreadyResolved 826 (pullRequestSessionsWith phase) `shouldBe` False)
        [SolveStarting, SolveRunning, SolveInterrupting, SolveAttention]
      pullRequestSessionAlreadyResolved 999 (pullRequestSessionsWith SolveFinished) `shouldBe` False

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

    it "resolves the bundled canonical issue reviewer from its Kanban-managed install directory" $ do
      temporaryRoot <- createTemporaryDirectory
      let installDir = temporaryRoot </> "issue-review"
          scriptPath = installDir </> "approve_issues.py"
      withEnvironmentValue "KANBAN_ISSUE_REVIEW_INSTALL_DIR" installDir $ do
        canonicalIssueReviewerPath `shouldReturn` scriptPath
        missing <- resolveCanonicalIssueReviewer
        case missing of
          Left message -> do
            message `shouldSatisfy` Data.Text.isInfixOf "was not found at"
            message `shouldSatisfy` Data.Text.isInfixOf "tools/install_issue_review.py"
          Right found -> expectationFailure ("expected a missing-backend diagnostic, got " <> found)
        createDirectoryIfMissing True installDir
        writeFile scriptPath "#!/usr/bin/env python3\n"
        resolveCanonicalIssueReviewer `shouldReturn` Right scriptPath

    it "resolves the bundled canonical issue reviewer without KANBAN_ISSUE_REVIEW_INSTALL_DIR requiring ~/work" $
      withoutEnvironmentValue "KANBAN_ISSUE_REVIEW_INSTALL_DIR" $ do
        scriptPath <- canonicalIssueReviewerPath
        scriptPath `shouldSatisfy` (not . isInfixOf "/work/approve-issues.py")
        scriptPath `shouldSatisfy` isInfixOf "kanban/issue-review/approve_issues.py"

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
      let codexArguments = solveArguments 844 SolveOnly CodexSolver Nothing ResumeAnswer ""
          claudeArguments = solveArguments 844 SolveOnly ClaudeSolver Nothing ResumeAnswer ""
      codexArguments `shouldContain` ["--model", "gpt-5.4"]
      codexArguments `shouldContain` ["model_reasoning_effort=\"high\""]
      codexArguments `shouldContain` ["model_reasoning_summary=\"detailed\""]
      claudeArguments `shouldContain` ["--model", "claude-sonnet-5"]
      claudeArguments `shouldContain` ["--effort", "high"]

    it "runs the ordinary solve command for both S and Kanban-owned A orchestration" $ do
      let codexSolvePrompt = last (solveArguments 844 SolveOnly CodexSolver Nothing ResumeAnswer "")
          codexAutoSolvePrompt = last (solveArguments 844 AutoSolve CodexSolver Nothing ResumeAnswer "")
          claudeSolvePrompt = last (solveArguments 844 SolveOnly ClaudeSolver Nothing ResumeAnswer "")
          claudeAutoSolvePrompt = last (solveArguments 844 AutoSolve ClaudeSolver Nothing ResumeAnswer "")
      codexSolvePrompt `shouldContain` "$solve"
      codexAutoSolvePrompt `shouldContain` "$solve"
      codexAutoSolvePrompt `shouldNotContain` "$autosolve"
      codexAutoSolvePrompt `shouldContain` "Kanban owns the bounded review/fix loop"
      claudeSolvePrompt `shouldContain` "/solve"
      claudeAutoSolvePrompt `shouldContain` "/solve"
      claudeAutoSolvePrompt `shouldNotContain` "/autosolve"
      codexSolvePrompt `shouldContain` "Do not run issue-review"

    it "recovers an interrupted same-issue worktree instead of treating it as a collision" $ do
      let solvePrompt = last (solveArguments 782 SolveOnly CodexSolver Nothing ResumeAnswer "")
      solvePrompt `shouldContain` "existing worktree for issue #782"
      solvePrompt `shouldContain` "prior solve was interrupted; it is recovery work, not a collision"
      solvePrompt `shouldContain` "inspect `git status`, committed progress relative to that base, and both staged and unstaged diffs"
      solvePrompt `shouldContain` "Do not discard, reset, or overwrite unfinished changes merely to start clean"
      solvePrompt `shouldContain` "Only create a new sibling worktree when no same-issue worktree exists"

    it "frames a resumed solve prompt with the true provenance of the resumed message instead of always claiming a user answer" $ do
      let answerPrompt = last (solveArguments 844 SolveOnly CodexSolver (Just "session-1") ResumeAnswer "pick option B")
          interruptPrompt = last (solveArguments 844 SolveOnly CodexSolver (Just "session-1") ResumeInterruptGuidance "focus on the other file instead")
          automatedPrompt = last (solveArguments 844 AutoSolve CodexSolver (Just "session-1") ResumeAutomatedChangesRequested "Kanban received CHANGES_REQUESTED for PR #900")
      answerPrompt `shouldContain` Data.Text.unpack (resumeProvenanceHeader ResumeAnswer)
      answerPrompt `shouldContain` "KANBAN_NEEDS_INPUT"
      interruptPrompt `shouldContain` Data.Text.unpack (resumeProvenanceHeader ResumeInterruptGuidance)
      interruptPrompt `shouldNotContain` "The user answered"
      interruptPrompt `shouldContain` "KANBAN_NEEDS_INPUT"
      automatedPrompt `shouldContain` Data.Text.unpack (resumeProvenanceHeader ResumeAutomatedChangesRequested)
      automatedPrompt `shouldNotContain` "The user answered"
      automatedPrompt `shouldContain` "KANBAN_NEEDS_INPUT"

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
      actionForLabels ["reviewed:revised"] `shouldBe` PullRequestRereview

    it "uses the opposite brand to review and the origin brand to revise" $ do
      agentForAction PullRequestCodex PullRequestReview `shouldBe` ClaudeSolver
      agentForAction PullRequestCodex PullRequestRevision `shouldBe` CodexSolver
      agentForAction PullRequestClaude PullRequestReview `shouldBe` CodexSolver
      agentForAction PullRequestClaude PullRequestRevision `shouldBe` ClaudeSolver

    it "pins canonical reviewer and reviser models" $ do
      pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing ResumeAnswer "" `shouldContain` ["--model", "claude-opus-4-8", "--effort", "xhigh"]
      pullRequestArguments 42 PullRequestCodex PullRequestRevision CodexSolver Nothing ResumeAnswer "" `shouldContain` ["--model", "gpt-5.4", "--config", "model_reasoning_effort=\"high\""]
      pullRequestArguments 42 PullRequestClaude PullRequestRevision ClaudeSolver Nothing ResumeAnswer "" `shouldContain` ["--model", "claude-sonnet-5", "--effort", "xhigh"]
      pullRequestArguments 42 PullRequestClaude PullRequestRereview CodexSolver Nothing ResumeAnswer "" `shouldContain` ["--model", "gpt-5.6-terra", "--config", "model_reasoning_effort=\"xhigh\""]

    it "routes r-key revisions through canonical pr-revise instead of the legacy manual-label prompt" $ do
      let codexOriginRevisionPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestRevision CodexSolver Nothing ResumeAnswer "")
          claudeOriginRevisionPrompt = last (pullRequestArguments 42 PullRequestClaude PullRequestRevision ClaudeSolver Nothing ResumeAnswer "")
      codexOriginRevisionPrompt `shouldContain` "$pr-revise"
      claudeOriginRevisionPrompt `shouldContain` "/pr-revise"
      codexOriginRevisionPrompt `shouldNotContain` "pr-review:v1"
      claudeOriginRevisionPrompt `shouldNotContain` "pr-review:v1"
      codexOriginRevisionPrompt `shouldNotContain` "create reviewed:revised"
      codexOriginRevisionPrompt `shouldContain` "leave reviewed:approve, reviewed:changes, and reviewed:revised to the canonical review coordinator"

    it "never asks the initial review prompt to remove a label only rereview can see, but keeps that instruction in rereview" $ do
      let initialReviewPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing ResumeAnswer "")
          rereviewPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestRereview ClaudeSolver Nothing ResumeAnswer "")
      initialReviewPrompt `shouldNotContain` "reviewed:revised"
      rereviewPrompt `shouldContain` "Remove reviewed:revised after successfully publishing the verdict"

    it "frames a resumed PR prompt with the true provenance of the resumed message instead of always claiming a user answer" $ do
      let answerPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver (Just "session-1") ResumeAnswer "looks good")
          interruptPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver (Just "session-1") ResumeInterruptGuidance "check the other file too")
      answerPrompt `shouldContain` Data.Text.unpack (resumeProvenanceHeader ResumeAnswer)
      answerPrompt `shouldContain` "KANBAN_NEEDS_INPUT"
      interruptPrompt `shouldContain` Data.Text.unpack (resumeProvenanceHeader ResumeInterruptGuidance)
      interruptPrompt `shouldNotContain` "The user answered"
      interruptPrompt `shouldContain` "KANBAN_NEEDS_INPUT"

    it "derives a pure post-revision verdict from current labels instead of waiting on a reviewed:revised handoff" $ do
      pullRequestVerdictForLabels [] `shouldBe` PullRequestVerdictPending
      pullRequestVerdictForLabels ["reviewed:revised"] `shouldBe` PullRequestVerdictPending
      pullRequestVerdictForLabels ["reviewed:approve"] `shouldBe` PullRequestVerdictApproved
      pullRequestVerdictForLabels ["reviewed:changes"] `shouldBe` PullRequestVerdictChangesRequested

    it "starts a fresh r-key revision round instead of reopening a finished one when the PR changed since it launched" $ do
      let launchedAt = UTCTime (fromGregorian 2026 7 18) 0
          unchanged = launchedAt
          afterFreshVerdict = UTCTime (fromGregorian 2026 7 19) 0
      -- A finished PullRequestRevision session addressing the same unchanged
      -- state (no new push, comment, or label change) is safely reused.
      pullRequestSessionReusable False False PullRequestRevision PullRequestRevision launchedAt unchanged `shouldBe` True
      -- pr-revise's own canonical rereview lands a fresh reviewed:changes
      -- verdict, so the recomputed action repeats (PullRequestRevision) but
      -- the PR has changed since this session launched: it must not reuse
      -- the finished session and instead start another canonical round.
      pullRequestSessionReusable False False PullRequestRevision PullRequestRevision launchedAt afterFreshVerdict `shouldBe` False
      -- A still-active session is always reused regardless of PR changes.
      pullRequestSessionReusable False True PullRequestRevision PullRequestRevision launchedAt afterFreshVerdict `shouldBe` True
      -- forceFresh always starts a new session.
      pullRequestSessionReusable True False PullRequestRevision PullRequestRevision launchedAt unchanged `shouldBe` False

  describe "review overlay digit dispatch" $ do
    let requestId = ReviewRequestId (String "req-1")
        choices = [ReviewChoice "keep" "Keep compatibility" "Preserve callers", ReviewChoice "break" "Break compatibility" ""]
        textQuestion allowOther =
          ReviewQuestion
            { reviewQuestionId = "scope",
              reviewQuestionHeader = "SCOPE",
              reviewQuestionText = "How many retries?",
              reviewQuestionKind = QuestionText,
              reviewQuestionChoices = [],
              reviewQuestionAllowOther = allowOther,
              reviewQuestionMultiple = False
            }
        choiceQuestion allowOther =
          ReviewQuestion
            { reviewQuestionId = "scope",
              reviewQuestionHeader = "SCOPE",
              reviewQuestionText = "Which contract?",
              reviewQuestionKind = QuestionChoice,
              reviewQuestionChoices = choices,
              reviewQuestionAllowOther = allowOther,
              reviewQuestionMultiple = False
            }
        approval = ReviewApproval Nothing Nothing False

    it "appends free-text digits instead of treating them as choice selections" $ do
      -- A QuestionText pending interaction must take precedence over any
      -- choices/allowOther it happens to carry (issue #3 spec addition).
      resolveReviewDigitAction (Just (PendingReviewQuestion requestId (textQuestion False))) 2 `shouldBe` ReviewDigitAppend
      resolveReviewDigitAction (Just (PendingReviewQuestion requestId (textQuestion True))) 8 `shouldBe` ReviewDigitAppend

    it "selects an in-range choice by its 1-based digit" $ do
      resolveReviewDigitAction (Just (PendingReviewQuestion requestId (choiceQuestion False))) 0
        `shouldBe` ReviewDigitSelectChoice requestId (ReviewChoice "keep" "Keep compatibility" "Preserve callers")
      resolveReviewDigitAction (Just (PendingReviewQuestion requestId (choiceQuestion False))) 1
        `shouldBe` ReviewDigitSelectChoice requestId (ReviewChoice "break" "Break compatibility" "")

    it "appends an out-of-range choice digit when free text is also accepted" $
      resolveReviewDigitAction (Just (PendingReviewQuestion requestId (choiceQuestion True))) 5 `shouldBe` ReviewDigitAppend

    it "reports an out-of-range choice digit unavailable when free text is not accepted" $
      resolveReviewDigitAction (Just (PendingReviewQuestion requestId (choiceQuestion False))) 5
        `shouldBe` ReviewDigitUnavailable "That review choice is not available"

    it "keeps approval digit handling exactly as before" $ do
      resolveReviewDigitAction (Just (PendingReviewApproval requestId approval)) 0 `shouldBe` ReviewDigitApprovalOnce requestId
      resolveReviewDigitAction (Just (PendingReviewApproval requestId approval)) 1 `shouldBe` ReviewDigitApprovalSession requestId
      resolveReviewDigitAction (Just (PendingReviewApproval requestId approval)) 2 `shouldBe` ReviewDigitApprovalDecline requestId
      resolveReviewDigitAction (Just (PendingReviewApproval requestId approval)) 5
        `shouldBe` ReviewDigitUnavailable "That approval choice is not available"

    it "appends digits when nothing is pending" $
      resolveReviewDigitAction Nothing 4 `shouldBe` ReviewDigitAppend

  describe "review overlay Ctrl-C cancel dispatch" $ do
    -- issue #31: canonical review stages (InitialReview/IssueRereview) have
    -- no app-server thread/turn, so the pre-existing app-server-only
    -- dispatch reported "no active turn to cancel" even while their
    -- ManagedProcess was still running. 'resolveReviewCancelAction' is the
    -- pure routing extracted from 'cancelReviewSession' so each branch is
    -- unconditionally covered without an 'EventM' harness.
    it "routes a ready app-server turn to the interrupt-turn action, unchanged" $ do
      resolveReviewCancelAction True (Just "thread-1") (Just "turn-1") IssueRevision ReviewRunning False
        `shouldBe` ReviewCancelInterruptTurn "thread-1" "turn-1"
      resolveReviewCancelAction False Nothing Nothing IssueRevision ReviewStarting False
        `shouldBe` ReviewCancelNoActiveTurn

    it "routes a live canonical process to the interrupt-process action" $ do
      resolveReviewCancelAction False Nothing Nothing InitialReview ReviewRunning True
        `shouldBe` ReviewCancelInterruptProcess
      resolveReviewCancelAction False Nothing Nothing IssueRereview ReviewRunning True
        `shouldBe` ReviewCancelInterruptProcess

    it "gives a truthful notice for a canonical stage with no live process" $ do
      resolveReviewCancelAction False Nothing Nothing InitialReview ReviewFinished False
        `shouldBe` ReviewCancelNotRunning
      resolveReviewCancelAction False Nothing Nothing InitialReview ReviewInterrupted False
        `shouldBe` ReviewCancelNotRunning
      resolveReviewCancelAction False Nothing Nothing InitialReview ReviewStarting False
        `shouldBe` ReviewCancelStillStarting

  describe "canonical review completion vs. cancellation" $ do
    -- issue #31 spec addition: a canonical process's completion event can
    -- arrive after the user already Ctrl-C'd the session; that late
    -- completion must not overwrite the ReviewInterrupted terminal phase.
    it "supersedes a late completion only once the session has been interrupted" $ do
      canonicalReviewCompletionSuperseded ReviewInterrupted `shouldBe` True
      mapM_
        (\phase -> canonicalReviewCompletionSuperseded phase `shouldBe` False)
        [ReviewStarting, ReviewRunning, ReviewWaiting, ReviewFinished, ReviewNeedsChanges, ReviewFailed]

  describe "review session same-stage retry eligibility" $ do
    -- issue #31 spec addition: after a canonical stage is interrupted, 'r'
    -- must launch a fresh label-derived stage rather than reopen the
    -- cancelled session -- but only once the prior invocation's process has
    -- actually finished, so a fresh launch never races its still-pending
    -- completion event.
    it "reuses a live session regardless of stage" $ do
      mapM_
        (\phase -> reviewSessionReusable phase InitialReview InitialReview False `shouldBe` True)
        [ReviewStarting, ReviewRunning, ReviewWaiting]
      reviewSessionReusable ReviewRunning InitialReview IssueRereview False `shouldBe` True

    it "reuses a finished session whose recorded stage still matches what labels request" $
      reviewSessionReusable ReviewFinished InitialReview InitialReview False `shouldBe` True

    it "does not reuse a finished session once labels request a different stage" $
      reviewSessionReusable ReviewNeedsChanges InitialReview IssueRereview False `shouldBe` False

    it "forces a fresh launch for an interrupted canonical stage once its process is gone" $
      reviewSessionReusable ReviewInterrupted InitialReview InitialReview False `shouldBe` False

    it "keeps reusing an interrupted session while its kill is still in flight" $
      reviewSessionReusable ReviewInterrupted InitialReview InitialReview True `shouldBe` True

    it "reuses an interrupted app-server revision when its stage is unchanged" $
      reviewSessionReusable ReviewInterrupted IssueRevision IssueRevision False `shouldBe` True

  describe "issue-revision refresh reconciliation" $ do
    -- issue #72: a completed issue-revision that posted its amendment and
    -- landed `reviewed:revised` was still shown as a failed revision after
    -- the board refreshed, because reconcileReviewSessions only recovered
    -- reviewed:approve and reviewed:changes. A failed issue-revision session
    -- refreshed against a reviewed:revised issue must now surface as the
    -- purple "awaiting rereview" state instead.
    let failedRevisionSession issue =
          ReviewSession
            { reviewSessionIssue = issue,
              reviewSessionStage = IssueRevision,
              reviewSessionThreadId = Nothing,
              reviewSessionTurnId = Nothing,
              reviewSessionPhase = ReviewFailed,
              reviewSessionActivity = "failed",
              reviewSessionTranscript = ChatTranscript "" "" "",
              reviewSessionPending = Nothing,
              reviewSessionInput = "",
              reviewSessionSpinnerFrame = 0
            }
        reconciledPhaseFor issue session =
          (reconcileReviewSessions [issue] (Map.singleton issue.issueNumber session) Map.! issue.issueNumber).reviewSessionPhase

    it "reconciles a failed issue-revision session to the revised state once the issue carries reviewed:revised" $ do
      let issue = (baseIssue 59 []) {issueLabels = [Label "reviewed:revised" "8250DF"]}
          session = failedRevisionSession issue
      reconciledPhaseFor issue session `shouldBe` ReviewRevised

    it "presents the revised state with the purple attribute and awaiting-rereview text, not the failure presentation" $ do
      let phase = ReviewRevised
          failedSession = failedRevisionSession (baseIssue 59 [])
          revisedSession = failedSession {reviewSessionPhase = phase}
      reviewPhaseAttribute phase `shouldBe` revisedAttr
      reviewPhaseAttribute phase `shouldNotBe` reviewPhaseAttribute ReviewFailed
      Data.Text.unpack (reviewPhaseLabel revisedSession) `shouldNotContain` "failed"
      reviewPhaseGlyphFor False revisedSession `shouldNotBe` reviewPhaseGlyphFor False failedSession
      reviewPhaseGlyphFor True revisedSession `shouldNotBe` reviewPhaseGlyphFor True failedSession

    it "leaves a failed issue-revision session genuinely failed when reviewed:revised is absent" $ do
      let issue = baseIssue 59 []
          session = failedRevisionSession issue
      reconciledPhaseFor issue session `shouldBe` ReviewFailed
      reviewPhaseAttribute ReviewFailed `shouldBe` reviewPhaseAttribute (reconciledPhaseFor issue session)
      Data.Text.unpack (reviewPhaseLabel session {reviewSessionPhase = reconciledPhaseFor issue session}) `shouldContain` "failed"

    it "matches a mixed-case reviewed:revised label the same as the canonical casing" $ do
      let issue = (baseIssue 59 []) {issueLabels = [Label "ReViEwEd:ReViSeD" "8250DF"]}
          session = failedRevisionSession issue
      reconciledPhaseFor issue session `shouldBe` ReviewRevised

    it "does not let a stray reviewed:revised label mask a failed rereview session" $ do
      let issue = (baseIssue 59 []) {issueLabels = [Label "reviewed:revised" "8250DF"]}
          session = (failedRevisionSession issue) {reviewSessionStage = IssueRereview}
      reconciledPhaseFor issue session `shouldBe` ReviewFailed

    it "keeps reviewed:approve as top precedence over a coincident reviewed:revised label" $ do
      let issue = (baseIssue 59 []) {issueLabels = [Label "reviewed:approve" "0e8a16", Label "reviewed:revised" "8250DF"]}
          session = failedRevisionSession issue
      reconciledPhaseFor issue session `shouldBe` ReviewFinished

  describe "processes overlay selection resolution" $ do
    let sessionEntry ref =
          AgentSessionEntry
            { agentSessionRef = ref,
              agentSessionLabel = "label",
              agentSessionProvider = "provider",
              agentSessionStatus = "status",
              agentSessionActivity = "activity",
              agentSessionId = Nothing,
              agentSessionLive = True,
              agentSessionProblem = False
            }
        solve = sessionEntry . SolveAgent

    it "keeps the clamped entry as the target when the list shrinks past the selection" $ do
      let selection = ProcessSelection (Just (SolveAgent 5)) 4
          shrunk = [solve 1, solve 2]
      resolveProcessSelection shrunk selection `shouldBe` ProcessSelection (Just (SolveAgent 2)) 1

    it "follows the selected identity across a reorder instead of the row" $ do
      let selection = ProcessSelection (Just (SolveAgent 2)) 1
          reordered = [solve 2, solve 1, solve 3]
      resolveProcessSelection reordered selection `shouldBe` ProcessSelection (Just (SolveAgent 2)) 0

    it "falls back to the nearest remaining row when the selected session disappears" $ do
      let selection = ProcessSelection (Just (WorkerAgent (WorkerId "w1"))) 2
          remaining = [solve 1, solve 2]
      resolveProcessSelection remaining selection `shouldBe` ProcessSelection (Just (SolveAgent 2)) 1

    it "resolves to no selection when no sessions remain" $
      resolveProcessSelection [] (ProcessSelection (Just (SolveAgent 1)) 0) `shouldBe` ProcessSelection Nothing 0

    it "adopts the fallback entry as canonical so a later reorder follows it, not the vanished identity" $ do
      let selection = ProcessSelection (Just (WorkerAgent (WorkerId "w1"))) 2
          afterDisappearance = [solve 1, solve 2, solve 3]
          afterReorder = [solve 3, solve 2, solve 1]
          resolvedOnce = resolveProcessSelection afterDisappearance selection
          resolvedTwice = resolveProcessSelection afterReorder resolvedOnce
      resolvedOnce `shouldBe` ProcessSelection (Just (SolveAgent 3)) 2
      resolvedTwice `shouldBe` ProcessSelection (Just (SolveAgent 3)) 0

    it "resolves a click by the identity rendered at that row, not the row itself, across a pre-dispatch reorder" $ do
      let selection = ProcessSelection (Just (SolveAgent 1)) 0
          reorderedBeforeDispatch = [solve 3, solve 1, solve 2]
      resolveProcessClick reorderedBeforeDispatch selection (SolveAgent 2)
        `shouldBe` ProcessClickSelect (ProcessSelection (Just (SolveAgent 2)) 2)
      resolveProcessClick reorderedBeforeDispatch selection (SolveAgent 1)
        `shouldBe` ProcessClickOpen
      resolveProcessClick [solve 1, solve 2] selection (SolveAgent 9)
        `shouldBe` ProcessClickIgnored

  describe "overlay mouse dispatch" $ do
    let backgroundCard = CardTarget Issues 0
        zeroLoc = Location (0, 0)
        rawWheel button = VtyEvent (Vty.EvMouseDown 0 0 button [])
        overlays =
          [ ("review overlay", ReviewPanel, ReviewViewport),
            ("solve overlay", SolvePanel, SolveViewport),
            ("pull request review overlay", PullRequestReviewPanel, PullRequestReviewViewport),
            ("details overlay", DetailsPanel, DetailsViewport)
          ]

    mapM_
      ( \(label, panel, viewport) -> describe label $ do
          it "scrolls, without closing, when the wheel lands on a background clickable" $ do
            overlayMouseAction panel (MouseDown backgroundCard Vty.BScrollUp [] zeroLoc) `shouldBe` Just (OverlayMouseScroll (-3))
            overlayMouseAction panel (MouseDown backgroundCard Vty.BScrollDown [] zeroLoc) `shouldBe` Just (OverlayMouseScroll 3)

          it "scrolls on a raw Vty wheel event that carries no Brick name at all" $ do
            overlayMouseAction panel (rawWheel Vty.BScrollUp) `shouldBe` Just (OverlayMouseScroll (-3))
            overlayMouseAction panel (rawWheel Vty.BScrollDown) `shouldBe` Just (OverlayMouseScroll 3)

          it "scrolls when the wheel lands on the overlay's own viewport or panel" $ do
            overlayMouseAction panel (MouseDown viewport Vty.BScrollUp [] zeroLoc) `shouldBe` Just (OverlayMouseScroll (-3))
            overlayMouseAction panel (MouseDown viewport Vty.BScrollDown [] zeroLoc) `shouldBe` Just (OverlayMouseScroll 3)
            overlayMouseAction panel (MouseDown panel Vty.BScrollUp [] zeroLoc) `shouldBe` Just (OverlayMouseScroll (-3))
            overlayMouseAction panel (MouseDown panel Vty.BScrollDown [] zeroLoc) `shouldBe` Just (OverlayMouseScroll 3)

          it "closes on an outside click, left or right, named or raw" $ do
            overlayMouseAction panel (MouseDown backgroundCard Vty.BLeft [] zeroLoc) `shouldBe` Just OverlayMouseClose
            overlayMouseAction panel (MouseDown backgroundCard Vty.BRight [] zeroLoc) `shouldBe` Just OverlayMouseClose
            overlayMouseAction panel (rawWheel Vty.BLeft) `shouldBe` Just OverlayMouseClose

          it "closes the panel on a right click but leaves a left click on the panel inert" $ do
            overlayMouseAction panel (MouseDown panel Vty.BRight [] zeroLoc) `shouldBe` Just OverlayMouseClose
            overlayMouseAction panel (MouseDown panel Vty.BLeft [] zeroLoc) `shouldBe` Just OverlayMouseNoOp
       )
       overlays

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

    it "makes a dirty checkout an error that prevents starting the drainer" $
      decodeDrainerStatus "{\"state\":\"dirty\",\"open_incident\":null}"
        `shouldBe` Right (DrainerStatus DrainerError "uncommitted changes; drainer will not start")

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

withoutEnvironmentValue :: String -> IO result -> IO result
withoutEnvironmentValue name action =
  bracket
    (do previous <- lookupEnv name; unsetEnv name; pure previous)
    (maybe (pure ()) (setEnv name))
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

-- | A shell command that spawns a TERM-resistant child detached into its
-- *own* process group (via Python's 'os.setpgrp' preexec hook) -- distinct
-- from the outer, registered process's own group -- and writes that
-- child's pid to the given file so a test can find and independently clean
-- it up without depending on 'killManagedProcess'/'killVerifiedGroupWith'.
detachedEscapedDescendantCommand :: FilePath -> String
detachedEscapedDescendantCommand pidFile =
  "python3 -c '"
    <> unlines
      [ "import os,subprocess,sys,time",
        "child = subprocess.Popen([\"sh\",\"-c\",\"trap \\\"\\\" TERM; while :; do sleep 1; done\"],preexec_fn=os.setpgrp)",
        "open(sys.argv[1],\"w\").write(str(child.pid))",
        "sys.stdout.flush()",
        "time.sleep(10)"
      ]
    <> "' "
    <> pidFile

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

workerFixtureSpec :: Repository -> WorkerId -> Int -> WorkerSpec
workerFixtureSpec repository identifier issueNumber =
  WorkerSpec
    { workerId = identifier,
      workerRepository = repository,
      workerTask = SolveWorkerTaskKind (SolveWorkerTask issueNumber SolveOnly CodexSolver),
      workerExistingSession = Nothing,
      workerExistingLogPath = Nothing,
      workerResumeProvenance = ResumeAnswer,
      workerUserMessage = "",
      workerParent = Nothing,
      workerCreatedAt = epoch,
      workerMaxRuntimeSeconds = 60
    }

-- | Like 'workerFixtureSpec', but with an explicit 'workerCreatedAt' and
-- 'workerMaxRuntimeSeconds' so a deadline test can construct a precise,
-- deterministic firing time.
deadlineFixtureSpec :: Repository -> WorkerId -> Int -> UTCTime -> Int -> WorkerSpec
deadlineFixtureSpec repository identifier issueNumber createdAt maxRuntimeSeconds =
  (workerFixtureSpec repository identifier issueNumber)
    { workerCreatedAt = createdAt,
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
