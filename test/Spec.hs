module Main (main) where

import Brick (AttrMap, BrickEvent (..), Location (..), Widget, hLimit)
import Brick.Main (renderWidget)
import Control.Concurrent (forkIO, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar, threadDelay)
import Control.Exception (IOException, SomeException, bracket, finally, throwIO, throwTo, try, uninterruptibleMask_)
import Control.Monad (void, when)
import Data.Aeson (Value (..), eitherDecode, encode, object, (.=))
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.IORef (atomicModifyIORef', modifyIORef, newIORef, readIORef, writeIORef)
import Data.List (dropWhileEnd, find, findIndex, intercalate, isInfixOf, isPrefixOf, nub, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text
import qualified Data.Text.Lazy as LazyText
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, getCurrentTime, minutesToTimeZone, secondsToDiffTime, utc)
import qualified Data.Vector as Vector
import qualified Graphics.Vty as Vty
import Graphics.Vty.PictureToSpans (displayOpsForPic)
import Graphics.Vty.Span (SpanOp (..))
import Kanban.Cache
  ( CacheLoad (..),
    UsageCacheLoad (..),
    loadRepositoryCache,
    loadUsageCache,
    repositoryCachePath,
    repositoryCacheSchemaVersion,
    writeRepositoryCache,
    writeUsageCache,
  )
import Kanban.CLI (BorderPolicy (..), ColorPolicy (..), Options (..))
import Kanban.Card (CardChip (..), boundedLines, displayWidth, labelChipRows)
import Kanban.Claude (decodeClaudeUsageText)
import Kanban.Codex (decodeCodexUsageResponse)
import Kanban.Config
import Kanban.Domain
import Kanban.Drainer (DrainerController (..), DrainerState (..), DrainerStatus (..), controllerFromProgramArguments, decodeDrainerStatus, drainerIsRunning)
import Kanban.GitHub (FetchState (..), decodeGitHubItems, graphqlArguments, paginationDecision, snapshotWarnings)
import Kanban.Layout (responsiveColumnWidths, responsiveOpenColumnWidths)
import Kanban.Preflight
  ( AuthObservation (..),
    BundleObservation (..),
    GitHubObservation (..),
    IssueOrigin (..),
    PreflightAction (..),
    PreflightCheck (..),
    PreflightEnvironment (..),
    PreflightProblem (..),
    PreflightReport (..),
    PreflightStatus (..),
    ProviderProbe (..),
    ReviewBackendObservation (..),
    VersionObservation (..),
    actionLabel,
    actionReport,
    blockingRemediation,
    canonicalReviewBrands,
    classifyBundleListing,
    classifyClaudeAuth,
    classifyCodexAuth,
    classifyVersion,
    doctorActions,
    doctorLines,
    doctorReady,
    gatherPreflightEnvironment,
    issueOriginFromBody,
    minimumClaudeVersion,
    minimumCodexVersion,
    preflightDiagnostic,
    preflightDiagnosticDetail,
    revisionAuthorBrand,
  )
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
import Kanban.Repository (parseRemoteRepository, parseRepositoryName, resolveRepository)
import Kanban.PullRequestFlow
  ( PullRequestAction (..),
    PullRequestFlowEvent (..),
    PullRequestOrigin (..),
    PullRequestVerdict (..),
    actionForLabels,
    agentForAction,
    flowOutcome,
    originFromBody,
    pullRequestArguments,
    pullRequestVerdictForLabels,
    runPullRequestFlow,
    runPullRequestFlowWith,
  )
import Kanban.Review
  ( CanonicalIssueReviewResult (..),
    CommandBounds (..),
    GitHubIssueOperation (..),
    GitHubIssueToolRequest (..),
    ReviewClient,
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
    attachToolProcess,
    canonicalIssueReviewArguments,
    canonicalIssueReviewerPath,
    drainToolRegistry,
    githubIssueCommentArguments,
    githubIssueEditArguments,
    githubIssueViewArguments,
    githubLabelCreateArguments,
    killThreadToolProcesses,
    newReviewClientForTesting,
    newToolRegistry,
    releaseToolSlot,
    reserveToolSlot,
    resolveCanonicalIssueReviewer,
    githubCommandBounds,
    reviewStageForLabels,
    runCanonicalCommand,
    runGitHubIssueTool,
    stopReviewClient,
    renderCanonicalIssueReviewResult,
    renderReviewResult,
    withReservedToolSlot,
  )
import Kanban.Solve
  ( AgentEvent (..),
    ResumeProvenance (..),
    SolveEvent (..),
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
    runSolve,
    runSolveWith,
    solveArguments,
    solveOutcome,
  )
import Kanban.Settings (ChatVerbosity (..), Settings (..), defaultSettings, loadSettings, saveSettings)
import Kanban.StreamReader
  ( StreamOutcome (..),
    handleReadLine,
    maxConsecutiveReadFailures,
    onStreamAbandoned,
    runStreamReader,
    runStreamReaderWith,
  )
import Kanban.Text (excerpt, sanitizeText)
import Kanban.Transcript (closeSessionLog, logRawLine, openSessionLog, sessionLogPath)
import Kanban.Tracker (implementationSortKey, parseTrackerBody, parseTrackerChildren, renderTrackerDiagnostic)
import Kanban.UI
  ( AgentSessionEntry (..),
    AgentSessionRef (..),
    CardEnv (..),
    ChatTranscript (..),
    DetailsEnv (..),
    Name (..),
    Overlay (..),
    OverlayMouseAction (..),
    PendingReviewInteraction (..),
    ProcessClickOutcome (..),
    ProcessSelection (..),
    PullRequestReviewSession (..),
    ReviewCancelAction (..),
    ReviewDigitAction (..),
    ReviewPhase (..),
    ReviewSession (..),
    ReviewTickArmOutcome (..),
    ReviewTickFireOutcome (..),
    SolvePhase (..),
    SolveSession (..),
    agentFailureNotice,
    canonicalReviewActivity,
    TranscriptGeometry (..),
    TranscriptSession (..),
    canonicalReviewCompletionSuperseded,
    canonicalReviewNotice,
    decideReviewTickArm,
    decideReviewTickFire,
    displayedTranscript,
    failureActivity,
    followAfterScroll,
    followAfterTurnStarted,
    killSelectionNotice,
    orphanMessage,
    overlayMouseAction,
    pullRequestSessionAlreadyResolved,
    pullRequestSessionReusable,
    approvedAttr,
    approvedInteriorAttr,
    autoSolveRevisionPrompt,
    cacheEnabled,
    cardExcerptLimit,
    cardInteriorAttribute,
    claudeRefreshTimeoutMicros,
    codexRefreshTimeoutMicros,
    drawCardFrame,
    drawDetails,
    githubRefreshTimeoutMicros,
    mergeExplanation,
    mergeText,
    neutralAttr,
    normalizeCollapsedRow,
    normalizeSelectedRowsAfterToggle,
    pendingAttr,
    problemAttr,
    pullRequestCardAttribute,
    readyAttr,
    reconcileReviewSessions,
    refreshOverlay,
    resolveReviewCancelAction,
    resolveProcessClick,
    resolveProcessSelection,
    resolveReviewDigitAction,
    reviewPhaseAttribute,
    reviewPhaseGlyphFor,
    reviewPhaseLabel,
    reviewSessionReusable,
    reviewSessionsNeedingArm,
    revisedAttr,
    solveSessionAlreadyResolved,
    themeFor,
    trackerAttr,
    trackerHeaderAttribute,
    transcriptScrollKey,
    transcriptShouldTail,
    visibleSelectionRows,
  )
import Kanban.Workflow (CardStatus (..), deriveBoard, entryItem, isProblem, orderCardLabels, pullRequestStatus)
import Kanban.Worker
  ( ProviderSlot (..),
    PullRequestWorkerTask (..),
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
    consumeJournalLines,
    discoverWorkerHistory,
    monitorWorker,
    recordLaunchedSupervisorIdentity,
    recoverIfWorkerStoppedWith,
    releaseWorkerLease,
    runWorker,
    runWorkerWith,
    runWorkerWithTask,
    spawnDetachedSupervisor,
    terminateProviderRefWith,
    terminateRecordedStateProcessesWith,
    terminateWorkerWith,
    waitForOrphanResolution,
    waitForWorkerStart,
    workerDeadlineReason,
  )
import System.Directory (createDirectory, createDirectoryIfMissing, createFileLink, doesDirectoryExist, doesFileExist, getTemporaryDirectory, listDirectory, removeFile, removePathForcibly, setModificationTime)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, takeDirectory, (</>))
import System.IO (hClose, openTempFile)
import System.Posix.Files (setFileMode)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (raiseSignal, sigKILL, sigTERM, signalProcess, signalProcessGroup)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (CreatePipe), createProcess, getPid, getProcessExitCode, proc, readProcessWithExitCode, waitForProcess)
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

    it "still reaches a surviving group member after its own leader has already exited and been reaped (issue #16: the review client's tool calls and its own app-server shutdown share this primitive)" $
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
          Right identities -> identityForPid childPid identities `shouldBe` Nothing

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
                workerMaxRuntimeSeconds = 14400,
                workerConfigPath = Nothing,
                workerWorkflowConfig = defaultWorkflowConfig
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
                  workerMaxRuntimeSeconds = 60,
                  workerConfigPath = Nothing,
                  workerWorkflowConfig = defaultWorkflowConfig
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
                registerThenReturn _spec rememberProvider _emit = rememberProvider managed
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

  describe "review tool process ownership" $ do
    it "keeps two overlapping same-thread invocations independently killable" $
      withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \processA ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \processB -> do
          registry <- newToolRegistry
          keyA <- requireJust "expected a reservation for invocation A" =<< reserveToolSlot registry "thread-1"
          keyB <- requireJust "expected a reservation for invocation B" =<< reserveToolSlot registry "thread-1"
          managedA <- managedProcessFor processA
          managedB <- managedProcessFor processB
          -- Under the old threadId-keyed map, the second `insert` here would
          -- have overwritten the first entry, leaving invocation A unkillable.
          attachToolProcess registry keyA managedA `shouldReturn` True
          attachToolProcess registry keyB managedB `shouldReturn` True
          killThreadToolProcesses registry "thread-1"
          timeout 3000000 (waitForProcess processA) `shouldReturn` Just (ExitFailure (-9))
          timeout 3000000 (waitForProcess processB) `shouldReturn` Just (ExitFailure (-9))

    it "leaves a same-thread sibling registered once one overlapping invocation completes" $
      withManagedShell "true" $ \quickProcess ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \longProcess -> do
          registry <- newToolRegistry
          keyA <- requireJust "expected a reservation for the quick invocation" =<< reserveToolSlot registry "thread-1"
          keyB <- requireJust "expected a reservation for the long invocation" =<< reserveToolSlot registry "thread-1"
          quickManaged <- managedProcessFor quickProcess
          longManaged <- managedProcessFor longProcess
          attachToolProcess registry keyA quickManaged `shouldReturn` True
          attachToolProcess registry keyB longManaged `shouldReturn` True
          -- Invocation A completes naturally and deregisters itself, exactly
          -- as 'runAuthenticatedClaude'/'runGitHubCommand' do after success --
          -- under the old threadId-keyed map this `delete` would have
          -- untracked invocation B too.
          timeout 3000000 (waitForProcess quickProcess) `shouldReturn` Just ExitSuccess
          releaseToolSlot registry keyA
          remaining <- drainToolRegistry registry
          length remaining `shouldBe` 1
          mapM_ killManagedProcess remaining
          timeout 3000000 (waitForProcess longProcess) `shouldReturn` Just (ExitFailure (-9))

    it "kills every invocation owned by a thread without disturbing another thread's entry" $
      withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \processA ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \processB ->
          withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \otherThreadProcess -> do
            registry <- newToolRegistry
            keyA <- requireJust "expected a reservation for thread-1's first invocation" =<< reserveToolSlot registry "thread-1"
            keyB <- requireJust "expected a reservation for thread-1's second invocation" =<< reserveToolSlot registry "thread-1"
            otherKey <- requireJust "expected a reservation for thread-2" =<< reserveToolSlot registry "thread-2"
            managedA <- managedProcessFor processA
            managedB <- managedProcessFor processB
            otherManaged <- managedProcessFor otherThreadProcess
            attachToolProcess registry keyA managedA `shouldReturn` True
            attachToolProcess registry keyB managedB `shouldReturn` True
            attachToolProcess registry otherKey otherManaged `shouldReturn` True
            killThreadToolProcesses registry "thread-1"
            timeout 3000000 (waitForProcess processA) `shouldReturn` Just (ExitFailure (-9))
            timeout 3000000 (waitForProcess processB) `shouldReturn` Just (ExitFailure (-9))
            getProcessExitCode otherThreadProcess `shouldReturn` Nothing
            remaining <- drainToolRegistry registry
            length remaining `shouldBe` 1

    it "never lets a spawn that races full client shutdown escape the shutdown drain" $
      withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \process -> do
        registry <- newToolRegistry
        key <- requireJust "expected a reservation before shutdown begins" =<< reserveToolSlot registry "thread-1"
        -- Shutdown begins (and finds nothing to drain yet, since the process
        -- has not spawned/attached) while the reservation is still pending.
        drained <- drainToolRegistry registry
        length drained `shouldBe` 0
        managed <- managedProcessFor process
        -- The spawn that raced shutdown discovers its reservation is gone
        -- and must kill what it just started itself.
        attachToolProcess registry key managed `shouldReturn` False
        killManagedProcess managed
        timeout 3000000 (waitForProcess process) `shouldReturn` Just (ExitFailure (-9))
        -- The registry stays closed: no later invocation can register either.
        reserveToolSlot registry "thread-1" `shouldReturn` Nothing

    it "never lets a spawn that races same-thread cancellation escape, while leaving the registry open for later work" $
      withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \process -> do
        registry <- newToolRegistry
        key <- requireJust "expected a reservation before the cancellation lands" =<< reserveToolSlot registry "thread-1"
        killThreadToolProcesses registry "thread-1"
        managed <- managedProcessFor process
        attachToolProcess registry key managed `shouldReturn` False
        killManagedProcess managed
        timeout 3000000 (waitForProcess process) `shouldReturn` Just (ExitFailure (-9))
        -- Unlike full shutdown, a per-thread cancellation does not close the
        -- registry: later work on the same thread still registers normally.
        laterReservation <- reserveToolSlot registry "thread-1"
        laterReservation `shouldSatisfy` isJust

    it "still fences a same-thread cancellation landing between the sequential gh subprocesses of one GitHub update" $
      withManagedShell "true" $ \firstProcess ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \secondProcess -> do
          registry <- newToolRegistry
          -- One reservation spans the *whole* multi-step GitHub update, the
          -- same way 'withReservedToolSlot' holds a single key across every
          -- subprocess of 'runGitHubIssueUpdate' (e.g. the issue comment,
          -- then the label edit) -- not one reservation per subprocess.
          key <- requireJust "expected a reservation for the whole update" =<< reserveToolSlot registry "thread-1"
          -- Subprocess 1 (e.g. the issue comment) runs to completion
          -- normally and its leader is swept, but the reservation itself is
          -- not released yet, since more subprocesses may still follow.
          managedOne <- managedProcessFor firstProcess
          attachToolProcess registry key managedOne `shouldReturn` True
          timeout 3000000 (waitForProcess firstProcess) `shouldReturn` Just ExitSuccess
          killManagedProcess managedOne
          -- A same-thread cancellation lands in the gap before subprocess 2
          -- (e.g. the label edit) ever spawns.
          killThreadToolProcesses registry "thread-1"
          -- Subprocess 2 reuses that very same reservation key and finds it
          -- already drained, so it must kill what it just spawned itself
          -- instead of running as though the cancellation never happened.
          managedTwo <- managedProcessFor secondProcess
          attachToolProcess registry key managedTwo `shouldReturn` False
          killManagedProcess managedTwo
          timeout 3000000 (waitForProcess secondProcess) `shouldReturn` Just (ExitFailure (-9))

    it "terminates a fake gh invocation that is still in flight when the client shuts down" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeGh = binaryRoot </> "gh"
            markerPath = temporaryRoot </> "gh-started"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        ByteString.writeFile
          fakeGh
          ( ByteString.unlines
              [ "#!/bin/sh",
                "touch \"$STARTED_MARKER\"",
                "trap '' TERM",
                "while :; do sleep 1; done"
              ]
          )
        setFileMode fakeGh 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $
          withEnvironmentValue "STARTED_MARKER" markerPath $ do
            client <- newReviewClientForTesting githubCommandBounds repositoryRoot "coghex/kanban" (const (pure ()))
            finished <- newEmptyMVar
            let request = GitHubIssueToolRequest GitHubIssueRead 844 Nothing [] []
            void . forkIO $ withReservedToolSlot client "thread-1" (\key -> runGitHubIssueTool client key request) >>= putMVar finished
            waitForFileToExist markerPath 50
            stopReviewClient client
            result <- timeout 5000000 (takeMVar finished)
            case result of
              Just (Left _) -> pure ()
              other -> expectationFailure ("expected the in-flight gh call to fail once the client shut down, got " <> show other)

  describe "review subprocess deadline and capture bounds" $ do
    let injectedBounds = CommandBounds {commandDeadlineMicros = 400000, commandCaptureGraceMicros = 400000}
        -- Every call below runs under this bound. It is generous next to
        -- what these calls actually cost -- the injected deadline plus the
        -- injected capture grace plus 'killManagedProcess'' own 750 ms
        -- termination grace, twice over for the two-subprocess updates --
        -- so a loaded CI runner cannot trip it. What matters is that it
        -- stays far under the 30 s the pipe-holding children in these
        -- fixtures live for: a runner that still waited on a capture worker
        -- it cannot unblock would hang until then, and so trips this bound
        -- instead of quietly passing once the child finally exits.
        boundedCallMicros = 10000000
        commentUrl = "https://example.invalid/coghex/kanban/issues/15#issuecomment-7"
        postComment = "printf '%s\\n' '" <> ByteString.pack (Data.Text.unpack commentUrl) <> "'"

    it "round-trips an ordinary fast gh read unchanged" $
      withFakeGitHubCli ["printf '%s' '{\"number\":15}'"] injectedBounds $ \client -> do
        result <- runBoundedGitHubTool boundedCallMicros client (GitHubIssueToolRequest GitHubIssueRead 15 Nothing [] [])
        result `shouldBe` Right "{\"number\":15}"

    it "reports a mutation whose stdout a forked child holds open past the deadline as outcome-unknown, never as a timeout" $
      withFakeGitHubCli ["sleep 30 &", postComment, "exit 0"] injectedBounds $ \client -> do
        result <- runBoundedGitHubTool boundedCallMicros client (GitHubIssueToolRequest GitHubIssueUpdate 15 (Just "body") [] [])
        message <- requireLeft "expected the truncated comment post to be reported as outcome-unknown" result
        message `shouldMention` "outcome is unknown"
        message `shouldMention` "may already have completed"
        message `shouldMention` "posting the issue comment"
        message `shouldMention` "with this tool"
        message `shouldNotMention` "timed out"

    it "still succeeds when only stderr is held open past the deadline and stdout arrived complete" $
      withFakeGitHubCli ["sleep 30 >/dev/null &", postComment, "exit 0"] injectedBounds $ \client -> do
        result <- runBoundedGitHubTool boundedCallMicros client (GitHubIssueToolRequest GitHubIssueUpdate 15 (Just "body") [] [])
        output <- requireRight "expected a clean exit with complete stdout to succeed despite unfinished stderr capture" result
        output `shouldMention` commentUrl

    it "keeps an observed nonzero exit a nonzero-exit failure even when capture is still held open" $
      withFakeGitHubCli ["sleep 30 &", "printf 'boom\\n' >&2", "exit 3"] injectedBounds $ \client -> do
        result <- runBoundedGitHubTool boundedCallMicros client (GitHubIssueToolRequest GitHubIssueRead 15 Nothing [] [])
        message <- requireLeft "expected a nonzero exit to stay a nonzero-exit failure" result
        message `shouldMention` "exited with status 3"
        message `shouldNotMention` "outcome is unknown"

    it "tells the model to verify current state before retrying when a comment post outlives the deadline" $
      withFakeGitHubCli ["sleep 30"] injectedBounds $ \client -> do
        result <- runBoundedGitHubTool boundedCallMicros client (GitHubIssueToolRequest GitHubIssueUpdate 15 (Just "body") [] [])
        message <- requireLeft "expected an unfinished comment post to be reported as outcome-unknown" result
        message `shouldMention` "did not exit within"
        message `shouldMention` "outcome is unknown"
        message `shouldMention` "Re-read the issue and its labels with this tool"

    it "leaves an ordinary read unaffected, reporting a plain failure with no verify-before-retry instruction" $
      withFakeGitHubCli ["sleep 30"] injectedBounds $ \client -> do
        result <- runBoundedGitHubTool boundedCallMicros client (GitHubIssueToolRequest GitHubIssueRead 15 Nothing [] [])
        message <- requireLeft "expected an unfinished read to fail" result
        message `shouldMention` "reading issue #15"
        message `shouldNotMention` "with this tool"
        message `shouldNotMention` "may already have completed"

    it "preserves a known-successful comment when the following label edit's outcome is unknown, without calling it failed" $
      withFakeGitHubCli
        [ "if [ \"$1\" = \"issue\" ] && [ \"$2\" = \"comment\" ]; then",
          postComment,
          "exit 0",
          "fi",
          "sleep 30"
        ]
        injectedBounds
        $ \client -> do
          result <- runBoundedGitHubTool boundedCallMicros client (GitHubIssueToolRequest GitHubIssueUpdate 15 (Just "body") ["reviewed:approve"] ["reviewed:changes"])
          message <- requireLeft "expected the unfinished label edit to be reported as outcome-unknown" result
          message `shouldMention` ("The issue comment was posted at " <> commentUrl)
          message `shouldMention` "updating the issue labels"
          message `shouldMention` "outcome is unknown"
          message `shouldMention` "with this tool"
          message `shouldNotMention` "failed"

    it "reports the forced reviewed:revised label creation as outcome-unknown when it outlives the deadline" $
      withFakeGitHubCli
        [ "if [ \"$1\" = \"issue\" ] && [ \"$2\" = \"comment\" ]; then",
          postComment,
          "exit 0",
          "fi",
          "sleep 30"
        ]
        injectedBounds
        $ \client -> do
          result <- runBoundedGitHubTool boundedCallMicros client (GitHubIssueToolRequest GitHubIssueUpdate 15 (Just "body") ["reviewed:revised"] [])
          message <- requireLeft "expected the unfinished label creation to be reported as outcome-unknown" result
          message `shouldMention` ("The issue comment was posted at " <> commentUrl)
          message `shouldMention` "creating the reviewed:revised label"
          message `shouldMention` "outcome is unknown"
          message `shouldNotMention` "failed"

    it "round-trips a fast canonical review unchanged, still logging both captured streams" $
      withFakeCanonicalReviewer ["printf '%s' '{\"approved\":true}'", "printf 'reviewer diagnostic\\n' >&2"] $ \cacheRoot repository reviewerPath -> do
        result <- runBoundedCanonicalCommand boundedCallMicros injectedBounds repository reviewerPath
        result `shouldBe` Right "{\"approved\":true}"
        logged <- canonicalSessionLogText cacheRoot
        logged `shouldSatisfy` isInfixOf "{\\\"approved\\\":true}"
        logged `shouldSatisfy` isInfixOf "reviewer diagnostic"

    it "reports a canonical review whose stdout a forked child holds open as outcome-unknown, never as a timeout" $
      withFakeCanonicalReviewer ["sleep 30 &", "printf '%s' '{\"approved\":true}'"] $ \_ repository reviewerPath -> do
        result <- runBoundedCanonicalCommand boundedCallMicros injectedBounds repository reviewerPath
        message <- requireLeft "expected truncated canonical stdout to be reported as outcome-unknown" result
        message `shouldMention` "still incomplete after"
        message `shouldMention` "outcome is unknown"
        message `shouldNotMention` "timed out"

    it "still decodes a canonical review whose stderr alone is held open past the deadline" $
      withFakeCanonicalReviewer ["sleep 30 >/dev/null &", "printf '%s' '{\"approved\":true}'"] $ \_ repository reviewerPath -> do
        result <- runBoundedCanonicalCommand boundedCallMicros injectedBounds repository reviewerPath
        result `shouldBe` Right "{\"approved\":true}"

    it "gives canonical outcome-unknown guidance without any same-tool reread instruction" $
      withFakeCanonicalReviewer ["sleep 30"] $ \_ repository reviewerPath -> do
        result <- runBoundedCanonicalCommand boundedCallMicros injectedBounds repository reviewerPath
        message <- requireLeft "expected an unfinished canonical review to be reported as outcome-unknown" result
        message `shouldMention` "did not exit within"
        message `shouldMention` "outcome is unknown"
        message `shouldMention` "Check the issue's current comments and labels"
        message `shouldNotMention` "this tool"

    it "renders a canonical outcome-unknown result to the operator without claiming the review failed" $ do
      unknown <-
        withFakeCanonicalReviewer ["sleep 30"] $ \_ repository reviewerPath ->
          requireLeft "expected an unfinished canonical review to be reported as outcome-unknown"
            =<< runBoundedCanonicalCommand boundedCallMicros injectedBounds repository reviewerPath
      canonicalReviewActivity unknown `shouldBe` "outcome unknown"
      canonicalReviewNotice unknown `shouldNotMention` "failed"
      canonicalReviewNotice unknown `shouldMention` "could not be observed"
      canonicalReviewActivity "python3 was not found on PATH" `shouldBe` "failed"
      canonicalReviewNotice "python3 was not found on PATH" `shouldBe` "Canonical issue review failed: python3 was not found on PATH"

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

    it "tells an operator with nothing selected to press the kill binding rather than the select-previous binding" $ do
      -- The board dispatches the kill on 'x'; 'k' selects the previous card,
      -- so a notice naming 'k' silently moves the selection instead. The Esc
      -- and Ctrl-L halves of this keyboard-contract fix dispatch in brick's
      -- 'EventM' (and Ctrl-L needs a live Vty handle), which no unit test
      -- here can drive; they stay covered by the manual checks in the PR.
      killSelectionNotice `shouldMention` "pressing x"
      killSelectionNotice `shouldNotMention` "pressing k"
      killSelectionNotice `shouldBe` "Select a working issue or PR before pressing x"

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
                solveSessionResumeProvenance = ResumeAnswer,
                solveSessionFollowing = True
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
                pullRequestSessionResumeProvenance = ResumeAnswer,
                pullRequestSessionFollowing = True
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
            "{\"issue\":844,\"stage\":\"review\",\"approved\":false,\"reviewerRoute\":\"codex-origin → Opus 5\",\"models\":[\"Opus 5 xhigh\"],\"commentUrl\":\"https://example.test/issues/844#issuecomment-1\",\"blockingReasons\":[\"Clarify the save-version migration.\",\"Name the regression probe.\"]}"
          expected =
            ReviewResult
              { reviewResultIssue = 844,
                reviewResultStage = InitialReview,
                reviewResultApproved = False,
                reviewResultReviewerRoute = "codex-origin → Opus 5",
                reviewResultModels = ["Opus 5 xhigh"],
                reviewResultCommentUrl = Just "https://example.test/issues/844#issuecomment-1",
                reviewResultBlockingReasons = ["Clarify the save-version migration.", "Name the regression probe."]
              }
      decodeReviewResult payload `shouldBe` Right expected
      renderReviewResult expected
        `shouldBe` Data.Text.unlines
          [ "Review result",
            "  Outcome: CHANGES REQUESTED",
            "  Reviewer route: codex-origin → Opus 5",
            "  Models: Opus 5 xhigh",
            "  Comment: https://example.test/issues/844#issuecomment-1",
            "  Blocking reasons:",
            "    • Clarify the save-version migration.",
            "    • Name the regression probe."
          ]

    it "selects revision and rereview stages from durable workflow labels" $ do
      reviewStageForLabels defaultWorkflowConfig [] `shouldBe` InitialReview
      reviewStageForLabels defaultWorkflowConfig ["reviewed:changes"] `shouldBe` IssueRevision
      reviewStageForLabels defaultWorkflowConfig ["REVIEWED:REVISED", "reviewed:changes"] `shouldBe` IssueRereview

    it "selects the revision stage from a configured changes-requested label" $
      reviewStageForLabels (defaultWorkflowConfig {changesRequestedLabel = "needs-work"}) ["needs-work"] `shouldBe` IssueRevision

    it "formats the canonical v2 gate without exposing raw JSON" $ do
      let payload =
            "{\"approved\":false,\"issue\":844,\"origin\":\"codex\",\"required_reviewers\":\"claude\",\"required_models\":\"claude-opus-5@xhigh\",\"reasons\":[\"latest current review verdict is CHANGES_REQUESTED\"]}"
          expected =
            CanonicalIssueReviewResult
              { canonicalReviewApproved = False,
                canonicalReviewIssue = 844,
                canonicalReviewOrigin = "codex",
                canonicalReviewRequiredReviewers = Just "claude",
                canonicalReviewRequiredModels = Just "claude-opus-5@xhigh",
                canonicalReviewReasons = ["latest current review verdict is CHANGES_REQUESTED"]
              }
      decodeCanonicalIssueReviewResult payload `shouldBe` Right expected
      renderCanonicalIssueReviewResult InitialReview expected
        `shouldBe` Data.Text.unlines
          [ "Review result",
            "  Outcome: CHANGES REQUESTED",
            "  Origin: codex",
            "  Reviewer route: claude",
            "  Models: claude-opus-5@xhigh",
            "  Blocking reasons:",
            "    • latest current review verdict is CHANGES_REQUESTED"
          ]

    it "passes an explicit --repo, matching Kanban's own resolved repository, to the canonical issue reviewer" $ do
      let repository = Repository "/tmp/repo" "coghex" "kanban"
          arguments = canonicalIssueReviewArguments "/opt/approve_issues.py" repository 844 InitialReview Nothing
      arguments `shouldContain` ["--repo", "coghex/kanban"]
      arguments `shouldContain` ["--path", "/tmp/repo"]

    it "resolves a --repo override the same way regardless of the checkout's own remote, mirroring a fork checkout" $ do
      -- The dashboard's own --repo option can point at a different
      -- repository than the checkout's configured remote (e.g. reviewing
      -- upstream from a fork checkout); the canonical reviewer must be told
      -- the same explicit identity Kanban resolved, not left to re-derive
      -- one from the remote itself.
      let forkCheckout = Repository "/tmp/fork" "upstream-owner" "upstream-repo"
          arguments = canonicalIssueReviewArguments "/opt/approve_issues.py" forkCheckout 844 IssueRereview (Just "/tmp/custom.toml")
      arguments `shouldContain` ["--repo", "upstream-owner/upstream-repo"]
      arguments `shouldContain` ["--rereview", "844"]
      arguments `shouldContain` ["--config", "/tmp/custom.toml"]

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
      decodeGitHubIssueToolRequest defaultWorkflowConfig request
        `shouldBe` Right
          GitHubIssueToolRequest
            { githubToolOperation = GitHubIssueUpdate,
              githubToolIssue = 844,
              githubToolComment = Just "## Review result\nApproved.",
              githubToolAddLabels = ["reviewed:approve"],
              githubToolRemoveLabels = ["reviewed:changes", "reviewed:revised"]
            }
      decodeGitHubIssueToolRequest defaultWorkflowConfig (object ["operation" .= ("update" :: Text), "issue" .= (844 :: Int), "addLabels" .= (["bug"] :: [Text])])
        `shouldBe` Left "kanban_github_issue may only change reviewed:approve, reviewed:changes, and reviewed:revised"
      decodeGitHubIssueToolRequest
        (defaultWorkflowConfig {approvalLabel = "lgtm", changesRequestedLabel = "needs-work"})
        (object ["operation" .= ("update" :: Text), "issue" .= (844 :: Int), "addLabels" .= (["lgtm"] :: [Text])])
        `shouldSatisfy` isRight

    it "passes an explicit --repo, matching Kanban's own resolved repository, to every embedded GitHub tool command" $ do
      let repo = "upstream-owner/upstream-repo"
          request =
            GitHubIssueToolRequest
              { githubToolOperation = GitHubIssueUpdate,
                githubToolIssue = 844,
                githubToolComment = Just "## Review result\nApproved.",
                githubToolAddLabels = ["reviewed:approve"],
                githubToolRemoveLabels = ["reviewed:changes", "reviewed:revised"]
              }
      githubIssueViewArguments repo 844 `shouldContain` ["--repo", "upstream-owner/upstream-repo"]
      githubIssueCommentArguments repo 844 `shouldContain` ["--repo", "upstream-owner/upstream-repo"]
      githubLabelCreateArguments repo `shouldContain` ["--repo", "upstream-owner/upstream-repo"]
      githubIssueEditArguments repo request `shouldContain` ["--repo", "upstream-owner/upstream-repo"]

  describe "Kanban.StreamReader" $ do
    it "reads every line through to EOF, forwarding each in order and never abandoning" $ do
      cursor <- newIORef (["one", "two", "three"] :: [ByteString.ByteString])
      onLineSeen <- newIORef ([] :: [ByteString.ByteString])
      abandonSeen <- newIORef ([] :: [Text])
      let readLine = do
            queued <- readIORef cursor
            case queued of
              [] -> pure (Right Nothing)
              (line : rest) -> writeIORef cursor rest >> pure (Right (Just line))
      outcome <- runStreamReaderWith readLine "stdout" (\line -> modifyIORef onLineSeen (line :)) (\reason -> modifyIORef abandonSeen (reason :))
      outcome `shouldBe` StreamCompleted
      seenLines <- reverse <$> readIORef onLineSeen
      seenLines `shouldBe` ["one", "two", "three"]
      readIORef abandonSeen `shouldReturn` []

    it "resets its consecutive-failure budget after every successful read, tolerating many isolated failures over a long stream" $ do
      -- Each simulated round fails one short of the bound, then succeeds:
      -- never a run long enough to exhaust it, even though the total
      -- failure count across the whole stream far exceeds the bound.
      let failsBetweenSuccesses = maxConsecutiveReadFailures - 1
          rounds = 12 :: Int
          failure = Left (userError "simulated transient read failure")
          scriptRound n = replicate failsBetweenSuccesses failure <> [Right (Just (ByteString.pack ("line-" <> show n)))]
          script = concatMap scriptRound [1 .. rounds] <> [Right Nothing]
      cursor <- newIORef script
      onLineSeen <- newIORef ([] :: [ByteString.ByteString])
      abandonSeen <- newIORef ([] :: [Text])
      let readLine = do
            queued <- readIORef cursor
            case queued of
              [] -> pure (Right Nothing)
              (next : rest) -> writeIORef cursor rest >> pure next
      outcome <- runStreamReaderWith readLine "stdout" (\line -> modifyIORef onLineSeen (line :)) (\reason -> modifyIORef abandonSeen (reason :))
      outcome `shouldBe` StreamCompleted
      seenLines <- reverse <$> readIORef onLineSeen
      length seenLines `shouldBe` rounds
      readIORef abandonSeen `shouldReturn` []

    it "gives up after maxConsecutiveReadFailures consecutive read failures instead of retrying forever or abandoning silently" $ do
      attempts <- newIORef (0 :: Int)
      onLineSeen <- newIORef ([] :: [ByteString.ByteString])
      abandonSeen <- newIORef ([] :: [Text])
      let readLine = do
            modifyIORef attempts (+ 1)
            pure (Left (userError "simulated persistent read failure"))
      outcome <- runStreamReaderWith readLine "stdout" (\line -> modifyIORef onLineSeen (line :)) (\reason -> modifyIORef abandonSeen (reason :))
      outcome `shouldBe` StreamAbandoned
      readIORef attempts `shouldReturn` maxConsecutiveReadFailures
      readIORef onLineSeen `shouldReturn` []
      reasons <- readIORef abandonSeen
      case reasons of
        [reason] -> do
          reason `shouldSatisfy` Data.Text.isInfixOf (Data.Text.pack (show maxConsecutiveReadFailures))
          reason `shouldSatisfy` Data.Text.isInfixOf "simulated persistent read failure"
        _ -> expectationFailure ("expected exactly one abandonment diagnostic, got " <> show (length reasons))

    it "onStreamAbandoned reports the diagnostic, remembers only the first reason, and terminates the still-live process" $
      withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \process -> do
        threadDelay 100000
        managed <- managedProcessFor process
        abandonReasonRef <- newIORef Nothing
        diagnostics <- newIORef ([] :: [Text])
        let emitDiagnostic message = modifyIORef diagnostics (message :)
        onStreamAbandoned emitDiagnostic managed abandonReasonRef "stdout gave up"
        onStreamAbandoned emitDiagnostic managed abandonReasonRef "stderr gave up too"
        readIORef abandonReasonRef `shouldReturn` Just "stdout gave up"
        seenDiagnostics <- reverse <$> readIORef diagnostics
        seenDiagnostics `shouldBe` ["stdout gave up", "stderr gave up too"]
        timeout 3000000 (waitForProcess process) `shouldReturn` Just (ExitFailure (-9))

    it "runStreamReader reads a real provider pipe through to EOF, exactly like the injected-action path" $ do
      (_, Just outputHandle, _, process) <- createProcess (proc "sh" ["-c", "printf 'alpha\\nbeta\\n'"]) {std_out = CreatePipe}
      onLineSeen <- newIORef ([] :: [ByteString.ByteString])
      abandonSeen <- newIORef ([] :: [Text])
      outcome <- runStreamReader outputHandle "stdout" (\line -> modifyIORef onLineSeen (line :)) (\reason -> modifyIORef abandonSeen (reason :))
      _ <- waitForProcess process
      outcome `shouldBe` StreamCompleted
      seenLines <- reverse <$> readIORef onLineSeen
      seenLines `shouldBe` ["alpha", "beta"]
      readIORef abandonSeen `shouldReturn` []

    it "handleReadLine reports a failure when the EOF probe itself throws" $ do
      (_, Just outputHandle, _, process) <- createProcess (proc "sh" ["-c", "sleep 30"]) {std_out = CreatePipe}
      hClose outputHandle
      result <- handleReadLine outputHandle
      case result of
        Left _ -> pure ()
        Right _ -> expectationFailure "expected hIsEOF on a closed handle to fail"
      managedProcessFor process >>= killManagedProcess
      void (timeout 3000000 (waitForProcess process))

    it "handleReadLine reports a failure when the line read is interrupted after the EOF probe already reported more to read" $ do
      (_, Just outputHandle, _, process) <- createProcess (proc "sh" ["-c", "printf '%s' 'partial-line-without-a-newline'; sleep 30"]) {std_out = CreatePipe}
      resultVar <- newEmptyMVar
      readerThread <- forkIO (handleReadLine outputHandle >>= putMVar resultVar)
      -- Long enough that the reader thread has certainly finished its
      -- (non-blocking, data-already-pending) EOF probe and parked in the
      -- blocking line read before the injected exception lands, so it
      -- exercises the line-read 'try', not the EOF probe's.
      threadDelay 500000
      throwTo readerThread (userError "simulated line-read cancellation")
      result <- timeout 5000000 (takeMVar resultVar)
      case result of
        Just (Left _) -> pure ()
        Just (Right _) -> expectationFailure "expected the interrupted read to fail"
        Nothing -> expectationFailure "handleReadLine did not return after being interrupted"
      managedProcessFor process >>= killManagedProcess
      void (timeout 3000000 (waitForProcess process))

  -- Both workflows classify their terminal outcome through one shared
  -- implementation, so every case below is asserted against 'solveOutcome'
  -- and 'flowOutcome' together: they must agree on marker anchoring and on
  -- exit-status precedence, and differ only in the failure diagnostic's
  -- agent label.
  describe "agent handoff outcome classification" $ do
    let bothOutcomes message exitCode = (solveOutcome exitCode message, flowOutcome exitCode message)

    it "treats a marker that begins the final message as a handoff" $
      bothOutcomes "KANBAN_NEEDS_INPUT: which base branch?" ExitSuccess
        `shouldBe` (SolveNeedsInput "which base branch?", SolveNeedsInput "which base branch?")

    it "treats a marker that begins a later line as a handoff" $
      bothOutcomes "I inspected the worktree.\nKANBAN_NEEDS_INPUT: which base branch?" ExitSuccess
        `shouldBe` (SolveNeedsInput "which base branch?", SolveNeedsInput "which base branch?")

    it "accepts an indented marker line" $
      bothOutcomes "Summary:\n   \tKANBAN_NEEDS_INPUT: which base branch?" ExitSuccess
        `shouldBe` (SolveNeedsInput "which base branch?", SolveNeedsInput "which base branch?")

    -- The regression this classification exists for: the prompts tell the
    -- agent to "stop with exactly KANBAN_NEEDS_INPUT: <question>", so a
    -- completion summary quoting the contract used to turn a finished run
    -- into a question nobody asked.
    it "completes a successful run whose message only mentions the marker mid-line" $
      bothOutcomes
        "Opened PR #42. Had ambiguity arisen I would have stopped with KANBAN_NEEDS_INPUT: a concrete question."
        ExitSuccess
        `shouldBe` (SolveCompleted, SolveCompleted)

    it "completes a successful run with no marker at all" $
      bothOutcomes "PR #42 — anchored the marker match." ExitSuccess
        `shouldBe` (SolveCompleted, SolveCompleted)

    it "ignores an anchored marker whose question is empty" $
      bothOutcomes "KANBAN_NEEDS_INPUT:   " ExitSuccess
        `shouldBe` (SolveCompleted, SolveCompleted)

    -- Deterministic rule: the last *valid* anchored line supplies the single
    -- question, so a resumed session's newest ask is the one surfaced.
    it "takes the last anchored line when several qualify" $
      bothOutcomes
        "KANBAN_NEEDS_INPUT: first question?\nstill working\nKANBAN_NEEDS_INPUT: second question?"
        ExitSuccess
        `shouldBe` (SolveNeedsInput "second question?", SolveNeedsInput "second question?")

    it "skips a trailing empty marker in favour of the last valid anchored line" $
      bothOutcomes "KANBAN_NEEDS_INPUT: real question?\nKANBAN_NEEDS_INPUT:" ExitSuccess
        `shouldBe` (SolveNeedsInput "real question?", SolveNeedsInput "real question?")

    -- A question the agent actually printed must outrank the exit status:
    -- needs-input is always more useful than a failure that buries it.
    it "keeps an anchored handoff when the agent exits nonzero" $
      bothOutcomes "KANBAN_NEEDS_INPUT: which base branch?" (ExitFailure 1)
        `shouldBe` (SolveNeedsInput "which base branch?", SolveNeedsInput "which base branch?")

    it "still fails a nonzero exit whose message only mentions the marker mid-line" $
      bothOutcomes "aborted before I could stop with KANBAN_NEEDS_INPUT: a question" (ExitFailure 3)
        `shouldBe` ( SolveFailed "Solver exited with status 3: aborted before I could stop with KANBAN_NEEDS_INPUT: a question",
                     SolveFailed "PR agent exited with status 3: aborted before I could stop with KANBAN_NEEDS_INPUT: a question"
                   )

    it "reports a nonzero exit without a marker using each workflow's diagnostic" $
      bothOutcomes "fatal: not a git repository" (ExitFailure 128)
        `shouldBe` ( SolveFailed "Solver exited with status 128: fatal: not a git repository",
                     SolveFailed "PR agent exited with status 128: fatal: not a git repository"
                   )

    it "omits the message from the diagnostic when the final message is blank" $
      bothOutcomes "  \n  " (ExitFailure 2)
        `shouldBe` (SolveFailed "Solver exited with status 2", SolveFailed "PR agent exited with status 2")

    it "truncates a long failure message to 1000 characters" $ do
      let (solveFailure, flowFailure) = bothOutcomes (Data.Text.replicate 1200 "x") (ExitFailure 1)
      solveFailure `shouldBe` SolveFailed ("Solver exited with status 1: " <> Data.Text.replicate 1000 "x")
      flowFailure `shouldBe` SolveFailed ("PR agent exited with status 1: " <> Data.Text.replicate 1000 "x")

  describe "solve process protocol" $ do
    it "pins the canonical solver and reviewer model contract" $ do
      codexSolverModel `shouldBe` "gpt-5.4 high"
      claudeSolverModel `shouldBe` "Sonnet 5 high"
      codexReviewerModel `shouldBe` "GPT-5.6-Terra xhigh"
      claudeReviewerModel `shouldBe` "Opus 5 xhigh"

    it "launches each solver with its pinned model and effort" $ do
      let codexArguments = solveArguments 844 SolveOnly CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer ""
          claudeArguments = solveArguments 844 SolveOnly ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer ""
      codexArguments `shouldContain` ["--model", "gpt-5.4"]
      codexArguments `shouldContain` ["model_reasoning_effort=\"high\""]
      codexArguments `shouldContain` ["model_reasoning_summary=\"detailed\""]
      claudeArguments `shouldContain` ["--model", "claude-sonnet-5"]
      claudeArguments `shouldContain` ["--effort", "high"]

    it "runs the ordinary solve command for both S and Kanban-owned A orchestration" $ do
      let codexSolvePrompt = last (solveArguments 844 SolveOnly CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
          codexAutoSolvePrompt = last (solveArguments 844 AutoSolve CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
          claudeSolvePrompt = last (solveArguments 844 SolveOnly ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
          claudeAutoSolvePrompt = last (solveArguments 844 AutoSolve ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
      codexSolvePrompt `shouldContain` "$solve"
      codexAutoSolvePrompt `shouldContain` "$solve"
      codexAutoSolvePrompt `shouldNotContain` "$autosolve"
      codexAutoSolvePrompt `shouldContain` "Kanban owns the bounded review/fix loop"
      claudeSolvePrompt `shouldContain` "/solve"
      claudeAutoSolvePrompt `shouldContain` "/solve"
      claudeAutoSolvePrompt `shouldNotContain` "/autosolve"
      codexSolvePrompt `shouldContain` "Do not run issue-review"

    it "passes a configured --config path through to the read-only gate-check instruction" $ do
      let promptWithConfig = last (solveArguments 844 SolveOnly CodexSolver (Just "/tmp/kanban/custom.toml") (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
          promptWithoutConfig = last (solveArguments 844 SolveOnly CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
      promptWithConfig `shouldContain` "Pass --config /tmp/kanban/custom.toml to the read-only v2 gate check"
      promptWithoutConfig `shouldNotContain` "Pass --config"

    it "always passes Kanban's own resolved --repo to the read-only gate-check instruction, even without a fork override" $ do
      let forkRepository = Repository "/tmp/fork" "upstream-owner" "upstream-repo"
          forkPrompt = last (solveArguments 844 SolveOnly CodexSolver Nothing forkRepository defaultWorkflowConfig Nothing ResumeAnswer "")
      forkPrompt `shouldContain` "Pass --repo upstream-owner/upstream-repo to the read-only v2 gate check"

    it "recovers an interrupted same-issue worktree instead of treating it as a collision" $ do
      let solvePrompt = last (solveArguments 782 SolveOnly CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
      solvePrompt `shouldContain` "existing worktree for issue #782"
      solvePrompt `shouldContain` "prior solve was interrupted; it is recovery work, not a collision"
      solvePrompt `shouldContain` "inspect `git status`, committed progress relative to that base, and both staged and unstaged diffs"
      solvePrompt `shouldContain` "Do not discard, reset, or overwrite unfinished changes merely to start clean"
      solvePrompt `shouldContain` "Only create a new sibling worktree when no same-issue worktree exists"

    it "frames a resumed solve prompt with the true provenance of the resumed message instead of always claiming a user answer" $ do
      let answerPrompt = last (solveArguments 844 SolveOnly CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig (Just "session-1") ResumeAnswer "pick option B")
          interruptPrompt = last (solveArguments 844 SolveOnly CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig (Just "session-1") ResumeInterruptGuidance "focus on the other file instead")
          automatedPrompt = last (solveArguments 844 AutoSolve CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig (Just "session-1") ResumeAutomatedChangesRequested "Kanban received CHANGES_REQUESTED for PR #900")
      answerPrompt `shouldContain` Data.Text.unpack (resumeProvenanceHeader defaultWorkflowConfig ResumeAnswer)
      answerPrompt `shouldContain` "KANBAN_NEEDS_INPUT"
      interruptPrompt `shouldContain` Data.Text.unpack (resumeProvenanceHeader defaultWorkflowConfig ResumeInterruptGuidance)
      interruptPrompt `shouldNotContain` "The user answered"
      interruptPrompt `shouldContain` "KANBAN_NEEDS_INPUT"
      automatedPrompt `shouldContain` Data.Text.unpack (resumeProvenanceHeader defaultWorkflowConfig ResumeAutomatedChangesRequested)
      automatedPrompt `shouldNotContain` "The user answered"
      automatedPrompt `shouldContain` "KANBAN_NEEDS_INPUT"

    it "names the configured changes-requested label in the automated resume header instead of the literal default" $ do
      let customConfig = defaultWorkflowConfig {changesRequestedLabel = "needs-work"}
          customAutomatedPrompt = last (solveArguments 844 AutoSolve CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") customConfig (Just "session-1") ResumeAutomatedChangesRequested "Kanban received CHANGES_REQUESTED for PR #900")
      customAutomatedPrompt `shouldContain` "the PR received needs-work"
      customAutomatedPrompt `shouldNotContain` "the PR received reviewed:changes"

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

    it "identifies the session before forwarding agent output, and reports normal completion" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"stream-session\"}'",
                "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Created PR #999\"}}'"
              ]
          )
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            events <- newIORef []
            runSolve repository 900 SolveOnly CodexSolver Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" (\event -> modifyIORef events (event :))
            collected <- reverse <$> readIORef events
            case (findIndex isSolveSessionIdentifiedEvent collected, findIndex isSolveOutputEvent collected) of
              (Just sessionIndex, Just outputIndex) -> sessionIndex `shouldSatisfy` (< outputIndex)
              _ -> expectationFailure "expected both a session-identified and an output event"
            case reverse collected of
              (SolveProcessFinished _ SolveCompleted : _) -> pure ()
              (SolveProcessFinished _ (SolveFailed message) : _) -> expectationFailure ("expected completion, got failure: " <> Data.Text.unpack message)
              (SolveProcessFinished _ (SolveNeedsInput question) : _) -> expectationFailure ("expected completion, got needs-input: " <> Data.Text.unpack question)
              _ -> expectationFailure "expected the final event to be SolveProcessFinished"

    it "reports a needs-input outcome when the agent's last message carries the KANBAN_NEEDS_INPUT marker" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"needs-input-session\"}'",
                "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"KANBAN_NEEDS_INPUT: which branch?\"}}'"
              ]
          )
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            events <- newIORef []
            runSolve repository 901 SolveOnly CodexSolver Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" (\event -> modifyIORef events (event :))
            collected <- reverse <$> readIORef events
            case reverse collected of
              (SolveProcessFinished _ (SolveNeedsInput question) : _) -> question `shouldBe` "which branch?"
              _ -> expectationFailure "expected a needs-input terminal outcome"

    it "signals stderr-reader completion (and returns) even when diagnostic delivery for a stderr line throws" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "echo 'stderr-poison-line' >&2",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"stderr-poison-session\"}'",
                "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Created PR #999\"}}'"
              ]
          )
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            let poisonedSink event = case event of
                  SolveDiagnostic _ message
                    | Data.Text.isInfixOf "stderr-poison-line" message -> throwIO (userError "diagnostic delivery exploded")
                  _ -> pure ()
            timeout 10000000 (runSolve repository 902 SolveOnly CodexSolver Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" poisonedSink) `shouldReturn` Just ()

    it "terminates the still-live provider and forces a failed terminal outcome when the stdout reader's read primitive keeps failing" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        -- A provider that just sleeps, kept alive so 'runSolveWith' has a
        -- real, still-live process to terminate. The stdout-only-failing
        -- read primitive below drives that path's abandonment
        -- deterministically; what the provider would otherwise have
        -- written on stdout is irrelevant, since the stdout reader never
        -- actually calls through to a real read here.
        ByteString.writeFile fakeCodex (ByteString.unlines ["#!/bin/sh", "sleep 30"])
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            events <- newIORef []
            spawnedIdentity <- newIORef Nothing
            let sink event = do
                  modifyIORef events (event :)
                  case event of
                    SolveProcessStarted _ _ managed -> do
                      maybePid <- managedProcessPid managed
                      case maybePid of
                        Nothing -> pure ()
                        Just pid -> do
                          snapshot <- readProcessSnapshot
                          case snapshot of
                            Right identities -> writeIORef spawnedIdentity (identityForPid (fromIntegral pid) identities)
                            Left _ -> pure ()
                    _ -> pure ()
                -- Fails only the stdout handle; the stderr reader keeps
                -- using the real primitive (and so completes normally once
                -- the provider is killed), so the failed terminal outcome
                -- below can only be attributed to the stdout path, not a
                -- race with stderr's own abandonment.
                stdoutOnlyFails tag handle
                  | tag == "stdout" = pure (Left (userError "simulated persistent stdout read failure"))
                  | otherwise = handleReadLine handle
            timeout 20000000 (runSolveWith stdoutOnlyFails repository 906 SolveOnly CodexSolver Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" sink) `shouldReturn` Just ()
            collected <- reverse <$> readIORef events
            let stdoutAbandonments = [message | SolveDiagnostic _ message <- collected, Data.Text.isInfixOf "stdout stream reader gave up" message]
            stdoutAbandonments `shouldSatisfy` (not . null)
            case reverse collected of
              (SolveProcessFinished _ (SolveFailed _) : _) -> pure ()
              _ -> expectationFailure "expected a failed terminal outcome after the stdout reader was abandoned"
            identity <- readIORef spawnedIdentity
            case identity of
              Nothing -> expectationFailure "expected to capture the spawned provider's process identity"
              Just recorded -> do
                snapshotAfter <- readProcessSnapshot
                case snapshotAfter of
                  Left message -> expectationFailure ("could not verify process death: " <> Data.Text.unpack message)
                  Right identities -> matchingIdentities identities [recorded] `shouldBe` []

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
      actionForLabels defaultWorkflowConfig [] `shouldBe` PullRequestReview
      actionForLabels defaultWorkflowConfig ["reviewed:changes"] `shouldBe` PullRequestRevision
      actionForLabels defaultWorkflowConfig ["reviewed:changes", "reviewed:revised"] `shouldBe` PullRequestRereview
      actionForLabels defaultWorkflowConfig ["reviewed:revised"] `shouldBe` PullRequestRereview

    it "advances to revision from a configured changes-requested label" $
      actionForLabels (defaultWorkflowConfig {changesRequestedLabel = "needs-work"}) ["needs-work"] `shouldBe` PullRequestRevision

    it "uses the opposite brand to review and the origin brand to revise" $ do
      agentForAction PullRequestCodex PullRequestReview `shouldBe` ClaudeSolver
      agentForAction PullRequestCodex PullRequestRevision `shouldBe` CodexSolver
      agentForAction PullRequestClaude PullRequestReview `shouldBe` CodexSolver
      agentForAction PullRequestClaude PullRequestRevision `shouldBe` ClaudeSolver

    it "pins canonical reviewer and reviser models" $ do
      pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "" `shouldContain` ["--model", "claude-opus-5", "--effort", "xhigh"]
      pullRequestArguments 42 PullRequestCodex PullRequestRevision CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "" `shouldContain` ["--model", "gpt-5.4", "--config", "model_reasoning_effort=\"high\""]
      pullRequestArguments 42 PullRequestClaude PullRequestRevision ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "" `shouldContain` ["--model", "claude-sonnet-5", "--effort", "xhigh"]
      pullRequestArguments 42 PullRequestClaude PullRequestRereview CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "" `shouldContain` ["--model", "gpt-5.6-terra", "--config", "model_reasoning_effort=\"xhigh\""]

    it "routes r-key revisions through canonical pr-revise instead of the legacy manual-label prompt" $ do
      let codexOriginRevisionPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestRevision CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
          claudeOriginRevisionPrompt = last (pullRequestArguments 42 PullRequestClaude PullRequestRevision ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
      codexOriginRevisionPrompt `shouldContain` "$pr-revise"
      claudeOriginRevisionPrompt `shouldContain` "/pr-revise"
      codexOriginRevisionPrompt `shouldNotContain` "pr-review:v1"
      claudeOriginRevisionPrompt `shouldNotContain` "pr-review:v1"
      codexOriginRevisionPrompt `shouldNotContain` "create reviewed:revised"
      codexOriginRevisionPrompt `shouldContain` "leave reviewed:approve, reviewed:changes, and reviewed:revised to the canonical review coordinator"

    it "builds the revision prompt's coordinator-owned labels from the configured workflow labels, not literals" $ do
      let customConfig = defaultWorkflowConfig {approvalLabel = "lgtm", changesRequestedLabel = "needs-work"}
          customPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestRevision CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") customConfig Nothing ResumeAnswer "")
      customPrompt `shouldContain` "leave lgtm, needs-work, and reviewed:revised to the canonical review coordinator"
      customPrompt `shouldNotContain` "reviewed:approve, reviewed:changes"

    it "tells a spawned reviewer to pass the dashboard's selected --config to the canonical coordinator, but only when one is configured" $ do
      let configuredPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver (Just "/tmp/custom-config.toml") (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
          defaultPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
      configuredPrompt `shouldContain` "--config /tmp/custom-config.toml"
      defaultPrompt `shouldNotContain` "--config"

    it "always tells a spawned reviewer to pass Kanban's own resolved --repo to the canonical coordinator, even without a fork override" $ do
      let forkRepository = Repository "/tmp/fork" "upstream-owner" "upstream-repo"
          forkPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing forkRepository defaultWorkflowConfig Nothing ResumeAnswer "")
      forkPrompt `shouldContain` "Pass --repo upstream-owner/upstream-repo to"

    it "tells a resumed autosolve pr-revise to pass the dashboard's selected --config, but only when one is configured" $ do
      let repository = Repository "/tmp/repo" "coghex" "kanban"
          configuredPrompt = Data.Text.unpack (autoSolveRevisionPrompt defaultWorkflowConfig (Just "/tmp/custom-config.toml") repository ClaudeSolver 42 1)
          defaultPrompt = Data.Text.unpack (autoSolveRevisionPrompt defaultWorkflowConfig Nothing repository ClaudeSolver 42 1)
      configuredPrompt `shouldContain` "--config /tmp/custom-config.toml"
      defaultPrompt `shouldNotContain` "--config"

    it "always tells a resumed autosolve pr-revise to pass Kanban's own resolved --repo, even without a fork override" $ do
      let forkRepository = Repository "/tmp/fork" "upstream-owner" "upstream-repo"
          forkPrompt = Data.Text.unpack (autoSolveRevisionPrompt defaultWorkflowConfig Nothing forkRepository ClaudeSolver 42 1)
      forkPrompt `shouldContain` "Pass --repo upstream-owner/upstream-repo to"

    it "never asks the initial review prompt to remove a label only rereview can see, but keeps that instruction in rereview" $ do
      let initialReviewPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
          rereviewPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestRereview ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
      initialReviewPrompt `shouldNotContain` "reviewed:revised"
      rereviewPrompt `shouldContain` "Remove reviewed:revised after successfully publishing the verdict"

    it "frames a resumed PR prompt with the true provenance of the resumed message instead of always claiming a user answer" $ do
      let answerPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig (Just "session-1") ResumeAnswer "looks good")
          interruptPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig (Just "session-1") ResumeInterruptGuidance "check the other file too")
      answerPrompt `shouldContain` Data.Text.unpack (resumeProvenanceHeader defaultWorkflowConfig ResumeAnswer)
      answerPrompt `shouldContain` "KANBAN_NEEDS_INPUT"
      interruptPrompt `shouldContain` Data.Text.unpack (resumeProvenanceHeader defaultWorkflowConfig ResumeInterruptGuidance)
      interruptPrompt `shouldNotContain` "The user answered"
      interruptPrompt `shouldContain` "KANBAN_NEEDS_INPUT"

    it "names the configured changes-requested label in a resumed PR revision's automated-handoff header" $ do
      let customConfig = defaultWorkflowConfig {changesRequestedLabel = "needs-work"}
          customAutomatedPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestRevision CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") customConfig (Just "session-1") ResumeAutomatedChangesRequested "Kanban received CHANGES_REQUESTED for PR #900")
      customAutomatedPrompt `shouldContain` "the PR received needs-work"
      customAutomatedPrompt `shouldNotContain` "the PR received reviewed:changes"

    it "derives a pure post-revision verdict from current labels instead of waiting on a reviewed:revised handoff" $ do
      pullRequestVerdictForLabels defaultWorkflowConfig [] `shouldBe` PullRequestVerdictPending
      pullRequestVerdictForLabels defaultWorkflowConfig ["reviewed:revised"] `shouldBe` PullRequestVerdictPending
      pullRequestVerdictForLabels defaultWorkflowConfig ["reviewed:approve"] `shouldBe` PullRequestVerdictApproved
      pullRequestVerdictForLabels defaultWorkflowConfig ["reviewed:changes"] `shouldBe` PullRequestVerdictChangesRequested

    it "derives a post-revision verdict using a configured approval label" $
      pullRequestVerdictForLabels (defaultWorkflowConfig {approvalLabel = "lgtm"}) ["lgtm"] `shouldBe` PullRequestVerdictApproved

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

    it "identifies the session before forwarding agent output, and reports normal completion" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"pr-stream-session\"}'",
                "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Reviewed\"}}'"
              ]
          )
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            events <- newIORef []
            runPullRequestFlow repository 904 PullRequestClaude PullRequestReview Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" (\event -> modifyIORef events (event :))
            collected <- reverse <$> readIORef events
            case (findIndex isPullRequestSessionIdentifiedEvent collected, findIndex isPullRequestFlowOutputEvent collected) of
              (Just sessionIndex, Just outputIndex) -> sessionIndex `shouldSatisfy` (< outputIndex)
              _ -> expectationFailure "expected both a session-identified and an output event"
            case reverse collected of
              (PullRequestProcessFinished _ SolveCompleted : _) -> pure ()
              (PullRequestProcessFinished _ (SolveFailed message) : _) -> expectationFailure ("expected completion, got failure: " <> Data.Text.unpack message)
              (PullRequestProcessFinished _ (SolveNeedsInput question) : _) -> expectationFailure ("expected completion, got needs-input: " <> Data.Text.unpack question)
              _ -> expectationFailure "expected the final event to be PullRequestProcessFinished"

    it "reports a needs-input outcome when the agent's last message carries the KANBAN_NEEDS_INPUT marker" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"pr-needs-input-session\"}'",
                "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"KANBAN_NEEDS_INPUT: which reviewer wins?\"}}'"
              ]
          )
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            events <- newIORef []
            runPullRequestFlow repository 905 PullRequestClaude PullRequestReview Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" (\event -> modifyIORef events (event :))
            collected <- reverse <$> readIORef events
            case reverse collected of
              (PullRequestProcessFinished _ (SolveNeedsInput question) : _) -> question `shouldBe` "which reviewer wins?"
              _ -> expectationFailure "expected a needs-input terminal outcome"

    it "signals stderr-reader completion (and returns) even when diagnostic delivery for a stderr line throws" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "echo 'stderr-poison-line' >&2",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"pr-stderr-poison-session\"}'",
                "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Reviewed\"}}'"
              ]
          )
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            let poisonedSink event = case event of
                  PullRequestFlowDiagnostic _ message
                    | Data.Text.isInfixOf "stderr-poison-line" message -> throwIO (userError "diagnostic delivery exploded")
                  _ -> pure ()
            timeout 10000000 (runPullRequestFlow repository 903 PullRequestClaude PullRequestReview Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" poisonedSink) `shouldReturn` Just ()

    it "terminates the still-live provider and forces a failed terminal outcome when the stdout reader's read primitive keeps failing" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        -- A provider that just sleeps, kept alive so
        -- 'runPullRequestFlowWith' has a real, still-live process to
        -- terminate. The stdout-only-failing read primitive below drives
        -- that path's abandonment deterministically; what the provider
        -- would otherwise have written on stdout is irrelevant, since the
        -- stdout reader never actually calls through to a real read here.
        ByteString.writeFile fakeCodex (ByteString.unlines ["#!/bin/sh", "sleep 30"])
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            events <- newIORef []
            spawnedIdentity <- newIORef Nothing
            let sink event = do
                  modifyIORef events (event :)
                  case event of
                    PullRequestProcessStarted _ _ _ managed -> do
                      maybePid <- managedProcessPid managed
                      case maybePid of
                        Nothing -> pure ()
                        Just pid -> do
                          snapshot <- readProcessSnapshot
                          case snapshot of
                            Right identities -> writeIORef spawnedIdentity (identityForPid (fromIntegral pid) identities)
                            Left _ -> pure ()
                    _ -> pure ()
                -- Fails only the stdout handle; the stderr reader keeps
                -- using the real primitive (and so completes normally once
                -- the provider is killed), so the failed terminal outcome
                -- below can only be attributed to the stdout path, not a
                -- race with stderr's own abandonment.
                stdoutOnlyFails tag handle
                  | tag == "stdout" = pure (Left (userError "simulated persistent stdout read failure"))
                  | otherwise = handleReadLine handle
            timeout 20000000 (runPullRequestFlowWith stdoutOnlyFails repository 907 PullRequestClaude PullRequestReview Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" sink) `shouldReturn` Just ()
            collected <- reverse <$> readIORef events
            let stdoutAbandonments = [message | PullRequestFlowDiagnostic _ message <- collected, Data.Text.isInfixOf "stdout stream reader gave up" message]
            stdoutAbandonments `shouldSatisfy` (not . null)
            case reverse collected of
              (PullRequestProcessFinished _ (SolveFailed _) : _) -> pure ()
              _ -> expectationFailure "expected a failed terminal outcome after the stdout reader was abandoned"
            identity <- readIORef spawnedIdentity
            case identity of
              Nothing -> expectationFailure "expected to capture the spawned provider's process identity"
              Just recorded -> do
                snapshotAfter <- readProcessSnapshot
                case snapshotAfter of
                  Left message -> expectationFailure ("could not verify process death: " <> Data.Text.unpack message)
                  Right identities -> matchingIdentities identities [recorded] `shouldBe` []

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

  describe "review animation tick decisions" $ do
    -- issue #30: answering a question/approval and the backend's matching
    -- 'ReviewTurnStarted' notification each used to call the tick
    -- scheduler unconditionally, arming two independent 10 Hz chains for
    -- the same turn; canonical (thread-less) sessions had no tick path at
    -- all. 'decideReviewTickArm'/'decideReviewTickFire' are the pure
    -- decision core extracted from 'armReviewTick'/
    -- 'applyReviewAnimationTick' so every transition is covered without an
    -- 'EventM' harness.
    it "arms a fresh chain only when eligible and not already armed" $ do
      decideReviewTickArm ReviewRunning True False 0 `shouldBe` ArmReviewTick 1
      decideReviewTickArm ReviewStarting True False 5 `shouldBe` ArmReviewTick 6

    it "coalesces a repeated trigger onto the chain already in flight" $
      decideReviewTickArm ReviewRunning True True 1 `shouldBe` ReviewTickAlreadyArmed

    it "does not arm a chain outside the eligible phases, even if visible" $
      mapM_
        (\phase -> decideReviewTickArm phase True False 0 `shouldBe` ReviewTickNotEligible)
        [ReviewWaiting, ReviewFinished, ReviewNeedsChanges, ReviewFailed, ReviewRevised, ReviewInterrupted]

    it "does not arm a chain while the review overlay is hidden" $
      decideReviewTickArm ReviewRunning False False 0 `shouldBe` ReviewTickNotEligible

    it "drops a tick carrying a stale generation instead of rescheduling" $
      decideReviewTickFire 2 1 ReviewRunning True `shouldBe` ReviewTickStale

    it "reschedules a tick that matches the current generation while still eligible" $
      decideReviewTickFire 1 1 ReviewRunning True `shouldBe` ReviewTickReschedule

    it "expires a matching tick once the phase transitions to terminal, unarming the session" $
      mapM_
        (\phase -> decideReviewTickFire 1 1 phase True `shouldBe` ReviewTickExpire)
        [ReviewFinished, ReviewNeedsChanges, ReviewFailed, ReviewRevised, ReviewInterrupted, ReviewWaiting]

    it "expires a matching tick once the review overlay is hidden" $
      decideReviewTickFire 1 1 ReviewRunning False `shouldBe` ReviewTickExpire

    it "answer-then-turn-started keeps exactly one live generation" $ do
      -- A chain is already armed (generation 1) from the turn that produced
      -- the question. The user answers before that tick fires: the answer
      -- path's arm request coalesces rather than minting generation 2.
      decideReviewTickArm ReviewRunning True True 1 `shouldBe` ReviewTickAlreadyArmed
      -- The backend's ReviewTurnStarted for the same turn arrives next and
      -- also coalesces onto the same still-armed chain.
      decideReviewTickArm ReviewRunning True True 1 `shouldBe` ReviewTickAlreadyArmed

    it "resolves the verified fast-resume race onto a single chain" $ do
      -- Generation 1 is armed while ReviewRunning, with its tick already
      -- scheduled. A question arrives (ReviewWaiting); armed stays True,
      -- only the phase changes -- the chain is still in flight.
      -- The user answers before that tick fires: phase returns to
      -- ReviewRunning and the answer's arm request coalesces, since
      -- generation 1 is still armed.
      decideReviewTickArm ReviewRunning True True 1 `shouldBe` ReviewTickAlreadyArmed
      -- The original in-flight tick for generation 1 then fires: it
      -- matches the still-current generation and the phase is running
      -- again, so it reschedules that same chain rather than a second one
      -- having been spawned alongside it.
      decideReviewTickFire 1 1 ReviewRunning True `shouldBe` ReviewTickReschedule

    it "arms exactly one chain across a canonical session's lifecycle" $ do
      -- CanonicalIssueReviewProcessStarted arms the first chain while the
      -- session sits in ReviewStarting for the whole run (canonical stages
      -- have no thread/turn, so this is their only tick trigger).
      decideReviewTickArm ReviewStarting True False 0 `shouldBe` ArmReviewTick 1
      -- Further ticks against generation 1 reschedule the same chain for
      -- as long as the process keeps running.
      decideReviewTickFire 1 1 ReviewStarting True `shouldBe` ReviewTickReschedule
      -- The process finishes; the session's phase leaves ReviewStarting.
      -- The next tick for generation 1 expires rather than rescheduling.
      decideReviewTickFire 1 1 ReviewFinished True `shouldBe` ReviewTickExpire
      -- No further chain arms once the session is terminal.
      decideReviewTickArm ReviewFinished True False 1 `shouldBe` ReviewTickNotEligible

    it "expires while hidden and arms exactly one fresh chain on reopen" $ do
      -- The overlay closes while a turn is still running: the in-flight
      -- tick for generation 1 expires (unarms) rather than rescheduling.
      decideReviewTickFire 1 1 ReviewRunning False `shouldBe` ReviewTickExpire
      -- Reopening the overlay re-checks eligibility with armed now False,
      -- arming exactly one fresh chain (generation 2) for the session.
      decideReviewTickArm ReviewRunning True False 1 `shouldBe` ArmReviewTick 2

    -- issue #30 follow-up (round 1 review): reopening the review overlay,
    -- or Tab-cycling within it, must resume every still-running session's
    -- spinner, not only the one being explicitly opened or focused next --
    -- a different session's chain can have expired while the overlay was
    -- closed. 'reviewSessionsNeedingArm' is what 'armVisibleReviewTicks'
    -- sweeps across all sessions to find and re-arm exactly those.
    let tickSession phase armed =
          ReviewSession
            { reviewSessionIssue = baseIssue 1 [],
              reviewSessionStage = InitialReview,
              reviewSessionThreadId = Nothing,
              reviewSessionTurnId = Nothing,
              reviewSessionPhase = phase,
              reviewSessionActivity = "",
              reviewSessionTranscript = ChatTranscript "" "" "",
              reviewSessionPending = Nothing,
              reviewSessionInput = "",
              reviewSessionSpinnerFrame = 0,
              reviewSessionTickGeneration = 1,
              reviewSessionTickArmed = armed,
              reviewSessionFollowing = True
            }

    it "finds a still-running session left unarmed behind another tab" $ do
      let sessions = Map.fromList [(1, tickSession ReviewRunning False), (2, tickSession ReviewRunning True)]
      reviewSessionsNeedingArm True sessions `shouldBe` [1]
      reviewSessionsNeedingArm False sessions `shouldBe` []

    it "does not flag a terminal or an already-armed session for arming" $ do
      reviewSessionsNeedingArm True (Map.singleton 1 (tickSession ReviewFinished False)) `shouldBe` []
      reviewSessionsNeedingArm True (Map.singleton 1 (tickSession ReviewRunning True)) `shouldBe` []

    -- issue #30 round-2/round-3 review: 'startIssueReview' discards a
    -- non-reusable session (e.g. its recorded stage no longer matches
    -- current labels) and replaces it with a genuinely fresh one for the
    -- same issue number. A tick the *old* session already queued can
    -- still be delivered, carrying whatever generation it last armed.
    it "would collide with a replaced session's stale in-flight tick if the generation reset to 0" $ do
      -- The old session reached generation 1 before being replaced, and
      -- left a tick in flight still carrying that generation.
      let staleTickGeneration = 1
      -- A from-scratch replacement session resets to generation 0, so it
      -- does not yet collide with the stale tick while unarmed...
      decideReviewTickFire 0 staleTickGeneration ReviewStarting True `shouldBe` ReviewTickStale
      -- ...but once that session's own first arm mints generation 1, the
      -- stale tick matches it exactly and incorrectly reschedules.
      decideReviewTickArm ReviewStarting True False 0 `shouldBe` ArmReviewTick 1
      decideReviewTickFire 1 staleTickGeneration ReviewStarting True `shouldBe` ReviewTickReschedule

    it "carrying the prior generation forward without bumping it still collides before the replacement's first arm" $ do
      -- Seeding the replacement at exactly the old session's last
      -- generation (rather than resetting to 0) is not sufficient on its
      -- own: a queued stale tick arriving *before* the replacement's own
      -- first arm still matches it exactly.
      let staleTickGeneration = 1
          seededButNotYetArmed = staleTickGeneration
      decideReviewTickFire seededButNotYetArmed staleTickGeneration ReviewStarting True `shouldBe` ReviewTickReschedule

    it "bumps the generation at replacement time so a queued stale tick is dropped even before the replacement's first arm" $ do
      let staleTickGeneration = 1 -- the old session's last-armed generation
          replacementGeneration = staleTickGeneration + 1 -- newReviewSession's construction-time generation
      -- The stale tick is dropped immediately, before the replacement
      -- session has armed any chain of its own.
      decideReviewTickFire replacementGeneration staleTickGeneration ReviewStarting True `shouldBe` ReviewTickStale
      -- Its own eventual first arm mints a generation still further past
      -- the stale tick's, so the collision cannot resurface later either.
      decideReviewTickArm ReviewStarting True False replacementGeneration `shouldBe` ArmReviewTick (replacementGeneration + 1)
      decideReviewTickFire (replacementGeneration + 1) staleTickGeneration ReviewStarting True `shouldBe` ReviewTickStale

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
              reviewSessionSpinnerFrame = 0,
              reviewSessionTickGeneration = 0,
              reviewSessionTickArmed = False,
              reviewSessionFollowing = True
            }
        reconciledPhaseFor issue session =
          (reconcileReviewSessions defaultWorkflowConfig [issue] (Map.singleton issue.issueNumber session) Map.! issue.issueNumber).reviewSessionPhase

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

  describe "live transcript follow state" $ do
    -- issue #39: every output delta used to force its transcript viewport
    -- to the end -- the review path did so even for a hidden overlay or a
    -- background tab -- so scrolling back during a running turn was
    -- impossible. 'tailTranscript', 'scrollTranscript', and
    -- 'presentTranscriptTail' run in brick's 'EventM', which a unit test
    -- cannot drive against a plain state; these cover the pure decisions
    -- those are assembled from: which transcript an overlay displays,
    -- whether an event may tail it, where a scroll gesture lands, which
    -- keys are scroll gestures at all, and what a turn start does.
    let solveOverlay = Just (SolveOverlay 39)
        reviewOverlay = Just (ReviewOverlay 39)
        pullRequestOverlay = Just (PullRequestReviewOverlay 39)
        atBottom = Just (TranscriptGeometry {transcriptTop = 80, transcriptHeight = 20, transcriptContentHeight = 100})
        scrolledUp = Just (TranscriptGeometry {transcriptTop = 50, transcriptHeight = 20, transcriptContentHeight = 100})

    it "maps each transcript overlay to its own session and every other overlay to none" $ do
      displayedTranscript solveOverlay `shouldBe` Just (SolveTranscript 39)
      displayedTranscript reviewOverlay `shouldBe` Just (ReviewTranscript 39)
      displayedTranscript pullRequestOverlay `shouldBe` Just (PullRequestTranscript 39)
      displayedTranscript (Just HelpOverlay) `shouldBe` Nothing
      displayedTranscript (Just ProcessesOverlay) `shouldBe` Nothing
      displayedTranscript Nothing `shouldBe` Nothing

    it "tails the displayed session's output while it is still following" $ do
      transcriptShouldTail solveOverlay (SolveTranscript 39) True `shouldBe` True
      transcriptShouldTail reviewOverlay (ReviewTranscript 39) True `shouldBe` True
      transcriptShouldTail pullRequestOverlay (PullRequestTranscript 39) True `shouldBe` True

    it "preserves the position of a displayed session the user has scrolled back into" $ do
      transcriptShouldTail solveOverlay (SolveTranscript 39) False `shouldBe` False
      transcriptShouldTail reviewOverlay (ReviewTranscript 39) False `shouldBe` False
      transcriptShouldTail pullRequestOverlay (PullRequestTranscript 39) False `shouldBe` False

    it "issues no viewport operation for a session that is not the one on screen" $ do
      -- The review overlay's tabs share a single viewport, so a background
      -- review session's output must not move the displayed tab; the same
      -- holds for a solve or PR session other than the open one.
      transcriptShouldTail reviewOverlay (ReviewTranscript 40) True `shouldBe` False
      transcriptShouldTail solveOverlay (SolveTranscript 40) True `shouldBe` False
      transcriptShouldTail pullRequestOverlay (PullRequestTranscript 40) True `shouldBe` False
      -- A different kind of overlay, or none at all, hides all three.
      transcriptShouldTail reviewOverlay (SolveTranscript 39) True `shouldBe` False
      transcriptShouldTail solveOverlay (ReviewTranscript 39) True `shouldBe` False
      transcriptShouldTail (Just HelpOverlay) (ReviewTranscript 39) True `shouldBe` False
      transcriptShouldTail Nothing (SolveTranscript 39) True `shouldBe` False
      transcriptShouldTail Nothing (PullRequestTranscript 39) True `shouldBe` False

    it "keeps following when the view is already at the bottom" $
      followAfterScroll True atBottom 0 `shouldBe` True

    it "disengages follow on any upward scroll away from the bottom" $ do
      followAfterScroll True atBottom (-1) `shouldBe` False
      followAfterScroll True atBottom (-3) `shouldBe` False

    it "re-engages follow only once a downward scroll actually reaches the bottom" $ do
      followAfterScroll False scrolledUp 3 `shouldBe` False
      followAfterScroll False scrolledUp 29 `shouldBe` False
      followAfterScroll False scrolledUp 30 `shouldBe` True
      -- Overshooting clamps to the bottom the way brick's own scroll does.
      followAfterScroll False scrolledUp 300 `shouldBe` True

    it "treats content shorter than the viewport as always at its bottom" $ do
      let short = Just (TranscriptGeometry {transcriptTop = 0, transcriptHeight = 20, transcriptContentHeight = 5})
      followAfterScroll False short (-3) `shouldBe` True
      followAfterScroll False short 3 `shouldBe` True

    it "leaves follow state alone when the viewport has never been rendered" $ do
      followAfterScroll True Nothing (-3) `shouldBe` True
      followAfterScroll False Nothing 3 `shouldBe` False

    it "recognizes the arrow bindings every transcript overlay shares" $
      mapM_
        ( \reviewChords -> do
            transcriptScrollKey reviewChords (Vty.EvKey Vty.KDown []) `shouldBe` Just 1
            transcriptScrollKey reviewChords (Vty.EvKey Vty.KUp []) `shouldBe` Just (-1)
        )
        [False, True]

    it "recognizes Ctrl-J/Ctrl-K only for the review transcript, which alone binds them" $ do
      transcriptScrollKey True (Vty.EvKey (Vty.KChar 'j') [Vty.MCtrl]) `shouldBe` Just 1
      transcriptScrollKey True (Vty.EvKey (Vty.KChar 'k') [Vty.MCtrl]) `shouldBe` Just (-1)
      transcriptScrollKey False (Vty.EvKey (Vty.KChar 'j') [Vty.MCtrl]) `shouldBe` Nothing
      transcriptScrollKey False (Vty.EvKey (Vty.KChar 'k') [Vty.MCtrl]) `shouldBe` Nothing

    it "leaves typing and the overlays' other bindings out of the scroll path" $
      mapM_
        (\event -> mapM_ (\reviewChords -> transcriptScrollKey reviewChords event `shouldBe` Nothing) [False, True])
        [ Vty.EvKey (Vty.KChar 'j') [],
          Vty.EvKey (Vty.KChar 'k') [],
          Vty.EvKey (Vty.KChar '\t') [],
          Vty.EvKey Vty.KEnter [],
          Vty.EvKey Vty.KBS [],
          Vty.EvKey (Vty.KChar 'c') [Vty.MCtrl]
        ]

    it "runs the wheel through the same follow-state transitions as the arrows" $ do
      -- The wheel reaches all three transcripts through
      -- 'overlayMouseAction', whose amount is handed to the same
      -- 'followAfterScroll' the key bindings use.
      let wheelAmount panel button = case overlayMouseAction panel (VtyEvent (Vty.EvMouseDown 0 0 button [])) of
            Just (OverlayMouseScroll amount) -> Just amount
            _ -> Nothing
      mapM_
        ( \panel -> do
            wheelAmount panel Vty.BScrollUp `shouldBe` Just (-3)
            wheelAmount panel Vty.BScrollDown `shouldBe` Just 3
        )
        [ReviewPanel, SolvePanel, PullRequestReviewPanel]
      followAfterScroll True atBottom (-3) `shouldBe` False
      followAfterScroll False scrolledUp 30 `shouldBe` True

    it "puts terminal output under the same gate as streamed output" $ do
      -- Round-1 review: the completion paths grow a transcript too --
      -- 'SolveProcessFinished'/'PullRequestProcessFinished' append
      -- interruption guidance, the resumable question, or the failure;
      -- 'ReviewTurnCompleted' and 'applyCanonicalIssueReview' append the
      -- verdict; the orphan and disconnect projections append their
      -- markers. Those all now route through 'tailTranscript' rather than
      -- ending silently above the tail, so they answer this same gate:
      -- follow the tail when displayed and engaged, move nothing
      -- otherwise.
      transcriptShouldTail solveOverlay (SolveTranscript 39) True `shouldBe` True
      transcriptShouldTail pullRequestOverlay (PullRequestTranscript 39) True `shouldBe` True
      transcriptShouldTail reviewOverlay (ReviewTranscript 39) True `shouldBe` True
      transcriptShouldTail solveOverlay (SolveTranscript 39) False `shouldBe` False
      transcriptShouldTail Nothing (SolveTranscript 39) True `shouldBe` False
      transcriptShouldTail reviewOverlay (ReviewTranscript 40) True `shouldBe` False

    it "re-engages follow when a genuinely new review turn starts" $ do
      followAfterTurnStarted False (Just "turn-1") "turn-2" `shouldBe` True
      followAfterTurnStarted False Nothing "turn-1" `shouldBe` True

    it "does not treat a repeated notification for the running turn as a new turn" $ do
      -- The backend can send a matching 'ReviewTurnStarted' after a
      -- question is answered (see the same-turn coverage above), which
      -- must not discard a deliberate scrollback.
      followAfterTurnStarted False (Just "turn-1") "turn-1" `shouldBe` False
      followAfterTurnStarted True (Just "turn-1") "turn-1" `shouldBe` True

  describe "repository identity parsing" $ do
    it "parses an HTTPS GitHub remote" $
      parseRemoteRepository "https://github.com/coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
    it "parses an SSH GitHub remote" $
      parseRemoteRepository "git@github.com:coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
    it "parses explicit OWNER/NAME syntax" $
      parseRepositoryName "coghex/kanban" `shouldBe` Right ("coghex", "kanban")

    it "parses every promised GitHub remote grammar" $ do
      -- Each supported scheme, with and without the optional userinfo,
      -- numeric port, '.git' suffix, and trailing slash.
      parseRemoteRepository "https://github.com/coghex/kanban" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "https://github.com/coghex/kanban/" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "https://github.com:443/coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "https://www.github.com/coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "ssh://git@github.com/coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "ssh://git@github.com:22/coghex/kanban" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "git://github.com/coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "git://github.com:9418/coghex/kanban" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "git@github.com:coghex/kanban" `shouldBe` Right ("coghex", "kanban")

    it "compares the remote host case-insensitively, as DNS does" $ do
      parseRemoteRepository "HTTPS://GitHub.COM/coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "git@GITHUB.com:coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")

    it "rejects a local or relative remote path instead of guessing an owner" $ do
      -- The bug this guards: a bare mirror parsed to ("team", "myrepo") and
      -- the dashboard then rendered an unrelated github.com/team/myrepo.
      parseRemoteRepository "/srv/git/team/myrepo.git" `shouldSatisfy` rejectsWithGuidance "/srv/git/team/myrepo.git"
      parseRemoteRepository "../local-fork" `shouldSatisfy` rejectsWithGuidance "../local-fork"
      parseRemoteRepository "team/myrepo" `shouldSatisfy` rejectsWithGuidance "team/myrepo"

    it "rejects remotes hosted anywhere other than github.com" $ do
      parseRemoteRepository "https://gitlab.com/coghex/kanban.git"
        `shouldSatisfy` rejectsWithGuidance "https://gitlab.com/coghex/kanban.git"
      parseRemoteRepository "https://git.corp.example.test/coghex/kanban.git"
        `shouldSatisfy` rejectsWithGuidance "git.corp.example.test"
      -- A deceptive suffix host: github.com is a label here, not the domain.
      parseRemoteRepository "https://github.com.example.test/coghex/kanban.git"
        `shouldSatisfy` rejectsWithGuidance "github.com.example.test"
      parseRemoteRepository "gh-alias:coghex/kanban" `shouldSatisfy` rejectsWithGuidance "gh-alias:coghex/kanban"

    it "rejects GitHub remotes whose path is not exactly OWNER/NAME" $ do
      parseRemoteRepository "https://github.com/coghex/kanban/tree/master"
        `shouldSatisfy` rejectsWithGuidance "tree/master"
      parseRemoteRepository "https://github.com/coghex" `shouldSatisfy` rejectsWithGuidance "https://github.com/coghex"
      -- SCP-style syntax has no port: the colon begins the path.
      parseRemoteRepository "git@github.com:22/coghex/kanban"
        `shouldSatisfy` rejectsWithGuidance "git@github.com:22/coghex/kanban"
      -- A trailing query cannot smuggle punctuation into the GraphQL query.
      parseRemoteRepository "https://github.com/coghex/kanban?owner=evil"
        `shouldSatisfy` rejectsWithGuidance "kanban?owner=evil"

    it "rejects a plaintext http remote, which is outside the supported schemes" $
      parseRemoteRepository "http://github.com/coghex/kanban.git"
        `shouldSatisfy` rejectsWithGuidance "http://github.com/coghex/kanban.git"

    it "accepts a relative OWNER/NAME only when the user supplied it explicitly" $ do
      -- Same text, different source: an inherited remote must not be
      -- trusted to name a GitHub repository, but --repo is a deliberate choice.
      parseRepositoryName "team/myrepo" `shouldBe` Right ("team", "myrepo")
      parseRemoteRepository "team/myrepo" `shouldSatisfy` rejectsWithGuidance "team/myrepo"

    it "still rejects an explicit --repo value that names no GitHub repository" $ do
      parseRepositoryName "/srv/git/team/myrepo.git" `shouldSatisfy` isLeft
      parseRepositoryName "https://gitlab.com/coghex/kanban.git" `shouldSatisfy` isLeft
      -- An explicit GitHub URL keeps working, as it did before validation.
      parseRepositoryName "https://github.com/coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")

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

    it "shows labeled trackers without children as empty headers" $ do
      let tracker = (baseIssue 12 []) {issueLabels = [Label "epic" "5319e7"]}
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [tracker] [] epoch False False)
      case Map.findWithDefault [] Issues columns of
        [TrackerHeader rendered] -> do
          rendered.trackerIssue.issueNumber `shouldBe` 12
          rendered.trackerTotal `shouldBe` 0
          rendered.trackerDiagnostics `shouldBe` [TrackerSectionMissing]
        entries -> expectationFailure ("unexpected issue entries: " <> show entries)

    -- §8: a configured tracker label keeps the issue out of the work cards
    -- however its checklist parsed. The one malformed row here is diagnosed
    -- and dropped, so the tracker reaches 'deriveBoard' with no children of
    -- its own while #3 falls back to Standalone per §17.
    it "keeps a tracker whose checklist parsed to nothing out of every column's work cards" $ do
      let snapshot = RepoSnapshot [zeroChildTracker, baseIssue 3 []] [] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
          workCards = filter (not . isTrackerHeaderEntry) (concat (Map.elems columns))
      map (itemNumber . entryItem) workCards `shouldBe` [3]
      case Map.findWithDefault [] Issues columns of
        [TrackerHeader rendered, standalone] -> do
          rendered.trackerIssue.issueNumber `shouldBe` 12
          rendered.trackerTotal `shouldBe` 0
          rendered.trackerDiagnostics `shouldBe` zeroChildDiagnostics
          standalone `shouldBe` Standalone (IssueItem (baseIssue 3 []))
        entries -> expectationFailure ("unexpected issue entries: " <> show entries)

    -- A childless header is structure, not work in progress, so it has no
    -- business competing for a slot in Active just because someone is
    -- assigned to the tracker issue.
    it "places an assigned zero-child tracker in Issues rather than Active" $ do
      let tracker = zeroChildTracker {issueAssignees = [Assignee "agent"]}
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [tracker] [] epoch False False)
      Map.findWithDefault [] Active columns `shouldBe` []
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [12]

    it "recognizes zero-child trackers by configured label rather than a hard-coded epic" $ do
      let config = defaultWorkflowConfig {trackerLabels = Set.singleton "tracker"}
          configured = zeroChildTracker {issueNumber = 20, issueLabels = [Label "tracker" "5319e7"]}
          Board columns = deriveBoard config (RepoSnapshot [configured, zeroChildTracker] [] epoch False False)
      case Map.findWithDefault [] Issues columns of
        [TrackerHeader rendered, epicLabelled] -> do
          rendered.trackerIssue.issueNumber `shouldBe` 20
          rendered.trackerDiagnostics `shouldBe` zeroChildDiagnostics
          -- "epic" is not configured here, so that issue is ordinary work.
          epicLabelled `shouldBe` Standalone (IssueItem zeroChildTracker)
        entries -> expectationFailure ("unexpected issue entries: " <> show entries)

    it "uses an Epic: title as a tracker fallback when the issue has no labels" $ do
      let tracker = (baseIssue 12 []) {issueTitle = "Epic: Legacy tracker"}
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [tracker] [] epoch False False)
      Map.findWithDefault [] Issues columns `shouldSatisfy` \case [TrackerHeader _] -> True; _ -> False

    it "keeps an open tracker visible as a header when none of its children are on the live board" $ do
      let tracker =
            (baseIssue 12 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #2 — A1: Child outside the live board"
              }
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [tracker] [] epoch False False)
      Map.findWithDefault [] Issues columns `shouldBe` [TrackerHeader (Tracker tracker 1 1 Map.empty [])]

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

  describe "epic collapse selection normalization" $ do
    it "moves another column's remembered row to the tracker's first row there once collapse hides it" $ do
      let issuesEntries = [fixtureTrackedEntry 100 [] 1, fixtureTrackedEntry 100 [] 2]
          activeEntries = [fixtureTrackedEntry 100 [] 3, fixtureTrackedEntry 100 [] 4]
          board = fixtureBoard [(Issues, issuesEntries), (Active, activeEntries)]
          -- Active's remembered row is #4 (row 1), a non-first child of #100.
          selectedBeforeCollapse = Map.fromList [(Issues, 0), (Active, 1)]
          expandedAfterCollapse = Set.empty
      normalizeSelectedRowsAfterToggle expandedAfterCollapse board selectedBeforeCollapse
        `shouldBe` Map.fromList [(Issues, 0), (Active, 0)]

    it "leaves a column empty of that tracker at row zero" $ do
      let board = fixtureBoard [(Issues, [fixtureTrackedEntry 100 [] 1])]
      normalizeCollapsedRow Set.empty board Done 0 `shouldBe` 0

    it "does not move a selection under a still-expanded tracker, a standalone card, or an entry only additionally tracking the collapsed epic" $ do
      let activeEntries =
            [ fixtureTrackedEntry 200 [] 6, -- row 0: unrelated, still-expanded tracker
              fixtureTrackedEntry 200 [100] 7, -- row 1: primary tracker 200; 100 is only an additional membership
              fixtureStandaloneEntry 5 -- row 2: unrelated standalone card
            ]
          board = fixtureBoard [(Active, activeEntries)]
          expandedAfterCollapse = Set.singleton 200
      normalizeCollapsedRow expandedAfterCollapse board Active 0 `shouldBe` 0
      normalizeCollapsedRow expandedAfterCollapse board Active 1 `shouldBe` 1
      normalizeCollapsedRow expandedAfterCollapse board Active 2 `shouldBe` 2

    it "leaves every column's remembered row unchanged when expanding" $ do
      let issuesEntries = [fixtureTrackedEntry 100 [] 1, fixtureTrackedEntry 100 [] 2]
          activeEntries = [fixtureStandaloneEntry 5]
          board = fixtureBoard [(Issues, issuesEntries), (Active, activeEntries)]
          selected = Map.fromList [(Issues, 1), (Active, 0)]
          expandedAfterExpand = Set.singleton 100
      normalizeSelectedRowsAfterToggle expandedAfterExpand board selected `shouldBe` selected

    it "leaves the affected column's remembered row on a visible entry, so moveCard advances past the collapsed group instead of defaulting to the top" $ do
      let activeEntries =
            [ fixtureTrackedEntry 100 [] 3, -- row 0: first child of #100, the collapsed header row
              fixtureTrackedEntry 100 [] 4, -- row 1: stale remembered row, hidden by the collapse
              fixtureStandaloneEntry 5 -- row 2: next visible target after the collapsed group
            ]
          board = fixtureBoard [(Active, activeEntries)]
          expandedAfterCollapse = Set.empty
          normalizedRow = normalizeCollapsedRow expandedAfterCollapse board Active 1
          rows = visibleSelectionRows expandedAfterCollapse board Active
          currentPosition = maybe 0 id (findIndex (== normalizedRow) rows)
      normalizedRow `shouldBe` 0
      rows `shouldBe` [0, 2]
      currentPosition `shouldBe` 0
      (rows !! (currentPosition + 1)) `shouldBe` 2

  -- A tracker with no children has no child card to be reached through, so
  -- the header itself has to carry every interaction §12 and §17 promise.
  describe "zero-child tracker headers" $ do
    it "is a keyboard focus target with no epic expanded" $ do
      let board = deriveBoard defaultWorkflowConfig (RepoSnapshot [zeroChildTracker, baseIssue 3 []] [] epoch False False)
      visibleSelectionRows Set.empty board Issues `shouldBe` [0, 1]
      normalizeCollapsedRow Set.empty board Issues 0 `shouldBe` 0

    it "draws amber while a tracker that parsed cleanly keeps the ordinary accent" $ do
      let Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [zeroChildTracker] [] epoch False False)
      case Map.findWithDefault [] Issues columns of
        [TrackerHeader rendered] -> trackerHeaderAttribute rendered `shouldBe` pendingAttr
        entries -> expectationFailure ("unexpected issue entries: " <> show entries)
      trackerHeaderAttribute (fixtureTracker 100) `shouldBe` trackerAttr

    it "keeps its details overlay open across a refresh while the tracker issue stays open" $ do
      let board = deriveBoard defaultWorkflowConfig (RepoSnapshot [zeroChildTracker] [] epoch False False)
          closed = deriveBoard defaultWorkflowConfig (RepoSnapshot [] [] epoch False False)
          overlay = Just (DetailsOverlay (IssueItem zeroChildTracker))
      refreshOverlay board overlay `shouldBe` (overlay, Nothing)
      refreshOverlay closed overlay `shouldBe` (Nothing, Just "Details closed because that item is no longer open")

    -- The overlay reads the diagnostics 'deriveBoard' attached to the header
    -- rather than re-parsing the body, so a tracker recognized only by a
    -- non-default configured label still explains itself here even though a
    -- re-parse under the default config would not recognize it at all.
    it "lists the diagnostics the derived tracker retained rather than a re-parse" $ do
      let config = defaultWorkflowConfig {trackerLabels = Set.singleton "tracker"}
          tracker = zeroChildTracker {issueLabels = [Label "tracker" "5319e7"]}
          board = deriveBoard config (RepoSnapshot [tracker] [] epoch False False)
      detailsRows (renderDetails board (IssueItem tracker)) "Tracker warnings"
        `shouldBe` map (("• " <>) . renderTrackerDiagnostic) zeroChildDiagnostics

  describe "tracker checklist parsing" $ do
    it "parses supported checkboxes, progress, and natural keys only in tracker sections" $ do
      let body =
            "## Related\n- [ ] #99 — A1: Ignore\n"
              <> "## Children\n### Phase A\n- [ ] #2 — **A10:** Later\n- [x] **#1 — A2: Earlier**\n"
              <> "External prerequisite:\n- [ ] #77 — A3: Ignore\n"
          children = parseTrackerChildren [] body
      map (.trackerChildIssueNumber) children `shouldBe` [2, 1]
      map (.trackerChildComplete) children `shouldBe` [False, True]
      map (.trackerChildImplementationKey) (sortOn implementationSortKey children) `shouldBe` [Just "A2", Just "A10"]

    it "reports structural checklist loss while retaining valid children" $ do
      let body = "## Children\n- [ ] #2 — A1: Valid\n- [ ] missing reference\n- [?] #3\n- [x] #2 — duplicate"
          (children, diagnostics) = parseTrackerBody [] body
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
      snd (parseTrackerBody [] body) `shouldBe` [TrackerSectionMissing]
      snapshotWarnings defaultLimitsConfig defaultWorkflowConfig (RepoSnapshot [tracker] [] epoch False False)
        `shouldSatisfy` any (Data.Text.isInfixOf "1 tracker")

    it "recognizes a configured additional tracker-section heading" $ do
      let body = "## Milestones\n- [ ] #2 — A1: Valid"
      snd (parseTrackerBody [] body) `shouldBe` [TrackerSectionMissing]
      snd (parseTrackerBody ["Milestones"] body) `shouldBe` []
      map (.trackerChildIssueNumber) (parseTrackerChildren ["Milestones"] body) `shouldBe` [2]
      map (.trackerChildIssueNumber) (parseTrackerChildren [] body) `shouldBe` []

    it "recognizes a tracker heading that explicitly names children" $ do
      let body = "## Remaining core work — children filed\n- [ ] #2 — A1: Valid"
      map (.trackerChildIssueNumber) (parseTrackerChildren [] body) `shouldBe` [2]

    it "recognizes bare Phase, prefixed Phases, and Phase breakdown as tracker sections" $ do
      let childrenOf body = map (.trackerChildIssueNumber) (parseTrackerChildren [] body)
      childrenOf "## Phase\n- [ ] #2 — A1: Valid" `shouldBe` [2]
      childrenOf "## Phases\n- [ ] #2 — A1: Valid" `shouldBe` [2]
      childrenOf "## Phases (ordered)\n- [ ] #2 — A1: Valid" `shouldBe` [2]
      let breakdown = "## Phase breakdown\n- [ ] #2 — A1: Valid"
      childrenOf breakdown `shouldBe` [2]
      snd (parseTrackerBody [] breakdown) `shouldBe` []

    it "keeps every documented heading form recognized: Children, Children (ordered), Phase plan, Phase 1, and Phase A" $ do
      let childrenOf body = map (.trackerChildIssueNumber) (parseTrackerChildren [] body)
      childrenOf "## Children\n- [ ] #2 — A1: Valid" `shouldBe` [2]
      childrenOf "## Children (ordered)\n- [ ] #2 — A1: Valid" `shouldBe` [2]
      childrenOf "## Phase plan\n- [ ] #2 — A1: Valid" `shouldBe` [2]
      childrenOf "## Phase 1\n- [ ] #2 — A1: Valid" `shouldBe` [2]
      childrenOf "## Phase A\n- [ ] #2 — A1: Valid" `shouldBe` [2]

    it "does not recognize a heading that merely starts with the word phase, such as Phased rollout" $ do
      let body = "## Phased rollout\n- [ ] #2 — A1: Ignored"
      parseTrackerChildren [] body `shouldBe` []
      snd (parseTrackerBody [] body) `shouldBe` [TrackerSectionMissing]

    it "keeps every documented checklist format parsing around prose that merely opens with an excluded word" $ do
      let surrounded sentence =
            "## Children\n"
              <> sentence
              <> "\n- [ ] #756 — **A1:** Define the persistence contract.\n"
              <> "- [ ] #742 — A1: Modal ownership with debug pass-through\n"
              <> sentence
              <> "\n- [x] **#88 — Data-driven location definitions**\n"
          childrenOf body = map (.trackerChildIssueNumber) (parseTrackerChildren [] body)
      childrenOf (surrounded "Related discussion happens in #100.") `shouldBe` [756, 742, 88]
      childrenOf (surrounded "External prerequisite work already landed.") `shouldBe` [756, 742, 88]
      childrenOf (surrounded "Out of scope items are tracked elsewhere.") `shouldBe` [756, 742, 88]
      snd (parseTrackerBody [] (surrounded "Related discussion happens in #100.")) `shouldBe` []

    it "excludes checklists under bare, bold, and underscored excluded pseudo-headings" $ do
      let excludedBy label = "## Children\n- [ ] #1 — A1: Kept\n" <> label <> "\n- [ ] #99 — A2: Ignored\n"
          childrenOf body = map (.trackerChildIssueNumber) (parseTrackerChildren [] body)
      childrenOf (excludedBy "Related:") `shouldBe` [1]
      childrenOf (excludedBy "**Related:**") `shouldBe` [1]
      childrenOf (excludedBy "**Related**:") `shouldBe` [1]
      childrenOf (excludedBy "_Related:_") `shouldBe` [1]
      childrenOf (excludedBy "*External prerequisites:*") `shouldBe` [1]
      childrenOf (excludedBy "__Out of scope__") `shouldBe` [1]

    it "ends a pseudo-heading exclusion at the next pseudo-heading or a deeper real heading" $ do
      let resumedBy resumption =
            "## Children\n- [ ] #1 — A1: Kept\n**Related:**\n- [ ] #99 — Ignored\n"
              <> resumption
              <> "\n- [ ] #2 — A2: Kept\n"
          childrenOf body = map (.trackerChildIssueNumber) (parseTrackerChildren [] body)
      childrenOf (resumedBy "**Remaining:**") `shouldBe` [1, 2]
      childrenOf (resumedBy "### Remaining") `shouldBe` [1, 2]
      childrenOf (resumedBy "## Remaining") `shouldBe` [1]

    it "leaves checklist diagnostics unreported inside an excluded pseudo-heading subsection" $ do
      let body = "## Children\n**Related:**\n- [ ] no reference\n- [?] #3\n- [ ] #2 — A1: Ignored\n"
      parseTrackerBody [] body `shouldBe` ([], [TrackerChildrenMissing])

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
          pullRequest.pullRequestChecks `shouldBe` ChecksFailed 1 2 [CheckDetail "review-approved" CheckFailed]
          let warnings = snapshotWarnings defaultLimitsConfig defaultWorkflowConfig (RepoSnapshot [issue] [pullRequest] epoch True True)
          length warnings `shouldBe` 3
          warnings `shouldSatisfy` any (Data.Text.isInfixOf "+N markers")
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    it "reports configured truncation caps in the board's GitHub warnings" $ do
      let configuredLimits = LimitsConfig {limitsMaxOpenIssues = 5, limitsMaxOpenPullRequests = 9, limitsExcerptLines = 3}
          warnings = snapshotWarnings configuredLimits defaultWorkflowConfig (RepoSnapshot [] [] epoch True True)
      warnings `shouldSatisfy` any (Data.Text.isInfixOf "5+ open issues")
      warnings `shouldSatisfy` any (Data.Text.isInfixOf "9+ open pull requests")

    it "deduplicates rerun checks and treats mergeable policy blocks as protected" $ do
      case decodeGitHubItems (LazyByteString.pack githubRerunResponse) of
        Left message -> expectationFailure message
        Right ([], [pullRequest]) -> do
          pullRequest.pullRequestChecks `shouldBe` ChecksPassed 3
          pullRequest.pullRequestMergeState `shouldBe` MergeProtected
          pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusReady
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- The retained per-check list must come out of the same latest-by-identity
    -- selection the aggregate counts use, or a superseded failure could be
    -- listed beside a passing aggregate.
    it "retains only the latest non-passing check of each identity for the details overlay" $ do
      case decodeGitHubItems (LazyByteString.pack githubMixedChecksResponse) of
        Left message -> expectationFailure message
        Right ([], [pullRequest]) ->
          pullRequest.pullRequestChecks
            `shouldBe` ChecksFailed
              1
              3
              [ CheckDetail "integration-suite" CheckFailed,
                CheckDetail "smoke" CheckPending
              ]
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    it "keeps a rollup past the context cap unknown rather than retaining the partial nodes it saw" $ do
      case decodeGitHubItems (LazyByteString.pack githubCappedChecksResponse) of
        Left message -> expectationFailure message
        Right ([], [pullRequest]) -> pullRequest.pullRequestChecks `shouldBe` ChecksUnknown
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

  describe "GraphQL argument construction" $ do
    -- GitHub permits all-numeric accounts and repositories, and gh's typed
    -- -F flag coerces all-digit values to Int and true/false to Boolean.
    -- The fixture below is the worst case: every String! variable holds a
    -- value that -F would coerce into a type the query rejects.
    let numericRepository = Repository "/tmp/board" "12345" "2048"
        pagedState =
          FetchState
            { fetchedIssues = [],
              fetchedPullRequests = [],
              issueCursor = Just "42",
              pullRequestCursor = Just "true",
              fetchMoreIssues = True,
              fetchMorePullRequests = True,
              issuesTruncated = False,
              pullRequestsTruncated = False
            }
        firstPageState = pagedState {issueCursor = Nothing, pullRequestCursor = Nothing}
        pagedArguments = graphqlArguments defaultLimitsConfig numericRepository pagedState

    it "passes every GraphQL String variable raw" $ do
      flagForVariable "owner" pagedArguments `shouldBe` Just "-f"
      flagForVariable "name" pagedArguments `shouldBe` Just "-f"
      flagForVariable "issueCursor" pagedArguments `shouldBe` Just "-f"
      flagForVariable "pullRequestCursor" pagedArguments `shouldBe` Just "-f"
      flagForVariable "query" pagedArguments `shouldBe` Just "-f"

    it "keeps the genuinely typed variables on the typed flag" $ do
      flagForVariable "issuePageSize" pagedArguments `shouldBe` Just "-F"
      flagForVariable "pullRequestPageSize" pagedArguments `shouldBe` Just "-F"
      flagForVariable "fetchIssues" pagedArguments `shouldBe` Just "-F"
      flagForVariable "fetchPullRequests" pagedArguments `shouldBe` Just "-F"

    it "carries coercible owner, name, and cursor values through verbatim" $ do
      pagedArguments `shouldContain` ["-f", "owner=12345"]
      pagedArguments `shouldContain` ["-f", "name=2048"]
      pagedArguments `shouldContain` ["-f", "issueCursor=42"]
      pagedArguments `shouldContain` ["-f", "pullRequestCursor=true"]

    it "omits absent cursors so the first request starts at the first page" $ do
      let firstPageArguments = graphqlArguments defaultLimitsConfig numericRepository firstPageState
      flagForVariable "issueCursor" firstPageArguments `shouldBe` Nothing
      flagForVariable "pullRequestCursor" firstPageArguments `shouldBe` Nothing

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

    it "round-trips the retained per-check detail" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
              pullRequest =
                (basePullRequest 823 [36] False [])
                  { pullRequestChecks =
                      ChecksFailed 9 12 [CheckDetail "integration-suite" CheckFailed, CheckDetail "docs-lint" CheckPending]
                  }
              snapshot = RepoSnapshot [] [pullRequest] epoch False False
          writeRepositoryCache repository snapshot `shouldReturn` Right ()
          loadRepositoryCache repository `shouldReturn` CacheLoaded snapshot

    -- A real version 2 file wrote its check summaries as two aggregate counts,
    -- so its snapshot cannot decode under the current schema at all. The
    -- version has to be read before the snapshot, or the user is told the file
    -- is malformed JSON when the truthful answer is that it is simply old.
    it "rejects a genuine version 2 file as unsupported rather than as malformed" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
          -- Write a current cache first, so the old file lands where the
          -- loader looks for it.
          writeRepositoryCache repository (RepoSnapshot [] [] epoch False False) `shouldReturn` Right ()
          cachePath <- repositoryCachePath repository
          ByteString.writeFile cachePath (versionTwoCacheFile 2)
          loadRepositoryCache repository `shouldReturn` CacheInvalid "cache ignored: unsupported schema version"
          -- Proof the version gate is what rejected it: relabel that same
          -- old-shaped file as current, and the snapshot decode fails instead.
          ByteString.writeFile cachePath (versionTwoCacheFile repositoryCacheSchemaVersion)
          relabeled <- loadRepositoryCache repository
          relabeled `shouldSatisfy` isInvalidCache
          relabeled `shouldNotBe` CacheInvalid "cache ignored: unsupported schema version"

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

    -- issue #48: approved + BEHIND must report checks-pending before
    -- merge-pending whenever checks are not yet ready, since a still-running
    -- check is more actionable information than a stale branch.
    it "reports checks-pending before merge-pending when approved, behind, and checks are still pending" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeBehind, pullRequestChecks = ChecksPending 1 2 [CheckDetail "build" CheckPending]}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusPending "checks pending"
    it "reports merge-pending once approved, behind, and checks have already passed" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeBehind, pullRequestChecks = ChecksPassed 4}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusPending "merge pending"

    it "defaults blocking severity to red, preserving the existing problem presentation" $ do
      let pullRequest = basePullRequest 10 [] False [Label "reviewed:changes" "ff0000"]
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusProblem "blocked"
      isProblem defaultWorkflowConfig (PullRequestItem pullRequest) `shouldBe` True
    it "renders and sorts a configured amber blocking severity as pending rather than a problem" $ do
      let config = defaultWorkflowConfig {blockingSeverity = SeverityAmber}
          pullRequest = basePullRequest 10 [] False [Label "reviewed:changes" "ff0000"]
      pullRequestStatus config pullRequest `shouldBe` StatusPending "blocked"
      isProblem config (PullRequestItem pullRequest) `shouldBe` False

    it "reorders standalone board entries when amber blocking severity drops a blocked PR out of the problem bucket" $ do
      let blocked = (basePullRequest 10 [] False [Label "reviewed:changes" "ff0000"]) {pullRequestCreatedAt = addUTCTime 3600 epoch}
          neutral = basePullRequest 11 [] False []
          snapshot = RepoSnapshot [] [blocked, neutral] epoch False False
          Board redColumns = deriveBoard defaultWorkflowConfig snapshot
          amberConfig = defaultWorkflowConfig {blockingSeverity = SeverityAmber}
          Board amberColumns = deriveBoard amberConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing redColumns) `shouldBe` [10, 11]
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing amberColumns) `shouldBe` [11, 10]

    it "reorders tracker groups when amber blocking severity drops a blocked child PR out of the problem bucket" $ do
      let blockedTracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #1 — A1: Child",
                issueCreatedAt = addUTCTime 3600 epoch
              }
          neutralTracker =
            (baseIssue 200 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #2 — A1: Child",
                issueCreatedAt = epoch
              }
          blockedPr = basePullRequest 10 [1] False [Label "reviewed:changes" "ff0000"]
          neutralPr = basePullRequest 11 [2] False []
          snapshot = RepoSnapshot [blockedTracker, neutralTracker, baseIssue 1 [], baseIssue 2 []] [blockedPr, neutralPr] epoch False False
          Board redColumns = deriveBoard defaultWorkflowConfig snapshot
          amberConfig = defaultWorkflowConfig {blockingSeverity = SeverityAmber}
          Board amberColumns = deriveBoard amberConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing redColumns) `shouldBe` [10, 11]
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing amberColumns) `shouldBe` [11, 10]

    it "leaves an unapproved PR with pending checks neutral rather than showing checks-pending" $ do
      let pullRequest = (basePullRequest 10 [] False []) {pullRequestChecks = ChecksPending 1 2 [CheckDetail "build" CheckPending]}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusNeutral

    it "renders an approved, amber-blocked PR's card as pending rather than approved" $ do
      let amberConfig = defaultWorkflowConfig {blockingSeverity = SeverityAmber}
          pullRequest = basePullRequest 10 [] False [Label "reviewed:approve" "00ff00", Label "reviewed:changes" "ff0000"]
      pullRequestCardAttribute amberConfig pullRequest `shouldBe` pendingAttr
      pullRequestCardAttribute amberConfig pullRequest `shouldNotBe` approvedAttr
      cardInteriorAttribute (pullRequestCardAttribute amberConfig pullRequest) `shouldBe` neutralAttr

    it "renders a fully ready, approved PR's card as ready with an approved interior wash" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeClean, pullRequestChecks = ChecksPassed 4}
      pullRequestCardAttribute defaultWorkflowConfig pullRequest `shouldBe` readyAttr
      cardInteriorAttribute (pullRequestCardAttribute defaultWorkflowConfig pullRequest) `shouldBe` approvedInteriorAttr

    it "keeps a red-severity blocked PR's card as a problem, with a neutral interior" $ do
      let pullRequest = basePullRequest 10 [] False [Label "reviewed:approve" "00ff00", Label "reviewed:changes" "ff0000"]
      pullRequestCardAttribute defaultWorkflowConfig pullRequest `shouldBe` problemAttr
      cardInteriorAttribute (pullRequestCardAttribute defaultWorkflowConfig pullRequest) `shouldBe` neutralAttr

    it "confines configurable blocking severity to pull requests, leaving blocked-issue treatment unchanged" $ do
      let issue = (baseIssue 10 []) {issueLabels = [Label "blocked" "d73a4a"]}
      isProblem defaultWorkflowConfig (IssueItem issue) `shouldBe` True
      isProblem (defaultWorkflowConfig {blockingSeverity = SeverityAmber}) (IssueItem issue) `shouldBe` True

    it "reports merge-pending, not checks-pending, when checks are unknown rather than a known pending state" $ do
      let pullRequest = (basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]) {pullRequestMergeState = MergeBehind, pullRequestChecks = ChecksUnknown}
      pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusPending "merge pending"

    it "lets a configured approval label change Done-column membership" $ do
      let config = defaultWorkflowConfig {approvalLabel = "lgtm"}
          pullRequest = basePullRequest 10 [] False [Label "lgtm" "00ff00"]
          snapshot = RepoSnapshot [] [pullRequest] epoch False False
          Board customColumns = deriveBoard config snapshot
          Board defaultColumns = deriveBoard defaultWorkflowConfig snapshot
      map itemNumber (map entryItem (Map.findWithDefault [] Done customColumns)) `shouldBe` [10]
      map itemNumber (map entryItem (Map.findWithDefault [] Done defaultColumns)) `shouldBe` []

  describe "cache precedence" $ do
    it "lets --no-cache disable the cache even when configuration enables it" $
      cacheEnabled (testOptions {optionNoCache = True}) (testResolvedConfig {resolvedCache = True}) `shouldBe` False
    it "lets configuration disable the cache without --no-cache" $
      cacheEnabled (testOptions {optionNoCache = False}) (testResolvedConfig {resolvedCache = False}) `shouldBe` False
    it "enables the cache only when neither --no-cache nor configuration disables it" $
      cacheEnabled (testOptions {optionNoCache = False}) (testResolvedConfig {resolvedCache = True}) `shouldBe` True

  describe "configured provider timeouts and excerpt height reaching their runtime consumers" $ do
    it "converts the configured GitHub timeout from seconds to the microseconds System.Timeout.timeout takes" $
      githubRefreshTimeoutMicros (testResolvedConfig {resolvedTimeouts = TimeoutsConfig 5 7 9}) `shouldBe` 5000000
    it "converts the configured Codex timeout from seconds to microseconds" $
      codexRefreshTimeoutMicros (testResolvedConfig {resolvedTimeouts = TimeoutsConfig 5 7 9}) `shouldBe` 7000000
    it "converts the configured Claude timeout from seconds to microseconds" $
      claudeRefreshTimeoutMicros (testResolvedConfig {resolvedTimeouts = TimeoutsConfig 5 7 9}) `shouldBe` 9000000
    it "passes the configured excerpt line count through to the card-rendering limit" $ do
      cardExcerptLimit (testResolvedConfig {resolvedLimits = LimitsConfig 250 100 3}) `shouldBe` 3
      cardExcerptLimit (testResolvedConfig {resolvedLimits = LimitsConfig 250 100 9}) `shouldBe` 9

  describe "card line budgeting" $ do
    it "keeps a wrapped excerpt within its line budget and marks the truncation" $ do
      boundedLines 10 3 "alpha beta gamma delta epsilon zeta" `shouldBe` ["alpha beta", "gamma", "delta…"]
      boundedLines 10 3 "alpha beta gamma delta" `shouldBe` ["alpha beta", "gamma", "delta"]

    it "leaves text that fits untouched, so an ellipsis only ever means dropped content" $ do
      boundedLines 10 3 "alpha beta gamma" `shouldBe` ["alpha beta", "gamma"]
      boundedLines 10 2 "" `shouldBe` []

    it "reflows to the width it is given rather than to a fixed layout" $ do
      boundedLines 5 3 "alpha beta gamma delta" `shouldBe` ["alpha", "beta", "gamm…"]
      boundedLines 22 3 "alpha beta gamma delta" `shouldBe` ["alpha beta gamma delta"]

    it "caps a title at two lines the same way, so it cannot crowd out the excerpt" $
      boundedLines 12 2 "#812  Modal input leaks through the overlay"
        `shouldBe` ["#812 Modal", "input leaks…"]

    it "measures display cells, not characters, so wide glyphs cannot overrun the border" $ do
      boundedLines 5 3 (Data.Text.replicate 8 "漢") `shouldBe` ["漢漢", "漢漢", "漢漢…"]
      map displayWidth (boundedLines 5 3 (Data.Text.replicate 8 "漢")) `shouldBe` [4, 4, 5]

    it "packs whole label chips into two rows and counts the rest into +N" $
      labelChipRows 20 2 ["alpha", "beta", "gamma", "delta", "epsilon"] 0
        `shouldBe` [ [LabelChip "alpha", LabelChip "beta"],
                     [LabelChip "gamma", LabelChip "delta", OverflowChip 1]
                   ]

    it "adds the overflow GitHub itself reported to the chips it could not place" $ do
      labelChipRows 20 2 ["alpha", "beta"] 4 `shouldBe` [[LabelChip "alpha", LabelChip "beta", OverflowChip 4]]
      labelChipRows 20 2 ["alpha", "beta", "gamma", "delta", "epsilon"] 3
        `shouldBe` [ [LabelChip "alpha", LabelChip "beta"],
                     [LabelChip "gamma", LabelChip "delta", OverflowChip 4]
                   ]

    it "omits and counts a chip too wide for a whole row rather than cropping it" $
      labelChipRows 10 2 ["a-very-long-label", "beta"] 0 `shouldBe` [[LabelChip "beta", OverflowChip 1]]

    it "gives the marker a spare row when the last one is full" $
      labelChipRows 16 2 ["alpha", "beta"] 1 `shouldBe` [[LabelChip "alpha", LabelChip "beta"], [OverflowChip 1]]

    it "evicts a trailing chip when that is the only way to show a whole marker" $
      labelChipRows 16 1 ["alpha", "beta"] 1 `shouldBe` [[LabelChip "alpha", OverflowChip 2]]

    it "orders workflow-status labels first and the remaining labels alphabetically" $ do
      let labels =
            [ Label "ui" "5319e7",
              Label "bug" "d73a4a",
              Label "reviewed:approve" "2f9e44",
              Label "Blocked" "b60205",
              Label "architecture" "0e8a16"
            ]
      map (.labelName) (orderCardLabels defaultWorkflowConfig labels)
        `shouldBe` ["reviewed:approve", "Blocked", "architecture", "bug", "ui"]

  describe "rendered cards" $ do
    it "shows every §11 element inside a frame sized to its own content" $ do
      let rendered = renderCard testOptions False cardFixtureEntry 46
      map Data.Text.strip (cardInterior rendered)
        `shouldBe` [ "#812 Modal input leaks through the overlay",
                     "and reaches the board beneath it",
                     "reviewed:approve   architecture   bug",
                     "code-health   input   ui  +2",
                     "@claude-agent · updated now",
                     "Empty modal areas currently allow pointer",
                     "events to reach lower pages, which is",
                     "visible whenever a dialog overlaps the…"
                   ]
      map displayWidth rendered `shouldBe` replicate (length rendered) 46
      cardBorderColumns rendered `shouldBe` (["╭"] <> replicate 8 "│" <> ["╰"], ["╮"] <> replicate 8 "│" <> ["╯"])

    it "reflows the same card, including its truncation markers, at a narrower width" $ do
      let rendered = renderCard testOptions False cardFixtureEntry 34
      map Data.Text.strip (cardInterior rendered)
        `shouldBe` [ "#812 Modal input leaks through",
                     "the overlay and reaches the…",
                     "reviewed:approve",
                     "architecture   bug  +5",
                     "@claude-agent · updated now",
                     "Empty modal areas currently",
                     "allow pointer events to reach",
                     "lower pages, which is visible…"
                   ]
      map displayWidth rendered `shouldBe` replicate (length rendered) 34
      cardBorderColumns rendered `shouldBe` (["╭"] <> replicate 8 "│" <> ["╰"], ["╮"] <> replicate 8 "│" <> ["╯"])

    it "grows the frame for a tracked card's tracker-context row" $ do
      let rendered = renderCard testOptions True cardFixtureTrackedEntry 46
      take 1 (map Data.Text.strip (cardInterior rendered)) `shouldBe` ["F2 · tracker #700 · MULTI-TRACKED"]
      length rendered `shouldBe` length (renderCard testOptions False cardFixtureEntry 46) + 1
      map displayWidth rendered `shouldBe` replicate (length rendered) 46
      cardBorderColumns rendered `shouldBe` (["╭"] <> replicate 9 "│" <> ["╰"], ["╮"] <> replicate 9 "│" <> ["╯"])

    it "wraps a long tracker reference across rows rather than dropping its tail" $ do
      let rendered = renderCard testOptions False cardFixtureLongKeyTrackedEntry 32
      take 2 (map Data.Text.strip (cardInterior rendered))
        `shouldBe` ["phase-two-renderer-contract", "· tracker #700"]
      map displayWidth rendered `shouldBe` replicate (length rendered) 32

    it "moves the multi-tracked warning to its own row when it no longer shares one" $ do
      let rendered = renderCard testOptions False cardFixtureTrackedEntry 32
      take 2 (map Data.Text.strip (cardInterior rendered)) `shouldBe` ["F2 · tracker #700", "MULTI-TRACKED"]
      length rendered `shouldBe` length (renderCard testOptions False cardFixtureEntry 32) + 2

    it "keeps every tracker diagnostic on the card, not just the first" $ do
      let rendered = renderCard testOptions False cardFixtureDiagnosticEntry 46
      drop 6 (map Data.Text.strip (cardInterior rendered))
        `shouldBe` [ "TRACKER · line 3: checklist item has no",
                     "issue reference",
                     "TRACKER · line 4: malformed checklist",
                     "checkbox",
                     "TRACKER · line 5: duplicate child #2"
                   ]
      map displayWidth rendered `shouldBe` replicate (length rendered) 46

    it "keeps a pull request's CI and merge status row visible" $ do
      let rendered = renderCard testOptions False cardFixturePullRequestEntry 46
      map Data.Text.strip (cardInterior rendered)
        `shouldBe` [ "PR #823 Route Shift-wheel through the",
                     "modal-aware ownership path",
                     "reviewed:approve   input",
                     "#812 · agent → master · updated now",
                     "Routes Shift-wheel through the same",
                     "modal-aware ownership path as ordinary",
                     "wheel events.",
                     "✓ CI 14/14 · clean"
                   ]
      map displayWidth rendered `shouldBe` replicate (length rendered) 46

    it "sizes a sparse card to its own content rather than to a fixed height" $ do
      let rendered = renderCard testOptions False (Standalone (IssueItem (baseIssue 5 []))) 46
      map Data.Text.strip (cardInterior rendered) `shouldBe` ["#5 Issue 5", "unassigned · updated now", "Body"]
      cardBorderColumns rendered `shouldBe` (["╭"] <> replicate 3 "│" <> ["╰"], ["╮"] <> replicate 3 "│" <> ["╯"])

    it "lays a card out identically under the ASCII and no-color options" $ do
      let rendered = renderCard testOptions False cardFixtureEntry 46
          asciiCard = renderCard (testOptions {optionAscii = True}) False cardFixtureEntry 46
          monochrome = renderCard (testOptions {optionColor = ColorNever}) False cardFixtureEntry 46
      cardInterior asciiCard `shouldBe` cardInterior rendered
      monochrome `shouldBe` rendered
      cardBorderColumns asciiCard `shouldBe` (["+"] <> replicate 8 "|" <> ["+"], ["+"] <> replicate 8 "|" <> ["+"])

  describe "details overlay §11 contract" $ do
    it "shows every §11 field for a pull request, including branches, links, merge explanation, and individual checks" $ do
      let rendered = renderDetails detailsFixtureBoard (PullRequestItem detailsFixturePullRequest)
      -- Heading, labels and their GitHub-reported overflow.
      rendered `shouldSatisfy` any (Data.Text.isInfixOf "#823")
      rendered `shouldSatisfy` any (Data.Text.isInfixOf "Route Shift-wheel through the modal-aware path")
      rendered `shouldSatisfy` any (Data.Text.isInfixOf "reviewed:approve")
      rendered `shouldSatisfy` any (Data.Text.isInfixOf "+2 labels omitted")
      -- A PR retains its author, so that is the person the overlay names.
      detailsText rendered "Author" `shouldBe` Just "@agent"
      detailsText rendered "Branches" `shouldBe` Just "issue-36-details → master"
      detailsText rendered "Linked issues" `shouldBe` Just "#36, #812 · +3 omitted"
      detailsText rendered "Mergeability"
        `shouldBe` Just "behind — the base has advanced past this head; update the branch before merging"
      -- Every non-passing check is named individually, beside a truthful
      -- passed count -- not folded into the card's aggregate glyph.
      detailsRows rendered "Checks"
        `shouldBe` [ "9/12 passed",
                     "• integration-suite — failed",
                     "• docs-lint — pending"
                   ]
      detailsRows rendered "Timestamps"
        `shouldBe` [ "created 2026-01-01 00:00 UTC",
                     "updated 2026-01-02 00:00 UTC · 3h ago"
                   ]
      rendered `shouldSatisfy` any (Data.Text.isInfixOf "Routes Shift-wheel through the modal-aware ownership path.")
      detailsText rendered "URL" `shouldBe` Just "https://example.test/pull/823"

    it "shows the issue-side §11 fields, deriving linked pull requests from the retained snapshot" $ do
      let rendered = renderDetails detailsFixtureBoard (IssueItem detailsFixtureIssue)
      -- An issue retains assignees rather than an author.
      detailsText rendered "Assignees" `shouldBe` Just "@worker, @second +1"
      -- GitHub reports the link on the PR side only; the reverse direction is
      -- a lookup over the pull requests the snapshot already retained.
      detailsText rendered "Linked pull requests" `shouldBe` Just "#823, #851"
      detailsRows rendered "Timestamps"
        `shouldBe` [ "created 2026-01-01 00:00 UTC",
                     "updated 2026-01-02 00:00 UTC · 3h ago"
                   ]
      rendered `shouldSatisfy` any (Data.Text.isInfixOf "under #900")
      detailsText rendered "URL" `shouldBe` Just "https://example.test/issues/36"
      -- Branches, mergeability, and checks cannot apply to an issue, so their
      -- sections are absent rather than present and blank.
      rendered `shouldSatisfy` all (not . Data.Text.isPrefixOf "Branches")
      rendered `shouldSatisfy` all (not . Data.Text.isPrefixOf "Mergeability")
      rendered `shouldSatisfy` all (not . Data.Text.isPrefixOf "Checks")

    -- The overlay's viewport only scrolls vertically, so anything a single
    -- chip row pushed past the right edge would be unreachable, not merely
    -- off-screen. §11 requires every retained label plus the exact overflow
    -- count, so the chips have to wrap instead.
    it "wraps label chips at a narrow width rather than cropping labels out of reach" $ do
      let many =
            detailsFixturePullRequest
              { pullRequestLabels = [Label name "2f9e44" | name <- ["reviewed:approve", "input", "ui", "code-health", "architecture"]],
                pullRequestLabelOverflow = 2
              }
          rendered = renderDetailsAt 30 detailsFixtureBoard (PullRequestItem many)
          labelBlock = takeWhile (/= "Metadata") rendered
      mapM_ (\name -> labelBlock `shouldSatisfy` any (Data.Text.isInfixOf name)) ["reviewed:approve", "input", "ui", "code-health", "architecture"]
      labelBlock `shouldSatisfy` any (Data.Text.isInfixOf "+2 labels omitted")
      -- Wrapping, not overrunning: no row exceeds the width it was given.
      map displayWidth rendered `shouldSatisfy` all (<= 30)

    it "counts a label too wide for a whole row in the overflow marker instead of dropping it silently" $ do
      let oversized =
            detailsFixturePullRequest
              { pullRequestLabels = [Label (Data.Text.replicate 40 "x") "2f9e44", Label "ui" "0075ca"],
                pullRequestLabelOverflow = 1
              }
          rendered = renderDetailsAt 20 detailsFixtureBoard (PullRequestItem oversized)
          labelBlock = takeWhile (/= "Metadata") rendered
      labelBlock `shouldSatisfy` any (Data.Text.isInfixOf "ui")
      labelBlock `shouldSatisfy` any (Data.Text.isInfixOf "+2 labels omitted")

    it "reports a rollup past the context cap as unknown instead of listing the nodes it did see" $ do
      let unknownChecks = detailsFixturePullRequest {pullRequestChecks = ChecksUnknown}
      detailsRows (renderDetails detailsFixtureBoard (PullRequestItem unknownChecks)) "Checks"
        `shouldBe` ["unknown — the rollup exceeded the retained context cap"]

    it "gives a complete rollup with nothing outstanding a truthful summary and no empty detail rows" $ do
      let passed = detailsFixturePullRequest {pullRequestChecks = ChecksPassed 12}
          none = detailsFixturePullRequest {pullRequestChecks = ChecksNone}
      detailsRows (renderDetails detailsFixtureBoard (PullRequestItem passed)) "Checks" `shouldBe` ["12/12 passed"]
      detailsRows (renderDetails detailsFixtureBoard (PullRequestItem none)) "Checks" `shouldBe` ["no checks configured"]

    it "says 'none' rather than nothing when an item genuinely has no links" $ do
      let unlinked = basePullRequest 999 [] False []
      detailsText (renderDetails detailsFixtureBoard (PullRequestItem unlinked)) "Linked issues" `shouldBe` Just "none"
      detailsText (renderDetails detailsFixtureBoard (IssueItem (baseIssue 404 []))) "Linked pull requests" `shouldBe` Just "none"

    it "explains every merge state the decoder can produce, always leading with the card's own word" $ do
      let states = [MergeClean, MergeBehind, MergeBlocked, MergeProtected, MergeConflicting, MergeUnstable, MergeUnknown]
          explanations = map mergeExplanation states
          explain state = detailsText (renderDetails detailsFixtureBoard (PullRequestItem (detailsFixturePullRequest {pullRequestMergeState = state}))) "Mergeability"
      explanations `shouldSatisfy` all (not . Data.Text.null)
      length (nub explanations) `shouldBe` length states
      -- §9's vocabulary is what the overlay leads with, so its sentence can
      -- never disagree with the word the card already showed.
      map explain states `shouldBe` map (\state -> Just (mergeText state <> " — " <> mergeExplanation state)) states

  describe "configuration loading" $ do
    it "yields the stable defaults when no configuration file exists" $
      withTemporaryCacheRoot $ \configRoot ->
        withEnvironmentValue "XDG_CONFIG_HOME" configRoot $ do
          path <- defaultConfigPath
          doesFileExist path `shouldReturn` False
          loadRawConfig Nothing `shouldReturn` Right (defaultRawConfig, [])
          defaultRawConfig.rawCache `shouldBe` True
          defaultRawConfig.rawRemoteName `shouldBe` "origin"
          defaultRawConfig.rawWorkflow `shouldBe` defaultWorkflowConfig
          defaultRawConfig.rawLimits `shouldBe` LimitsConfig 250 100 3
          defaultRawConfig.rawTimeouts `shouldBe` TimeoutsConfig 30 10 45

    it "honors an explicit --config path pointing at a fixture" $
      withTemporaryCacheRoot $ \configRoot -> do
        let fixturePath = configRoot </> "fixture.toml"
        writeFile fixturePath "remote_name = \"upstream\"\n"
        loaded <- loadRawConfig (Just fixturePath)
        let (config, warnings) = unsafeConfig loaded
        warnings `shouldBe` []
        config.rawRemoteName `shouldBe` "upstream"

    it "resolves an explicit --config path to an absolute path so a worker spawned from a different directory still finds it" $ do
      resolveConfigPathOption Nothing `shouldReturn` Nothing
      absolutePath <- resolveConfigPathOption (Just "/already/absolute/config.toml")
      absolutePath `shouldBe` Just "/already/absolute/config.toml"
      relativeResult <- resolveConfigPathOption (Just "relative-config.toml")
      case relativeResult of
        Just resolved -> isAbsolute resolved `shouldBe` True
        Nothing -> expectationFailure "expected a resolved path"

    it "decodes a full-file fixture covering every documented key and warns on an unknown top-level key" $ do
      let (config, warnings) = unsafeConfig (decodeConfigText fullFixtureToml)
      config.rawCache `shouldBe` False
      config.rawRemoteName `shouldBe` "upstream"
      config.rawWorkflow
        `shouldBe` WorkflowConfig
          { approvalLabel = "lgtm",
            changesRequestedLabel = "needs-work",
            blockedLabels = Set.fromList ["blocked", "urgent"],
            trackerLabels = Set.fromList ["epic", "tracker"],
            additionalTrackerSectionHeadings = ["Milestones"],
            approvalMode = ApprovalByEither,
            blockingSeverity = SeverityAmber
          }
      config.rawLimits `shouldBe` LimitsConfig 500 200 5
      config.rawTimeouts `shouldBe` TimeoutsConfig 60 20 90
      config.rawUsage
        `shouldBe` UsageConfig
          (Just (UsageCommandConfig ["/usr/local/bin/my-codex-usage", "--json"]))
          (Just (UsageCommandConfig ["/usr/local/bin/my-claude-usage", "--json"]))
      Map.member "coghex/kanban" config.rawRepositories `shouldBe` True
      Map.member "other/repo" config.rawRepositories `shouldBe` True
      Data.Text.concat warnings `shouldSatisfy` Data.Text.isInfixOf "unknown_top_level_key"

    it "merges a matching repository override onto the global table, leaving unset fields inherited" $ do
      let (config, _) = unsafeConfig (decodeConfigText fullFixtureToml)
          resolved = resolveConfig "coghex/kanban" config
      resolved.resolvedWorkflow.approvalLabel `shouldBe` "ship-it"
      resolved.resolvedWorkflow.changesRequestedLabel `shouldBe` "needs-work"
      resolved.resolvedLimits `shouldBe` LimitsConfig 999 200 5
      resolved.resolvedTimeouts `shouldBe` TimeoutsConfig 15 20 90
      resolved.resolvedCache `shouldBe` False
      resolved.resolvedRemoteName `shouldBe` "upstream"

    it "selects the repository table by an exact, case-sensitive owner/name match" $ do
      let (config, _) = unsafeConfig (decodeConfigText fullFixtureToml)
      (resolveConfig "COGHEX/KANBAN" config).resolvedWorkflow.approvalLabel `shouldBe` "lgtm"

    it "leaves an unrelated repository table without effect on a different repository's resolution" $ do
      let (config, _) = unsafeConfig (decodeConfigText fullFixtureToml)
          resolved = resolveConfig "coghex/kanban" config
      resolved.resolvedWorkflow.approvalLabel `shouldNotBe` "should-not-apply"

    it "replaces rather than extends a global array when a repository override sets it" $ do
      let toml =
            "[workflow]\n"
              <> "blocked_labels = [\"blocked\", \"urgent\"]\n"
              <> "[repositories.\"acme/widgets\".workflow]\n"
              <> "blocked_labels = [\"custom-block\"]\n"
          (config, _) = unsafeConfig (decodeConfigText toml)
          resolved = resolveConfig "acme/widgets" config
      resolved.resolvedWorkflow.blockedLabels `shouldBe` Set.fromList ["custom-block"]

    it "fails on syntactically malformed TOML" $
      decodeConfigText "this is not [valid toml" `shouldSatisfy` isLeftText

    it "rejects each semantically invalid known value, naming the full key path" $ do
      decodeConfigText "[workflow]\napproval_label = \"\"\n" `shouldSatisfy` errorContains ["workflow", "approval_label"]
      decodeConfigText "remote_name = \"\"\n" `shouldSatisfy` errorContains ["remote_name"]
      decodeConfigText "[workflow]\napproval_mode = \"bogus\"\n" `shouldSatisfy` errorContains ["approval_mode"]
      decodeConfigText "[workflow]\nblocking_severity = \"purple\"\n" `shouldSatisfy` errorContains ["blocking_severity"]
      decodeConfigText "[limits]\nmax_open_issues = 0\n" `shouldSatisfy` errorContains ["limits", "max_open_issues"]
      decodeConfigText "[limits]\nexcerpt_lines = -1\n" `shouldSatisfy` errorContains ["excerpt_lines"]
      decodeConfigText "[timeouts]\ngithub_seconds = 0\n" `shouldSatisfy` errorContains ["github_seconds"]
      decodeConfigText "[usage.codex]\ncommand = []\n" `shouldSatisfy` errorContains ["command"]
      decodeConfigText "[usage.codex]\ncommand = [\"\"]\n" `shouldSatisfy` errorContains ["command"]

    it "rejects a timeout large enough to overflow when converted to microseconds, but accepts the boundary" $ do
      let overflowingSeconds = (maxBound :: Int) `div` 1000000 + 1
          largestSafeSeconds = (maxBound :: Int) `div` 1000000
      decodeConfigText ("[timeouts]\ngithub_seconds = " <> Data.Text.pack (show overflowingSeconds) <> "\n")
        `shouldSatisfy` errorContains ["github_seconds"]
      (decodeConfigText ("[timeouts]\ngithub_seconds = " <> Data.Text.pack (show largestSafeSeconds) <> "\n"))
        `shouldSatisfy` isRight

    it "rejects the global-only keys cache, remote_name, and usage inside a repository override" $ do
      decodeConfigText "[repositories.\"a/b\"]\ncache = true\n" `shouldSatisfy` errorContains ["cache"]
      decodeConfigText "[repositories.\"a/b\"]\nremote_name = \"origin\"\n" `shouldSatisfy` errorContains ["remote_name"]
      decodeConfigText "[repositories.\"a/b\"]\n[repositories.\"a/b\".usage]\n" `shouldSatisfy` errorContains ["usage"]

    it "warns, rather than fails, on an unrecognized key while still loading" $ do
      let (_, warnings) = unsafeConfig (decodeConfigText "[workflow]\nunexpected_field = 1\n")
      Data.Text.concat warnings `shouldSatisfy` Data.Text.isInfixOf "unexpected_field"
      Data.Text.concat warnings `shouldSatisfy` Data.Text.isInfixOf "workflow"

    it "rejects a global approval_label and changes_requested_label that resolve to the same label" $
      decodeConfigText "[workflow]\napproval_label = \"lgtm\"\nchanges_requested_label = \"LGTM\"\n"
        `shouldSatisfy` errorContains ["workflow.approval_label", "workflow.changes_requested_label"]

    it "rejects a configured label that collides with the reserved reviewed:revised protocol label" $ do
      decodeConfigText "[workflow]\napproval_label = \"reviewed:revised\"\n"
        `shouldSatisfy` errorContains ["approval_label", "reviewed:revised"]
      decodeConfigText "[workflow]\nchanges_requested_label = \"Reviewed:Revised\"\n"
        `shouldSatisfy` errorContains ["changes_requested_label", "reviewed:revised"]

    it "rejects a repository override whose merged labels collide, even though neither table alone does" $ do
      let toml =
            "[workflow]\n"
              <> "approval_label = \"lgtm\"\n"
              <> "changes_requested_label = \"needs-work\"\n"
              <> "[repositories.\"acme/widgets\".workflow]\n"
              <> "changes_requested_label = \"lgtm\"\n"
      decodeConfigText toml `shouldSatisfy` errorContains ["repositories.\"acme/widgets\".workflow"]

  describe "global remote resolution" $ do
    it "resolves the repository through a configured non-origin remote" $
      withTemporaryCacheRoot $ \projectRoot -> do
        _ <- readProcessWithExitCode "git" ["-C", projectRoot, "init", "--quiet"] ""
        _ <- readProcessWithExitCode "git" ["-C", projectRoot, "remote", "add", "upstream", "https://github.com/coghex/kanban.git"] ""
        result <- resolveRepository "upstream" projectRoot Nothing
        case result of
          Left message -> expectationFailure (Data.Text.unpack message)
          Right repository -> do
            repository.repositoryOwner `shouldBe` "coghex"
            repository.repositoryName `shouldBe` "kanban"

    it "fails startup rather than querying GitHub for a bare mirror's owner" $
      withTemporaryCacheRoot $ \projectRoot -> do
        _ <- readProcessWithExitCode "git" ["-C", projectRoot, "init", "--quiet"] ""
        _ <- readProcessWithExitCode "git" ["-C", projectRoot, "remote", "add", "origin", "/srv/git/team/myrepo.git"] ""
        result <- resolveRepository "origin" projectRoot Nothing
        result `shouldSatisfy` rejectsWithGuidance "/srv/git/team/myrepo.git"

    it "honors an explicit --repo value when the remote cannot be used" $
      withTemporaryCacheRoot $ \projectRoot -> do
        _ <- readProcessWithExitCode "git" ["-C", projectRoot, "init", "--quiet"] ""
        result <- resolveRepository "origin" projectRoot (Just "coghex/kanban")
        case result of
          Left message -> expectationFailure (Data.Text.unpack message)
          Right repository -> do
            repository.repositoryOwner `shouldBe` "coghex"
            repository.repositoryName `shouldBe` "kanban"

  describe "responsive board layout" $ do
    it "shares a wide board across all four columns" $
      responsiveColumnWidths 167 `shouldBe` [41, 41, 40, 40]
    it "keeps readable columns and relies on scrolling below the threshold" $
      responsiveColumnWidths 100 `shouldBe` [32, 32, 32, 32]
    it "accounts for two-cell gutters in the open layout" $
      responsiveOpenColumnWidths 170 `shouldBe` [41, 41, 41, 41]

  describe "workflow preflight" $ do
    describe "status-only probe classification" $ do
      it "reads a signed-in codex login status" $
        classifyCodexAuth (Right (ExitSuccess, "Logged in using ChatGPT\n")) `shouldBe` AuthAuthenticated
      it "reads a signed-out codex login status" $
        classifyCodexAuth (Right (ExitFailure 1, "Not logged in\n")) `shouldSatisfy` isNotAuthenticated
      it "reads a signed-in claude auth status from its loggedIn field" $
        classifyClaudeAuth (Right (ExitSuccess, "{\"loggedIn\": true, \"authMethod\": \"claude.ai\"}"))
          `shouldBe` AuthAuthenticated
      it "reads a signed-out claude auth status from its loggedIn field" $
        classifyClaudeAuth (Right (ExitSuccess, "{\"loggedIn\": false}")) `shouldSatisfy` isNotAuthenticated
      -- A CLI too old to know the subcommand at all must not be reported as
      -- signed out: that would block an action the user could still run.
      it "never reads an unrecognized auth subcommand as a sign-out" $ do
        classifyCodexAuth (Right (ExitFailure 2, "error: unrecognized subcommand 'login'"))
          `shouldSatisfy` isUnknownAuth
        classifyClaudeAuth (Right (ExitFailure 1, "error: unknown command 'auth'"))
          `shouldSatisfy` isUnknownAuth
      it "never reads a probe that could not run at all as a sign-out" $
        classifyCodexAuth (Left "codex login status timed out") `shouldSatisfy` isUnknownAuth
      it "reads the codex plugin listing envelope" $
        classifyBundleListing
          (Right (ExitSuccess, "{\"installed\":[{\"pluginId\":\"kanban@kanban\",\"installed\":true,\"enabled\":true}]}"))
          `shouldBe` BundleEnabled
      it "reads the claude plugin listing envelope" $
        classifyBundleListing (Right (ExitSuccess, "[{\"id\":\"kanban@kanban\",\"enabled\":false}]"))
          `shouldBe` BundleDisabled
      it "reads a marketplace offering that is not installed as absent" $
        classifyBundleListing
          (Right (ExitSuccess, "{\"installed\":[{\"pluginId\":\"kanban@kanban\",\"installed\":false}]}"))
          `shouldBe` BundleAbsent
      it "reports an absent bundle when no listing entry names it" $
        classifyBundleListing (Right (ExitSuccess, "[]")) `shouldBe` BundleAbsent
      it "never reads an undecodable listing as an absent bundle" $
        classifyBundleListing (Right (ExitSuccess, "not json")) `shouldSatisfy` isUnknownBundle
      it "accepts the versions the tracked bundles were verified against" $ do
        classifyVersion minimumCodexVersion (Right (ExitSuccess, "codex-cli 0.144.6\n"))
          `shouldBe` VersionSupported "0.144.6"
        classifyVersion minimumClaudeVersion (Right (ExitSuccess, "2.1.220 (Claude Code)\n"))
          `shouldBe` VersionSupported "2.1.220"
      it "rejects a release older than the one the bundle install path needs" $
        classifyVersion minimumClaudeVersion (Right (ExitSuccess, "2.1.100 (Claude Code)\n"))
          `shouldBe` VersionUnsupported "2.1.100" "2.1.216"
      it "never reads an unparseable version banner as unsupported" $
        classifyVersion minimumCodexVersion (Right (ExitSuccess, "dev build\n"))
          `shouldSatisfy` isUnknownVersion

    describe "per-action readiness" $ do
      it "reports a fully provisioned environment as ready for every action" $
        mapM_
          (\action -> blockingRemediation (actionReport readyPreflightEnvironment action) `shouldBe` Nothing)
          doctorActions
      it "blocks only the actions that reach for a missing provider executable" $ do
        let environment = withCodexProbe (readyProviderProbe CodexSolver) {probeExecutable = Nothing}
        blockedProblems environment (ActionSolve CodexSolver) `shouldBe` [ExecutableUnavailable]
        blockedProblems environment (ActionSolve ClaudeSolver) `shouldBe` []
        -- Auto-solve reviews the PR with the opposite brand itself, so a
        -- claude auto-solve still depends on codex being installed.
        blockedProblems environment (ActionAutoSolve ClaudeSolver) `shouldBe` [ExecutableUnavailable]
        blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` []
      it "distinguishes an unauthenticated provider from a missing one" $ do
        let environment = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeAuth = AuthNotAuthenticated "signed out"}
        -- A Codex-origin PR is reviewed by Claude.
        blockedProblems environment (ActionPullRequestFlow PullRequestCodex PullRequestReview)
          `shouldBe` [ProviderUnauthenticated]
      it "names the setup command when a workflow bundle is absent" $ do
        let environment = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeBundle = BundleAbsent}
        blockedProblems environment (ActionSolve ClaudeSolver) `shouldBe` [WorkflowBundleUnavailable]
        blockingRemediation (actionReport environment (ActionSolve ClaudeSolver))
          `shouldSatisfy` maybe False (Data.Text.isInfixOf "tools/setup_workflows.py --component claude-plugin")
      it "blocks the canonical review gate, but not issue revision, on a missing backend" $ do
        let environment = readyPreflightEnvironment {environmentReviewBackend = ReviewBackendMissing "/nowhere/approve_issues.py"}
        blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ReviewBackendUnavailable]
        blockedProblems environment (ActionSolve CodexSolver) `shouldBe` [ReviewBackendUnavailable]
        blockedProblems environment (ActionIssueRevision IssueOriginCodex) `shouldBe` []
      -- A Claude-origin revision authors its amendment through
      -- kanban_run_claude, so it needs that CLI even though no packaged
      -- bundle is involved; a Codex-origin one must not be blocked by it.
      it "requires the Claude CLI only for a Claude-origin revision" $ do
        let environment = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeExecutable = Nothing}
        blockedProblems environment (ActionIssueRevision IssueOriginClaude) `shouldBe` [ExecutableUnavailable]
        blockedProblems environment (ActionIssueRevision IssueOriginCodex) `shouldBe` []
      it "requires a signed-in Claude for a Claude-origin revision" $ do
        let environment = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeAuth = AuthNotAuthenticated "signed out"}
        blockedProblems environment (ActionIssueRevision IssueOriginClaude) `shouldBe` [ProviderUnauthenticated]
      -- Revision runs Kanban's own prompts through codex app-server, so a
      -- missing packaged bundle must never block it for either origin.
      it "never requires a packaged bundle for a revision of either origin" $ do
        let environment =
              readyPreflightEnvironment
                { environmentCodex = (readyProviderProbe CodexSolver) {probeBundle = BundleAbsent},
                  environmentClaude = (readyProviderProbe ClaudeSolver) {probeBundle = BundleAbsent}
                }
        blockedProblems environment (ActionIssueRevision IssueOriginCodex) `shouldBe` []
        blockedProblems environment (ActionIssueRevision IssueOriginClaude) `shouldBe` []
      it "reads an issue's origin from its marker" $ do
        issueOriginFromBody "Body\n\n<!-- issue-origin:claude -->" `shouldBe` IssueOriginClaude
        issueOriginFromBody "Body\n\n<!-- issue-origin:codex -->" `shouldBe` IssueOriginCodex
        issueOriginFromBody "Body with no marker" `shouldBe` IssueOriginUnmarked
      -- The backend routes on ORIGIN_RE, which is case-insensitive and
      -- allows whitespace on both sides of the value. Reading it more
      -- strictly here would demand a provider the review never spawns.
      it "accepts every marker spelling the backend accepts" $ do
        issueOriginFromBody "<!-- issue-origin:CLAUDE -->" `shouldBe` IssueOriginClaude
        issueOriginFromBody "<!-- ISSUE-ORIGIN:Claude -->" `shouldBe` IssueOriginClaude
        issueOriginFromBody "<!--issue-origin:codex-->" `shouldBe` IssueOriginCodex
        issueOriginFromBody "<!--   issue-origin:codex   -->" `shouldBe` IssueOriginCodex
        issueOriginFromBody "<!--\n  issue-origin:codex\n-->" `shouldBe` IssueOriginCodex
        issueOriginFromBody "a <!-- issue-origin:codex --> b <!-- issue-origin:CODEX -->"
          `shouldBe` IssueOriginCodex
      it "rejects text that only looks like a marker" $ do
        issueOriginFromBody "issue-origin:claude" `shouldBe` IssueOriginUnmarked
        issueOriginFromBody "<!-- issue-origin:claudex -->" `shouldBe` IssueOriginUnmarked
        issueOriginFromBody "<!-- issue-origin: claude -->" `shouldBe` IssueOriginUnmarked
        issueOriginFromBody "<!-- issue-origin:claude" `shouldBe` IssueOriginUnmarked
      -- The backend raises on a body declaring both, before reaching any
      -- reviewer, so preflight must not demand a provider for it either.
      it "mirrors the backend's conflicting-marker case" $ do
        let conflicting = "<!-- issue-origin:claude -->\n<!-- issue-origin:codex -->"
        issueOriginFromBody conflicting `shouldBe` IssueOriginConflicting
        canonicalReviewBrands IssueOriginConflicting `shouldBe` []
        blockedProblems readyPreflightEnvironment (ActionIssueReview IssueOriginConflicting)
          `shouldBe` []
        blockedProblems
          (withClaudeProbe (readyProviderProbe ClaudeSolver) {probeExecutable = Nothing})
          (ActionIssueReview IssueOriginConflicting)
          `shouldBe` []
      it "routes the revision amendment author by that origin" $ do
        revisionAuthorBrand IssueOriginClaude `shouldBe` ClaudeSolver
        revisionAuthorBrand IssueOriginCodex `shouldBe` CodexSolver
        revisionAuthorBrand IssueOriginUnmarked `shouldBe` CodexSolver
      -- approve_issues.py spawns the opposite brand itself, and both under
      -- the dual legacy policy Kanban always passes, so the canonical gate
      -- is only ready if that reviewer's own CLI is.
      it "routes the canonical reviewer to the opposite brand, or both when unmarked" $ do
        canonicalReviewBrands IssueOriginClaude `shouldBe` [CodexSolver]
        canonicalReviewBrands IssueOriginCodex `shouldBe` [ClaudeSolver]
        canonicalReviewBrands IssueOriginUnmarked `shouldBe` [CodexSolver, ClaudeSolver]
      it "requires the canonical reviewer's own CLI for a review" $ do
        let environment = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeExecutable = Nothing}
        blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ExecutableUnavailable]
        blockedProblems environment (ActionIssueReview IssueOriginClaude) `shouldBe` []
        blockedProblems environment (ActionIssueReview IssueOriginUnmarked) `shouldBe` [ExecutableUnavailable]
      it "requires a signed-in canonical reviewer for a review" $ do
        let environment = withCodexProbe (readyProviderProbe CodexSolver) {probeAuth = AuthNotAuthenticated "signed out"}
        blockedProblems environment (ActionIssueReview IssueOriginClaude) `shouldBe` [ProviderUnauthenticated]
        blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` []
      -- pr-revise runs on the PR's own brand and then spawns the opposite
      -- one for its single nested canonical rereview, so a revision needs
      -- both CLIs even though review and rereview need only the reviewer's.
      it "requires the nested cross-brand reviewer for a PR revision" $ do
        let environment = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeExecutable = Nothing}
        blockedProblems environment (ActionPullRequestFlow PullRequestCodex PullRequestRevision)
          `shouldBe` [ExecutableUnavailable]
        blockedProblems environment (ActionPullRequestFlow PullRequestClaude PullRequestRevision)
          `shouldBe` [ExecutableUnavailable]
        -- A Claude-origin PR is reviewed by Codex, which is present here.
        blockedProblems environment (ActionPullRequestFlow PullRequestClaude PullRequestReview)
          `shouldBe` []
        blockedProblems environment (ActionPullRequestFlow PullRequestClaude PullRequestRereview)
          `shouldBe` []
      it "requires the nested reviewer to be signed in for a PR revision" $ do
        let environment = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeAuth = AuthNotAuthenticated "signed out"}
        blockedProblems environment (ActionPullRequestFlow PullRequestCodex PullRequestRevision)
          `shouldBe` [ProviderUnauthenticated]
        blockedProblems environment (ActionPullRequestFlow PullRequestClaude PullRequestReview)
          `shouldBe` []
      -- The nested rereview is a direct `codex exec`/`claude -p` spawn by
      -- the bundled coordinator, so only the launched brand needs a bundle.
      it "requires a bundle only for the brand the PR action itself launches" $ do
        let environment = withCodexProbe (readyProviderProbe CodexSolver) {probeBundle = BundleAbsent}
        blockedProblems environment (ActionPullRequestFlow PullRequestCodex PullRequestRevision)
          `shouldBe` [WorkflowBundleUnavailable]
        blockedProblems environment (ActionPullRequestFlow PullRequestCodex PullRequestReview)
          `shouldBe` []
        blockedProblems environment (ActionPullRequestFlow PullRequestClaude PullRequestRevision)
          `shouldBe` []
      -- The backend runs `codex exec`/`claude -p` itself, so no packaged
      -- workflow bundle is involved in a canonical review.
      it "never requires a packaged bundle for a canonical review" $ do
        let environment =
              readyPreflightEnvironment
                { environmentCodex = (readyProviderProbe CodexSolver) {probeBundle = BundleAbsent},
                  environmentClaude = (readyProviderProbe ClaudeSolver) {probeBundle = BundleAbsent}
                }
        blockedProblems environment (ActionIssueReview IssueOriginUnmarked) `shouldBe` []
      it "tells an occupied install path apart from a never-installed one" $ do
        let environment = readyPreflightEnvironment {environmentReviewBackend = ReviewBackendConflicting "/occupied" "a directory"}
        blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ConflictingInstallation]
        blockingRemediation (actionReport environment (ActionIssueReview IssueOriginCodex))
          `shouldSatisfy` maybe False (Data.Text.isInfixOf "move or remove that path yourself")
      it "reports an unavailable GitHub CLI for every action" $ do
        let environment = readyPreflightEnvironment {environmentGitHub = GitHubExecutableMissing}
        mapM_ (\action -> blockedProblems environment action `shouldSatisfy` elem GitHubUnavailable) doctorActions
      -- The whole point of the unknown status: a probe Kanban could not
      -- interpret must never break a setup that actually works.
      it "never blocks an action on an inconclusive probe" $ do
        let inconclusive brand =
              (readyProviderProbe brand)
                { probeVersion = VersionUnknown "no version banner",
                  probeAuth = AuthUnknown "unreadable",
                  probeBundle = BundleUnknown "unreadable"
                }
            environment =
              readyPreflightEnvironment
                { environmentCodex = inconclusive CodexSolver,
                  environmentClaude = inconclusive ClaudeSolver,
                  environmentGitHub = GitHubUnknown "unreadable"
                }
        mapM_ (\action -> blockedProblems environment action `shouldBe` []) doctorActions
        doctorReady environment `shouldBe` True

    describe "board diagnostics" $ do
      it "round-trips a remediation through the failure message" $
        preflightDiagnosticDetail (preflightDiagnostic "install the bundle") `shouldBe` Just "install the bundle"
      it "leaves an ordinary agent failure unclassified" $
        preflightDiagnosticDetail "codex was not found on PATH" `shouldBe` Nothing
      it "reports a setup gap as unavailable rather than as another failed agent" $ do
        canonicalReviewNotice (preflightDiagnostic "no canonical issue reviewer. Run setup.")
          `shouldSatisfy` Data.Text.isInfixOf "cannot start"
        canonicalReviewNotice (preflightDiagnostic "no canonical issue reviewer. Run setup.")
          `shouldSatisfy` Data.Text.isInfixOf "Run setup."
      it "keeps a generic provider failure reading as a failure" $
        canonicalReviewNotice "the backend crashed" `shouldSatisfy` Data.Text.isInfixOf "failed:"
      it "distinguishes a setup gap from a generic failure in the activity text" $ do
        failureActivity (preflightDiagnostic "bundle absent") `shouldBe` "setup required"
        failureActivity "provider exited 1" `shouldBe` "failed"
      -- The revision path reports through canonicalReviewActivity whether
      -- the coordinator rejected the turn or preflight stopped it against
      -- an already-running backend, so both readings live here.
      it "classifies a revision start failure by cause" $ do
        canonicalReviewActivity (preflightDiagnostic "claude was not found on PATH") `shouldBe` "setup required"
        canonicalReviewActivity "the coordinator rejected the turn" `shouldBe` "failed"
      it "names the remediation when a revision cannot start" $ do
        agentFailureNotice "Issue revision" (preflightDiagnostic "claude was not found on PATH. Install it.")
          `shouldSatisfy` Data.Text.isInfixOf "Issue revision cannot start — "
        agentFailureNotice "Issue revision" (preflightDiagnostic "claude was not found on PATH. Install it.")
          `shouldSatisfy` Data.Text.isInfixOf "Install it."
        agentFailureNotice "Issue revision" "the coordinator rejected the turn"
          `shouldSatisfy` Data.Text.isInfixOf "Issue revision failed: "

    describe "hermetic fresh-machine probing" $ do
      it "reports a fully provisioned machine as ready for every action" $
        withPreflightMachine fullyProvisionedFakes BackendInstalled $
          \root _ -> do
            environment <- gatherPreflightEnvironment root
            doctorReady environment `shouldBe` True
      it "only ever runs status-only probes, and mutates nothing" $
        withPreflightMachine fullyProvisionedFakes BackendInstalled $
          \root probeLog -> do
            snapshotBefore <- machineSnapshot root
            _ <- gatherPreflightEnvironment root
            snapshotAfter <- machineSnapshot root
            snapshotAfter `shouldBe` snapshotBefore
            invocations <- probeInvocations probeLog
            invocations `shouldSatisfy` not . null
            invocations `shouldSatisfy` all (`elem` allowedProbeInvocations)
      -- With an installed backend and no provider at all, every action's
      -- one complaint is the missing executable — including the canonical
      -- gate, whose reviewer the backend spawns itself.
      it "reports absent provider executables for every action that needs one" $
        withPreflightMachine [readyGitHubFake, python3Fake] BackendInstalled $ \root _ -> do
          environment <- gatherPreflightEnvironment root
          environment.environmentReviewBackend `shouldSatisfy` isReadyBackend
          mapM_
            (\action -> blockedProblems environment action `shouldBe` [ExecutableUnavailable])
            [ ActionSolve CodexSolver,
              ActionSolve ClaudeSolver,
              ActionIssueReview IssueOriginCodex,
              ActionIssueReview IssueOriginClaude,
              ActionIssueRevision IssueOriginCodex
            ]
      it "reports an unauthenticated provider" $
        withPreflightMachine [signedOutCodexFake, readyClaudeFake, readyGitHubFake, python3Fake] BackendInstalled $
          \root _ -> do
            environment <- gatherPreflightEnvironment root
            blockedProblems environment (ActionSolve CodexSolver) `shouldBe` [ProviderUnauthenticated]
      it "reports an absent workflow bundle" $
        withPreflightMachine [bundlelessCodexFake, readyClaudeFake, readyGitHubFake, python3Fake] BackendInstalled $
          \root _ -> do
            environment <- gatherPreflightEnvironment root
            blockedProblems environment (ActionSolve CodexSolver) `shouldBe` [WorkflowBundleUnavailable]
      it "reports an uninstalled canonical review backend" $
        withPreflightMachine fullyProvisionedFakes BackendMissing $
          \root _ -> do
            environment <- gatherPreflightEnvironment root
            blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ReviewBackendUnavailable]
      it "reports an install path occupied by something Kanban did not install" $
        withPreflightMachine fullyProvisionedFakes BackendOccupied $
          \root _ -> do
            environment <- gatherPreflightEnvironment root
            blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ConflictingInstallation]
      -- Setup refuses an ordinary file on the install path, so reporting it
      -- ready here would both contradict setup and hand the canonical
      -- reviewer an unmanaged script to run.
      it "reports an ordinary file on the install path as conflicting, not ready" $
        withPreflightMachine fullyProvisionedFakes BackendOrdinaryFile $ \root _ -> do
          environment <- gatherPreflightEnvironment root
          environment.environmentReviewBackend `shouldSatisfy` isConflictingBackend
          blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ConflictingInstallation]
      it "reports a dangling managed link as conflicting" $
        withPreflightMachine fullyProvisionedFakes BackendDanglingLink $ \root _ -> do
          environment <- gatherPreflightEnvironment root
          environment.environmentReviewBackend `shouldSatisfy` isConflictingBackend
          blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ConflictingInstallation]
      -- A link resolving to a readable script under a plausible tools/
      -- path passes every shape test; only the tracked file's own identity
      -- marker tells it apart from Kanban's backend.
      it "reports a link to a file that is not Kanban's own backend as conflicting" $
        withPreflightMachine fullyProvisionedFakes BackendForeignLink $ \root _ -> do
          environment <- gatherPreflightEnvironment root
          environment.environmentReviewBackend `shouldSatisfy` isConflictingBackend
          blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ConflictingInstallation]
      -- approve_issues.py imports kanban_config at module scope, so half an
      -- installation is not an installation.
      it "reports a missing companion config module as an unavailable backend" $
        withPreflightMachine fullyProvisionedFakes BackendCompanionMissing $ \root _ -> do
          environment <- gatherPreflightEnvironment root
          environment.environmentReviewBackend `shouldSatisfy` isMissingBackend
          blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [ReviewBackendUnavailable]
      it "reports an unauthenticated GitHub CLI" $
        withPreflightMachine [readyCodexFake, readyClaudeFake, signedOutGitHubFake, python3Fake] BackendInstalled $
          \root _ -> do
            environment <- gatherPreflightEnvironment root
            blockedProblems environment (ActionIssueReview IssueOriginCodex) `shouldBe` [GitHubUnavailable]
      it "renders one doctor line per supported AI action" $
        withPreflightMachine [readyGitHubFake, python3Fake] BackendMissing $ \root _ -> do
          environment <- gatherPreflightEnvironment root
          let rendered = Data.Text.unlines (doctorLines environment)
          mapM_ (\action -> rendered `shouldSatisfy` Data.Text.isInfixOf (actionLabel action)) doctorActions
          -- Every action a user can select from the board gets its own
          -- line, including the ones whose dependency set happens to match
          -- another's, so a future collapse cannot silently drop one.
          mapM_
            (\action -> doctorActions `shouldSatisfy` elem action)
            [ ActionIssueReview IssueOriginCodex,
              ActionIssueReview IssueOriginClaude,
              ActionIssueReview IssueOriginUnmarked,
              ActionIssueRevision IssueOriginCodex,
              ActionIssueRevision IssueOriginClaude,
              ActionSolve CodexSolver,
              ActionSolve ClaudeSolver,
              ActionAutoSolve CodexSolver,
              ActionAutoSolve ClaudeSolver,
              ActionPullRequestFlow PullRequestCodex PullRequestReview,
              ActionPullRequestFlow PullRequestClaude PullRequestReview,
              ActionPullRequestFlow PullRequestCodex PullRequestRereview,
              ActionPullRequestFlow PullRequestClaude PullRequestRereview,
              ActionPullRequestFlow PullRequestCodex PullRequestRevision,
              ActionPullRequestFlow PullRequestClaude PullRequestRevision
            ]
          rendered `shouldSatisfy` Data.Text.isInfixOf "PR rereview (r)"
          -- The drainer keeps its own dedicated install and status flow.
          rendered `shouldSatisfy` (not . Data.Text.isInfixOf "drainer")

