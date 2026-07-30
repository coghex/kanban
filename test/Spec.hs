-- | The Haskell test suite's entry point. The @managed agent processes@ group
-- lives in @Spec.Agent.ManagedProcess@ and the shared fixtures in
-- @Spec.Support@; the remaining groups are still inline here and move out
-- next. Group order is unchanged.
module Main (main) where

import Brick (BrickEvent (..), Location (..))
import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (throwIO, throwTo)
import Control.Monad (foldM, void)
import Data.Aeson (Value (..), eitherDecode, object, (.=))
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.Char (isControl)
import Data.IORef (modifyIORef, newIORef, readIORef, writeIORef)
import Data.Foldable (for_)
import Data.List (findIndex, intercalate, isInfixOf, nub, sort, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, minutesToTimeZone)
import qualified Graphics.Vty as Vty
import Kanban.CLI (ColorPolicy (..), Options (..))
import Kanban.Cache
  ( CacheLoad (..),
    UsageCacheLoad (..),
    ghGroupRecordPath,
    loadRepositoryCache,
    loadUsageCache,
    repositoryCachePath,
    repositoryCacheSchemaVersion,
    usageCachePath,
    writeGhGroupRecord,
    writeRepositoryCache,
    writeUsageCache
  )
import Kanban.Card (CardChip (..), boundedLines, displayWidth, labelChipRows)
import Kanban.Claude (decodeClaudeUsageText, runClaudeProvider)
import Kanban.Codex (decodeCodexUsageResponse)
import Kanban.Config
import Kanban.Domain
import Kanban.Drainer
  ( DrainerController (..),
    DrainerRecord (..),
    DrainerState (..),
    DrainerStatus (..),
    DrainerToggle (..),
    controllerFromProgramArguments,
    decodeDrainerStatus,
    drainerIsRunning,
    drainerRecordFromBytes,
    drainerRecordPath,
    drainerToggle,
    resolveDrainerPlist,
    runDrainerCommand,
    statusFromControllerExit,
    unreadablePlist
  )
import Kanban.GitHub
  ( FetchState (..),
    GhCleanupFailure (..),
    GhCleanupGuard (..),
    GhFailurePhase (..),
    GitHubResult (..),
    advanceState,
    classifyFailure,
    compactError,
    confirmsOwnGroupLeadership,
    decodeGitHubItems,
    ghBehindBarrier,
    ghFailureKind,
    groupConfirmedEmpty,
    graphqlArguments,
    paginationDecision,
    snapshotWarnings
  )
import Kanban.Layout (responsiveColumnWidths, responsiveOpenColumnWidths)
import Kanban.Preflight
  ( AuthObservation (..),
    BundleObservation (..),
    GitHubObservation (..),
    IssueOrigin (..),
    PreflightAction (..),
    PreflightEnvironment (..),
    PreflightProblem (..),
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
    reviewBackendAction,
    revisionAuthorBrand
  )
import Kanban.Process
  ( OwnedProcessGroup (..),
    ProcessIdentity (..),
    identityForPid,
    killManagedProcess,
    managedProcessPid,
    matchingIdentities,
    readProcessSnapshot
  )
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
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
    runPullRequestFlowWith
  )
import Kanban.Repository (parseRemoteRepository, parseRepositoryName, resolveRepository)
import Kanban.Review
  ( CanonicalIssueReviewResult (..),
    CommandBounds (..),
    GitHubIssueOperation (..),
    GitHubIssueToolRequest (..),
    ReviewApproval (..),
    ReviewChoice (..),
    ReviewEvent (..),
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
    handleWireMessage,
    killThreadToolProcesses,
    newReviewClientForTesting,
    newToolRegistry,
    releaseToolSlot,
    reserveToolSlot,
    resolveCanonicalIssueReviewer,
    githubCommandBounds,
    reviewStageForLabels,
    runGitHubIssueTool,
    sendReviewMessage,
    stopReviewClient,
    renderCanonicalIssueReviewResult,
    renderReviewResult,
    withReservedToolSlot
  )
import Kanban.Settings
  ( ChatVerbosity (..),
    Settings (..),
    defaultSettings,
    loadSettings,
    saveSettings,
    settingsPath
  )
import Kanban.Solve
  ( AgentEvent (..),
    ResumeProvenance (..),
    SolveEvent (..),
    SolveOutcome (..),
    SolveWorkflow (..),
    SolverBrand (..),
    StreamEvent (..),
    maxUnknownNoticeLength,
    newUnknownAggregator,
    parseSolveOutputLine,
    renderAgentEvent,
    resumeProvenanceHeader,
    runSolve,
    runSolveWith,
    solveArguments,
    solveOutcome,
    unknownNoticeSamples
  )
import Kanban.StreamReader
  ( StreamOutcome (..),
    handleReadLine,
    maxConsecutiveReadFailures,
    onStreamAbandoned,
    runStreamReader,
    runStreamReaderWith
  )
import Kanban.Text (excerpt, sanitizeText)
import Kanban.Tracker
  ( implementationSortKey,
    parseTrackerBody,
    parseTrackerChildren,
    renderTrackerDiagnostic
  )
import Kanban.Transcript
  ( closeSessionLog,
    logRawLine,
    openSessionLog,
    sessionLogPath,
    transcriptRoot
  )
import Kanban.UI
  ( AgentSessionEntry (..),
    AgentSessionRef (..),
    BoardRefreshOutcome (..),
    ChatTranscript (..),
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
    applyUndeliveredSteer,
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
    liveReviewSessions,
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
    drawUndeliveredSteers,
    githubRefreshTimeoutMicros,
    itemHasAmberWarning,
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
    reusableSolveSession,
    reviewAgentSessionEntry,
    reviewPhaseAttribute,
    reviewPhaseGlyphFor,
    reviewPhaseLabel,
    reviewSessionLive,
    reviewSessionReusable,
    reviewSessionsNeedingArm,
    reviewTurnInterruptible,
    revisedAttr,
    solveSessionAlreadyResolved,
    themeFor,
    trackerAttr,
    trackerHeaderAttribute,
    transcriptScrollKey,
    transcriptShouldTail,
    unverifiedRefreshNotice,
    visibleSelectionRows
  )
import Kanban.Worker (WorkerId (..), workerDeadlineReason)
import Kanban.Workflow
  ( CardStatus (..),
    deriveBoard,
    entryItem,
    isProblem,
    orderCardLabels,
    pullRequestStatus
  )
import qualified Spec.Agent.ManagedProcess as ManagedProcess
import Spec.Support.Board
  ( captureBoardRefresh,
    forcedCleanupRun,
    heldOffMessage,
    readMarkerPid,
    withFakeGh
  )
import Spec.Support.ClaudeProbe
  ( ClaudeProbeFixture (..),
    ClaudeSignalPolicy (..),
    withClaudeProbeFixture
  )
import Spec.Support.Env
  ( createTemporaryDirectory,
    permissionsOf,
    waitForFileToExist,
    withEnvironmentValue,
    withFakeOnPath,
    withFileCreationMask,
    withTemporaryCacheRoot,
    withoutEnvironmentValue
  )
import Spec.Support.Expect
  ( countOccurrences,
    errorContains,
    flagForVariable,
    isInvalidCache,
    isInvalidUsageCache,
    isLeft,
    isLeftText,
    isRight,
    rejectsWithGuidance,
    requireJust,
    requireLeft,
    requireRight,
    shouldMention,
    shouldNotMention,
    unsafeConfig
  )
import Spec.Support.Fixtures
  ( baseIssue,
    basePullRequest,
    cardFixtureDiagnosticEntry,
    cardFixtureEntry,
    cardFixtureLongKeyTrackedEntry,
    cardFixturePullRequestEntry,
    cardFixtureTrackedEntry,
    detailsFixtureBoard,
    detailsFixtureIssue,
    detailsFixturePullRequest,
    entryImplementationKey,
    epoch,
    fixtureBoard,
    fixtureStandaloneEntry,
    fixtureTrackedEntry,
    fixtureTracker,
    fullFixtureToml,
    isStandaloneIssue,
    isTrackerHeaderEntry,
    itemNumber,
    testOptions,
    testResolvedConfig,
    zeroChildDiagnostics,
    zeroChildTracker
  )
import Spec.Support.Json
  ( checkRunJson,
    claudeUsageOutput,
    codexRateLimitResponse,
    codexWeeklyOnlyResponse,
    completedOnlyCheckRunJson,
    emptyAssigneesJson,
    emptyClosingIssuesJson,
    emptyGraphqlPage,
    emptyLabelsJson,
    futureCheckContextJson,
    githubCappedChecksResponse,
    githubChecksResponse,
    githubMixedChecksResponse,
    githubPageWith,
    githubPageWithErrors,
    githubRerunResponse,
    githubResponse,
    graphqlErrorsOnly,
    issueNodeJson,
    namelessCheckRunJson,
    pullRequestNodeJson,
    queuedCheckRunJson,
    rollupJson,
    statusContextJson,
    undatedCheckRunJson,
    versionThreeCacheFile,
    versionTwoCacheFile
  )
import Spec.Support.Locale
  ( LocaleProbe (..),
    localeProbeVariable,
    runLocaleProbe,
    unicodeCheckoutName,
    unicodeFailureText,
    unicodeIssueTitles,
    withLocaleProbe
  )
import Spec.Support.Preflight
  ( BackendFixture (..),
    allowedProbeInvocations,
    blockedProblems,
    bundlelessCodexFake,
    fullyProvisionedFakes,
    hangingGitHubFake,
    isConflictingBackend,
    isMissingBackend,
    isNotAuthenticated,
    isReadyBackend,
    isUnknownAuth,
    isUnknownBundle,
    isUnknownVersion,
    machineSnapshot,
    probeInvocations,
    python3Fake,
    readyClaudeFake,
    readyCodexFake,
    readyGitHubFake,
    readyPreflightEnvironment,
    readyProviderProbe,
    signedOutCodexFake,
    signedOutGitHubFake,
    undecodableCodexFake,
    withClaudeProbe,
    withCodexProbe,
    withPreflightMachine
  )
import Spec.Support.Process
  ( aggregatedNotices,
    canonicalSessionLogText,
    chattyProvider,
    chattyProviderLines,
    encodedValue,
    expectNoFurtherClientRequests,
    fakeController,
    isPullRequestFlowOutputEvent,
    isPullRequestSessionIdentifiedEvent,
    isSolveOutputEvent,
    isSolveSessionIdentifiedEvent,
    managedProcessFor,
    nextClientRequest,
    plainChatTranscript,
    protocolWarnings,
    rawTelemetryLines,
    readRecordedPid,
    runBoundedCanonicalCommand,
    runBoundedClaudeCall,
    runBoundedGitHubTool,
    shouldRecordASweptProcess,
    singleNotice,
    undeliveredSteers,
    withFakeCanonicalReviewer,
    withFakeClaudeCli,
    withFakeGitHubCli,
    withManagedShell,
    withNonLeaderProcess,
    withRecordingReviewClient,
    withSurvivingGroupLeader
  )
import Spec.Support.Render
  ( cardBorderColumns,
    cardInterior,
    detailsRows,
    detailsText,
    renderCard,
    renderDetails,
    renderDetailsAt,
    renderWidgetLines
  )
import System.Directory (createDirectory, createDirectoryIfMissing, doesFileExist, findExecutable)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, takeDirectory, (</>))
import System.IO (hClose)
import System.IO.Error
  ( doesNotExistErrorType,
    fullErrorType,
    mkIOError,
    permissionErrorType,
    resourceVanishedErrorType
  )
import System.Posix.Files (setFileMode)
import System.Process
  ( CreateProcess (..),
    StdStream (CreatePipe),
    createProcess,
    getPid,
    getProcessExitCode,
    proc,
    readProcessWithExitCode,
    waitForProcess
  )
import System.Timeout (timeout)
import Test.Hspec

-- | Ordinarily the suite. When 'localeProbeVariable' is set this process is
-- the C-locale child a single test re-ran the binary as, and it runs that
-- probe instead — see "Spec.Support.Locale" for why the condition cannot be
-- established from inside an already-started test process.
main :: IO ()
main = lookupEnv localeProbeVariable >>= maybe (hspec suite) runLocaleProbe