baseIssue :: Int -> [Assignee] -> Issue
baseIssue number assignees =
  Issue number ("Issue " <> showText number) "Body" "https://example.test" [] assignees epoch epoch 0 0

-- | A tracker whose child section is recognized but yields nothing usable:
-- its single row is malformed, so it is diagnosed and dropped. The tracker
-- reaches 'deriveBoard' with zero children without depending on any parser
-- defect, and #3 stays an ordinary issue.
zeroChildTracker :: Issue
zeroChildTracker =
  (baseIssue 12 [])
    { issueLabels = [Label "epic" "5319e7"],
      issueBody = "## Children\n- [?] #3 — A1: Malformed"
    }

-- | Row-level diagnostics first, then the section-level verdict, exactly as
-- 'parseTrackerBody' orders them.
zeroChildDiagnostics :: [TrackerDiagnostic]
zeroChildDiagnostics = [TrackerMalformedCheckbox 2, TrackerChildrenMissing]

isTrackerHeaderEntry :: ColumnEntry -> Bool
isTrackerHeaderEntry (TrackerHeader _) = True
isTrackerHeaderEntry _ = False

fixtureTracker :: Int -> Tracker
fixtureTracker number = Tracker (baseIssue number []) 0 0 Map.empty []

fixtureMembership :: Int -> Int -> TrackerMembership
fixtureMembership trackerNumber childNumber = TrackerMembership (fixtureTracker trackerNumber) (TrackerChild childNumber Nothing 0 False)

-- | A tracked entry whose primary tracker is 'primaryTrackerNumber'; any
-- 'additionalTrackerNumbers' become its secondary (non-primary) memberships.
fixtureTrackedEntry :: Int -> [Int] -> Int -> ColumnEntry
fixtureTrackedEntry primaryTrackerNumber additionalTrackerNumbers childNumber =
  Tracked
    (TrackingContext (fixtureMembership primaryTrackerNumber childNumber) (map (`fixtureMembership` childNumber) additionalTrackerNumbers))
    (IssueItem (baseIssue childNumber []))

fixtureStandaloneEntry :: Int -> ColumnEntry
fixtureStandaloneEntry number = Standalone (IssueItem (baseIssue number []))

fixtureBoard :: [(BoardColumn, [ColumnEntry])] -> Board
fixtureBoard populated = Board (Map.fromList ([(column, []) | column <- [minBound .. maxBound]] <> populated))

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
entryImplementationKey (TrackerHeader _) = Nothing

showText :: Show value => value -> Text
showText = Data.Text.pack . show

epoch :: UTCTime
epoch = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)

-- | An issue that exercises every §11 element at once: a title too long for
-- one row, more labels than two rows can hold plus GitHub-reported overflow,
-- an assignee, and a body far longer than the excerpt budget.
cardFixtureIssue :: Issue
cardFixtureIssue =
  Issue
    { issueNumber = 812,
      issueTitle = "Modal input leaks through the overlay and reaches the board beneath it",
      issueBody =
        "Empty modal areas currently allow pointer events to reach lower pages, which is "
          <> "visible whenever a dialog overlaps the world and the reviewer scrolls the board.",
      issueUrl = "https://example.test/issues/812",
      issueLabels =
        [ Label "ui" "5319e7",
          Label "bug" "d73a4a",
          Label "reviewed:approve" "2f9e44",
          Label "input" "0075ca",
          Label "code-health" "1d76db",
          Label "architecture" "0e8a16"
        ],
      issueAssignees = [Assignee "claude-agent"],
      issueCreatedAt = epoch,
      issueUpdatedAt = epoch,
      issueLabelOverflow = 2,
      issueAssigneeOverflow = 0
    }