suite :: Spec
suite = do
  ManagedProcess.spec
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

    -- The Claude reviewer was the third short-lived runner in this module and
    -- the one #15 never enumerated, so it kept the very hGetContents-plus-
    -- takeMVar shape that fix existed to remove (issue #154). Its answer is
    -- prose read by a model rather than a URL or a JSON verdict, so unlike the
    -- two runners above a truncated capture stays a *success* carrying what
    -- arrived -- but it is never a timeout, and never outcome-unknown.
    it "round-trips an ordinary fast claude reviewer call unchanged" $
      withFakeClaudeCli ["printf '%s' 'reviewer answer'"] injectedBounds $ \_ client -> do
        result <- runBoundedClaudeCall boundedCallMicros client "review this"
        result `shouldBe` Right "reviewer answer"

    it "returns the prefix captured before the grace expired when a forked child holds claude's stdout open, never a timeout" $
      withFakeClaudeCli
        [ "sleep 30 &",
          "echo $! > \"$CLAUDE_CHILD_MARKER\"",
          "printf '%s' 'partial verdict'",
          "exit 0"
        ]
        injectedBounds
        $ \markerPath client -> do
          result <- runBoundedClaudeCall boundedCallMicros client "review this"
          output <- requireRight "expected a clean exit with truncated stdout to keep what was captured" result
          output `shouldMention` "partial verdict"
          output `shouldMention` "Incomplete output"
          output `shouldMention` "still incomplete after"
          output `shouldNotMention` "timed out"
          -- The marker this path must not carry: 'CommandExited' already
          -- established the exit, and the run is read-only, so there is
          -- neither an unknown outcome nor anything to re-verify.
          output `shouldNotMention` "outcome is unknown"
          output `shouldNotMention` "may already have completed"
          markerPath `shouldRecordASweptProcess` "the child holding claude's stdout open"

    it "describes an incomplete capture that yielded nothing as incomplete rather than as no output" $
      withFakeClaudeCli
        [ "sleep 30 &",
          "echo $! > \"$CLAUDE_CHILD_MARKER\"",
          "exit 0"
        ]
        injectedBounds
        $ \_ client -> do
          result <- runBoundedClaudeCall boundedCallMicros client "review this"
          output <- requireRight "expected an empty truncated capture to still be reported as incomplete" result
          output `shouldMention` "Incomplete output"
          output `shouldMention` "nothing had been captured"
          output `shouldNotMention` "Claude returned no reviewer output"
          output `shouldNotMention` "timed out"

    it "still reports a claude reviewer that outlives its own deadline as a timeout, sweeping its process group" $
      withFakeClaudeCli ["echo $$ > \"$CLAUDE_CHILD_MARKER\"", "sleep 30"] injectedBounds $ \markerPath client -> do
        result <- runBoundedClaudeCall boundedCallMicros client "review this"
        message <- requireLeft "expected a claude reviewer past its deadline to time out" result
        message `shouldBe` "Claude Sonnet 5 revision agent timed out after ten minutes"
        markerPath `shouldRecordASweptProcess` "the claude reviewer that outlived its deadline"

    it "still succeeds unchanged when only claude's stderr is held open past the grace" $
      withFakeClaudeCli ["sleep 30 >/dev/null &", "printf '%s' 'complete verdict'", "exit 0"] injectedBounds $ \_ client -> do
        result <- runBoundedClaudeCall boundedCallMicros client "review this"
        result `shouldBe` Right "complete verdict"

    it "keeps an observed nonzero claude exit a status failure carrying whatever prefixes were captured" $
      withFakeClaudeCli ["sleep 30 &", "printf 'boom\\n' >&2", "exit 3"] injectedBounds $ \_ client -> do
        result <- runBoundedClaudeCall boundedCallMicros client "review this"
        message <- requireLeft "expected a nonzero claude exit to stay a nonzero-exit failure" result
        message `shouldMention` "Claude Sonnet 5 exited with status 3"
        message `shouldMention` "boom"
        message `shouldNotMention` "Incomplete output"
        message `shouldNotMention` "timed out"

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

  -- issue #17: a rejected turn/steer used to land in 'handleResponse''s
  -- catch-all arm as a generic protocol warning, so the feedback the user
  -- typed was neither retried, restored, nor flagged -- it vanished while the
  -- transcript still showed it as sent. These drive real responses through
  -- 'handleWireMessage' against a client whose app-server stdin is a readable
  -- pipe, so both halves of the contract are observed directly: what goes
  -- back out on the wire, and what the session is told.
  describe "rejected turn/steer recovery" $ do
    let steerThread = "thread-1" :: Text
        targetTurn = "turn-1" :: Text
        newerTurn = "turn-2" :: Text
        steerMessage = "actually, check the drainer path too" :: Text
        turnStarted turnId =
          WireNotification
            "turn/started"
            (object ["threadId" .= steerThread, "turn" .= object ["id" .= turnId]])
        turnCompleted =
          WireNotification
            "turn/completed"
            (object ["threadId" .= steerThread, "turn" .= object ["status" .= ("completed" :: Text)]])
        -- The app-server's own rejection when 'expectedTurnId' no longer
        -- names the running turn. The steer is the first request this client
        -- sends, so it carries id 2 (the testing client's counter starts at
        -- 2, matching the real one after 'initialize').
        steerRejected =
          WireResponse (Number 2) (Left (object ["message" .= ("expected turn is not active" :: Text)]))
        steerAccepted = WireResponse (Number 2) (Right (object []))
        sendSteer client = do
          sent <- sendReviewMessage client steerThread (Just targetTurn) steerMessage
          sent `shouldBe` Right ()

    it "resends the message as a new turn/start when the turn it aimed at has already completed" $
      withRecordingReviewClient $ \client wire events -> do
        handleWireMessage client (turnStarted targetTurn)
        sendSteer client
        (steerMethod, steerParams) <- nextClientRequest wire
        steerMethod `shouldBe` "turn/steer"
        encodedValue steerParams `shouldMention` ("\"expectedTurnId\":\"" <> targetTurn <> "\"")
        -- The race the issue describes: the targeted turn finishes in the
        -- instant between Enter and the request arriving.
        handleWireMessage client turnCompleted
        handleWireMessage client steerRejected
        (retryMethod, retryParams) <- nextClientRequest wire
        retryMethod `shouldBe` "turn/start"
        encodedValue retryParams `shouldMention` ("\"text\":\"" <> steerMessage <> "\"")
        -- Exactly one follow-up, and nothing reported to the session: the
        -- optimistic "You:" entry it already holds stayed accurate, so a
        -- second entry would duplicate it.
        expectNoFurtherClientRequests wire
        recorded <- readIORef events
        undeliveredSteers recorded `shouldBe` []
        protocolWarnings recorded `shouldBe` []

    it "hands the message back undelivered, sending nothing, when a newer turn is already running" $
      withRecordingReviewClient $ \client wire events -> do
        handleWireMessage client (turnStarted targetTurn)
        sendSteer client
        void (nextClientRequest wire)
        handleWireMessage client turnCompleted
        handleWireMessage client (turnStarted newerTurn)
        handleWireMessage client steerRejected
        -- Silently applying the guidance to a turn the user never aimed at
        -- is exactly the misdirection the rejection is warning about.
        expectNoFurtherClientRequests wire
        recorded <- readIORef events
        undeliveredSteers recorded `shouldBe` [ReviewSteerUndelivered steerThread targetTurn steerMessage]
        protocolWarnings recorded `shouldBe` []

    it "hands the message back undelivered when the targeted turn is still the running one" $
      withRecordingReviewClient $ \client wire events -> do
        handleWireMessage client (turnStarted targetTurn)
        sendSteer client
        void (nextClientRequest wire)
        handleWireMessage client steerRejected
        expectNoFurtherClientRequests wire
        recorded <- readIORef events
        undeliveredSteers recorded `shouldBe` [ReviewSteerUndelivered steerThread targetTurn steerMessage]

    it "leaves an accepted steer alone: no retry and no undelivered state" $
      withRecordingReviewClient $ \client wire events -> do
        handleWireMessage client (turnStarted targetTurn)
        sendSteer client
        void (nextClientRequest wire)
        handleWireMessage client steerAccepted
        expectNoFurtherClientRequests wire
        recorded <- readIORef events
        undeliveredSteers recorded `shouldBe` []
        protocolWarnings recorded `shouldBe` []

  -- The session half of issue #17. 'applyReviewEvent' runs in brick's
  -- 'EventM', which no unit test here can drive, so the transition a
  -- 'ReviewSteerUndelivered' causes lives in 'applyUndeliveredSteer' and is
  -- covered directly.
  describe "undelivered review message recovery" $ do
    let steerMessage = "actually, check the drainer path too" :: Text
        laterMessage = "and the label cleanup" :: Text
        undeliveredSession input undelivered =
          ReviewSession
            { reviewSessionIssue = baseIssue 17 [],
              reviewSessionStage = InitialReview,
              reviewSessionThreadId = Just "thread-1",
              reviewSessionTurnId = Just "turn-2",
              reviewSessionPhase = ReviewRunning,
              reviewSessionActivity = "thinking",
              reviewSessionTranscript = plainChatTranscript ("\nYou: " <> steerMessage <> "\n"),
              reviewSessionPending = Nothing,
              reviewSessionInput = input,
              reviewSessionUndelivered = undelivered,
              reviewSessionSpinnerFrame = 0,
              reviewSessionTickGeneration = 1,
              reviewSessionTickArmed = False,
              reviewSessionFollowing = True
            }

    it "restores the rejected message to an input line the user left alone" $ do
      let recovered = applyUndeliveredSteer steerMessage (undeliveredSession "" [])
      recovered.reviewSessionInput `shouldBe` steerMessage
      recovered.reviewSessionUndelivered `shouldBe` []

    it "qualifies the optimistic transcript entry rather than leaving it claiming delivery" $ do
      let recovered = applyUndeliveredSteer steerMessage (undeliveredSession "" [])
      recovered.reviewSessionTranscript.standardTranscript `shouldMention` ("[not delivered] " <> steerMessage)

    it "keeps a draft typed after the send, queueing the rejected message behind it" $ do
      let draft = "wait, ignore that"
          recovered = applyUndeliveredSteer steerMessage (undeliveredSession draft [])
      recovered.reviewSessionInput `shouldBe` draft
      recovered.reviewSessionUndelivered `shouldBe` [steerMessage]

    it "preserves every independently rejected steer instead of overwriting the first" $ do
      let draft = "wait, ignore that"
          recovered =
            applyUndeliveredSteer laterMessage (applyUndeliveredSteer steerMessage (undeliveredSession draft []))
      recovered.reviewSessionInput `shouldBe` draft
      recovered.reviewSessionUndelivered `shouldBe` [steerMessage, laterMessage]

    it "returns queued messages oldest first once the input line is free again" $ do
      let recovered = applyUndeliveredSteer laterMessage (undeliveredSession "" [steerMessage])
      recovered.reviewSessionInput `shouldBe` steerMessage
      recovered.reviewSessionUndelivered `shouldBe` [laterMessage]

    it "shows what is still waiting inside the session overlay, not only in a transient notice" $ do
      let rendered =
            renderWidgetLines
              (themeFor testOptions)
              60
              (drawUndeliveredSteers (undeliveredSession "wait, ignore that" [steerMessage]))
      Data.Text.unlines rendered `shouldMention` "NOT DELIVERED"
      Data.Text.unlines rendered `shouldMention` steerMessage

    it "renders nothing at all when no message is waiting" $
      renderWidgetLines (themeFor testOptions) 60 (drawUndeliveredSteers (undeliveredSession "" []))
        `shouldBe` []

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
      seenLines `shouldBe` [ByteString.pack ("line-" <> show n) | n <- [1 .. rounds]]
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
    it "launches each solver with its pinned model and effort, including the separately constructed Codex resume branch" $ do
      let codexArguments = solveArguments 844 SolveOnly CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer ""
          claudeArguments = solveArguments 844 SolveOnly ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer ""
          codexResumeArguments = solveArguments 844 SolveOnly CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig (Just "session-1") ResumeAnswer "pick option B"
      codexArguments `shouldContain` ["--model", "gpt-5.4"]
      codexArguments `shouldContain` ["model_reasoning_effort=\"high\""]
      codexArguments `shouldContain` ["model_reasoning_summary=\"detailed\""]
      claudeArguments `shouldContain` ["--model", "claude-sonnet-5"]
      claudeArguments `shouldContain` ["--effort", "high"]
      codexResumeArguments `shouldContain` ["--model", "gpt-5.4"]
      codexResumeArguments `shouldContain` ["model_reasoning_effort=\"high\""]
      codexResumeArguments `shouldContain` ["model_reasoning_summary=\"detailed\""]
      codexResumeArguments `shouldContain` ["approval_policy=\"never\""]

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
      -- Short distinguishing substrings rather than whole sentences, so this
      -- fails when the underlying instruction is lost or reversed but not on
      -- an unrelated copy edit to the surrounding prose.
      let solvePrompt = last (solveArguments 782 SolveOnly CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
      solvePrompt `shouldContain` "issue #782"
      solvePrompt `shouldContain` "not a collision"
      solvePrompt `shouldContain` "inspect `git status`"
      solvePrompt `shouldContain` "Do not discard, reset, or overwrite"
      solvePrompt `shouldContain` "when no same-issue worktree exists"

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
        `shouldBe` Right (Nothing, [StreamEvent Nothing (AgentEvent "message" "Created PR #42" "" (Just "Created PR #42"))])

    it "extracts Claude session ids and assistant text" $ do
      parseSolveOutputLine "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"claude-session\"}"
        `shouldBe` Right (Just "claude-session", [])
      parseSolveOutputLine "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Working in issue-42\"}]}}"
        `shouldBe` Right (Nothing, [StreamEvent Nothing (AgentEvent "message" "Working in issue-42" "" (Just "Working in issue-42"))])

    it "promotes Claude Bash tools to visible running commands while retaining full input" $ do
      let toolLine = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"git status --short\"}}]}}"
      case parseSolveOutputLine toolLine of
        Right (_, [streamEvent]) -> do
          let agentEvent = streamEvent.streamEventAgent
          agentEvent.agentEventKind `shouldBe` "command"
          renderAgentEvent CompactChat agentEvent `shouldBe` Just "[command] git status --short"
          renderAgentEvent StandardChat agentEvent `shouldSatisfy` maybe False (Data.Text.isInfixOf "git status --short")
          renderAgentEvent FullChat agentEvent `shouldSatisfy` maybe False (Data.Text.isInfixOf "command")
        result -> expectationFailure ("unexpected parsed tool event: " <> show result)

    it "bounds every unrecognized payload to a single-line notice instead of embedding its whole JSON" $ do
      -- One chatty unrecognized type per parser fallback, each carrying a
      -- payload far larger than the notice budget.
      let blob = Data.Text.replicate 400 "0123456789"
          topLevel = "{\"type\":\"telemetry\",\"blob\":\"" <> Data.Text.unpack blob <> "\"}"
          item = "{\"type\":\"item.completed\",\"item\":{\"type\":\"heartbeat\",\"blob\":\"" <> Data.Text.unpack blob <> "\"}}"
          content = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"telemetry_delta\",\"blob\":\"" <> Data.Text.unpack blob <> "\"}]}}"
      notices <- traverse (\(line, tag) -> (,) tag <$> singleNotice (ByteString.pack line)) [(topLevel, "[event] telemetry"), (item, "[item] heartbeat"), (content, "[content] telemetry_delta")]
      mapM_
        ( \(tag, agentEvent) -> do
            let summary = agentEvent.agentEventSummary
            summary `shouldSatisfy` Data.Text.isPrefixOf tag
            Data.Text.length summary `shouldSatisfy` (<= maxUnknownNoticeLength)
            Data.Text.lines summary `shouldSatisfy` ((== 1) . length)
            -- A prefix of the payload is kept for diagnosis; the payload
            -- itself never is.
            summary `shouldSatisfy` Data.Text.isInfixOf "0123456789"
            summary `shouldNotSatisfy` Data.Text.isInfixOf blob
            -- The detail lives inside the one-line summary, so even the Full
            -- rendering (which would otherwise indent a detail onto its own
            -- lines) stays one bounded line.
            agentEvent.agentEventDetail `shouldBe` ""
            case renderAgentEvent FullChat agentEvent of
              Nothing -> expectationFailure "expected the Full rendering to keep the unknown notice"
              Just rendered -> do
                rendered `shouldBe` summary
                Data.Text.length rendered `shouldSatisfy` (<= maxUnknownNoticeLength)
        )
        notices

    it "gives a missing, non-string, blank, multi-line, or overlong type a bounded one-line label" $ do
      -- Every shape of unusable or hostile 'type' across all three
      -- fallbacks. None may escape the whole-notice bound or the one-line
      -- rule, and none may be dropped.
      let payloads =
            [ "{\"detail\":\"no type at all\"}",
              "{\"type\":42,\"detail\":\"numeric type\"}",
              "{\"type\":{\"nested\":\"object\"},\"detail\":\"object type\"}",
              "{\"type\":[\"array\"],\"detail\":\"array type\"}",
              "{\"type\":\"   \",\"detail\":\"blank type\"}",
              "{\"type\":\"first\\nsecond\\rthird\\ttab\",\"detail\":\"multi-line type\"}",
              "{\"type\":\"bell\\u0007bidi\\u202e\",\"detail\":\"control type\"}",
              "{\"type\":\"" <> replicate 500 'z' <> "\",\"detail\":\"overlong type\"}"
            ]
          wrapped payload =
            [ ByteString.pack payload,
              ByteString.pack ("{\"type\":\"item.completed\",\"item\":" <> payload <> "}"),
              ByteString.pack ("{\"type\":\"assistant\",\"message\":{\"content\":[" <> payload <> "]}}")
            ]
      mapM_
        ( \line -> do
            agentEvent <- singleNotice line
            let summary = agentEvent.agentEventSummary
            summary `shouldSatisfy` (not . Data.Text.null)
            Data.Text.length summary `shouldSatisfy` (<= maxUnknownNoticeLength)
            Data.Text.lines summary `shouldSatisfy` ((== 1) . length)
            summary `shouldSatisfy` Data.Text.all (not . isControl)
        )
        (concatMap wrapped payloads)

    it "treats a non-string type naming a recognized type as unrecognized rather than letting it reach an unbounded branch" $ do
      -- A permissive type discriminator would coerce these into recognized
      -- branches and hand back exactly what the bound exists to prevent: an
      -- unbounded 'error' message, and 'tool_result' 's whole-payload
      -- fallback. Only a literal JSON string names a recognized type.
      let blob = Data.Text.replicate 400 "0123456789"
          coerced = ["[\"error\"]", "{\"text\":\"error\"}", "[\"tool_result\"]", "{\"text\":\"agent_message\"}", "[\"assistant\"]"]
          payload typeValue = "{\"type\":" <> typeValue <> ",\"message\":\"" <> Data.Text.unpack blob <> "\",\"text\":\"" <> Data.Text.unpack blob <> "\",\"content\":\"" <> Data.Text.unpack blob <> "\"}"
          wrapped typeValue =
            [ ByteString.pack (payload typeValue),
              ByteString.pack ("{\"type\":\"item.completed\",\"item\":" <> payload typeValue <> "}"),
              ByteString.pack ("{\"type\":\"assistant\",\"message\":{\"content\":[" <> payload typeValue <> "]}}")
            ]
      mapM_
        ( \line -> do
            agentEvent <- singleNotice line
            agentEvent.agentEventKind `shouldBe` "event"
            agentEvent.agentEventSummary `shouldSatisfy` Data.Text.isInfixOf "unknown"
            Data.Text.length agentEvent.agentEventSummary `shouldSatisfy` (<= maxUnknownNoticeLength)
            agentEvent.agentEventSummary `shouldNotSatisfy` Data.Text.isInfixOf blob
            agentEvent.agentEventDetail `shouldBe` ""
        )
        (concatMap wrapped coerced)

    it "reports the first three occurrences of an unknown key and collapses the rest into one counted summary" $ do
      -- The exact boundary: three occurrences are all reported and leave no
      -- summary behind; a fourth suppresses itself and redeems the key as a
      -- single total-count summary.
      let telemetry = "{\"type\":\"telemetry\",\"n\":1}"
      atBoundary <- aggregatedNotices (replicate unknownNoticeSamples telemetry)
      length atBoundary `shouldBe` unknownNoticeSamples
      atBoundary `shouldSatisfy` all (Data.Text.isPrefixOf "[event] telemetry ")
      atBoundary `shouldSatisfy` all (not . Data.Text.isInfixOf "×")

      pastBoundary <- aggregatedNotices (replicate (unknownNoticeSamples + 1) telemetry)
      length pastBoundary `shouldBe` unknownNoticeSamples + 1
      last pastBoundary `shouldBe` "[event] telemetry ×4"

      -- A chatty type stays O(1) per invocation however long it runs.
      chatty <- aggregatedNotices (replicate 418 telemetry)
      length chatty `shouldBe` unknownNoticeSamples + 1
      last chatty `shouldBe` "[event] telemetry ×418"

    it "counts each category, type, and prefix-sharing type apart, and lets recognized events pass between repeats" $ do
      -- 'foo' arriving as a top-level event, a Codex item, and a Claude
      -- content block is three independent keys, not one; two distinct long
      -- types that share a bounded display prefix are two keys, not one; and
      -- recognized output interleaved with the repeats neither resets a
      -- count nor is itself suppressed.
      let longPrefix = replicate 60 'p'
          typeA = longPrefix <> "-alpha"
          typeB = longPrefix <> "-beta"
          eventFoo = "{\"type\":\"foo\"}"
          itemFoo = "{\"type\":\"item.completed\",\"item\":{\"type\":\"foo\"}}"
          contentFoo = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"foo\"}]}}"
          recognizedLine = "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"still working\"}}"
          longA = "{\"type\":\"" <> typeA <> "\"}"
          longB = "{\"type\":\"" <> typeB <> "\"}"
      notices <-
        aggregatedNotices
          ( concat (replicate 5 [eventFoo, itemFoo, contentFoo])
              <> [recognizedLine]
              <> concat (replicate 5 [eventFoo, itemFoo, contentFoo])
              <> replicate 5 longA
              <> replicate 7 longB
          )
      let summaries = filter (Data.Text.isInfixOf "×") notices
      -- Each of the five keys is counted on its own; the interleaved
      -- recognized event did not restart 'foo' at one.
      sort summaries
        `shouldBe` sort
          [ "[content] foo ×10",
            "[event] " <> Data.Text.pack (take 47 typeA) <> "… ×5",
            "[event] " <> Data.Text.pack (take 47 typeB) <> "… ×7",
            "[event] foo ×10",
            "[item] foo ×10"
          ]
      notices `shouldSatisfy` elem "still working"

    it "keeps a textual error message in full while bounding an error payload that has no usable message" $ do
      -- The one exemption stays: a literal string 'message' is never
      -- truncated. Anything else about an 'error' payload — missing,
      -- non-string, or blank message — is bounded like any other
      -- unrecognized payload rather than embedding the raw JSON.
      let longMessage = Data.Text.replicate 120 "failure detail "
          textualError = ByteString.pack ("{\"type\":\"error\",\"message\":\"" <> Data.Text.unpack longMessage <> "\"}")
          textualItemError = ByteString.pack ("{\"type\":\"item.completed\",\"item\":{\"type\":\"error\",\"message\":\"" <> Data.Text.unpack longMessage <> "\"}}")
      mapM_
        ( \line -> do
            agentEvent <- singleNotice line
            agentEvent.agentEventKind `shouldBe` "error"
            agentEvent.agentEventSummary `shouldBe` "[error] " <> longMessage
            agentEvent.agentEventOutcomeText `shouldBe` Just longMessage
        )
        [textualError, textualItemError]

      let blob = Data.Text.replicate 400 "0123456789"
          unusable suffix = "{\"type\":\"error\"," <> suffix <> ",\"blob\":\"" <> Data.Text.unpack blob <> "\"}"
          messageShapes = map unusable ["\"detail\":\"no message\"", "\"message\":123", "\"message\":{\"text\":\"coerced\"}", "\"message\":\"  \""]
      mapM_
        ( \payload ->
            mapM_
              ( \line -> do
                  agentEvent <- singleNotice line
                  agentEvent.agentEventKind `shouldBe` "event"
                  Data.Text.length agentEvent.agentEventSummary `shouldSatisfy` (<= maxUnknownNoticeLength)
                  agentEvent.agentEventSummary `shouldNotSatisfy` Data.Text.isInfixOf blob
              )
              [ByteString.pack payload, ByteString.pack ("{\"type\":\"item.completed\",\"item\":" <> payload <> "}")]
        )
        messageShapes

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
            aggregator <- newUnknownAggregator
            runSolve repository 900 SolveOnly CodexSolver Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator (\event -> modifyIORef events (event :))
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
            aggregator <- newUnknownAggregator
            runSolve repository 901 SolveOnly CodexSolver Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator (\event -> modifyIORef events (event :))
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
            aggregator <- newUnknownAggregator
            timeout 10000000 (runSolve repository 902 SolveOnly CodexSolver Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator poisonedSink) `shouldReturn` Just ()

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
            aggregator <- newUnknownAggregator
            timeout 20000000 (runSolveWith stdoutOnlyFails repository 906 SolveOnly CodexSolver Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator sink) `shouldReturn` Just ()
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

    it "records every raw line of a chatty unknown event type while forwarding only bounded, collapsed notices" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        ByteString.writeFile fakeCodex (chattyProvider "unknown-stream-session" "Created PR #999" [])
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            events <- newIORef []
            aggregator <- newUnknownAggregator
            runSolve repository 907 SolveOnly CodexSolver Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator (\event -> modifyIORef events (event :))
            collected <- reverse <$> readIORef events
            -- Only a constant number of records reach the sink the worker
            -- journals: the samples plus one counted summary, however many
            -- occurrences the provider streamed.
            let notices = [agentEvent | SolveOutput _ agentEvent <- collected, Data.Text.isPrefixOf "[event] telemetry" agentEvent.agentEventSummary]
            length notices `shouldBe` unknownNoticeSamples + 1
            notices `shouldSatisfy` all ((<= maxUnknownNoticeLength) . Data.Text.length . (.agentEventSummary))
            -- The summary lands before the terminal event, which is where
            -- replay stops reading the journal.
            case reverse collected of
              (SolveProcessFinished _ SolveCompleted : SolveOutput _ summary : _) ->
                summary.agentEventSummary `shouldBe` "[event] telemetry ×" <> Data.Text.pack (show chattyProviderLines)
              _ -> expectationFailure "expected the aggregate summary immediately before the terminal event"
            -- Full fidelity still lives in the session log, untouched.
            rawTelemetryLines [path | SolveLogOpened _ path <- collected] `shouldReturn` chattyProviderLines

    it "still emits exactly one aggregate summary when the provider is interrupted mid-stream" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        -- The provider stays alive after its chatty burst, so the kill below
        -- lands as a real interruption rather than racing a normal exit. The
        -- sentinel is only reached once every telemetry line before it has
        -- already been read and aggregated, which is what makes the expected
        -- count deterministic.
        ByteString.writeFile fakeCodex (chattyProvider "interrupted-stream-session" "READY" ["sleep 30"])
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            events <- newIORef []
            managedRef <- newIORef Nothing
            let sink event = do
                  modifyIORef events (event :)
                  case event of
                    SolveProcessStarted _ _ managed -> writeIORef managedRef (Just managed)
                    SolveOutput _ agentEvent
                      | agentEvent.agentEventSummary == "READY" -> readIORef managedRef >>= mapM_ killManagedProcess
                    _ -> pure ()
            aggregator <- newUnknownAggregator
            timeout 20000000 (runSolve repository 908 SolveOnly CodexSolver Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator sink) `shouldReturn` Just ()
            collected <- reverse <$> readIORef events
            [agentEvent.agentEventSummary | SolveOutput _ agentEvent <- collected, Data.Text.isInfixOf "×" agentEvent.agentEventSummary]
              `shouldBe` ["[event] telemetry ×" <> Data.Text.pack (show chattyProviderLines)]
            case reverse collected of
              (SolveProcessFinished _ (SolveFailed _) : SolveOutput _ summary : _) ->
                summary.agentEventSummary `shouldBe` "[event] telemetry ×" <> Data.Text.pack (show chattyProviderLines)
              _ -> expectationFailure "expected the aggregate summary immediately before the interrupted terminal event"
            rawTelemetryLines [path | SolveLogOpened _ path <- collected] `shouldReturn` chattyProviderLines

  describe "settings" $ do
    it "defaults chat output to standard and persists a selected verbosity" $
      withTemporaryCacheRoot $ \configRoot ->
        withEnvironmentValue "XDG_CONFIG_HOME" configRoot $ do
          loadSettings `shouldReturn` (defaultSettings, Nothing)
          saveSettings (Settings FullChat) `shouldReturn` Right ()
          loadSettings `shouldReturn` (Settings FullChat, Nothing)

    -- The version the writer has always stamped is now read, and it follows
    -- the cache's rule: a file from another version of the format is silently
    -- the defaults, however little of its payload this build understands.
    it "falls back to the defaults silently for a settings file from another schema version" $
      withTemporaryCacheRoot $ \configRoot ->
        withEnvironmentValue "XDG_CONFIG_HOME" configRoot $ do
          saveSettings (Settings FullChat) `shouldReturn` Right ()
          path <- settingsPath
          ByteString.writeFile path "{\"schemaVersion\":999,\"chatVerbosity\":{\"mode\":\"full\",\"density\":3}}"
          loadSettings `shouldReturn` (defaultSettings, Nothing)

    it "still warns for settings it cannot decode under a version it does recognise" $
      withTemporaryCacheRoot $ \configRoot ->
        withEnvironmentValue "XDG_CONFIG_HOME" configRoot $ do
          saveSettings (Settings FullChat) `shouldReturn` Right ()
          path <- settingsPath
          let expectWarnedDefaults = do
                (settings, warning) <- loadSettings
                settings `shouldBe` defaultSettings
                warning `shouldSatisfy` isJust
          ByteString.writeFile path "{\"schemaVersion\":1,\"chatVerbosity\":\"deafening\"}"
          expectWarnedDefaults
          ByteString.writeFile path "not JSON"
          expectWarnedDefaults
          ByteString.writeFile path "{\"chatVerbosity\":\"full\"}"
          expectWarnedDefaults

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
            aggregator <- newUnknownAggregator
            runPullRequestFlow repository 904 PullRequestClaude PullRequestReview Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator (\event -> modifyIORef events (event :))
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
            aggregator <- newUnknownAggregator
            runPullRequestFlow repository 905 PullRequestClaude PullRequestReview Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator (\event -> modifyIORef events (event :))
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
            aggregator <- newUnknownAggregator
            timeout 10000000 (runPullRequestFlow repository 903 PullRequestClaude PullRequestReview Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator poisonedSink) `shouldReturn` Just ()

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
            aggregator <- newUnknownAggregator
            timeout 20000000 (runPullRequestFlowWith stdoutOnlyFails repository 907 PullRequestClaude PullRequestReview Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator sink) `shouldReturn` Just ()
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

    it "records every raw line of a chatty unknown event type while forwarding only bounded, collapsed notices" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- The PR flow owns its own stdout loop, so it needs its own proof
        -- that the shared parser's bounding and this flow's own aggregation
        -- are wired together the same way the solve flow's are.
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        ByteString.writeFile fakeCodex (chattyProvider "pr-unknown-stream-session" "Reviewed" [])
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            events <- newIORef []
            aggregator <- newUnknownAggregator
            runPullRequestFlow repository 908 PullRequestClaude PullRequestReview Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator (\event -> modifyIORef events (event :))
            collected <- reverse <$> readIORef events
            let notices = [agentEvent | PullRequestFlowOutput _ agentEvent <- collected, Data.Text.isPrefixOf "[event] telemetry" agentEvent.agentEventSummary]
            length notices `shouldBe` unknownNoticeSamples + 1
            notices `shouldSatisfy` all ((<= maxUnknownNoticeLength) . Data.Text.length . (.agentEventSummary))
            case reverse collected of
              (PullRequestProcessFinished _ SolveCompleted : PullRequestFlowOutput _ summary : _) ->
                summary.agentEventSummary `shouldBe` "[event] telemetry ×" <> Data.Text.pack (show chattyProviderLines)
              _ -> expectationFailure "expected the aggregate summary immediately before the terminal event"
            rawTelemetryLines [path | PullRequestLogOpened _ path <- collected] `shouldReturn` chattyProviderLines

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

  describe "review session liveness, quit protection, and the x gate" $ do
    -- issue #151: the processes overlay, the `x` gate that dispatches on
    -- its rows, and the dashboard quit guard each re-implemented "live"
    -- differently, so a revision waiting on a question or approval blocked
    -- `q` while the overlay called the same session dead and refused `x`.
    -- 'reviewSessionLive' is now the one decision all three consume, and it
    -- means *currently killable*: the session has a target 'killReviewAgent'
    -- can act on. These are the pure decisions behind those call sites, so
    -- the whole input matrix is covered without an 'EventM' harness.
    let reviewedIssue = 151
        sessionFor (_, _, stage, phase, threadId, turnId) =
          ReviewSession
            { reviewSessionIssue = baseIssue reviewedIssue [],
              reviewSessionStage = stage,
              reviewSessionThreadId = threadId,
              reviewSessionTurnId = turnId,
              reviewSessionPhase = phase,
              reviewSessionActivity = "",
              reviewSessionTranscript = ChatTranscript "" "" "",
              reviewSessionPending = Nothing,
              reviewSessionInput = "",
              reviewSessionUndelivered = [],
              reviewSessionSpinnerFrame = 0,
              reviewSessionTickGeneration = 1,
              reviewSessionTickArmed = False,
              reviewSessionFollowing = True
            }
        canonicalProcesses hasProcess = if hasProcess then Set.singleton reviewedIssue else Set.empty
        allPhases =
          [ ReviewStarting,
            ReviewRunning,
            ReviewWaiting,
            ReviewFinished,
            ReviewNeedsChanges,
            ReviewFailed,
            ReviewRevised,
            ReviewInterrupted
          ]
        allStages = [InitialReview, IssueRevision, IssueRereview]
        -- Every input the kill target depends on: phase, stage,
        -- canonical-process presence, backend readiness, and both IDs.
        killTargetInputs =
          [ (backendReady, hasProcess, stage, phase, threadId, turnId)
            | backendReady <- [False, True],
              hasProcess <- [False, True],
              stage <- allStages,
              phase <- allPhases,
              threadId <- [Nothing, Just "thread-1"],
              turnId <- [Nothing, Just "turn-1"]
          ]
        -- The issue's rule restated independently of the code under test.
        expectedLive (backendReady, hasProcess, stage, phase, threadId, turnId) =
          hasProcess
            || ( stage == IssueRevision
                   && phase `elem` [ReviewStarting, ReviewRunning, ReviewWaiting]
                   && backendReady
                   && isJust threadId
                   && isJust turnId
               )
        sharedLive inputs@(backendReady, hasProcess, _, _, _, _) =
          reviewSessionLive backendReady hasProcess (sessionFor inputs)
        overlayLive inputs@(backendReady, hasProcess, _, _, _, _) =
          (reviewAgentSessionEntry backendReady hasProcess reviewedIssue (sessionFor inputs)).agentSessionLive
        quitBlocked inputs@(backendReady, hasProcess, _, _, _, _) =
          liveReviewSessions backendReady (canonicalProcesses hasProcess) (Map.singleton reviewedIssue (sessionFor inputs))
            == [reviewedIssue]
        -- Every combination whose answer disagrees with the rule above,
        -- tagged with its inputs, so a failure names the exact
        -- combinations rather than reporting "True /= False" or dumping
        -- the whole matrix.
        wrongAnswers decide = [(inputs, decide inputs) | inputs <- killTargetInputs, decide inputs /= expectedLive inputs]

    it "covers every combination of phase, stage, canonical process, backend readiness, and both IDs" $ do
      length killTargetInputs `shouldBe` 384
      (any expectedLive killTargetInputs, all expectedLive killTargetInputs) `shouldBe` (True, False)

    it "reports a review session live exactly when it currently has a kill target" $
      wrongAnswers sharedLive `shouldBe` []

    it "keeps the processes overlay and the quit guard agreeing over the whole matrix" $ do
      wrongAnswers overlayLive `shouldBe` []
      wrongAnswers quitBlocked `shouldBe` []

    it "keeps a waiting revision live and routes x to its interruptible turn" $ do
      let waiting = (True, False, IssueRevision, ReviewWaiting, Just "thread-1", Just "turn-1")
          session = sessionFor waiting
      sharedLive waiting `shouldBe` True
      overlayLive waiting `shouldBe` True
      liveReviewSessions True Set.empty (Map.singleton reviewedIssue session) `shouldBe` [reviewedIssue]
      -- The gate hands a live review row to 'killReviewAgent', whose turn
      -- branch takes the recorded thread and turn under exactly this
      -- condition, so `x` interrupts the turn instead of reporting no live
      -- process to kill.
      reviewTurnInterruptible IssueRevision ReviewWaiting `shouldBe` True

    it "leaves a canonical stage quittable until its process is registered" $ do
      let starting = (True, False, InitialReview, ReviewStarting, Nothing, Nothing)
      sharedLive starting `shouldBe` False
      overlayLive starting `shouldBe` False
      liveReviewSessions True Set.empty (Map.singleton reviewedIssue (sessionFor starting)) `shouldBe` []

    it "leaves a starting revision quittable until its backend is ready and it has both IDs" $
      mapM_
        (\inputs -> (inputs, sharedLive inputs, overlayLive inputs, quitBlocked inputs) `shouldBe` (inputs, False, False, False))
        [ (False, False, IssueRevision, ReviewStarting, Nothing, Nothing),
          (False, False, IssueRevision, ReviewStarting, Just "thread-1", Just "turn-1"),
          (True, False, IssueRevision, ReviewStarting, Nothing, Nothing),
          (True, False, IssueRevision, ReviewStarting, Just "thread-1", Nothing),
          (True, False, IssueRevision, ReviewStarting, Nothing, Just "turn-1")
        ]

    it "keeps a registered canonical process live and killable whatever the session phase" $
      mapM_
        ( \phase -> do
            let withProcess = (False, True, InitialReview, phase, Nothing, Nothing)
            sharedLive withProcess `shouldBe` True
            overlayLive withProcess `shouldBe` True
            quitBlocked withProcess `shouldBe` True
            -- No interruptible turn, so 'killReviewAgent' reaches the
            -- unchanged canonical process-kill branch for this row.
            reviewTurnInterruptible InitialReview phase `shouldBe` False
            (reviewAgentSessionEntry False True reviewedIssue (sessionFor withProcess)).agentSessionRef
              `shouldBe` ReviewAgent reviewedIssue
        )
        allPhases

    it "stops counting a just-killed revision as live while it still carries its turn ID" $ do
      -- 'killReviewAgent' leaves the session ReviewFailed without clearing
      -- the thread and turn IDs, so without the phase condition `q` would
      -- stay refused after the kill and a second `x` would pass the gate
      -- only to hit the no-live-process notice.
      let killed = (True, False, IssueRevision, ReviewFailed, Just "thread-1", Just "turn-1")
      sharedLive killed `shouldBe` False
      overlayLive killed `shouldBe` False
      quitBlocked killed `shouldBe` False
      reviewTurnInterruptible IssueRevision ReviewFailed `shouldBe` False

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
              reviewSessionUndelivered = [],
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
              reviewSessionUndelivered = [],
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
    -- NFC is the final step, so a decomposed base-plus-accent input and its
    -- precomposed twin converge on the identical result.
    it "sanitizes NFC-equivalent composed and decomposed input identically" $ do
      sanitizeText "Caf\233" `shouldBe` sanitizeText "Cafe\769"
      sanitizeText "Cafe\769" `shouldBe` "Caf\233"
    -- A combining mark over a digit has no precomposed form -- Unicode never
    -- defines one -- so it survives both the safe-character filter (general
    -- category Mn, not Format or a bidi control) and NFC, which has nothing
    -- to fold it into.
    it "preserves an ordinary combining mark that has no precomposed form" $
      sanitizeText "5\817" `shouldBe` "5\817"

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

    -- An assignee connection that never arrived is not evidence of nobody
    -- working on the issue, so it must not land in the column that presents
    -- it as unclaimed work waiting to be picked up.
    it "keeps an issue whose assignees GitHub never delivered out of the backlog column" $ do
      let issue = (baseIssue 1 []) {issueDataGaps = [AssigneesUnavailable]}
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [issue] [] epoch False False)
      map (itemNumber . entryItem) (Map.findWithDefault [] Active columns) `shouldBe` [1]
      Map.findWithDefault [] Issues columns `shouldBe` []

    it "keeps draft approved pull requests in Reviewing" $ do
      let pullRequest = basePullRequest 10 [] True [Label "reviewed:approve" "00ff00"]
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [] [pullRequest] epoch False False)
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing columns) `shouldBe` [10]
      Map.findWithDefault [] Done columns `shouldBe` []

    it "classifies non-draft approved pull requests as Done" $ do
      let pullRequest = basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [] [pullRequest] epoch False False)
      map (itemNumber . entryItem) (Map.findWithDefault [] Done columns) `shouldBe` [10]

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

    -- attentionKey orders on two independent booleans (problem, approved)
    -- before age, so an item carrying both a changes-requested and an
    -- approval label sits in its own tier rather than collapsing into either
    -- one alone.
    it "orders standalone issues by all four problem/approved tiers, then by age within each tier" $ do
      let older = epoch
          newer = addUTCTime 3600 epoch
          problemLabel = Label "reviewed:changes" "d73a4a"
          approvedLabel = Label "reviewed:approve" "0e8a16"
          tiered number labels createdAt = (baseIssue number []) {issueLabels = labels, issueCreatedAt = createdAt}
          bothOld = tiered 1 [problemLabel, approvedLabel] older
          bothNew = tiered 2 [problemLabel, approvedLabel] newer
          problemOld = tiered 3 [problemLabel] older
          problemNew = tiered 4 [problemLabel] newer
          approvedOld = tiered 5 [approvedLabel] older
          approvedNew = tiered 6 [approvedLabel] newer
          neitherOld = tiered 7 [] older
          neitherNew = tiered 8 [] newer
          snapshot =
            RepoSnapshot
              [neitherNew, bothOld, approvedOld, problemNew, bothNew, neitherOld, approvedNew, problemOld]
              []
              epoch
              False
              False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [1, 2, 3, 4, 5, 6, 7, 8]

    -- classifyPullRequest routes a non-draft approved PR to Done regardless
    -- of its tier, which would split the four tiers across two columns.
    -- Keeping every fixture a draft holds them all in Reviewing (drafts stay
    -- there no matter their approval label), so the same four-tier,
    -- age-ordered assertion applies to pull requests too.
    it "orders standalone pull requests by all four problem/approved tiers, then by age within each tier" $ do
      let older = epoch
          newer = addUTCTime 3600 epoch
          approvedLabel = Label "reviewed:approve" "0e8a16"
          tiered number labels mergeState createdAt =
            (basePullRequest number [] True labels) {pullRequestMergeState = mergeState, pullRequestCreatedAt = createdAt}
          bothOld = tiered 1 [approvedLabel] MergeConflicting older
          bothNew = tiered 2 [approvedLabel] MergeConflicting newer
          problemOld = tiered 3 [] MergeConflicting older
          problemNew = tiered 4 [] MergeConflicting newer
          approvedOld = tiered 5 [approvedLabel] MergeClean older
          approvedNew = tiered 6 [approvedLabel] MergeClean newer
          neitherOld = tiered 7 [] MergeClean older
          neitherNew = tiered 8 [] MergeClean newer
          snapshot =
            RepoSnapshot
              []
              [neitherNew, bothOld, approvedOld, problemNew, bothNew, neitherOld, approvedNew, problemOld]
              epoch
              False
              False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing columns) `shouldBe` [1, 2, 3, 4, 5, 6, 7, 8]

    -- trackerGroupKey reads the same two booleans off a group's tracked
    -- children rather than the tracker issue itself, so the "both" tier here
    -- comes from two different children each contributing one flag.
    it "orders tracker groups by the four problem/approved tiers, then by the tracker's own age within a tier" $ do
      let older = epoch
          newer = addUTCTime 3600 epoch
          problemLabel = Label "reviewed:changes" "d73a4a"
          approvedLabel = Label "reviewed:approve" "0e8a16"
          tracker number createdAt childrenBody =
            (baseIssue number [])
              { issueLabels = [Label "epic" "5319e7"],
                issueCreatedAt = createdAt,
                issueBody = "## Children\n" <> childrenBody
              }
          bothTracker = tracker 100 older "- [ ] #10 — A1: Problem child\n- [ ] #11 — A2: Approved child"
          problemTracker = tracker 200 older "- [ ] #12 — A1: Problem child"
          approvedTracker = tracker 300 older "- [ ] #13 — A1: Approved child"
          neitherOldTracker = tracker 400 older "- [ ] #14 — A1: Ordinary child"
          neitherNewTracker = tracker 500 newer "- [ ] #15 — A1: Ordinary child"
          children =
            [ (baseIssue 10 []) {issueLabels = [problemLabel]},
              (baseIssue 11 []) {issueLabels = [approvedLabel]},
              (baseIssue 12 []) {issueLabels = [problemLabel]},
              (baseIssue 13 []) {issueLabels = [approvedLabel]},
              baseIssue 14 [],
              baseIssue 15 []
            ]
          snapshot =
            RepoSnapshot
              ([neitherNewTracker, approvedTracker, bothTracker, neitherOldTracker, problemTracker] <> children)
              []
              epoch
              False
              False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [10, 11, 12, 13, 14, 15]

    -- trackedChildKey ranks only rereview status ahead of checklist order;
    -- isProblem never enters it, so a later child carrying a blocked label
    -- must not jump ahead of an earlier, ordinary one.
    it "keeps a later problematic child in its natural implementation position rather than promoting it" $ do
      let tracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #1 — A1: Earlier\n- [ ] #2 — A2: Later problem"
              }
          problemChild = (baseIssue 2 []) {issueLabels = [Label "blocked" "d73a4a"]}
          snapshot = RepoSnapshot [tracker, baseIssue 1 [], problemChild] [] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [1, 2]

    -- sortOn is stable, so standalone issues sharing an identical attention
    -- key -- no labels, the same creation time -- keep the order the
    -- snapshot listed them in rather than picking up an incidental
    -- numeric or canonical-identity ordering.
    it "preserves snapshot input order for standalone issues with equal attention keys" $ do
      let snapshot = RepoSnapshot [baseIssue 7 [], baseIssue 3 [], baseIssue 9 []] [] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [7, 3, 9]

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
          warnings `shouldSatisfy` any (Data.Text.isInfixOf "open issues; board is truncated")
          warnings `shouldSatisfy` any (Data.Text.isInfixOf "open pull requests; board is truncated")
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

    -- A rerun GitHub has queued but not started reports no timestamps at all,
    -- so ranking it by an empty-string timestamp let the completed failure it
    -- supersedes stay current and the card stay red. It is the newest run of
    -- its key by definition.
    it "supersedes a completed failure with the queued rerun that has no timestamps yet" $ do
      let response =
            githubChecksResponse
              2
              [ checkRunJson "review-approved" "FAILURE" "2026-07-17T14:43:13Z",
                queuedCheckRunJson "review-approved"
              ]
      case decodeGitHubItems (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right ([], [pullRequest]) ->
          pullRequest.pullRequestChecks `shouldBe` ChecksPending 0 1 [CheckDetail "review-approved" CheckPending]
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- Only a run with neither timestamp is a fresh rerun: one reporting just
    -- @completedAt@ has run, and keeps that timestamp as its effective one.
    it "ranks a run reporting only completedAt by that timestamp rather than as unstarted" $ do
      let response =
            githubChecksResponse
              2
              [ completedOnlyCheckRunJson "review-approved" "FAILURE" "2026-07-17T14:50:00Z",
                checkRunJson "review-approved" "SUCCESS" "2026-07-17T14:55:00Z"
              ]
      case decodeGitHubItems (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right ([], [pullRequest]) -> pullRequest.pullRequestChecks `shouldBe` ChecksPassed 1
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- Two runs of one key that are equally untimestamped have no age to
    -- separate them, so the dedup keeps the one GitHub listed last. Reversing
    -- the payload reverses the winner, which is what makes the rule a rule and
    -- not an accident of which state happens to sort higher.
    it "resolves two untimestamped runs of one check by the order GitHub listed them" $ do
      let response nodes = githubChecksResponse 2 nodes
          queued = queuedCheckRunJson "review-approved"
          failed = undatedCheckRunJson "review-approved" "FAILURE"
          checksOf payload = case decodeGitHubItems (LazyByteString.pack (response payload)) of
            Left message -> Left message
            Right ([], [pullRequest]) -> Right pullRequest.pullRequestChecks
            Right values -> Left ("unexpected decoded values: " <> show values)
      checksOf [queued, failed] `shouldBe` Right (ChecksFailed 0 1 [CheckDetail "review-approved" CheckFailed])
      checksOf [failed, queued] `shouldBe` Right (ChecksPending 0 1 [CheckDetail "review-approved" CheckPending])

    -- The other rollup kind reads its age from @createdAt@, and a status
    -- context that arrives without one says nothing about being newer. It has
    -- to rank oldest, or a later payload entry would displace a timestamped
    -- context of the same key purely by position.
    it "does not let a status context with no createdAt displace the timestamped one" $ do
      let response =
            githubChecksResponse
              2
              [ statusContextJson "ci/build" "SUCCESS" (Just "2026-07-17T14:43:00Z"),
                statusContextJson "ci/build" "FAILURE" Nothing
              ]
      case decodeGitHubItems (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right ([], [pullRequest]) -> pullRequest.pullRequestChecks `shouldBe` ChecksPassed 1
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    it "keeps a rollup past the context cap unknown rather than retaining the partial nodes it saw" $ do
      case decodeGitHubItems (LazyByteString.pack githubCappedChecksResponse) of
        Left message -> expectationFailure message
        Right ([], [pullRequest]) -> do
          pullRequest.pullRequestChecks `shouldBe` ChecksUnknown
          -- The cap is the documented §13 behavior, not an anomaly: it must
          -- not pick up the incomplete-data marker or warning that a context
          -- this build could not read would earn.
          pullRequest.pullRequestDataGaps `shouldBe` []
          snapshotWarnings defaultLimitsConfig defaultWorkflowConfig (RepoSnapshot [] [pullRequest] epoch False False)
            `shouldSatisfy` not . any (Data.Text.isInfixOf "incomplete data")
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- A rollup context type this build has never seen -- GitHub adding a
    -- kind, or an edge case returning a bare node -- used to fail the whole
    -- page, so every refresh of a repository containing one such PR broke
    -- permanently. It degrades that one pull request instead.
    it "keeps a rollup holding an unknown context type unknown instead of failing the page" $ do
      let response =
            githubPageWith
              []
              [ pullRequestNodeJson 9 [emptyLabelsJson, emptyClosingIssuesJson, rollupJson 2 [checkRunJson "build-test" "SUCCESS" "2026-01-03T00:00:00Z", futureCheckContextJson]],
                pullRequestNodeJson 10 [emptyLabelsJson, emptyClosingIssuesJson, rollupJson 1 [checkRunJson "build-test" "SUCCESS" "2026-01-03T00:00:00Z"]]
              ]
      case decodeGitHubItems (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right ([], [degraded, intact]) -> do
          degraded.pullRequestNumber `shouldBe` 9
          degraded.pullRequestChecks `shouldBe` ChecksUnknown
          degraded.pullRequestDataGaps `shouldBe` [ChecksUndecodable]
          intact.pullRequestNumber `shouldBe` 10
          intact.pullRequestChecks `shouldBe` ChecksPassed 1
          intact.pullRequestDataGaps `shouldBe` []
          snapshotWarnings defaultLimitsConfig defaultWorkflowConfig (RepoSnapshot [] [degraded, intact] epoch False False)
            `shouldSatisfy` any (Data.Text.isInfixOf "PR #9: incomplete data")
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- The same fail-closed treatment covers a type this build knows that
    -- arrives without a field its decode needs; "undecodable" is about the
    -- context node, not only about its typename.
    it "keeps a rollup holding a recognized context missing a required field unknown" $ do
      let response =
            githubPageWith
              []
              [pullRequestNodeJson 9 [emptyLabelsJson, emptyClosingIssuesJson, rollupJson 1 [namelessCheckRunJson]]]
      case decodeGitHubItems (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right ([], [pullRequest]) -> do
          pullRequest.pullRequestChecks `shouldBe` ChecksUnknown
          pullRequest.pullRequestDataGaps `shouldBe` [ChecksUndecodable]
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- GitHub's schema makes every nested connection nullable, and a
    -- partial-error response nulls out exactly the fields that errored. One
    -- "labels": null used to discard the entire refresh.
    it "decodes a null nested connection as no nodes and a gap on that item alone" $ do
      let response =
            githubPageWith
              []
              [ pullRequestNodeJson 9 ["\"labels\":null", emptyClosingIssuesJson],
                pullRequestNodeJson 10 ["\"labels\":{\"totalCount\":1,\"nodes\":[{\"name\":\"bug\",\"color\":\"d73a4a\"}]}", emptyClosingIssuesJson]
              ]
      case decodeGitHubItems (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right ([], [degraded, intact]) -> do
          degraded.pullRequestLabels `shouldBe` []
          degraded.pullRequestLabelOverflow `shouldBe` 0
          degraded.pullRequestDataGaps `shouldBe` [LabelsUnavailable]
          intact.pullRequestLabels `shouldBe` [Label "bug" "d73a4a"]
          intact.pullRequestDataGaps `shouldBe` []
          snapshotWarnings defaultLimitsConfig defaultWorkflowConfig (RepoSnapshot [] [degraded, intact] epoch False False)
            `shouldSatisfy` any (Data.Text.isInfixOf "PR #9: incomplete data")
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- Absence is the other form the same anomaly takes, and it has to reach
    -- issues as well as pull requests.
    it "decodes an absent nested connection on an issue as a gap rather than as no assignees" $ do
      let response =
            githubPageWith
              [ issueNodeJson 41 [emptyLabelsJson],
                issueNodeJson 42 [emptyLabelsJson, emptyAssigneesJson]
              ]
              [pullRequestNodeJson 9 [emptyLabelsJson, "\"closingIssuesReferences\":null"]]
      case decodeGitHubItems (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right ([degraded, intact], [pullRequest]) -> do
          degraded.issueAssignees `shouldBe` []
          degraded.issueAssigneeOverflow `shouldBe` 0
          degraded.issueDataGaps `shouldBe` [AssigneesUnavailable]
          intact.issueDataGaps `shouldBe` []
          pullRequest.pullRequestLinkedIssues `shouldBe` []
          pullRequest.pullRequestDataGaps `shouldBe` [LinkedIssuesUnavailable]
          let warnings = snapshotWarnings defaultLimitsConfig defaultWorkflowConfig (RepoSnapshot [degraded, intact] [pullRequest] epoch False False)
          warnings `shouldSatisfy` any (Data.Text.isInfixOf "Issue #41, PR #9: incomplete data")
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- The banner is one line, so many degraded items are named up to a limit
    -- and the rest counted -- visibly truncated rather than silently dropped.
    it "names the first few incomplete items and counts the rest" $ do
      let issues = [(baseIssue number []) {issueDataGaps = [AssigneesUnavailable]} | number <- [1 .. 5]]
          warnings = snapshotWarnings defaultLimitsConfig defaultWorkflowConfig (RepoSnapshot issues [] epoch False False)
      warnings `shouldSatisfy` any (Data.Text.isInfixOf "Issue #1, Issue #2, Issue #3 +2 more: incomplete data")

    -- A connection GitHub did deliver stays strict. These are not one item's
    -- missing field but a response shape the decoder cannot reason about, and
    -- degrading them would hide real corruption behind an amber card.
    it "still fails the page when a present nested connection is malformed" $ do
      let pageWithLabels labels = LazyByteString.pack (githubPageWith [] [pullRequestNodeJson 9 [labels, emptyClosingIssuesJson]])
      -- totalCount below the node list it came with
      decodeGitHubItems (pageWithLabels "\"labels\":{\"totalCount\":0,\"nodes\":[{\"name\":\"bug\",\"color\":\"d73a4a\"}]}")
        `shouldSatisfy` isLeft
      -- no totalCount at all
      decodeGitHubItems (pageWithLabels "\"labels\":{\"nodes\":[]}") `shouldSatisfy` isLeft
      -- a totalCount that is not a number
      decodeGitHubItems (pageWithLabels "\"labels\":{\"totalCount\":\"many\",\"nodes\":[]}") `shouldSatisfy` isLeft
      -- a node missing a field the item parser requires
      decodeGitHubItems (pageWithLabels "\"labels\":{\"totalCount\":1,\"nodes\":[{\"name\":\"bug\"}]}") `shouldSatisfy` isLeft
      -- a connection that is not an object
      decodeGitHubItems (pageWithLabels "\"labels\":5") `shouldSatisfy` isLeft

    -- The rollup's own container is not a per-context anomaly either.
    it "still fails the page when the rollup container itself is malformed" $ do
      let pageWithRollup rollup = LazyByteString.pack (githubPageWith [] [pullRequestNodeJson 9 [emptyLabelsJson, emptyClosingIssuesJson, rollup]])
      decodeGitHubItems (pageWithRollup "\"statusCheckRollup\":{\"contexts\":{\"nodes\":[]}}") `shouldSatisfy` isLeft
      decodeGitHubItems (pageWithRollup "\"statusCheckRollup\":{}") `shouldSatisfy` isLeft

    it "rejects a response that reported errors and delivered no repository" $
      decodeGitHubItems "{\"errors\":[{\"message\":\"boom\"}],\"data\":{}}"
        `shouldSatisfy` isLeft

    -- Errors with nothing usable behind them still fail the refresh, but the
    -- line section 17 shows now says what GitHub said. It used to read
    -- "contained errors" and never the rate limit, NOT_FOUND, or field
    -- problem that actually stopped the request.
    it "carries the GraphQL error messages into a fatal failure" $
      case decodeGitHubItems (LazyByteString.pack (graphqlErrorsOnly ["API rate limit exceeded for user ID 1"])) of
        Right values -> expectationFailure ("unexpected decode: " <> show values)
        Left message -> message `shouldSatisfy` isInfixOf "API rate limit exceeded for user ID 1"

    -- Every message, in the order GitHub reported them, folded onto the one
    -- line the banner has: GraphQL messages routinely arrive with newlines.
    it "joins every GraphQL message in order onto one line" $
      case decodeGitHubItems (LazyByteString.pack (graphqlErrorsOnly ["first problem", "second\\n   problem"])) of
        Right values -> expectationFailure ("unexpected decode: " <> show values)
        Left message -> message `shouldSatisfy` isInfixOf "first problem; second problem"

    -- The messages are GitHub's and unbounded, and they share that line with
    -- the counts and the snapshot time, so the aggregate is capped exactly
    -- where gh's stderr already is.
    it "caps the joined GraphQL messages at the provider message bound" $
      case decodeGitHubItems (LazyByteString.pack (graphqlErrorsOnly [replicate 400 'a', replicate 400 'b'])) of
        Right values -> expectationFailure ("unexpected decode: " <> show values)
        Left message -> do
          message `shouldSatisfy` isInfixOf (replicate 400 'a' <> "; " <> replicate 98 'b')
          message `shouldSatisfy` (not . isInfixOf (replicate 99 'b'))

    -- A page Aeson cannot read fails on Aeson's own text, which never passed
    -- through the structural checks and so never met the errors GitHub sent.
    -- Those failures are exactly the ones with an explanation available, and
    -- it has to survive them too -- not only the shapes the decoder itself
    -- rejects.
    it "keeps the GraphQL messages when the page itself cannot be decoded" $ do
      let respondWith nodes = LazyByteString.pack (githubPageWithErrors ["Something went wrong while executing your query"] Nothing nodes [])
          -- An item missing a scalar the parser requires.
          numberlessIssue = respondWith ["{\"title\":\"no number here\"}"]
          -- A requested connection that is not an object at all.
          brokenConnection =
            "{\"errors\":[{\"message\":\"Something went wrong while executing your query\"}],"
              <> "\"data\":{\"repository\":{\"issues\":5,\"pullRequests\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}"
      for_ [numberlessIssue, brokenConnection] $ \response ->
        case decodeGitHubItems response of
          Right values -> expectationFailure ("unexpected decode: " <> show values)
          Left message -> message `shouldSatisfy` isInfixOf "Something went wrong while executing your query"

    let initialFetchState =
          FetchState
            { fetchedIssues = [],
              fetchedPullRequests = [],
              issueCursor = Nothing,
              pullRequestCursor = Nothing,
              fetchMoreIssues = True,
              fetchMorePullRequests = True,
              issuesTruncated = False,
              pullRequestsTruncated = False,
              fetchWarnings = []
            }

    -- GraphQL answers a partly-resolvable query with data and errors
    -- together. This page is structurally complete -- both requested
    -- connections, both paginated to the end -- so the board shows what did
    -- arrive and the messages become the warning saying it is not everything.
    it "keeps a structurally complete response that carried errors, as a warning" $ do
      let response =
            githubPageWithErrors
              ["Could not resolve reviewDecision for pull request 9"]
              Nothing
              [issueNodeJson 41 [emptyLabelsJson, emptyAssigneesJson]]
              [pullRequestNodeJson 9 [emptyLabelsJson, emptyClosingIssuesJson]]
      case eitherDecode (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right page -> case advanceState defaultLimitsConfig initialFetchState page of
          Left providerError -> expectationFailure ("unexpectedly failed: " <> show providerError)
          Right state -> do
            map (.issueNumber) state.fetchedIssues `shouldBe` [41]
            map (.pullRequestNumber) state.fetchedPullRequests `shouldBe` [9]
            state.fetchWarnings
              `shouldBe` ["GitHub could not resolve part of this refresh: Could not resolve reviewDecision for pull request 9"]

    -- A refresh spans pages and only the last one builds the result, so a
    -- warning an earlier page raised has to survive the pages after it -- and
    -- none of the items it arrived with may be dropped on the way.
    it "accumulates one warning per page without losing decoded items" $ do
      let pageJson messages cursor issueNumber pullRequestNumber =
            githubPageWithErrors
              messages
              cursor
              [issueNodeJson issueNumber [emptyLabelsJson, emptyAssigneesJson]]
              [pullRequestNodeJson pullRequestNumber [emptyLabelsJson, emptyClosingIssuesJson]]
          pages =
            [ pageJson ["field errored on issue 41"] (Just "cursor-1") 41 9,
              pageJson ["field errored on issue 42"] Nothing 42 10
            ]
      case traverse (eitherDecode . LazyByteString.pack) pages of
        Left message -> expectationFailure message
        Right decoded -> case foldM (advanceState defaultLimitsConfig) initialFetchState decoded of
          Left providerError -> expectationFailure ("unexpectedly failed: " <> show providerError)
          Right state -> do
            map (.issueNumber) state.fetchedIssues `shouldBe` [41, 42]
            map (.pullRequestNumber) state.fetchedPullRequests `shouldBe` [9, 10]
            state.fetchWarnings
              `shouldBe` [ "GitHub could not resolve part of this refresh: field errored on issue 41",
                           "GitHub could not resolve part of this refresh: field errored on issue 42"
                         ]

    -- Errors beside data the decoder cannot reason about are not a partial
    -- response: a connection this request asked for is missing outright. The
    -- page fails as it always did, and the messages explain the hole instead
    -- of leaving a bare shape complaint with no cause.
    it "fails a response whose errors came with an incomplete page, keeping the messages" $ do
      let response =
            "{\"errors\":[{\"message\":\"Timeout resolving pullRequests\"}],\"data\":{\"repository\":"
              <> "{\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}}}}"
      case eitherDecode response of
        Left message -> expectationFailure message
        Right page -> case advanceState defaultLimitsConfig initialFetchState page of
          Right state -> expectationFailure ("unexpectedly advanced: " <> show state.fetchWarnings)
          Left providerError -> do
            providerError.providerErrorKind `shouldBe` InvalidResponse
            providerError.providerErrorMessage
              `shouldBe` "GitHub response omitted the pull requests connection: Timeout resolving pullRequests"

    it "marks a capped connection incomplete instead of requesting beyond its limit" $
      paginationDecision 250 250 True (Just "next") `shouldBe` Right (False, Nothing, True)

    it "does not mark an exact cap incomplete when GitHub reports no next page" $
      paginationDecision 250 250 False Nothing `shouldBe` Right (False, Nothing, False)

    it "requires a cursor whenever another page is needed" $
      paginationDecision 250 100 True Nothing `shouldSatisfy` isLeft

  describe "GitHub failure classification" $ do
    -- Verbatim from gh 2.83.1: the signed-out text it prints instead of
    -- running a command, the same state reported by `gh auth status`, and
    -- what it prints when a token is present but rejected. Phrase matching
    -- only earns its keep if it still recognizes these.
    it "reports a real gh authentication failure as authentication" $ do
      classifyFailure
        ( "To get started with GitHub CLI, please run:  gh auth login\n"
            <> "Alternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token."
        )
        `shouldBe` AuthenticationRequired
      classifyFailure "You are not logged into any GitHub hosts. To log in, run: gh auth login" `shouldBe` AuthenticationRequired
      classifyFailure "gh: Bad credentials (HTTP 401)" `shouldBe` AuthenticationRequired
      -- The API's own 401 body, which gh passes through for endpoints that
      -- answer with it rather than with Bad credentials.
      classifyFailure "gh: Requires authentication (HTTP 401)" `shouldBe` AuthenticationRequired
      classifyFailure "GraphQL: Authentication required (repository)" `shouldBe` AuthenticationRequired
      -- Recognition is case-insensitive, and does not depend on a phrase
      -- arriving beside any of the others.
      classifyFailure "BAD CREDENTIALS" `shouldBe` AuthenticationRequired
      classifyFailure "gh: You Are Not Logged Into github.com" `shouldBe` AuthenticationRequired

    -- The word "token" says nothing about credentials. AUTH REQUIRED over a
    -- rate limiter's token bucket sends a fully authenticated user off to log
    -- in again for what is a transient server error.
    it "does not read a bare token mention as an authentication failure" $ do
      classifyFailure "GraphQL: token bucket exhausted, retry after 60s" `shouldBe` RequestFailed
      classifyFailure "GraphQL: invalid pagination token" `shouldBe` RequestFailed
      classifyFailure "gh: OAuth application rate limit reached" `shouldBe` RequestFailed

    -- Reclassifying those is only half of it: what the user is left with has
    -- to be gh's own text, folded onto one line rather than replaced by a
    -- category name.
    it "preserves gh's own text for a failure that is not about credentials" $ do
      compactError "GraphQL: token bucket exhausted,\n  retry after 60s"
        `shouldBe` "GraphQL: token bucket exhausted, retry after 60s"
      compactError "GraphQL: invalid pagination token"
        `shouldBe` "GraphQL: invalid pagination token"

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
              pullRequestsTruncated = False,
              fetchWarnings = []
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

  -- NOT INSTALLED is a claim about the installation, so only a launch that
  -- failed because there was nothing runnable to launch may make it. The
  -- phase is what carries that distinction: the same errno means opposite
  -- things before and after the child exists.
  describe "gh process failure phases" $ do
    it "reports a gh that is not on PATH as a missing executable" $
      ghFailureKind GhLaunching (mkIOError doesNotExistErrorType "gh" Nothing (Just "gh"))
        `shouldBe` ExecutableMissing

    it "reports a gh that cannot be executed as a missing executable" $
      ghFailureKind GhLaunching (mkIOError permissionErrorType "gh" Nothing (Just "gh"))
        `shouldBe` ExecutableMissing

    it "reports a launch that ran out of resources as a failed request, not a missing gh" $
      ghFailureKind GhLaunching (mkIOError fullErrorType "runInteractiveProcess" Nothing Nothing)
        `shouldBe` RequestFailed

    it "reports a failure after the child exists as a failed request" $
      ghFailureKind GhRunning (mkIOError resourceVanishedErrorType "hGetContents" Nothing Nothing)
        `shouldBe` RequestFailed

    -- The regression itself: gh had already launched, so whatever the errno
    -- says, it is not missing. A classifier that read the exception alone
    -- would send a user with a working gh off to install it.
    it "never blames the installation for a does-not-exist error raised after the child exists" $
      ghFailureKind GhRunning (mkIOError doesNotExistErrorType "hGetContents" Nothing (Just "gh"))
        `shouldBe` RequestFailed

  describe "board refresh gh process group cleanup" $ do
    it "kills the abandoned gh's whole process group, credential-helper descendant included, before it publishes the timeout" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let leaderMarker = temporaryRoot </> "gh.pid"
            descendantMarker = temporaryRoot </> "helper.pid"
        -- gh itself ignores TERM, standing in for one wedged on network I/O,
        -- and the helper it spawned inherits its process group and ignores
        -- TERM too. Cleanup that only TERMed the direct child -- what
        -- readProcessWithExitCode did -- leaves both of these running.
        withFakeGh
          temporaryRoot
          [ "trap '' TERM",
            "sh -c 'trap \"\" TERM; while :; do sleep 1; done' </dev/null >/dev/null 2>&1 &",
            "printf '%s\\n' \"$!\" > " <> ByteString.pack descendantMarker,
            "printf '%s\\n' \"$$\" > " <> ByteString.pack leaderMarker,
            "while :; do sleep 1; done"
          ]
          $ do
            (outcome, snapshotWhenPublished) <- captureBoardRefresh temporaryRoot 1
            leaderPid <- readMarkerPid leaderMarker
            descendantPid <- readMarkerPid descendantMarker
            -- The snapshot was taken by the publish callback itself, so this
            -- is the process table as of the instant the outcome was
            -- published -- not merely some time afterwards.
            case snapshotWhenPublished of
              Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
              Right identities -> do
                identityForPid leaderPid identities `shouldBe` Nothing
                identityForPid descendantPid identities `shouldBe` Nothing
            case outcome of
              BoardRefreshCompleted (Left providerError) -> providerError.providerErrorKind `shouldBe` RequestTimedOut
              other -> expectationFailure ("expected a clean timeout, got " <> show other)

    it "kills a descendant that joined the group after the census, while the members it did capture were exiting" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let binaryRoot = temporaryRoot </> "bin"
            lateChild = binaryRoot </> "late-child"
            descendantMarker = temporaryRoot </> "late.pid"
        createDirectoryIfMissing True binaryRoot
        ByteString.writeFile lateChild (ByteString.unlines ["#!/bin/sh", "trap '' TERM", "while :; do sleep 1; done"])
        setFileMode lateChild 0o700
        -- gh forks this one from its own TERM handler and then exits, so it
        -- joins the group strictly after the census and every captured
        -- member is gone by the time the escalation re-checks them. A
        -- verification that only looked for the identities it captured would
        -- see them all absent, call the group clean, and report an ordinary
        -- timeout with this still running.
        withFakeGh
          temporaryRoot
          [ ByteString.pack ("trap '" <> lateChild <> " </dev/null >/dev/null 2>&1 & printf \"%s\" \"$!\" > " <> descendantMarker <> "; exit 0' TERM"),
            "while :; do sleep 1; done"
          ]
          $ do
            (outcome, snapshotWhenPublished) <- captureBoardRefresh temporaryRoot 1
            descendantPid <- readMarkerPid descendantMarker
            case snapshotWhenPublished of
              Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
              Right identities -> identityForPid descendantPid identities `shouldBe` Nothing
            case outcome of
              BoardRefreshCompleted (Left providerError) -> providerError.providerErrorKind `shouldBe` RequestTimedOut
              other -> expectationFailure ("expected a clean timeout, got " <> show other)

    it "leaves a fast gh's decoded page untouched" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeGh
          temporaryRoot
          ["printf '%s' '" <> emptyGraphqlPage <> "'"]
          $ do
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshCompleted (Right githubResult) -> do
                githubResult.githubSnapshot.snapshotIssues `shouldBe` []
                githubResult.githubSnapshot.snapshotPullRequests `shouldBe` []
              other -> expectationFailure ("expected a decoded snapshot, got " <> show other)

    -- The stderr is gh 2.83.1's own text for a token it was given and the
    -- API rejected, so the refresh is reporting a failure gh can really
    -- produce rather than one shaped to match the classifier.
    it "leaves a failing gh's exit status and stderr untouched" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeGh
          temporaryRoot
          [ "printf '%s\\n' 'gh: Bad credentials (HTTP 401)' >&2",
            "exit 1"
          ]
          $ do
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshCompleted (Left providerError) -> do
                providerError.providerErrorKind `shouldBe` AuthenticationRequired
                Data.Text.unpack providerError.providerErrorMessage `shouldContain` "Bad credentials (HTTP 401)"
              other -> expectationFailure ("expected a reported gh failure, got " <> show other)

    -- classifyFailure's phrase list is unit-tested on its own; this is the
    -- integration half, proving an ordinary (non-credential) gh failure
    -- reaches the board as RequestFailed rather than AuthenticationRequired.
    it "classifies a non-authentication gh failure as an ordinary request failure" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeGh
          temporaryRoot
          [ "printf '%s\\n' 'gh: GraphQL: Something went wrong while executing your query (repository)' >&2",
            "exit 1"
          ]
          $ do
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshCompleted (Left providerError) -> do
                providerError.providerErrorKind `shouldBe` RequestFailed
                Data.Text.unpack providerError.providerErrorMessage
                  `shouldContain` "Something went wrong while executing your query"
              other -> expectationFailure ("expected a reported gh failure, got " <> show other)

    -- graphqlArguments' construction is unit-tested on its own; this drives
    -- a real two-page fetch through the actual gh invocation and proves the
    -- exact argv it builds is what reaches the subprocess on both the first
    -- page and the cursor-carrying follow-up, while accumulating both
    -- connections in the order the pages arrived.
    it "observes the exact first-page and cursor-page argv gh is invoked with, and preserves page order" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository temporaryRoot "coghex" "kanban"
            argvLog = temporaryRoot </> "argv.log"
            counterFile = temporaryRoot </> "invocation.count"
            firstPage =
              githubPageWithErrors
                []
                (Just "cursor-1")
                [issueNodeJson 41 [emptyLabelsJson, emptyAssigneesJson]]
                [pullRequestNodeJson 9 [emptyLabelsJson, emptyClosingIssuesJson]]
            secondPage =
              githubPageWithErrors
                []
                Nothing
                [issueNodeJson 42 [emptyLabelsJson, emptyAssigneesJson]]
                [pullRequestNodeJson 10 [emptyLabelsJson, emptyClosingIssuesJson]]
            initialState = FetchState [] [] Nothing Nothing True True False False []
        decodedFirstPage <- case eitherDecode (LazyByteString.pack firstPage) of
          Left message -> fail ("undecodable fixture page: " <> message)
          Right page -> pure page
        secondPageState <- case advanceState defaultLimitsConfig initialState decodedFirstPage of
          Left providerError -> fail ("fixture page unexpectedly failed to advance: " <> show providerError)
          Right state -> pure state
        outcome <-
          withFakeGh
            temporaryRoot
            [ "for arg in \"$@\"; do printf '%s\\037' \"$arg\" >> " <> ByteString.pack argvLog <> "; done",
              "printf '\\036' >> " <> ByteString.pack argvLog,
              "count=$(( $(cat " <> ByteString.pack counterFile <> " 2>/dev/null || echo 0) + 1 ))",
              "printf '%s' \"$count\" > " <> ByteString.pack counterFile,
              "if [ \"$count\" -eq 1 ]; then printf '%s' '"
                <> ByteString.pack firstPage
                <> "'; else printf '%s' '"
                <> ByteString.pack secondPage
                <> "'; fi"
            ]
            (fst <$> captureBoardRefresh temporaryRoot 30)
        case outcome of
          BoardRefreshCompleted (Right githubResult) -> do
            map (.issueNumber) githubResult.githubSnapshot.snapshotIssues `shouldBe` [41, 42]
            map (.pullRequestNumber) githubResult.githubSnapshot.snapshotPullRequests `shouldBe` [9, 10]
          other -> expectationFailure ("expected a decoded two-page snapshot, got " <> show other)
        recordedBytes <- ByteString.readFile argvLog
        let invocations =
              map
                (map ByteString.unpack . init . ByteString.split '\US')
                (filter (not . ByteString.null) (ByteString.split '\RS' recordedBytes))
        case invocations of
          [firstArgv, secondArgv] -> do
            firstArgv `shouldBe` graphqlArguments defaultLimitsConfig repository initialState
            secondArgv `shouldBe` graphqlArguments defaultLimitsConfig repository secondPageState
          other -> expectationFailure ("expected exactly two recorded gh invocations, got " <> show (length other))

    -- The pull-request cap is 100, equal to the page size, so a single full
    -- page reaching it truncates immediately without needing a second
    -- fetch -- the exact shape a capped connection takes in production.
    it "reports the pull-request truncation fields and warning once a connection reaches its configured cap" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let cappedPullRequestNodes = intercalate "," [pullRequestNodeJson number [emptyLabelsJson, emptyClosingIssuesJson] | number <- [1 .. 100]]
            cappedPage =
              "{\"data\":{\"repository\":{"
                <> "\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}},"
                <> "\"pullRequests\":{\"nodes\":["
                <> cappedPullRequestNodes
                <> "],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"more\"}}"
                <> "}}}"
        withFakeGh temporaryRoot ["printf '%s' '" <> ByteString.pack cappedPage <> "'"] $ do
          (outcome, _) <- captureBoardRefresh temporaryRoot 30
          case outcome of
            BoardRefreshCompleted (Right githubResult) -> do
              githubResult.githubSnapshot.snapshotPullRequestsTruncated `shouldBe` True
              githubResult.githubSnapshot.snapshotIssuesTruncated `shouldBe` False
              length githubResult.githubSnapshot.snapshotPullRequests `shouldBe` 100
              githubResult.githubWarnings `shouldBe` ["100+ open pull requests; board is truncated"]
            other -> expectationFailure ("expected a truncated snapshot, got " <> show other)

    -- The output is read as bytes and decoded once, leniently, as UTF-8, so a
    -- response GitHub truncated mid-character is a page with a replacement
    -- character in it rather than an exception thrown out of the decoder --
    -- which the locale path reported as a missing executable.
    it "replaces malformed bytes inside a decoded page instead of failing the refresh" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeGh
          temporaryRoot
          -- \377 is never a legal UTF-8 byte anywhere, so it cannot be read
          -- as a lone continuation or a truncated sequence.
          [ "printf '%s\\377%s' "
              <> "'{\"data\":{\"repository\":{\"issues\":{\"nodes\":[{\"number\":41,\"title\":\"Broken "
              <> "' '"
              <> "byte\",\"body\":\"B\",\"url\":\"https://example.test/issues/41\","
              <> "\"createdAt\":\"2026-01-01T00:00:00Z\",\"updatedAt\":\"2026-01-02T00:00:00Z\"}],"
              <> "\"pageInfo\":{\"hasNextPage\":false}},"
              <> "\"pullRequests\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}'"
          ]
          $ do
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshCompleted (Right githubResult) ->
                map issueTitle githubResult.githubSnapshot.snapshotIssues
                  `shouldBe` [Data.Text.pack "Broken \65533byte"]
              other -> expectationFailure ("expected a decoded snapshot, got " <> show other)

    -- The one condition that cannot be established from in here: GHC fixes
    -- the locale encoding before main runs, so this re-runs the test binary
    -- as a child under LC_ALL=C and asserts on the bytes it wrote back.
    it "decodes a non-ASCII page and a non-ASCII failure identically under a C locale" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withLocaleProbe temporaryRoot $ \probe -> do
          -- Asserted before the decodes, so a fixture that never handed the
          -- child a C locale reports that rather than passing vacuously.
          probe.localeProbeLcAll `shouldBe` Data.Text.pack "C"
          probe.localeProbeTitles `shouldBe` Data.Text.intercalate "\n" unicodeIssueTitles
          probe.localeProbeFailureKind `shouldBe` Data.Text.pack (show AuthenticationRequired)
          probe.localeProbeFailureMessage `shouldBe` unicodeFailureText

    it "re-kills a gh group recorded by an earlier run before it fetches again, then clears the record" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let ranMarker = temporaryRoot </> "gh-ran"
            repository = Repository temporaryRoot "coghex" "kanban"
        -- Stands in for the gh a previous dashboard could not confirm dead:
        -- still alive, still ignoring TERM, recorded on disk exactly as
        -- 'abandonGh' would have left it. Nothing in this process has ever
        -- seen it before -- which is the point, since the concern is a
        -- restarted dashboard racing a survivor.
        withSurvivingGroupLeader $ \survivorPid ->
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            snapshot <- readProcessSnapshot
            case snapshot of
              Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
              Right identities -> do
                let members = filter ((== survivorPid) . processIdentityGroupPid) identities
                members `shouldNotBe` []
                writeGhGroupRecord repository [OwnedProcessGroup survivorPid members True] `shouldReturn` Right ()
            withFakeGh
              temporaryRoot
              [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
                "printf '%s' '" <> emptyGraphqlPage <> "'"
              ]
              $ do
                (outcome, _) <- captureBoardRefresh temporaryRoot 30
                case outcome of
                  BoardRefreshCompleted (Right _) -> pure ()
                  other -> expectationFailure ("expected the refresh to proceed once the survivor was reclaimed, got " <> show other)
            -- The survivor is gone, and it was dealt with by the reclaim step
            -- rather than left to race the gh this refresh went on to spawn.
            reclaimed <- readProcessSnapshot
            case reclaimed of
              Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
              Right identities -> identityForPid survivorPid identities `shouldBe` Nothing
            doesFileExist ranMarker `shouldReturn` True
            (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    it "empties a recorded group whose member would fork a replacement from its TERM handler, without giving it the chance" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let binaryRoot = temporaryRoot </> "bin"
            lateChild = binaryRoot </> "late-child"
            descendantMarker = temporaryRoot </> "late.pid"
            repository = Repository temporaryRoot "coghex" "kanban"
        createDirectoryIfMissing True binaryRoot
        ByteString.writeFile lateChild (ByteString.unlines ["#!/bin/sh", "trap '' TERM", "while :; do sleep 1; done"])
        setFileMode lateChild 0o700
        -- This member would fork a replacement from its TERM handler and
        -- exit. Under a TERM-first escalation that newcomer is unanswerable:
        -- it appears in no census taken while ownership was provable, and the
        -- member that proved ownership is gone by the time any census could
        -- see it -- a fork and an exit being quicker than a process listing.
        --
        -- Freezing the group first removes the opening rather than racing it.
        -- SIGSTOP cannot be handled, so the trap never runs, nothing is
        -- forked, and the census taken while the group is frozen is both
        -- complete and provably ours.
        (_, _, _, recordedLeader) <-
          createProcess
            (proc "sh" ["-c", "trap '" <> lateChild <> " </dev/null >/dev/null 2>&1 & printf \"%s\" \"$!\" > " <> descendantMarker <> "; exit 0' TERM; while :; do sleep 1; done </dev/null >/dev/null 2>&1"])
              {create_group = True}
        Just leaderPid <- fmap fromIntegral <$> getPid recordedLeader
        threadDelay 200000
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          snapshot <- readProcessSnapshot
          case snapshot of
            Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
            Right identities ->
              writeGhGroupRecord repository [OwnedProcessGroup leaderPid (filter ((== leaderPid) . processIdentityGroupPid) identities) True]
                `shouldReturn` Right ()
          withFakeGh temporaryRoot ["printf '%s' '" <> emptyGraphqlPage <> "'"] $ do
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshCompleted (Right _) -> pure ()
              other -> expectationFailure ("expected the reclaimed group to let the fetch proceed, got " <> show other)
          reclaimed <- readProcessSnapshot
          case reclaimed of
            Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
            Right identities -> identityForPid leaderPid identities `shouldBe` Nothing
          -- The trap never ran, so there is no replacement to account for.
          doesFileExist descendantMarker `shouldReturn` False
          (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    it "refuses to spawn gh while a non-leader record's saved gh is alive in some other process group" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let ranMarker = temporaryRoot </> "gh-ran"
            repository = Repository temporaryRoot "coghex" "kanban"
        -- The record 'abandonGh' writes when create_group did not take
        -- effect: the pgid is gh's own PID, but gh is sitting in somebody
        -- else's group, so nothing ever has that pgid. Asking only about the
        -- pgid finds an empty group and calls the record spent -- while the
        -- gh it names is still running.
        withNonLeaderProcess $ \nonLeaderPid ->
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            snapshot <- readProcessSnapshot
            identity <- case snapshot >>= maybe (Left "fixture absent from snapshot") Right . identityForPid nonLeaderPid of
              Left message -> fail (Data.Text.unpack message)
              Right identity -> pure identity
            identity.processIdentityGroupPid `shouldNotBe` nonLeaderPid
            writeGhGroupRecord repository [OwnedProcessGroup nonLeaderPid [identity] False] `shouldReturn` Right ()
            withFakeGh
              temporaryRoot
              [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
                "printf '%s' '" <> emptyGraphqlPage <> "'"
              ]
              $ do
                (outcome, _) <- captureBoardRefresh temporaryRoot 30
                heldOffMessage outcome >>= (`shouldMention` "cannot be identified as this repository's")
            doesFileExist ranMarker `shouldReturn` False
            (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` True
        -- Once the saved gh exits the record has nothing left to name, so the
        -- refusal lifts on its own.
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          withFakeGh
            temporaryRoot
            [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
              "printf '%s' '" <> emptyGraphqlPage <> "'"
            ]
            $ do
              (outcome, _) <- captureBoardRefresh temporaryRoot 30
              case outcome of
                BoardRefreshCompleted (Right _) -> pure ()
                other -> expectationFailure ("expected the refresh to proceed once the saved gh exited, got " <> show other)
          doesFileExist ranMarker `shouldReturn` True
          (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    it "refuses to spawn gh while an uncensused record's pgid is still occupied, rather than reading its empty membership as absent" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let ranMarker = temporaryRoot </> "gh-ran"
            repository = Repository temporaryRoot "coghex" "kanban"
        -- What 'abandonGh' records when the process snapshot itself failed:
        -- the pgid and nothing else. Handing that to a group membership check
        -- would find no recorded members present and call the group gone --
        -- vacuously, while it is plainly still running.
        withSurvivingGroupLeader $ \survivorPid ->
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            writeGhGroupRecord repository [OwnedProcessGroup survivorPid [] False] `shouldReturn` Right ()
            withFakeGh
              temporaryRoot
              [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
                "printf '%s' '" <> emptyGraphqlPage <> "'"
              ]
              $ do
                (outcome, _) <- captureBoardRefresh temporaryRoot 30
                heldOffMessage outcome >>= (`shouldMention` "cannot be identified as this repository's")
            doesFileExist ranMarker `shouldReturn` False
            -- The record survives the refusal: nothing about this attempt
            -- made the survivor any more accounted for.
            (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` True

    it "refuses to spawn gh while an uncensused record's own identity is still alive, then proceeds once it exits" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let ranMarker = temporaryRoot </> "gh-ran"
            repository = Repository temporaryRoot "coghex" "kanban"
        -- What 'abandonGh' records when gh turned out not to lead its own
        -- group: the identity is exact, but its pgid covers processes this
        -- dashboard never spawned, so it may be watched and never signalled.
        survivorIdentity <-
          withSurvivingGroupLeader $ \survivorPid -> do
            snapshot <- readProcessSnapshot
            case snapshot >>= maybe (Left "fixture absent from snapshot") Right . identityForPid survivorPid of
              Left message -> fail (Data.Text.unpack message)
              Right identity -> do
                withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
                  writeGhGroupRecord repository [OwnedProcessGroup survivorPid [identity] False] `shouldReturn` Right ()
                  withFakeGh
                    temporaryRoot
                    [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
                      "printf '%s' '" <> emptyGraphqlPage <> "'"
                    ]
                    $ do
                      (outcome, _) <- captureBoardRefresh temporaryRoot 30
                      heldOffMessage outcome >>= (`shouldMention` "cannot be identified as this repository's")
                  doesFileExist ranMarker `shouldReturn` False
                pure identity
        -- 'withSurvivingGroupLeader' has now killed it, so the very same
        -- record clears itself: the guard is fail-closed, not a permanent
        -- wedge.
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          survivorIdentity.processIdentityCommand `shouldMention` "TERM"
          withFakeGh
            temporaryRoot
            [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
              "printf '%s' '" <> emptyGraphqlPage <> "'"
            ]
            $ do
              (outcome, _) <- captureBoardRefresh temporaryRoot 30
              case outcome of
                BoardRefreshCompleted (Right _) -> pure ()
                other -> expectationFailure ("expected the refresh to proceed once the survivor exited, got " <> show other)
          doesFileExist ranMarker `shouldReturn` True
          (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    it "refuses to spawn gh at all while a recorded group cannot be read back" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let ranMarker = temporaryRoot </> "gh-ran"
            repository = Repository temporaryRoot "coghex" "kanban"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          recordPath <- ghGroupRecordPath repository
          createDirectoryIfMissing True (takeDirectory recordPath)
          -- A record that cannot be decoded means "a gh of ours may be live
          -- and we cannot tell which": treating that as "nothing recorded"
          -- is precisely the overlap this guard exists to prevent.
          ByteString.writeFile recordPath "{ this is not a gh group record"
          withFakeGh
            temporaryRoot
            [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
              "printf '%s' '" <> emptyGraphqlPage <> "'"
            ]
            $ do
              (outcome, _) <- captureBoardRefresh temporaryRoot 30
              heldOffMessage outcome >>= (`shouldMention` "refusing to start another")
          doesFileExist ranMarker `shouldReturn` False

    it "stops the gh it just spawned when no durable guard can be written for it, leaving nothing for a restart to overlap" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let unwritableCacheRoot = temporaryRoot </> "cache-is-a-file"
        -- An unwritable cache is the case where the guard cannot be
        -- persisted at all. Since it is written before gh is used for
        -- anything, the failure is caught while gh is still this process's
        -- to terminate -- rather than after a timeout, when only an
        -- in-memory gate would be left and a restart would drop it.
        ByteString.writeFile unwritableCacheRoot "not a directory"
        withEnvironmentValue "XDG_CACHE_HOME" unwritableCacheRoot $
          withFakeGh
            temporaryRoot
            ["trap '' TERM", "while :; do sleep 1; done"]
            $ do
              -- The refresh timeout is short only so that a regression here
              -- fails fast: the guard is written before gh runs, so the real
              -- path never gets near it.
              (outcome, _) <- captureBoardRefresh temporaryRoot 2
              case outcome of
                BoardRefreshCompleted (Left providerError) -> do
                  providerError.providerErrorKind `shouldBe` RequestFailed
                  providerError.providerErrorMessage `shouldMention` "could not record the gh process it started"
                other -> expectationFailure ("expected the unguarded gh to be refused, got " <> show other)
              -- Asked of the process table rather than of a marker file the
              -- fake would have to win a race to write: whether it got as far
              -- as running or was stopped before it did, nothing from this
              -- fetch may still be alive for a restart to collide with.
              snapshot <- readProcessSnapshot
              case snapshot of
                Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
                Right identities ->
                  filter (Data.Text.isInfixOf (Data.Text.pack (temporaryRoot </> "bin")) . processIdentityCommand) identities
                    `shouldBe` []

    it "treats a forced kill as a clean outcome once a snapshot shows the whole group gone, descendant included" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- ps fails for exactly as long as the verified kill needs it (three
        -- attempts, the retry budget of 'defaultProcessSnapshot') and then
        -- works again, so the forced fallback runs and its own whole-group
        -- check is the thing that gets to answer. Because that check
        -- succeeds, this is not a failed cleanup at all: proven emptiness is
        -- the ordinary result no matter which signal established it.
        (outcome, survivors) <- forcedCleanupRun temporaryRoot 2 (Just 3)
        survivors `shouldBe` []
        case outcome of
          -- Reported as an ordinary failed refresh rather than an unverified
          -- cleanup, which is the point: the group was proven empty, so there
          -- is nothing left for a later refresh to overlap and no reason to
          -- hold the board off. Whether it surfaces as the guard-write
          -- failure or as the timeout depends on which the clock reached
          -- first, and neither is a claim about surviving processes.
          BoardRefreshCompleted (Left providerError) ->
            providerError.providerErrorKind `shouldSatisfy` (`elem` [RequestFailed, RequestTimedOut])
          other -> expectationFailure ("expected a plain failure once the group was proven empty, got " <> show other)

    it "makes no claim at all while no snapshot can confirm the group, but still takes the descendant with it" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- ps never works, so whole-group absence can never be shown and
        -- nothing durable can be written either. SIGKILL still went to the
        -- group, so the TERM-ignoring descendant is gone -- but that is not
        -- evidence, and the outcome must say so rather than infer from it.
        (outcome, survivors) <- forcedCleanupRun temporaryRoot 2 Nothing
        case outcome of
          BoardRefreshUnverified failure -> failure.ghCleanupGuard `shouldBe` GuardInMemoryOnly
          other -> expectationFailure ("expected an unguarded gh, got " <> show other)
        survivors `shouldBe` []

    it "finishes cleanup even when the refresh timer fires part-way through it" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- One second is a legal github_seconds, and cleanup needs longer than
        -- that: two 750ms grace windows plus snapshots. The timer therefore
        -- lands inside it. 'mask' does not stop that -- every one of those
        -- waits is an interruptible point -- so cleanup abandoned half-way
        -- would leave the TERM-resistant descendant running while the fetch
        -- reported an ordinary timeout. The store is unwritable throughout,
        -- so no durable record can paper over it either.
        (outcome, survivors) <- forcedCleanupRun temporaryRoot 1 (Just 0)
        -- The property is that nothing outlived the report. Whether the
        -- refresh surfaces the timeout or the guard-write failure depends on
        -- which the clock reached first, and neither is a claim about
        -- surviving processes.
        survivors `shouldBe` []
        case outcome of
          BoardRefreshCompleted (Left providerError) ->
            providerError.providerErrorKind `shouldSatisfy` (`elem` [RequestTimedOut, RequestFailed])
          BoardRefreshUnverified _ -> pure ()
          other -> expectationFailure ("expected the refresh to report a stopped gh, got " <> show other)

    it "cleans up a descendant that outlives a gh which exited normally, rather than deferring it" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let binaryRoot = temporaryRoot </> "bin"
            lingerer = binaryRoot </> "lingerer"
            descendantMarker = temporaryRoot </> "lingerer.pid"
            repository = Repository temporaryRoot "coghex" "kanban"
        createDirectoryIfMissing True binaryRoot
        ByteString.writeFile lingerer (ByteString.unlines ["#!/bin/sh", "trap '' TERM", "while :; do sleep 1; done"])
        setFileMode lingerer 0o700
        -- gh answers correctly and exits 0, but leaves a descendant behind in
        -- its group with the pipes closed, so nothing about the ordinary
        -- collect path notices. The fetch records what it found and hands the
        -- group to cleanup without reaping, which is what leaves cleanup a
        -- live PID to escalate against -- so the descendant is dealt with
        -- here rather than deferred to whatever fetch comes next.
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          withFakeGh
            temporaryRoot
            [ ByteString.pack (lingerer <> " </dev/null >/dev/null 2>&1 &"),
              ByteString.pack ("printf '%s' \"$!\" > " <> descendantMarker),
              "printf '%s' '" <> emptyGraphqlPage <> "'",
              "exit 0"
            ]
            $ do
              (outcome, _) <- captureBoardRefresh temporaryRoot 30
              case outcome of
                -- The fetch failed -- it did leave a group it could not
                -- account for -- but the board is not held off, because
                -- cleanup went on to prove there is nothing left to hold off
                -- for. Holding off with nothing surviving would mean never
                -- refreshing again.
                BoardRefreshCompleted (Left providerError) ->
                  providerError.providerErrorMessage `shouldMention` "could not confirm stopped"
                other -> expectationFailure ("expected the unresolved group to be reported, got " <> show other)
          descendantPid <- readMarkerPid descendantMarker
          snapshot <- readProcessSnapshot
          case snapshot of
            Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
            Right identities -> identityForPid descendantPid identities `shouldBe` Nothing
          -- Nothing survives, so nothing is left on record either.
          (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    it "finishes reclaiming a recorded group even when the refresh timer fires during it" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let ranMarker = temporaryRoot </> "gh-ran"
            repository = Repository temporaryRoot "coghex" "kanban"
        -- Reclaim signals a process group and then confirms what it did.
        -- Two recorded groups take comfortably longer than the one-second
        -- timeout to work through, so the timer certainly fires part-way.
        -- Interrupted there, reclaim would leave groups signalled but
        -- unestablished and the record uncleared -- and, because reclaim runs
        -- before the guard holds anything, the refresh would publish an
        -- ordinary timeout over whatever it had not got to.
        withSurvivingGroupLeader $ \survivorPid ->
          withSurvivingGroupLeader $ \secondPid ->
            withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
              snapshot <- readProcessSnapshot
              case snapshot of
                Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
                Right identities -> do
                  let membersOf pid = filter ((== pid) . processIdentityGroupPid) identities
                  membersOf survivorPid `shouldNotBe` []
                  membersOf secondPid `shouldNotBe` []
                  writeGhGroupRecord
                    repository
                    [ OwnedProcessGroup survivorPid (membersOf survivorPid) True,
                      OwnedProcessGroup secondPid (membersOf secondPid) True
                    ]
                    `shouldReturn` Right ()
              withFakeGh
                temporaryRoot
                [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
                  "printf '%s' '" <> emptyGraphqlPage <> "'"
                ]
                $ do
                  -- Whatever the refresh goes on to report -- it may well
                  -- time out, and honestly so once the groups are provably
                  -- gone -- is not the point here. Whether reclaim finished
                  -- is.
                  void (captureBoardRefresh temporaryRoot 1)
              -- Both groups gone, and the record cleared: reclaim reached its
              -- confirming census and its own conclusion, rather than being
              -- abandoned after the signals with the record still standing.
              reclaimed <- readProcessSnapshot
              case reclaimed of
                Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
                Right identities -> do
                  identityForPid survivorPid identities `shouldBe` Nothing
                  identityForPid secondPid identities `shouldBe` Nothing
              (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    it "reports a reclaim that refused, even when the refresh timer fired while it was shielded" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository temporaryRoot "coghex" "kanban"
        -- Two recorded groups: the first this repository's and killable, the
        -- second occupied by a process no saved identity matches. Working
        -- through the first outlasts the one-second timeout, so the timer is
        -- already pending when the second is refused.
        --
        -- That pending exception is delivered the instant the shield's mask
        -- lifts, before anything outside it could run -- so a refusal decided
        -- inside and published outside would simply be lost, and the refresh
        -- would report an ordinary timeout over a record it had just failed
        -- to clear.
        withSurvivingGroupLeader $ \ourPid ->
          withSurvivingGroupLeader $ \squatterPid ->
            withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
              snapshot <- readProcessSnapshot
              case snapshot of
                Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
                Right identities -> do
                  let ours = filter ((== ourPid) . processIdentityGroupPid) identities
                      departed =
                        ProcessIdentity
                          { processIdentityPid = squatterPid,
                            processIdentityParentPid = 1,
                            processIdentityGroupPid = squatterPid,
                            processIdentityStartedAt = "Thu Jan 1 00:00:00 1970",
                            processIdentityCommand = "gh api graphql"
                          }
                  ours `shouldNotBe` []
                  writeGhGroupRecord
                    repository
                    [ OwnedProcessGroup ourPid ours True,
                      OwnedProcessGroup squatterPid [departed] True
                    ]
                    `shouldReturn` Right ()
              withFakeGh temporaryRoot ["printf '%s' '" <> emptyGraphqlPage <> "'"] $ do
                (outcome, _) <- captureBoardRefresh temporaryRoot 1
                heldOffMessage outcome >>= (`shouldMention` "cannot be identified as this repository's")
              -- The record stands, naming the group that was refused.
              (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` True

    it "does not mistake a gh that is still exiting for a group it leaked" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository temporaryRoot "coghex" "kanban"
        -- Closing the output is not exiting. This gh answers, closes both
        -- streams so the drain sees EOF, and only then takes its time going
        -- away. Censusing at EOF would find the leader itself still sitting
        -- in the group and refuse a perfectly good fetch -- which is why the
        -- census waits for the leader to leave the table first.
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          withFakeGh
            temporaryRoot
            [ "printf '%s' '" <> emptyGraphqlPage <> "'",
              "exec 1>&- 2>&-",
              "sleep 0.4",
              "exit 0"
            ]
            $ do
              (outcome, _) <- captureBoardRefresh temporaryRoot 30
              case outcome of
                BoardRefreshCompleted (Right _) -> pure ()
                other -> expectationFailure ("expected the slow-exiting gh to be accepted, got " <> show other)
          (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    it "keeps the record when it cannot census the group of a gh that exited normally" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let binaryRoot = temporaryRoot </> "bin"
            repository = Repository temporaryRoot "coghex" "kanban"
        -- gh answers and exits perfectly, but by the time its group must be
        -- censused ps has stopped working, so nothing can establish that the
        -- group is empty. Reading "no census" as "nothing there" is what would
        -- drop the guard here.
        --
        -- ps is allowed to work for the first two calls -- the pre-release
        -- leadership check and the wait for gh to leave the table -- so the
        -- failure lands on the census itself rather than on an earlier guard
        -- that would refuse for an entirely different reason.
        let psCounter = temporaryRoot </> "ps.count"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          withFakeGh temporaryRoot ["printf '%s' '" <> emptyGraphqlPage <> "'"] $ do
            createDirectoryIfMissing True binaryRoot
            ByteString.writeFile
              (binaryRoot </> "ps")
              ( ByteString.unlines
                  [ "#!/bin/sh",
                    ByteString.pack ("attempt=$(cat " <> psCounter <> " 2>/dev/null || echo 0)"),
                    "attempt=$((attempt + 1))",
                    ByteString.pack ("printf '%s' \"$attempt\" > " <> psCounter),
                    "[ \"$attempt\" -gt 2 ] && exit 1",
                    "exec /bin/ps \"$@\""
                  ]
              )
            setFileMode (binaryRoot </> "ps") 0o700
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshUnverified failure ->
                -- The inner message, not the wrapper: the wrapper reads the
                -- same whichever guard refused, which would let this pass
                -- while testing an entirely different one.
                failure.ghCleanupMessage `shouldMention` "could not confirm gh's process group was empty"
              other -> expectationFailure ("expected the uncensusable group to be reported, got " <> show other)
          (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` True

    it "resolves each page's group before the next page starts, so a paginated fetch never guards two at once" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository temporaryRoot "coghex" "kanban"
            pageCounter = temporaryRoot </> "page.count"
            recordCopy = temporaryRoot </> "record-seen"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          recordPath <- ghGroupRecordPath repository
          -- Each invocation copies the guard record as it stood when that
          -- page's gh began. One snapshot fetch runs several sequential gh
          -- processes, and page N's entry must be gone by the time page N+1
          -- exists -- otherwise an abandoned earlier page would be left
          -- unresolved while a later one was already running.
          withFakeGh
            temporaryRoot
            [ ByteString.pack ("page=$(cat " <> pageCounter <> " 2>/dev/null || echo 0)"),
              "page=$((page + 1))",
              ByteString.pack ("printf '%s' \"$page\" > " <> pageCounter),
              ByteString.pack ("cp " <> recordPath <> " " <> recordCopy <> ".$page 2>/dev/null || true"),
              "if [ \"$page\" -eq 1 ]; then",
              "  printf '%s' '{\"data\":{\"repository\":{\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"c1\"}},\"pullRequests\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}'",
              "else",
              "  printf '%s' '{\"data\":{\"repository\":{\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}'",
              "fi"
            ]
            $ do
              (outcome, _) <- captureBoardRefresh temporaryRoot 30
              case outcome of
                BoardRefreshCompleted (Right _) -> pure ()
                other -> expectationFailure ("expected the paginated fetch to succeed, got " <> show other)
          readMarkerPid pageCounter `shouldReturn` 2
          -- Page 2 began with exactly one guarded group on record: its own.
          secondPageRecord <- ByteString.readFile (recordCopy <> ".2")
          countOccurrences "ownedProcessGroupPid" secondPageRecord `shouldBe` 1
          -- And nothing is left guarded once the fetch completes.
          doesFileExist recordPath `shouldReturn` False

    it "refuses to let a child that does not lead its own group proceed to gh at all" $ do
      -- Every pgid question this module asks -- is the group empty, who is in
      -- it, may it be signalled -- presumes the number names this fetch's own
      -- group. When create_group has not taken effect it names nothing, and a
      -- helper the child leaves behind lives somewhere the module cannot see.
      -- So leadership is established while the child is parked on the barrier
      -- and has run nothing, which is both the only moment it is certainly
      -- observable and the only moment refusing is free.
      --
      -- create_group does take effect on this platform, so the two answers are
      -- asked of the check directly.
      withSurvivingGroupLeader $ \leaderPid -> confirmsOwnGroupLeadership leaderPid `shouldReturn` Right ()
      withNonLeaderProcess $ \nonLeaderPid -> do
        outcome <- confirmsOwnGroupLeadership nonLeaderPid
        case outcome of
          Left message -> message `shouldMention` "not the leader of its own process group"
          Right () -> expectationFailure "a non-leader child was accepted as leading its own group"

    it "does not read an unoccupied pgid as proof when the process it names is not that group's leader" $
      -- The forced fallback signals the spawned PID as a process group and
      -- then asks whether that group is empty. For a child that never became
      -- its own leader the signal reaches no group at all, and the pgid it
      -- names is unoccupied precisely because it does not exist -- so pgid
      -- emptiness alone would read as a successful kill while the process is
      -- plainly still running. create_group does take effect on this
      -- platform, so this is asked of the check directly.
      withNonLeaderProcess $ \nonLeaderPid -> do
        snapshot <- readProcessSnapshot
        case snapshot >>= maybe (Left "fixture absent from snapshot") Right . identityForPid nonLeaderPid of
          Left message -> expectationFailure (Data.Text.unpack message)
          Right identity -> identity.processIdentityGroupPid `shouldNotBe` nonLeaderPid
        groupConfirmedEmpty nonLeaderPid `shouldReturn` False

    it "never lets the child reach gh when the dashboard is lost before the guard is committed" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let ranMarker = temporaryRoot </> "gh-ran"
            fakeGh = temporaryRoot </> "gh"
        ByteString.writeFile fakeGh (ByteString.unlines ["#!/bin/sh", ByteString.pack ("printf '%s' ran > " <> ranMarker)])
        setFileMode fakeGh 0o700
        -- Standing in for the dashboard dying between 'createProcess' and the
        -- record being committed: the barrier is never released, and closing
        -- the pipe is exactly what a dead parent does. The child must exit
        -- having never executed gh, so a fresh fetch has nothing to overlap
        -- and nothing to have recorded.
        (Just barrierInput, _, _, child) <-
          createProcess (uncurry proc (ghBehindBarrier fakeGh ["api", "graphql"])) {std_in = CreatePipe, create_group = True}
        hClose barrierInput
        timeout 5000000 (waitForProcess child) `shouldReturn` Just ExitSuccess
        doesFileExist ranMarker `shouldReturn` False

    it "reports a gh that is missing from PATH as an unavailable executable" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let binaryRoot = temporaryRoot </> "bin"
        createDirectoryIfMissing True binaryRoot
        -- PATH carries nothing but the empty shim directory -- deliberately
        -- not the system paths, since gh is installed in one of those on some
        -- machines and the point here is that it cannot be found. Nothing on
        -- this path needs ps either: the fetch fails at resolution, before
        -- any process is spawned to census.
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" binaryRoot $ do
            (findExecutable "gh" >>= (`shouldBe` Nothing))
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshCompleted (Left providerError) -> providerError.providerErrorKind `shouldBe` ExecutableMissing
              other -> expectationFailure ("expected a missing gh, got " <> show other)

    it "refuses to signal a recorded pgid that some unrelated process now occupies, and keeps the record until it frees up" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let ranMarker = temporaryRoot </> "gh-ran"
            repository = Repository temporaryRoot "coghex" "kanban"
        -- A recycled pgid: the record's saved identities are all long gone,
        -- and the pgid it names now belongs to somebody else entirely.
        -- Signalling it would kill processes this repository never started,
        -- so the only safe answer is to refuse and keep watching.
        withSurvivingGroupLeader $ \squatterPid ->
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            let departed =
                  ProcessIdentity
                    { processIdentityPid = squatterPid,
                      processIdentityParentPid = 1,
                      processIdentityGroupPid = squatterPid,
                      processIdentityStartedAt = "Thu Jan 1 00:00:00 1970",
                      processIdentityCommand = "gh api graphql"
                    }
            writeGhGroupRecord repository [OwnedProcessGroup squatterPid [departed] True] `shouldReturn` Right ()
            withFakeGh
              temporaryRoot
              [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
                "printf '%s' '" <> emptyGraphqlPage <> "'"
              ]
              $ do
                (outcome, _) <- captureBoardRefresh temporaryRoot 30
                heldOffMessage outcome >>= (`shouldMention` "cannot be identified as this repository's")
            doesFileExist ranMarker `shouldReturn` False
            (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` True
            -- The squatter is untouched: refusing must not mean signalling.
            reclaimed <- readProcessSnapshot
            case reclaimed of
              Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
              Right identities -> identityForPid squatterPid identities `shouldSatisfy` isJust
        -- With the pgid free again the record clears on the next fetch.
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          withFakeGh temporaryRoot ["printf '%s' '" <> emptyGraphqlPage <> "'"] $ do
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshCompleted (Right _) -> pure ()
              other -> expectationFailure ("expected the refresh to proceed once the pgid was free, got " <> show other)
          (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    it "explains the unverified gh and what happens next, without offering a restart as the fix" $ do
      -- A recorded group self-heals on the next refresh; an unrecorded one
      -- leaves this dashboard unable to refresh at all. Neither may suggest
      -- restarting, which drops only the in-memory guard and would let a new
      -- gh overlap the old one.
      let noticeFor = unverifiedRefreshNotice . GhCleanupFailure "ps exited 1"
          recorded = noticeFor GuardRecorded
          inMemory = noticeFor GuardInMemoryOnly
      mapM_ (`shouldMention` "ps exited 1") [recorded, inMemory]
      mapM_ (`shouldMention` "could not be confirmed stopped") [recorded, inMemory]
      recorded `shouldMention` "the next refresh re-checks it"
      -- Neither notice may suggest restarting. Only a recorded group has
      -- anything that survives one, and a cleanup that proved the group gone
      -- does not produce a notice at all.
      inMemory `shouldMention` "check for a stray gh process"
      mapM_ (`shouldNotMention` "restarting is safe") [recorded, inMemory]

  -- One defect class at the three remaining call sites that captured a
  -- child's output as locale-decoded text: the process census, repository
  -- resolution and the provider preflight probes (issue #172). Each of
  -- these was a healthy child whose output raised an invalid-byte
  -- IOException on the way in, before the call site's own handling of the
  -- exit status ever ran. \377 is illegal UTF-8 under every locale, so the
  -- malformed-byte cases here reproduce the failure without needing one;
  -- the C-locale half of the repository case is in the locale probe, which
  -- has to re-run the test binary to establish a locale at all.
  describe "byte-safe subprocess capture" $ do
    -- A git that answers the two questions 'resolveRepository' asks: where
    -- the checkout is, and what the remote URL is. The URL is a printf
    -- format, so a fixture can put a byte no encoding accepts inside it.
    --
    -- The marker check is the fixture refusing to answer from anywhere but
    -- the checkout. resolveRepository conveys the directory as a cwd rather
    -- than as an argument -- the only channel that survives a path the
    -- locale cannot encode -- and a fixture that simply ignored the
    -- directory would answer just as happily from nowhere in particular.
    let checkoutMarker = "kanban-fixture-checkout"
        gitRemoteFake remoteUrl =
          ( "git",
            [ "[ -f ./" <> ByteString.pack checkoutMarker <> " ] || "
                <> "{ printf 'fake git: not started in the checkout\\n' >&2; exit 9; }",
              "case \"$*\" in",
              "  'rev-parse --show-toplevel') pwd -P ;;",
              "  'remote get-url origin') printf '" <> remoteUrl <> "\\n' ;;",
              "  *) exit 1 ;;",
              "esac"
            ]
          )

    it "keeps a ps row whose command carries an undecodable byte, in its original order" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeOnPath
          temporaryRoot
          ( "ps",
            [ "printf ' 101 100 101 S Mon Jan  1 00:00:01 2026 /usr/bin/first\\n'",
              "printf ' 102 100 101 S Mon Jan  1 00:00:02 2026 /usr/bin/broken-\\377-command\\n'",
              -- A zombie and an unparseable row, both of which the census
              -- already drops: replacement decoding must not start letting
              -- them in.
              "printf ' 103 100 101 Z Mon Jan  1 00:00:03 2026 /usr/bin/zombie\\n'",
              "printf 'ps: this row is not a process\\n'",
              "printf ' 104 100 101 S Mon Jan  1 00:00:04 2026 /usr/bin/last\\n'"
            ]
          )
          $ do
            snapshot <- readProcessSnapshot
            case snapshot of
              Left message -> expectationFailure ("expected a census, got " <> Data.Text.unpack message)
              Right identities -> do
                map processIdentityPid identities `shouldBe` [101, 102, 104]
                map processIdentityCommand identities
                  `shouldBe` [ Data.Text.pack "/usr/bin/first",
                               Data.Text.pack "/usr/bin/broken-\65533-command",
                               Data.Text.pack "/usr/bin/last"
                             ]

    -- The fail-closed contract of issue #10: a census that could not be
    -- taken stays a reported failure and never becomes an empty -- and so
    -- reassuring -- survivor list.
    it "still reports a failing ps as a census failure rather than an empty snapshot" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeOnPath
          temporaryRoot
          ("ps", ["printf '%s\\n' 'ps: illegal option -- q' >&2", "exit 3"])
          $ do
            snapshot <- readProcessSnapshot
            case snapshot of
              Right identities -> expectationFailure ("expected a census failure, got " <> show identities)
              Left message -> do
                Data.Text.unpack message `shouldContain` "ps exited 3"
                Data.Text.unpack message `shouldContain` "illegal option"

    it "hands a remote carrying an undecodable byte to the remote parser" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeOnPath temporaryRoot (gitRemoteFake "https://u\\377ser@github.com/coghex/kanban.git") $ do
          ByteString.writeFile (temporaryRoot </> checkoutMarker) ""
          -- The byte lands in the URL's optional userinfo, which the parser
          -- drops: the identity is decided by the parser on what it was
          -- given, exactly as it would have been for wholly decodable
          -- output.
          result <- resolveRepository "origin" temporaryRoot Nothing
          case result of
            Left message -> expectationFailure ("expected a resolved repository, got " <> Data.Text.unpack message)
            Right repository -> do
              repository.repositoryOwner `shouldBe` "coghex"
              repository.repositoryName `shouldBe` "kanban"

    it "rejects an undecodable remote identity semantically rather than as a git failure" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeOnPath temporaryRoot (gitRemoteFake "https://github.com/coghex/kanb\\377an.git") $ do
          ByteString.writeFile (temporaryRoot </> checkoutMarker) ""
          -- Here the byte lands inside the repository name, which git ran
          -- perfectly well to report. The existing ASCII-only identity rule
          -- still refuses it -- and says so about the remote, not about git.
          result <- resolveRepository "origin" temporaryRoot Nothing
          case result of
            Right repository -> expectationFailure ("expected a rejected remote, got " <> show repository)
            Left message -> do
              Data.Text.unpack message `shouldContain` "cannot derive OWNER/NAME from remote URL"
              Data.Text.unpack message `shouldContain` "kanb\65533an"

    it "preserves a failing git's own diagnostic" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeOnPath
          temporaryRoot
          ("git", ["printf '%s\\n' 'fatal: not a git repository (or any of the parent directories)' >&2", "exit 128"])
          $ do
            result <- resolveRepository "origin" temporaryRoot Nothing
            case result of
              Right repository -> expectationFailure ("expected a git failure, got " <> show repository)
              Left message -> do
                Data.Text.unpack message `shouldContain` "git could not identify a repository"
                Data.Text.unpack message `shouldContain` "fatal: not a git repository"

    -- The condition that cannot be established from in here, for the same
    -- reason the gh probe beside this one re-execs: GHC fixes the locale
    -- encoding before main runs. A repository root is a path rather than a
    -- diagnostic, so what the child proves is that the resolved value still
    -- reaches the real checkout, not merely that it decoded to something.
    it "resolves a repository whose path a C locale cannot decode, and the root still reaches it" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withLocaleProbe temporaryRoot $ \probe -> do
          probe.localeProbeLcAll `shouldBe` Data.Text.pack "C"
          probe.localeProbeRepositoryIdentity `shouldBe` Data.Text.pack "coghex/kanban"
          -- git's own answer when the resolved root was handed back to it.
          Data.Text.unpack (Data.Text.strip probe.localeProbeRepositoryRoot)
            `shouldEndWith` ("/" <> Data.Text.unpack unicodeCheckoutName)

    it "hands a provider probe's real exit status and replacement-decoded output to the classifier" $
      withPreflightMachine [undecodableCodexFake, readyClaudeFake, readyGitHubFake, python3Fake] BackendInstalled $
        \root _ -> do
          environment <- gatherPreflightEnvironment root
          -- Both classifications are reached only by reading what codex
          -- actually printed and what it actually exited with; a decoder
          -- failure would have replaced each with an unknown.
          environment.environmentCodex.probeVersion `shouldBe` VersionSupported (Data.Text.pack "0.144.6")
          environment.environmentCodex.probeAuth
            `shouldBe` AuthNotAuthenticated (Data.Text.pack "codex login status exited 1 (Not logged in\65533)")

    it "still times out a provider probe that never exits" $
      withPreflightMachine [hangingGitHubFake, python3Fake] BackendInstalled $ \root _ -> do
        environment <- gatherPreflightEnvironment root
        case environment.environmentGitHub of
          GitHubUnknown message -> Data.Text.unpack message `shouldContain` "timed out"
          other -> expectationFailure ("expected a timed-out probe, got " <> show other)

  describe "solve launch against a session attached while the chooser sits open" $ do
    -- 'startIssueSolve' and 'openIssueSolveChooser' both run in brick's
    -- 'EventM', which no unit test here can drive; this covers
    -- 'reusableSolveSession', the single predicate they now share. A 'Just'
    -- answer is precisely what routes a chooser digit into
    -- 'openExistingSolveOverlay' -- select 'SolveOverlay', present the
    -- transcript, return -- instead of the 'Map.insert' plus
    -- 'launchSolveInvocation' that would replace the session.
    let sessionFor workflow phase =
          SolveSession
            { solveSessionIssue = baseIssue 40 [],
              solveSessionWorkflow = workflow,
              solveSessionBrand = CodexSolver,
              solveSessionId = Just "recovered-worker-session",
              solveSessionPhase = phase,
              solveSessionActivity = "reattaching persistent worker",
              solveSessionActivityStartedAt = epoch,
              solveSessionLogPath = Just "/tmp/recovered.jsonl",
              solveSessionTranscript = ChatTranscript "recovered" "" "",
              solveSessionInput = "",
              solveSessionSpinnerFrame = 0,
              solveSessionAutoProgress = Nothing,
              solveSessionResumeProvenance = ResumeAnswer,
              solveSessionFollowing = True
            }
        sessionsWith session = Map.fromList [(40, session)]

    it "reuses a session that persistent-worker discovery attached after the chooser opened" $ do
      -- The chooser opened because nothing was attached yet...
      reusableSolveSession AutoSolve 40 Map.empty `shouldBe` Nothing
      -- ...then 'ensureWorkerSession' inserted the recovered session, and the
      -- digit that follows must return that very object, untouched: its
      -- transcript, log path, and worker session id are what the live worker's
      -- events still target.
      let recovered = sessionFor SolveOnly SolveStarting
      reusableSolveSession AutoSolve 40 (sessionsWith recovered) `shouldBe` Just recovered
      reusableSolveSession SolveOnly 40 (sessionsWith recovered) `shouldBe` Just recovered

    it "reuses any still-running session, whichever workflow was requested" $
      mapM_
        (\phase -> reusableSolveSession AutoSolve 40 (sessionsWith (sessionFor SolveOnly phase)) `shouldSatisfy` isJust)
        [SolveStarting, SolveRunning, SolveAttention, SolveOrphanedPhase]

    it "still replaces a finished session belonging to a different workflow" $ do
      reusableSolveSession AutoSolve 40 (sessionsWith (sessionFor SolveOnly SolveFinished)) `shouldBe` Nothing
      reusableSolveSession AutoSolve 40 (sessionsWith (sessionFor AutoSolve SolveFinished))
        `shouldBe` Just (sessionFor AutoSolve SolveFinished)

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

  describe "Claude usage probe termination" $ do
    it "decodes a clean-exiting probe's usage without ever needing TERM or KILL" $
      -- separateGroup=True so the wrapper's background job keeps its real
      -- stdin (bash redirects a backgrounded job's stdin to /dev/null unless
      -- job control put it in its own process group) -- the fake claude
      -- child needs the actual bytes Kanban writes to know when to exit.
      -- The descendant exits on its own once it has drained them, so
      -- escalation never needs to signal anyone.
      withClaudeProbeFixture True ClaudeExitsCleanly True $ \fixture -> do
        result <- timeout 20000000 (runClaudeProvider 8000000 fixture.claudeProbeScriptPath fixture.claudeProbeClaudePath)
        case result of
          Nothing -> expectationFailure "expected the clean-exit probe to return well within its bound"
          Just (Left providerError) -> expectationFailure ("expected a decoded snapshot, got " <> show providerError)
          Just (Right snapshot) -> map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["5 hour", "week"]
        shouldRecordASweptProcess fixture.claudeProbeScriptMarker "the script wrapper"
        shouldRecordASweptProcess fixture.claudeProbeChildMarker "the claude child"
        doesFileExist fixture.claudeProbeTermMarker `shouldReturn` False

    it "kills a reaped wrapper's INT-resistant claude child even though a pty gave it a separate session" $
      -- The wrapper has no INT handler of its own and dies immediately, well
      -- before the claude child (which ignores INT, in its own process
      -- group) does -- exactly the "leader reaped, descendant survives"
      -- shape 'script''s pty produces in production.
      withClaudeProbeFixture True ClaudeIgnoresInterrupt False $ \fixture -> do
        result <- timeout 20000000 (runClaudeProvider 1000000 fixture.claudeProbeScriptPath fixture.claudeProbeClaudePath)
        case result of
          Just (Left providerError) -> providerError.providerErrorKind `shouldBe` RequestTimedOut
          other -> expectationFailure ("expected a clean timeout, got " <> show other)
        shouldRecordASweptProcess fixture.claudeProbeScriptMarker "the script wrapper"
        shouldRecordASweptProcess fixture.claudeProbeChildMarker "the claude child"
        -- Confirms escalation actually reached TERM for the child, rather
        -- than the assertions above passing for some unrelated reason.
        doesFileExist fixture.claudeProbeTermMarker `shouldReturn` True

    it "kills an INT-resistant claude child that still shares the wrapper's own process group" $
      withClaudeProbeFixture False ClaudeIgnoresInterrupt False $ \fixture -> do
        result <- timeout 20000000 (runClaudeProvider 1000000 fixture.claudeProbeScriptPath fixture.claudeProbeClaudePath)
        case result of
          Just (Left providerError) -> providerError.providerErrorKind `shouldBe` RequestTimedOut
          other -> expectationFailure ("expected a clean timeout, got " <> show other)
        shouldRecordASweptProcess fixture.claudeProbeScriptMarker "the script wrapper"
        shouldRecordASweptProcess fixture.claudeProbeChildMarker "the claude child"
        doesFileExist fixture.claudeProbeTermMarker `shouldReturn` True

    it "reports a forced-kill failure instead of a decoded snapshot when a captured probe refuses TERM and needs SIGKILL" $
      -- Valid /usage was already captured -- the transcript decodes cleanly
      -- on its own -- but the claude child ignores both INT and TERM, so
      -- only SIGKILL ends it; the provider must report that as a failure
      -- rather than silently decode the snapshot it already has.
      withClaudeProbeFixture True ClaudeIgnoresInterruptAndTerminate True $ \fixture -> do
        result <- timeout 20000000 (runClaudeProvider 8000000 fixture.claudeProbeScriptPath fixture.claudeProbeClaudePath)
        case result of
          Just (Left providerError) -> do
            providerError.providerErrorKind `shouldBe` RequestFailed
            providerError.providerErrorMessage `shouldMention` "forced kill"
          other -> expectationFailure ("expected a forced-kill failure, got " <> show other)
        shouldRecordASweptProcess fixture.claudeProbeScriptMarker "the script wrapper"
        shouldRecordASweptProcess fixture.claudeProbeChildMarker "the claude child"

  describe "PR drainer LaunchAgent discovery" $ do
    let recordDocument label plist =
          ByteString.pack
            ( "{\"launchd_label\":\""
                <> label
                <> "\",\"plist_path\":\""
                <> plist
                <> "\",\"repository\":\"/tmp/example-project\"}"
            )
        failureFor = either id (\plist -> "unexpectedly resolved " <> Data.Text.pack plist)

    it "reads the label, plist path, and repository the installer recorded" $
      drainerRecordFromBytes
        (recordDocument "com.example.drain" "/Users/example/Library/LaunchAgents/com.example.drain.plist")
        `shouldBe` Right
          ( DrainerRecord
              "com.example.drain"
              "/Users/example/Library/LaunchAgents/com.example.drain.plist"
              "/tmp/example-project"
          )

    it "rejects a record that cannot name the installed job" $ do
      -- Each of these parses as JSON, or as an object, without identifying a
      -- launchd job — so each has to be an unreadable record rather than a
      -- lookup that proceeds on a value it cannot use.
      let rejects document = drainerRecordFromBytes document `shouldSatisfy` isLeft
      rejects "[\"com.example.drain\"]"
      rejects "\"com.example.drain\""
      rejects "{\"plist_path\":\"/tmp/x.plist\",\"repository\":\"/tmp/r\"}"
      rejects "{\"launchd_label\":\"com.example.drain\",\"repository\":\"/tmp/r\"}"
      rejects "{\"launchd_label\":\"com.example.drain\",\"plist_path\":\"/tmp/x.plist\"}"
      rejects "{\"launchd_label\":42,\"plist_path\":\"/tmp/x.plist\",\"repository\":\"/tmp/r\"}"
      rejects "{\"launchd_label\":\"com.example.drain\",\"plist_path\":[],\"repository\":\"/tmp/r\"}"
      rejects (recordDocument "   " "/tmp/x.plist")
      rejects (recordDocument "com.example.drain" "Library/LaunchAgents/x.plist")

    it "looks for that record where the installer fixes it, not where --install-dir moved" $ do
      recordPath <- drainerRecordPath
      Data.Text.pack recordPath
        `shouldMention` "/Library/Application Support/kanban/pr-drainer/config.json"

    it "names macOS rather than a missing /usr/bin/plutil on another host" $ do
      outcome <- resolveDrainerPlist "linux" "/nonexistent/pr-drainer/config.json"
      failureFor outcome `shouldMention` "macOS"

    it "says the drainer is not installed when no record was written" $
      withTemporaryCacheRoot $ \root -> do
        outcome <- resolveDrainerPlist "darwin" (root </> "config.json")
        failureFor outcome `shouldMention` "not installed"
        failureFor outcome `shouldMention` "tools/install_drainer.py"

    it "distinguishes an unreadable record from an absent one" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
        ByteString.writeFile recordPath (recordDocument "" "/tmp/x.plist")
        outcome <- resolveDrainerPlist "darwin" recordPath
        failureFor outcome `shouldMention` "unreadable"
        failureFor outcome `shouldMention` "tools/install_drainer.py"

    it "reports an installation predating the record without Aeson's JSONPath" $
      withTemporaryCacheRoot $ \root -> do
        -- What an install made before the record existed actually looks like:
        -- the installer's config.json is there, holding only the keys it
        -- always wrote.
        let recordPath = root </> "config.json"
        ByteString.writeFile recordPath "{\"ntfy_url\":\"https://notify.example.test/topic\"}"
        outcome <- resolveDrainerPlist "darwin" recordPath
        failureFor outcome `shouldMention` "launchd_label"
        failureFor outcome `shouldMention` "tools/install_drainer.py"
        failureFor outcome `shouldNotMention` "Error in $"

    it "reports a stale install when the recorded plist is gone" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
            plist = root </> "com.example.drain.plist"
        ByteString.writeFile recordPath (recordDocument "com.example.drain" plist)
        outcome <- resolveDrainerPlist "darwin" recordPath
        failureFor outcome `shouldMention` "LaunchAgent is missing"
        failureFor outcome `shouldMention` "tools/install_drainer.py"

    it "keeps a plist that will not parse distinct, and still names the repair" $ do
      -- The one failure the record cannot diagnose: it located the plist
      -- correctly and the file is there. plutil's own complaint is carried
      -- through, but re-running the installer rewrites the plist, so this
      -- branch is no less actionable than the others.
      let message =
            unreadablePlist
              "/Users/example/Library/LaunchAgents/com.example.drain.plist"
              "Property List error: Unexpected character b at line 1"
      message `shouldMention` "com.example.drain.plist"
      message `shouldMention` "Unexpected character"
      message `shouldMention` "tools/install_drainer.py"
      message `shouldNotMention` "install record"

    it "resolves the plist the record names, wherever the installer put it" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
            plist = root </> "com.example.drain.plist"
        ByteString.writeFile plist "<plist/>"
        ByteString.writeFile recordPath (recordDocument "com.example.drain" plist)
        resolveDrainerPlist "darwin" recordPath `shouldReturn` Right plist

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

    it "surfaces a per-pull-request merge-conflict incident on the board" $ do
      let result =
            decodeDrainerStatus
              "{\"state\":\"running\",\"open_incident\":{\"summary\":\"PR #42 has a merge conflict in README; the drainer left it unmerged.\",\"pull_request\":42,\"kind\":\"merge-conflict\"}}"
      result
        `shouldBe` Right
          ( DrainerStatus
              DrainerWarning
              "on · unresolved incident · PR #42 has a merge conflict in README; the drainer left it unmerged."
          )
      result `shouldSatisfy` either (const False) drainerIsRunning

    it "makes a stopped drainer with an unresolved incident an error" $
      decodeDrainerStatus "{\"state\":\"stopped\",\"open_incident\":{\"summary\":\"model failed\"}}"
        `shouldBe` Right (DrainerStatus DrainerError "stopped · unresolved incident · model failed")

    it "names the git operation a checkout stopped mid-operation has to finish" $ do
      let render operation =
            decodeDrainerStatus
              ( "{\"state\":\"mid_operation\",\"operation\":\""
                  <> operation
                  <> "\",\"open_incident\":null}"
              )
      render "merge" `shouldBe` Right (DrainerStatus DrainerError "merge in progress; finish or abort it")
      render "rebase" `shouldBe` Right (DrainerStatus DrainerError "rebase in progress; finish or abort it")
      render "cherry-pick" `shouldBe` Right (DrainerStatus DrainerError "cherry-pick in progress; finish or abort it")
      render "bisect" `shouldBe` Right (DrainerStatus DrainerError "bisect in progress; finish or abort it")

    it "still says something actionable when the controller names no operation" $ do
      decodeDrainerStatus "{\"state\":\"mid_operation\",\"operation\":null,\"open_incident\":null}"
        `shouldBe` Right (DrainerStatus DrainerError "unfinished git operation; finish or abort it")
      decodeDrainerStatus "{\"state\":\"mid_operation\",\"open_incident\":null}"
        `shouldBe` Right (DrainerStatus DrainerError "unfinished git operation; finish or abort it")

    it "no longer recognises the uncommitted-changes state the removed gate produced" $
      -- Ordinary uncommitted work is carried across the post-merge
      -- fast-forward by the drainer's own autostash, so a controller still
      -- reporting `dirty` is one that has had the blanket gate put back. The
      -- board must not have a rendering waiting for it.
      decodeDrainerStatus "{\"state\":\"dirty\",\"open_incident\":null}"
        `shouldBe` Right (DrainerStatus DrainerError "unknown state: dirty")

    it "warns when the singleton drainer belongs to another repository" $
      decodeDrainerStatus "{\"state\":\"foreign\",\"open_incident\":null}"
        `shouldBe` Right (DrainerStatus DrainerWarning "another repository is running")

    it "renders a state the controller reports but this version does not know as an error" $
      decodeDrainerStatus "{\"state\":\"paused\"}"
        `shouldBe` Right (DrainerStatus DrainerError "unknown state: paused")

    it "keeps a status document the controller printed while exiting nonzero" $ do
      -- Exiting nonzero while reporting "stopped with an unresolved incident"
      -- is the natural convention for that state, and the state machine
      -- already renders it in red with the incident attached. Collapsing it
      -- to an opaque error blob would discard exactly the detail the nonzero
      -- exit is flagging.
      statusFromControllerExit (ExitFailure 3) "{\"state\":\"stopped\",\"open_incident\":{\"summary\":\"model failed\"}}" ""
        `shouldBe` Right (DrainerStatus DrainerError "stopped · unresolved incident · model failed")

    it "prefers a decodable status over diagnostics the same failing run wrote to stderr" $
      statusFromControllerExit
        (ExitFailure 1)
        "{\"state\":\"running\",\"open_incident\":{\"summary\":\"prior crash\"}}"
        "launchctl: warning\n"
        `shouldBe` Right (DrainerStatus DrainerWarning "on · unresolved incident · prior crash")

    it "falls back to stderr when a failing run's output does not decode" $
      statusFromControllerExit (ExitFailure 2) "not json at all\n" "  controller exploded\n"
        `shouldBe` Left "controller exploded"

    it "falls back to stdout when a failing run wrote no diagnostics" $
      statusFromControllerExit (ExitFailure 2) "  not json at all\n" ""
        `shouldBe` Left "not json at all"

    it "still reports undecodable output from a successful run as a decode failure" $
      statusFromControllerExit ExitSuccess "not json at all\n" ""
        `shouldSatisfy` either (Data.Text.isPrefixOf "could not decode PR drainer status") (const False)

    it "decodes the status a real controller process prints while exiting nonzero" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- The interpreter above is pure, so only an actual process proves the
        -- exit code and the stream reach it the way they are produced.
        controller <-
          fakeController
            temporaryRoot
            [ "printf '%s' '{\"state\":\"stopped\",\"open_incident\":{\"summary\":\"model failed\"}}'",
              "echo 'controller reported a failure' >&2",
              "exit 4"
            ]
        runDrainerCommand 5 controller "status"
          `shouldReturn` Right (DrainerStatus DrainerError "stopped · unresolved incident · model failed")

    it "reports a failing controller's diagnostics when it printed nothing decodable" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        controller <- fakeController temporaryRoot ["echo 'launchd job is not loaded' >&2", "exit 1"]
        runDrainerCommand 5 controller "status" `shouldReturn` Left "launchd job is not loaded"

    it "leaves no survivor from a wedged controller's process group, and says the transition's outcome is unknown" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let leaderFile = temporaryRoot </> "leader-pid"
            descendantFile = temporaryRoot </> "descendant-pid"
        -- Both the controller and something it started ignore TERM, and the
        -- descendant holds the inherited pipes open, so nothing about the
        -- invocation ending implies either of them stopped. `create_group`
        -- puts both in the invocation's own group; the escalation has to
        -- reach the whole group and prove it empty, not just TERM the child.
        controller <-
          fakeController
            temporaryRoot
            [ "trap '' TERM",
              "sh -c \"trap '' TERM; while :; do sleep 1; done\" &",
              ByteString.pack ("echo $! > " <> descendantFile),
              ByteString.pack ("echo $$ > " <> leaderFile),
              "while :; do sleep 1; done"
            ]
        outcome <- runDrainerCommand 1 controller "start"
        -- Taken the instant the invocation returns, so this proves the group
        -- was already empty when the timeout was reported -- not merely that
        -- it emptied by the time an assertion got around to looking.
        snapshot <- readProcessSnapshot >>= requireRight "process snapshot after the drainer timeout"
        leaderPid <- readRecordedPid leaderFile
        descendantPid <- readRecordedPid descendantFile
        descendantPid `shouldNotBe` leaderPid
        identityForPid leaderPid snapshot `shouldBe` Nothing
        identityForPid descendantPid snapshot `shouldBe` Nothing
        message <- requireLeft "a wedged controller reported success" outcome
        message `shouldMention` "drainer start timed out after 1 seconds"
        message `shouldMention` "the outcome is unknown"
        message `shouldMention` "the next status poll will reconcile it"

    it "terminates a descendant still holding the pipes after the controller itself exits" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let descendantFile = temporaryRoot </> "orphan-pid"
        -- The controller exits promptly and cleanly; what keeps the read
        -- blocked to the timeout is the TERM-resistant descendant holding
        -- the inherited pipes open. Its leader is a zombie by then and so is
        -- absent from every process snapshot -- which is exactly why group
        -- ownership has to be established at spawn. Deciding it here instead
        -- could not tell this case apart from a pgid this process never
        -- owned, and refusing would leave the descendant running for the
        -- next ten-second poll to overlap.
        controller <-
          fakeController
            temporaryRoot
            [ "sh -c \"trap '' TERM; while :; do sleep 1; done\" &",
              ByteString.pack ("echo $! > " <> descendantFile),
              "exit 0"
            ]
        outcome <- runDrainerCommand 1 controller "status"
        snapshot <- readProcessSnapshot >>= requireRight "process snapshot after the orphaned-descendant timeout"
        descendantPid <- readRecordedPid descendantFile
        identityForPid descendantPid snapshot `shouldBe` Nothing
        message <- requireLeft "an orphaned descendant reported success" outcome
        message `shouldMention` "drainer status timed out after 1 seconds"
        -- A terminated group is a settled timeout, not a cleanup failure.
        message `shouldNotMention` "could not"
        message `shouldNotMention` "still running"

    it "terminates a replacement the controller's own TERM handler forked before exiting" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let leaderFile = temporaryRoot </> "handler-leader-pid"
            forkedFile = temporaryRoot </> "handler-forked-pid"
        -- The nastiest shape a single pass cannot settle. Escalation stops
        -- as soon as the members censused before it signalled are gone, so a
        -- TERM handler that forks a replacement and *then* exits satisfies
        -- that pass without SIGKILL ever being sent -- and the replacement,
        -- which no signal has yet reached, is left holding the group. Only a
        -- second census finds it.
        controller <-
          fakeController
            temporaryRoot
            [ "spawn_replacement() {",
              "  sh -c 'trap \"\" TERM; while :; do sleep 1; done' &",
              ByteString.pack ("  echo $! > " <> forkedFile),
              "  exit 0",
              "}",
              "trap spawn_replacement TERM",
              ByteString.pack ("echo $$ > " <> leaderFile),
              "while :; do sleep 1; done"
            ]
        outcome <- runDrainerCommand 1 controller "status"
        snapshot <- readProcessSnapshot >>= requireRight "process snapshot after the forking-handler timeout"
        leaderPid <- readRecordedPid leaderFile
        forkedPid <- readRecordedPid forkedFile
        forkedPid `shouldNotBe` leaderPid
        identityForPid leaderPid snapshot `shouldBe` Nothing
        identityForPid forkedPid snapshot `shouldBe` Nothing
        message <- requireLeft "a forking TERM handler reported success" outcome
        message `shouldMention` "drainer status timed out after 1 seconds"
        message `shouldNotMention` "still running"

    it "keeps the outcome-unknown wording generic for a timed-out status query" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- A killed status query changed nothing, so there is no transition
        -- for the poll to reconcile and nothing unknown to promise about.
        controller <- fakeController temporaryRoot ["while :; do sleep 1; done"]
        outcome <- runDrainerCommand 1 controller "status"
        message <- requireLeft "a wedged status query reported success" outcome
        message `shouldMention` "drainer status timed out after 1 seconds"
        message `shouldNotMention` "reconcile"

  describe "PR drainer toggle decisions" $ do
    it "issues no second start while a reported start is still in flight" $
      -- The status poll can report `starting` for a transition this
      -- dashboard never began, and `drainerIsRunning` calls that "not
      -- running" -- which is precisely how the toggle used to answer a start
      -- already under way with another one.
      case drainerToggle False (DrainerStatus DrainerStarting "starting…") of
        DrainerToggleBusy notice -> notice `shouldBe` "PR drainer is already starting"
        decision -> expectationFailure ("a reported starting drainer produced " <> show decision)

    it "issues nothing while this dashboard's own toggle is still in flight" $
      case drainerToggle True (DrainerStatus DrainerOff "off") of
        DrainerToggleBusy notice -> notice `shouldBe` "PR drainer is already starting or stopping"
        decision -> expectationFailure ("a busy toggle produced " <> show decision)

    it "starts a settled off drainer and stops a settled running one" $ do
      drainerToggle False (DrainerStatus DrainerOff "off") `shouldBe` StartDrainer
      drainerToggle False (DrainerStatus DrainerOn "on") `shouldBe` StopDrainer
      drainerToggle False (DrainerStatus DrainerWarning "on · unresolved incident") `shouldBe` StopDrainer
      drainerToggle False (DrainerStatus DrainerError "merge in progress; finish or abort it") `shouldBe` StartDrainer

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

    -- A card restored from cache has to keep saying what it does not know.
    -- Reloading one with its gaps dropped would put back the amber marker's
    -- absence and the definite "unassigned" the live decode refused.
    it "round-trips the per-item data gaps" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
              issue = (baseIssue 41 []) {issueDataGaps = [AssigneesUnavailable]}
              pullRequest =
                (basePullRequest 823 [] False [])
                  {pullRequestDataGaps = [LabelsUnavailable, ChecksUndecodable]}
              snapshot = RepoSnapshot [issue] [pullRequest] epoch False False
          writeRepositoryCache repository snapshot `shouldReturn` Right ()
          loadRepositoryCache repository `shouldReturn` CacheLoaded snapshot

    -- §16: an unknown version is absent, not corruption. Meeting a file
    -- written by another version of the binary is the expected outcome of an
    -- upgrade or a downgrade, so it must start up exactly as it would with no
    -- cache at all -- no warning, nothing for the user to act on.
    it "treats a future schema version as absent rather than as corruption" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
          writeRepositoryCache repository (RepoSnapshot [] [] epoch False False) `shouldReturn` Right ()
          cachePath <- repositoryCachePath repository
          ByteString.writeFile cachePath (versionThreeCacheFile 999)
          loadRepositoryCache repository `shouldReturn` CacheAbsent

    -- Version 3 knew nothing of those gaps, so reusing one of its entries
    -- would restore a card as though every field had arrived.
    it "treats a genuine version 3 file as absent rather than as malformed" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
          writeRepositoryCache repository (RepoSnapshot [] [] epoch False False) `shouldReturn` Right ()
          cachePath <- repositoryCachePath repository
          ByteString.writeFile cachePath (versionThreeCacheFile 3)
          loadRepositoryCache repository `shouldReturn` CacheAbsent
          -- The version gate, not the decoder, is what turned it away:
          -- relabelled as current, the same file fails on its missing gap
          -- fields and keeps the warning a real corruption earns.
          ByteString.writeFile cachePath (versionThreeCacheFile repositoryCacheSchemaVersion)
          relabeled <- loadRepositoryCache repository
          relabeled `shouldSatisfy` isInvalidCache

    -- A real version 2 file wrote its check summaries as two aggregate counts,
    -- so its snapshot cannot decode under the current schema at all. The
    -- version has to be read before the snapshot, or the user is told the file
    -- is malformed JSON when the truthful answer is that it is simply old.
    it "treats a genuine version 2 file as absent rather than as malformed" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
          -- Write a current cache first, so the old file lands where the
          -- loader looks for it.
          writeRepositoryCache repository (RepoSnapshot [] [] epoch False False) `shouldReturn` Right ()
          cachePath <- repositoryCachePath repository
          ByteString.writeFile cachePath (versionTwoCacheFile 2)
          loadRepositoryCache repository `shouldReturn` CacheAbsent
          -- Proof the version gate is what turned it away: relabel that same
          -- old-shaped file as current, and the snapshot decode fails instead.
          ByteString.writeFile cachePath (versionTwoCacheFile repositoryCacheSchemaVersion)
          relabeled <- loadRepositoryCache repository
          relabeled `shouldSatisfy` isInvalidCache

    -- Only a version is silent. A file with no integer version to read is not
    -- "from another release", it is unreadable, and still warns.
    it "keeps warning for a file with no usable schema version" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
          writeRepositoryCache repository (RepoSnapshot [] [] epoch False False) `shouldReturn` Right ()
          cachePath <- repositoryCachePath repository
          ByteString.writeFile cachePath "{\"repositoryKey\":\"coghex/kanban\",\"snapshot\":{}}"
          missing <- loadRepositoryCache repository
          missing `shouldSatisfy` isInvalidCache
          ByteString.writeFile cachePath "{\"schemaVersion\":\"four\",\"repositoryKey\":\"coghex/kanban\"}"
          notAnInteger <- loadRepositoryCache repository
          notAnInteger `shouldSatisfy` isInvalidCache

    -- A recognised version that names someone else's repository is a real
    -- mix-up rather than a version skew, so it keeps the warning.
    it "still reports a recognised-version file belonging to another repository as invalid" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let mine = Repository "/tmp/project" "coghex" "kanban"
              theirs = Repository "/tmp/other" "coghex" "other"
          writeRepositoryCache mine (RepoSnapshot [] [] epoch False False) `shouldReturn` Right ()
          minePath <- repositoryCachePath mine
          theirsPath <- repositoryCachePath theirs
          ByteString.readFile minePath >>= ByteString.writeFile theirsPath
          loadRepositoryCache theirs `shouldReturn` CacheInvalid "cache ignored: repository identity mismatch"

    it "round-trips global usage snapshots" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let codexUsage = UsageSnapshot [UsageWindow "week" 77 epoch] epoch
              claudeUsage = UsageSnapshot [UsageWindow "5 hour" 65 epoch] epoch
              snapshots = Map.fromList [(Codex, codexUsage), (Claude, claudeUsage)]
          writeUsageCache snapshots `shouldReturn` Right ()
          loadUsageCache `shouldReturn` UsageCacheLoaded snapshots

    -- The usage cache follows the same policy, and needs the same
    -- version-before-payload order to do so: its snapshots are decoded from a
    -- shape that a future version is free to change.
    it "treats an unknown usage schema version as absent, whatever its payload looks like" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          writeUsageCache (Map.fromList [(Codex, UsageSnapshot [UsageWindow "week" 77 epoch] epoch)]) `shouldReturn` Right ()
          path <- usageCachePath
          ByteString.writeFile path "{\"schemaVersion\":999,\"snapshots\":\"whatever this came to mean\"}"
          loadUsageCache `shouldReturn` UsageCacheAbsent
          -- Relabelled as current, that same payload is a genuine decode
          -- failure -- so the version, not the decoder, produced the silence.
          ByteString.writeFile path "{\"schemaVersion\":1,\"snapshots\":\"whatever this came to mean\"}"
          relabeled <- loadUsageCache
          relabeled `shouldSatisfy` isInvalidUsageCache

    it "keeps warning for a corrupt or version-less usage cache" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          writeUsageCache Map.empty `shouldReturn` Right ()
          path <- usageCachePath
          ByteString.writeFile path "not JSON"
          corrupt <- loadUsageCache
          corrupt `shouldSatisfy` isInvalidUsageCache
          ByteString.writeFile path "{\"snapshots\":{}}"
          missing <- loadUsageCache
          missing `shouldSatisfy` isInvalidUsageCache

  -- 'createDirectoryIfMissing' gives a parent it creates the process umask,
  -- so chmodding only the leaf left ~/.cache/kanban at whatever mode the
  -- writer that happened to run first was given -- and the cache holds issue
  -- and pull request bodies from private repositories.
  describe "private state directory permissions" $ do
    it "creates every cache level it owns as 0700 under a permissive umask, and leaves the XDG root alone" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let xdgRoot = temporaryRoot </> "cache"
            repository = Repository "/tmp/project" "coghex" "kanban"
        createDirectory xdgRoot
        setFileMode xdgRoot 0o755
        withEnvironmentValue "XDG_CACHE_HOME" xdgRoot $
          withFileCreationMask 0o000 $ do
            writeRepositoryCache repository (RepoSnapshot [] [] epoch False False) `shouldReturn` Right ()
            cachePath <- repositoryCachePath repository
            permissionsOf (xdgRoot </> "kanban") `shouldReturn` 0o700
            permissionsOf (takeDirectory cachePath) `shouldReturn` 0o700
            permissionsOf cachePath `shouldReturn` 0o600
            permissionsOf xdgRoot `shouldReturn` 0o755

    -- The transcript root is three levels deep, so the intermediate "logs"
    -- directory is one no writer ever chmodded; here both it and a kanban
    -- directory an earlier version left loose are tightened.
    it "tightens intermediate levels an earlier writer left loose" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let xdgRoot = temporaryRoot </> "cache"
            repository = Repository "/tmp/project" "coghex" "kanban"
        createDirectory xdgRoot
        setFileMode xdgRoot 0o755
        createDirectoryIfMissing True (xdgRoot </> "kanban" </> "logs")
        setFileMode (xdgRoot </> "kanban") 0o755
        setFileMode (xdgRoot </> "kanban" </> "logs") 0o755
        withEnvironmentValue "XDG_CACHE_HOME" xdgRoot $
          withFileCreationMask 0o000 $ do
            opened <- openSessionLog repository "solve-claude" 45 Nothing
            case opened of
              Left message -> expectationFailure (Data.Text.unpack message)
              Right sessionLog -> closeSessionLog sessionLog
            logsRoot <- transcriptRoot repository
            permissionsOf (xdgRoot </> "kanban") `shouldReturn` 0o700
            permissionsOf (xdgRoot </> "kanban" </> "logs") `shouldReturn` 0o700
            permissionsOf logsRoot `shouldReturn` 0o700
            permissionsOf xdgRoot `shouldReturn` 0o755

    it "creates the config level it owns as 0700 under a permissive umask" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let xdgRoot = temporaryRoot </> "config"
        createDirectory xdgRoot
        setFileMode xdgRoot 0o755
        withEnvironmentValue "XDG_CONFIG_HOME" xdgRoot $
          withFileCreationMask 0o000 $ do
            saveSettings (Settings FullChat) `shouldReturn` Right ()
            path <- settingsPath
            permissionsOf (xdgRoot </> "kanban") `shouldReturn` 0o700
            permissionsOf path `shouldReturn` 0o600
            permissionsOf xdgRoot `shouldReturn` 0o755

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

    -- An item missing data reaches the same amber incomplete treatment the
    -- overflow markers use, and its card says what it does not know rather
    -- than asserting the absence as a fact.
    it "renders an item with missing data amber, without claiming it is unassigned or unlinked" $ do
      let issue = (baseIssue 812 []) {issueDataGaps = [AssigneesUnavailable]}
          pullRequest = (basePullRequest 823 [] False []) {pullRequestDataGaps = [LinkedIssuesUnavailable]}
      itemHasAmberWarning defaultWorkflowConfig (IssueItem issue) `shouldBe` True
      itemHasAmberWarning defaultWorkflowConfig (PullRequestItem pullRequest) `shouldBe` True
      pullRequestCardAttribute defaultWorkflowConfig pullRequest `shouldBe` pendingAttr
      let issueCard = renderCard testOptions False (Standalone (IssueItem issue)) 46
      issueCard `shouldSatisfy` any (Data.Text.isInfixOf "assignees unknown")
      issueCard `shouldSatisfy` not . any (Data.Text.isInfixOf "unassigned")
      let pullRequestCard = renderCard testOptions False (Standalone (PullRequestItem pullRequest)) 46
      pullRequestCard `shouldSatisfy` any (Data.Text.isInfixOf "LINKS UNKNOWN")
      pullRequestCard `shouldSatisfy` not . any (Data.Text.isInfixOf "UNLINKED")

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

    -- The overlay is where a user goes to find out what the amber card means,
    -- so it is the last place that may present missing data as a verdict.
    it "says an item's assignees and links are unknown when GitHub never delivered them" $ do
      let issue = (baseIssue 36 []) {issueDataGaps = [AssigneesUnavailable]}
          pullRequest = (basePullRequest 823 [] False []) {pullRequestDataGaps = [LinkedIssuesUnavailable]}
      detailsText (renderDetails detailsFixtureBoard (IssueItem issue)) "Assignees" `shouldBe` Just "assignees unknown"
      detailsText (renderDetails detailsFixtureBoard (PullRequestItem pullRequest)) "Linked issues" `shouldBe` Just "LINKS UNKNOWN"

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

  -- The card frame pre-wraps its title and excerpt with Kanban.Card's own
  -- 'boundedLines'/'displayWidth' (already covered directly), but the details
  -- overlay hands its title and body to Brick's own 'txtWrap'. These render
  -- through that production Brick/Vty path -- not a duplicate width
  -- algorithm -- and stay separate from the full golden-frame scope of #55.
  describe "Unicode rendering through Brick's own reflow" $ do
    -- A CJK title has no whitespace for txtWrap to break on, so it emits the
    -- title as one unbroken line; the frame then relies on Vty to clip that
    -- line to the width it was given rather than reflow it onto more rows.
    -- This is the "clipping" half of the wrapping-or-clipping contract, and
    -- it holds regardless: no row may ever exceed the given width.
    it "clips an unbroken CJK title to the given width rather than overrunning it" $ do
      let wideTitle = Data.Text.replicate 40 "漢"
          issue = (baseIssue 5 []) {issueTitle = wideTitle}
          rendered = renderDetailsAt 20 (fixtureBoard []) (IssueItem issue)
      map displayWidth rendered `shouldSatisfy` all (<= 20)
      Data.Text.count "漢" (Data.Text.concat rendered) `shouldBe` 20 `div` 2

    it "renders a base-plus-combining-mark title intact through the same path" $ do
      let combiningTitle = "5\817"
          issue = (baseIssue 6 []) {issueTitle = combiningTitle}
          rendered = renderDetailsAt 40 (fixtureBoard []) (IssueItem issue)
      rendered `shouldSatisfy` any (Data.Text.isInfixOf combiningTitle)

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
      -- One coordinator serves every revision session, and a backend
      -- failure fails all of them. If its preflight depended on an issue's
      -- origin, a Claude-origin issue with no Claude CLI would fail the
      -- backend for a Codex-origin revision queued behind it, and tell that
      -- session to install Claude.
      it "keeps the shared revision coordinator's preflight origin-independent" $ do
        let claudeMissing = withClaudeProbe (readyProviderProbe ClaudeSolver) {probeExecutable = Nothing}
            codexMissing = withCodexProbe (readyProviderProbe CodexSolver) {probeExecutable = Nothing}
        blockedProblems claudeMissing reviewBackendAction `shouldBe` []
        blockedProblems claudeMissing (ActionIssueRevision IssueOriginClaude)
          `shouldBe` [ExecutableUnavailable]
        -- A genuinely shared cause still fails the coordinator, which is
        -- what every queued session needs to hear.
        blockedProblems codexMissing reviewBackendAction `shouldBe` [ExecutableUnavailable]
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