cardFixtureEntry :: ColumnEntry
cardFixtureEntry = Standalone (IssueItem cardFixtureIssue)

-- | The same issue as a tracked child of two trackers, which adds the
-- tracker-context row above the title.
cardFixtureTrackedEntry :: ColumnEntry
cardFixtureTrackedEntry =
  Tracked
    (TrackingContext (TrackerMembership (fixtureTracker 700) (TrackerChild 812 (Just "F2") 1 False)) [fixtureMembership 701 812])
    (IssueItem cardFixtureIssue)

-- | A tracked child whose implementation key alone outgrows a narrow card, so
-- the tracker reference has to wrap rather than lose its tail.
cardFixtureLongKeyTrackedEntry :: ColumnEntry
cardFixtureLongKeyTrackedEntry =
  Tracked
    (TrackingContext (TrackerMembership (fixtureTracker 700) (TrackerChild 812 (Just "phase-two-renderer-contract") 1 False)) [])
    (IssueItem (baseIssue 812 []))

-- | A tracker whose checklist is malformed three separate ways, so the card
-- has more than one diagnostic to keep visible.
cardFixtureDiagnosticEntry :: ColumnEntry
cardFixtureDiagnosticEntry =
  Standalone
    ( IssueItem
        (baseIssue 900 [])
          { issueLabels = [Label "epic" "5319e7"],
            issueBody = "## Children\n- [ ] #2 — A1: Valid\n- [ ] missing reference\n- [?] #3\n- [x] #2 — duplicate"
          }
    )

-- | A pull request, which carries the CI/merge status row cards must keep.
cardFixturePullRequestEntry :: ColumnEntry
cardFixturePullRequestEntry =
  Standalone
    ( PullRequestItem
        (basePullRequest 823 [812] False [Label "reviewed:approve" "2f9e44", Label "input" "0075ca"])
          { pullRequestTitle = "Route Shift-wheel through the modal-aware ownership path",
            pullRequestBody = "Routes Shift-wheel through the same modal-aware ownership path as ordinary wheel events.",
            pullRequestChecks = ChecksPassed 14,
            pullRequestMergeState = MergeClean,
            pullRequestReviewDecision = ReviewApproved
          }
    )

-- | A pull request carrying every §11 field at once: a head and base that
-- differ, more linked issues than GitHub returned, a behind branch, and a
-- rollup with both a failure and a still-running check.
detailsFixturePullRequest :: PullRequest
detailsFixturePullRequest =
  (basePullRequest 823 [36, 812] False [Label "reviewed:approve" "2f9e44", Label "input" "0075ca"])
    { pullRequestTitle = "Route Shift-wheel through the modal-aware path",
      pullRequestBody = "Routes Shift-wheel through the modal-aware ownership path.",
      pullRequestUrl = "https://example.test/pull/823",
      pullRequestBase = "master",
      pullRequestHead = "issue-36-details",
      pullRequestMergeState = MergeBehind,
      pullRequestChecks =
        ChecksFailed 9 12 [CheckDetail "integration-suite" CheckFailed, CheckDetail "docs-lint" CheckPending],
      pullRequestLabelOverflow = 2,
      pullRequestLinkedIssueOverflow = 3,
      pullRequestCreatedAt = epoch,
      pullRequestUpdatedAt = detailsFixtureUpdatedAt
    }

-- | The issue side of the same contract: retained assignees plus overflow,
-- tracker membership, and pull requests that link back to it.
detailsFixtureIssue :: Issue
detailsFixtureIssue =
  (baseIssue 36 [Assignee "worker", Assignee "second"])
    { issueTitle = "Details overlay omits most required fields",
      issueBody = "The overlay renders only a subset of the fields the design requires.",
      issueUrl = "https://example.test/issues/36",
      issueLabels = [Label "bug" "d73a4a"],
      issueAssigneeOverflow = 1,
      issueCreatedAt = epoch,
      issueUpdatedAt = detailsFixtureUpdatedAt
    }

detailsFixtureUpdatedAt :: UTCTime
detailsFixtureUpdatedAt = addUTCTime 86400 epoch

-- | A board holding both fixtures, a tracker that owns the issue, and a
-- second pull request linking the same issue, so the reverse-link derivation
-- has more than one PR to find.
detailsFixtureBoard :: Board
detailsFixtureBoard =
  deriveBoard
    defaultWorkflowConfig
    ( RepoSnapshot
        [ (baseIssue 900 [])
            { issueLabels = [Label "epic" "5319e7"],
              issueBody = "## Children\n- [ ] #36 — A1: Details overlay fields"
            },
          detailsFixtureIssue
        ]
        [detailsFixturePullRequest, basePullRequest 851 [36] False []]
        epoch
        False
        False
    )

-- | Draw the details overlay at the width the real overlay gives its content
-- and read it back as plain text.
renderDetails :: Board -> BoardItem -> [Text]
renderDetails = renderDetailsAt 84

renderDetailsAt :: Int -> Board -> BoardItem -> [Text]
renderDetailsAt width board item = renderWidgetLines (themeFor testOptions) width (hLimit width (drawDetails environment item))
  where
    environment =
      DetailsEnv
        { detailsConfig = testResolvedConfig,
          detailsBoard = board,
          -- Three hours after the fixtures were updated, so the relative age
          -- is computed from this redraw rather than stored with the item.
          detailsNow = addUTCTime (3 * 3600) detailsFixtureUpdatedAt,
          detailsTimeZone = utc
        }

-- | Every heading the overlay can draw, so a section can be read back as the
-- rows between its own heading and the next one.
detailsHeadings :: [Text]
detailsHeadings =
  [ "Metadata",
    "Assignees",
    "Author",
    "Branches",
    "Linked issues",
    "Linked pull requests",
    "Mergeability",
    "Checks",
    "Timestamps",
    "Tracker",
    "Tracker warnings",
    "Body",
    "URL"
  ]

-- | The rows of one overlay section.
detailsRows :: [Text] -> Text -> [Text]
detailsRows rendered heading =
  map Data.Text.strip (takeWhile (`notElem` detailsHeadings) (drop 1 (dropWhile (/= heading) rendered)))

-- | A section's rows rejoined into the single logical line they wrapped from.
detailsText :: [Text] -> Text -> Maybe Text
detailsText rendered heading = case detailsRows rendered heading of
  [] -> Nothing
  rows -> Just (Data.Text.unwords rows)

-- | Draw one card at a fixed width and read the frame back as plain text, the
-- way a terminal would show it.
renderCard :: Options -> Bool -> ColumnEntry -> Int -> [Text]
renderCard options selected entry width =
  renderWidgetLines (themeFor options) width (hLimit width (drawCardFrame environment selected entry))
  where
    environment =
      CardEnv
        { cardOptions = options,
          cardConfig = testResolvedConfig,
          cardNow = epoch,
          cardSolveSessions = Map.empty
        }

renderWidgetLines :: AttrMap -> Int -> Widget Name -> [Text]
renderWidgetLines theme width widget =
  dropWhileEnd Data.Text.null (map rowText (Vector.toList (displayOpsForPic picture region)))
  where
    region = (width, 80)
    picture = renderWidget (Just theme) [widget] region
    rowText = Data.Text.stripEnd . foldMap spanText . Vector.toList
    spanText (TextSpan _ _ _ value) = LazyText.toStrict value
    spanText (Skip columns) = Data.Text.replicate columns " "
    spanText (RowEnd columns) = Data.Text.replicate columns " "

-- | The interior of a card frame: every row between the top and bottom
-- borders, with the side borders stripped.
cardInterior :: [Text] -> [Text]
cardInterior rendered = map (Data.Text.dropEnd 1 . Data.Text.drop 1) (drop 1 (dropLast rendered))
  where
    dropLast [] = []
    dropLast rows = take (length rows - 1) rows

-- | The frame's left and right border columns, top to bottom. Equal-length
-- runs of edge glyphs are what proves the frame matches the content height.
cardBorderColumns :: [Text] -> ([Text], [Text])
cardBorderColumns rendered = (map (Data.Text.take 1) rendered, map (Data.Text.takeEnd 1) rendered)

isLeft :: Either left right -> Bool
isLeft (Left _) = True
isLeft (Right _) = False

isRight :: Either left right -> Bool
isRight (Right _) = True
isRight (Left _) = False

isLeftText :: Either Text value -> Bool
isLeftText (Left _) = True
isLeftText (Right _) = False

unsafeConfig :: Either Text (RawConfig, [Text]) -> (RawConfig, [Text])
unsafeConfig = either (error . Data.Text.unpack) id

errorContains :: [Text] -> Either Text value -> Bool
errorContains needles (Left message) = all (`Data.Text.isInfixOf` message) needles
errorContains _ (Right _) = False

-- | A rejected remote must show the offending value and point at the
-- documented escape hatch, so the user can act without reading the source.
rejectsWithGuidance :: Text -> Either Text value -> Bool
rejectsWithGuidance remoteValue = errorContains [remoteValue, "--repo OWNER/NAME"]

-- | The gh flag a GraphQL variable is passed with, or 'Nothing' when the
-- variable is absent from the argument vector.
flagForVariable :: String -> [String] -> Maybe String
flagForVariable variableName =
  fmap fst . find (((variableName <> "=") `isPrefixOf`) . snd) . flaggedArguments
  where
    flaggedArguments (flag : value : rest)
      | flag `elem` ["-f", "-F"] = (flag, value) : flaggedArguments rest
    flaggedArguments (_ : rest) = flaggedArguments rest
    flaggedArguments [] = []

-- Workflow-preflight fixtures ------------------------------------------------

isNotAuthenticated :: AuthObservation -> Bool
isNotAuthenticated (AuthNotAuthenticated _) = True
isNotAuthenticated _ = False

isUnknownAuth :: AuthObservation -> Bool
isUnknownAuth (AuthUnknown _) = True
isUnknownAuth _ = False

isUnknownBundle :: BundleObservation -> Bool
isUnknownBundle (BundleUnknown _) = True
isUnknownBundle _ = False

isUnknownVersion :: VersionObservation -> Bool
isUnknownVersion (VersionUnknown _) = True
isUnknownVersion _ = False

readyProviderProbe :: SolverBrand -> ProviderProbe
readyProviderProbe brand =
  ProviderProbe
    { probeBrand = brand,
      probeExecutable = Just "/fixture/bin/agent",
      probeVersion = VersionSupported "9.9.9",
      probeAuth = AuthAuthenticated,
      probeBundle = BundleEnabled
    }

readyPreflightEnvironment :: PreflightEnvironment
readyPreflightEnvironment =
  PreflightEnvironment
    { environmentCodex = readyProviderProbe CodexSolver,
      environmentClaude = readyProviderProbe ClaudeSolver,
      environmentGitHub = GitHubReady,
      environmentReviewBackend = ReviewBackendReadyAt "/fixture/approve_issues.py"
    }

withCodexProbe :: ProviderProbe -> PreflightEnvironment
withCodexProbe probe = readyPreflightEnvironment {environmentCodex = probe}

withClaudeProbe :: ProviderProbe -> PreflightEnvironment
withClaudeProbe probe = readyPreflightEnvironment {environmentClaude = probe}

blockedProblems :: PreflightEnvironment -> PreflightAction -> [PreflightProblem]
blockedProblems environment action =
  [ problem
    | check <- (actionReport environment action).reportChecks,
      PreflightBlocked problem _ _ <- [check.checkStatus]
  ]

isConflictingBackend :: ReviewBackendObservation -> Bool
isConflictingBackend (ReviewBackendConflicting _ _) = True
isConflictingBackend _ = False

isMissingBackend :: ReviewBackendObservation -> Bool
isMissingBackend (ReviewBackendMissing _) = True
isMissingBackend _ = False

isReadyBackend :: ReviewBackendObservation -> Bool
isReadyBackend (ReviewBackendReadyAt _) = True
isReadyBackend _ = False

-- | Every executable a fully provisioned machine resolves, so a backend
-- scenario is only ever about the backend.
fullyProvisionedFakes :: [(String, [ByteString.ByteString])]
fullyProvisionedFakes = [readyCodexFake, readyClaudeFake, readyGitHubFake, python3Fake]

-- | What the Kanban-managed canonical review backend's install directory
-- holds on the fresh machine a scenario probes. Only 'BackendInstalled' is
-- what @tools\/install_issue_review.py@ actually produces: a symlink, per
-- installed asset, to a checkout file carrying that asset's identity
-- marker. Every other constructor is a state setup would refuse.
data BackendFixture
  = BackendInstalled
  | BackendMissing
  | BackendOccupied
  | BackendOrdinaryFile
  | BackendDanglingLink
  | BackendForeignLink
  | BackendCompanionMissing

-- | A hermetic fresh machine: a PATH holding only the fake executables the
-- scenario installs, a Kanban install directory it populates, and a log
-- every fake appends its argument vector to so a test can assert nothing
-- beyond a status-only probe was ever run. No credentials, network access,
-- or model call is involved.
withPreflightMachine ::
  [(String, [ByteString.ByteString])] ->
  BackendFixture ->
  (FilePath -> FilePath -> IO result) ->
  IO result
withPreflightMachine executables backend action =
  withTemporaryCacheRoot $ \temporaryRoot -> do
    let binaryRoot = temporaryRoot </> "bin"
        installRoot = temporaryRoot </> "issue-review"
        workingDirectory = temporaryRoot </> "repo"
        probeLog = temporaryRoot </> "probes.log"
        backendPath = installRoot </> "approve_issues.py"
    mapM_ (createDirectoryIfMissing True) [binaryRoot, installRoot, workingDirectory]
    mapM_ (installFakeExecutable binaryRoot) executables
    let installAsset name = do
          let checkoutFile = temporaryRoot </> ("checkout-" <> name)
          ByteString.writeFile
            checkoutFile
            (ByteString.pack ("# kanban-managed-asset:issue-review/" <> name <> "\n"))
          createFileLink checkoutFile (installRoot </> name)
        installCompanion = installAsset "kanban_config.py"
    case backend of
      BackendInstalled -> installAsset "approve_issues.py" >> installCompanion
      BackendMissing -> pure ()
      BackendOccupied -> createDirectoryIfMissing True backendPath >> installCompanion
      BackendOrdinaryFile -> ByteString.writeFile backendPath "#!/usr/bin/env python3\n" >> installCompanion
      BackendDanglingLink -> createFileLink (temporaryRoot </> "gone.py") backendPath >> installCompanion
      BackendForeignLink -> do
        -- A perfectly good script that simply is not Kanban's: readable,
        -- resolvable, and sitting under a plausible tools/ path.
        let foreign_ = temporaryRoot </> "elsewhere" </> "tools"
        createDirectoryIfMissing True foreign_
        ByteString.writeFile (foreign_ </> "approve_issues.py") "#!/usr/bin/env python3\nprint('not kanban')\n"
        createFileLink (foreign_ </> "approve_issues.py") backendPath
        installCompanion
      BackendCompanionMissing -> installAsset "approve_issues.py"
    withEnvironmentValue "PATH" binaryRoot $
      withEnvironmentValue "KANBAN_ISSUE_REVIEW_INSTALL_DIR" installRoot $
        withEnvironmentValue "KANBAN_TEST_PROBE_LOG" probeLog $
          action workingDirectory probeLog

installFakeExecutable :: FilePath -> (String, [ByteString.ByteString]) -> IO ()
installFakeExecutable binaryRoot (name, body) = do
  let path = binaryRoot </> name
  ByteString.writeFile
    path
    (ByteString.unlines (["#!/bin/sh", "printf '%s\\n' \"$*\" >> \"$KANBAN_TEST_PROBE_LOG\""] <> body))
  setFileMode path 0o700

-- | Everything on the fresh machine a probe could have written to,
-- snapshotted so a test can prove the doctor path changed none of it.
machineSnapshot :: FilePath -> IO [(FilePath, [FilePath])]
machineSnapshot workingDirectory = do
  let temporaryRoot = takeDirectory workingDirectory
  mapM
    (\name -> (,) name . sortOn id <$> listDirectory (temporaryRoot </> name))
    ["bin", "issue-review", "repo"]

probeInvocations :: FilePath -> IO [String]
probeInvocations probeLog = do
  present <- doesFileExist probeLog
  if present then lines <$> readFile probeLog else pure []

-- | Exactly the status-only argument vectors 'gatherPreflightEnvironment'
-- is allowed to run. Anything else — an agent session, a login flow, a
-- write — would show up here as an unrecognized invocation.
allowedProbeInvocations :: [String]
allowedProbeInvocations =
  ["--version", "login status", "auth status", "plugin list --json"]

readyCodexFake :: (String, [ByteString.ByteString])
readyCodexFake =
  ( "codex",
    [ "case \"$*\" in",
      "  '--version') printf 'codex-cli 0.144.6\\n' ;;",
      "  'login status') printf 'Logged in using ChatGPT\\n' ;;",
      "  'plugin list --json') printf '%s\\n' '{\"installed\":[{\"pluginId\":\"kanban@kanban\",\"installed\":true,\"enabled\":true}]}' ;;",
      "  *) exit 1 ;;",
      "esac"
    ]
  )

signedOutCodexFake :: (String, [ByteString.ByteString])
signedOutCodexFake =
  ( "codex",
    [ "case \"$*\" in",
      "  '--version') printf 'codex-cli 0.144.6\\n' ;;",
      "  'login status') printf 'Not logged in\\n'; exit 1 ;;",
      "  'plugin list --json') printf '%s\\n' '{\"installed\":[{\"pluginId\":\"kanban@kanban\",\"installed\":true,\"enabled\":true}]}' ;;",
      "  *) exit 1 ;;",
      "esac"
    ]
  )

bundlelessCodexFake :: (String, [ByteString.ByteString])
bundlelessCodexFake =
  ( "codex",
    [ "case \"$*\" in",
      "  '--version') printf 'codex-cli 0.144.6\\n' ;;",
      "  'login status') printf 'Logged in using ChatGPT\\n' ;;",
      "  'plugin list --json') printf '%s\\n' '{\"installed\":[]}' ;;",
      "  *) exit 1 ;;",
      "esac"
    ]
  )

readyClaudeFake :: (String, [ByteString.ByteString])
readyClaudeFake =
  ( "claude",
    [ "case \"$*\" in",
      "  '--version') printf '2.1.220 (Claude Code)\\n' ;;",
      "  'auth status') printf '%s\\n' '{\"loggedIn\": true}' ;;",
      "  'plugin list --json') printf '%s\\n' '[{\"id\":\"kanban@kanban\",\"enabled\":true}]' ;;",
      "  *) exit 1 ;;",
      "esac"
    ]
  )

readyGitHubFake :: (String, [ByteString.ByteString])
readyGitHubFake =
  ( "gh",
    [ "case \"$*\" in",
      "  'auth status') printf 'Logged in to github.com\\n' ;;",
      "  *) exit 1 ;;",
      "esac"
    ]
  )

signedOutGitHubFake :: (String, [ByteString.ByteString])
signedOutGitHubFake =
  ( "gh",
    [ "case \"$*\" in",
      "  'auth status') printf 'You are not logged into any GitHub hosts\\n'; exit 1 ;;",
      "  *) exit 1 ;;",
      "esac"
    ]
  )

-- | Only ever resolved, never run: the canonical review backend's
-- interpreter has to exist for the backend check to be about the backend.
python3Fake :: (String, [ByteString.ByteString])
python3Fake = ("python3", ["exit 0"])

testOptions :: Options
testOptions =
  Options
    { optionPath = ".",
      optionRepo = Nothing,
      optionColor = ColorAuto,
      optionBorder = BorderBox,
      optionGlyphTest = False,
      optionDoctor = False,
      optionAscii = False,
      optionNoCache = False,
      optionConfig = Nothing,
      optionWorkerSpec = Nothing
    }

testResolvedConfig :: ResolvedConfig
testResolvedConfig =
  ResolvedConfig
    { resolvedCache = True,
      resolvedRemoteName = "origin",
      resolvedWorkflow = defaultWorkflowConfig,
      resolvedLimits = defaultLimitsConfig,
      resolvedTimeouts = defaultTimeoutsConfig,
      resolvedUsage = defaultUsageConfig
    }

fullFixtureToml :: Text
fullFixtureToml =
  "cache = false\n"
    <> "remote_name = \"upstream\"\n"
    <> "\n"
    <> "[workflow]\n"
    <> "approval_label = \"lgtm\"\n"
    <> "changes_requested_label = \"needs-work\"\n"
    <> "blocked_labels = [\"blocked\", \"urgent\"]\n"
    <> "tracker_labels = [\"epic\", \"tracker\"]\n"
    <> "additional_tracker_section_headings = [\"Milestones\"]\n"
    <> "approval_mode = \"either\"\n"
    <> "blocking_severity = \"amber\"\n"
    <> "\n"
    <> "[limits]\n"
    <> "max_open_issues = 500\n"
    <> "max_open_pull_requests = 200\n"
    <> "excerpt_lines = 5\n"
    <> "\n"
    <> "[timeouts]\n"
    <> "github_seconds = 60\n"
    <> "codex_seconds = 20\n"
    <> "claude_seconds = 90\n"
    <> "\n"
    <> "[usage.codex]\n"
    <> "command = [\"/usr/local/bin/my-codex-usage\", \"--json\"]\n"
    <> "\n"
    <> "[usage.claude]\n"
    <> "command = [\"/usr/local/bin/my-claude-usage\", \"--json\"]\n"
    <> "\n"
    <> "unknown_top_level_key = 1\n"
    <> "\n"
    <> "[repositories.\"coghex/kanban\".workflow]\n"
    <> "approval_label = \"ship-it\"\n"
    <> "\n"
    <> "[repositories.\"coghex/kanban\".limits]\n"
    <> "max_open_issues = 999\n"
    <> "\n"
    <> "[repositories.\"coghex/kanban\".timeouts]\n"
    <> "github_seconds = 15\n"
    <> "\n"
    <> "[repositories.\"other/repo\".workflow]\n"
    <> "approval_label = \"should-not-apply\"\n"

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

isSolveSessionIdentifiedEvent :: SolveEvent -> Bool
isSolveSessionIdentifiedEvent (SolveSessionIdentified _ _) = True
isSolveSessionIdentifiedEvent _ = False

isSolveOutputEvent :: SolveEvent -> Bool
isSolveOutputEvent (SolveOutput _ _) = True
isSolveOutputEvent _ = False

isPullRequestSessionIdentifiedEvent :: PullRequestFlowEvent -> Bool
isPullRequestSessionIdentifiedEvent (PullRequestSessionIdentified _ _) = True
isPullRequestSessionIdentifiedEvent _ = False

isPullRequestFlowOutputEvent :: PullRequestFlowEvent -> Bool
isPullRequestFlowOutputEvent (PullRequestFlowOutput _ _) = True
isPullRequestFlowOutputEvent _ = False

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
      workerMaxRuntimeSeconds = 60,
      workerConfigPath = Nothing,
      workerWorkflowConfig = defaultWorkflowConfig
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

requireJust :: String -> Maybe value -> IO value
requireJust message = maybe (fail message) pure

requireLeft :: String -> Either Text value -> IO Text
requireLeft message = either pure (const (fail message))

requireRight :: String -> Either Text value -> IO value
requireRight message = either (\failure -> fail (message <> ": " <> Data.Text.unpack failure)) pure

shouldMention :: Text -> Text -> Expectation
shouldMention haystack needle
  | Data.Text.isInfixOf needle haystack = pure ()
  | otherwise = expectationFailure ("expected " <> show haystack <> " to mention " <> show needle)

shouldNotMention :: Text -> Text -> Expectation
shouldNotMention haystack needle
  | Data.Text.isInfixOf needle haystack = expectationFailure ("expected " <> show haystack <> " not to mention " <> show needle)
  | otherwise = pure ()

-- | A fake @gh@ on a temporary PATH plus a review client wired to the given
-- 'CommandBounds', so the deadline and capture-grace paths are reachable in
-- well under a second instead of the production 30 s.
withFakeGitHubCli :: [ByteString.ByteString] -> CommandBounds -> (ReviewClient -> IO result) -> IO result
withFakeGitHubCli scriptLines bounds action =
  withTemporaryCacheRoot $ \temporaryRoot -> do
    let repositoryRoot = temporaryRoot </> "repo"
        binaryRoot = temporaryRoot </> "bin"
        fakeGh = binaryRoot </> "gh"
    createDirectory repositoryRoot
    createDirectory binaryRoot
    -- Drain stdin first, as the real `gh issue comment --body-file -` does.
    -- 'runGitHubCommand' always writes the request body and closes its end,
    -- so a fake that exited without reading would leave that write to fail
    -- with EPIPE at the flush -- a fixture artifact that says nothing about
    -- the capture bounds under test, and one whose timing differs by
    -- platform.
    ByteString.writeFile fakeGh (ByteString.unlines ("#!/bin/sh" : "cat >/dev/null" : scriptLines))
    setFileMode fakeGh 0o700
    originalPath <- maybe "" id <$> lookupEnv "PATH"
    withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $
      bracket
        (newReviewClientForTesting bounds repositoryRoot "coghex/kanban" (const (pure ())))
        stopReviewClient
        action

runBoundedGitHubTool :: Int -> ReviewClient -> GitHubIssueToolRequest -> IO (Either Text Text)
runBoundedGitHubTool boundMicros client request = do
  outcome <- timeout boundMicros (withReservedToolSlot client "thread-1" (\key -> runGitHubIssueTool client key request))
  requireJust "the GitHub tool call did not return within its bounded window" outcome

-- | A fake canonical reviewer executable, with @XDG_CACHE_HOME@ pointed at
-- the temporary root so the run's session log lands somewhere inspectable.
withFakeCanonicalReviewer :: [ByteString.ByteString] -> (FilePath -> Repository -> FilePath -> IO result) -> IO result
withFakeCanonicalReviewer scriptLines action =
  withTemporaryCacheRoot $ \temporaryRoot -> do
    let repositoryRoot = temporaryRoot </> "repo"
        binaryRoot = temporaryRoot </> "bin"
        fakeReviewer = binaryRoot </> "approve-issues"
    createDirectory repositoryRoot
    createDirectory binaryRoot
    ByteString.writeFile fakeReviewer (ByteString.unlines ("#!/bin/sh" : scriptLines))
    setFileMode fakeReviewer 0o700
    withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
      action temporaryRoot (Repository repositoryRoot "coghex" "kanban") fakeReviewer

runBoundedCanonicalCommand :: Int -> CommandBounds -> Repository -> FilePath -> IO (Either Text Text)
runBoundedCanonicalCommand boundMicros bounds repository executable = do
  outcome <- timeout boundMicros (runCanonicalCommand bounds repository 15 executable [] (const (pure ())))
  requireJust "the canonical review call did not return within its bounded window" outcome

canonicalSessionLogText :: FilePath -> IO String
canonicalSessionLogText cacheRoot = do
  let logDirectory = cacheRoot </> "kanban" </> "logs" </> "coghex-kanban"
  entries <- listDirectory logDirectory
  concat <$> mapM (readFile . (logDirectory </>)) entries

waitForFileToExist :: FilePath -> Int -> IO ()
waitForFileToExist path attempts = do
  exists <- doesFileExist path
  if exists
    then pure ()
    else
      if attempts <= 0
        then fail ("expected " <> path <> " to exist")
        else threadDelay 100000 >> waitForFileToExist path (attempts - 1)

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

-- | A rollup holding a superseded failure (now green), a current failure, and
-- a rerun that is still running, so the aggregate counts and the retained
-- detail both have something to select from.
githubMixedChecksResponse :: String
githubMixedChecksResponse =
  githubChecksResponse
    5
    [ checkRunJson "build-test" "SUCCESS" "2026-07-17T14:43:00Z",
      checkRunJson "integration-suite" "SUCCESS" "2026-07-17T14:40:00Z",
      checkRunJson "integration-suite" "FAILURE" "2026-07-17T14:50:00Z",
      checkRunJson "smoke" "FAILURE" "2026-07-17T14:30:00Z",
      runningCheckRunJson "smoke" "2026-07-17T14:55:00Z"
    ]

-- | A rollup GitHub reports as larger than the 100 contexts §13 requests.
githubCappedChecksResponse :: String
githubCappedChecksResponse =
  githubChecksResponse 150 [checkRunJson "build-test" "SUCCESS" "2026-07-17T14:43:00Z"]

-- | One open pull request whose only interesting field is its check rollup.
githubChecksResponse :: Int -> [String] -> String
githubChecksResponse totalCount nodes =
  unlines
    [ "{\"data\":{\"repository\":{",
      "\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}},",
      "\"pullRequests\":{\"nodes\":[{",
      "\"number\":860,\"title\":\"Mixed checks\",\"body\":\"Closes #36\",\"url\":\"https://example.test/pull/860\",",
      "\"labels\":{\"totalCount\":0,\"nodes\":[]},",
      "\"author\":{\"login\":\"author\"},\"isDraft\":false,\"baseRefName\":\"master\",\"headRefName\":\"fix\",",
      "\"closingIssuesReferences\":{\"totalCount\":1,\"nodes\":[{\"number\":36}]},",
      "\"reviewDecision\":null,\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"UNSTABLE\",",
      "\"statusCheckRollup\":{\"contexts\":{\"totalCount\":" <> show totalCount <> ",\"nodes\":[",
      intercalate "," nodes,
      "]}},",
      "\"createdAt\":\"2026-07-17T13:21:31Z\",\"updatedAt\":\"2026-07-17T14:48:47Z\"",
      "}],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}",
      "}}}"
    ]

runningCheckRunJson :: String -> String -> String
runningCheckRunJson name startedAt =
  "{\"__typename\":\"CheckRun\",\"name\":\""
    <> name
    <> "\",\"status\":\"IN_PROGRESS\",\"conclusion\":null,\"startedAt\":\""
    <> startedAt
    <> "\",\"checkSuite\":{\"app\":{\"slug\":\"github-actions\"}}}"

-- | A cache file exactly as version 2 wrote one: the current envelope shape,
-- but with a check summary carrying only its two aggregate counts. Everything
-- else is the current encoder's own output, so the only thing that cannot
-- decode under the current schema is the part version 3 actually changed.
versionTwoCacheFile :: Int -> ByteString.ByteString
versionTwoCacheFile version =
  ByteString.pack
    ( "{\"schemaVersion\":"
        <> show version
        <> ",\"repositoryKey\":\"coghex/kanban\",\"snapshot\":{"
        <> "\"snapshotFetchedAt\":\"2026-01-01T00:00:00Z\",\"snapshotIssues\":[],"
        <> "\"snapshotIssuesTruncated\":false,\"snapshotPullRequestsTruncated\":false,"
        <> "\"snapshotPullRequests\":[{"
        <> "\"pullRequestAuthor\":\"agent\",\"pullRequestBase\":\"master\",\"pullRequestBody\":\"B\","
        <> "\"pullRequestChecks\":{\"contents\":[1,2],\"tag\":\"ChecksFailed\"},"
        <> "\"pullRequestCreatedAt\":\"2026-01-01T00:00:00Z\",\"pullRequestDraft\":false,"
        <> "\"pullRequestHead\":\"branch\",\"pullRequestLabelOverflow\":0,\"pullRequestLabels\":[],"
        <> "\"pullRequestLinkedIssueOverflow\":0,\"pullRequestLinkedIssues\":[36],"
        <> "\"pullRequestMergeState\":\"MergeUnknown\",\"pullRequestNumber\":823,"
        <> "\"pullRequestReviewDecision\":\"ReviewRequired\",\"pullRequestTitle\":\"T\","
        <> "\"pullRequestUpdatedAt\":\"2026-01-01T00:00:00Z\",\"pullRequestUrl\":\"u\"}]}}"
    )

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
